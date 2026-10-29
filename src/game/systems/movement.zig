// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const data = @import("../data_system.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const SimulationIntent = @import("../simulation.zig").SimulationIntent;

const default_intent_speed: f32 = 40.0;

pub const MovementConfig = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

const MovementThreads = @import("../../app/thread_system.zig").StageThreads(MovementConfig);

pub const MovementStats = struct {
    body_count: usize = 0,
    perf: Perf = .{},

    /// The integrate batch, kept only with `runtime_perf_log.enabled`.
    pub const Perf = if (runtime_perf_log.enabled) struct { batch: BatchStats = .{} } else struct {};
};

pub const MovementIntentStats = struct {
    intent_count: usize = 0,
    perf: Perf = .{},

    /// The apply batch, kept only with `runtime_perf_log.enabled`.
    pub const Perf = if (runtime_perf_log.enabled) struct { batch: BatchStats = .{} } else struct {};
};

pub const MovementSystem = struct {
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    apply_intents_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init() MovementSystem {
        return .{
            .adaptive_tuner = AdaptiveWorkTuner.init(.{}),
            .apply_intents_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn update(
        self: *MovementSystem,
        slice: *data.MovementBodySlice,
        thread_system: *ThreadSystem,
        delta_seconds: f32,
        config: MovementConfig,
    ) MovementStats {
        return updateMovementBodies(slice, (MovementThreads{ .thread_system = thread_system, .config = config }).stage(&self.adaptive_tuner), delta_seconds);
    }

    pub fn syncPreviousPositions(_: *MovementSystem, slice: *data.MovementBodySlice) void {
        syncPreviousPositionsImpl(slice);
    }

    /// Writes this step's movement intents into velocity as a threaded stage over the
    /// merged stream: `direction * speed` at the entity's movement row, speed `40` when
    /// not positive. Entities without both an AI agent and a movement body are skipped.
    /// Ranges write rows in parallel, relying on `frame.intents` carrying at most one
    /// movement intent per entity. Records timing into `apply_intents_tuner` only on adaptive
    /// selection (`adaptive`, no `items_per_range`, workers available). An empty stream
    /// records nothing.
    pub fn applyIntents(
        self: *MovementSystem,
        bodies: *data.DataSystem,
        frame: *const SimulationFrame,
        thread_system: *ThreadSystem,
        config: MovementConfig,
    ) MovementIntentStats {
        const intents = frame.intents.mergedItems();
        if (intents.len == 0) return .{};

        const apply = (MovementThreads{ .thread_system = thread_system, .config = config }).stage(&self.apply_intents_tuner);
        const selection = apply.select(intents.len, data.movement_range_alignment_items);
        var context = ApplyIntentsJobContext{
            .bodies = bodies,
            .intents = intents,
            .slice = bodies.movementBodySlice(),
            .range_count = selection.range_count,
        };
        const batch = apply.run(selection, intents.len, data.movement_range_alignment_items, &context, applyIntentsJob);
        return .{
            .intent_count = intents.len,
            .perf = if (comptime runtime_perf_log.enabled) .{ .batch = batch } else .{},
        };
    }
};

const ApplyIntentsJobContext = struct {
    bodies: *const data.DataSystem,
    intents: []const SimulationIntent,
    slice: data.MovementBodySlice,
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
};

fn applyIntentsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ApplyIntentsJobContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    applyIntentRange(job.bodies, job.intents, &job.slice, range);
}

// Applies the intents in `range`; written rows are the intents' movement rows, which
// the one-intent-per-entity stream keeps disjoint across ranges. Slot resolves are
// per-intent pointer chases and stay scalar; the speed math runs in lane blocks.
fn applyIntentRange(
    bodies: *const data.DataSystem,
    intents: []const SimulationIntent,
    slice: *const data.MovementBodySlice,
    range: ParallelRange,
) void {
    std.debug.assert(range.start <= range.end and range.end <= intents.len);
    std.debug.assert(slice.velocity_x.len == slice.entities.len and slice.velocity_y.len == slice.entities.len);
    std.debug.assert(slice.speed.len == slice.entities.len);
    var lanes = IntentLanes{};
    for (intents[range.start..range.end]) |item| {
        switch (item) {
            .movement => |movement_intent| {
                const row = bodies.aiMovementDenseIndex(movement_intent.entity) orelse continue;
                lanes.push(row, movement_intent.direction_x, movement_intent.direction_y);
                if (lanes.count == simd.lane_count) lanes.flush(slice);
            },
        }
    }
    lanes.flush(slice);
}

// Up to one lane block of resolved intents awaiting their velocity write.
const IntentLanes = struct {
    rows: [simd.lane_count]usize = undefined,
    dir_x: [simd.lane_count]f32 = undefined,
    dir_y: [simd.lane_count]f32 = undefined,
    count: usize = 0,

    fn push(self: *IntentLanes, row: usize, direction_x: f32, direction_y: f32) void {
        std.debug.assert(self.count < simd.lane_count);
        self.rows[self.count] = row;
        self.dir_x[self.count] = direction_x;
        self.dir_y[self.count] = direction_y;
        self.count += 1;
    }

    // One lane batch; a partial block is the same kernel masked to its live lanes, which
    // gather the first live row and are never stored.
    fn flush(self: *IntentLanes, slice: *const data.MovementBodySlice) void {
        if (self.count == 0) return;
        for (self.rows[self.count..], self.dir_x[self.count..], self.dir_y[self.count..]) |*row, *direction_x, *direction_y| {
            row.* = self.rows[0];
            direction_x.* = 0;
            direction_y.* = 0;
        }
        const speed = simd.gatherFloat4(slice.speed, self.rows);
        const effective_speed = simd.selectFloat4(
            simd.greaterThanFloat4(speed, simd.splatFloat4(0)),
            speed,
            simd.splatFloat4(default_intent_speed),
        );
        const velocity_x = simd.mulFloat4(simd.loadFloat4(&self.dir_x), effective_speed);
        const velocity_y = simd.mulFloat4(simd.loadFloat4(&self.dir_y), effective_speed);
        if (self.count == simd.lane_count) {
            simd.scatterFloat4(slice.velocity_x, self.rows, velocity_x);
            simd.scatterFloat4(slice.velocity_y, self.rows, velocity_y);
        } else {
            const live = simd.lanesBelow(self.count);
            simd.scatterFloat4Masked(slice.velocity_x, self.rows, velocity_x, live);
            simd.scatterFloat4Masked(slice.velocity_y, self.rows, velocity_y, live);
        }
        self.count = 0;
    }
};

// Scalar reference for the lane kernel.
fn applyIntentScalar(slice: *const data.MovementBodySlice, row: usize, direction_x: f32, direction_y: f32) void {
    const speed = slice.speed[row];
    const effective_speed = if (speed > 0) speed else default_intent_speed;
    slice.velocity_x[row] = direction_x * effective_speed;
    slice.velocity_y[row] = direction_y * effective_speed;
}

// Scalar reference for the lane blocks: every intent through `applyIntentScalar`.
fn applyIntentRangeScalar(bodies: *data.DataSystem, frame: *const SimulationFrame) void {
    const slice = bodies.movementBodySlice();
    for (frame.intents.mergedItems()) |item| {
        switch (item) {
            .movement => |movement_intent| {
                const row = bodies.aiMovementDenseIndex(movement_intent.entity) orelse continue;
                applyIntentScalar(&slice, row, movement_intent.direction_x, movement_intent.direction_y);
            },
        }
    }
}

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
    integrate: Dispatch,
    delta_seconds: f32,
) MovementStats {
    if (slice.entities.len == 0) return .{};

    // Pre-select so the job context can dual-assert range.index against the
    // dispatched range count.
    const selection = integrate.select(slice.entities.len, data.movement_range_alignment_items);
    var context = MovementJobContext{
        .slice = slice.*,
        .delta_seconds = delta_seconds,
        .range_count = selection.range_count,
    };
    const batch = integrate.run(selection, slice.entities.len, data.movement_range_alignment_items, &context, movementJob);
    return .{
        .body_count = slice.entities.len,
        .perf = if (comptime runtime_perf_log.enabled) .{ .batch = batch } else .{},
    };
}

