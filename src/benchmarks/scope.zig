// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `scope-cognition`: the think set alone (`compactCognition`) over a halo index built once
//!   untimed: `spread` over N entities on 16 x-chunks whose levels (`index % 5`) give a
//!   mixed-tier population (cognition, locomotion, kinematic, dormant), `dense_chunk` with
//!   every agent in one chunk (one index record), whose ranges split the chunk. Pass shape: linear in the H indexed
//!   rows in both layouts, `spread` on workers at the largest size on the tuned case, the
//!   main thread's share (the window merges) flat per row. Asserts check `spread`'s tuned case
//!   off main at the largest size, one record for `dense_chunk`, every case's think set equal
//!   to the serial pass's, and every indexed row counted once, thinking or skipped. Item
//!   code `layout * 10^6 + agents` (layout 0 `spread`, 1 `dense_chunk`). Prints `indexed=`
//!   (H) and `thinking=`; `--details` adds `main=` with `main_per_item=` (per indexed row).

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const IndexGeometry = @import("../game/systems/spatial_index.zig").IndexGeometry;
const SpatialIndexView = @import("../game/systems/spatial_index.zig").SpatialIndexView;
const SpatialIndexSystem = @import("../game/systems/spatial_index.zig").SpatialIndexSystem;
const CognitionResult = @import("../game/systems/simulation_scope.zig").CognitionResult;
const SimulationScopeSystem = @import("../game/systems/simulation_scope.zig").SimulationScopeSystem;
const ScopeConfig = @import("../game/systems/simulation_scope.zig").ScopeConfig;
const scope_range_alignment_items = @import("../game/systems/simulation_scope.zig").scope_range_alignment_items;
const ActiveRegion = @import("../game/simulation_scope.zig").ActiveRegion;
const tierForChunkDistance = @import("../game/simulation_scope.zig").tierForChunkDistance;
const cognition_halo_chunks = @import("../game/simulation_scope.zig").cognition_halo_chunks;
const cognition_stagger_n = @import("../game/simulation_scope.zig").cognition_stagger_n;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

// Grid: 32px tiles, 8-tile (256px) chunks, 16 chunks across. Entities spread over
// the 16 x-chunks and are banded into all four LOD tiers by distance from the
// visible window (see visibleRegion); the cognition subset is then stagger-gated.
const tile_size: f32 = 32;
const chunk_size_tiles: u16 = 8;
const grid_chunks: u16 = 16;
const grid_tiles: u16 = grid_chunks * chunk_size_tiles;
const chunk_px: f32 = tile_size * @as(f32, @floatFromInt(chunk_size_tiles));
// The grid's five populated levels (`level = index % 5`).
const index_geometry = IndexGeometry{ .tile_size = tile_size, .chunk_size_tiles = chunk_size_tiles, .chunks_x = grid_chunks, .chunks_y = grid_chunks, .level_count = 5 };

// Camera-visible chunk window: left two x-chunks, full height. The LOD bands fan
// out from here, so over the 16 x-chunks the population lands roughly: cognition
// x0-5, locomotion x6-9, kinematic x10-13, dormant x14-15 — a real four-tier mix.
fn visibleRegion() ActiveRegion {
    return .{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 2, .y = grid_chunks } };
}

// Cognition halo = visible window expanded by cognition_halo_chunks; the AI gather
// gates on it. Matches the cognition band so cognition-tier entities are in-halo.
fn cognitionHaloRegion() ActiveRegion {
    const v = visibleRegion();
    const h: i32 = cognition_halo_chunks;
    return .{
        .min = .{ .x = v.min.x - h, .y = v.min.y - h },
        .max_exclusive = .{ .x = v.max_exclusive.x + h, .y = v.max_exclusive.y + h },
    };
}

pub const cognition_group = suite.BenchmarkGroup{
    .name = "scope-cognition",
    .item_label = CognitionCode.label,
    .item_counts = &cognition_item_counts,
    .runCase = runCognitionCase,
    .write_workload = writeCognitionWorkload,
};

// `spread` banded over the x-chunks; `dense_chunk` puts every agent in chunk (0, 0).
const CognitionLayout = enum(u8) { spread, dense_chunk };
const CognitionCode = suite.ItemCode(struct { layout: CognitionLayout, agents: u32 }, &.{6});

// Each layout at the event-scale sizes.
const cognition_item_counts = cognitionCodes(&suite.event_scale_counts);

fn cognitionCodes(comptime counts: []const usize) [2 * counts.len]usize {
    var codes: [2 * counts.len]usize = undefined;
    for (counts, 0..) |count, index| {
        codes[index] = CognitionCode.of(.{ .layout = .spread, .agents = count });
        codes[counts.len + index] = CognitionCode.of(.{ .layout = .dense_chunk, .agents = count });
    }
    return codes;
}

