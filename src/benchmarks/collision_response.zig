// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
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
    if (case.usesThreadSystem()) return suite.RunStats.skipped("collision response v1 has deterministic serial apply");

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
        last_stats = try system.update(&fixture.data, &fixture.frame);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), suite.serialBatch(item_count, movement_range_alignment_items));
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_stats.trigger_count;
    stats.output_count = last_stats.intent_count;
    return stats;
}

fn runOnce(system: *CollisionResponseSystem, fixture: *Fixture, mode: FixtureMode) !CollisionResponseStats {
    prepareFrameForRun(fixture, mode);
    return try system.update(&fixture.data, &fixture.frame);
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

test "collision response benchmark fixture creates requested contacts" {
    var fixture = try createSolidFixture(std.testing.allocator, 32);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 64), fixture.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 64), fixture.data.collisionResponseSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 32), fixture.frame.contacts.mergedItems().len);
}

test "collision response benchmark mixed fixture includes triggers and physical intents" {
    var fixture = try createMixedFixture(std.testing.allocator, 16);
    defer fixture.deinit();
    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();

    const stats = try runOnce(&system, &fixture, .mixed);

    try std.testing.expectEqual(@as(usize, 16), stats.contact_count);
    try std.testing.expect(stats.intent_count > 0);
    try std.testing.expect(stats.trigger_count > 0);
}

test "collision response benchmark tiny serial case runs without display" {
    const options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    const stats = try runSolidCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 10_000);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 10_000), stats.output_count);
}

test "collision response benchmark skips threaded cases until response apply has a merge phase" {
    const options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    const stats = try runSolidCase(std.testing.allocator, std.testing.io, options, suite.default_cases[1], 10_000);
    try std.testing.expectEqual(suite.RunStatus.skipped, stats.status);
}

test "collision response benchmark profiles sweep shared event scale counts" {
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.quick), defaultItemCounts(.quick));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.standard), defaultItemCounts(.standard));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.stress), defaultItemCounts(.stress));
}
