// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const builtin = @import("builtin");
const std = @import("std");
const data = @import("../data_system.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;

/// Chunk grid parameters + destination columns for in-pass chunk derivation.
/// Movement already streams each integrated body's new position, so it writes the
/// position-derived chunk in the same pass — exact every step at any speed, with
/// no separate O(N) recompute. The formula mirrors `WorldSystem.chunkCoordForWorldPos`;
/// movement takes the grid as plain scalars rather than importing the world.
pub const ChunkGridParams = struct {
    chunk_x: data.HotI32Slice,
    chunk_y: data.HotI32Slice,
    tile_size: f32,
    chunk_size_tiles: u16,
    width: u16,
    height: u16,
};

pub const MovementConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
    /// When non-null, only these dense movement indices integrate this step (the
    /// scope system excludes dormant entities). Null = the full contiguous SoA
    /// range, which keeps the warm SIMD path. The indexed path is taken only when
    /// dormant entities actually exist, so its per-row scalar cost is bounded.
    scope_dense_indices: ?[]const u32 = null,
    /// When set, movement derives each integrated body's chunk from its new
    /// position into these columns. Null skips chunk maintenance (e.g. isolated
    /// movement benchmarks/tests with no scope grid).
    chunk_grid: ?ChunkGridParams = null,
};

pub const MovementStats = struct {
    body_count: usize = 0,
    batch: BatchStats = .{},
};

