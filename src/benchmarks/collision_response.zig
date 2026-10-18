// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const CollisionResponse = @import("../game/data_system.zig").CollisionResponse;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const movement_range_alignment_items = @import("../game/data_system.zig").movement_range_alignment_items;
const CollisionResponseStats = @import("../game/systems/collision_response.zig").CollisionResponseStats;
const CollisionResponseSystem = @import("../game/systems/collision_response.zig").CollisionResponseSystem;
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

// `collision-response-stage`: one response step over a contact stream where every body
// sits in several contacts as `a` and as `b`, written once in a scattered order. Timed:
// one `update`; the movement columns are restored untimed before each run so every run
// takes the same branch mix. `--details` reports intents, triggers, the gather and
// apply shapes, and the time and share on main outside the stage batches.
pub const stage_group = suite.BenchmarkGroup{
    .name = "collision-response-stage",
    .item_label = "contacts",
    .item_counts = &stage_item_counts,
    .runCase = runStageCase,
    .write_workload = writeResponseStageWorkload,
};

const stage_item_counts = [_]usize{ 1_024, 4_096, 16_384 };
// First stride tried for the scattered contact order; stepped until coprime with the
// contact count so the order visits every contact once.
const stage_scatter_stride_seed: usize = 7_919;
const stage_bounce_restitution: f32 = 0.5;

const StageFixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    observer: EntityId,
    expected_intents: usize,
    expected_triggers: usize,
    expected_observer_contacts: usize,
    // Movement columns as built, restored before each run.
    position_x: []f32,
    position_y: []f32,
    velocity_x: []f32,
    velocity_y: []f32,

    fn deinit(self: *StageFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.velocity_y);
        allocator.free(self.velocity_x);
        allocator.free(self.position_y);
        allocator.free(self.position_x);
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn restoreMovement(self: *StageFixture) void {
        const movement = self.data.movementBodySlice();
        @memcpy(movement.position_x, self.position_x);
        @memcpy(movement.position_y, self.position_y);
        @memcpy(movement.velocity_x, self.velocity_x);
        @memcpy(movement.velocity_y, self.velocity_y);
    }
};

fn stageBodyResponse(body: usize) CollisionResponse {
    if (body % 16 == 3) return .{ .mode = .trigger, .mobility = .static, .restitution = 0 };
    if (body % 8 == 7) return .{ .mode = .solid, .mobility = .static, .restitution = 0 };
    if (body % 4 == 1) return .{ .mode = .bounce, .mobility = .dynamic, .restitution = stage_bounce_restitution };
    return .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 };
}

// Contact `index` pairs body `index / 2` with the body one or two rows after it.
fn stageContactBodies(index: usize) [2]usize {
    const a = index / 2;
    return .{ a, a + 1 + index % 2 };
}

// Axis normals cycling through all four directions by contact index.
fn stageContactNormal(index: usize) [2]f32 {
    return switch (index % 4) {
        0 => .{ 1, 0 },
        1 => .{ -1, 0 },
        2 => .{ 0, 1 },
        else => .{ 0, -1 },
    };
}

// Intents the response emits for a non-trigger contact between these two bodies.
fn stageExpectedIntents(a: CollisionResponse, b: CollisionResponse) usize {
    const a_dynamic = a.mobility == .dynamic;
    const b_dynamic = b.mobility == .dynamic;
    if (!a_dynamic and !b_dynamic) return 0;
    if (a_dynamic != b_dynamic) return 1;
    if ((a.mode == .bounce) != (b.mode == .bounce)) return 1;
    return 2;
}

// `contact_count / 2 + 2` bodies, body `j` on movement row `j`, with nonzero velocities of
// mixed sign; the contacts carry correct movement hints and are written in
// `order * stride mod contact_count` order. The observer is body 0.
fn buildStageFixture(allocator: std.mem.Allocator, contact_count: usize) !StageFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const body_count = contact_count / 2 + 2;
    for (0..body_count) |body| {
        const x: f32 = @floatFromInt((body % 256) * 4);
        const y: f32 = @floatFromInt((body / 256) * 4);
        const speed_x: f32 = 10.0 + @as(f32, @floatFromInt(body % 7));
        const speed_y: f32 = 8.0 + @as(f32, @floatFromInt(body % 5));
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{
            .position = .{ .x = x, .y = y },
            .previous_position = .{ .x = x, .y = y },
            .velocity = .{
                .x = if (body % 2 == 0) speed_x else -speed_x,
                .y = if (body % 3 == 0) -speed_y else speed_y,
            },
            .speed = 0,
        });
        try data.setCollisionResponse(entity, stageBodyResponse(body));
    }
    const entities = data.movementBodySliceConst().entities;
    std.debug.assert(entities.len == body_count);
    for (entities, 0..) |entity, row| {
        std.debug.assert(data.movementBodyDenseIndex(entity).? == row);
    }

    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(1, 0, 0, contact_count, contact_count, 0);
    var writer = try fixtures.beginOneRange(CollisionContact, &frame.contacts, contact_count);
    const stride = fixtures.coprimeStride(stage_scatter_stride_seed, contact_count);
    var expected_intents: usize = 0;
    var expected_triggers: usize = 0;
    var expected_observer_contacts: usize = 0;
    for (0..contact_count) |order| {
        const index = order * stride % contact_count;
        const bodies = stageContactBodies(index);
        const normal = stageContactNormal(index);
        writer.write(.{
            .a = entities[bodies[0]],
            .b = entities[bodies[1]],
            .a_movement_index = bodies[0],
            .b_movement_index = bodies[1],
            .normal_x = normal[0],
            .normal_y = normal[1],
            .penetration = @as(f32, @floatFromInt(index % 5 + 1)) * 0.25,
        });
        if (bodies[0] == 0) expected_observer_contacts += 1;
        const a_response = stageBodyResponse(bodies[0]);
        const b_response = stageBodyResponse(bodies[1]);
        if (a_response.mode == .trigger or b_response.mode == .trigger) {
            expected_triggers += 1;
        } else {
            expected_intents += stageExpectedIntents(a_response, b_response);
        }
    }
    writer.finish();
    frame.contacts.finishWrite();
    std.debug.assert(frame.contacts.mergedItems().len == contact_count);

    const movement = data.movementBodySliceConst();
    const position_x = try allocator.dupe(f32, movement.position_x);
    errdefer allocator.free(position_x);
    const position_y = try allocator.dupe(f32, movement.position_y);
    errdefer allocator.free(position_y);
    const velocity_x = try allocator.dupe(f32, movement.velocity_x);
    errdefer allocator.free(velocity_x);
    const velocity_y = try allocator.dupe(f32, movement.velocity_y);

    return .{
        .data = data,
        .frame = frame,
        .observer = entities[0],
        .expected_intents = expected_intents,
        .expected_triggers = expected_triggers,
        .expected_observer_contacts = expected_observer_contacts,
        .position_x = position_x,
        .position_y = position_y,
        .velocity_x = velocity_x,
        .velocity_y = velocity_y,
    };
}

