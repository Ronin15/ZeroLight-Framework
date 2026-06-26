// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Steering and local avoidance system for Slice 19.
//! Consumes high-level navigation intents, pathfinding status, and steering
//! component data, then emits final movement intents for NPC movement.
//! Selection, path requests, and world snapshots run on the main thread; worker
//! jobs read immutable slices and write range-owned movement intents.

const std = @import("std");
const AdaptiveWorkProfile = @import("../../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const math = @import("../../core/math.zig");
const ConstCollisionBoundsSlice = @import("../data_system.zig").ConstCollisionBoundsSlice;
const ConstCollisionResponseSlice = @import("../data_system.zig").ConstCollisionResponseSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const ConstSteeringAgentSlice = @import("../data_system.zig").ConstSteeringAgentSlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const MovementIntent = @import("../simulation.zig").MovementIntent;
const NavigationIntent = @import("../simulation.zig").NavigationIntent;
const PathRequest = @import("../simulation.zig").PathRequest;
const SimulationIntent = @import("../simulation.zig").SimulationIntent;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const PathfindingSystem = @import("pathfinding.zig").PathfindingSystem;

pub const steering_range_alignment_items: usize = @import("../data_system.zig").movement_range_alignment_items;
const HotF32List = std.ArrayListAligned(f32, .fromByteUnits(64));
const invalid_index = std.math.maxInt(usize);
const min_spatial_cell_size: f32 = 1.0;
const max_agent_candidate_checks: u16 = 64;
const max_obstacle_candidate_checks: u16 = 64;

pub const SteeringConfig = struct {
    max_selected_intents: ?usize = null,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const SteeringStats = struct {
    navigation_intent_count: usize = 0,
    selected_intent_count: usize = 0,
    movement_intent_count: usize = 0,
    path_request_count: usize = 0,
    path_available_count: usize = 0,
    path_pending_count: usize = 0,
    path_unavailable_count: usize = 0,
    replan_cooldown_count: usize = 0,
    unavailable_backoff_count: usize = 0,
    stuck_replan_count: usize = 0,
    agent_neighbor_samples: usize = 0,
    obstacle_samples: usize = 0,
    agent_candidate_checks: usize = 0,
    obstacle_candidate_checks: usize = 0,
    batch: BatchStats = .{},
};

pub const SteeringSystem = struct {
    allocator: std.mem.Allocator,
    // Runtime rows keep per-entity cooldown/progress state outside DataSystem.
    // They are pruned by entity ID whenever steering components disappear.
    runtime_rows: std.ArrayList(RuntimeRow) = .empty,
    // Selection and index scratch convert many navigation intents into one
    // deterministic steering job per entity.
    selected: std.ArrayList(SelectedIntent) = .empty,
    selected_index_by_steering: std.ArrayList(usize) = .empty,
    runtime_index_by_steering: std.ArrayList(usize) = .empty,
    agent_neighbor_counts: std.ArrayList(u16) = .empty,
    obstacle_counts: std.ArrayList(u16) = .empty,
    agent_candidate_counts: std.ArrayList(u16) = .empty,
    obstacle_candidate_counts: std.ArrayList(u16) = .empty,
    // Selected-work columns are range-written by workers and aligned with
    // `selected` by index.
    start_x: HotF32List = .empty,
    start_y: HotF32List = .empty,
    base_dir_x: HotF32List = .empty,
    base_dir_y: HotF32List = .empty,
    final_dir_x: HotF32List = .empty,
    final_dir_y: HotF32List = .empty,
    selected_agent_radii: HotF32List = .empty,
    selected_avoidance_radii: HotF32List = .empty,
    selected_avoidance_weights: HotF32List = .empty,
    selected_max_neighbor_samples: std.ArrayList(u16) = .empty,
    // World snapshots are immutable during worker dispatch. DataSystem is not
    // touched from steering worker jobs.
    all_agent_entities: std.ArrayList(EntityId) = .empty,
    all_agent_x: HotF32List = .empty,
    all_agent_y: HotF32List = .empty,
    all_agent_radii: HotF32List = .empty,
    agent_cell_entries: std.ArrayList(SpatialCellEntry) = .empty,
    agent_cell_ranges: std.ArrayList(SpatialCellRange) = .empty,
    obstacle_min_x: HotF32List = .empty,
    obstacle_min_y: HotF32List = .empty,
    obstacle_max_x: HotF32List = .empty,
    obstacle_max_y: HotF32List = .empty,
    obstacle_cell_entries: std.ArrayList(SpatialCellEntry) = .empty,
    obstacle_cell_ranges: std.ArrayList(SpatialCellRange) = .empty,
    spatial_cell_size: f32 = 64.0,
    spatial_obstacle_query_extra: f32 = 0,
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = steering_range_alignment_items,
        .smallest_range_items = steering_range_alignment_items,
    }),

    pub fn init(allocator: std.mem.Allocator) SteeringSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SteeringSystem) void {
        self.obstacle_cell_ranges.deinit(self.allocator);
        self.obstacle_cell_entries.deinit(self.allocator);
        self.obstacle_max_y.deinit(self.allocator);
        self.obstacle_max_x.deinit(self.allocator);
        self.obstacle_min_y.deinit(self.allocator);
        self.obstacle_min_x.deinit(self.allocator);
        self.agent_cell_ranges.deinit(self.allocator);
        self.agent_cell_entries.deinit(self.allocator);
        self.all_agent_radii.deinit(self.allocator);
        self.all_agent_y.deinit(self.allocator);
        self.all_agent_x.deinit(self.allocator);
        self.all_agent_entities.deinit(self.allocator);
        self.selected_max_neighbor_samples.deinit(self.allocator);
        self.selected_avoidance_weights.deinit(self.allocator);
        self.selected_avoidance_radii.deinit(self.allocator);
        self.selected_agent_radii.deinit(self.allocator);
        self.final_dir_y.deinit(self.allocator);
        self.final_dir_x.deinit(self.allocator);
        self.base_dir_y.deinit(self.allocator);
        self.base_dir_x.deinit(self.allocator);
        self.start_y.deinit(self.allocator);
        self.start_x.deinit(self.allocator);
        self.obstacle_candidate_counts.deinit(self.allocator);
        self.agent_candidate_counts.deinit(self.allocator);
        self.obstacle_counts.deinit(self.allocator);
        self.agent_neighbor_counts.deinit(self.allocator);
        self.runtime_index_by_steering.deinit(self.allocator);
        self.selected_index_by_steering.deinit(self.allocator);
        self.selected.deinit(self.allocator);
        self.runtime_rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *SteeringSystem, max_agents: usize) !void {
        try self.reserveForCapacity(max_agents, max_agents);
    }

    pub fn reserveForCapacity(self: *SteeringSystem, max_agents: usize, max_obstacles: usize) !void {
        // Reserve separates agent and obstacle budgets because dense static
        // obstacle scenes can be larger than the steering-agent population.
        try self.runtime_rows.ensureTotalCapacity(self.allocator, max_agents);
        try self.selected.ensureTotalCapacity(self.allocator, max_agents);
        try self.selected_index_by_steering.ensureTotalCapacity(self.allocator, max_agents);
        try self.runtime_index_by_steering.ensureTotalCapacity(self.allocator, max_agents);
        try self.agent_neighbor_counts.ensureTotalCapacity(self.allocator, max_agents);
        try self.obstacle_counts.ensureTotalCapacity(self.allocator, max_agents);
        try self.agent_candidate_counts.ensureTotalCapacity(self.allocator, max_agents);
        try self.obstacle_candidate_counts.ensureTotalCapacity(self.allocator, max_agents);
        try self.start_x.ensureTotalCapacity(self.allocator, max_agents);
        try self.start_y.ensureTotalCapacity(self.allocator, max_agents);
        try self.base_dir_x.ensureTotalCapacity(self.allocator, max_agents);
        try self.base_dir_y.ensureTotalCapacity(self.allocator, max_agents);
        try self.final_dir_x.ensureTotalCapacity(self.allocator, max_agents);
        try self.final_dir_y.ensureTotalCapacity(self.allocator, max_agents);
        try self.selected_agent_radii.ensureTotalCapacity(self.allocator, max_agents);
        try self.selected_avoidance_radii.ensureTotalCapacity(self.allocator, max_agents);
        try self.selected_avoidance_weights.ensureTotalCapacity(self.allocator, max_agents);
        try self.selected_max_neighbor_samples.ensureTotalCapacity(self.allocator, max_agents);
        try self.all_agent_entities.ensureTotalCapacity(self.allocator, max_agents);
        try self.all_agent_x.ensureTotalCapacity(self.allocator, max_agents);
        try self.all_agent_y.ensureTotalCapacity(self.allocator, max_agents);
        try self.all_agent_radii.ensureTotalCapacity(self.allocator, max_agents);
        try self.agent_cell_entries.ensureTotalCapacity(self.allocator, max_agents);
        try self.agent_cell_ranges.ensureTotalCapacity(self.allocator, max_agents);
        try self.obstacle_min_x.ensureTotalCapacity(self.allocator, max_obstacles);
        try self.obstacle_min_y.ensureTotalCapacity(self.allocator, max_obstacles);
        try self.obstacle_max_x.ensureTotalCapacity(self.allocator, max_obstacles);
        try self.obstacle_max_y.ensureTotalCapacity(self.allocator, max_obstacles);
        try self.obstacle_cell_entries.ensureTotalCapacity(self.allocator, max_obstacles);
        try self.obstacle_cell_ranges.ensureTotalCapacity(self.allocator, max_obstacles);
    }

    pub fn update(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        pathfinding: *const PathfindingSystem,
        config: SteeringConfig,
    ) !SteeringStats {
        var stats = try self.prepareUpdate(data, frame, pathfinding, config);
        try self.writePathRequests(frame, stats.path_request_count);
        stats.batch = try self.writeMovementIntentsThreaded(frame, thread_system, config);
        self.finishStats(&stats);
        return stats;
    }

    pub fn updateSerial(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        pathfinding: *const PathfindingSystem,
        config: SteeringConfig,
    ) !SteeringStats {
        var stats = try self.prepareUpdate(data, frame, pathfinding, config);
        try self.writePathRequests(frame, stats.path_request_count);
        stats.batch = try self.writeMovementIntentsSerial(frame);
        self.finishStats(&stats);
        return stats;
    }

    fn prepareUpdate(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        pathfinding: *const PathfindingSystem,
        config: SteeringConfig,
    ) !SteeringStats {
        // Preparation is single-threaded by design: it owns intent arbitration,
        // runtime-row mutation, path query decisions, and snapshot construction.
        const steering = data.steeringAgentSliceConst();
        self.pruneRuntimeRows(data);
        self.tickRuntimeRows();
        const navigation_intents = frame.navigation_intents.mergedItems();
        // Multiple systems may target the same entity. Selection keeps one
        // intent per steering row by priority, then source order for ties.
        try self.selectIntents(data, steering, navigation_intents, config);

        const movement = data.movementBodySliceConst();
        // Snapshot all avoidance inputs before dispatch so worker jobs never
        // touch DataSystem or pathfinding mutable state.
        try self.gatherWorldSnapshot(data, movement, steering, data.collisionBoundsSliceConst(), data.collisionResponseSliceConst());

        var stats = SteeringStats{
            .navigation_intent_count = navigation_intents.len,
            .selected_intent_count = self.selected.items.len,
        };

        try self.prepareSelectedDirections(data, movement, steering, pathfinding, &stats);
        return stats;
    }

    fn finishStats(self: *SteeringSystem, stats: *SteeringStats) void {
        stats.movement_intent_count = self.selected.items.len;
        stats.agent_neighbor_samples = sumU16(self.agent_neighbor_counts.items);
        stats.obstacle_samples = sumU16(self.obstacle_counts.items);
        stats.agent_candidate_checks = sumU16(self.agent_candidate_counts.items);
        stats.obstacle_candidate_checks = sumU16(self.obstacle_candidate_counts.items);
    }

    fn tickRuntimeRows(self: *SteeringSystem) void {
        // Cooldowns are fixed-step counters so path request cadence remains
        // deterministic under variable render frame timing.
        for (self.runtime_rows.items) |*row| {
            if (row.replan_cooldown > 0) row.replan_cooldown -= 1;
            if (row.unavailable_backoff > 0) row.unavailable_backoff -= 1;
        }
    }

    fn selectIntents(
        self: *SteeringSystem,
        data: *const DataSystem,
        steering: ConstSteeringAgentSlice,
        intents: []const NavigationIntent,
        config: SteeringConfig,
    ) !void {
        self.selected.clearRetainingCapacity();
        self.agent_neighbor_counts.clearRetainingCapacity();
        self.obstacle_counts.clearRetainingCapacity();
        self.agent_candidate_counts.clearRetainingCapacity();
        self.obstacle_candidate_counts.clearRetainingCapacity();
        self.clearSelectedWork();
        const limit = config.max_selected_intents orelse intents.len;
        try self.selected.ensureTotalCapacity(self.allocator, @min(intents.len, limit));
        try self.agent_neighbor_counts.ensureTotalCapacity(self.allocator, @min(intents.len, limit));
        try self.obstacle_counts.ensureTotalCapacity(self.allocator, @min(intents.len, limit));
        try self.agent_candidate_counts.ensureTotalCapacity(self.allocator, @min(intents.len, limit));
        try self.obstacle_candidate_counts.ensureTotalCapacity(self.allocator, @min(intents.len, limit));
        try resetIndexScratch(&self.selected_index_by_steering, self.allocator, steering.entities.len);

        for (intents, 0..) |intent, source_order| {
            const movement_index = data.movementBodyDenseIndex(intent.entity) orelse continue;
            const steering_index = data.steeringAgentDenseIndex(intent.entity) orelse continue;
            const existing_index = self.selected_index_by_steering.items[steering_index];
            if (existing_index != invalid_index) {
                if (intentIsBetter(intent.priority, source_order, self.selected.items[existing_index])) {
                    self.selected.items[existing_index] = .{
                        .entity = intent.entity,
                        .movement_index = movement_index,
                        .steering_index = steering_index,
                        .source_order = source_order,
                        .intent = intent,
                    };
                }
                continue;
            }
            if (self.selected.items.len >= limit) {
                const replace_index = lowestPrioritySelectedIndex(self.selected.items) orelse continue;
                if (!intentIsBetter(intent.priority, source_order, self.selected.items[replace_index])) continue;
                self.selected_index_by_steering.items[self.selected.items[replace_index].steering_index] = invalid_index;
                self.selected_index_by_steering.items[steering_index] = replace_index;
                self.selected.items[replace_index] = .{
                    .entity = intent.entity,
                    .movement_index = movement_index,
                    .steering_index = steering_index,
                    .source_order = source_order,
                    .intent = intent,
                };
                continue;
            }
            self.selected_index_by_steering.items[steering_index] = self.selected.items.len;
            self.selected.appendAssumeCapacity(.{
                .entity = intent.entity,
                .movement_index = movement_index,
                .steering_index = steering_index,
                .source_order = source_order,
                .intent = intent,
            });
            self.agent_neighbor_counts.appendAssumeCapacity(0);
            self.obstacle_counts.appendAssumeCapacity(0);
            self.agent_candidate_counts.appendAssumeCapacity(0);
            self.obstacle_candidate_counts.appendAssumeCapacity(0);
        }
        if (config.max_selected_intents != null) {
            // Capped selection can replace lower-priority entries out of source
            // order; sort restores deterministic emission order.
            std.mem.sort(SelectedIntent, self.selected.items, {}, selectedIntentLessThan);
        }
    }

    fn clearSelectedWork(self: *SteeringSystem) void {
        self.start_x.clearRetainingCapacity();
        self.start_y.clearRetainingCapacity();
        self.base_dir_x.clearRetainingCapacity();
        self.base_dir_y.clearRetainingCapacity();
        self.final_dir_x.clearRetainingCapacity();
        self.final_dir_y.clearRetainingCapacity();
        self.selected_agent_radii.clearRetainingCapacity();
        self.selected_avoidance_radii.clearRetainingCapacity();
        self.selected_avoidance_weights.clearRetainingCapacity();
        self.selected_max_neighbor_samples.clearRetainingCapacity();
    }

    fn gatherWorldSnapshot(
        self: *SteeringSystem,
        data: *const DataSystem,
        movement: ConstMovementBodySlice,
        steering: ConstSteeringAgentSlice,
        collision_bounds: ConstCollisionBoundsSlice,
        collision_responses: ConstCollisionResponseSlice,
    ) !void {
        // The snapshot uses previous fixed-step positions. Steering output for
        // this step should not depend on partially updated movement columns.
        self.all_agent_entities.clearRetainingCapacity();
        self.all_agent_x.clearRetainingCapacity();
        self.all_agent_y.clearRetainingCapacity();
        self.all_agent_radii.clearRetainingCapacity();
        self.agent_cell_entries.clearRetainingCapacity();
        self.agent_cell_ranges.clearRetainingCapacity();
        self.obstacle_min_x.clearRetainingCapacity();
        self.obstacle_min_y.clearRetainingCapacity();
        self.obstacle_max_x.clearRetainingCapacity();
        self.obstacle_max_y.clearRetainingCapacity();
        self.obstacle_cell_entries.clearRetainingCapacity();
        self.obstacle_cell_ranges.clearRetainingCapacity();
        self.spatial_cell_size = spatialCellSize(steering);
        self.spatial_obstacle_query_extra = 0;

        try self.all_agent_entities.ensureTotalCapacity(self.allocator, steering.entities.len);
        try self.all_agent_x.ensureTotalCapacity(self.allocator, steering.entities.len);
        try self.all_agent_y.ensureTotalCapacity(self.allocator, steering.entities.len);
        try self.all_agent_radii.ensureTotalCapacity(self.allocator, steering.entities.len);
        try self.agent_cell_entries.ensureTotalCapacity(self.allocator, steering.entities.len);
        try self.agent_cell_ranges.ensureTotalCapacity(self.allocator, steering.entities.len);
        for (steering.entities, 0..) |entity, steering_index| {
            const movement_index = data.movementBodyDenseIndex(entity) orelse continue;
            self.all_agent_entities.appendAssumeCapacity(entity);
            self.all_agent_x.appendAssumeCapacity(movement.previous_x[movement_index]);
            self.all_agent_y.appendAssumeCapacity(movement.previous_y[movement_index]);
            self.all_agent_radii.appendAssumeCapacity(steering.agent_radii[steering_index]);
        }

        try self.obstacle_min_x.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        try self.obstacle_min_y.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        try self.obstacle_max_x.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        try self.obstacle_max_y.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        try self.obstacle_cell_entries.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        try self.obstacle_cell_ranges.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        for (collision_responses.entities, 0..) |obstacle_entity, response_index| {
            if (collision_responses.mobilities[response_index] != .static) continue;
            const bounds_index = data.collisionBoundsDenseIndex(obstacle_entity) orelse continue;
            const movement_index = data.movementBodyDenseIndex(obstacle_entity) orelse continue;
            const min_x = movement.previous_x[movement_index] + collision_bounds.offset_x[bounds_index];
            const min_y = movement.previous_y[movement_index] + collision_bounds.offset_y[bounds_index];
            const size_x = collision_bounds.size_x[bounds_index];
            const size_y = collision_bounds.size_y[bounds_index];
            self.spatial_obstacle_query_extra = @max(self.spatial_obstacle_query_extra, @max(size_x, size_y) * 0.5);
            self.obstacle_min_x.appendAssumeCapacity(min_x);
            self.obstacle_min_y.appendAssumeCapacity(min_y);
            self.obstacle_max_x.appendAssumeCapacity(min_x + size_x);
            self.obstacle_max_y.appendAssumeCapacity(min_y + size_y);
        }
        try self.buildSpatialIndexes();
    }

    fn buildSpatialIndexes(self: *SteeringSystem) !void {
        // Entries are sorted into compact cell ranges so worker queries do a
        // binary search per neighboring cell instead of scanning every actor.
        for (self.all_agent_entities.items, 0..) |_, index| {
            const cell_x = spatialCell(self.all_agent_x.items[index], self.spatial_cell_size);
            const cell_y = spatialCell(self.all_agent_y.items[index], self.spatial_cell_size);
            self.agent_cell_entries.appendAssumeCapacity(.{
                .cell_x = cell_x,
                .cell_y = cell_y,
                .index = index,
            });
        }
        try buildCellRanges(self.agent_cell_entries.items, &self.agent_cell_ranges, self.allocator);

        for (self.obstacle_min_x.items, self.obstacle_min_y.items, self.obstacle_max_x.items, self.obstacle_max_y.items, 0..) |min_x, min_y, max_x, max_y, index| {
            const center_x = (min_x + max_x) * 0.5;
            const center_y = (min_y + max_y) * 0.5;
            const cell_x = spatialCell(center_x, self.spatial_cell_size);
            const cell_y = spatialCell(center_y, self.spatial_cell_size);
            self.obstacle_cell_entries.appendAssumeCapacity(.{
                .cell_x = cell_x,
                .cell_y = cell_y,
                .index = index,
            });
        }
        try buildCellRanges(self.obstacle_cell_entries.items, &self.obstacle_cell_ranges, self.allocator);
    }

    fn prepareSelectedDirections(
        self: *SteeringSystem,
        data: *const DataSystem,
        movement: ConstMovementBodySlice,
        steering: ConstSteeringAgentSlice,
        pathfinding: *const PathfindingSystem,
        stats: *SteeringStats,
    ) !void {
        // This stage turns pathfinding status into base directions and marks any
        // path requests that should be appended before movement intents.
        const count = self.selected.items.len;
        try self.start_x.ensureTotalCapacity(self.allocator, count);
        try self.start_y.ensureTotalCapacity(self.allocator, count);
        try self.base_dir_x.ensureTotalCapacity(self.allocator, count);
        try self.base_dir_y.ensureTotalCapacity(self.allocator, count);
        try self.final_dir_x.ensureTotalCapacity(self.allocator, count);
        try self.final_dir_y.ensureTotalCapacity(self.allocator, count);
        try self.selected_agent_radii.ensureTotalCapacity(self.allocator, count);
        try self.selected_avoidance_radii.ensureTotalCapacity(self.allocator, count);
        try self.selected_avoidance_weights.ensureTotalCapacity(self.allocator, count);
        try self.selected_max_neighbor_samples.ensureTotalCapacity(self.allocator, count);
        try resetIndexScratch(&self.runtime_index_by_steering, self.allocator, steering.entities.len);
        for (self.runtime_rows.items, 0..) |row, runtime_index| {
            const steering_index = data.steeringAgentDenseIndex(row.entity) orelse continue;
            self.runtime_index_by_steering.items[steering_index] = runtime_index;
        }

        var request_count: usize = 0;
        for (self.selected.items) |*selected| {
            const steering_agent = steeringAgentAt(steering, selected.steering_index);
            const start = math.Vec2{
                .x = movement.previous_x[selected.movement_index],
                .y = movement.previous_y[selected.movement_index],
            };
            const runtime = try self.runtimeRowForSelected(selected);
            const path_dir = self.directionFromPathStatus(pathfinding, selected, start, steering_agent, runtime, stats, &request_count);
            const direct_dir = math.normalizeOrZeroFinite(selected.intent.direct_direction_x, selected.intent.direct_direction_y, 0.0001);
            const base_dir = if (path_dir.has_direction) path_dir.direction else direct_dir;

            self.updateProgress(selected, runtime, path_dir.progress_distance, steering_agent, path_dir.status_allows_replan, stats, &request_count);
            self.start_x.appendAssumeCapacity(start.x);
            self.start_y.appendAssumeCapacity(start.y);
            self.base_dir_x.appendAssumeCapacity(base_dir.x);
            self.base_dir_y.appendAssumeCapacity(base_dir.y);
            self.final_dir_x.appendAssumeCapacity(0);
            self.final_dir_y.appendAssumeCapacity(0);
            self.selected_agent_radii.appendAssumeCapacity(steering_agent.agent_radius);
            self.selected_avoidance_radii.appendAssumeCapacity(steering_agent.avoidance_radius);
            self.selected_avoidance_weights.appendAssumeCapacity(steering_agent.avoidance_weight);
            self.selected_max_neighbor_samples.appendAssumeCapacity(steering_agent.max_neighbor_samples);
        }
        stats.path_request_count = request_count;
    }

    fn writePathRequests(self: *SteeringSystem, frame: *SimulationFrame, request_count: usize) !void {
        // Agents have no per-entity level column yet, so the start level is the
        // single-level default; a per-entity lookup replaces this when multi-level
        // placement exists.
        const agent_start_level: u16 = 0;
        const request_range_base = try frame.path_requests.appendRangeCounts(1);
        frame.path_requests.addCount(request_range_base, request_count);
        try frame.path_requests.prefixAppendedRanges(request_range_base);
        var request_writer = frame.path_requests.rangeWriter(request_range_base);
        // Path requests are appended as their own range so steering can coexist
        // with future producers without rebuilding earlier stream offsets.
        for (self.selected.items, 0..) |selected, index| {
            if (!selected.emit_path_request) continue;
            request_writer.write(PathRequest{
                .entity = selected.entity,
                .agent_class = selected.intent.agent_class,
                .kind = selected.intent.kind,
                // No per-entity level store exists yet, so the agent's start level
                // is the single-level default (0). When real multi-level placement
                // lands, source this from a per-entity level column.
                .start_level = agent_start_level,
                .goal_level = selected.intent.goal_level,
                .start = .{ .x = self.start_x.items[index], .y = self.start_y.items[index] },
                .goal = selected.intent.goal,
            });
        }
        request_writer.finish();
        frame.path_requests.finishWrite();
    }

    fn writeMovementIntentsThreaded(
        self: *SteeringSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        config: SteeringConfig,
    ) !BatchStats {
        // Each worker range writes a matching SimulationFrame output range. The
        // range prefixing happens before dispatch so writers never resize.
        const count = self.selected.items.len;
        if (count == 0) return .{};
        const work = selectSteeringWork(thread_system, count, config, self);
        const range_base = try frame.intents.appendRangeCounts(work.range_count);
        for (0..work.range_count) |range_index| {
            const start = range_index * work.items_per_range;
            const end = @min(start + work.items_per_range, count);
            frame.intents.addCount(range_base + range_index, end - start);
        }
        try frame.intents.prefixAppendedRanges(range_base);

        var context = self.jobContext(frame, range_base);
        const batch = thread_system.parallelForWithOptions(count, &context, writeSteeringMovementJob, .{
            .items_per_range = work.items_per_range,
            .max_worker_threads = work.worker_threads,
            .range_alignment_items = steering_range_alignment_items,
            .adaptive_tuner = work.active_tuner,
            .selected_profile = work.profile,
        });
        frame.intents.finishWrite();
        return batch;
    }

    fn writeMovementIntentsSerial(self: *SteeringSystem, frame: *SimulationFrame) !BatchStats {
        const count = self.selected.items.len;
        if (count == 0) return .{};
        const range_base = try frame.intents.appendRangeCounts(1);
        frame.intents.addCount(range_base, count);
        try frame.intents.prefixAppendedRanges(range_base);
        var context = self.jobContext(frame, range_base);
        writeSteeringMovementJob(&context, .{ .index = 0, .start = 0, .end = count }, WorkerId.main);
        frame.intents.finishWrite();
        return serialBatch(count);
    }

    fn directionFromPathStatus(
        self: *SteeringSystem,
        pathfinding: *const PathfindingSystem,
        selected: *SelectedIntent,
        start: math.Vec2,
        steering_agent: SteeringAgentView,
        runtime: *RuntimeRow,
        stats: *SteeringStats,
        request_count: *usize,
    ) PathDirection {
        _ = self;
        // Missing paths request work, pending paths hold direction, unavailable
        // paths enter backoff, and available paths steer toward the next waypoint.
        // Single-level default start level (0).
        const goal_distance = distance(start, selected.intent.goal);
        const view = pathfinding.statusForEntityWorld(selected.entity, 0, start, selected.intent.goal_level, selected.intent.goal, selected.intent.agent_class);
        switch (view.status) {
            .available => {
                stats.path_available_count += 1;
                const to_waypoint = math.Vec2{
                    .x = view.next_waypoint.x - start.x,
                    .y = view.next_waypoint.y - start.y,
                };
                if (math.lengthSquared(to_waypoint) <= steering_agent.waypoint_tolerance * steering_agent.waypoint_tolerance) {
                    // At the waypoint: steer straight to the goal, so progress is goal distance.
                    return .{ .has_direction = true, .direction = math.normalizeOrZeroFinite(selected.intent.goal.x - start.x, selected.intent.goal.y - start.y, 0.0001), .status_allows_replan = true, .progress_distance = goal_distance };
                }
                // Following the path: progress is closing on the next waypoint, which a
                // detour reduces even while straight-line goal distance grows.
                return .{ .has_direction = true, .direction = math.normalizeOrZeroFinite(to_waypoint.x, to_waypoint.y, 0.0001), .status_allows_replan = true, .progress_distance = math.length(to_waypoint) };
            },
            .missing => {
                if (runtime.replan_cooldown == 0 and runtime.unavailable_backoff == 0) {
                    selected.emit_path_request = true;
                    runtime.replan_cooldown = steering_agent.replan_cooldown_steps;
                    request_count.* += 1;
                } else {
                    stats.replan_cooldown_count += 1;
                }
                return .{ .status_allows_replan = true, .progress_distance = goal_distance };
            },
            .pending => {
                stats.path_pending_count += 1;
                return .{ .progress_distance = goal_distance };
            },
            .unavailable => {
                stats.path_unavailable_count += 1;
                if (runtime.unavailable_backoff == 0) {
                    runtime.unavailable_backoff = steering_agent.unavailable_backoff_steps;
                } else {
                    stats.unavailable_backoff_count += 1;
                }
                return .{ .progress_distance = goal_distance };
            },
        }
    }

    fn updateProgress(
        self: *SteeringSystem,
        selected: *SelectedIntent,
        runtime: *RuntimeRow,
        progress_distance: f32,
        steering_agent: SteeringAgentView,
        status_allows_replan: bool,
        stats: *SteeringStats,
        request_count: *usize,
    ) void {
        _ = self;
        // Stuck detection watches distance to the active steering target (next
        // waypoint, or goal when direct), not instantaneous velocity, so local
        // avoidance jitter does not immediately trigger replans and an agent walking
        // a detour around an obstacle is not mistaken for stuck.
        const progress_epsilon: f32 = 0.25;
        if (runtime.has_previous_distance and progress_distance + progress_epsilon >= runtime.previous_progress_distance) {
            if (runtime.stuck_steps < std.math.maxInt(u16)) runtime.stuck_steps += 1;
        } else {
            runtime.stuck_steps = 0;
        }
        runtime.previous_progress_distance = progress_distance;
        runtime.has_previous_distance = true;

        if (status_allows_replan and steering_agent.stuck_step_threshold > 0 and
            runtime.stuck_steps >= steering_agent.stuck_step_threshold and
            runtime.replan_cooldown == 0 and runtime.unavailable_backoff == 0)
        {
            runtime.stuck_steps = 0;
            runtime.replan_cooldown = steering_agent.replan_cooldown_steps;
            if (!selected.emit_path_request) {
                selected.emit_path_request = true;
                request_count.* += 1;
                stats.stuck_replan_count += 1;
            }
        }
    }

    fn runtimeRowForSelected(self: *SteeringSystem, selected: *const SelectedIntent) !*RuntimeRow {
        const existing_index = self.runtime_index_by_steering.items[selected.steering_index];
        if (existing_index != invalid_index) return &self.runtime_rows.items[existing_index];
        try self.runtime_rows.ensureTotalCapacity(self.allocator, self.runtime_rows.items.len + 1);
        self.runtime_index_by_steering.items[selected.steering_index] = self.runtime_rows.items.len;
        self.runtime_rows.appendAssumeCapacity(.{ .entity = selected.entity });
        return &self.runtime_rows.items[self.runtime_rows.items.len - 1];
    }

    fn pruneRuntimeRows(self: *SteeringSystem, data: *const DataSystem) void {
        var index: usize = 0;
        while (index < self.runtime_rows.items.len) {
            if (data.steeringAgentDenseIndex(self.runtime_rows.items[index].entity) != null) {
                index += 1;
                continue;
            }
            const last = self.runtime_rows.items.len - 1;
            self.runtime_rows.items[index] = self.runtime_rows.items[last];
            _ = self.runtime_rows.pop();
        }
    }

    fn jobContext(self: *SteeringSystem, frame: *SimulationFrame, range_base: usize) SteeringJobContext {
        return .{
            .selected = self.selected.items,
            .start_x = self.start_x.items,
            .start_y = self.start_y.items,
            .base_dir_x = self.base_dir_x.items,
            .base_dir_y = self.base_dir_y.items,
            .final_dir_x = self.final_dir_x.items,
            .final_dir_y = self.final_dir_y.items,
            .selected_agent_radii = self.selected_agent_radii.items,
            .selected_avoidance_radii = self.selected_avoidance_radii.items,
            .selected_avoidance_weights = self.selected_avoidance_weights.items,
            .selected_max_neighbor_samples = self.selected_max_neighbor_samples.items,
            .all_agent_entities = self.all_agent_entities.items,
            .all_agent_x = self.all_agent_x.items,
            .all_agent_y = self.all_agent_y.items,
            .all_agent_radii = self.all_agent_radii.items,
            .agent_cell_entries = self.agent_cell_entries.items,
            .agent_cell_ranges = self.agent_cell_ranges.items,
            .obstacle_min_x = self.obstacle_min_x.items,
            .obstacle_min_y = self.obstacle_min_y.items,
            .obstacle_max_x = self.obstacle_max_x.items,
            .obstacle_max_y = self.obstacle_max_y.items,
            .obstacle_cell_entries = self.obstacle_cell_entries.items,
            .obstacle_cell_ranges = self.obstacle_cell_ranges.items,
            .spatial_cell_size = self.spatial_cell_size,
            .spatial_obstacle_query_extra = self.spatial_obstacle_query_extra,
            .agent_neighbor_counts = self.agent_neighbor_counts.items,
            .obstacle_counts = self.obstacle_counts.items,
            .agent_candidate_counts = self.agent_candidate_counts.items,
            .obstacle_candidate_counts = self.obstacle_candidate_counts.items,
            .intents = &frame.intents,
            .range_base = range_base,
        };
    }
};

