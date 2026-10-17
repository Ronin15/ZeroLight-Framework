// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const sprite_batch = @import("../render/sprite_batch.zig");
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const sprite_prep_range_alignment_items: usize = 1;
const ordered_workload_total_parts: usize = 10;
const ordered_workload_world_parts: usize = 8;
const ordered_workload_ui_parts: usize = 1;
const ordered_world_depth_buckets: usize = 16;
const ordered_ui_depths = [_]sprite_batch.UiDepth{ .background, .panel, .highlight, .text };

// `render-prep` (CPU only, no window or GPU submission): each iteration submits an ordered
// stream of N sprites (world depth buckets, then UI depths, then the debug overlay; every
// 23rd on a dead texture) into one `SpriteBatch`, then snapshots, emits vertices (the
// threaded stage), and builds draw groups. Prints `vertices=`, `sprites=` (valid),
// `skipped=` (unresolved textures), `groups=`, and the bench's own phase timers
// (`ordered_submit`, `snapshot`, `vertex_emit`, `draw_groups`). No pass shape asserted.
pub const group = suite.BenchmarkGroup{
    .name = "render-prep",
    .item_label = "draw commands",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
    .write_workload = writeRenderPrepWorkload,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    const table = &fixtures.TextureTable.bench;

    var batch = sprite_batch.SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(item_count, item_count * 6, item_count);

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();

    if (suite.adaptiveTunerForCase(case, sprite_prep_range_alignment_items)) |tuner| {
        batch.adaptive_tuner = tuner;
    }

    // Warm up and settle through the same decomposed path used for measurement so
    // settled_before_measurement and work_tuning reflect the path actually timed.
    for (0..options.warmup_iterations) |_| {
        _ = try runMeasuredOnce(item_count, &batch, table.resolver(), if (threads) |*thread_system| thread_system else null, case, io);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!batch.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runMeasuredOnce(item_count, &batch, table.resolver(), if (threads) |*thread_system| thread_system else null, case, io);
        }
    }
    const settled_before_measurement = if (case.adaptive) batch.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var phase_accumulator = fixtures.PhaseAccumulator(suite.RenderPrepPhaseSummary){};
    var last_prep = sprite_batch.SpritePrepStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const measured = try runMeasuredOnce(item_count, &batch, table.resolver(), if (threads) |*thread_system| thread_system else null, case, io);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), measured.stats.batch);
        phase_accumulator.record(measured.phases);
        last_prep = measured.stats;
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_prep.vertex_count;
    stats.output_count = last_prep.valid_sprite_count;
    stats.deferred_count = last_prep.skipped_invalid_count;
    stats.sample_count = last_prep.draw_group_count;
    stats.render_prep_phases = phase_accumulator.finish(options.iterations);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(batch.adaptive_tuner.report(), settled_before_measurement);
    }
    return stats;
}

const MeasuredPrep = struct {
    stats: sprite_batch.SpritePrepStats,
    phases: suite.RenderPrepPhaseSummary,
};

fn runMeasuredOnce(
    item_count: usize,
    batch: *sprite_batch.SpriteBatch,
    resolver: sprite_batch.TextureResolver,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
    io: std.Io,
) !MeasuredPrep {
    const submit_start_ns = suite.nowNs(io);
    try submitOrderedCommandsOnce(batch, item_count);
    const submit_end_ns = suite.nowNs(io);

    const snapshot_start_ns = suite.nowNs(io);
    _ = batch.snapshotCommandsAssumeCapacity(resolver);
    const snapshot_end_ns = suite.nowNs(io);

    const vertex_start_ns = suite.nowNs(io);
    const vertex_batch = emitVertices(batch, thread_system, case);
    const vertex_end_ns = suite.nowNs(io);

    const group_start_ns = suite.nowNs(io);
    batch.buildDrawGroupsAssumeCapacity();
    const stats = batch.finishPrepStats(vertex_batch);
    const group_end_ns = suite.nowNs(io);

    return .{
        .stats = stats,
        .phases = .{
            .ordered_submit_ns = suite.elapsedNs(submit_start_ns, submit_end_ns),
            .snapshot_ns = suite.elapsedNs(snapshot_start_ns, snapshot_end_ns),
            .vertex_emit_ns = suite.elapsedNs(vertex_start_ns, vertex_end_ns),
            .draw_group_ns = suite.elapsedNs(group_start_ns, group_end_ns),
        },
    };
}

