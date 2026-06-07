// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned fixed-step simulation contracts.
//! Persistent gameplay data stays in DataSystem; this module owns transient
//! per-step streams for processor events, intents, and deferred structure.

const std = @import("std");
const thread_mod = @import("../app/thread_system.zig");
const DataSystem = data_mod.DataSystem;
const EntityId = data_mod.EntityId;
const data_mod = @import("data_system.zig");

pub const SimulationPhase = enum {
    idle,
    begin_step,
    main_thread_inputs,
    processors,
    merge_outputs,
    commit_structural,
    finished,
};

pub const SimulationEvent = union(enum) {
    entity_created: EntityId,
    entity_destroyed: EntityId,
    marker: u32,
};

pub const MovementIntent = struct {
    entity: EntityId,
    direction_x: f32,
    direction_y: f32,
};

pub const SimulationIntent = union(enum) {
    movement: MovementIntent,
    marker: u32,
};

pub const CollisionContact = struct {
    a: EntityId,
    b: EntityId,
    a_movement_index: usize,
    b_movement_index: usize,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
};

pub const SimulationFrame = struct {
    allocator: std.mem.Allocator,
    phase: SimulationPhase = .idle,
    events: RangeOutputStream(SimulationEvent),
    intents: RangeOutputStream(SimulationIntent),
    contacts: RangeOutputStream(CollisionContact),
    structural_commands: RangeOutputStream(data_mod.StructuralCommand),

    pub fn init(allocator: std.mem.Allocator) SimulationFrame {
        return .{
            .allocator = allocator,
            .events = RangeOutputStream(SimulationEvent).init(allocator),
            .intents = RangeOutputStream(SimulationIntent).init(allocator),
            .contacts = RangeOutputStream(CollisionContact).init(allocator),
            .structural_commands = RangeOutputStream(data_mod.StructuralCommand).init(allocator),
        };
    }

    pub fn deinit(self: *SimulationFrame) void {
        self.structural_commands.deinit();
        self.contacts.deinit();
        self.intents.deinit();
        self.events.deinit();
        self.* = undefined;
    }

    pub fn beginStep(self: *SimulationFrame) void {
        self.clearRetainingCapacity();
        self.phase = .begin_step;
    }

    pub fn clearRetainingCapacity(self: *SimulationFrame) void {
        self.events.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.contacts.clearRetainingCapacity();
        self.structural_commands.clearRetainingCapacity();
    }

    pub fn reserveStreams(
        self: *SimulationFrame,
        range_count: usize,
        event_capacity: usize,
        intent_capacity: usize,
        contact_capacity: usize,
        structural_command_capacity: usize,
    ) !void {
        try self.events.reserve(range_count, event_capacity);
        try self.intents.reserve(range_count, intent_capacity);
        try self.contacts.reserve(range_count, contact_capacity);
        try self.structural_commands.reserve(range_count, structural_command_capacity);
    }

    pub fn applyStructuralCommands(self: *SimulationFrame, data: *DataSystem) !data_mod.StructuralCommitStats {
        self.phase = .commit_structural;
        return try data.applyStructuralCommands(self.structural_commands.mergedItems());
    }
};