const SelectedIntent = struct {
    // Stable source_order keeps arbitration deterministic when priorities tie or
    // capped selection has to replace an earlier choice.
    entity: EntityId,
    movement_index: usize,
    steering_index: usize,
    source_order: usize = 0,
    intent: NavigationIntent,
    emit_path_request: bool = false,
};

const RuntimeRow = struct {
    // Runtime state is intentionally separate from SteeringAgent component data;
    // it is simulation-local and safe to discard when the component is removed.
    entity: EntityId,
    previous_progress_distance: f32 = 0,
    has_previous_distance: bool = false,
    stuck_steps: u16 = 0,
    replan_cooldown: u16 = 0,
    unavailable_backoff: u16 = 0,
};

const SteeringAgentView = struct {
    agent_radius: f32,
    waypoint_tolerance: f32,
    avoidance_radius: f32,
    avoidance_weight: f32,
    max_neighbor_samples: u16,
    stuck_step_threshold: u16,
    replan_cooldown_steps: u16,
    unavailable_backoff_steps: u16,
};

const PathDirection = struct {
    has_direction: bool = false,
    direction: math.Vec2 = .{},
    status_allows_replan: bool = false,
    // Distance from the agent to the point it is actually steering toward this step
    // (the next path waypoint, or the goal when steering direct). Stuck detection
    // measures progress against this, not the straight-line goal distance, so an
    // agent correctly walking a detour around an obstacle is not flagged stuck.
    progress_distance: f32 = 0,
};

