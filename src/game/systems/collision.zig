// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const thread_mod = @import("../../app/thread_system.zig");
const ThreadSystem = thread_mod.ThreadSystem;
const ParallelRange = thread_mod.ParallelRange;
const AdaptiveRangeTuner = thread_mod.AdaptiveRangeTuner;
const AdaptiveThreadCount = thread_mod.AdaptiveThreadCount;
const data_mod = @import("../data_system.zig");
const DataSystem = data_mod.DataSystem;
const EntityId = data_mod.EntityId;
const simd = @import("../../core/simd.zig");
const simulation = @import("../simulation.zig");
const CollisionContact = simulation.CollisionContact;
const RangeOutputStream = simulation.RangeOutputStream;

pub const collision_range_alignment_items: usize = data_mod.movement_range_alignment_items;

const HotF32List = std.ArrayListAligned(f32, .fromByteUnits(data_mod.hot_soa_column_alignment));

pub const CollisionConfig = struct {
    min_parallel_items: ?usize = null,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_thread_count: ?*AdaptiveThreadCount = null,
    range_tuner: ?*AdaptiveRangeTuner = null,
    full_sort_disorder_percent: u8 = 12,
};

pub const CollisionStats = struct {
    body_count: usize = 0,
    contact_count: usize = 0,
    candidate_pair_count: usize = 0,
    count_batch: thread_mod.BatchStats = .{},
    write_batch: thread_mod.BatchStats = .{},
    used_full_sort: bool = false,
};

