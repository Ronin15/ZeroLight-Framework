// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned fixed-step simulation contracts.
//! Persistent gameplay data stays in DataSystem; this module owns transient
//! per-step streams for processor events, intents, and deferred structure.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../core/math.zig");
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../app/thread_system.zig").WorkerId;
const Component = @import("data_system.zig").Component;
const ComponentMask = @import("data_system.zig").ComponentMask;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const StructuralChange = @import("data_system.zig").StructuralChange;
const StructuralCommitStats = @import("data_system.zig").StructuralCommitStats;
const StructuralPlanScratch = @import("data_system.zig").StructuralPlanScratch;

pub const SimulationPhase = enum {
    idle,
    begin_step,
    main_thread_inputs,
    // The concrete processor order is state-owned. GameDemoState currently uses
    // AI -> steering -> pathfinding -> intent apply -> movement -> collision ->
    // response -> particles before structural commits.
    processors,
    merge_outputs,
    commit_structural,
    finished,
};

pub const SimulationEventStage = enum {
    structural_commit,
    domain_reaction,
};

pub const NavInvalidationReason = enum {
    static_obstacle_changed,
};

pub const NavRegionInvalidatedEvent = struct {
    reason: NavInvalidationReason,
};

pub const WorldTileChangedEvent = struct {
    level: u16,
    x: u16,
    y: u16,
    old_tile_id: u16,
    new_tile_id: u16,
    old_blocks_movement: bool = false,
    new_blocks_movement: bool = false,
};

pub const WorldObstacleChangedEvent = struct {
    level: u16,
    min_x: u16,
    min_y: u16,
    max_x_exclusive: u16,
    max_y_exclusive: u16,
};

pub const ComponentChangedEvent = struct {
    entity: EntityId,
    component: Component,
    was_static_navigation_obstacle: bool = false,
    is_static_navigation_obstacle: bool = false,
};

pub const EntityDestroyedEvent = struct {
    entity: EntityId,
    component_mask: ComponentMask,
    was_static_navigation_obstacle: bool = false,
};

pub const SimulationEventPayload = union(enum) {
    entity_created: EntityId,
    entity_destroyed: EntityDestroyedEvent,
    component_changed: ComponentChangedEvent,
    world_tile_changed: WorldTileChangedEvent,
    world_obstacle_changed: WorldObstacleChangedEvent,
    nav_region_invalidated: NavRegionInvalidatedEvent,
};

pub const SimulationEvent = struct {
    stage: SimulationEventStage,
    payload: SimulationEventPayload,
};

pub const SimulationEventStats = struct {
    total: usize = 0,
    dropped: usize = 0,
    entity_created: usize = 0,
    entity_destroyed: usize = 0,
    component_changed: usize = 0,
    world_tile_changed: usize = 0,
    world_obstacle_changed: usize = 0,
    nav_region_invalidated: usize = 0,
    structural_commit_stage: usize = 0,
    domain_reaction_stage: usize = 0,

    fn record(self: *SimulationEventStats, event: SimulationEvent) void {
        self.total += 1;
        switch (event.stage) {
            .structural_commit => self.structural_commit_stage += 1,
            .domain_reaction => self.domain_reaction_stage += 1,
        }
        switch (event.payload) {
            .entity_created => self.entity_created += 1,
            .entity_destroyed => self.entity_destroyed += 1,
            .component_changed => self.component_changed += 1,
            .world_tile_changed => self.world_tile_changed += 1,
            .world_obstacle_changed => self.world_obstacle_changed += 1,
            .nav_region_invalidated => self.nav_region_invalidated += 1,
        }
    }

    fn addProduced(self: *SimulationEventStats, produced: SimulationEventStats) void {
        self.total += produced.total;
        self.entity_created += produced.entity_created;
        self.entity_destroyed += produced.entity_destroyed;
        self.component_changed += produced.component_changed;
        self.world_tile_changed += produced.world_tile_changed;
        self.world_obstacle_changed += produced.world_obstacle_changed;
        self.nav_region_invalidated += produced.nav_region_invalidated;
        self.structural_commit_stage += produced.structural_commit_stage;
        self.domain_reaction_stage += produced.domain_reaction_stage;
    }
};