const SteeringWorkSelection = struct {
    profile: AdaptiveWorkProfile,
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
    active_tuner: ?*AdaptiveWorkTuner = null,
};

const SteeringJobContext = struct {
    // Worker context is immutable input plus range-indexed output columns and a
    // pre-prefixed SimulationFrame stream.
    selected: []const SelectedIntent,
    start_x: []const f32,
    start_y: []const f32,
    base_dir_x: []const f32,
    base_dir_y: []const f32,
    final_dir_x: []f32,
    final_dir_y: []f32,
    selected_agent_radii: []const f32,
    selected_avoidance_radii: []const f32,
    selected_avoidance_weights: []const f32,
    selected_max_neighbor_samples: []const u16,
    all_agent_entities: []const EntityId,
    all_agent_x: []const f32,
    all_agent_y: []const f32,
    all_agent_radii: []const f32,
    agent_cell_entries: []const SpatialCellEntry,
    agent_cell_ranges: []const SpatialCellRange,
    obstacle_min_x: []const f32,
    obstacle_min_y: []const f32,
    obstacle_max_x: []const f32,
    obstacle_max_y: []const f32,
    obstacle_cell_entries: []const SpatialCellEntry,
    obstacle_cell_ranges: []const SpatialCellRange,
    spatial_cell_size: f32,
    spatial_obstacle_query_extra: f32,
    agent_neighbor_counts: []u16,
    obstacle_counts: []u16,
    agent_candidate_counts: []u16,
    obstacle_candidate_counts: []u16,
    intents: *RangeOutputStream(SimulationIntent),
    range_base: usize,
};