fn emitVertices(
    batch: *sprite_batch.SpriteBatch,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    if (!case.usesThreadSystem()) {
        return batch.emitVerticesAssumeCapacity(null, .{ .adaptive = false });
    }

    return batch.emitVerticesAssumeCapacity(thread_system.?, .{
        .items_per_range = case.stageItemsPerRange(sprite_prep_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn submitOrderedCommandsOnce(batch: *sprite_batch.SpriteBatch, count: usize) !void {
    batch.commands.clearRetainingCapacity();
    batch.last_order = null;
    for (0..count) |index| {
        try batch.drawSprite(benchmarkSprite(index, orderedBenchmarkOrder(index, count)));
    }
}

fn benchmarkSprite(index: usize, order: sprite_batch.RenderOrder) sprite_batch.Sprite {
    const texture = if (index % 23 == 0)
        fixtures.textureId(4, 1)
    else
        fixtures.textureId(@intCast(index % 4), 1);
    return .{
        .texture = texture,
        .source = if (index % 5 == 0)
            sprite_batch.Rect{ .x = 2, .y = 4, .w = 12, .h = 12 }
        else
            null,
        .dest = .{
            .x = @floatFromInt((index * 13) % 1280),
            .y = @floatFromInt((index * 7) % 720),
            .w = 12 + @as(f32, @floatFromInt(index % 11)),
            .h = 12 + @as(f32, @floatFromInt(index % 9)),
        },
        .tint = fixtures.tintFor(index),
        .origin = .{
            .x = if (index % 3 == 0) 6 else 0,
            .y = if (index % 3 == 0) 6 else 0,
        },
        .rotation = if (index % 3 == 0) @as(f32, @floatFromInt(index % 31)) * 0.01 else 0,
        .order = order,
        .coordinate_space = switch (index % 6) {
            0, 1, 2, 3 => .world,
            4 => .logical,
            else => .drawable,
        },
    };
}

fn orderedBenchmarkOrder(index: usize, count: usize) sprite_batch.RenderOrder {
    const world_count = count * ordered_workload_world_parts / ordered_workload_total_parts;
    const ui_count = count * ordered_workload_ui_parts / ordered_workload_total_parts;
    if (index < world_count) {
        return sprite_batch.RenderOrder.world(@intCast(index / @max(@as(usize, 1), world_count / ordered_world_depth_buckets)));
    }
    if (index < world_count + ui_count) {
        const ui_depth_index = (index - world_count) / @max(@as(usize, 1), ui_count / ordered_ui_depths.len);
        return sprite_batch.RenderOrder.ui(ordered_ui_depths[@min(ui_depth_index, ordered_ui_depths.len - 1)]);
    }
    return sprite_batch.RenderOrder.debug(.overlay);
}

fn writeRenderPrepWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("vertices={} sprites={} skipped={} groups={}", .{ stats.candidate_pairs, stats.output_count, stats.deferred_count, stats.sample_count });
    const phases = stats.render_prep_phases orelse return;
    try writer.print(" phases ordered_submit={f} snapshot={f} vertex_emit={f} draw_groups={f}", .{ suite.formatDuration(phases.ordered_submit_ns), suite.formatDuration(phases.snapshot_ns), suite.formatDuration(phases.vertex_emit_ns), suite.formatDuration(phases.draw_group_ns) });
}