fn syncPreviousPositionsImpl(slice: *data.MovementBodySlice) void {
    for (0..slice.entities.len) |index| {
        slice.previous_x[index] = slice.position_x[index];
        slice.previous_y[index] = slice.position_y[index];
    }
}

fn movementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *MovementJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig). Buffer bounds
    // also live in processRange (shared with the serial path).
    std.debug.assert(range.index < job.range_count);
    processRange(&job.slice, range, job.delta_seconds);
}

// Integrates `range` in lane batches; its last batch is the same kernel masked to the rows
// left, so no lane reads or writes past the range.
fn processRange(slice: *data.MovementBodySlice, range: ParallelRange, delta_seconds: f32) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= slice.entities.len);

    var index = range.start;
    const dt = simd.splatFloat4(delta_seconds);
    while (index < range.end) : (index += simd.lane_count) {
        const count = range.end - index;
        const position_x = simd.loadFloat4Lanes(slice.position_x[index..], count);
        const position_y = simd.loadFloat4Lanes(slice.position_y[index..], count);
        const velocity_x = simd.loadFloat4Lanes(slice.velocity_x[index..], count);
        const velocity_y = simd.loadFloat4Lanes(slice.velocity_y[index..], count);
        const next_x = simd.addFloat4(position_x, simd.mulFloat4(velocity_x, dt));
        const next_y = simd.addFloat4(position_y, simd.mulFloat4(velocity_y, dt));

        simd.storeFloat4Lanes(slice.previous_x[index..], position_x, count);
        simd.storeFloat4Lanes(slice.previous_y[index..], position_y, count);
        simd.storeFloat4Lanes(slice.position_x[index..], next_x, count);
        simd.storeFloat4Lanes(slice.position_y[index..], next_y, count);
    }
}