fn stageRunOnce(
    system: *CollisionResponseSystem,
    fixture: *StageFixture,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) !CollisionResponseStats {
    const stats = try system.update(&fixture.data, &fixture.frame, fixture.observer, thread_system, .{
        .items_per_range = case.stageItemsPerRange(movement_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
    std.debug.assert(stats.contact_count == fixture.frame.contacts.mergedItems().len);
    std.debug.assert(stats.intent_count == fixture.expected_intents);
    std.debug.assert(stats.trigger_count == fixture.expected_triggers);
    std.debug.assert(fixture.frame.collision_triggers.mergedItems().len == fixture.expected_triggers);
    std.debug.assert(stats.observer_contact_count == fixture.expected_observer_contacts);
    std.debug.assert(system.observerContacts(&fixture.frame, fixture.observer).len == fixture.expected_observer_contacts);
    return stats;
}

// An inline-settled gather never dispatches the apply, so its tuner settles alone.
fn stageTunersSettled(system: *const CollisionResponseSystem) bool {
    const gather = &system.gather_tuner;
    return (gather.phase == .settled) and (!gather.has_threaded_profile or (system.apply_tuner.phase == .settled));
}

fn runStageCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var fixture = try buildStageFixture(allocator, item_count);
    defer fixture.deinit(allocator);
    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    try system.reserveForContacts(item_count);
    if (suite.adaptiveTunerForCase(case, movement_range_alignment_items)) |tuner| {
        system.gather_tuner = tuner;
        // Apply: one band per range, so the fixed control dispatches the bands rather than
        // keeping them in one inline range.
        system.apply_tuner = suite.adaptiveTunerForPartition(case, 1, 1).?;
    }

    // A fixed threaded case with more than one range of contacts dispatches the gather.
    const expect_dispatch = !case.adaptive and thread_ptr.workerThreadCount() > 0 and item_count > case.fixedItemsPerRange(movement_range_alignment_items);

    var warm = suite.Warmup.init(options, case, 1);
    while (warm.next(stageTunersSettled(&system))) {
        fixture.restoreMovement();
        _ = try stageRunOnce(&system, &fixture, thread_ptr, case);
    }
    const settled_before_measurement = if (case.adaptive) stageTunersSettled(&system) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    var last_stats = CollisionResponseStats{};
    for (0..options.iterations) |_| {
        fixture.restoreMovement();
        const start_ns = suite.nowNs(io);
        last_stats = try stageRunOnce(&system, &fixture, thread_ptr, case);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        std.debug.assert(!expect_dispatch or (last_stats.gather_batch.range_count > 1 and !last_stats.gather_batch.ran_inline));
        accumulator.record(elapsed_ns, last_stats.gather_batch);
        // Main outside the stage batches: the main thread's own ranges inside a
        // dispatched batch are not counted (see the batch's `main_ranges`).
        main_total += elapsed_ns -| offMainNs(last_stats.gather_batch) -| offMainNs(last_stats.apply_batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_stats.trigger_count;
    stats.output_count = last_stats.intent_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_stats.apply_batch);
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&system.gather_tuner), settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(suite.tunerReport(&system.apply_tuner), settled_before_measurement);
    }
    return stats;
}

fn writeResponseStageWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("intents={} triggers={}", .{ stats.output_count, stats.candidate_pairs });
    if (view == .summary) return;
    try writer.writeAll(" gather=");
    try suite.writeStageShape(writer, stats.batch);
    try writer.writeAll(" apply=");
    try suite.writeStageShape(writer, stats.secondary_batch orelse .{});
    try suite.writeShare(writer, "main_outside_stage_batches", stats.main_ns orelse 0, stats.mean_ns);
}