pub const MovementSystem = struct {
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init() MovementSystem {
        return .{
            .adaptive_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn update(
        self: *MovementSystem,
        slice: *data.MovementBodySlice,
        thread_system: *ThreadSystem,
        delta_seconds: f32,
        config: MovementConfig,
    ) MovementStats {
        var system_config = config;
        if (system_config.adaptive and system_config.adaptive_tuner == null and system_config.items_per_range == null) {
            system_config.adaptive_tuner = &self.adaptive_tuner;
        }
        return updateMovementBodies(slice, thread_system, delta_seconds, system_config);
    }

    pub fn syncPreviousPositions(_: *MovementSystem, slice: *data.MovementBodySlice) void {
        syncPreviousPositionsImpl(slice);
    }
};

fn updateMovementBodies(
    slice: *data.MovementBodySlice,
    thread_system: *ThreadSystem,
    delta_seconds: f32,
    config: MovementConfig,
) MovementStats {
    if (slice.entities.len == 0) return .{};

    if (config.scope_dense_indices) |indices| {
        // Scoped path: integrate only the selected rows. Index ranges break the
        // contiguous SIMD load, so each row integrates scalar; still threaded so a
        // large active subset fans out. Range alignment is irrelevant here.
        if (indices.len == 0) return .{ .body_count = 0 };
        var indexed = MovementIndexedJobContext{
            .slice = slice.*,
            .indices = indices,
            .delta_seconds = delta_seconds,
            .chunk_grid = config.chunk_grid,
        };
        const batch = thread_system.parallelForWithOptions(indices.len, &indexed, movementIndexedJob, .{
            .items_per_range = config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
            .adaptive_tuner = config.adaptive_tuner,
        });
        return .{ .body_count = indices.len, .batch = batch };
    }

    var context = MovementJobContext{
        .slice = slice.*,
        .delta_seconds = delta_seconds,
        .chunk_grid = config.chunk_grid,
    };
    const batch = thread_system.parallelForWithOptions(slice.entities.len, &context, movementJob, .{
        .items_per_range = config.items_per_range,
        .max_worker_threads = config.max_worker_threads,
        .range_alignment_items = data.movement_range_alignment_items,
        .adaptive = config.adaptive,
        .adaptive_tuner = config.adaptive_tuner,
    });
    return .{
        .body_count = slice.entities.len,
        .batch = batch,
    };
}

pub fn updateSerial(slice: *data.MovementBodySlice, delta_seconds: f32) void {
    updateSerialScoped(slice, delta_seconds, null, null);
}

/// Single-threaded integration with the same scope/chunk dispatch as `update`:
/// a non-null `scope_dense_indices` integrates only the selected rows (indexed
/// SIMD-gather path), otherwise the full contiguous range. Lets the serial
/// benchmark case measure the same scoped workload as the threaded cases.
pub fn updateSerialScoped(
    slice: *data.MovementBodySlice,
    delta_seconds: f32,
    scope_dense_indices: ?[]const u32,
    chunk_grid: ?ChunkGridParams,
) void {
    if (scope_dense_indices) |indices| {
        processIndexedRange(slice, indices, .{ .index = 0, .start = 0, .end = indices.len }, delta_seconds, chunk_grid);
    } else {
        processRange(slice, .{ .start = 0, .end = slice.entities.len }, delta_seconds, chunk_grid);
    }
}

pub fn syncPreviousPositions(slice: *data.MovementBodySlice) void {
    syncPreviousPositionsImpl(slice);
}

fn syncPreviousPositionsImpl(slice: *data.MovementBodySlice) void {
    for (0..slice.entities.len) |index| {
        slice.previous_x[index] = slice.position_x[index];
        slice.previous_y[index] = slice.position_y[index];
        slice.previous_z[index] = slice.position_z[index];
    }
}

fn movementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *MovementJobContext = @ptrCast(@alignCast(context));
    processRange(&job.slice, range, job.delta_seconds, job.chunk_grid);
}

/// Position → chunk for one row, written into the scope chunk columns. Mirrors
/// `WorldSystem.chunkCoordForWorldPos` (clamp to world bounds, then cell/chunk
/// division). Kept inline here so movement derives chunk in-pass without importing
/// the world; the formula is stable. Worker ranges own disjoint rows, so the write
/// is range-disjoint exactly like the position write beside it.
inline fn writeChunkRow(grid: ChunkGridParams, index: usize, x: f32, y: f32) void {
    const tx = math.worldPosToCell(x, grid.tile_size, grid.width);
    const ty = math.worldPosToCell(y, grid.tile_size, grid.height);
    grid.chunk_x[index] = @intCast(tx / grid.chunk_size_tiles);
    grid.chunk_y[index] = @intCast(ty / grid.chunk_size_tiles);
}

fn processRange(slice: *data.MovementBodySlice, range: ParallelRange, delta_seconds: f32, chunk_grid: ?ChunkGridParams) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= slice.entities.len);

    var index = range.start;
    const dt = simd.splatFloat4(delta_seconds);
    while (index + simd.lane_count <= range.end) : (index += simd.lane_count) {
        const position_x = simd.loadFloat4(slice.position_x[index..]);
        const position_y = simd.loadFloat4(slice.position_y[index..]);
        const velocity_x = simd.loadFloat4(slice.velocity_x[index..]);
        const velocity_y = simd.loadFloat4(slice.velocity_y[index..]);
        const next_x = simd.addFloat4(position_x, simd.mulFloat4(velocity_x, dt));
        const next_y = simd.addFloat4(position_y, simd.mulFloat4(velocity_y, dt));

        simd.storeFloat4Slice(slice.previous_x[index..], position_x);
        simd.storeFloat4Slice(slice.previous_y[index..], position_y);
        for (index..index + simd.lane_count) |z_index| {
            slice.previous_z[z_index] = slice.position_z[z_index];
        }
        simd.storeFloat4Slice(slice.position_x[index..], next_x);
        simd.storeFloat4Slice(slice.position_y[index..], next_y);
        // Derive chunk from the just-computed new positions (reuse the vectors).
        if (chunk_grid) |grid| {
            const nx = simd.toFloatArray(next_x);
            const ny = simd.toFloatArray(next_y);
            inline for (0..simd.lane_count) |lane| {
                writeChunkRow(grid, index + lane, nx[lane], ny[lane]);
            }
        }
    }

    while (index < range.end) : (index += 1) {
        const position_x = slice.position_x[index];
        const position_y = slice.position_y[index];
        slice.previous_x[index] = position_x;
        slice.previous_y[index] = position_y;
        slice.previous_z[index] = slice.position_z[index];
        const next_x = position_x + slice.velocity_x[index] * delta_seconds;
        const next_y = position_y + slice.velocity_y[index] * delta_seconds;
        slice.position_x[index] = next_x;
        slice.position_y[index] = next_y;
        if (chunk_grid) |grid| writeChunkRow(grid, index, next_x, next_y);
    }
}

