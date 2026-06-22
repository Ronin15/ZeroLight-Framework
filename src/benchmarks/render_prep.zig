// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const config = @import("../config.zig");
const math = @import("../core/math.zig");
const resources = @import("../render/resources.zig");
const RenderQueue = @import("../render/render_queue.zig").RenderQueue;
const sprite_batch = @import("../render/sprite_batch.zig");
const suite = @import("suite.zig");

const sprite_prep_range_alignment_items: usize = 1;
const ordered_workload_total_parts: usize = 10;
const ordered_workload_world_parts: usize = 8;
const ordered_workload_ui_parts: usize = 1;
const ordered_world_depth_buckets: usize = 16;
const ordered_ui_depths = [_]sprite_batch.UiDepth{ .background, .panel, .highlight, .text };

pub const group = suite.BenchmarkGroup{
    .name = "render-prep",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

const TextureSlot = struct {
    id: sprite_batch.TextureId,
    desc: resources.TextureDesc,
    alive: bool = true,
};

const TextureTable = struct {
    slots: []const TextureSlot,

    fn resolver(self: *const TextureTable) sprite_batch.TextureResolver {
        return .{
            .context = self,
            .resolve = resolve,
        };
    }

    fn resolve(context: *const anyopaque, id: sprite_batch.TextureId) ?resources.TextureDesc {
        const self: *const TextureTable = @ptrCast(@alignCast(context));
        if (!id.isValid()) return null;
        for (self.slots) |slot| {
            if (slot.alive and slot.id.matches(id.index, id.generation)) return slot.desc;
        }
        return null;
    }
};

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    const slots = [_]TextureSlot{
        .{ .id = textureId(0, 1), .desc = .{ .width = 64, .height = 64 } },
        .{ .id = textureId(1, 1), .desc = .{ .width = 128, .height = 32 } },
        .{ .id = textureId(2, 1), .desc = .{ .width = 32, .height = 128 } },
        .{ .id = textureId(3, 1), .desc = .{ .width = 16, .height = 16 } },
        .{ .id = textureId(4, 1), .desc = .{ .width = 8, .height = 8 }, .alive = false },
    };
    const table = TextureTable{ .slots = &slots };

    var batch = sprite_batch.SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(item_count, item_count * 6, item_count);
    var queue = RenderQueue.init(allocator);
    defer queue.deinit();
    try queue.ensureTotalCapacity(item_count);

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    if (suite.adaptiveTunerForCase(case, sprite_prep_range_alignment_items)) |tuner| {
        batch.adaptive_tuner = tuner;
    }

    const presentation = try suitePresentation();
    for (0..options.warmup_iterations) |_| {
        try queueToBatchOnce(&queue, &batch, item_count);
        _ = try runOnce(&batch, table.resolver(), presentation, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!batch.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            try queueToBatchOnce(&queue, &batch, item_count);
            _ = try runOnce(&batch, table.resolver(), presentation, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) batch.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var phase_accumulator = PhaseAccumulator{};
    var last_prep = sprite_batch.SpritePrepStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const measured = try runMeasuredOnce(&queue, item_count, &batch, table.resolver(), presentation, if (threads) |*thread_system| thread_system else null, case, io);
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

fn runOnce(
    batch: *sprite_batch.SpriteBatch,
    resolver: sprite_batch.TextureResolver,
    presentation: @import("../app/resolution.zig").Presentation,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) !sprite_batch.SpritePrepStats {
    if (!case.usesThreadSystem()) {
        return batch.buildAssumeCapacity(resolver, presentation, null, .{ .adaptive = false });
    }

    return batch.buildAssumeCapacity(resolver, presentation, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(sprite_prep_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, sprite_prep_range_alignment_items);
}

const MeasuredPrep = struct {
    stats: sprite_batch.SpritePrepStats,
    phases: suite.RenderPrepPhaseSummary,
};

const PhaseAccumulator = struct {
    queue_order_ns: u128 = 0,
    snapshot_ns: u128 = 0,
    vertex_emit_ns: u128 = 0,
    draw_group_ns: u128 = 0,

    fn record(self: *PhaseAccumulator, phases: suite.RenderPrepPhaseSummary) void {
        self.queue_order_ns += phases.queue_order_ns;
        self.snapshot_ns += phases.snapshot_ns;
        self.vertex_emit_ns += phases.vertex_emit_ns;
        self.draw_group_ns += phases.draw_group_ns;
    }

    fn finish(self: PhaseAccumulator, iterations: usize) suite.RenderPrepPhaseSummary {
        if (iterations == 0) return .{};
        const count: u128 = iterations;
        return .{
            .queue_order_ns = u128ToU64Saturated(self.queue_order_ns / count),
            .snapshot_ns = u128ToU64Saturated(self.snapshot_ns / count),
            .vertex_emit_ns = u128ToU64Saturated(self.vertex_emit_ns / count),
            .draw_group_ns = u128ToU64Saturated(self.draw_group_ns / count),
        };
    }
};

fn runMeasuredOnce(
    queue: *RenderQueue,
    item_count: usize,
    batch: *sprite_batch.SpriteBatch,
    resolver: sprite_batch.TextureResolver,
    presentation: @import("../app/resolution.zig").Presentation,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
    io: std.Io,
) !MeasuredPrep {
    const queue_start_ns = suite.nowNs(io);
    try queueToBatchOnce(queue, batch, item_count);
    const queue_end_ns = suite.nowNs(io);

    const snapshot_start_ns = suite.nowNs(io);
    _ = batch.snapshotCommandsAssumeCapacity(resolver);
    const snapshot_end_ns = suite.nowNs(io);

    const vertex_start_ns = suite.nowNs(io);
    const vertex_batch = emitVertices(batch, presentation, thread_system, case);
    const vertex_end_ns = suite.nowNs(io);

    const group_start_ns = suite.nowNs(io);
    batch.buildDrawGroupsAssumeCapacity();
    const stats = batch.finishPrepStats(vertex_batch);
    const group_end_ns = suite.nowNs(io);

    return .{
        .stats = stats,
        .phases = .{
            .queue_order_ns = suite.elapsedNs(queue_start_ns, queue_end_ns),
            .snapshot_ns = suite.elapsedNs(snapshot_start_ns, snapshot_end_ns),
            .vertex_emit_ns = suite.elapsedNs(vertex_start_ns, vertex_end_ns),
            .draw_group_ns = suite.elapsedNs(group_start_ns, group_end_ns),
        },
    };
}

fn emitVertices(
    batch: *sprite_batch.SpriteBatch,
    presentation: @import("../app/resolution.zig").Presentation,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    if (!case.usesThreadSystem()) {
        return batch.emitVerticesAssumeCapacity(presentation, null, .{ .adaptive = false });
    }

    return batch.emitVerticesAssumeCapacity(presentation, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn u128ToU64Saturated(value: u128) u64 {
    return if (value > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(value);
}

fn snapshotCommands(
    snapshot: *@TypeOf(sprite_batch.SpriteBatch.init(undefined).commands),
    allocator: std.mem.Allocator,
    commands: anytype,
) !void {
    snapshot.clearRetainingCapacity();
    try snapshot.ensureTotalCapacity(allocator, commands.len);
    snapshot.items.len = commands.len;
    @memcpy(snapshot.items, commands);
}

fn restoreCommands(batch: *sprite_batch.SpriteBatch, commands: anytype) void {
    std.debug.assert(batch.commands.capacity >= commands.len);
    batch.commands.clearRetainingCapacity();
    batch.commands.items.len = commands.len;
    @memcpy(batch.commands.items, commands);
    batch.last_order = if (commands.len == 0) null else commands[commands.len - 1].sprite.order;
}

fn fillCommands(batch: *sprite_batch.SpriteBatch, count: usize) !void {
    batch.setCamera(.{ .position = .{ .x = 320, .y = 180 }, .zoom = 1.25 });
    for (0..count) |index| {
        try batch.drawSprite(benchmarkSprite(index, orderedBenchmarkOrder(index, count)));
    }
}

fn queueToBatchOnce(queue: *RenderQueue, batch: *sprite_batch.SpriteBatch, count: usize) !void {
    queue.clearRetainingCapacity();
    batch.commands.clearRetainingCapacity();
    batch.last_order = null;
    for (0..count) |index| {
        try queue.addSprite(benchmarkSprite(index, queueBenchmarkOrder(index, count)));
    }
    queue.sortForSubmit();
    for (0..queue.recordCount()) |index| {
        if (queue.sortedSprite(index)) |sprite| {
            try batch.drawSprite(sprite);
        }
    }
}

fn benchmarkSprite(index: usize, order: sprite_batch.RenderOrder) sprite_batch.Sprite {
    const texture = if (index % 23 == 0)
        textureId(4, 1)
    else
        textureId(@intCast(index % 4), 1);
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
        .tint = tintFor(index),
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

fn queueBenchmarkOrder(index: usize, count: usize) sprite_batch.RenderOrder {
    if (count == 0) return orderedBenchmarkOrder(index, count);
    return orderedBenchmarkOrder(count - 1 - index, count);
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

fn tintFor(index: usize) config.Color {
    return .{
        .r = 0.45 + @as(f32, @floatFromInt(index % 5)) * 0.08,
        .g = 0.55 + @as(f32, @floatFromInt(index % 7)) * 0.05,
        .b = 0.65 + @as(f32, @floatFromInt(index % 3)) * 0.09,
        .a = 1,
    };
}

fn textureId(index: u32, generation: u32) sprite_batch.TextureId {
    return sprite_batch.TextureId.init(index, generation) catch unreachable;
}

fn suitePresentation() !@import("../app/resolution.zig").Presentation {
    return @import("../app/resolution.zig").computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1440 },
    );
}

test "render prep benchmark fixture creates requested commands" {
    var batch = sprite_batch.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.reserveStorage(128, 128 * 6, 128);
    try fillCommands(&batch, 128);
    try std.testing.expectEqual(@as(usize, 128), batch.commands.items.len);
}

test "render prep benchmark tiny serial case runs without display" {
    var options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    options.profile = .quick;
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 1_024);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
    try std.testing.expect(stats.output_count > 0);
    try std.testing.expect(stats.deferred_count > 0);
    try std.testing.expect(stats.render_prep_phases != null);
}

test "render prep benchmark feeds sorted queue stream into sprite batch" {
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.ensureTotalCapacity(128);
    var batch = sprite_batch.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.reserveStorage(128, 128 * 6, 128);

    try queueToBatchOnce(&queue, &batch, 128);

    try std.testing.expectEqual(@as(usize, 128), batch.commands.items.len);
    for (batch.commands.items[1..], 1..) |command, index| {
        try std.testing.expect(batch.commands.items[index - 1].sprite.order.lessOrEqual(command.sprite.order));
    }
}

test "render prep benchmark preserves ordered command stream before prep" {
    const allocator = std.testing.allocator;
    const slots = [_]TextureSlot{
        .{ .id = textureId(0, 1), .desc = .{ .width = 64, .height = 64 } },
        .{ .id = textureId(1, 1), .desc = .{ .width = 128, .height = 32 } },
        .{ .id = textureId(2, 1), .desc = .{ .width = 32, .height = 128 } },
        .{ .id = textureId(3, 1), .desc = .{ .width = 16, .height = 16 } },
        .{ .id = textureId(4, 1), .desc = .{ .width = 8, .height = 8 }, .alive = false },
    };
    const table = TextureTable{ .slots = &slots };
    var batch = sprite_batch.SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(128, 128 * 6, 128);
    try fillCommands(&batch, 128);

    var original_commands: @TypeOf(batch.commands) = .empty;
    defer original_commands.deinit(allocator);
    try snapshotCommands(&original_commands, allocator, batch.commands.items);

    _ = batch.buildAssumeCapacity(table.resolver(), try suitePresentation(), null, .{ .adaptive = false });
    try std.testing.expect(commandsEqual(original_commands.items, batch.commands.items));

    batch.commands.items[0] = batch.commands.items[1];
    restoreCommands(&batch, original_commands.items);
    try std.testing.expect(commandsEqual(original_commands.items, batch.commands.items));
}

test "render prep benchmark fixed cases use explicit range controls" {
    try std.testing.expectEqual(
        suite.alignItemCount(suite.default_items_per_range, sprite_prep_range_alignment_items),
        benchmarkItemsPerRange(suite.default_cases[3]).?,
    );
    try std.testing.expectEqual(suite.default_cases[4].itemsPerRange(sprite_prep_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[4]).?);
    try std.testing.expectEqual(suite.default_cases[5].itemsPerRange(sprite_prep_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[5]).?);
    try std.testing.expectEqual(@as(?usize, null), benchmarkItemsPerRange(suite.default_cases[6]));
    try std.testing.expectEqual(@as(?usize, null), benchmarkItemsPerRange(suite.default_cases[7]));
}

test "render prep benchmark profiles sweep multiple command counts" {
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.quick), defaultItemCounts(.quick));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.standard), defaultItemCounts(.standard));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.stress), defaultItemCounts(.stress));
}

fn commandsEqual(lhs: anytype, rhs: anytype) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.sprite.order.domain != right.sprite.order.domain) return false;
        if (left.sprite.order.depth != right.sprite.order.depth) return false;
        if (left.sprite.texture.index != right.sprite.texture.index) return false;
        if (left.sprite.texture.generation != right.sprite.texture.generation) return false;
    }
    return true;
}