pub const CollisionSystem = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(EntityId) = .empty,
    movement_indices: std.ArrayList(usize) = .empty,
    min_x: HotF32List = .empty,
    min_y: HotF32List = .empty,
    max_x: HotF32List = .empty,
    max_y: HotF32List = .empty,
    order: std.ArrayList(usize) = .empty,
    candidate_counts: std.ArrayList(usize) = .empty,
    range_tuner: AdaptiveRangeTuner = AdaptiveRangeTuner.init(.{}),
    adaptive_thread_count: AdaptiveThreadCount = .{},

    pub fn init(allocator: std.mem.Allocator) CollisionSystem {
        return .{
            .allocator = allocator,
            .range_tuner = AdaptiveRangeTuner.init(.{}),
            .adaptive_thread_count = .{},
        };
    }

    pub fn deinit(self: *CollisionSystem) void {
        self.candidate_counts.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.max_y.deinit(self.allocator);
        self.max_x.deinit(self.allocator);
        self.min_y.deinit(self.allocator);
        self.min_x.deinit(self.allocator);
        self.movement_indices.deinit(self.allocator);
        self.entities.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
        thread_system: *ThreadSystem,
        config: CollisionConfig,
    ) !CollisionStats {
        try self.gatherBodies(data);
        const body_count = self.entities.items.len;
        if (body_count <= 1) {
            contacts.clearRetainingCapacity();
            return .{ .body_count = body_count };
        }

        const used_full_sort = self.sortWarm(config.full_sort_disorder_percent);

        var system_config = config;
        if (system_config.items_per_range == null and system_config.range_tuner == null) {
            system_config.range_tuner = &self.range_tuner;
        }
        if (system_config.adaptive and system_config.adaptive_thread_count == null) {
            system_config.adaptive_thread_count = &self.adaptive_thread_count;
        }

        const active_tuner = if (system_config.items_per_range == null) system_config.range_tuner else null;
        const items_per_range = if (active_tuner) |tuner|
            tuner.itemsPerRange(body_count, collision_range_alignment_items)
        else
            system_config.items_per_range orelse thread_system.config.items_per_range;
        const aligned_items_per_range = thread_mod.alignItemCount(@max(items_per_range, @as(usize, 1)), collision_range_alignment_items);
        const range_count = thread_mod.rangeCount(body_count, aligned_items_per_range);

        try contacts.prepareRangeCounts(range_count);
        try self.prepareCandidateCounts(range_count);
        var context = CollisionJobContext{
            .system = self,
            .contacts = contacts,
            .candidate_counts = self.candidate_counts.items,
        };
        const count_batch = thread_system.parallelForWithOptions(body_count, &context, countContactsJob, .{
            .min_parallel_items = system_config.min_parallel_items,
            .items_per_range = aligned_items_per_range,
            .max_worker_threads = system_config.max_worker_threads,
            .range_alignment_items = collision_range_alignment_items,
            .adaptive = system_config.adaptive,
            .adaptive_thread_count = system_config.adaptive_thread_count,
        });

        try contacts.prefix();
        const write_batch = thread_system.parallelForWithOptions(body_count, &context, writeContactsJob, .{
            .min_parallel_items = system_config.min_parallel_items,
            .items_per_range = aligned_items_per_range,
            .max_worker_threads = system_config.max_worker_threads,
            .range_alignment_items = collision_range_alignment_items,
            .adaptive = system_config.adaptive,
            .adaptive_thread_count = system_config.adaptive_thread_count,
        });
        contacts.finishWrite();

        if (active_tuner) |tuner| {
            tuner.record(write_batch);
        }

        return .{
            .body_count = body_count,
            .contact_count = contacts.mergedItems().len,
            .candidate_pair_count = sumCounts(self.candidate_counts.items),
            .count_batch = count_batch,
            .write_batch = write_batch,
            .used_full_sort = used_full_sort,
        };
    }

    pub fn updateSerial(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
    ) !CollisionStats {
        try self.gatherBodies(data);
        const body_count = self.entities.items.len;
        if (body_count <= 1) {
            contacts.clearRetainingCapacity();
            return .{ .body_count = body_count };
        }
        const used_full_sort = self.sortWarm(100);
        try contacts.prepareRangeCounts(1);
        try self.prepareCandidateCounts(1);
        const range = ParallelRange{ .index = 0, .start = 0, .end = body_count };
        const count_result = countContactsInRange(self, range);
        self.candidate_counts.items[0] = count_result.candidate_pairs;
        contacts.addCount(0, count_result.contacts);
        try contacts.prefix();
        var writer = contacts.rangeWriter(0);
        writeContactsInRange(self, range, &writer);
        writer.finish();
        contacts.finishWrite();
        return .{
            .body_count = body_count,
            .contact_count = contacts.mergedItems().len,
            .candidate_pair_count = sumCounts(self.candidate_counts.items),
            .count_batch = serialBatch(body_count),
            .write_batch = serialBatch(body_count),
            .used_full_sort = used_full_sort,
        };
    }

    pub fn bodyCount(self: *const CollisionSystem) usize {
        return self.entities.items.len;
    }

    fn gatherBodies(self: *CollisionSystem, data: *const DataSystem) !void {
        const bounds = data.collisionBoundsSliceConst();
        self.clearProxiesRetainingCapacity();
        try self.ensureProxyCapacity(bounds.entities.len);

        for (bounds.entities, 0..) |entity, bounds_index| {
            const movement_index = data.movementBodyDenseIndex(entity) orelse continue;
            const body = data.movementBodyConst(entity) orelse continue;
            const offset_x = bounds.offset_x[bounds_index];
            const offset_y = bounds.offset_y[bounds_index];
            const size_x = bounds.size_x[bounds_index];
            const size_y = bounds.size_y[bounds_index];
            const min_x = body.position.x + offset_x;
            const min_y = body.position.y + offset_y;
            self.entities.appendAssumeCapacity(entity);
            self.movement_indices.appendAssumeCapacity(movement_index);
            self.min_x.appendAssumeCapacity(min_x);
            self.min_y.appendAssumeCapacity(min_y);
            self.max_x.appendAssumeCapacity(min_x + size_x);
            self.max_y.appendAssumeCapacity(min_y + size_y);
        }
        try self.ensureOrder();
    }

    fn clearProxiesRetainingCapacity(self: *CollisionSystem) void {
        self.entities.clearRetainingCapacity();
        self.movement_indices.clearRetainingCapacity();
        self.min_x.clearRetainingCapacity();
        self.min_y.clearRetainingCapacity();
        self.max_x.clearRetainingCapacity();
        self.max_y.clearRetainingCapacity();
    }

    fn ensureProxyCapacity(self: *CollisionSystem, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(self.allocator, capacity);
        try self.movement_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.min_x.ensureTotalCapacity(self.allocator, capacity);
        try self.min_y.ensureTotalCapacity(self.allocator, capacity);
        try self.max_x.ensureTotalCapacity(self.allocator, capacity);
        try self.max_y.ensureTotalCapacity(self.allocator, capacity);
    }

    fn ensureOrder(self: *CollisionSystem) !void {
        const count = self.entities.items.len;
        if (self.order.items.len == count) return;
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(self.allocator, count);
        for (0..count) |index| {
            self.order.appendAssumeCapacity(index);
        }
    }

    fn prepareCandidateCounts(self: *CollisionSystem, range_count: usize) !void {
        self.candidate_counts.clearRetainingCapacity();
        try self.candidate_counts.ensureTotalCapacity(self.allocator, range_count);
        for (0..range_count) |_| {
            self.candidate_counts.appendAssumeCapacity(0);
        }
    }

    fn sortWarm(self: *CollisionSystem, full_sort_disorder_percent: u8) bool {
        if (self.order.items.len <= 1) return false;
        const max_percent = @min(full_sort_disorder_percent, @as(u8, 100));
        const inversion_count = self.adjacentInversionCount();
        if (inversion_count == 0) return false;
        const full_sort = @as(u128, inversion_count) * 100 > @as(u128, self.order.items.len) * max_percent;
        if (full_sort) {
            std.mem.sort(usize, self.order.items, self, proxyIndexLessThan);
            return true;
        }
        self.insertionSortOrder();
        return false;
    }

    fn adjacentInversionCount(self: *const CollisionSystem) usize {
        var inversions: usize = 0;
        for (1..self.order.items.len) |index| {
            if (proxyIndexLessThan(self, self.order.items[index], self.order.items[index - 1])) {
                inversions += 1;
            }
        }
        return inversions;
    }

    fn insertionSortOrder(self: *CollisionSystem) void {
        var index: usize = 1;
        while (index < self.order.items.len) : (index += 1) {
            const value = self.order.items[index];
            var insert = index;
            while (insert > 0 and proxyIndexLessThan(self, value, self.order.items[insert - 1])) : (insert -= 1) {
                self.order.items[insert] = self.order.items[insert - 1];
            }
            self.order.items[insert] = value;
        }
    }
};

