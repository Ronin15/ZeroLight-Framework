// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const thread_mod = @import("../../app/thread_system.zig");
const ThreadSystem = thread_mod.ThreadSystem;
const ParallelRange = thread_mod.ParallelRange;
const AdaptiveGrainTuner = thread_mod.AdaptiveGrainTuner;
const AdaptiveThreadCount = thread_mod.AdaptiveThreadCount;
const data_mod = @import("../data_system.zig");
const DataSystem = data_mod.DataSystem;
const MovementBodySlice = data_mod.MovementBodySlice;
const simd = @import("../../core/simd.zig");

pub const MovementConfig = struct {
    min_parallel_items: ?usize = null,
    grain_size: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_thread_count: ?*AdaptiveThreadCount = null,
    grain_tuner: ?*AdaptiveGrainTuner = null,
};

pub const MovementStats = struct {
    body_count: usize = 0,
    batch: thread_mod.BatchStats = .{},
};

pub const Runtime = struct {
    grain_tuner: AdaptiveGrainTuner = AdaptiveGrainTuner.init(.{}),
    adaptive_thread_count: AdaptiveThreadCount = .{},

    pub fn init() Runtime {
        return .{
            .grain_tuner = AdaptiveGrainTuner.init(.{}),
            .adaptive_thread_count = .{},
        };
    }

    pub fn update(
        self: *Runtime,
        data: *DataSystem,
        thread_system: *ThreadSystem,
        delta_seconds: f32,
        config: MovementConfig,
    ) MovementStats {
        var runtime_config = config;
        if (runtime_config.grain_size == null and runtime_config.grain_tuner == null) {
            runtime_config.grain_tuner = &self.grain_tuner;
        }
        if (runtime_config.adaptive and runtime_config.adaptive_thread_count == null) {
            runtime_config.adaptive_thread_count = &self.adaptive_thread_count;
        }
        return movementUpdate(data, thread_system, delta_seconds, runtime_config);
    }

    pub fn syncPreviousPositions(_: *Runtime, data: *DataSystem) void {
        movementSyncPreviousPositions(data);
    }
};

pub fn update(
    data: *DataSystem,
    thread_system: *ThreadSystem,
    delta_seconds: f32,
    config: MovementConfig,
) MovementStats {
    return movementUpdate(data, thread_system, delta_seconds, config);
}

fn movementUpdate(
    data: *DataSystem,
    thread_system: *ThreadSystem,
    delta_seconds: f32,
    config: MovementConfig,
) MovementStats {
    const slice = data.movementBodySlice();
    if (slice.entities.len == 0) return .{};

    var context = MovementJobContext{
        .slice = slice,
        .delta_seconds = delta_seconds,
    };
    const active_tuner = if (config.grain_size == null) config.grain_tuner else null;
    const grain_size = if (active_tuner) |tuner|
        tuner.grainSize(slice.entities.len, data_mod.movement_range_alignment_items)
    else
        config.grain_size;
    const batch = thread_system.parallelForWithOptions(slice.entities.len, &context, movementJob, .{
        .min_parallel_items = config.min_parallel_items,
        .grain_size = grain_size,
        .max_worker_threads = config.max_worker_threads,
        .range_alignment_items = data_mod.movement_range_alignment_items,
        .adaptive = config.adaptive,
        .adaptive_thread_count = config.adaptive_thread_count,
    });
    if (active_tuner) |tuner| {
        tuner.record(batch);
    }
    return .{
        .body_count = slice.entities.len,
        .batch = batch,
    };
}

pub fn updateSerial(data: *DataSystem, delta_seconds: f32) void {
    var slice = data.movementBodySlice();
    processRange(&slice, .{ .start = 0, .end = slice.entities.len }, delta_seconds);
}

pub fn syncPreviousPositions(data: *DataSystem) void {
    movementSyncPreviousPositions(data);
}

fn movementSyncPreviousPositions(data: *DataSystem) void {
    var slice = data.movementBodySlice();
    for (0..slice.entities.len) |index| {
        slice.previous_x[index] = slice.position_x[index];
        slice.previous_y[index] = slice.position_y[index];
    }
}

fn movementJob(context: *anyopaque, range: ParallelRange, _: thread_mod.WorkerId) void {
    const job: *MovementJobContext = @ptrCast(@alignCast(context));
    processRange(&job.slice, range, job.delta_seconds);
}

fn processRange(slice: *MovementBodySlice, range: ParallelRange, delta_seconds: f32) void {
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

        storeFloat4(slice.previous_x[index..], position_x);
        storeFloat4(slice.previous_y[index..], position_y);
        storeFloat4(slice.position_x[index..], next_x);
        storeFloat4(slice.position_y[index..], next_y);
    }

    while (index < range.end) : (index += 1) {
        const position_x = slice.position_x[index];
        const position_y = slice.position_y[index];
        slice.previous_x[index] = position_x;
        slice.previous_y[index] = position_y;
        slice.position_x[index] = position_x + slice.velocity_x[index] * delta_seconds;
        slice.position_y[index] = position_y + slice.velocity_y[index] * delta_seconds;
    }
}