// `count` AI agents spread over the 16 x-chunks, rows stepping in y, each tiered by its chunk
// and level (`index % 5`) from the visible window.
fn createSpreadFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    for (0..count) |index| {
        const entity = try data.createEntity();
        const chunk_col: f32 = @floatFromInt(index % grid_chunks);
        const row: f32 = @floatFromInt(index / grid_chunks);
        const position = math.Vec2{
            .x = chunk_col * chunk_px + 8.0 + @mod(row, 200.0),
            .y = 32.0 + @mod(row * 13.0, @as(f32, grid_tiles) * tile_size - 64.0),
        };
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
        try data.setAiAgent(entity, .{
            .active_behavior = if (index % 3 == 0) .wander else .pursue,
            .wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29)),
            .gain_pursue = if (index % 3 == 0) 0.0 else 0.5,
        });
        // The cube LOD distance weights one level as a full band, so levels 0–4 fan the
        // population into all four tiers regardless of x/y, and the cube excludes the
        // off-level entities from cognition.
        const chunk_x: i32 = @intCast(index % grid_chunks);
        const level: u16 = @intCast(index % 5);
        const tier = tierForChunkDistance(visibleRegion().lodDistance(.{ .x = chunk_x, .y = 0 }, level));
        try data.setSimulationMetadata(entity, .{
            .tier = tier,
            .chunk = .{ .x = chunk_x, .y = 0 },
            .level = level,
            .stagger_phase = @intCast(index % cognition_stagger_n),
        });
    }
    return data;
}

// Every agent a cognition-tier body in chunk (0, 0) on level 0, over its 8x8 index cells.
fn createDenseChunkFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const side: usize = @intFromFloat(chunk_px - 16);
    for (0..count) |index| {
        const entity = try data.createEntity();
        const position = math.Vec2{
            .x = 8.0 + @as(f32, @floatFromInt(index % side)),
            .y = 8.0 + @as(f32, @floatFromInt(index / side % side)),
        };
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
        try data.setSimulationMetadata(entity, .{ .tier = .cognition, .stagger_phase = @intCast(index % cognition_stagger_n) });
    }
    return data;
}

fn runCognitionCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    const fields = try CognitionCode.decode(item_count);
    var data = switch (fields.layout) {
        .spread => try createSpreadFixture(allocator, fields.agents),
        .dense_chunk => try createDenseChunkFixture(allocator, fields.agents),
    };
    defer data.deinit();
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    try scope.reserve(fields.agents);
    if (suite.adaptiveTunerForCase(case, scope_range_alignment_items)) |tuner| scope.cognition_tuner = tuner;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    // Positions never change, so the halo's index is built once, untimed and inline.
    var setup_threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 0 });
    defer setup_threads.deinit();
    var spatial_index = SpatialIndexSystem.init(allocator);
    defer spatial_index.deinit();
    const halo = (try scope.gatherAiPopulations(&data, cognitionHaloRegion(), &setup_threads, .{})).halo;
    _ = try spatial_index.build(&data, .{ .entities = data.aiAgentSliceConst().entities, .rows = halo }, index_geometry, &setup_threads, .{});
    const view = spatial_index.view();
    const indexed = view.entryCount();
    if (fields.layout == .dense_chunk) std.debug.assert(view.recordCount() == 1 and indexed == fields.agents);
    // The inline pass's think set, untimed: every case must match it.
    const serial_think = blk: {
        var reference = SimulationScopeSystem.init(allocator);
        defer reference.deinit();
        break :blk try allocator.dupe(u32, (try reference.compactCognition(&view, 0, true, &setup_threads, .{})).cognition);
    };
    defer allocator.free(serial_think);

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(scope.cognition_tuner.phase == .settled)) _ = try runCognitionOnce(&scope, &view, thread_ptr, case);
    const settled_before_measurement = if (case.adaptive) (scope.cognition_tuner.phase == .settled) else false;

    const counts = &suite.event_scale_counts;
    // `dense_chunk` runs inline where its tuner measures that cheaper.
    const expect_off_main = fields.layout == .spread and case.adaptive and case.adaptive_range_mode == .tuned and fields.agents == counts[counts.len - 1];
    var accumulator = suite.StatsAccumulator.init(item_count);
    var think_rows: usize = 0;
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const result = try runCognitionOnce(&scope, &view, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        if (expect_off_main and result.batch.ran_inline) return error.CognitionRanInline;
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, result.batch);
        main_total += elapsed_ns -| offMainNs(result.batch);
        std.debug.assert(std.mem.eql(u32, serial_think, result.cognition));
        think_rows = result.cognition.len;
        // Every indexed row thinks or is skipped, once.
        std.debug.assert(think_rows + scope.stagger_skips == indexed);
    }

    var stats = accumulator.finish();
    stats.items_per_second = suite.itemsPerSecond(fields.agents, stats.mean_ns);
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.candidate_pairs = indexed;
    stats.output_count = think_rows;
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&scope.cognition_tuner), settled_before_measurement);
    return stats;
}

fn runCognitionOnce(scope: *SimulationScopeSystem, view: *const SpatialIndexView, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !CognitionResult {
    return scope.compactCognition(view, 0, true, thread_system, scopeConfig(case));
}

// `candidate_pairs` holds the indexed rows and `output_count` the rows that think; `main` is
// the time outside the pass's worker dispatch.
fn writeCognitionWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("indexed={} thinking={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, stats.candidate_pairs);
}

// Scope-pass threading config for a case: adaptive cases let the tuner train (null range);
// fixed cases pin the case's range size.
fn scopeConfig(case: suite.BenchmarkCase) ScopeConfig {
    return .{
        .items_per_range = case.stageItemsPerRange(scope_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    };
}