const CollisionJobContext = struct {
    system: *const CollisionSystem,
    contacts: *RangeOutputStream(CollisionContact),
    candidate_counts: []usize,
};

fn countContactsJob(context: *anyopaque, range: ParallelRange, _: thread_mod.WorkerId) void {
    const job: *CollisionJobContext = @ptrCast(@alignCast(context));
    const result = countContactsInRange(job.system, range);
    job.candidate_counts[range.index] = result.candidate_pairs;
    job.contacts.addCount(range.index, result.contacts);
}

fn writeContactsJob(context: *anyopaque, range: ParallelRange, _: thread_mod.WorkerId) void {
    const job: *CollisionJobContext = @ptrCast(@alignCast(context));
    var writer = job.contacts.rangeWriter(range.index);
    writeContactsInRange(job.system, range, &writer);
    writer.finish();
}

const ContactCountResult = struct {
    candidate_pairs: usize = 0,
    contacts: usize = 0,
};

fn countContactsInRange(system: *const CollisionSystem, range: ParallelRange) ContactCountResult {
    var result = ContactCountResult{};
    for (range.start..range.end) |sorted_index| {
        const proxy_index = system.order.items[sorted_index];
        const max_x = system.max_x.items[proxy_index];
        var candidate_sorted_index = sorted_index + 1;
        while (candidate_sorted_index < system.order.items.len) : (candidate_sorted_index += 1) {
            const candidate_index = system.order.items[candidate_sorted_index];
            if (system.min_x.items[candidate_index] >= max_x) break;
            result.candidate_pairs += 1;
            if (overlapsY(system, proxy_index, candidate_index)) {
                result.contacts += 1;
            }
        }
    }
    return result;
}