pub fn RangeOutputStream(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        counts: std.ArrayList(usize) = .empty,
        offsets: std.ArrayList(usize) = .empty,
        write_offsets: std.ArrayList(usize) = .empty,
        values: std.ArrayList(T) = .empty,
        prefix_ready: bool = false,
        merged_len: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.values.deinit(self.allocator);
            self.write_offsets.deinit(self.allocator);
            self.offsets.deinit(self.allocator);
            self.counts.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.counts.clearRetainingCapacity();
            self.offsets.clearRetainingCapacity();
            self.write_offsets.clearRetainingCapacity();
            self.values.clearRetainingCapacity();
            self.prefix_ready = false;
            self.merged_len = 0;
        }

        pub fn reserve(self: *Self, range_count: usize, value_capacity: usize) !void {
            try self.counts.ensureTotalCapacity(self.allocator, range_count);
            try self.offsets.ensureTotalCapacity(self.allocator, range_count);
            try self.write_offsets.ensureTotalCapacity(self.allocator, range_count);
            try self.values.ensureTotalCapacity(self.allocator, value_capacity);
        }

        pub fn prepareRangeCounts(self: *Self, range_count: usize) !void {
            self.clearRetainingCapacity();
            try self.counts.ensureTotalCapacity(self.allocator, range_count);
            for (0..range_count) |_| {
                self.counts.appendAssumeCapacity(0);
            }
        }

        pub fn addCount(self: *Self, range_index: usize, count: usize) void {
            std.debug.assert(range_index < self.counts.items.len);
            self.counts.items[range_index] += count;
        }

        pub fn prefix(self: *Self) !void {
            self.offsets.clearRetainingCapacity();
            self.write_offsets.clearRetainingCapacity();
            try self.offsets.ensureTotalCapacity(self.allocator, self.counts.items.len);
            try self.write_offsets.ensureTotalCapacity(self.allocator, self.counts.items.len);

            var running_total: usize = 0;
            for (self.counts.items) |count| {
                self.offsets.appendAssumeCapacity(running_total);
                self.write_offsets.appendAssumeCapacity(running_total);
                running_total += count;
            }

            self.values.clearRetainingCapacity();
            try self.values.ensureTotalCapacity(self.allocator, running_total);
            for (0..running_total) |_| {
                self.values.appendAssumeCapacity(undefined);
            }
            self.merged_len = running_total;
            self.prefix_ready = true;
        }

        pub const RangeWriter = struct {
            stream: *Self,
            range_index: usize,
            next: usize,
            end: usize,

            pub fn write(self: *RangeWriter, value: T) void {
                std.debug.assert(self.next < self.end);
                self.stream.values.items[self.next] = value;
                self.next += 1;
            }

            pub fn finish(self: *RangeWriter) void {
                std.debug.assert(self.next == self.end);
                self.stream.write_offsets.items[self.range_index] = self.next;
            }
        };

        pub fn rangeWriter(self: *Self, range_index: usize) RangeWriter {
            std.debug.assert(self.prefix_ready);
            std.debug.assert(range_index < self.write_offsets.items.len);

            return .{
                .stream = self,
                .range_index = range_index,
                .next = self.offsets.items[range_index],
                .end = self.rangeEnd(range_index),
            };
        }

        pub fn finishWrite(self: *const Self) void {
            std.debug.assert(self.prefix_ready);
            for (self.write_offsets.items, 0..) |write_offset, range_index| {
                std.debug.assert(write_offset == self.rangeEnd(range_index));
            }
        }

        pub fn mergedItems(self: *const Self) []const T {
            std.debug.assert(self.prefix_ready or self.merged_len == 0);
            return self.values.items[0..self.merged_len];
        }

        pub fn rangeCount(self: *const Self) usize {
            return self.counts.items.len;
        }

        fn rangeEnd(self: *const Self, range_index: usize) usize {
            if (range_index + 1 < self.offsets.items.len) {
                return self.offsets.items[range_index + 1];
            }
            return self.merged_len;
        }
    };
}

const StreamJobContext = struct {
    stream: *RangeOutputStream(SimulationEvent),
};

fn countEvenEvents(context: *anyopaque, range: thread_mod.ParallelRange, _: thread_mod.WorkerId) void {
    const job: *StreamJobContext = @ptrCast(@alignCast(context));
    var count: usize = 0;
    for (range.start..range.end) |item| {
        if (item % 2 == 0) count += 1;
    }
    job.stream.addCount(range.index, count);
}

fn writeEvenEvents(context: *anyopaque, range: thread_mod.ParallelRange, _: thread_mod.WorkerId) void {
    const job: *StreamJobContext = @ptrCast(@alignCast(context));
    var writer = job.stream.rangeWriter(range.index);
    for (range.start..range.end) |item| {
        if (item % 2 == 0) {
            writer.write(.{ .marker = @intCast(item) });
        }
    }
    writer.finish();
}

test "range output stream merges by range index" {
    var stream = RangeOutputStream(SimulationEvent).init(std.testing.allocator);
    defer stream.deinit();

    try stream.prepareRangeCounts(3);
    stream.addCount(2, 1);
    stream.addCount(0, 2);
    stream.addCount(1, 1);
    try stream.prefix();
    var writer_2 = stream.rangeWriter(2);
    writer_2.write(.{ .marker = 30 });
    writer_2.finish();
    var writer_0 = stream.rangeWriter(0);
    writer_0.write(.{ .marker = 10 });
    writer_0.write(.{ .marker = 11 });
    writer_0.finish();
    var writer_1 = stream.rangeWriter(1);
    writer_1.write(.{ .marker = 20 });
    writer_1.finish();
    stream.finishWrite();

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqual(@as(u32, 10), merged[0].marker);
    try std.testing.expectEqual(@as(u32, 11), merged[1].marker);
    try std.testing.expectEqual(@as(u32, 20), merged[2].marker);
    try std.testing.expectEqual(@as(u32, 30), merged[3].marker);
}

test "range output stream keeps deterministic order across threaded passes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var stream = RangeOutputStream(SimulationEvent).init(std.testing.allocator);
    defer stream.deinit();
    var threads = try thread_mod.ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .items_per_range = 5,
    });
    defer threads.deinit();

    try stream.prepareRangeCounts(8);
    var context = StreamJobContext{ .stream = &stream };
    const count_stats = threads.parallelForWithOptions(40, &context, countEvenEvents, .{
        .adaptive = false,
    });
    try std.testing.expectEqual(stream.rangeCount(), count_stats.range_count);
    try stream.prefix();
    _ = threads.parallelForWithOptions(40, &context, writeEvenEvents, .{
        .adaptive = false,
    });
    stream.finishWrite();

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 20), merged.len);
    for (merged, 0..) |event, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index * 2)), event.marker);
    }
}

