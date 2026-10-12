// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const inlineBatch = @import("../app/thread_system.zig").inlineBatch;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const CollisionResponse = @import("../game/data_system.zig").CollisionResponse;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const movement_range_alignment_items = @import("../game/data_system.zig").movement_range_alignment_items;
const CollisionResponseStats = @import("../game/systems/collision_response.zig").CollisionResponseStats;
const CollisionResponseSystem = @import("../game/systems/collision_response.zig").CollisionResponseSystem;
const simulation = @import("../game/simulation.zig");
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const suite = @import("suite.zig");

pub const solid_group = suite.BenchmarkGroup{
    .name = "collision-response-solid",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runSolidCase,
};

pub const bounce_group = suite.BenchmarkGroup{
    .name = "collision-response-bounce",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runBounceCase,
};

pub const trigger_group = suite.BenchmarkGroup{
    .name = "collision-response-trigger",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runTriggerCase,
};

pub const mixed_group = suite.BenchmarkGroup{
    .name = "collision-response-mixed",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runMixedCase,
};

const FixtureMode = enum {
    solid_static,
    bounce_static,
    trigger_only,
    mixed,
};

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,

    fn deinit(self: *Fixture) void {
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createSolidFixture(allocator: std.mem.Allocator, contact_count: usize) !Fixture {
    return createFixture(allocator, contact_count, .solid_static);
}

pub fn createMixedFixture(allocator: std.mem.Allocator, contact_count: usize) !Fixture {
    return createFixture(allocator, contact_count, .mixed);
}

fn runSolidCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .solid_static);
}

fn runBounceCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .bounce_static);
}

fn runTriggerCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .trigger_only);
}

fn runMixedCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .mixed);
}

fn runCaseWithMode(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, mode: FixtureMode) !suite.RunStats {
    if (case.usesThreadSystem()) return suite.RunStats.skipped("threaded response is benched by collision-response-stage");

    var fixture = try createFixture(allocator, item_count, mode);
    defer fixture.deinit();
    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, &fixture, mode);
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = CollisionResponseStats{};
    for (0..options.iterations) |_| {
        prepareFrameForRun(&fixture, mode);
        const start_ns = suite.nowNs(io);
        last_stats = try system.updateSerial(&fixture.data, &fixture.frame, EntityId.invalid);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), inlineBatch(item_count, movement_range_alignment_items));
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_stats.trigger_count;
    stats.output_count = last_stats.intent_count;
    return stats;
}

fn runOnce(system: *CollisionResponseSystem, fixture: *Fixture, mode: FixtureMode) !CollisionResponseStats {
    prepareFrameForRun(fixture, mode);
    return try system.updateSerial(&fixture.data, &fixture.frame, EntityId.invalid);
}

fn prepareFrameForRun(fixture: *Fixture, mode: FixtureMode) void {
    if (mode == .trigger_only or mode == .mixed) {
        fixture.frame.collision_triggers.clearRetainingCapacity();
    }
}

fn createFixture(allocator: std.mem.Allocator, contact_count: usize, mode: FixtureMode) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(1, 0, 0, contact_count, contact_count, 0);

    try frame.contacts.prepareRangeCounts(1);
    frame.contacts.addCount(0, contact_count);
    try frame.contacts.prefix();
    var writer = frame.contacts.rangeWriter(0);
    for (0..contact_count) |index| {
        const pair = try addContactPair(&data, index, mode);
        writer.write(.{
            .a = pair.a,
            .b = pair.b,
            .a_movement_index = data.movementBodyDenseIndex(pair.a).?,
            .b_movement_index = data.movementBodyDenseIndex(pair.b).?,
            .normal_x = if (index % 2 == 0) @as(f32, -1) else @as(f32, 0),
            .normal_y = if (index % 2 == 0) @as(f32, 0) else @as(f32, -1),
            .penetration = @as(f32, @floatFromInt((index % 5) + 1)),
        });
    }
    writer.finish();
    frame.contacts.finishWrite();

    return .{ .data = data, .frame = frame };
}

const ContactPair = struct {
    a: EntityId,
    b: EntityId,
};

fn addContactPair(data: *DataSystem, index: usize, mode: FixtureMode) !ContactPair {
    return switch (mode) {
        .solid_static => addPhysicalPair(data, index, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 }, .{ .mode = .solid, .mobility = .static, .restitution = 0 }),
        .bounce_static => addPhysicalPair(data, index, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 }, .{ .mode = .solid, .mobility = .static, .restitution = 0 }),
        .trigger_only => addPhysicalPair(data, index, .{ .mode = .trigger, .mobility = .static, .restitution = 0 }, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 }),
        .mixed => switch (index % 4) {
            0 => addPhysicalPair(data, index, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 }, .{ .mode = .solid, .mobility = .static, .restitution = 0 }),
            1 => addPhysicalPair(data, index, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 }, .{ .mode = .solid, .mobility = .static, .restitution = 0 }),
            2 => addPhysicalPair(data, index, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 }, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 }),
            else => addPhysicalPair(data, index, .{ .mode = .trigger, .mobility = .static, .restitution = 0 }, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 }),
        },
    };
}

