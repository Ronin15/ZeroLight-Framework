// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const CollisionResponse = @import("../data_system.zig").CollisionResponse;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const MovementBodySlice = @import("../data_system.zig").MovementBodySlice;
const hot_soa_column_alignment = @import("../data_system.zig").hot_soa_column_alignment;
const CollisionContact = @import("../simulation.zig").CollisionContact;
const CollisionTriggerEvent = @import("../simulation.zig").CollisionTriggerEvent;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const simd = @import("../../core/simd.zig");

const collision_response_range_alignment_items: usize = hot_soa_column_alignment / @sizeOf(f32);

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, collision_response_range_alignment_items);
}

const ResponseIntentKind = enum {
    solid,
    bounce,
};

const IntentRow = struct {
    entity: EntityId,
    movement_index: usize,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
    restitution: f32,
    correction_x: f32,
    correction_y: f32,
    velocity_scale: f32,
    kind: ResponseIntentKind,
};

fn appendIntentRow(
    rows: *std.MultiArrayList(IntentRow),
    row_slice: *std.MultiArrayList(IntentRow).Slice,
    row: IntentRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

pub const CollisionResponseStats = struct {
    contact_count: usize = 0,
    intent_count: usize = 0,
    trigger_count: usize = 0,
};

/// Worst-case `collision_triggers` stream capacity for a given `contact_capacity` — this
/// module's own domain knowledge (a trigger event requires an underlying contact, so
/// trigger count can never exceed contact count), not a ratio a caller sizing
/// `SimulationFrame.reserveStreams` should independently guess.
pub fn estimateTriggerCapacity(contact_capacity: usize) usize {
    return contact_capacity;
}

pub const CollisionResponseSystem = struct {
    allocator: std.mem.Allocator,
    intent_rows: std.MultiArrayList(IntentRow) = .{},
    intent_row_slice: std.MultiArrayList(IntentRow).Slice = .empty,
    trigger_pairs: std.ArrayList(CollisionTriggerEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) CollisionResponseSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CollisionResponseSystem) void {
        self.trigger_pairs.deinit(self.allocator);
        self.intent_rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consumes the completed same-step sorted contact stream after
    /// CollisionSystem broadphase/narrowphase contact generation has finished.
    /// Dense movement indices are fast-path hints; release builds revalidate
    /// before writing.
    pub fn update(self: *CollisionResponseSystem, data: *DataSystem, frame: *SimulationFrame) !CollisionResponseStats {
        const contacts = frame.contacts.mergedItems();
        self.clearIntentsRetainingCapacity();
        try self.ensureIntentCapacity(contacts.len * 2);
        try self.ensureTriggerCapacity(contacts.len);
        self.intent_row_slice = self.intent_rows.slice();
        frame.collision_triggers.clearRetainingCapacity();
        const trigger_count = try self.gatherIntentsAndEvents(data, frame, contacts);
        self.computeIntentMathSimd();
        self.applyIntents(data);
        return .{
            .contact_count = contacts.len,
            .intent_count = self.intent_rows.len,
            .trigger_count = trigger_count,
        };
    }

    pub fn reserveForContacts(self: *CollisionResponseSystem, max_contacts: usize) !void {
        try self.ensureIntentCapacity(max_contacts * 2);
        try self.ensureTriggerCapacity(max_contacts);
    }

    fn gatherIntentsAndEvents(
        self: *CollisionResponseSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        contacts: []const CollisionContact,
    ) !usize {
        var trigger_count: usize = 0;
        for (contacts) |contact| {
            const a_response = data.collisionResponseConst(contact.a) orelse continue;
            const b_response = data.collisionResponseConst(contact.b) orelse continue;
            if (a_response.mode == .trigger or b_response.mode == .trigger) {
                self.trigger_pairs.appendAssumeCapacity(.{ .a = contact.a, .b = contact.b });
                trigger_count += 1;
                continue;
            }
            self.gatherPhysicalIntents(contact, a_response, b_response);
        }

        if (trigger_count > 0) {
            try frame.collision_triggers.prepareRangeCounts(1);
            frame.collision_triggers.addCount(0, trigger_count);
            try frame.collision_triggers.prefix();
            var writer = frame.collision_triggers.rangeWriter(0);
            for (self.trigger_pairs.items) |trigger| {
                writer.write(trigger);
            }
            writer.finish();
            frame.collision_triggers.finishWrite();
        }

        return trigger_count;
    }

    fn gatherPhysicalIntents(
        self: *CollisionResponseSystem,
        contact: CollisionContact,
        a_response: CollisionResponse,
        b_response: CollisionResponse,
    ) void {
        const a_dynamic = a_response.mobility == .dynamic;
        const b_dynamic = b_response.mobility == .dynamic;
        if (!a_dynamic and !b_dynamic) return;

        if (a_dynamic and !b_dynamic) {
            self.appendIntentAssumeCapacity(contact.a, contact.a_movement_index, contact.normal_x, contact.normal_y, contact.penetration, a_response);
            return;
        }
        if (!a_dynamic and b_dynamic) {
            self.appendIntentAssumeCapacity(contact.b, contact.b_movement_index, -contact.normal_x, -contact.normal_y, contact.penetration, b_response);
            return;
        }

        if (a_response.mode == .bounce and b_response.mode != .bounce) {
            self.appendIntentAssumeCapacity(contact.a, contact.a_movement_index, contact.normal_x, contact.normal_y, contact.penetration, a_response);
            return;
        }
        if (b_response.mode == .bounce and a_response.mode != .bounce) {
            self.appendIntentAssumeCapacity(contact.b, contact.b_movement_index, -contact.normal_x, -contact.normal_y, contact.penetration, b_response);
            return;
        }

        const split_penetration = contact.penetration * 0.5;
        self.appendIntentAssumeCapacity(contact.a, contact.a_movement_index, contact.normal_x, contact.normal_y, split_penetration, a_response);
        self.appendIntentAssumeCapacity(contact.b, contact.b_movement_index, -contact.normal_x, -contact.normal_y, split_penetration, b_response);
    }

    fn appendIntentAssumeCapacity(
        self: *CollisionResponseSystem,
        entity: EntityId,
        movement_index: usize,
        normal_x: f32,
        normal_y: f32,
        penetration: f32,
        response: CollisionResponse,
    ) void {
        appendIntentRow(&self.intent_rows, &self.intent_row_slice, .{
            .entity = entity,
            .movement_index = movement_index,
            .normal_x = normal_x,
            .normal_y = normal_y,
            .penetration = penetration,
            .restitution = response.restitution,
            .correction_x = 0,
            .correction_y = 0,
            .velocity_scale = 0,
            .kind = if (response.mode == .bounce) .bounce else .solid,
        });
    }

    fn computeIntentMathSimd(self: *CollisionResponseSystem) void {
        const count = self.intent_rows.len;
        if (count == 0) return;

        const s = self.intent_rows.slice();
        const normal_x = s.items(.normal_x);
        const normal_y = s.items(.normal_y);
        const penetration = s.items(.penetration);
        const restitution = s.items(.restitution);
        const correction_x = s.items(.correction_x);
        const correction_y = s.items(.correction_y);
        const velocity_scale = s.items(.velocity_scale);

        var index: usize = 0;
        const negative_one = simd.splatFloat4(-1);
        while (index + simd.lane_count <= count) : (index += simd.lane_count) {
            const normal_x_lanes = simd.loadFloat4(normal_x[index..]);
            const normal_y_lanes = simd.loadFloat4(normal_y[index..]);
            const penetration_lanes = simd.loadFloat4(penetration[index..]);
            const restitution_lanes = simd.loadFloat4(restitution[index..]);
            simd.storeFloat4Slice(correction_x[index..], simd.mulFloat4(normal_x_lanes, penetration_lanes));
            simd.storeFloat4Slice(correction_y[index..], simd.mulFloat4(normal_y_lanes, penetration_lanes));
            simd.storeFloat4Slice(velocity_scale[index..], simd.mulFloat4(restitution_lanes, negative_one));
        }

        while (index < count) : (index += 1) {
            correction_x[index] = normal_x[index] * penetration[index];
            correction_y[index] = normal_y[index] * penetration[index];
            velocity_scale[index] = -restitution[index];
        }
    }

    fn applyIntents(self: *CollisionResponseSystem, data: *DataSystem) void {
        const count = self.intent_rows.len;
        if (count == 0) return;

        const s = self.intent_rows.slice();
        const entities = s.items(.entity);
        const movement_indices = s.items(.movement_index);
        const normal_x = s.items(.normal_x);
        const normal_y = s.items(.normal_y);
        const correction_x = s.items(.correction_x);
        const correction_y = s.items(.correction_y);
        const velocity_scale = s.items(.velocity_scale);
        const kinds = s.items(.kind);

        var movement = data.movementBodySlice();
        for (0..count) |index| {
            const movement_index = movementIndexForIntent(data, movement, entities[index], movement_indices[index]) orelse continue;
            movement.position_x[movement_index] += correction_x[index];
            movement.position_y[movement_index] += correction_y[index];
            if (shouldApplyNormalVelocityResponse(movement.velocity_x[movement_index], normal_x[index])) {
                switch (kinds[index]) {
                    .solid => movement.velocity_x[movement_index] = 0,
                    .bounce => movement.velocity_x[movement_index] *= velocity_scale[index],
                }
            }
            if (shouldApplyNormalVelocityResponse(movement.velocity_y[movement_index], normal_y[index])) {
                switch (kinds[index]) {
                    .solid => movement.velocity_y[movement_index] = 0,
                    .bounce => movement.velocity_y[movement_index] *= velocity_scale[index],
                }
            }
        }
    }

    fn clearIntentsRetainingCapacity(self: *CollisionResponseSystem) void {
        self.intent_rows.clearRetainingCapacity();
        self.trigger_pairs.clearRetainingCapacity();
    }

    fn ensureIntentCapacity(self: *CollisionResponseSystem, capacity: usize) !void {
        try self.intent_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(capacity));
    }

    fn ensureTriggerCapacity(self: *CollisionResponseSystem, capacity: usize) !void {
        try self.trigger_pairs.ensureTotalCapacity(self.allocator, capacity);
    }
};