const AvoidanceResult = struct {
    direction: math.Vec2,
    agent_samples: u16 = 0,
    obstacle_samples: u16 = 0,
    agent_candidate_checks: u16 = 0,
    obstacle_candidate_checks: u16 = 0,
};

const SpatialCellEntry = struct {
    cell_x: i32,
    cell_y: i32,
    index: usize,
};

const SpatialCellRange = struct {
    cell_x: i32,
    cell_y: i32,
    start: usize,
    end: usize,
};

fn writeSteeringMovementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    // Jobs never append outside their assigned output range, which keeps the
    // transient intent stream deterministic across serial and threaded runs.
    const job: *SteeringJobContext = @ptrCast(@alignCast(context));
    var writer = job.intents.rangeWriter(job.range_base + range.index);
    for (range.start..range.end) |index| {
        const result = computeAvoidance(job, index);
        job.final_dir_x[index] = result.direction.x;
        job.final_dir_y[index] = result.direction.y;
        job.agent_neighbor_counts[index] = result.agent_samples;
        job.obstacle_counts[index] = result.obstacle_samples;
        job.agent_candidate_counts[index] = result.agent_candidate_checks;
        job.obstacle_candidate_counts[index] = result.obstacle_candidate_checks;
        writer.write(.{ .movement = MovementIntent{
            .entity = job.selected[index].entity,
            .direction_x = result.direction.x,
            .direction_y = result.direction.y,
        } });
    }
    writer.finish();
}