fn addPhysicalPair(
    data: *DataSystem,
    index: usize,
    a_response: CollisionResponse,
    b_response: CollisionResponse,
) !ContactPair {
    const base_x: f32 = @floatFromInt((index % 512) * 4);
    const base_y: f32 = @floatFromInt((index / 512) * 4);
    const a = try addEntity(data, base_x, base_y, 20, -12, a_response);
    const b = try addEntity(data, base_x + 2, base_y + 2, -18, 10, b_response);
    return .{ .a = a, .b = b };
}

fn addEntity(data: *DataSystem, position_x: f32, position_y: f32, velocity_x: f32, velocity_y: f32, response: CollisionResponse) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = position_x, .y = position_y },
        .previous_position = .{ .x = position_x, .y = position_y },
        .velocity = .{ .x = velocity_x, .y = velocity_y },
        .speed = 0,
    });
    try data.setCollisionResponse(entity, response);
    return entity;
}

// `collision-response-stage`: one response step over a contact stream where every body
// sits in several contacts as `a` and as `b`, written once in a scattered order. Timed:
// one `update`; the movement columns are restored untimed before each run so every run
// takes the same branch mix. `--details` reports intents, triggers, the gather and
// apply shapes, and the time and share on main outside the stage batches.
pub const stage_group = suite.BenchmarkGroup{
    .name = "collision-response-stage",
    .defaultItemCounts = stageItemCounts,
    .runCase = runStageCase,
};

const stage_item_counts = [_]usize{ 1_024, 4_096, 16_384 };
// First stride tried for the scattered contact order; stepped by 2 until coprime with
// the contact count so the order visits every contact once.
const stage_scatter_stride_seed: usize = 7_919;
const stage_bounce_restitution: f32 = 0.5;

fn stageItemCounts(_: suite.Profile) []const usize {
    return &stage_item_counts;
}

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

fn stageScatterStride(count: usize) usize {
    if (count <= 1) return 1;
    var stride = stage_scatter_stride_seed;
    while (std.math.gcd(stride, count) != 1) stride += 2;
    return stride;
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
    try frame.contacts.prepareRangeCounts(1);
    frame.contacts.addCount(0, contact_count);
    try frame.contacts.prefix();
    var writer = frame.contacts.rangeWriter(0);
    const stride = stageScatterStride(contact_count);
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
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) !CollisionResponseStats {
    const stats = if (thread_system) |threads|
        try system.update(&fixture.data, &fixture.frame, fixture.observer, threads, .{
            .items_per_range = stageItemsPerRange(case),
            .max_worker_threads = case.maxWorkerThreads(),
            .adaptive = case.adaptive,
        })
    else
        try system.updateSerial(&fixture.data, &fixture.frame, fixture.observer);
    std.debug.assert(stats.contact_count == fixture.frame.contacts.mergedItems().len);
    std.debug.assert(stats.intent_count == fixture.expected_intents);
    std.debug.assert(stats.trigger_count == fixture.expected_triggers);
    std.debug.assert(fixture.frame.collision_triggers.mergedItems().len == fixture.expected_triggers);
    std.debug.assert(stats.observer_contact_count == fixture.expected_observer_contacts);
    std.debug.assert(system.observerContacts(&fixture.frame, fixture.observer).len == fixture.expected_observer_contacts);
    return stats;
}

fn stageItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(movement_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, movement_range_alignment_items);
}

// The fixed-range adaptive case's apply tuner: one band per range, so the fixed control
// dispatches the bands rather than keeping them in one inline range.
fn stageBandTunerForCase(case: suite.BenchmarkCase) ?AdaptiveWorkTuner {
    if (!case.adaptive or case.adaptive_range_mode != .fixed) return null;
    return AdaptiveWorkTuner.init(.{ .initial_range_items = 1, .smallest_range_items = 1, .largest_range_items = 1 });
}

// An inline-settled gather never dispatches the apply, so its tuner settles alone.
fn stageTunersSettled(system: *const CollisionResponseSystem) bool {
    const gather = &system.gather_tuner;
    return gather.isSettled() and (!gather.report().has_threaded_profile or system.apply_tuner.isSettled());
}

fn runStageCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    var fixture = try buildStageFixture(allocator, item_count);
    defer fixture.deinit(allocator);
    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    try system.reserveForContacts(item_count);
    if (suite.adaptiveTunerForCase(case, movement_range_alignment_items)) |tuner| {
        system.gather_tuner = tuner;
        system.apply_tuner = stageBandTunerForCase(case).?;
    }

    // A fixed threaded case with more than one range of contacts dispatches the gather.
    const expect_dispatch = if (thread_ptr) |thread_system|
        !case.adaptive and thread_system.workerThreadCount() > 0 and item_count > stageItemsPerRange(case).?
    else
        false;

    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| {
        fixture.restoreMovement();
        _ = try stageRunOnce(&system, &fixture, thread_ptr, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!stageTunersSettled(&system) and settle_guard < settle_limit) : (settle_guard += 1) {
            fixture.restoreMovement();
            _ = try stageRunOnce(&system, &fixture, thread_ptr, case);
        }
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
    if (stats.iterations > 0) {
        stats.terrain_edit_phases = .{ .main_ns = @intCast(main_total / stats.iterations) };
    }
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.gather_tuner.report(), settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.apply_tuner.report(), settled_before_measurement);
    }
    return stats;
}