pub const SimulationEvents = struct {
    stream: RangeOutputStream(SimulationEvent),
    range_stats: std.ArrayList(SimulationEventStats) = .empty,
    stats: SimulationEventStats = .{},
    capacity_limit: ?usize = null,

    pub const RangeWriter = struct {
        inner: RangeOutputStream(SimulationEvent).RangeWriter,
        stats: *SimulationEventStats,

        pub fn write(self: *RangeWriter, event: SimulationEvent) void {
            self.inner.write(event);
            self.stats.record(event);
        }

        pub fn finish(self: *RangeWriter) void {
            self.inner.finish();
        }
    };

    pub fn init(allocator: std.mem.Allocator) SimulationEvents {
        return .{ .stream = RangeOutputStream(SimulationEvent).init(allocator) };
    }

    pub fn deinit(self: *SimulationEvents) void {
        self.range_stats.deinit(self.stream.allocator);
        self.stream.deinit();
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *SimulationEvents) void {
        self.stream.clearRetainingCapacity();
        self.range_stats.clearRetainingCapacity();
        self.stats = .{};
    }

    pub fn reserve(self: *SimulationEvents, range_count: usize, value_capacity: usize) !void {
        try self.stream.reserve(range_count, value_capacity);
        try self.range_stats.ensureTotalCapacity(self.stream.allocator, range_count);
    }

    pub fn setCapacityLimit(self: *SimulationEvents, value_capacity: ?usize) void {
        self.capacity_limit = value_capacity;
    }

    pub fn prepareRangeCounts(self: *SimulationEvents, range_count: usize) !void {
        self.clearRetainingCapacity();
        _ = try self.appendRangeCounts(range_count);
    }

    pub fn appendRangeCounts(self: *SimulationEvents, range_count: usize) !usize {
        const first_range = self.stream.counts.items.len;
        try self.range_stats.ensureTotalCapacity(self.stream.allocator, first_range + range_count);
        const stream_first_range = try self.stream.appendRangeCounts(range_count);
        std.debug.assert(stream_first_range == first_range);
        for (0..range_count) |_| {
            self.range_stats.appendAssumeCapacity(.{});
        }
        return first_range;
    }

    pub fn addCount(self: *SimulationEvents, range_index: usize, count: usize) void {
        self.stream.addCount(range_index, count);
    }

    pub fn prefix(self: *SimulationEvents) !void {
        try self.ensureCanAppend(self.pendingCountFrom(0));
        try self.stream.prefix();
    }

    pub fn prefixAppendedRanges(self: *SimulationEvents, first_range: usize) !void {
        try self.ensureCanAppend(self.pendingCountFrom(first_range));
        try self.stream.prefixAppendedRanges(first_range);
    }

    pub fn rangeWriter(self: *SimulationEvents, range_index: usize) RangeWriter {
        std.debug.assert(range_index < self.range_stats.items.len);
        return .{
            .inner = self.stream.rangeWriter(range_index),
            .stats = &self.range_stats.items[range_index],
        };
    }

    pub fn finishWrite(self: *SimulationEvents) void {
        self.stream.finishWrite();
        self.rebuildStatsFromRanges();
    }

    pub fn mergedItems(self: *const SimulationEvents) []const SimulationEvent {
        return self.stream.mergedItems();
    }

    pub fn rangeCount(self: *const SimulationEvents) usize {
        return self.stream.rangeCount();
    }

    pub fn appendRequired(self: *SimulationEvents, event: SimulationEvent) !void {
        try self.ensureCanAppend(1);
        try self.reserveAppendCapacity(1, 1);
        const first_range = try self.appendRangeCounts(1);
        self.addCount(first_range, 1);
        try self.prefixAppendedRanges(first_range);
        var writer = self.rangeWriter(first_range);
        writer.write(event);
        writer.finish();
        self.finishWrite();
    }

    pub fn appendDiagnostic(self: *SimulationEvents, event: SimulationEvent) void {
        self.appendRequired(event) catch {
            self.stats.dropped += 1;
        };
    }

    pub fn ensureCanAppend(self: *const SimulationEvents, count: usize) !void {
        const limit = self.capacity_limit orelse return;
        if (count > limit or self.stream.mergedItems().len > limit - count) {
            return error.EventCapacityExceeded;
        }
    }

    fn pendingCountFrom(self: *const SimulationEvents, first_range: usize) usize {
        var count: usize = 0;
        for (self.stream.counts.items[first_range..]) |range_count| {
            count += range_count;
        }
        return count;
    }

    fn reserveAppendCapacity(self: *SimulationEvents, range_count: usize, value_count: usize) !void {
        const new_range_count = self.stream.counts.items.len + range_count;
        try self.stream.counts.ensureTotalCapacity(self.stream.allocator, new_range_count);
        try self.stream.offsets.ensureTotalCapacity(self.stream.allocator, new_range_count);
        try self.stream.write_offsets.ensureTotalCapacity(self.stream.allocator, new_range_count);
        try self.range_stats.ensureTotalCapacity(self.stream.allocator, new_range_count);

        const new_value_count = if (self.stream.prefix_ready)
            self.stream.mergedItems().len + value_count
        else
            self.pendingCountFrom(0) + value_count;
        try self.stream.values.ensureTotalCapacity(self.stream.allocator, new_value_count);
    }

    fn rebuildStatsFromRanges(self: *SimulationEvents) void {
        const dropped = self.stats.dropped;
        self.stats = .{ .dropped = dropped };
        for (self.range_stats.items) |range_stat| {
            self.stats.addProduced(range_stat);
        }
    }
};