fn processRangeScalar(slice: *data.MovementBodySlice, range: ParallelRange, delta_seconds: f32) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= slice.entities.len);

    for (range.start..range.end) |index| {
        const position_x = slice.position_x[index];
        const position_y = slice.position_y[index];
        slice.previous_x[index] = position_x;
        slice.previous_y[index] = position_y;
        slice.previous_z[index] = slice.position_z[index];
        slice.position_x[index] = position_x + slice.velocity_x[index] * delta_seconds;
        slice.position_y[index] = position_y + slice.velocity_y[index] * delta_seconds;
    }
}

const MovementJobContext = struct {
    slice: data.MovementBodySlice,
    delta_seconds: f32,
    chunk_grid: ?ChunkGridParams,
};

fn movementIndexedJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *MovementIndexedJobContext = @ptrCast(@alignCast(context));
    processIndexedRange(&job.slice, job.indices, range, job.delta_seconds, job.chunk_grid);
}

/// Integrates only the rows named by `indices[range.start..range.end]`. The indices
/// are not contiguous, so this gathers four scattered rows into lanes with
/// `simd.gatherFloat4`, integrates them as `Float4`, and scatters the results back —
/// the SIMD-gather path the plan specifies. A scalar tail covers the remainder.
/// The scope gather emits each dense index at most once, so the four lane indices in
/// a block are distinct (required by `scatterFloat4`) and worker ranges are disjoint.
fn processIndexedRange(slice: *data.MovementBodySlice, indices: []const u32, range: ParallelRange, delta_seconds: f32, chunk_grid: ?ChunkGridParams) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= indices.len);

    const dt = simd.splatFloat4(delta_seconds);
    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{
            indices[k], indices[k + 1], indices[k + 2], indices[k + 3],
        };
        const position_x = simd.gatherFloat4(slice.position_x, lanes);
        const position_y = simd.gatherFloat4(slice.position_y, lanes);
        const velocity_x = simd.gatherFloat4(slice.velocity_x, lanes);
        const velocity_y = simd.gatherFloat4(slice.velocity_y, lanes);
        const next_x = simd.addFloat4(position_x, simd.mulFloat4(velocity_x, dt));
        const next_y = simd.addFloat4(position_y, simd.mulFloat4(velocity_y, dt));

        simd.scatterFloat4(slice.previous_x, lanes, position_x);
        simd.scatterFloat4(slice.previous_y, lanes, position_y);
        // Movement leaves z unchanged; previous_z follows it. No signed-int scatter
        // helper, so the four z lanes copy scalar.
        inline for (0..simd.lane_count) |lane| {
            slice.previous_z[lanes[lane]] = slice.position_z[lanes[lane]];
        }
        simd.scatterFloat4(slice.position_x, lanes, next_x);
        simd.scatterFloat4(slice.position_y, lanes, next_y);

        if (chunk_grid) |grid| {
            const nx = simd.toFloatArray(next_x);
            const ny = simd.toFloatArray(next_y);
            inline for (0..simd.lane_count) |lane| {
                writeChunkRow(grid, lanes[lane], nx[lane], ny[lane]);
            }
        }
    }

    while (k < range.end) : (k += 1) {
        const index: usize = indices[k];
        const position_x = slice.position_x[index];
        const position_y = slice.position_y[index];
        slice.previous_x[index] = position_x;
        slice.previous_y[index] = position_y;
        slice.previous_z[index] = slice.position_z[index];
        const next_x = position_x + slice.velocity_x[index] * delta_seconds;
        const next_y = position_y + slice.velocity_y[index] * delta_seconds;
        slice.position_x[index] = next_x;
        slice.position_y[index] = next_y;
        if (chunk_grid) |grid| writeChunkRow(grid, index, next_x, next_y);
    }
}

