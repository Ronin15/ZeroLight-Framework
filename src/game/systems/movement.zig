// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const builtin = @import("builtin");
const std = @import("std");
const data = @import("../data_system.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;

pub const MovementConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
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

/// Integrates every movement body over one contiguous SIMD range. Non-moving
/// (dormant/kinematic) rows carry zero velocity — DataSystem zeros it on entry to a
/// non-moving tier — so they integrate as no-ops; movement needs no scattered
/// skip-path and the warm contiguous SIMD load stays intact. Chunk maintenance is a
/// separate pass (SimulationScopeSystem.deriveChunks); movement only integrates
/// position, so its benchmark exercises exactly this production path.
///
/// Only x/y are snapshotted for render interpolation: z is a discrete plane index
/// the renderer orders by directly (never interpolated), so movement never reads or
/// writes it — there is no previous-z to maintain, keeping the vectorized loop pure.
fn updateMovementBodies(
    slice: *data.MovementBodySlice,
    thread_system: *ThreadSystem,
    delta_seconds: f32,
    config: MovementConfig,
) MovementStats {
    if (slice.entities.len == 0) return .{};

    var context = MovementJobContext{
        .slice = slice.*,
        .delta_seconds = delta_seconds,
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
    processRange(slice, .{ .start = 0, .end = slice.entities.len }, delta_seconds);
}

pub fn syncPreviousPositions(slice: *data.MovementBodySlice) void {
    syncPreviousPositionsImpl(slice);
}

fn syncPreviousPositionsImpl(slice: *data.MovementBodySlice) void {
    for (0..slice.entities.len) |index| {
        slice.previous_x[index] = slice.position_x[index];
        slice.previous_y[index] = slice.position_y[index];
    }
}

fn movementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *MovementJobContext = @ptrCast(@alignCast(context));
    processRange(&job.slice, range, job.delta_seconds);
}

fn processRange(slice: *data.MovementBodySlice, range: ParallelRange, delta_seconds: f32) void {
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
        simd.storeFloat4Slice(slice.position_x[index..], next_x);
        simd.storeFloat4Slice(slice.position_y[index..], next_y);
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

fn processRangeScalar(slice: *data.MovementBodySlice, range: ParallelRange, delta_seconds: f32) void {
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

const MovementJobContext = struct {
    slice: data.MovementBodySlice,
    delta_seconds: f32,
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

test "integrate leaves the discrete z plane untouched" {
    // z is a discrete depth-sort plane index, not integrated or interpolated.
    // Movement must not write z, so a body on a plane keeps its position_z.
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();

    const entity = try game_data.createEntity();
    try game_data.setMovementBody(entity, .{ .position = .{ .x = 10, .y = 20 }, .velocity = .{ .x = 5, .y = -5 } });
    game_data.movementBodyPtr(entity).?.snapZ(3);

    var slice = game_data.movementBodySlice();
    updateSerial(&slice, 0.5);

    const body = game_data.movementBodyConst(entity).?;
    try std.testing.expectEqual(@as(i32, 3), body.position_z);
    // x/y still integrated + snapshotted as before.
    try std.testing.expectEqual(@as(f32, 10), body.previous_position.x);
    try std.testing.expectEqual(@as(f32, 10 + 5 * 0.5), body.position.x);
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

test "dormant rows carry zero velocity and stay frozen across a full-range integrate" {
    // Movement integrates the full contiguous SoA range (no scattered skip-path).
    // Correctness for non-moving rows relies on DataSystem zeroing their velocity on
    // entry to a non-moving tier, so integrating them here is a no-op.
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();

    const moving = try game_data.createEntity();
    try game_data.setMovementBody(moving, .{ .position = .{ .x = 100, .y = 200 }, .velocity = .{ .x = 40, .y = -20 } });
    const going_dormant = try game_data.createEntity();
    try game_data.setMovementBody(going_dormant, .{ .position = .{ .x = 300, .y = 400 }, .velocity = .{ .x = 64, .y = 64 } });
    try game_data.setSimulationTier(going_dormant, .dormant);

    // Tier entry must have zeroed the dormant row's velocity.
    const dormant_body = game_data.movementBodyConst(going_dormant).?;
    try std.testing.expectEqual(@as(f32, 0), dormant_body.velocity.x);
    try std.testing.expectEqual(@as(f32, 0), dormant_body.velocity.y);

    var slice = game_data.movementBodySlice();
    updateSerial(&slice, 0.5);

    // Dormant row unmoved; moving row integrated pos + vel*dt exactly.
    const after_dormant = game_data.movementBodyConst(going_dormant).?;
    try std.testing.expectEqual(@as(f32, 300), after_dormant.position.x);
    try std.testing.expectEqual(@as(f32, 400), after_dormant.position.y);
    const after_moving = game_data.movementBodyConst(moving).?;
    try std.testing.expectEqual(@as(f32, 100 + 40 * 0.5), after_moving.position.x);
    try std.testing.expectEqual(@as(f32, 200 - 20 * 0.5), after_moving.position.y);
}