// Scalar reference for the lane kernel.
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
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
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

fn expectMovementDataBitsEqual(actual: *const data.DataSystem, expected: *const data.DataSystem) !void {
    const actual_slice = actual.movementBodySliceConst();
    const expected_slice = expected.movementBodySliceConst();
    try std.testing.expectEqual(expected_slice.entities.len, actual_slice.entities.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_slice.previous_x), std.mem.sliceAsBytes(actual_slice.previous_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_slice.previous_y), std.mem.sliceAsBytes(actual_slice.previous_y));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_slice.position_x), std.mem.sliceAsBytes(actual_slice.position_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_slice.position_y), std.mem.sliceAsBytes(actual_slice.position_y));
}

// `MovementSystem.update` inline as one range: a thread system with no workers.
fn updateInline(slice: *data.MovementBodySlice, delta_seconds: f32) !void {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var system = MovementSystem.init();
    _ = system.update(slice, &threads, delta_seconds, .{});
}

// `MovementSystem.applyIntents` inline as one range: a thread system with no workers.
fn applyIntentsInline(bodies: *data.DataSystem, frame: *const SimulationFrame) !void {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var system = MovementSystem.init();
    _ = system.applyIntents(bodies, frame, &threads, .{});
}

test "inline movement lane batches, the masked tail included, match scalar integration bit for bit" {
    inline for (.{ 0, 1, 3, 4, 5, 9 }) |count| {
        var simd_data = data.DataSystem.init(std.testing.allocator);
        defer simd_data.deinit();
        var scalar_data = data.DataSystem.init(std.testing.allocator);
        defer scalar_data.deinit();

        try fillMovementData(&simd_data, count);
        try fillMovementData(&scalar_data, count);

        var simd_slice = simd_data.movementBodySlice();
        try updateInline(&simd_slice, 0.25);
        var scalar_slice = scalar_data.movementBodySlice();
        processRangeScalar(&scalar_slice, .{ .start = 0, .end = scalar_slice.entities.len }, 0.25);

        try expectMovementDataBitsEqual(&simd_data, &scalar_data);
    }
}