const StructuralChangeSink = struct {
    changes: *std.ArrayList(StructuralChange),

    pub fn record(self: *StructuralChangeSink, change: StructuralChange) void {
        self.changes.appendAssumeCapacity(change);
    }
};

const StructuralCommitPreparer = struct {
    frame: *SimulationFrame,
    changes: *std.ArrayList(StructuralChange),
    extra_required_events: usize,
    structural_event_count: usize = 0,

    pub fn prepare(self: *StructuralCommitPreparer, structural_event_count: usize) !void {
        self.structural_event_count = structural_event_count;
        const required_event_count = try std.math.add(usize, structural_event_count, self.extra_required_events);
        try self.frame.events.ensureCanAppend(required_event_count);
        try self.frame.reserveStructuralEvents(required_event_count);
        try self.changes.ensureTotalCapacity(self.frame.events.stream.allocator, structural_event_count);
    }
};

pub const CollisionTriggerEvent = struct {
    a: EntityId,
    b: EntityId,
};

pub const MovementIntent = struct {
    entity: EntityId,
    direction_x: f32,
    direction_y: f32,
};

pub const PathAgentClass = enum {
    default,
};

/// Solver mode selected per navigation request.
/// `individual` runs goal-keyed budget-bounded A*; `group` declares a shared
/// goal serviced by a managed reverse-Dijkstra flow field. Grouping is always
/// declared by the requester, never detected.
pub const PathRequestKind = enum {
    individual,
    group,
};

pub const PathRequest = struct {
    entity: EntityId,
    agent_class: PathAgentClass = .default,
    kind: PathRequestKind = .individual,
    // Z-level floors for start/goal. Both default to 0 for the single-level
    // demo; cross-level queries route through `LevelLink` edges.
    start_level: u16 = 0,
    goal_level: u16 = 0,
    start: math.Vec2,
    goal: math.Vec2,
};

pub const NavigationIntent = struct {
    entity: EntityId,
    agent_class: PathAgentClass = .default,
    kind: PathRequestKind = .individual,
    // Target Z-level floor. Defaults to 0 until multi-level gameplay placement
    // exists; the start level is supplied by the producing system.
    goal_level: u16 = 0,
    goal: math.Vec2,
    direct_direction_x: f32 = 0,
    direct_direction_y: f32 = 0,
    priority: i16 = 0,
};

pub const SimulationIntent = union(enum) {
    movement: MovementIntent,
};

pub const CollisionContact = struct {
    /// Dense movement indices are same-step hints emitted after CollisionSystem
    /// jobs finish. Consumers must use them before structural commits or remap.
    a: EntityId,
    b: EntityId,
    a_movement_index: usize,
    b_movement_index: usize,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
};

/// Per-step player dig request captured in the `main_thread_inputs` phase and
/// consumed by the pipeline-owned dig controller in `processors`. Single value:
/// the player digs at most one faced cell per fixed step. `hole` punches a
/// see-through hole to fall through; `ramp` carves a walkable cross-plane link.
pub const DigIntent = enum { none, hole, ramp };