fn movementIndexForIntent(data: *const DataSystem, movement: MovementBodySlice, entity: EntityId, cached_index: usize) ?usize {
    if (cached_index < movement.entities.len and movement.entities[cached_index].eql(entity)) {
        return cached_index;
    }
    return data.movementBodyDenseIndex(entity);
}

fn shouldApplyNormalVelocityResponse(velocity: f32, normal: f32) bool {
    return normal != 0 and velocity * normal < 0;
}

fn addEntity(
    data: *DataSystem,
    position_x: f32,
    position_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    response: CollisionResponse,
) !EntityId {
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

fn makeContact(a: EntityId, b: EntityId, a_index: usize, b_index: usize, normal_x: f32, normal_y: f32, penetration: f32) CollisionContact {
    return .{
        .a = a,
        .b = b,
        .a_movement_index = a_index,
        .b_movement_index = b_index,
        .normal_x = normal_x,
        .normal_y = normal_y,
        .penetration = penetration,
    };
}

fn writeContacts(frame: *SimulationFrame, contacts: []const CollisionContact) !void {
    try frame.contacts.prepareRangeCounts(1);
    frame.contacts.addCount(0, contacts.len);
    try frame.contacts.prefix();
    var writer = frame.contacts.rangeWriter(0);
    for (contacts) |contact| writer.write(contact);
    writer.finish();
    frame.contacts.finishWrite();
}

test "solid dynamic response separates from static and stops normal velocity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, 50, 7, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 3)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try system.update(&data, &frame);

    try std.testing.expectEqual(@as(usize, 1), stats.intent_count);
    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectEqual(@as(f32, 7), body.velocity.y);
    try std.testing.expectEqual(@as(f32, 0), body.velocity.x);
    try std.testing.expectApproxEqAbs(@as(f32, 7), body.position.x, 0.001);
}

