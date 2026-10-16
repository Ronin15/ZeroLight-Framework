// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Collision detect throughput: `collision` (a dense 7 px grid of 9 px bodies),
//! `collision-sparse` (isolated pairs), and the broadphase shape groups on the dense grid at
//! a fixed population:
//! - `collision-tall`: the grid's aspect (rows over columns) grows.
//! - `collision-stacked`: a 32 x 32 grid copied onto more levels.
//! Pass shape (both shape groups): time per body flat in aspect and in levels. The counted
//! candidate pairs are the same-level overlapping pairs, flat by construction; the sweep's
//! visits to bodies it then rejects show only in time. Asserts check the contact count
//! only: the grid's analytic same-level overlap count.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const CollisionStats = @import("../game/systems/collision.zig").CollisionStats;
const CollisionSystem = @import("../game/systems/collision.zig").CollisionSystem;
const collision_range_alignment_items = @import("../game/systems/collision.zig").collision_range_alignment_items;
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "collision",
    .item_label = "collision bodies",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
    .write_workload = writeCollisionWorkload,
};

pub const sparse_group = suite.BenchmarkGroup{
    .name = "collision-sparse",
    .item_label = "collision bodies",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runSparseCase,
    .write_workload = writeCollisionWorkload,
};

pub const tall_group = suite.BenchmarkGroup{
    .name = "collision-tall",
    .item_label = ShapeCode.label,
    .defaultItemCounts = tallItemCounts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

pub const stacked_group = suite.BenchmarkGroup{
    .name = "collision-stacked",
    .item_label = ShapeCode.label,
    .defaultItemCounts = stackedItemCounts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

const FixtureMode = enum {
    dense,
    sparse,
};

// The dense grid's body size and pitch: each body overlaps its eight neighbours.
const dense_body_size: f32 = 9;
const dense_pitch: f32 = 7;

const ShapeVariant = enum(u8) { tall, stacked };
// `axis` is the grid's rows over columns (tall) or its level count (stacked).
const ShapeCode = suite.ItemCode(struct { variant: ShapeVariant, axis: u32 }, &.{6});

// The tall group's fixed population, and the stacked group's grid side per level: the
// sweep's growth in column height and in levels shows at these sizes.
const shape_bodies: usize = 4_096;
const stacked_side: usize = 32;

const tall_item_counts = [_]usize{
    ShapeCode.of(.{ .variant = .tall, .axis = 1 }),
    ShapeCode.of(.{ .variant = .tall, .axis = 16 }),
    ShapeCode.of(.{ .variant = .tall, .axis = 256 }),
};

const stacked_item_counts = [_]usize{
    ShapeCode.of(.{ .variant = .stacked, .axis = 1 }),
    ShapeCode.of(.{ .variant = .stacked, .axis = 4 }),
    ShapeCode.of(.{ .variant = .stacked, .axis = 16 }),
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

fn tallItemCounts(_: suite.Profile) []const usize {
    return &tall_item_counts;
}

fn stackedItemCounts(_: suite.Profile) []const usize {
    return &stacked_item_counts;
}

// A grid of `columns` x `rows` dense bodies on each of `levels` levels, the same xy on
// every level; levels are set only when `stamp_levels`.
const GridShape = struct {
    columns: usize,
    rows: usize,
    levels: u16,
    stamp_levels: bool,

    fn bodies(self: GridShape) usize {
        return self.columns * self.rows * self.levels;
    }

    // Same-level overlapping pairs: horizontal, vertical, and both diagonals per level.
    fn contacts(self: GridShape) usize {
        const c = self.columns;
        const r = self.rows;
        return self.levels * ((c - 1) * r + c * (r - 1) + 2 * (c - 1) * (r - 1));
    }
};

fn gridShapeFor(code: usize) !GridShape {
    const fields = try ShapeCode.decode(code);
    switch (fields.variant) {
        .tall => {
            std.debug.assert(fields.axis > 0 and shape_bodies % fields.axis == 0);
            const columns: usize = std.math.sqrt(shape_bodies / fields.axis);
            std.debug.assert(columns * columns * fields.axis == shape_bodies);
            return .{ .columns = columns, .rows = shape_bodies / columns, .levels = 1, .stamp_levels = false };
        },
        .stacked => return .{ .columns = stacked_side, .rows = stacked_side, .levels = @intCast(fields.axis), .stamp_levels = true },
    }
}

fn createGridFixture(allocator: std.mem.Allocator, shape: GridShape) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    for (0..shape.levels) |level| {
        for (0..shape.rows) |row| {
            for (0..shape.columns) |column| {
                const entity = try data.createEntity();
                const position = math.Vec2{
                    .x = @as(f32, @floatFromInt(column)) * dense_pitch,
                    .y = @as(f32, @floatFromInt(row)) * dense_pitch,
                };
                try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
                try data.setCollisionBounds(entity, .{ .size = .{ .x = dense_body_size, .y = dense_body_size } });
                if (shape.stamp_levels) try data.setWorldLevel(entity, @intCast(level));
            }
        }
    }
    return data;
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    return createFixtureWithMode(allocator, count, .dense);
}

fn createFixtureWithMode(allocator: std.mem.Allocator, count: usize, mode: FixtureMode) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const columns: usize = 512;
    for (0..count) |index| {
        const entity = try data.createEntity();
        const position = benchmarkPosition(index, columns, mode);
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 0,
        });
        try data.setCollisionBounds(entity, .{
            .size = .{ .x = dense_body_size, .y = dense_body_size },
        });
    }

    return data;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .dense);
}