pub const SimulationFrame = struct {
    allocator: std.mem.Allocator,
    phase: SimulationPhase = .idle,
    // Transient player intent for this step; reset each `beginStep`.
    dig_intent: DigIntent = .none,
    // These streams are transient frame outputs. Producers reserve/count per
    // range, write range-owned records, then consumers read mergedItems only
    // after the producer stage has finished.
    events: SimulationEvents,
    navigation_intents: RangeOutputStream(NavigationIntent),
    intents: RangeOutputStream(SimulationIntent),
    path_requests: RangeOutputStream(PathRequest),
    contacts: RangeOutputStream(CollisionContact),
    collision_triggers: RangeOutputStream(CollisionTriggerEvent),
    structural_commands: RangeOutputStream(StructuralCommand),
    structural_plan_scratch: StructuralPlanScratch,
    // Reused across commits so a structural-mutating frame stays allocation-free
    // after warmup; cleared (capacity retained) at the start of each commit.
    structural_changes_scratch: std.ArrayList(StructuralChange) = .empty,

    pub fn init(allocator: std.mem.Allocator) SimulationFrame {
        return .{
            .allocator = allocator,
            .events = SimulationEvents.init(allocator),
            .navigation_intents = RangeOutputStream(NavigationIntent).init(allocator),
            .intents = RangeOutputStream(SimulationIntent).init(allocator),
            .path_requests = RangeOutputStream(PathRequest).init(allocator),
            .contacts = RangeOutputStream(CollisionContact).init(allocator),
            .collision_triggers = RangeOutputStream(CollisionTriggerEvent).init(allocator),
            .structural_commands = RangeOutputStream(StructuralCommand).init(allocator),
            .structural_plan_scratch = StructuralPlanScratch.init(allocator),
        };
    }

    pub fn deinit(self: *SimulationFrame) void {
        self.structural_changes_scratch.deinit(self.allocator);
        self.structural_plan_scratch.deinit();
        self.structural_commands.deinit();
        self.collision_triggers.deinit();
        self.contacts.deinit();
        self.path_requests.deinit();
        self.intents.deinit();
        self.navigation_intents.deinit();
        self.events.deinit();
        self.* = undefined;
    }

    pub fn beginStep(self: *SimulationFrame) void {
        self.clearRetainingCapacity();
        self.phase = .begin_step;
    }

    pub fn clearRetainingCapacity(self: *SimulationFrame) void {
        self.dig_intent = .none;
        self.events.clearRetainingCapacity();
        self.navigation_intents.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.path_requests.clearRetainingCapacity();
        self.contacts.clearRetainingCapacity();
        self.collision_triggers.clearRetainingCapacity();
        self.structural_commands.clearRetainingCapacity();
        self.structural_plan_scratch.clearRetainingCapacity();
        self.structural_changes_scratch.clearRetainingCapacity();
    }

    pub fn reserveStreams(
        self: *SimulationFrame,
        range_count: usize,
        event_capacity: usize,
        intent_capacity: usize,
        contact_capacity: usize,
        collision_trigger_capacity: usize,
        structural_command_capacity: usize,
    ) !void {
        try self.events.reserve(range_count, event_capacity);
        self.events.setCapacityLimit(event_capacity);
        try self.navigation_intents.reserve(range_count, intent_capacity);
        try self.intents.reserve(range_count, intent_capacity);
        try self.contacts.reserve(range_count, contact_capacity);
        try self.collision_triggers.reserve(range_count, collision_trigger_capacity);
        try self.structural_commands.reserve(range_count, structural_command_capacity);
    }

    pub fn reservePathRequests(self: *SimulationFrame, range_count: usize, request_capacity: usize) !void {
        try self.path_requests.reserve(range_count, request_capacity);
    }

    pub fn reserveNavigationIntents(self: *SimulationFrame, range_count: usize, intent_capacity: usize) !void {
        try self.navigation_intents.reserve(range_count, intent_capacity);
    }

    pub fn applyStructuralCommands(self: *SimulationFrame, data: *DataSystem) !StructuralCommitStats {
        return try self.applyStructuralCommandsWithExtraEvents(data, 0);
    }

    pub fn applyStructuralCommandsWithExtraEvents(
        self: *SimulationFrame,
        data: *DataSystem,
        extra_required_events: usize,
    ) !StructuralCommitStats {
        self.phase = .commit_structural;
        const commands = self.structural_commands.mergedItems();
        const changes = &self.structural_changes_scratch;
        changes.clearRetainingCapacity();
        var preparer = StructuralCommitPreparer{
            .frame = self,
            .changes = changes,
            .extra_required_events = extra_required_events,
        };
        var sink = StructuralChangeSink{ .changes = changes };
        const stats = try data.applyStructuralCommandsPrepared(commands, &self.structural_plan_scratch, &preparer, &sink);
        std.debug.assert(changes.items.len <= preparer.structural_event_count);
        try self.publishStructuralChanges(changes.items);
        return stats;
    }

    fn reserveStructuralEvents(self: *SimulationFrame, event_count: usize) !void {
        if (event_count == 0) return;
        try self.events.reserve(self.events.rangeCount() + event_count, self.events.mergedItems().len + event_count);
    }

    fn publishStructuralChanges(self: *SimulationFrame, changes: []const StructuralChange) !void {
        for (changes) |change| {
            try self.events.appendRequired(switch (change) {
                .entity_created => |entity| .{
                    .stage = .structural_commit,
                    .payload = .{ .entity_created = entity },
                },
                .entity_destroyed => |destroyed| .{
                    .stage = .structural_commit,
                    .payload = .{ .entity_destroyed = .{
                        .entity = destroyed.entity,
                        .component_mask = destroyed.component_mask,
                        .was_static_navigation_obstacle = destroyed.was_static_navigation_obstacle,
                    } },
                },
                .component_changed => |changed| .{
                    .stage = .structural_commit,
                    .payload = .{ .component_changed = .{
                        .entity = changed.entity,
                        .component = changed.component,
                        .was_static_navigation_obstacle = changed.was_static_navigation_obstacle,
                        .is_static_navigation_obstacle = changed.is_static_navigation_obstacle,
                    } },
                },
            });
        }
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
            _ = try self.appendRangeCounts(range_count);
        }

        pub fn appendRangeCounts(self: *Self, range_count: usize) !usize {
            if (self.prefix_ready) {
                std.debug.assert(self.offsets.items.len == self.counts.items.len);
                std.debug.assert(self.write_offsets.items.len == self.counts.items.len);
            }
            const first_range = self.counts.items.len;
            try self.counts.ensureTotalCapacity(self.allocator, first_range + range_count);
            for (0..range_count) |_| {
                self.counts.appendAssumeCapacity(0);
            }
            return first_range;
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

        pub fn prefixAppendedRanges(self: *Self, first_range: usize) !void {
            if (!self.prefix_ready) {
                try self.prefix();
                return;
            }

            std.debug.assert(first_range == self.offsets.items.len);
            std.debug.assert(first_range == self.write_offsets.items.len);
            try self.offsets.ensureTotalCapacity(self.allocator, self.counts.items.len);
            try self.write_offsets.ensureTotalCapacity(self.allocator, self.counts.items.len);

            var running_total = self.merged_len;
            for (self.counts.items[first_range..]) |count| {
                self.offsets.appendAssumeCapacity(running_total);
                self.write_offsets.appendAssumeCapacity(running_total);
                running_total += count;
            }

            try self.values.ensureTotalCapacity(self.allocator, running_total);
            while (self.values.items.len < running_total) {
                self.values.appendAssumeCapacity(undefined);
            }
            self.merged_len = running_total;
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

const TestStreamEvent = struct {
    marker: u32,
};

const StreamJobContext = struct {
    stream: *RangeOutputStream(TestStreamEvent),
};

fn testStreamEvent(marker: u32) TestStreamEvent {
    return .{ .marker = marker };
}

fn expectTestStreamEvent(event: TestStreamEvent, expected: u32) !void {
    try std.testing.expectEqual(@as(u32, expected), event.marker);
}

fn entityCreatedEvent(index: u32) SimulationEvent {
    return .{ .stage = .structural_commit, .payload = .{ .entity_created = .{ .index = index, .generation = 1 } } };
}

fn expectEntityCreatedEvent(event: SimulationEvent, expected_index: u32) !void {
    try std.testing.expectEqual(SimulationEventStage.structural_commit, event.stage);
    try std.testing.expectEqual(@as(u32, expected_index), event.payload.entity_created.index);
}

fn writeStructuralCommands(frame: *SimulationFrame, commands: []const StructuralCommand) !void {
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| {
        writer.write(command);
    }
    writer.finish();
    frame.structural_commands.finishWrite();
}

fn countEvenEvents(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *StreamJobContext = @ptrCast(@alignCast(context));
    var count: usize = 0;
    for (range.start..range.end) |item| {
        if (item % 2 == 0) count += 1;
    }
    job.stream.addCount(range.index, count);
}

fn writeEvenEvents(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *StreamJobContext = @ptrCast(@alignCast(context));
    var writer = job.stream.rangeWriter(range.index);
    for (range.start..range.end) |item| {
        if (item % 2 == 0) {
            writer.write(testStreamEvent(@intCast(item)));
        }
    }
    writer.finish();
}

test "range output stream merges by range index" {
    var stream = RangeOutputStream(TestStreamEvent).init(std.testing.allocator);
    defer stream.deinit();

    try stream.prepareRangeCounts(3);
    stream.addCount(2, 1);
    stream.addCount(0, 2);
    stream.addCount(1, 1);
    try stream.prefix();
    var writer_2 = stream.rangeWriter(2);
    writer_2.write(testStreamEvent(30));
    writer_2.finish();
    var writer_0 = stream.rangeWriter(0);
    writer_0.write(testStreamEvent(10));
    writer_0.write(testStreamEvent(11));
    writer_0.finish();
    var writer_1 = stream.rangeWriter(1);
    writer_1.write(testStreamEvent(20));
    writer_1.finish();
    stream.finishWrite();

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try expectTestStreamEvent(merged[0], 10);
    try expectTestStreamEvent(merged[1], 11);
    try expectTestStreamEvent(merged[2], 20);
    try expectTestStreamEvent(merged[3], 30);
}

test "range output stream keeps deterministic order across threaded passes" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var stream = RangeOutputStream(TestStreamEvent).init(std.testing.allocator);
    defer stream.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
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
        try expectTestStreamEvent(event, @intCast(index * 2));
    }
}

test "simulation events collect deterministic threaded records and stats" {
    var events = SimulationEvents.init(std.testing.allocator);
    defer events.deinit();

    try events.prepareRangeCounts(2);
    events.addCount(1, 1);
    events.addCount(0, 2);
    try events.prefix();
    var writer_1 = events.rangeWriter(1);
    writer_1.write(entityCreatedEvent(30));
    writer_1.finish();
    var writer_0 = events.rangeWriter(0);
    writer_0.write(entityCreatedEvent(10));
    writer_0.write(entityCreatedEvent(20));
    writer_0.finish();
    try std.testing.expectEqual(@as(usize, 0), events.stats.total);
    try std.testing.expectEqual(@as(usize, 2), events.range_stats.items[0].total);
    try std.testing.expectEqual(@as(usize, 1), events.range_stats.items[1].total);
    events.finishWrite();

    const merged = events.mergedItems();
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try expectEntityCreatedEvent(merged[0], 10);
    try expectEntityCreatedEvent(merged[1], 20);
    try expectEntityCreatedEvent(merged[2], 30);
    try std.testing.expectEqual(@as(usize, 3), events.stats.total);
    try std.testing.expectEqual(@as(usize, 3), events.stats.entity_created);
    try std.testing.expectEqual(@as(usize, 3), events.stats.structural_commit_stage);
}

test "simulation events drop diagnostic records when capacity cannot grow" {
    for (0..5) |fail_index| {
        var events = SimulationEvents.init(std.testing.allocator);
        defer events.deinit();

        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const original_allocator = events.stream.allocator;
        events.stream.allocator = failing_allocator.allocator();
        defer events.stream.allocator = original_allocator;

        events.appendDiagnostic(entityCreatedEvent(1));

        try std.testing.expectEqual(@as(usize, 0), events.stream.counts.items.len);
        try std.testing.expectEqual(@as(usize, 0), events.range_stats.items.len);
        try std.testing.expectEqual(@as(usize, 0), events.mergedItems().len);
        try std.testing.expectEqual(@as(usize, 0), events.stats.total);
        try std.testing.expectEqual(@as(usize, 1), events.stats.dropped);
    }
}

test "simulation events enforce explicit per-step event capacity" {
    var events = SimulationEvents.init(std.testing.allocator);
    defer events.deinit();

    try events.reserve(1, 1);
    events.setCapacityLimit(1);

    try events.appendRequired(entityCreatedEvent(1));
    events.appendDiagnostic(entityCreatedEvent(2));

    try std.testing.expectError(error.EventCapacityExceeded, events.appendRequired(entityCreatedEvent(3)));
    try std.testing.expectEqual(@as(usize, 1), events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 1), events.stats.total);
    try std.testing.expectEqual(@as(usize, 1), events.stats.dropped);

    var ranged_events = SimulationEvents.init(std.testing.allocator);
    defer ranged_events.deinit();
    try ranged_events.reserve(1, 1);
    ranged_events.setCapacityLimit(1);
    try ranged_events.prepareRangeCounts(1);
    ranged_events.addCount(0, 2);
    try std.testing.expectError(error.EventCapacityExceeded, ranged_events.prefix());
    try std.testing.expectEqual(@as(usize, 0), ranged_events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), ranged_events.stats.total);
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
    try std.testing.expectEqual(@as(usize, 2), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.entity_created);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.component_changed);
}