fn computeAvoidance(job: *const SteeringJobContext, index: usize) AvoidanceResult {
    // Start with the path/direct base direction, then add bounded local pushes
    // from nearby agents and static obstacle boxes.
    var ax = job.base_dir_x[index];
    var ay = job.base_dir_y[index];
    var sample_count: u16 = 0;
    var agent_candidate_count: u16 = 0;
    const max_samples = job.selected_max_neighbor_samples[index];
    if (max_samples > 0) {
        accumulateAgentAvoidanceBounded(job, index, &ax, &ay, &sample_count, &agent_candidate_count, max_samples);
    }

    var obstacle_count: u16 = 0;
    var obstacle_candidate_count: u16 = 0;
    const start_x = job.start_x[index];
    const start_y = job.start_y[index];
    const radius = job.selected_avoidance_radii[index] + job.selected_agent_radii[index];
    const weight = job.selected_avoidance_weights[index];
    const obstacle_query_radius = radius + job.spatial_obstacle_query_extra;
    const min_cell_x = spatialCell(start_x - obstacle_query_radius, job.spatial_cell_size);
    const max_cell_x = spatialCell(start_x + obstacle_query_radius, job.spatial_cell_size);
    const min_cell_y = spatialCell(start_y - obstacle_query_radius, job.spatial_cell_size);
    const max_cell_y = spatialCell(start_y + obstacle_query_radius, job.spatial_cell_size);
    var cell_y = min_cell_y;
    while (cell_y <= max_cell_y and obstacle_candidate_count < max_obstacle_candidate_checks) : (cell_y += 1) {
        var cell_x = min_cell_x;
        while (cell_x <= max_cell_x and obstacle_candidate_count < max_obstacle_candidate_checks) : (cell_x += 1) {
            const range = findCellRange(job.obstacle_cell_ranges, cell_x, cell_y) orelse continue;
            for (job.obstacle_cell_entries[range.start..range.end]) |entry| {
                if (obstacle_candidate_count >= max_obstacle_candidate_checks) break;
                obstacle_candidate_count += 1;
                const obstacle_index = entry.index;
                accumulateObstacleSample(job, obstacle_index, start_x, start_y, radius, weight, &ax, &ay, &obstacle_count);
            }
        }
    }

    return .{
        .direction = math.normalizeOrZeroFinite(ax, ay, 0.0001),
        .agent_samples = sample_count,
        .obstacle_samples = obstacle_count,
        .agent_candidate_checks = agent_candidate_count,
        .obstacle_candidate_checks = obstacle_candidate_count,
    };
}