test "simulation frame applies deferred structural commands" {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    frame.beginStep();
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, 1);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    writer.write(.{ .create_entity = .{
        .movement_body = .{
            .position = .{ .x = 2, .y = 3 },
            .previous_position = .{ .x = 2, .y = 3 },
            .velocity = .{},
            .speed = 1,
        },
    } });
    writer.finish();
    frame.structural_commands.finishWrite();

    const stats = try frame.applyStructuralCommands(&data);
    frame.phase = .finished;

    try std.testing.expectEqual(SimulationPhase.finished, frame.phase);
    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 1), stats.components_set);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);
}

test "range output stream reuses warmed capacity without allocation" {
    var stream = RangeOutputStream(SimulationEvent).init(std.testing.allocator);
    defer stream.deinit();

    try stream.prepareRangeCounts(2);
    stream.addCount(0, 2);
    stream.addCount(1, 1);
    try stream.prefix();
    var first_writer_0 = stream.rangeWriter(0);
    first_writer_0.write(.{ .marker = 1 });
    first_writer_0.write(.{ .marker = 2 });
    first_writer_0.finish();
    var first_writer_1 = stream.rangeWriter(1);
    first_writer_1.write(.{ .marker = 3 });
    first_writer_1.finish();
    stream.finishWrite();

    const original_allocator = stream.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    stream.allocator = failing_allocator.allocator();
    defer stream.allocator = original_allocator;

    try stream.prepareRangeCounts(2);
    stream.addCount(0, 1);
    stream.addCount(1, 1);
    try stream.prefix();
    var second_writer_0 = stream.rangeWriter(0);
    second_writer_0.write(.{ .marker = 4 });
    second_writer_0.finish();
    var second_writer_1 = stream.rangeWriter(1);
    second_writer_1.write(.{ .marker = 5 });
    second_writer_1.finish();
    stream.finishWrite();

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(@as(u32, 4), merged[0].marker);
    try std.testing.expectEqual(@as(u32, 5), merged[1].marker);
}

test "simulation frame reserves stream capacity for warmed fixed-step output" {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    try frame.reserveStreams(2, 2, 2, 2, 1);

    const original_allocator = frame.allocator;
    const original_events_allocator = frame.events.allocator;
    const original_intents_allocator = frame.intents.allocator;
    const original_commands_allocator = frame.structural_commands.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    frame.allocator = fail;
    frame.events.allocator = fail;
    frame.intents.allocator = fail;
    frame.structural_commands.allocator = fail;
    defer {
        frame.allocator = original_allocator;
        frame.events.allocator = original_events_allocator;
        frame.intents.allocator = original_intents_allocator;
        frame.structural_commands.allocator = original_commands_allocator;
    }

    try frame.events.prepareRangeCounts(2);
    frame.events.addCount(0, 1);
    frame.events.addCount(1, 1);
    try frame.events.prefix();
    var event_writer = frame.events.rangeWriter(0);
    event_writer.write(.{ .marker = 1 });
    event_writer.finish();
    event_writer = frame.events.rangeWriter(1);
    event_writer.write(.{ .marker = 2 });
    event_writer.finish();
    frame.events.finishWrite();

    try frame.intents.prepareRangeCounts(2);
    frame.intents.addCount(0, 1);
    frame.intents.addCount(1, 1);
    try frame.intents.prefix();
    var intent_writer = frame.intents.rangeWriter(0);
    intent_writer.write(.{ .marker = 3 });
    intent_writer.finish();
    intent_writer = frame.intents.rangeWriter(1);
    intent_writer.write(.{ .marker = 4 });
    intent_writer.finish();
    frame.intents.finishWrite();

    try frame.contacts.prepareRangeCounts(2);
    frame.contacts.addCount(0, 1);
    frame.contacts.addCount(1, 1);
    try frame.contacts.prefix();
    var contact_writer = frame.contacts.rangeWriter(0);
    contact_writer.write(.{
        .a = EntityId.invalid,
        .b = EntityId.invalid,
        .a_movement_index = 0,
        .b_movement_index = 1,
        .normal_x = 1,
        .normal_y = 0,
        .penetration = 2,
    });
    contact_writer.finish();
    contact_writer = frame.contacts.rangeWriter(1);
    contact_writer.write(.{
        .a = EntityId.invalid,
        .b = EntityId.invalid,
        .a_movement_index = 2,
        .b_movement_index = 3,
        .normal_x = 0,
        .normal_y = 1,
        .penetration = 4,
    });
    contact_writer.finish();
    frame.contacts.finishWrite();

    try frame.structural_commands.prepareRangeCounts(2);
    frame.structural_commands.addCount(0, 1);
    try frame.structural_commands.prefix();
    var command_writer = frame.structural_commands.rangeWriter(0);
    command_writer.write(.{ .destroy_entity = EntityId.invalid });
    command_writer.finish();
    command_writer = frame.structural_commands.rangeWriter(1);
    command_writer.finish();
    frame.structural_commands.finishWrite();

    try std.testing.expectEqual(@as(usize, 2), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 2), frame.intents.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 2), frame.contacts.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 1), frame.structural_commands.mergedItems().len);
}