test "bounce dynamic response reflects normal velocity by restitution" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, 20, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 0.5 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 4)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try system.update(&data, &frame);

    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectApproxEqAbs(@as(f32, 6), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -10), body.velocity.x, 0.001);
}

test "bounce response preserves separating normal velocity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, -20, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 0.5 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 4)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try system.update(&data, &frame);

    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectApproxEqAbs(@as(f32, 6), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -20), body.velocity.x, 0.001);
}

test "solid response preserves separating normal velocity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, -15, 3, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 3)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try system.update(&data, &frame);

    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectApproxEqAbs(@as(f32, 7), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -15), body.velocity.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), body.velocity.y, 0.001);
}

test "solid versus bounce dynamic pair gives response to bounce entity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const solid = try addEntity(&data, 10, 20, 0, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const bounce = try addEntity(&data, 14, 20, -12, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(solid, bounce, data.movementBodyDenseIndex(solid).?, data.movementBodyDenseIndex(bounce).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try system.update(&data, &frame);

    const solid_body = data.movementBodyConst(solid).?;
    const bounce_body = data.movementBodyConst(bounce).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), solid_body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16), bounce_body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12), bounce_body.velocity.x, 0.001);
}

test "trigger response emits event without physical correction" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const trigger = try addEntity(&data, 10, 20, 5, 0, .{ .mode = .trigger, .mobility = .static, .restitution = 0 });
    const dynamic = try addEntity(&data, 14, 20, 5, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(trigger, dynamic, data.movementBodyDenseIndex(trigger).?, data.movementBodyDenseIndex(dynamic).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);
    try frame.events.prepareRangeCounts(1);
    frame.events.addCount(0, 1);
    try frame.events.prefix();
    var event_writer = frame.events.rangeWriter(0);
    event_writer.write(.{ .stage = .structural_commit, .payload = .{ .entity_created = trigger } });
    event_writer.finish();
    frame.events.finishWrite();

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try system.update(&data, &frame);

    try std.testing.expectEqual(@as(usize, 0), stats.intent_count);
    try std.testing.expectEqual(@as(usize, 1), stats.trigger_count);
    try std.testing.expectEqual(@as(usize, 1), frame.events.mergedItems().len);
    try std.testing.expect(trigger.eql(frame.events.mergedItems()[0].payload.entity_created));
    try std.testing.expectEqual(@as(usize, 1), frame.collision_triggers.mergedItems().len);
    try std.testing.expect(trigger.eql(frame.collision_triggers.mergedItems()[0].a));
    try std.testing.expect(dynamic.eql(frame.collision_triggers.mergedItems()[0].b));
    try std.testing.expectEqual(@as(f32, 14), data.movementBodyConst(dynamic).?.position.x);
}