pub fn runSparseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .sparse);
}

fn runShapeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const shape = try gridShapeFor(item_count);
    var data = try createGridFixture(allocator, shape);
    defer data.deinit();
    var stats = try measureCase(allocator, io, options, case, shape.bodies(), &data);
    std.debug.assert(stats.output_count == shape.contacts());
    // The header names the config; throughput stays per body.
    stats.item_count = item_count;
    return stats;
}

fn runCaseWithMode(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, mode: FixtureMode) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var data = try createFixtureWithMode(allocator, item_count, mode);
    defer data.deinit();
    return measureCase(allocator, io, options, case, item_count, &data);
}

fn measureCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, data: *const DataSystem) !suite.RunStats {
    var system = CollisionSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, collision_range_alignment_items)) |tuner| {
        system.broadphase_tuner = tuner;
        system.narrowphase_tuner = suite.adaptiveTunerForCase(case, collision_range_alignment_items).?;
    }
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, data, &contacts, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!system.broadphase_tuner.isSettled() or !system.narrowphase_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, data, &contacts, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const broadphase_settled_before_measurement = if (case.adaptive) system.broadphase_tuner.isSettled() else false;
    const narrowphase_settled_before_measurement = if (case.adaptive) system.narrowphase_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_collision_stats = CollisionStats{};
    var gather_total: u128 = 0;
    var sort_total: u128 = 0;
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_collision_stats = try runOnce(&system, data, &contacts, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_collision_stats.broadphase_batch);
        gather_total += last_collision_stats.gather_ns;
        sort_total += last_collision_stats.sort_ns;
        main_total += elapsed_ns -| offMainNs(last_collision_stats.broadphase_batch) -| offMainNs(last_collision_stats.narrowphase_batch);
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) {
        stats.collision_phases = .{
            .gather_ns = @intCast(gather_total / stats.iterations),
            .sort_ns = @intCast(sort_total / stats.iterations),
        };
        stats.main_ns = @intCast(main_total / stats.iterations);
    }
    stats.sample_count = item_count;
    stats.candidate_pairs = last_collision_stats.candidate_pair_count;
    stats.output_count = last_collision_stats.contact_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_collision_stats.narrowphase_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.broadphase_tuner.report(), broadphase_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.narrowphase_tuner.report(), narrowphase_settled_before_measurement);
    }
    return stats;
}

fn runOnce(
    system: *CollisionSystem,
    data: *const DataSystem,
    contacts: *RangeOutputStream(CollisionContact),
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) !CollisionStats {
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(data, contacts);
    }

    return try system.update(data, contacts, thread_system.?, .{
        .items_per_range = case.stageItemsPerRange(collision_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkPosition(index: usize, columns: usize, mode: FixtureMode) math.Vec2 {
    return switch (mode) {
        .dense => .{
            .x = @as(f32, @floatFromInt(index % columns)) * dense_pitch,
            .y = @as(f32, @floatFromInt(index / columns)) * dense_pitch,
        },
        .sparse => sparseBenchmarkPosition(index, columns),
    };
}

fn sparseBenchmarkPosition(index: usize, columns: usize) math.Vec2 {
    const sparse_group_index = index / 20;
    const slot = index % 20;
    const base_index = sparse_group_index * 20 + if (slot == 1) @as(usize, 0) else slot;
    const offset_x: usize = if (slot == 1) 6 else 0;
    return .{
        .x = @floatFromInt((base_index % columns) * 32 + offset_x),
        .y = @floatFromInt((base_index / columns) * 32),
    };
}

fn writeCollisionWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidate_pairs={} contacts={}", .{ stats.candidate_pairs, stats.output_count });
    // `sample_count` holds the body count.
    if (stats.sample_count != 0) try writer.print(" per_body={f}", .{suite.formatDuration(stats.mean_ns / stats.sample_count)});
    if (view == .summary) return;
    if (stats.collision_phases) |phases| {
        try suite.writeShare(writer, "gather", phases.gather_ns, stats.mean_ns);
        try suite.writeShare(writer, "sort", phases.sort_ns, stats.mean_ns);
    }
    if (stats.main_ns) |main_ns| try suite.writeShare(writer, "main", main_ns, stats.mean_ns);
    const narrow = stats.secondary_batch orelse return;
    try writer.writeAll(" narrow=");
    try suite.writeStageShape(writer, narrow);
    if (narrow.ran_inline or narrow.active_worker_threads == 0) {
        if (stats.secondary_work_tuning) |summary| try writer.print(" tuned={s}", .{if (summary.has_threaded_profile) "threaded" else "none"});
    }
}