fn writeContactsInRange(
    system: *const CollisionSystem,
    range: ParallelRange,
    writer: *RangeOutputStream(CollisionContact).RangeWriter,
) void {
    for (range.start..range.end) |sorted_index| {
        const proxy_index = system.order.items[sorted_index];
        const max_x = system.max_x.items[proxy_index];
        var candidate_sorted_index = sorted_index + 1;
        while (candidate_sorted_index < system.order.items.len) : (candidate_sorted_index += 1) {
            const candidate_index = system.order.items[candidate_sorted_index];
            if (system.min_x.items[candidate_index] >= max_x) break;
            if (overlapsY(system, proxy_index, candidate_index)) {
                writer.write(contactFor(system, proxy_index, candidate_index));
            }
        }
    }
}

fn overlapsY(system: *const CollisionSystem, a: usize, b: usize) bool {
    return system.max_y.items[a] > system.min_y.items[b] and system.max_y.items[b] > system.min_y.items[a];
}

fn contactFor(system: *const CollisionSystem, a: usize, b: usize) CollisionContact {
    const overlap_left = system.max_x.items[a] - system.min_x.items[b];
    const overlap_right = system.max_x.items[b] - system.min_x.items[a];
    const overlap_x = @min(overlap_left, overlap_right);
    const overlap_top = system.max_y.items[a] - system.min_y.items[b];
    const overlap_bottom = system.max_y.items[b] - system.min_y.items[a];
    const overlap_y = @min(overlap_top, overlap_bottom);

    var normal_x: f32 = 0;
    var normal_y: f32 = 0;
    var penetration = overlap_x;
    if (overlap_x <= overlap_y) {
        const center_a = (system.min_x.items[a] + system.max_x.items[a]) * 0.5;
        const center_b = (system.min_x.items[b] + system.max_x.items[b]) * 0.5;
        normal_x = if (center_a <= center_b) -1 else 1;
    } else {
        const center_a = (system.min_y.items[a] + system.max_y.items[a]) * 0.5;
        const center_b = (system.min_y.items[b] + system.max_y.items[b]) * 0.5;
        normal_y = if (center_a <= center_b) -1 else 1;
        penetration = overlap_y;
    }

    return .{
        .a = system.entities.items[a],
        .b = system.entities.items[b],
        .a_movement_index = system.movement_indices.items[a],
        .b_movement_index = system.movement_indices.items[b],
        .normal_x = normal_x,
        .normal_y = normal_y,
        .penetration = penetration,
    };
}

fn proxyIndexLessThan(system: *const CollisionSystem, lhs: usize, rhs: usize) bool {
    const lhs_min_x = system.min_x.items[lhs];
    const rhs_min_x = system.min_x.items[rhs];
    if (lhs_min_x != rhs_min_x) return lhs_min_x < rhs_min_x;
    const lhs_min_y = system.min_y.items[lhs];
    const rhs_min_y = system.min_y.items[rhs];
    if (lhs_min_y != rhs_min_y) return lhs_min_y < rhs_min_y;
    const lhs_entity = system.entities.items[lhs];
    const rhs_entity = system.entities.items[rhs];
    if (lhs_entity.index != rhs_entity.index) return lhs_entity.index < rhs_entity.index;
    return lhs_entity.generation < rhs_entity.generation;
}

fn sumCounts(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| {
        total += value;
    }
    return total;
}

fn serialBatch(item_count: usize) thread_mod.BatchStats {
    return .{
        .item_count = item_count,
        .range_count = if (item_count > 0) 1 else 0,
        .items_per_range = item_count,
        .range_alignment_items = collision_range_alignment_items,
        .main_thread_ranges = if (item_count > 0) 1 else 0,
        .ran_inline = true,
    };
}

fn addBody(data: *DataSystem, position_x: f32, position_y: f32, size: f32) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = position_x, .y = position_y },
        .previous_position = .{ .x = position_x, .y = position_y },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = size, .y = size } });
    return entity;
}