const MovementIndexedJobContext = struct {
    slice: data.MovementBodySlice,
    indices: []const u32,
    delta_seconds: f32,
    chunk_grid: ?ChunkGridParams,
};

fn fillMovementData(data_system: *data.DataSystem, count: usize) !void {
    for (0..count) |index| {
        const entity = try data_system.createEntity();
        const base: f32 = @floatFromInt(index);
        try data_system.setMovementBody(entity, .{
            .position = .{ .x = base * 2, .y = base * -3 },
            .previous_position = .{ .x = -1000, .y = -1000 },
            .velocity = .{ .x = base + 1, .y = -base - 2 },
            .speed = 1,
        });
    }
}

fn expectMovementDataApproxEqual(actual: *const data.DataSystem, expected: *const data.DataSystem) !void {
    const actual_slice = actual.movementBodySliceConst();
    const expected_slice = expected.movementBodySliceConst();
    try std.testing.expectEqual(expected_slice.entities.len, actual_slice.entities.len);

    for (0..actual_slice.entities.len) |index| {
        try std.testing.expectApproxEqAbs(expected_slice.previous_x[index], actual_slice.previous_x[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_slice.previous_y[index], actual_slice.previous_y[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_slice.position_x[index], actual_slice.position_x[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_slice.position_y[index], actual_slice.position_y[index], 0.001);
    }
}

test "serial movement uses simd lanes and scalar tails like scalar integration" {
    inline for (.{ 0, 3, 4, 9 }) |count| {
        var simd_data = data.DataSystem.init(std.testing.allocator);
        defer simd_data.deinit();
        var scalar_data = data.DataSystem.init(std.testing.allocator);
        defer scalar_data.deinit();

        try fillMovementData(&simd_data, count);
        try fillMovementData(&scalar_data, count);

        var simd_slice = simd_data.movementBodySlice();
        updateSerial(&simd_slice, 0.25);
        var scalar_slice = scalar_data.movementBodySlice();
        processRangeScalar(&scalar_slice, .{ .start = 0, .end = scalar_slice.entities.len }, 0.25);

        try expectMovementDataApproxEqual(&simd_data, &scalar_data);
    }
}

test "threaded movement matches serial movement" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threaded_data = data.DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();
    var serial_data = data.DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    try fillMovementData(&threaded_data, data.movement_range_alignment_items * 8);
    try fillMovementData(&serial_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var threaded_slice = threaded_data.movementBodySlice();
    const stats = updateMovementBodies(&threaded_slice, &threads, 0.5, .{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    var serial_slice = serial_data.movementBodySlice();
    updateSerial(&serial_slice, 0.5);

    try std.testing.expectEqual(serial_data.movementBodySliceConst().entities.len, stats.body_count);
    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expectEqual(data.movement_range_alignment_items, stats.batch.items_per_range);
    try expectMovementDataApproxEqual(&threaded_data, &serial_data);
}

test "threaded movement matches serial across multiple range splits and worker counts" {
    if (builtin.single_threaded) return error.SkipZigTest;

    // The single-split parity test above pins one fixed split; the AdaptiveWorkTuner
    // instead picks range/worker counts dynamically, and its probe-driven choice is not
    // reproducible in a unit test. This asserts the split-INVARIANCE the tuner relies on:
    // every explicit partition and worker count must reproduce the serial reference.
    const item_count = data.movement_range_alignment_items * 8;
    var serial_data = data.DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    try fillMovementData(&serial_data, item_count);
    var serial_slice = serial_data.movementBodySlice();
    updateSerial(&serial_slice, 0.5);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = data.movement_range_alignment_items, .workers = 2 },
        .{ .items_per_range = data.movement_range_alignment_items * 2, .workers = 2 },
        .{ .items_per_range = data.movement_range_alignment_items, .workers = 4 },
        .{ .items_per_range = data.movement_range_alignment_items * 3, .workers = 3 },
    };
    for (splits) |split| {
        var threaded_data = data.DataSystem.init(std.testing.allocator);
        defer threaded_data.deinit();
        try fillMovementData(&threaded_data, item_count);
        var threaded_slice = threaded_data.movementBodySlice();
        const stats = updateMovementBodies(&threaded_slice, &threads, 0.5, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        // Real workers partitioned the batch (not the inline fallback), so this split
        // exercised the multi-range, multi-worker path it claims to.
        try std.testing.expect(!stats.batch.ran_inline);
        try expectMovementDataApproxEqual(&threaded_data, &serial_data);
    }
}

test "movement explicit items_per_range bypasses tuner" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = data.movement_range_alignment_items * 2,
        .smallest_range_items = data.movement_range_alignment_items,
        .largest_range_items = data.movement_range_alignment_items * 4,
    });
    var slice = game_data.movementBodySlice();
    const stats = updateMovementBodies(&slice, &threads, 0.5, .{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive_tuner = &adaptive_tuner,
    });

    try std.testing.expectEqual(data.movement_range_alignment_items, stats.batch.items_per_range);
    try std.testing.expectEqual(@as(usize, 0), adaptive_tuner.report().sample_count);
    try std.testing.expectEqual(@as(u64, 0), adaptive_tuner.report().best_mean_batch_duration_ns);
}

test "movement system owns adaptive tuner for default update" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    var stats = MovementStats{};
    for (0..system.adaptive_tuner.report().sample_window) |_| {
        var slice = game_data.movementBodySlice();
        stats = system.update(&slice, &threads, 0.5, .{
            .max_worker_threads = 2,
        });
    }

    try std.testing.expect(system.adaptive_tuner.report().baseline_mean_batch_duration_ns > 0);
    try std.testing.expect(!system.adaptive_tuner.report().has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().best_mean_batch_duration_ns);
    try std.testing.expectEqual(game_data.movementBodySliceConst().entities.len, stats.body_count);
}