fn accumulateObstacleSample(
    job: *const SteeringJobContext,
    obstacle_index: usize,
    start_x: f32,
    start_y: f32,
    radius: f32,
    weight: f32,
    ax: *f32,
    ay: *f32,
    obstacle_count: *u16,
) void {
    // Axis-aligned obstacle push uses the closest point on the box. If the agent
    // is inside the box, push away from the center to avoid a zero vector.
    const min_x = job.obstacle_min_x[obstacle_index];
    const min_y = job.obstacle_min_y[obstacle_index];
    const max_x = job.obstacle_max_x[obstacle_index];
    const max_y = job.obstacle_max_y[obstacle_index];
    const closest_x = math.clampMinMax(start_x, min_x, max_x);
    const closest_y = math.clampMinMax(start_y, min_y, max_y);
    var dx = start_x - closest_x;
    var dy = start_y - closest_y;
    if (dx == 0 and dy == 0) {
        dx = start_x - (min_x + max_x) * 0.5;
        dy = start_y - (min_y + max_y) * 0.5;
    }
    const dist2 = dx * dx + dy * dy;
    if (dist2 > 0.0001 and dist2 < radius * radius) {
        const dist = @sqrt(dist2);
        const strength = (1.0 - dist / radius) * weight;
        ax.* += (dx / dist) * strength;
        ay.* += (dy / dist) * strength;
        obstacle_count.* += 1;
    }
}

fn accumulateAgentAvoidanceBounded(
    job: *const SteeringJobContext,
    index: usize,
    ax: *f32,
    ay: *f32,
    sample_count: *u16,
    candidate_count: *u16,
    max_samples: u16,
) void {
    // Candidate and sample caps are separate: candidate caps bound dense-cell
    // cost, while sample caps keep behavior stable for configured agents.
    const start_x = job.start_x[index];
    const start_y = job.start_y[index];
    const avoidance_radius = job.selected_avoidance_radii[index];
    const query_radius = avoidance_radius + job.selected_agent_radii[index];
    const weight = job.selected_avoidance_weights[index];
    const self_entity = job.selected[index].entity;
    const min_cell_x = spatialCell(start_x - query_radius, job.spatial_cell_size);
    const max_cell_x = spatialCell(start_x + query_radius, job.spatial_cell_size);
    const min_cell_y = spatialCell(start_y - query_radius, job.spatial_cell_size);
    const max_cell_y = spatialCell(start_y + query_radius, job.spatial_cell_size);

    var cell_y = min_cell_y;
    while (cell_y <= max_cell_y and sample_count.* < max_samples and candidate_count.* < max_agent_candidate_checks) : (cell_y += 1) {
        var cell_x = min_cell_x;
        while (cell_x <= max_cell_x and sample_count.* < max_samples and candidate_count.* < max_agent_candidate_checks) : (cell_x += 1) {
            const range = findCellRange(job.agent_cell_ranges, cell_x, cell_y) orelse continue;
            for (job.agent_cell_entries[range.start..range.end]) |entry| {
                if (sample_count.* >= max_samples or candidate_count.* >= max_agent_candidate_checks) break;
                candidate_count.* += 1;
                const other_index = entry.index;
                if (entityIdsEqual(job.all_agent_entities[other_index], self_entity)) continue;
                const dx = start_x - job.all_agent_x[other_index];
                const dy = start_y - job.all_agent_y[other_index];
                const combined_radius = avoidance_radius + job.all_agent_radii[other_index];
                const dist2 = dx * dx + dy * dy;
                if (dist2 > 0.0001 and dist2 < combined_radius * combined_radius) {
                    accumulateAgentSample(dx, dy, dist2, combined_radius, weight, ax, ay, sample_count);
                }
            }
        }
    }
}

fn accumulateAgentSample(
    dx: f32,
    dy: f32,
    dist2: f32,
    combined_radius: f32,
    weight: f32,
    ax: *f32,
    ay: *f32,
    sample_count: *u16,
) void {
    const dist = @sqrt(dist2);
    const strength = (1.0 - dist / combined_radius) * weight;
    ax.* += (dx / dist) * strength;
    ay.* += (dy / dist) * strength;
    sample_count.* += 1;
}

fn selectSteeringWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    config: SteeringConfig,
    system: *SteeringSystem,
) SteeringWorkSelection {
    // Steering owns its tuner because avoidance cost differs from movement,
    // pathfinding, and render-prep work even when item counts are similar.
    const available_workers = thread_system.workerThreadCount();
    const max_worker_threads = @min(config.max_worker_threads orelse available_workers, available_workers);
    const requested_items_per_range = config.items_per_range orelse thread_system.config.items_per_range;
    const active_tuner = if (config.adaptive and config.items_per_range == null and max_worker_threads > 0)
        config.adaptive_tuner orelse &system.adaptive_tuner
    else
        null;
    const profile = if (active_tuner) |tuner|
        tuner.selectProfile(.{
            .item_count = item_count,
            .available_worker_threads = available_workers,
            .max_worker_threads = max_worker_threads,
            .fallback_items_per_range = requested_items_per_range,
            .range_alignment_items = steering_range_alignment_items,
        })
    else
        AdaptiveWorkProfile{
            .worker_threads = max_worker_threads,
            .items_per_range = requested_items_per_range,
        };
    const aligned_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), steering_range_alignment_items);
    const selected_range_count = rangeCount(item_count, aligned_items_per_range);
    const selected_worker_threads = if (selected_range_count <= 1)
        @as(usize, 0)
    else
        @min(profile.worker_threads, @min(max_worker_threads, selected_range_count - 1));
    const items_per_range = if (selected_worker_threads == 0 and active_tuner != null and profile.worker_threads == 0)
        item_count
    else
        aligned_items_per_range;

    return .{
        .profile = .{
            .worker_threads = selected_worker_threads,
            .items_per_range = items_per_range,
        },
        .items_per_range = items_per_range,
        .worker_threads = selected_worker_threads,
        .range_count = rangeCount(item_count, items_per_range),
        .active_tuner = active_tuner,
    };
}