test "threaded movement matches serial movement, the last range ending in the masked tail" {
    var threaded_data = data.DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();
    var serial_data = data.DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    try fillMovementData(&threaded_data, data.movement_range_alignment_items * 8 + 3);
    try fillMovementData(&serial_data, data.movement_range_alignment_items * 8 + 3);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    var threaded_slice = threaded_data.movementBodySlice();
    const stats = system.update(&threaded_slice, &threads, 0.5, .{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    var serial_slice = serial_data.movementBodySlice();
    try updateInline(&serial_slice, 0.5);

    try std.testing.expectEqual(serial_data.movementBodySliceConst().entities.len, stats.body_count);
    try expectMovementDataBitsEqual(&threaded_data, &serial_data);
}

test "threaded movement matches serial across multiple range splits and worker counts" {
    // Every explicit partition and worker count reproduces the serial reference: the
    // split invariance the tuner's choice relies on. The last range ends in the masked tail.
    const item_count = data.movement_range_alignment_items * 8 + 3;
    var serial_data = data.DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    try fillMovementData(&serial_data, item_count);
    var serial_slice = serial_data.movementBodySlice();
    try updateInline(&serial_slice, 0.5);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = data.movement_range_alignment_items, .workers = 2 },
        .{ .items_per_range = data.movement_range_alignment_items * 2, .workers = 2 },
        .{ .items_per_range = data.movement_range_alignment_items, .workers = 4 },
        .{ .items_per_range = data.movement_range_alignment_items * 3, .workers = 3 },
    };
    var system = MovementSystem.init();
    for (splits) |split| {
        var threaded_data = data.DataSystem.init(std.testing.allocator);
        defer threaded_data.deinit();
        try fillMovementData(&threaded_data, item_count);
        var threaded_slice = threaded_data.movementBodySlice();
        _ = system.update(&threaded_slice, &threads, 0.5, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        try expectMovementDataBitsEqual(&threaded_data, &serial_data);
    }
}

test "movement explicit items_per_range bypasses tuner" {
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    var slice = game_data.movementBodySlice();
    _ = system.update(&slice, &threads, 0.5, .{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
    });

    try std.testing.expectEqual(@as(usize, 0), system.adaptive_tuner.sample_count);
    try std.testing.expect(system.adaptive_tuner.last_request == null);
}

test "movement system owns adaptive tuner for default update" {
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    var slice = game_data.movementBodySlice();
    const stats = system.update(&slice, &threads, 0.5, .{ .max_worker_threads = 2 });

    try std.testing.expectEqual(game_data.movementBodySliceConst().entities.len, stats.body_count);
    try std.testing.expectEqual(@as(usize, 1), system.adaptive_tuner.sample_count);
    try std.testing.expect(system.adaptive_tuner.last_request != null);
    try std.testing.expectEqual(@as(usize, 0), system.apply_intents_tuner.sample_count);
    try std.testing.expect(system.apply_intents_tuner.last_request == null);
}

test "a movement range writes only its rows, a masked last batch included" {
    // Whole batches, a whole batch then a one-row tail, and a tail alone.
    for ([_]ParallelRange{ .{ .start = 2, .end = 6 }, .{ .start = 2, .end = 7 }, .{ .start = 5, .end = 8 } }) |range| {
        try expectMovementRangeWritesOnlyItsRows(range);
    }
}

fn expectMovementRangeWritesOnlyItsRows(range: ParallelRange) !void {
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, 12);

    var slice = game_data.movementBodySlice();
    processRange(&slice, range, 1.0);

    for (0..slice.entities.len) |index| {
        const base: f32 = @floatFromInt(index);
        if (index >= range.start and index < range.end) {
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
    try updateInline(&slice, 0.5);

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

    var system = MovementSystem.init();
    var slice = game_data.movementBodySlice();
    const stats = system.update(&slice, &threads, 0.016, .{
        .items_per_range = data.movement_range_alignment_items,
    });
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
}

test "threaded multi-worker movement update has no steady-state allocation after warmup (FailingAllocator)" {
    var game_data = data.DataSystem.init(std.testing.allocator);
    defer game_data.deinit();
    try fillMovementData(&game_data, data.movement_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    var slice = game_data.movementBodySlice();
    _ = system.update(&slice, &threads, 0.016, .{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    // Movement writes only into the caller's SoA columns and ThreadSystem
    // work queues (both reserved at init); swap both to a failing allocator.
    const original_data_allocator = game_data.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    game_data.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        game_data.allocator = original_data_allocator;
        threads.allocator = original_thread_allocator;
    }

    slice = game_data.movementBodySlice();
    const stats = system.update(&slice, &threads, 0.016, .{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    try std.testing.expectEqual(data.movement_range_alignment_items * 8, stats.body_count);
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
    try updateInline(&slice, 0.5);

    // Dormant row unmoved; moving row integrated pos + vel*dt exactly.
    const after_dormant = game_data.movementBodyConst(going_dormant).?;
    try std.testing.expectEqual(@as(f32, 300), after_dormant.position.x);
    try std.testing.expectEqual(@as(f32, 400), after_dormant.position.y);
    const after_moving = game_data.movementBodyConst(moving).?;
    try std.testing.expectEqual(@as(f32, 100 + 40 * 0.5), after_moving.position.x);
    try std.testing.expectEqual(@as(f32, 200 - 20 * 0.5), after_moving.position.y);
}

// Intents the apply must skip, interleaved through the fixture's stream.
const IntentSkip = enum { invalid_entity, destroyed_entity, body_without_agent, agent_without_body };

// Velocity of a row no intent writes.
const unapplied_velocity: f32 = -7.5;

const IntentFixture = struct {
    game_data: data.DataSystem,
    frame: SimulationFrame,
    agent_count: usize,
    // Movement row of the body without an AI agent, when the fixture has skips.
    body_only_row: ?usize,

    fn deinit(self: *IntentFixture) void {
        self.frame.deinit();
        self.game_data.deinit();
        self.* = undefined;
    }
};

// Every 5th agent has a non-positive speed (alternating -0.0 and 0), so the default
// speed applies.
fn intentAgentSpeed(row: usize) f32 {
    if (row % 10 == 0) return -0.0;
    return if (row % 5 == 0) 0 else 0.5 + @as(f32, @floatFromInt(row % 7)) * 1.25;
}

// Every 9th agent steers along a non-finite direction, which must propagate the same
// through the lane and scalar forms.
fn intentDirection(row: usize) [2]f32 {
    if (row % 9 == 2) return .{ std.math.nan(f32), std.math.inf(f32) };
    return .{
        (@as(f32, @floatFromInt(row % 9)) - 4.0) / 3.0,
        (@as(f32, @floatFromInt(row % 5)) - 2.0) / 7.0,
    };
}

// `agent_count` agents (movement body and AI agent) on movement rows `0..agent_count`,
// one intent each in a scattered row order; with `with_skips`, one intent per
// `IntentSkip` spread through the stream so they land in different ranges.
fn initIntentFixture(agent_count: usize, with_skips: bool) !IntentFixture {
    const allocator = std.testing.allocator;
    var game_data = data.DataSystem.init(allocator);
    errdefer game_data.deinit();
    for (0..agent_count) |row| {
        const entity = try game_data.createEntity();
        try game_data.setMovementBody(entity, .{
            .velocity = .{ .x = unapplied_velocity, .y = unapplied_velocity },
            .speed = intentAgentSpeed(row),
        });
        try game_data.setAiAgent(entity, .{});
    }

    var skip_entities: [std.meta.tags(IntentSkip).len]data.EntityId = undefined;
    var body_only_row: ?usize = null;
    if (with_skips) {
        const body_only = try game_data.createEntity();
        try game_data.setMovementBody(body_only, .{ .velocity = .{ .x = unapplied_velocity, .y = unapplied_velocity }, .speed = 3 });
        body_only_row = agent_count;
        const agent_only = try game_data.createEntity();
        try game_data.setAiAgent(agent_only, .{});
        // Created last, so removing its movement row moves no other row.
        const destroyed = try game_data.createEntity();
        try game_data.setMovementBody(destroyed, .{ .speed = 3 });
        try game_data.setAiAgent(destroyed, .{});
        try std.testing.expect(try game_data.destroyEntity(destroyed));
        skip_entities[@backingInt(IntentSkip.invalid_entity)] = data.EntityId.invalid;
        skip_entities[@backingInt(IntentSkip.destroyed_entity)] = destroyed;
        skip_entities[@backingInt(IntentSkip.body_without_agent)] = body_only;
        skip_entities[@backingInt(IntentSkip.agent_without_body)] = agent_only;
    }
    const skip_count: usize = if (with_skips) skip_entities.len else 0;

    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.intents.prepareRangeCounts(1);
    frame.intents.addCount(0, agent_count + skip_count);
    try frame.intents.prefix();
    var writer = frame.intents.rangeWriter(0);
    var stride: usize = if (agent_count <= 1) 1 else 7;
    while (agent_count > 1 and std.math.gcd(stride, agent_count) != 1) stride += 2;
    const entities = game_data.movementBodySliceConst().entities;
    var next_skip: usize = 0;
    for (0..agent_count) |order| {
        while (next_skip < skip_count and next_skip * agent_count / skip_count <= order) : (next_skip += 1) {
            writer.write(.{ .movement = .{ .entity = skip_entities[next_skip], .direction_x = 1, .direction_y = 1 } });
        }
        const row = order * stride % agent_count;
        const direction = intentDirection(row);
        writer.write(.{ .movement = .{ .entity = entities[row], .direction_x = direction[0], .direction_y = direction[1] } });
    }
    while (next_skip < skip_count) : (next_skip += 1) {
        writer.write(.{ .movement = .{ .entity = skip_entities[next_skip], .direction_x = 1, .direction_y = 1 } });
    }
    writer.finish();
    frame.intents.finishWrite();

    return .{ .game_data = game_data, .frame = frame, .agent_count = agent_count, .body_only_row = body_only_row };
}

fn expectVelocityBitsEqual(actual: *const data.DataSystem, expected: *const data.DataSystem) !void {
    const actual_slice = actual.movementBodySliceConst();
    const expected_slice = expected.movementBodySliceConst();
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_slice.velocity_x), std.mem.sliceAsBytes(actual_slice.velocity_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_slice.velocity_y), std.mem.sliceAsBytes(actual_slice.velocity_y));
}

test "applied intents set velocity from direction and speed, default speed when not positive" {
    var fixture = try initIntentFixture(data.movement_range_alignment_items * 2 + 3, true);
    defer fixture.deinit();

    try applyIntentsInline(&fixture.game_data, &fixture.frame);

    const slice = fixture.game_data.movementBodySliceConst();
    try std.testing.expectEqual(fixture.agent_count + 1, slice.entities.len);
    for (0..fixture.agent_count) |row| {
        const direction = intentDirection(row);
        const speed: f32 = if (row % 5 == 0) default_intent_speed else intentAgentSpeed(row);
        // Bitwise, so the non-finite direction rows compare.
        try std.testing.expectEqual(@as(u32, @bitCast(direction[0] * speed)), @as(u32, @bitCast(slice.velocity_x[row])));
        try std.testing.expectEqual(@as(u32, @bitCast(direction[1] * speed)), @as(u32, @bitCast(slice.velocity_y[row])));
    }
    // The body without an AI agent keeps its velocity; the other skips own no row.
    const body_only_row = fixture.body_only_row.?;
    try std.testing.expectEqual(unapplied_velocity, slice.velocity_x[body_only_row]);
    try std.testing.expectEqual(unapplied_velocity, slice.velocity_y[body_only_row]);
}

test "threaded intent apply matches serial across range splits and worker counts" {
    const agent_count = data.movement_range_alignment_items * 8 + 3;
    var serial = try initIntentFixture(agent_count, true);
    defer serial.deinit();
    try applyIntentsInline(&serial.game_data, &serial.frame);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = data.movement_range_alignment_items, .workers = 2 },
        .{ .items_per_range = data.movement_range_alignment_items * 2, .workers = 2 },
        .{ .items_per_range = data.movement_range_alignment_items, .workers = 4 },
        .{ .items_per_range = data.movement_range_alignment_items * 3, .workers = 3 },
    };
    for (splits) |split| {
        var threaded = try initIntentFixture(agent_count, true);
        defer threaded.deinit();
        var system = MovementSystem.init();
        const stats = system.applyIntents(&threaded.game_data, &threaded.frame, &threads, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        try std.testing.expectEqual(agent_count + std.meta.tags(IntentSkip).len, stats.intent_count);
        try expectVelocityBitsEqual(&threaded.game_data, &serial.game_data);
    }
}

test "intent lanes match the scalar apply bit for bit" {
    inline for (.{ 0, 3, 4, 9, 17 }) |agent_count| {
        var lanes = try initIntentFixture(agent_count, false);
        defer lanes.deinit();
        var scalar = try initIntentFixture(agent_count, false);
        defer scalar.deinit();

        try applyIntentsInline(&lanes.game_data, &lanes.frame);
        applyIntentRangeScalar(&scalar.game_data, &scalar.frame);

        try expectVelocityBitsEqual(&lanes.game_data, &scalar.game_data);
    }
}

test "threaded multi-worker intent apply allocates nothing after warmup (FailingAllocator)" {
    var fixture = try initIntentFixture(data.movement_range_alignment_items * 8, true);
    defer fixture.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    const config = MovementConfig{
        .items_per_range = data.movement_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    };
    _ = system.applyIntents(&fixture.game_data, &fixture.frame, &threads, config);

    const original_data_allocator = fixture.game_data.allocator;
    const original_intents_allocator = fixture.frame.intents.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.game_data.allocator = failing_allocator.allocator();
    fixture.frame.intents.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        fixture.game_data.allocator = original_data_allocator;
        fixture.frame.intents.allocator = original_intents_allocator;
        threads.allocator = original_thread_allocator;
    }

    const stats = system.applyIntents(&fixture.game_data, &fixture.frame, &threads, config);
    try std.testing.expectEqual(fixture.frame.intents.mergedItems().len, stats.intent_count);
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "intent apply records into its own tuner" {
    var fixture = try initIntentFixture(data.movement_range_alignment_items * 8, false);
    defer fixture.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    _ = system.applyIntents(&fixture.game_data, &fixture.frame, &threads, .{ .max_worker_threads = 2 });

    try std.testing.expectEqual(@as(usize, 1), system.apply_intents_tuner.sample_count);
    try std.testing.expect(system.apply_intents_tuner.last_request != null);
    try std.testing.expectEqual(@as(usize, 0), system.adaptive_tuner.sample_count);
    try std.testing.expect(system.adaptive_tuner.last_request == null);
}

test "empty intent stream applies nothing and records no batch" {
    var fixture = try initIntentFixture(data.movement_range_alignment_items, false);
    defer fixture.deinit();
    fixture.frame.intents.clearRetainingCapacity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = data.movement_range_alignment_items,
    });
    defer threads.deinit();

    var system = MovementSystem.init();
    const stats = system.applyIntents(&fixture.game_data, &fixture.frame, &threads, .{ .max_worker_threads = 2 });

    try std.testing.expectEqual(@as(usize, 0), stats.intent_count);
    try std.testing.expectEqual(@as(usize, 0), system.apply_intents_tuner.sample_count);
    const slice = fixture.game_data.movementBodySliceConst();
    for (slice.velocity_x, slice.velocity_y) |velocity_x, velocity_y| {
        try std.testing.expectEqual(unapplied_velocity, velocity_x);
        try std.testing.expectEqual(unapplied_velocity, velocity_y);
    }
}