fn processRangeScalar(slice: *MovementBodySlice, range: ParallelRange, delta_seconds: f32) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= slice.entities.len);

    for (range.start..range.end) |index| {
        const position_x = slice.position_x[index];
        const position_y = slice.position_y[index];
        slice.previous_x[index] = position_x;
        slice.previous_y[index] = position_y;
        slice.position_x[index] = position_x + slice.velocity_x[index] * delta_seconds;
        slice.position_y[index] = position_y + slice.velocity_y[index] * delta_seconds;
    }
}

fn storeFloat4(values: []f32, vector: simd.Float4) void {
    std.debug.assert(values.len >= simd.lane_count);
    const stored = simd.toFloatArray(vector);
    inline for (0..simd.lane_count) |lane| {
        values[lane] = stored[lane];
    }
}

const MovementJobContext = struct {
    slice: MovementBodySlice,
    delta_seconds: f32,
};

fn fillMovementData(data: *DataSystem, count: usize) !void {
    for (0..count) |index| {
        const entity = try data.createEntity();
        const base: f32 = @floatFromInt(index);
        try data.setMovementBody(entity, .{
            .position = .{ .x = base * 2, .y = base * -3 },
            .previous_position = .{ .x = -1000, .y = -1000 },
            .velocity = .{ .x = base + 1, .y = -base - 2 },
            .speed = 1,
        });
    }
}

fn expectMovementDataApproxEqual(actual: *const DataSystem, expected: *const DataSystem) !void {
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
        var simd_data = DataSystem.init(std.testing.allocator);
        defer simd_data.deinit();
        var scalar_data = DataSystem.init(std.testing.allocator);
        defer scalar_data.deinit();

        try fillMovementData(&simd_data, count);
        try fillMovementData(&scalar_data, count);

        updateSerial(&simd_data, 0.25);
        var scalar_slice = scalar_data.movementBodySlice();
        processRangeScalar(&scalar_slice, .{ .start = 0, .end = scalar_slice.entities.len }, 0.25);

        try expectMovementDataApproxEqual(&simd_data, &scalar_data);
    }
}

test "threaded movement matches serial movement" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threaded_data = DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();
    var serial_data = DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    try fillMovementData(&threaded_data, data_mod.movement_range_alignment_items * 8);
    try fillMovementData(&serial_data, data_mod.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();

    var grain_tuner = AdaptiveGrainTuner.init(.{
        .initial_grain_size = data_mod.movement_range_alignment_items,
        .min_grain_size = data_mod.movement_range_alignment_items,
        .max_grain_size = data_mod.movement_range_alignment_items * 4,
    });
    const stats = update(&threaded_data, &threads, 0.5, .{
        .min_parallel_items = 1,
        .max_worker_threads = 2,
        .adaptive = false,
        .grain_tuner = &grain_tuner,
    });
    updateSerial(&serial_data, 0.5);

    try std.testing.expectEqual(serial_data.movementBodySliceConst().entities.len, stats.body_count);
    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expectEqual(data_mod.movement_range_alignment_items, stats.batch.grain_size);
    try expectMovementDataApproxEqual(&threaded_data, &serial_data);
}

test "movement explicit grain bypasses tuner" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillMovementData(&data, data_mod.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();

    var grain_tuner = AdaptiveGrainTuner.init(.{
        .initial_grain_size = data_mod.movement_range_alignment_items * 2,
        .min_grain_size = data_mod.movement_range_alignment_items,
        .max_grain_size = data_mod.movement_range_alignment_items * 4,
    });
    const stats = update(&data, &threads, 0.5, .{
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
        .grain_tuner = &grain_tuner,
    });

    try std.testing.expectEqual(data_mod.movement_range_alignment_items, stats.batch.grain_size);
    try std.testing.expectEqual(@as(usize, 0), grain_tuner.report().sample_count);
    try std.testing.expectEqual(@as(u64, 0), grain_tuner.report().best_mean_batch_duration_ns);
}

test "movement runtime owns tuner for default update" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillMovementData(&data, data_mod.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();

    var runtime = Runtime.init();
    const stats = runtime.update(&data, &threads, 0.5, .{
        .min_parallel_items = 1,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), runtime.grain_tuner.report().sample_count);
}

test "movement update uses provided adaptive thread count" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillMovementData(&data, data_mod.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();

    var adaptive_thread_count = AdaptiveThreadCount{
        .last_batch_duration_ns = 100_000,
    };
    const stats = update(&data, &threads, 0.5, .{
        .min_parallel_items = 1,
        .max_worker_threads = 2,
        .adaptive_thread_count = &adaptive_thread_count,
    });

    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expect(adaptive_thread_count.last_batch_duration_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_thread_count.last_batch_duration_ns);
}

test "movement range only writes assigned items" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillMovementData(&data, 8);

    var slice = data.movementBodySlice();
    processRange(&slice, .{ .start = 2, .end = 6 }, 1.0);

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
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillMovementData(&data, 32);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();

    const original_data_allocator = data.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    data.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        data.allocator = original_data_allocator;
        threads.allocator = original_thread_allocator;
    }

    const stats = update(&data, &threads, 0.016, .{
        .min_parallel_items = 1,
        .grain_size = data_mod.movement_range_alignment_items,
    });
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
    try std.testing.expect(stats.batch.ran_inline);
}