fn steeringAgentAt(slice: ConstSteeringAgentSlice, index: usize) SteeringAgentView {
    return .{
        .agent_radius = slice.agent_radii[index],
        .waypoint_tolerance = slice.waypoint_tolerances[index],
        .avoidance_radius = slice.avoidance_radii[index],
        .avoidance_weight = slice.avoidance_weights[index],
        .max_neighbor_samples = slice.max_neighbor_samples[index],
        .stuck_step_threshold = slice.stuck_step_thresholds[index],
        .replan_cooldown_steps = slice.replan_cooldown_steps[index],
        .unavailable_backoff_steps = slice.unavailable_backoff_steps[index],
    };
}

fn lowestPrioritySelectedIndex(items: []const SelectedIntent) ?usize {
    if (items.len == 0) return null;
    var worst_index: usize = 0;
    for (items[1..], 1..) |item, index| {
        const worst = items[worst_index];
        if (item.intent.priority < worst.intent.priority or
            (item.intent.priority == worst.intent.priority and item.source_order > worst.source_order))
        {
            worst_index = index;
        }
    }
    return worst_index;
}

fn intentIsBetter(priority: i16, source_order: usize, selected: SelectedIntent) bool {
    return priority > selected.intent.priority or
        (priority == selected.intent.priority and source_order < selected.source_order);
}

fn selectedIntentLessThan(_: void, lhs: SelectedIntent, rhs: SelectedIntent) bool {
    return lhs.intent.priority > rhs.intent.priority or
        (lhs.intent.priority == rhs.intent.priority and lhs.source_order < rhs.source_order);
}

fn resetIndexScratch(values: *std.ArrayList(usize), allocator: std.mem.Allocator, count: usize) !void {
    try values.ensureTotalCapacity(allocator, count);
    values.items.len = count;
    @memset(values.items, invalid_index);
}

fn buildCellRanges(entries: []SpatialCellEntry, ranges: *std.ArrayList(SpatialCellRange), allocator: std.mem.Allocator) !void {
    // The sorted entry array remains the payload; ranges only mark contiguous
    // windows for each occupied spatial cell.
    ranges.clearRetainingCapacity();
    if (entries.len == 0) return;

    std.mem.sort(SpatialCellEntry, entries, {}, spatialCellEntryLessThan);
    try ranges.ensureTotalCapacity(allocator, entries.len);

    var entry_index: usize = 0;
    while (entry_index < entries.len) {
        const cell_x = entries[entry_index].cell_x;
        const cell_y = entries[entry_index].cell_y;
        const start = entry_index;
        while (entry_index < entries.len and entries[entry_index].cell_x == cell_x and entries[entry_index].cell_y == cell_y) {
            entry_index += 1;
        }
        ranges.appendAssumeCapacity(.{
            .cell_x = cell_x,
            .cell_y = cell_y,
            .start = start,
            .end = entry_index,
        });
    }
}

fn spatialCellEntryLessThan(_: void, lhs: SpatialCellEntry, rhs: SpatialCellEntry) bool {
    if (lhs.cell_y != rhs.cell_y) return lhs.cell_y < rhs.cell_y;
    if (lhs.cell_x != rhs.cell_x) return lhs.cell_x < rhs.cell_x;
    return lhs.index < rhs.index;
}

fn findCellRange(ranges: []const SpatialCellRange, cell_x: i32, cell_y: i32) ?SpatialCellRange {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (cellLessThan(range.cell_x, range.cell_y, cell_x, cell_y)) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low >= ranges.len) return null;
    const range = ranges[low];
    if (range.cell_x == cell_x and range.cell_y == cell_y) return range;
    return null;
}

fn cellLessThan(lhs_x: i32, lhs_y: i32, rhs_x: i32, rhs_y: i32) bool {
    return lhs_y < rhs_y or (lhs_y == rhs_y and lhs_x < rhs_x);
}

fn spatialCellSize(steering: ConstSteeringAgentSlice) f32 {
    var largest_radius: f32 = min_spatial_cell_size;
    for (steering.avoidance_radii, steering.agent_radii) |avoidance_radius, agent_radius| {
        largest_radius = @max(largest_radius, avoidance_radius + agent_radius);
    }
    return @max(largest_radius, min_spatial_cell_size);
}

fn spatialCell(value: f32, cell_size: f32) i32 {
    return math.floorToI32(value / @max(cell_size, min_spatial_cell_size));
}

fn distance(a: math.Vec2, b: math.Vec2) f32 {
    return math.length(.{ .x = a.x - b.x, .y = a.y - b.y });
}

fn entityIdsEqual(lhs: EntityId, rhs: EntityId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
}

fn serialBatch(count: usize) BatchStats {
    return .{
        .item_count = count,
        .range_count = if (count == 0) 0 else 1,
        .items_per_range = if (count == 0) 1 else count,
        .range_alignment_items = steering_range_alignment_items,
        .main_thread_ranges = if (count == 0) 0 else 1,
        .ran_inline = true,
    };
}

fn sumU16(values: []const u16) usize {
    var total: usize = 0;
    for (values) |value| total += value;
    return total;
}

test "steering requests missing paths then follows available path results" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 2, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const missing_stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), missing_stats.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), frame.path_requests.mergedItems().len);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);

    _ = try pathfinding.updateSerial(&frame.path_requests, 1, .{});

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    const available_stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), available_stats.path_available_count);
    try std.testing.expectEqual(@as(usize, 0), available_stats.path_request_count);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);
}

test "steering missing path requests respect replan cooldown" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 2, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const first = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), first.path_request_count);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const second = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 0), second.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), second.replan_cooldown_count);
    try std.testing.expectEqual(@as(usize, 0), frame.path_requests.mergedItems().len);
}

test "steering unavailable paths enter backoff without request spam" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 160 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 128, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    const solve = try pathfinding.updateSerial(&frame.path_requests, 1, .{});
    try std.testing.expectEqual(@as(usize, 1), solve.unavailable_results);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 128, .y = 0 }, .direct_direction_x = 1 });
    const unavailable = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), unavailable.path_unavailable_count);
    try std.testing.expectEqual(@as(usize, 0), unavailable.path_request_count);
}

test "steering keeps highest priority navigation intent with stable tie order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntents(&frame, &.{
        .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1, .priority = 0 },
        .{ .entity = agent, .goal = .{ .x = 0, .y = 96 }, .direct_direction_y = 1, .priority = 10 },
        .{ .entity = agent, .goal = .{ .x = 96, .y = 96 }, .direct_direction_x = 1, .direct_direction_y = 1, .priority = 10 },
    });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 3), stats.navigation_intent_count);
    try std.testing.expectEqual(@as(usize, 1), stats.selected_intent_count);
    const intent = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(intent.direction_y > 0.9);
    try std.testing.expect(@abs(intent.direction_x) < 0.01);
}