test "simulation frame rejects structural commit before mutation when event capacity is too small" {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    try frame.reserveStreams(1, 1, 0, 0, 0, 1);
    frame.beginStep();
    try writeStructuralCommands(&frame, &.{.{ .create_entity = .{
        .movement_body = .{
            .position = .{ .x = 2, .y = 3 },
            .previous_position = .{ .x = 2, .y = 3 },
            .velocity = .{},
            .speed = 1,
        },
    } }});

    try std.testing.expectError(error.EventCapacityExceeded, frame.applyStructuralCommands(&data));
    try std.testing.expectEqual(@as(usize, 0), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.total);
}

test "simulation frame emits structural destroy event with prior component mask" {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = 1, .y = 2 },
        .previous_position = .{ .x = 1, .y = 2 },
        .velocity = .{},
        .speed = 1,
    });

    frame.beginStep();
    try writeStructuralCommands(&frame, &.{.{ .destroy_entity = entity }});
    const stats = try frame.applyStructuralCommands(&data);

    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expect(!data.isAlive(entity));
    const event = frame.events.mergedItems()[0];
    try std.testing.expectEqual(SimulationEventStage.structural_commit, event.stage);
    try std.testing.expectEqual(entity.index, event.payload.entity_destroyed.entity.index);
    try std.testing.expect((event.payload.entity_destroyed.component_mask & @import("data_system.zig").component_masks.movement_body) != 0);
    try std.testing.expect(!event.payload.entity_destroyed.was_static_navigation_obstacle);
}

