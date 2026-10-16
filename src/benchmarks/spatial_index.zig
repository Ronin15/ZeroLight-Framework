// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared spatial index build throughput: times only
//! `SpatialIndexSystem.build`/`buildSerial` in isolation, separately from the
//! `ai` group (which excludes the build from its own timed window). The primary
//! batch is the bucket stage, the secondary the sort stage; `main` is the time
//! outside both stages' worker dispatches. Slots and positions are shuffled, so
//! keys reach the sort in store order, not key order, as the halo's do. Pass
//! shape: H log(H/B) in indexed entities, with the build off main on the tuned
//! case; the asserts check both stages ran on workers at the largest size.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const IndexPopulation = @import("../game/systems/spatial_index.zig").IndexPopulation;
const SpatialIndexStats = @import("../game/systems/spatial_index.zig").SpatialIndexStats;
const SpatialIndexSystem = @import("../game/systems/spatial_index.zig").SpatialIndexSystem;
const spatial_index_range_alignment_items = @import("../game/systems/spatial_index.zig").spatial_index_range_alignment_items;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "spatial_index",
    .item_label = "indexed entities",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
    .write_workload = writeIndexWorkload,
};

const Fixture = struct {
    data: DataSystem,

    fn deinit(self: *Fixture) void {
        self.data.deinit();
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    // Grid point `grid[index]` for slot `index`: a fixed-seed shuffle.
    const grid = try allocator.alloc(usize, count);
    defer allocator.free(grid);
    for (grid, 0..) |*point, index| point.* = index;
    var prng = std.Random.DefaultPrng.init(0x5107_0dde);
    prng.random().shuffle(usize, grid);

    for (0..count) |index| {
        const entity = try data.createEntity();
        const position = math.Vec2{
            .x = @as(f32, @floatFromInt(grid[index] % 128)) * 11.0,
            .y = @as(f32, @floatFromInt(grid[index] / 128)) * 9.0,
        };
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 35.0 + @as(f32, @floatFromInt(index % 17)),
        });
        try data.setAiAgent(entity, .{
            .active_behavior = if (index % 3 == 0) .wander else .pursue,
            .wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29)),
            .gain_pursue = if (index % 3 == 0) 0.0 else 0.4 + @as(f32, @floatFromInt(index % 7)) * 0.1,
        });
    }

    return .{ .data = data };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = SpatialIndexSystem.init(allocator);
    defer system.deinit();
    try system.reserve(item_count);
    if (suite.adaptiveTunerForCase(case, spatial_index_range_alignment_items)) |tuner| {
        system.bucket_tuner = tuner;
        system.sort_tuner = suite.adaptiveTunerForCase(case, spatial_index_range_alignment_items).?;
    }

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!system.bucket_tuner.isSettled() or !system.sort_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const bucket_settled_before_measurement = if (case.adaptive) system.bucket_tuner.isSettled() else false;
    const sort_settled_before_measurement = if (case.adaptive) system.sort_tuner.isSettled() else false;

    const counts = defaultItemCounts(options.profile);
    const expect_off_main = case.adaptive and case.adaptive_range_mode == .tuned and item_count == counts[counts.len - 1];
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = SpatialIndexStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        std.debug.assert(!expect_off_main or (!last_stats.bucket_batch.ran_inline and !last_stats.sort_batch.ran_inline));
        accumulator.record(elapsed_ns, last_stats.bucket_batch);
        main_total += elapsed_ns -| (offMainNs(last_stats.bucket_batch) + offMainNs(last_stats.sort_batch));
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.output_count = last_stats.entity_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_stats.sort_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.bucket_tuner.report(), bucket_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.sort_tuner.report(), sort_settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *SpatialIndexSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !SpatialIndexStats {
    const population = IndexPopulation{ .entities = fixture.data.aiAgentSliceConst().entities };
    if (!case.usesThreadSystem()) {
        return try system.buildSerial(&fixture.data, population, .{});
    }

    return try system.build(&fixture.data, population, thread_system.?, .{
        .items_per_range = case.stageItemsPerRange(spatial_index_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn writeIndexWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("entities={}", .{stats.output_count});
    if (view == .summary) return;
    if (stats.main_ns) |main_ns| try suite.writeShare(writer, "main", main_ns, stats.mean_ns);
    const sort = stats.secondary_batch orelse return;
    try writer.writeAll(" sort=");
    try suite.writeStageShape(writer, sort);
}