test "steering capped selection keeps highest priority entity intent" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const low = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const mid = try addSteeredEntity(&data, .{ .x = 16, .y = 0 });
    const high = try addSteeredEntity(&data, .{ .x = 32, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntents(&frame, &.{
        .{ .entity = low, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1, .priority = 0 },
        .{ .entity = mid, .goal = .{ .x = 96, .y = 16 }, .direct_direction_x = 1, .priority = 2 },
        .{ .entity = high, .goal = .{ .x = 96, .y = 32 }, .direct_direction_x = 1, .priority = 10 },
    });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{ .max_selected_intents = 1 });
    try std.testing.expectEqual(@as(usize, 3), stats.navigation_intent_count);
    try std.testing.expectEqual(@as(usize, 1), stats.selected_intent_count);
    const intent = frame.intents.mergedItems()[0].movement;
    try std.testing.expectEqual(high.index, intent.entity.index);
    try std.testing.expectEqual(high.generation, intent.entity.generation);
}

test "steering prunes runtime rows for removed steering entities" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), steering.runtime_rows.items.len);

    try std.testing.expect(data.destroyEntity(agent));
    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 0), steering.runtime_rows.items.len);
}

test "steering applies local agent and static obstacle avoidance" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addSteeredEntity(&data, .{ .x = 20, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 24, .y = -24 }, .{ .x = 20, .y = 20 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    const movement = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(stats.agent_neighbor_samples > 0);
    try std.testing.expect(stats.obstacle_samples > 0);
    try std.testing.expect(movement.direction_x < 1);
}

test "steering serial and real threaded workers produce identical movement intents" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var intents = std.ArrayList(NavigationIntent).empty;
    defer intents.deinit(std.testing.allocator);
    try intents.ensureTotalCapacity(std.testing.allocator, 128);

    for (0..128) |index| {
        const x: f32 = @floatFromInt(index % 16);
        const y: f32 = @floatFromInt(index / 16);
        const entity = try addSteeredEntity(&data, .{ .x = x * 14.0, .y = y * 14.0 });
        intents.appendAssumeCapacity(.{
            .entity = entity,
            .goal = .{ .x = 420, .y = 220 },
            .direct_direction_x = if (index % 2 == 0) 1 else -1,
            .direct_direction_y = if (index % 3 == 0) 0.25 else -0.15,
            .priority = 1,
        });
    }
    _ = try addStaticObstacle(&data, .{ .x = 72, .y = 32 }, .{ .x = 36, .y = 96 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 128, .max_pending_requests = 128, .max_cached_results = 256, .max_group_fields = 4, .worker_participant_count = 1, .max_solved_requests_per_step = 128 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 32);

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(16, 0, 128, 0, 0, 0);
    try serial_frame.reservePathRequests(16, 128);
    serial_frame.beginStep();
    try appendNavigationIntents(&serial_frame, intents.items);
    var serial_system = SteeringSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(128);
    _ = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, .{});
    const serial = serial_frame.intents.mergedItems();

    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(16, 0, 128, 0, 0, 0);
    try threaded_frame.reservePathRequests(16, 128);
    threaded_frame.beginStep();
    try appendNavigationIntents(&threaded_frame, intents.items);
    var threaded_system = SteeringSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    try threaded_system.reserve(128);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = steering_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded_stats = try threaded_system.update(&data, &threaded_frame, &threads, &pathfinding, .{
        .items_per_range = steering_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    const threaded = threaded_frame.intents.mergedItems();

    try std.testing.expect(threaded_stats.batch.active_worker_threads > 0);
    try std.testing.expectEqual(serial.len, threaded.len);
    for (serial, threaded) |a, b| {
        try std.testing.expectEqual(a.movement.entity.index, b.movement.entity.index);
        try std.testing.expectEqual(a.movement.entity.generation, b.movement.entity.generation);
        try std.testing.expectEqual(a.movement.direction_x, b.movement.direction_x);
        try std.testing.expectEqual(a.movement.direction_y, b.movement.direction_y);
    }
}

test "steering update is allocation-free after reserves and warmup" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addSteeredEntity(&data, .{ .x = 24, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 32, .y = -12 }, .{ .x = 16, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = steering.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    const original_intent_allocator = frame.intents.allocator;
    const original_path_allocator = frame.path_requests.allocator;
    steering.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    frame.intents.allocator = failing.allocator();
    frame.path_requests.allocator = failing.allocator();
    defer {
        steering.allocator = original_system_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
        frame.intents.allocator = original_intent_allocator;
        frame.path_requests.allocator = original_path_allocator;
    }

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
}

test "steering obstacle scratch reserve is independent from agent reserve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 24, .y = -12 }, .{ .x = 12, .y = 12 });
    _ = try addStaticObstacle(&data, .{ .x = 48, .y = -12 }, .{ .x = 12, .y = 12 });
    _ = try addStaticObstacle(&data, .{ .x = 72, .y = -12 }, .{ .x = 12, .y = 12 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserveForCapacity(1, 3);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = steering.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    const original_intent_allocator = frame.intents.allocator;
    const original_path_allocator = frame.path_requests.allocator;
    steering.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    frame.intents.allocator = failing.allocator();
    frame.path_requests.allocator = failing.allocator();
    defer {
        steering.allocator = original_system_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
        frame.intents.allocator = original_intent_allocator;
        frame.path_requests.allocator = original_path_allocator;
    }

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
    try std.testing.expect(stats.obstacle_candidate_checks > 0);
}

test "steering prunes runtime rows for destroyed entities" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(1);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 1), steering.runtime_rows.items.len);

    try std.testing.expect(data.destroyEntity(agent));
    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expectEqual(@as(usize, 0), steering.runtime_rows.items.len);
}

test "steering bounds dense crowd candidate checks" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    try data.setSteeringAgent(agent, .{
        .agent_radius = 8,
        .waypoint_tolerance = 4,
        .avoidance_radius = 64,
        .avoidance_weight = 1.5,
        .max_neighbor_samples = 256,
        .stuck_step_threshold = 3,
        .replan_cooldown_steps = 4,
        .unavailable_backoff_steps = 12,
    });
    for (0..128) |index| {
        const x: f32 = @floatFromInt(index % 16);
        const y: f32 = @floatFromInt(index / 16);
        _ = try addSteeredEntity(&data, .{ .x = 4 + x, .y = y });
    }

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 256, 256, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(129);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(stats.agent_candidate_checks <= max_agent_candidate_checks);
    try std.testing.expect(stats.agent_neighbor_samples <= 256);
    try std.testing.expect(stats.agent_candidate_checks > 0);
}

test "steering bounds dense obstacle candidate checks" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    for (0..128) |_| {
        _ = try addStaticObstacle(&data, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 8 });
    }

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 256, 256, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserveForCapacity(1, 128);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(stats.obstacle_candidate_checks <= max_obstacle_candidate_checks);
    try std.testing.expect(stats.obstacle_candidate_checks > 0);
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
}

fn addSteeredEntity(data: *DataSystem, position: math.Vec2) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 32,
    });
    try data.setSteeringAgent(entity, .{
        .agent_radius = 8,
        .waypoint_tolerance = 4,
        .avoidance_radius = 48,
        .avoidance_weight = 1.5,
        .max_neighbor_samples = 8,
        .stuck_step_threshold = 3,
        .replan_cooldown_steps = 4,
        .unavailable_backoff_steps = 12,
    });
    return entity;
}

fn addStaticObstacle(data: *DataSystem, position: math.Vec2, size: math.Vec2) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    return entity;
}

fn appendNavigationIntent(frame: *SimulationFrame, intent: NavigationIntent) !void {
    try appendNavigationIntents(frame, &.{intent});
}

fn appendNavigationIntents(frame: *SimulationFrame, intents: []const NavigationIntent) !void {
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, intents.len);
    try frame.navigation_intents.prefix();
    var writer = frame.navigation_intents.rangeWriter(0);
    for (intents) |intent| writer.write(intent);
    writer.finish();
    frame.navigation_intents.finishWrite();
}