test "simulation frame skips structural events for stale commands" {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    frame.beginStep();
    try writeStructuralCommands(&frame, &.{.{ .set_movement_body = .{
        .entity = EntityId.invalid,
        .body = .{
            .position = .{ .x = 1, .y = 2 },
            .previous_position = .{ .x = 1, .y = 2 },
            .velocity = .{},
            .speed = 1,
        },
    } }});
    const stats = try frame.applyStructuralCommands(&data);

    try std.testing.expectEqual(@as(usize, 1), stats.stale_skipped);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.total);
}

test "range output stream reuses warmed capacity without allocation" {
    var stream = RangeOutputStream(TestStreamEvent).init(std.testing.allocator);
    defer stream.deinit();

    try stream.prepareRangeCounts(2);
    stream.addCount(0, 2);
    stream.addCount(1, 1);
    try stream.prefix();
    var first_writer_0 = stream.rangeWriter(0);
    first_writer_0.write(testStreamEvent(1));
    first_writer_0.write(testStreamEvent(2));
    first_writer_0.finish();
    var first_writer_1 = stream.rangeWriter(1);
    first_writer_1.write(testStreamEvent(3));
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
    second_writer_0.write(testStreamEvent(4));
    second_writer_0.finish();
    var second_writer_1 = stream.rangeWriter(1);
    second_writer_1.write(testStreamEvent(5));
    second_writer_1.finish();
    stream.finishWrite();

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try expectTestStreamEvent(merged[0], 4);
    try expectTestStreamEvent(merged[1], 5);
}