test "movement update uses provided adaptive tuner" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1 });
    var slice = game_data.movementBodySlice();
    const stats = updateMovementBodies(&slice, &threads, 0.5, .{
        .max_worker_threads = 2,
        .adaptive_tuner = &adaptive_tuner,
    });

    try std.testing.expectEqual(game_data.movementBodySliceConst().entities.len, stats.body_count);
    try std.testing.expect(adaptive_tuner.report().baseline_mean_batch_duration_ns > 0);
    try std.testing.expect(!adaptive_tuner.report().has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().best_mean_batch_duration_ns);
}

test "movement range only writes assigned items" {
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, 8);

    var slice = game_data.movementBodySlice();
    processRange(&slice, .{ .start = 2, .end = 6 }, 1.0, null);

    for (0..slice.entities.len) |index| {
        const base: f32 = @floatFromInt(index);
        if (index >= 2 and index < 6) {
            try std.testing.expectEqual(base * 2, slice.previous_x[index]);
            try std.testing.expectEqual(base * -3, slice.previous_y[index]);
            try std.testing.expectEqual(base * 2 + base + 1, slice.position_x[index]);
            try std.testing.expectEqual(base * -3 - base - 2, slice.position_y[index]);
        } else {
            try std.testing.expectEqual(@as(f32, -1000), slice.previous_x[index]);
            try std.testing.expectEqual(@as(f32, -1000), slice.previous_y[index]);
            try std.testing.expectEqual(base * 2, slice.position_x[index]);
            try std.testing.expectEqual(base * -3, slice.position_y[index]);
        }
    }
}

test "warmed movement update does not allocate" {
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, 32);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    const original_data_allocator = game_data.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    game_data.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        game_data.allocator = original_data_allocator;
        threads.allocator = original_thread_allocator;
    }

    var slice = game_data.movementBodySlice();
    const stats = updateMovementBodies(&slice, &threads, 0.016, .{
        .items_per_range = data.movement_range_alignment_items,
    });
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
    try std.testing.expect(stats.batch.ran_inline);
}