test "response remaps stale cached movement index before writing" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const target = try addEntity(&data, 10, 20, 10, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const wrong = try addEntity(&data, 50, 20, 0, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    const wrong_before = data.movementBodyConst(wrong).?;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(target, static, data.movementBodyDenseIndex(wrong).?, data.movementBodyDenseIndex(static).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try system.update(&data, &frame);

    const target_after = data.movementBodyConst(target).?;
    const wrong_after = data.movementBodyConst(wrong).?;
    try std.testing.expectApproxEqAbs(@as(f32, 8), target_after.position.x, 0.001);
    try std.testing.expectApproxEqAbs(wrong_before.position.x, wrong_after.position.x, 0.001);
    try std.testing.expectApproxEqAbs(wrong_before.velocity.x, wrong_after.velocity.x, 0.001);
}

test "warmed response update does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const trigger = try addEntity(&data, 10, 20, 0, 0, .{ .mode = .trigger, .mobility = .static, .restitution = 0 });
    const dynamic = try addEntity(&data, 14, 20, 5, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 1, 1, 0);
    const contacts = [_]CollisionContact{makeContact(trigger, dynamic, data.movementBodyDenseIndex(trigger).?, data.movementBodyDenseIndex(dynamic).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserveForContacts(1);

    const original_system_allocator = system.allocator;
    const original_trigger_allocator = frame.collision_triggers.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    system.allocator = fail;
    frame.collision_triggers.allocator = fail;
    defer {
        system.allocator = original_system_allocator;
        frame.collision_triggers.allocator = original_trigger_allocator;
    }

    const stats = try system.update(&data, &frame);

    try std.testing.expectEqual(@as(usize, 1), stats.trigger_count);
    try std.testing.expectEqual(@as(usize, 1), frame.collision_triggers.mergedItems().len);
}

test "serial response math uses simd chunks and scalar tails" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const static = try addEntity(&data, 100, 0, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var dynamics: [simd.lane_count + 1]EntityId = undefined;
    var contacts: [simd.lane_count + 1]CollisionContact = undefined;
    for (&dynamics, 0..) |*entity, index| {
        entity.* = try addEntity(&data, @floatFromInt(index * 10), 0, 10, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 });
        contacts[index] = makeContact(entity.*, static, data.movementBodyDenseIndex(entity.*).?, data.movementBodyDenseIndex(static).?, -1, 0, @floatFromInt(index + 1));
    }
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try system.update(&data, &frame);

    try std.testing.expectEqual(@as(usize, simd.lane_count + 1), stats.intent_count);
    try std.testing.expectEqual(@as(usize, simd.lane_count), simd.vectorizedEnd(stats.intent_count));
    try std.testing.expectEqual(@as(usize, 1), simd.tailLen(stats.intent_count));
    for (dynamics, 0..) |entity, index| {
        const body = data.movementBodyConst(entity).?;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(index * 10)) - @as(f32, @floatFromInt(index + 1)), body.position.x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, -10), body.velocity.x, 0.001);
    }
}