test "range output stream appends ranges after completed output" {
    var stream = RangeOutputStream(TestStreamEvent).init(std.testing.allocator);
    defer stream.deinit();

    try stream.prepareRangeCounts(1);
    stream.addCount(0, 1);
    try stream.prefix();
    var first_writer = stream.rangeWriter(0);
    first_writer.write(testStreamEvent(7));
    first_writer.finish();
    stream.finishWrite();

    const appended_range = try stream.appendRangeCounts(2);
    try std.testing.expectEqual(@as(usize, 1), appended_range);
    stream.addCount(appended_range, 1);
    stream.addCount(appended_range + 1, 2);
    try stream.prefixAppendedRanges(appended_range);
    var writer_1 = stream.rangeWriter(appended_range);
    writer_1.write(testStreamEvent(8));
    writer_1.finish();
    var writer_2 = stream.rangeWriter(appended_range + 1);
    writer_2.write(testStreamEvent(9));
    writer_2.write(testStreamEvent(10));
    writer_2.finish();
    stream.finishWrite();

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try expectTestStreamEvent(merged[0], 7);
    try expectTestStreamEvent(merged[1], 8);
    try expectTestStreamEvent(merged[2], 9);
    try expectTestStreamEvent(merged[3], 10);
}

test "simulation frame reserves stream capacity for warmed fixed-step output" {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    try frame.reserveStreams(2, 2, 2, 2, 2, 1);

    const original_allocator = frame.allocator;
    const original_events_allocator = frame.events.stream.allocator;
    const original_navigation_intents_allocator = frame.navigation_intents.allocator;
    const original_intents_allocator = frame.intents.allocator;
    const original_triggers_allocator = frame.collision_triggers.allocator;
    const original_commands_allocator = frame.structural_commands.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    frame.allocator = fail;
    frame.events.stream.allocator = fail;
    frame.navigation_intents.allocator = fail;
    frame.intents.allocator = fail;
    frame.collision_triggers.allocator = fail;
    frame.structural_commands.allocator = fail;
    defer {
        frame.allocator = original_allocator;
        frame.events.stream.allocator = original_events_allocator;
        frame.navigation_intents.allocator = original_navigation_intents_allocator;
        frame.intents.allocator = original_intents_allocator;
        frame.collision_triggers.allocator = original_triggers_allocator;
        frame.structural_commands.allocator = original_commands_allocator;
    }

    try frame.events.prepareRangeCounts(2);
    frame.events.addCount(0, 1);
    frame.events.addCount(1, 1);
    try frame.events.prefix();
    var event_writer = frame.events.rangeWriter(0);
    event_writer.write(entityCreatedEvent(1));
    event_writer.finish();
    event_writer = frame.events.rangeWriter(1);
    event_writer.write(entityCreatedEvent(2));
    event_writer.finish();
    frame.events.finishWrite();

    try frame.navigation_intents.prepareRangeCounts(2);
    frame.navigation_intents.addCount(0, 1);
    frame.navigation_intents.addCount(1, 1);
    try frame.navigation_intents.prefix();
    var navigation_writer = frame.navigation_intents.rangeWriter(0);
    navigation_writer.write(.{
        .entity = EntityId.invalid,
        .goal = .{ .x = 10, .y = 20 },
        .direct_direction_x = 1,
        .priority = 2,
    });
    navigation_writer.finish();
    navigation_writer = frame.navigation_intents.rangeWriter(1);
    navigation_writer.write(.{
        .entity = EntityId.invalid,
        .goal = .{ .x = 30, .y = 40 },
        .direct_direction_y = 1,
        .priority = 1,
    });
    navigation_writer.finish();
    frame.navigation_intents.finishWrite();

    try frame.intents.prepareRangeCounts(2);
    frame.intents.addCount(0, 1);
    frame.intents.addCount(1, 1);
    try frame.intents.prefix();
    var intent_writer = frame.intents.rangeWriter(0);
    intent_writer.write(.{ .movement = .{ .entity = EntityId.invalid, .direction_x = 1, .direction_y = 0 } });
    intent_writer.finish();
    intent_writer = frame.intents.rangeWriter(1);
    intent_writer.write(.{ .movement = .{ .entity = EntityId.invalid, .direction_x = 0, .direction_y = 1 } });
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

    try frame.collision_triggers.prepareRangeCounts(2);
    frame.collision_triggers.addCount(0, 1);
    try frame.collision_triggers.prefix();
    var trigger_writer = frame.collision_triggers.rangeWriter(0);
    trigger_writer.write(.{ .a = EntityId.invalid, .b = EntityId.invalid });
    trigger_writer.finish();
    trigger_writer = frame.collision_triggers.rangeWriter(1);
    trigger_writer.finish();
    frame.collision_triggers.finishWrite();

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
    try std.testing.expectEqual(@as(usize, 2), frame.navigation_intents.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 2), frame.intents.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 2), frame.contacts.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 1), frame.collision_triggers.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 1), frame.structural_commands.mergedItems().len);
}