test "collision contacts are stable and reject non-overlaps" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addBody(&data, 0, 0, 10);
    const second = try addBody(&data, 8, 2, 10);
    _ = try addBody(&data, 30, 30, 4);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try system.updateSerial(&data, &contacts);

    try std.testing.expectEqual(@as(usize, 3), stats.body_count);
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 1), stats.contact_count);
    const merged = contacts.mergedItems();
    try std.testing.expectEqual(first.index, merged[0].a.index);
    try std.testing.expectEqual(second.index, merged[0].b.index);
    try std.testing.expectEqual(@as(f32, -1), merged[0].normal_x);
    try std.testing.expectEqual(@as(f32, 0), merged[0].normal_y);
    try std.testing.expectApproxEqAbs(@as(f32, 2), merged[0].penetration, 0.001);
}

test "collision stats report candidate pairs separately from contacts" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addBody(&data, 0, 0, 5);
    _ = try addBody(&data, 3, 20, 5);
    _ = try addBody(&data, 4, 1, 5);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try system.updateSerial(&data, &contacts);

    try std.testing.expectEqual(@as(usize, 3), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 1), stats.contact_count);
}

test "warm sorted collision order skips repair when already ordered" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..16) |index| {
        _ = try addBody(&data, @floatFromInt(index * 16), 0, 8);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const first = try system.updateSerial(&data, &contacts);
    const second = try system.updateSerial(&data, &contacts);

    try std.testing.expect(!first.used_full_sort);
    try std.testing.expect(!second.used_full_sort);
    try std.testing.expectEqual(@as(usize, 0), second.candidate_pair_count);
}

test "threaded collision matches serial contact order" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var serial_data = DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();

    for (0..64) |index| {
        const x: f32 = @floatFromInt((index % 16) * 6);
        const y: f32 = @floatFromInt((index / 16) * 6);
        _ = try addBody(&serial_data, x, y, 8);
        _ = try addBody(&threaded_data, x, y, 8);
    }

    var serial_system = CollisionSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    var threaded_system = CollisionSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    var threaded_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer threaded_contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .items_per_range = collision_range_alignment_items,
    });
    defer threads.deinit();

    _ = try serial_system.updateSerial(&serial_data, &serial_contacts);
    const threaded_stats = try threaded_system.update(&threaded_data, &threaded_contacts, &threads, .{
        .min_parallel_items = 1,
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    try std.testing.expect(!threaded_stats.write_batch.ran_inline);
    const serial_items = serial_contacts.mergedItems();
    const threaded_items = threaded_contacts.mergedItems();
    try std.testing.expectEqual(serial_items.len, threaded_items.len);
    for (serial_items, threaded_items) |serial, threaded| {
        try std.testing.expectEqual(serial.a.index, threaded.a.index);
        try std.testing.expectEqual(serial.b.index, threaded.b.index);
        try std.testing.expectEqual(serial.a_movement_index, threaded.a_movement_index);
        try std.testing.expectEqual(serial.b_movement_index, threaded.b_movement_index);
        try std.testing.expectEqual(serial.normal_x, threaded.normal_x);
        try std.testing.expectEqual(serial.normal_y, threaded.normal_y);
        try std.testing.expectApproxEqAbs(serial.penetration, threaded.penetration, 0.001);
    }
}

test "collision update reuses warmed scratch without steady state allocation" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..32) |index| {
        _ = try addBody(&data, @floatFromInt(index * 2), 0, 4);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try system.updateSerial(&data, &contacts);

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    system.allocator = fail;
    contacts.allocator = fail;
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    const stats = try system.updateSerial(&data, &contacts);
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
    try std.testing.expect(contacts.mergedItems().len > 0);
}

test "collision scratch columns are cache-line aligned" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..collision_range_alignment_items + 1) |index| {
        _ = try addBody(&data, @floatFromInt(index * 4), 0, 6);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try system.updateSerial(&data, &contacts);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.min_x.items.ptr) % data_mod.hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.min_y.items.ptr) % data_mod.hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.max_x.items.ptr) % data_mod.hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.max_y.items.ptr) % data_mod.hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), simd.vectorizedEnd(system.bodyCount()) % simd.lane_count);
}
