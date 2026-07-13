// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Steering and local avoidance system for Slice 19.
//! Consumes high-level navigation intents, pathfinding status, and steering
//! component data, then emits final movement intents for NPC movement.
//! Selection, path requests, and world snapshots run on the main thread; worker
//! jobs read immutable slices and write range-owned movement intents.

const std = @import("std");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BatchSelection = @import("../../app/thread_system.zig").BatchSelection;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const ConstCollisionBoundsSlice = @import("../data_system.zig").ConstCollisionBoundsSlice;
const ConstCollisionResponseSlice = @import("../data_system.zig").ConstCollisionResponseSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const ConstScopeColumnsSlice = @import("../data_system.zig").ConstScopeColumnsSlice;
const ConstSteeringAgentSlice = @import("../data_system.zig").ConstSteeringAgentSlice;
const Component = @import("../data_system.zig").Component;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const StageTimer = runtime_perf_log.StageTimer;
const MovementIntent = @import("../simulation.zig").MovementIntent;
const NavigationIntent = @import("../simulation.zig").NavigationIntent;
const PathRequest = @import("../simulation.zig").PathRequest;
const SimulationEvent = @import("../simulation.zig").SimulationEvent;
const SimulationIntent = @import("../simulation.zig").SimulationIntent;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const PathfindingSystem = @import("pathfinding.zig").PathfindingSystem;

pub const steering_range_alignment_items: usize = @import("../data_system.zig").movement_range_alignment_items;

// Range alignment only; batch time gate comes from AdaptiveWorkTunerConfig defaults.
const steering_adaptive_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = steering_range_alignment_items,
    .smallest_range_items = steering_range_alignment_items,
};

pub const HotF32Slice = []f32;
pub const ConstHotF32Slice = []const f32;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, steering_range_alignment_items);
}

fn entityWorldLevel(data: *const DataSystem, entity: EntityId) u16 {
    return data.worldLevelConst(entity) orelse 0;
}

/// Prefer the dense movement scope level (kept in sync with world_level) when the
/// caller already has a movement row index — avoids a second entity slot resolve.
fn movementScopeLevel(scope: ConstScopeColumnsSlice, movement_index: usize) u16 {
    if (movement_index >= scope.level.len) return 0;
    return scope.level[movement_index];
}

const invalid_index = std.math.maxInt(usize);
const min_spatial_cell_size: f32 = 1.0;
const max_agent_candidate_checks: u16 = 64;
const max_obstacle_candidate_checks: u16 = 64;

/// Fraction of the way from the previous emitted direction toward the new
/// target direction each fixed step. `base_dir` can flip discretely — the
/// path/direct-fallback selection toggles while a goal-cell requantization is
/// in flight, a fresh corridor solve replaces a stale waypoint, or a wander
/// epoch changes — and without smoothing each flip snaps the heading in one
/// step, which reads as a wiggle while chasing a moving goal. Blending softens
/// any such flip into a turn over several steps (~10 steps to mostly converge
/// at 60Hz) instead of an instant snap, while staying responsive enough not to
/// lag behind a genuinely moving goal.
const steering_turn_smoothing: f32 = 0.15;

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
    // Main-thread prepareUpdate phases (ns); zero when perf logging is disabled.
    select_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    directions_ns: u64 = 0,
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
    // Selected-work rows are range-written by workers and aligned with
    // `selected` by index.
    selected_work_rows: std.MultiArrayList(SelectedWorkRow) = .{},
    // World snapshots are immutable during worker dispatch. DataSystem is not
    // touched from steering worker jobs.
    agent_snapshot_rows: std.MultiArrayList(AgentSnapshotRow) = .{},
    agent_cell_entries: std.ArrayList(SpatialCellEntry) = .empty,
    agent_cell_ranges: std.ArrayList(SpatialCellRange) = .empty,
    // Parallel to steering dense order: movement body dense index per steering row.
    // Rebuilt only when invalidated (structural create/destroy/component renumber),
    // not every cognition step — avoids per-agent slot resolve in the hot snapshot.
    steering_movement_index: std.ArrayList(usize) = .empty,
    steering_movement_index_valid: bool = false,
    obstacle_snapshot_rows: std.MultiArrayList(ObstacleSnapshotRow) = .{},
    obstacle_cell_entries: std.ArrayList(SpatialCellEntry) = .empty,
    obstacle_cell_ranges: std.ArrayList(SpatialCellRange) = .empty,
    spatial_cell_size: f32 = 64.0,
    spatial_obstacle_query_extra: f32 = 0,
    // Static-obstacle snapshot + spatial bins are rebuilt only when invalid.
    // Invalidation is event-driven (reactToPostCommitSteeringEvents), same shape
    // as pathfinding/perception post-commit reactions — not a per-step poll.
    // Also rebuilt when the agent-radius-derived cell size changes (bins wrong).
    obstacle_index_valid: bool = false,
    /// `spatial_cell_size` used when the obstacle index was last built.
    obstacle_spatial_cell_size: f32 = 0,
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),

    pub fn init(allocator: std.mem.Allocator) SteeringSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SteeringSystem) void {
        self.obstacle_cell_ranges.deinit(self.allocator);
        self.obstacle_cell_entries.deinit(self.allocator);
        self.obstacle_snapshot_rows.deinit(self.allocator);
        self.agent_cell_ranges.deinit(self.allocator);
        self.agent_cell_entries.deinit(self.allocator);
        self.agent_snapshot_rows.deinit(self.allocator);
        self.steering_movement_index.deinit(self.allocator);
        self.selected_work_rows.deinit(self.allocator);
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

    /// Marks the retained static-obstacle snapshot/spatial index dirty so the next
    /// `prepareUpdate` rebuilds it. Called from the post-commit structural reaction
    /// (and tests that mutate obstacles outside the event stream).
    pub fn invalidateStaticObstacleSpatial(self: *SteeringSystem) void {
        self.obstacle_index_valid = false;
        self.obstacle_spatial_cell_size = 0;
    }

    pub fn invalidateSteeringMovementIndexCache(self: *SteeringSystem) void {
        self.steering_movement_index_valid = false;
    }

    /// Post-commit reaction: structural_commit events that change static obstacles
    /// and/or renumber steering↔movement dense indices. Allocation-free.
    pub fn reactToPostCommitSteeringEvents(self: *SteeringSystem, frame: *const SimulationFrame) void {
        var hit_obstacle = false;
        var hit_movement_index = false;
        for (frame.events.mergedItems()) |event| {
            if (event.stage != .structural_commit) continue;
            if (!hit_obstacle and eventInvalidatesStaticObstacleSpatial(event)) {
                self.invalidateStaticObstacleSpatial();
                hit_obstacle = true;
            }
            if (!hit_movement_index and eventInvalidatesSteeringMovementIndexCache(event)) {
                self.invalidateSteeringMovementIndexCache();
                hit_movement_index = true;
            }
            if (hit_obstacle and hit_movement_index) return;
        }
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
        try self.selected_work_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(max_agents));
        try self.agent_snapshot_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(max_agents));
        try self.steering_movement_index.ensureTotalCapacity(self.allocator, max_agents);
        try self.agent_cell_entries.ensureTotalCapacity(self.allocator, max_agents);
        try self.agent_cell_ranges.ensureTotalCapacity(self.allocator, max_agents);
        try self.obstacle_snapshot_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(max_obstacles));
        try self.obstacle_cell_entries.ensureTotalCapacity(self.allocator, max_obstacles);
        try self.obstacle_cell_ranges.ensureTotalCapacity(self.allocator, max_obstacles);
    }

    pub fn selectedWorkSlice(self: *SteeringSystem) SelectedWorkSlice {
        const s = self.selected_work_rows.slice();
        return .{
            .start_x = s.items(.start_x),
            .start_y = s.items(.start_y),
            .base_dir_x = s.items(.base_dir_x),
            .base_dir_y = s.items(.base_dir_y),
            .final_dir_x = s.items(.final_dir_x),
            .final_dir_y = s.items(.final_dir_y),
            .selected_agent_radii = s.items(.selected_agent_radii),
            .selected_avoidance_radii = s.items(.selected_avoidance_radii),
            .selected_avoidance_weights = s.items(.selected_avoidance_weights),
            .selected_max_neighbor_samples = s.items(.selected_max_neighbor_samples),
        };
    }

    pub fn selectedWorkSliceConst(self: *const SteeringSystem) ConstSelectedWorkSlice {
        const s = self.selected_work_rows.slice();
        return .{
            .start_x = s.items(.start_x),
            .start_y = s.items(.start_y),
            .base_dir_x = s.items(.base_dir_x),
            .base_dir_y = s.items(.base_dir_y),
            .final_dir_x = s.items(.final_dir_x),
            .final_dir_y = s.items(.final_dir_y),
            .selected_agent_radii = s.items(.selected_agent_radii),
            .selected_avoidance_radii = s.items(.selected_avoidance_radii),
            .selected_avoidance_weights = s.items(.selected_avoidance_weights),
            .selected_max_neighbor_samples = s.items(.selected_max_neighbor_samples),
        };
    }

    pub fn agentSnapshotSliceConst(self: *const SteeringSystem) ConstAgentSnapshotSlice {
        const s = self.agent_snapshot_rows.slice();
        return .{
            .entity = s.items(.entity),
            .x = s.items(.x),
            .y = s.items(.y),
            .radius = s.items(.radius),
        };
    }

    pub fn obstacleSnapshotSliceConst(self: *const SteeringSystem) ConstObstacleSnapshotSlice {
        const s = self.obstacle_snapshot_rows.slice();
        return .{
            .min_x = s.items(.min_x),
            .min_y = s.items(.min_y),
            .max_x = s.items(.max_x),
            .max_y = s.items(.max_y),
        };
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
        try self.writePathRequests(data, frame, stats.path_request_count);
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
        try self.writePathRequests(data, frame, stats.path_request_count);
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
        var select_timer = StageTimer.start();
        try self.selectIntents(data, steering, navigation_intents, config);
        const select_ns = select_timer.lap();

        const movement = data.movementBodySliceConst();
        // Snapshot all avoidance inputs before dispatch so worker jobs never
        // touch DataSystem or pathfinding mutable state.
        var snapshot_timer = StageTimer.start();
        try self.gatherWorldSnapshot(data, movement, steering, data.collisionBoundsSliceConst(), data.collisionResponseSliceConst());
        const snapshot_ns = snapshot_timer.lap();

        var stats = SteeringStats{
            .navigation_intent_count = navigation_intents.len,
            .selected_intent_count = self.selected.items.len,
            .select_ns = select_ns,
            .snapshot_ns = snapshot_ns,
        };

        var directions_timer = StageTimer.start();
        try self.prepareSelectedDirections(data, movement, steering, pathfinding, &stats);
        stats.directions_ns = directions_timer.lap();
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
            // One slot resolve for both dense indices (not movement + steering separately).
            const indices = data.movementSteeringDenseIndices(intent.entity) orelse continue;
            const movement_index = indices.movement;
            const steering_index = indices.steering;
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
        self.selected_work_rows.clearRetainingCapacity();
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
        const cell_size = spatialCellSize(steering);
        self.spatial_cell_size = cell_size;

        try self.ensureSteeringMovementIndexCache(data, steering);

        // Agents move every step: pack previous positions into SoA, then dense
        // SIMD cell assignment + sort (no per-agent slot resolve on the hot path).
        self.agent_snapshot_rows.clearRetainingCapacity();
        self.agent_cell_entries.clearRetainingCapacity();
        self.agent_cell_ranges.clearRetainingCapacity();
        try self.agent_snapshot_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(steering.entities.len));
        try self.agent_cell_entries.ensureTotalCapacity(self.allocator, steering.entities.len);
        try self.agent_cell_ranges.ensureTotalCapacity(self.allocator, steering.entities.len);
        var agent_row_slice = self.agent_snapshot_rows.slice();
        const movement_indices = self.steering_movement_index.items;
        std.debug.assert(movement_indices.len == steering.entities.len);
        for (steering.entities, movement_indices, 0..) |entity, movement_index, steering_index| {
            if (movement_index == invalid_index) continue;
            if (movement_index >= movement.previous_x.len) continue;
            appendMalRow(AgentSnapshotRow, &self.agent_snapshot_rows, &agent_row_slice, .{
                .entity = entity,
                .x = movement.previous_x[movement_index],
                .y = movement.previous_y[movement_index],
                .radius = steering.agent_radii[steering_index],
            });
        }
        try self.fillAgentCellEntriesDense(cell_size);
        try buildCellRanges(self.agent_cell_entries.items, &self.agent_cell_ranges, self.allocator);

        // Static obstacles never move between structural commits. Rebuild only when
        // post-commit events invalidated the cache, or the agent-radius-derived cell
        // size changed (bins would be wrong under a different grid).
        const cell_size_changed = self.obstacle_index_valid and self.obstacle_spatial_cell_size != cell_size;
        if (!self.obstacle_index_valid or cell_size_changed) {
            try self.rebuildStaticObstacleSnapshot(
                data,
                movement,
                collision_bounds,
                collision_responses,
                cell_size,
            );
            self.obstacle_index_valid = true;
            self.obstacle_spatial_cell_size = cell_size;
        }
    }

    fn ensureSteeringMovementIndexCache(
        self: *SteeringSystem,
        data: *const DataSystem,
        steering: ConstSteeringAgentSlice,
    ) !void {
        const count = steering.entities.len;
        if (self.steering_movement_index_valid and self.steering_movement_index.items.len == count) return;

        try self.steering_movement_index.ensureTotalCapacity(self.allocator, count);
        self.steering_movement_index.items.len = count;
        for (steering.entities, 0..) |entity, steering_index| {
            self.steering_movement_index.items[steering_index] =
                data.movementBodyDenseIndex(entity) orelse invalid_index;
        }
        self.steering_movement_index_valid = true;
    }

    /// After agent snapshot rows are packed, assign spatial cells over the contiguous
    /// x/y columns (SIMD 4-wide + scalar tail), bit-identical to `spatialCell`.
    fn fillAgentCellEntriesDense(self: *SteeringSystem, cell_size: f32) !void {
        const agents = self.agentSnapshotSliceConst();
        const n = agents.len();
        if (n == 0) return;
        try self.agent_cell_entries.ensureTotalCapacity(self.allocator, n);
        self.agent_cell_entries.items.len = n;

        const safe_cell = @max(cell_size, min_spatial_cell_size);
        const cell_size_vec = simd.splatFloat4(safe_cell);
        const xs = agents.x;
        const ys = agents.y;
        var i: usize = 0;
        const vend = simd.vectorizedEnd(n);
        while (i < vend) : (i += simd.lane_count) {
            const px = simd.loadFloat4(xs[i..]);
            const py = simd.loadFloat4(ys[i..]);
            const cx = simd.toIntArray(simd.floorToI4(simd.divFloat4(px, cell_size_vec)));
            const cy = simd.toIntArray(simd.floorToI4(simd.divFloat4(py, cell_size_vec)));
            inline for (0..simd.lane_count) |lane| {
                self.agent_cell_entries.items[i + lane] = .{
                    .cell_x = cx[lane],
                    .cell_y = cy[lane],
                    .index = i + lane,
                };
            }
        }
        while (i < n) : (i += 1) {
            self.agent_cell_entries.items[i] = .{
                .cell_x = spatialCell(xs[i], cell_size),
                .cell_y = spatialCell(ys[i], cell_size),
                .index = i,
            };
        }
    }

    fn rebuildStaticObstacleSnapshot(
        self: *SteeringSystem,
        data: *const DataSystem,
        movement: ConstMovementBodySlice,
        collision_bounds: ConstCollisionBoundsSlice,
        collision_responses: ConstCollisionResponseSlice,
        cell_size: f32,
    ) !void {
        self.obstacle_snapshot_rows.clearRetainingCapacity();
        self.obstacle_cell_entries.clearRetainingCapacity();
        self.obstacle_cell_ranges.clearRetainingCapacity();
        try self.obstacle_snapshot_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(collision_responses.entities.len));
        try self.obstacle_cell_entries.ensureTotalCapacity(self.allocator, collision_responses.entities.len);
        try self.obstacle_cell_ranges.ensureTotalCapacity(self.allocator, collision_responses.entities.len);

        var obstacle_row_slice = self.obstacle_snapshot_rows.slice();
        self.spatial_obstacle_query_extra = 0;
        var obstacle_index: usize = 0;
        for (collision_responses.entities, 0..) |obstacle_entity, response_index| {
            if (collision_responses.mobilities[response_index] != .static) continue;
            const bounds_index = data.collisionBoundsDenseIndex(obstacle_entity) orelse continue;
            const movement_index = data.movementBodyDenseIndex(obstacle_entity) orelse continue;
            const min_x = movement.previous_x[movement_index] + collision_bounds.offset_x[bounds_index];
            const min_y = movement.previous_y[movement_index] + collision_bounds.offset_y[bounds_index];
            const size_x = collision_bounds.size_x[bounds_index];
            const size_y = collision_bounds.size_y[bounds_index];
            self.spatial_obstacle_query_extra = @max(self.spatial_obstacle_query_extra, @max(size_x, size_y) * 0.5);
            const max_x = min_x + size_x;
            const max_y = min_y + size_y;
            appendMalRow(ObstacleSnapshotRow, &self.obstacle_snapshot_rows, &obstacle_row_slice, .{
                .min_x = min_x,
                .min_y = min_y,
                .max_x = max_x,
                .max_y = max_y,
            });
            const center_x = (min_x + max_x) * 0.5;
            const center_y = (min_y + max_y) * 0.5;
            self.obstacle_cell_entries.appendAssumeCapacity(.{
                .cell_x = spatialCell(center_x, cell_size),
                .cell_y = spatialCell(center_y, cell_size),
                .index = obstacle_index,
            });
            obstacle_index += 1;
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
        try self.selected_work_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(count));
        // Map existing runtime rows first, then reserve only for selected intents
        // that still lack a row. `items.len + count` overshoots a warm population
        // (requests 2N when N rows already exist) and forces a one-shot realloc
        // after the first full step — breaking the reserve/warmup contract.
        try resetIndexScratch(&self.runtime_index_by_steering, self.allocator, steering.entities.len);
        for (self.runtime_rows.items, 0..) |row, runtime_index| {
            const steering_index = data.steeringAgentDenseIndex(row.entity) orelse continue;
            self.runtime_index_by_steering.items[steering_index] = runtime_index;
        }
        var missing_runtime_rows: usize = 0;
        for (self.selected.items) |selected| {
            if (self.runtime_index_by_steering.items[selected.steering_index] == invalid_index) {
                missing_runtime_rows += 1;
            }
        }
        try self.runtime_rows.ensureTotalCapacity(self.allocator, self.runtime_rows.items.len + missing_runtime_rows);

        const scope = data.scopeColumnsSliceConst();
        var request_count: usize = 0;
        var work_row_slice = self.selected_work_rows.slice();
        for (self.selected.items) |*selected| {
            const steering_agent = steeringAgentAt(steering, selected.steering_index);
            const start = math.Vec2{
                .x = movement.previous_x[selected.movement_index],
                .y = movement.previous_y[selected.movement_index],
            };
            const runtime = self.runtimeRowForSelected(selected);
            const start_level = movementScopeLevel(scope, selected.movement_index);
            const path_dir = self.directionFromPathStatus(pathfinding, selected, start, start_level, steering_agent, runtime, stats, &request_count);
            const direct_dir = math.normalizeOrZeroFinite(selected.intent.direct_direction_x, selected.intent.direct_direction_y, 0.0001);
            const target_dir = if (path_dir.has_direction) path_dir.direction else direct_dir;
            const base_dir = smoothBaseDirection(runtime, target_dir);

            self.updateProgress(selected, runtime, path_dir.progress_distance, steering_agent, path_dir.status_allows_replan, stats, &request_count);
            appendMalRow(SelectedWorkRow, &self.selected_work_rows, &work_row_slice, .{
                .start_x = start.x,
                .start_y = start.y,
                .base_dir_x = base_dir.x,
                .base_dir_y = base_dir.y,
                .final_dir_x = 0,
                .final_dir_y = 0,
                .selected_agent_radii = steering_agent.agent_radius,
                .selected_avoidance_radii = steering_agent.avoidance_radius,
                .selected_avoidance_weights = steering_agent.avoidance_weight,
                .selected_max_neighbor_samples = steering_agent.max_neighbor_samples,
            });
        }
        stats.path_request_count = request_count;
    }

    fn writePathRequests(self: *SteeringSystem, data: *const DataSystem, frame: *SimulationFrame, request_count: usize) !void {
        const request_range_base = try frame.path_requests.appendRangeCounts(1);
        frame.path_requests.addCount(request_range_base, request_count);
        try frame.path_requests.prefixAppendedRanges(request_range_base);
        var request_writer = frame.path_requests.rangeWriter(request_range_base);
        // Path requests are appended as their own range so steering can coexist
        // with future producers without rebuilding earlier stream offsets.
        const work = self.selectedWorkSliceConst();
        const scope = data.scopeColumnsSliceConst();
        for (self.selected.items, 0..) |selected, index| {
            if (!selected.emit_path_request) continue;
            request_writer.write(PathRequest{
                .entity = selected.entity,
                .agent_class = selected.intent.agent_class,
                .kind = selected.intent.kind,
                .start_level = movementScopeLevel(scope, selected.movement_index),
                .goal_level = selected.intent.goal_level,
                .start = .{ .x = work.start_x[index], .y = work.start_y[index] },
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

        var context = self.jobContext(frame, range_base, work.range_count);
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
        var context = self.jobContext(frame, range_base, 1);
        writeSteeringMovementJob(&context, .{ .index = 0, .start = 0, .end = count }, WorkerId.main);
        frame.intents.finishWrite();
        return serialBatch(count);
    }

    /// Blends `runtime.prev_dir` toward `target` by `steering_turn_smoothing`
    /// and re-normalizes, so a discrete flip in the chosen target direction
    /// (path/direct toggle, waypoint replan, wander epoch change) turns into a
    /// bounded per-step turn instead of an instant snap. The first direction
    /// seen for a runtime row is used as-is (no artificial startup lag).
    fn smoothBaseDirection(runtime: *RuntimeRow, target: math.Vec2) math.Vec2 {
        if (!runtime.has_prev_dir) {
            runtime.prev_dir_x = target.x;
            runtime.prev_dir_y = target.y;
            runtime.has_prev_dir = true;
            return target;
        }
        const blended = math.lerpVec2(
            .{ .x = runtime.prev_dir_x, .y = runtime.prev_dir_y },
            target,
            steering_turn_smoothing,
        );
        const smoothed = math.normalizeOrDefaultFinite(blended.x, blended.y, 0.0001, target);
        runtime.prev_dir_x = smoothed.x;
        runtime.prev_dir_y = smoothed.y;
        return smoothed;
    }

    fn directionFromPathStatus(
        self: *SteeringSystem,
        pathfinding: *const PathfindingSystem,
        selected: *SelectedIntent,
        start: math.Vec2,
        start_level: u16,
        steering_agent: SteeringAgentView,
        runtime: *RuntimeRow,
        stats: *SteeringStats,
        request_count: *usize,
    ) PathDirection {
        _ = self;
        // Missing paths request work, pending paths hold direction, unavailable
        // paths enter backoff, and available paths steer toward the next waypoint.
        const goal_distance = distance(start, selected.intent.goal);
        const view = pathfinding.statusForWorld(start_level, start, selected.intent.goal_level, selected.intent.goal, selected.intent.agent_class, &runtime.waypoint_hint);
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

    fn runtimeRowForSelected(self: *SteeringSystem, selected: *const SelectedIntent) *RuntimeRow {
        // Capacity for up to one new row per selected intent is reserved once,
        // upfront, by the caller (prepareSelectedDirections).
        const existing_index = self.runtime_index_by_steering.items[selected.steering_index];
        if (existing_index != invalid_index) return &self.runtime_rows.items[existing_index];
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

    fn jobContext(self: *SteeringSystem, frame: *SimulationFrame, range_base: usize, range_count: usize) SteeringJobContext {
        return .{
            .selected = self.selected.items,
            .work = self.selectedWorkSlice(),
            .agents = self.agentSnapshotSliceConst(),
            .obstacles = self.obstacleSnapshotSliceConst(),
            .agent_cell_entries = self.agent_cell_entries.items,
            .agent_cell_ranges = self.agent_cell_ranges.items,
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
            .range_count = range_count,
        };
    }
};

const SelectedWorkRow = struct {
    start_x: f32,
    start_y: f32,
    base_dir_x: f32,
    base_dir_y: f32,
    final_dir_x: f32,
    final_dir_y: f32,
    selected_agent_radii: f32,
    selected_avoidance_radii: f32,
    selected_avoidance_weights: f32,
    selected_max_neighbor_samples: u16,
};

const AgentSnapshotRow = struct {
    entity: EntityId,
    x: f32,
    y: f32,
    radius: f32,
};

const ObstacleSnapshotRow = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

fn appendMalRow(comptime Row: type, rows: *std.MultiArrayList(Row), row_slice: *std.MultiArrayList(Row).Slice, row: Row) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

pub const SelectedWorkSlice = struct {
    start_x: HotF32Slice,
    start_y: HotF32Slice,
    base_dir_x: HotF32Slice,
    base_dir_y: HotF32Slice,
    final_dir_x: HotF32Slice,
    final_dir_y: HotF32Slice,
    selected_agent_radii: HotF32Slice,
    selected_avoidance_radii: HotF32Slice,
    selected_avoidance_weights: HotF32Slice,
    selected_max_neighbor_samples: []u16,

    pub fn len(self: SelectedWorkSlice) usize {
        return self.start_x.len;
    }
};

pub const ConstSelectedWorkSlice = struct {
    start_x: ConstHotF32Slice,
    start_y: ConstHotF32Slice,
    base_dir_x: ConstHotF32Slice,
    base_dir_y: ConstHotF32Slice,
    final_dir_x: ConstHotF32Slice,
    final_dir_y: ConstHotF32Slice,
    selected_agent_radii: ConstHotF32Slice,
    selected_avoidance_radii: ConstHotF32Slice,
    selected_avoidance_weights: ConstHotF32Slice,
    selected_max_neighbor_samples: []const u16,

    pub fn len(self: ConstSelectedWorkSlice) usize {
        return self.start_x.len;
    }
};

pub const ConstAgentSnapshotSlice = struct {
    entity: []const EntityId,
    x: ConstHotF32Slice,
    y: ConstHotF32Slice,
    radius: ConstHotF32Slice,

    pub fn len(self: ConstAgentSnapshotSlice) usize {
        return self.entity.len;
    }
};

pub const ConstObstacleSnapshotSlice = struct {
    min_x: ConstHotF32Slice,
    min_y: ConstHotF32Slice,
    max_x: ConstHotF32Slice,
    max_y: ConstHotF32Slice,

    pub fn len(self: ConstObstacleSnapshotSlice) usize {
        return self.min_x.len;
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
    // Last-matched index into the agent's cached path, passed to the pathfinding query so
    // its per-step waypoint derivation probes a small forward window instead of scanning
    // the whole shared path. A stale value (goal/path changed) only misses and falls back.
    waypoint_hint: u32 = 0,
    // Last emitted (possibly smoothed) base direction, blended toward each new
    // target direction in `smoothBaseDirection` instead of snapping to it.
    prev_dir_x: f32 = 0,
    prev_dir_y: f32 = 0,
    has_prev_dir: bool = false,
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

const SteeringWorkSelection = BatchSelection;

const SteeringJobContext = struct {
    // Worker context is immutable input plus range-indexed output columns and a
    // pre-prefixed SimulationFrame stream.
    selected: []const SelectedIntent,
    work: SelectedWorkSlice,
    agents: ConstAgentSnapshotSlice,
    obstacles: ConstObstacleSnapshotSlice,
    agent_cell_entries: []const SpatialCellEntry,
    agent_cell_ranges: []const SpatialCellRange,
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
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
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
    // Dual worker asserts (mirror affect.zig / collision.zig).
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.selected.len);
    var writer = job.intents.rangeWriter(job.range_base + range.index);
    for (range.start..range.end) |index| {
        const result = computeAvoidance(job, index);
        job.work.final_dir_x[index] = result.direction.x;
        job.work.final_dir_y[index] = result.direction.y;
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
    var ax = job.work.base_dir_x[index];
    var ay = job.work.base_dir_y[index];
    var sample_count: u16 = 0;
    var agent_candidate_count: u16 = 0;
    const max_samples = job.work.selected_max_neighbor_samples[index];
    if (max_samples > 0) {
        accumulateAgentAvoidanceBounded(job, index, &ax, &ay, &sample_count, &agent_candidate_count, max_samples);
    }

    var obstacle_count: u16 = 0;
    var obstacle_candidate_count: u16 = 0;
    const start_x = job.work.start_x[index];
    const start_y = job.work.start_y[index];
    const radius = job.work.selected_avoidance_radii[index] + job.work.selected_agent_radii[index];
    const weight = job.work.selected_avoidance_weights[index];
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
    const min_x = job.obstacles.min_x[obstacle_index];
    const min_y = job.obstacles.min_y[obstacle_index];
    const max_x = job.obstacles.max_x[obstacle_index];
    const max_y = job.obstacles.max_y[obstacle_index];
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
        const push = math.lengthDirection(dx, dy, 0);
        const strength = (1.0 - push.length / radius) * weight;
        ax.* += push.direction.x * strength;
        ay.* += push.direction.y * strength;
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
    const start_x = job.work.start_x[index];
    const start_y = job.work.start_y[index];
    const avoidance_radius = job.work.selected_avoidance_radii[index];
    const query_radius = avoidance_radius + job.work.selected_agent_radii[index];
    const weight = job.work.selected_avoidance_weights[index];
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
                if (job.agents.entity[other_index].eql(self_entity)) continue;
                const dx = start_x - job.agents.x[other_index];
                const dy = start_y - job.agents.y[other_index];
                const combined_radius = avoidance_radius + job.agents.radius[other_index];
                const dist2 = dx * dx + dy * dy;
                if (dist2 > 0.0001 and dist2 < combined_radius * combined_radius) {
                    accumulateAgentSample(dx, dy, combined_radius, weight, ax, ay, sample_count);
                }
            }
        }
    }
}

fn accumulateAgentSample(
    dx: f32,
    dy: f32,
    combined_radius: f32,
    weight: f32,
    ax: *f32,
    ay: *f32,
    sample_count: *u16,
) void {
    const push = math.lengthDirection(dx, dy, 0);
    const strength = (1.0 - push.length / combined_radius) * weight;
    ax.* += push.direction.x * strength;
    ay.* += push.direction.y * strength;
    sample_count.* += 1;
}

fn selectSteeringWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    config: SteeringConfig,
    system: *SteeringSystem,
) SteeringWorkSelection {
    // Steering owns its tuner because avoidance cost differs from movement,
    // pathfinding, and render-prep work even when item counts are similar. Shape is
    // resolved through the single tuner-owned entry point so pre-sizing and dispatch
    // agree exactly.
    return thread_system.selectBatchProfile(config.adaptive_tuner orelse &system.adaptive_tuner, .{
        .item_count = item_count,
        .items_per_range = config.items_per_range,
        .max_worker_threads = config.max_worker_threads,
        .range_alignment_items = steering_range_alignment_items,
        .adaptive = config.adaptive,
    });
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

    // pdqsort: agents move slowly so order is often nearly sorted; still O(n log n)
    // worst case, better constant factors than the previous generic sort on large N.
    std.sort.pdq(SpatialCellEntry, entries, {}, spatialCellEntryLessThan);
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

/// Whether a committed structural event changes the set of static entity
/// obstacles steering uses for local avoidance. Mirrors the entity/static side of
/// `PathfindingSystem.eventInvalidatesNavigation` (same `isStaticNavigationObstacle`
/// definition: movement + bounds + response.mobility == .static). World *tile*
/// events are not consulted — steering's obstacle spatial is entity AABBs only;
/// pathfinding/perception own tile occupancy.
pub fn eventInvalidatesStaticObstacleSpatial(event: SimulationEvent) bool {
    return switch (event.payload) {
        .entity_destroyed => |destroyed| destroyed.was_static_navigation_obstacle,
        .component_changed => |changed| switch (changed.component) {
            .movement_body, .collision_bounds => changed.was_static_navigation_obstacle or changed.is_static_navigation_obstacle,
            .collision_response => changed.was_static_navigation_obstacle != changed.is_static_navigation_obstacle,
            else => false,
        },
        else => false,
    };
}

/// Whether a structural event can renumber or drop steering↔movement dense
/// index pairs (swap-remove, destroy, add/remove components). Forces a rebuild
/// of `steering_movement_index` before the next snapshot.
pub fn eventInvalidatesSteeringMovementIndexCache(event: SimulationEvent) bool {
    return switch (event.payload) {
        .entity_destroyed => true,
        .entity_created => true,
        .component_changed => |changed| switch (changed.component) {
            .movement_body, .steering_agent => true,
            else => false,
        },
        else => false,
    };
}

fn distance(a: math.Vec2, b: math.Vec2) f32 {
    return math.length(.{ .x = a.x - b.x, .y = a.y - b.y });
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

fn expectAgentSnapshotColumnsAligned(rows: *const std.MultiArrayList(AgentSnapshotRow)) !void {
    const count = rows.len;
    const s = rows.slice();
    try std.testing.expectEqual(count, s.items(.entity).len);
    try std.testing.expectEqual(count, s.items(.x).len);
    try std.testing.expectEqual(count, s.items(.y).len);
    try std.testing.expectEqual(count, s.items(.radius).len);
}

test "steering agent snapshot rows keep MAL columns compact after gather" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addSteeredEntity(&data, .{ .x = 32, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});

    try expectAgentSnapshotColumnsAligned(&steering.agent_snapshot_rows);
    try std.testing.expectEqual(@as(usize, 2), steering.agent_snapshot_rows.len);
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

test "steering smooths a discrete target-direction flip over several steps instead of snapping" {
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

    // Never resolving path requests keeps status `.missing` for every step, so
    // `direct_dir` (the raw target direction below) is what smoothing acts on.

    // First observation for this runtime row is used as-is: no startup lag.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 1, .direct_direction_y = 0 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    const first = frame.intents.mergedItems()[0].movement;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), first.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), first.direction_y, 0.001);

    // Target direction flips a full 90 degrees to (0, 1). A hard snap would
    // jump straight to direction_y == 1; smoothing should only partially turn.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    const second = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(second.direction_y > 0.0);
    try std.testing.expect(second.direction_y < 0.9);
    try std.testing.expect(second.direction_x > 0.0);

    // Repeated steps toward the same (0, 1) target converge close to it.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        frame.beginStep();
        try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
        _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    }
    const converged = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(converged.direction_y > 0.95);
}

test "steering sources path request start level from entity world level" {
    // Default surface NPCs without an explicit world_level component still emit
    // start_level 0. Underground placement uses setWorldLevel before steering runs.
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
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});

    const requests = frame.path_requests.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqual(@as(u16, 0), requests[0].start_level);
    try std.testing.expectEqual(@as(u16, 0), requests[0].goal_level);

    // entityWorldLevel is the sole source of a path request's start_level (see
    // writePathRequests above); this is the direct regression guard that a
    // future edit can't quietly hardcode it back to 0. Exercised directly
    // rather than through another full updateSerial step, since a second step
    // for the same agent would hit the replan cooldown the first request just
    // armed and never re-request regardless of level.
    try std.testing.expectEqual(@as(u16, 0), entityWorldLevel(&data, agent));
    try data.setWorldLevel(agent, 2);
    try std.testing.expectEqual(@as(u16, 2), entityWorldLevel(&data, agent));
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

test "steering movement index cache rebuilds only after structural invalidate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(8);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(steering.steering_movement_index_valid);
    try std.testing.expectEqual(@as(usize, 1), steering.steering_movement_index.items.len);
    const cached_mi = steering.steering_movement_index.items[0];
    try std.testing.expectEqual(data.movementBodyDenseIndex(agent).?, cached_mi);

    // Second step without structural events reuses the cache.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(steering.steering_movement_index_valid);
    try std.testing.expectEqual(cached_mi, steering.steering_movement_index.items[0]);

    // Structural destroy of a different entity still invalidates (renumber risk).
    const other = try addSteeredEntity(&data, .{ .x = 40, .y = 0 });
    frame.beginStep();
    try frame.events.ensureCanAppend(1);
    try frame.events.appendRequired(.{
        .stage = .structural_commit,
        .payload = .{ .entity_destroyed = .{
            .entity = other,
            .component_mask = 0,
        } },
    });
    steering.reactToPostCommitSteeringEvents(&frame);
    try std.testing.expect(!steering.steering_movement_index_valid);
}

test "steering reuses the static obstacle index until post-commit events invalidate it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 24, .y = -24 }, .{ .x = 20, .y = 20 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(8);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(steering.obstacle_index_valid);
    try std.testing.expectEqual(@as(usize, 1), steering.obstacle_cell_entries.items.len);
    const first_query_extra = steering.spatial_obstacle_query_extra;

    // No structural events: retained obstacle spatial is reused (no rebuild).
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(steering.obstacle_index_valid);
    try std.testing.expectEqual(@as(usize, 1), steering.obstacle_cell_entries.items.len);
    try std.testing.expectEqual(first_query_extra, steering.spatial_obstacle_query_extra);

    // Structural change: post-commit reaction invalidates; next update rebuilds.
    const new_obstacle = try addStaticObstacle(&data, .{ .x = -24, .y = 24 }, .{ .x = 20, .y = 20 });
    frame.beginStep();
    try frame.events.ensureCanAppend(1);
    try frame.events.appendRequired(.{
        .stage = .structural_commit,
        .payload = .{ .component_changed = .{
            .entity = new_obstacle,
            .component = .collision_response,
            .was_static_navigation_obstacle = false,
            .is_static_navigation_obstacle = true,
        } },
    });
    steering.reactToPostCommitSteeringEvents(&frame);
    try std.testing.expect(!steering.obstacle_index_valid);

    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, .{});
    try std.testing.expect(steering.obstacle_index_valid);
    try std.testing.expectEqual(@as(usize, 2), steering.obstacle_cell_entries.items.len);
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

test "steering serial matches threaded intents across multiple range splits and worker counts" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // The single-split parity test above pins one fixed split; the AdaptiveWorkTuner
    // instead picks range/worker counts dynamically, and its probe-driven choice is not
    // reproducible in a unit test. This asserts the split-INVARIANCE the tuner relies on:
    // every explicit partition and worker count must reproduce the serial reference. The
    // read-only inputs (data, obstacles, nav grid, intents) are shared; only the mutated
    // output frame and system are rebuilt per split.
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
    try std.testing.expect(serial.len > 0);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = steering_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = steering_range_alignment_items, .workers = 2 },
        .{ .items_per_range = steering_range_alignment_items * 2, .workers = 2 },
        .{ .items_per_range = steering_range_alignment_items, .workers = 4 },
        .{ .items_per_range = steering_range_alignment_items * 3, .workers = 3 },
    };
    for (splits) |split| {
        var threaded_frame = SimulationFrame.init(std.testing.allocator);
        defer threaded_frame.deinit();
        try threaded_frame.reserveStreams(16, 0, 128, 0, 0, 0);
        try threaded_frame.reservePathRequests(16, 128);
        threaded_frame.beginStep();
        try appendNavigationIntents(&threaded_frame, intents.items);
        var threaded_system = SteeringSystem.init(std.testing.allocator);
        defer threaded_system.deinit();
        try threaded_system.reserve(128);
        const threaded_stats = try threaded_system.update(&data, &threaded_frame, &threads, &pathfinding, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        // Real workers processed the batch, so this split exercised the multi-worker
        // path it claims to.
        try std.testing.expect(threaded_stats.batch.active_worker_threads > 0);
        const threaded = threaded_frame.intents.mergedItems();
        try std.testing.expectEqual(serial.len, threaded.len);
        for (serial, threaded) |a, b| {
            try std.testing.expectEqual(a.movement.entity.index, b.movement.entity.index);
            try std.testing.expectEqual(a.movement.entity.generation, b.movement.entity.generation);
            try std.testing.expectEqual(a.movement.direction_x, b.movement.direction_x);
            try std.testing.expectEqual(a.movement.direction_y, b.movement.direction_y);
        }
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

test "steering threaded multi-worker update has no steady-state allocation after warmup (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var agents: [steering_range_alignment_items * 4]EntityId = undefined;
    for (&agents, 0..) |*slot, i| {
        const x: f32 = @floatFromInt(i % 8);
        const y: f32 = @floatFromInt(i / 8);
        slot.* = try addSteeredEntity(&data, .{ .x = x * 16.0, .y = y * 16.0 });
    }
    _ = try addStaticObstacle(&data, .{ .x = 48, .y = -12 }, .{ .x = 16, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{
        .max_frame_requests = agents.len,
        .max_pending_requests = agents.len,
        .max_cached_results = agents.len * 2,
        .max_group_fields = 1,
        .worker_participant_count = 1,
        .max_solved_requests_per_step = agents.len,
    });
    try pathfinding.rebuildStaticNavGrid(&data, 256, 256, 32);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = steering_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(8, 0, agents.len, 0, 0, 0);
    try frame.reservePathRequests(8, agents.len);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(agents.len);

    const cfg: SteeringConfig = .{
        .items_per_range = steering_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    };

    // One batched append: each appendNavigationIntent prepareRangeCounts-clears
    // the stream, so a per-agent loop would leave only the last intent and collapse
    // the batch to a single-range inline path.
    var warmup_intents: [agents.len]NavigationIntent = undefined;
    for (&warmup_intents, agents) |*slot, agent| {
        slot.* = .{ .entity = agent, .goal = .{ .x = 200, .y = 0 }, .direct_direction_x = 1 };
    }
    frame.beginStep();
    try appendNavigationIntents(&frame, &warmup_intents);
    const warmup = try steering.update(&data, &frame, &threads, &pathfinding, cfg);
    try std.testing.expect(!warmup.batch.ran_inline);

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
    try appendNavigationIntents(&frame, &warmup_intents);
    const stats = try steering.update(&data, &frame, &threads, &pathfinding, cfg);
    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expectEqual(agents.len, stats.movement_intent_count);
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

test "steering production adaptive tuner uses central gate and range alignment" {
    var system = SteeringSystem.init(std.testing.allocator);
    defer system.deinit();
    try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, system.adaptive_tuner.config.threaded_batch_ns);
    try std.testing.expectEqual(steering_range_alignment_items, system.adaptive_tuner.config.initial_range_items);
    try std.testing.expectEqual(steering_range_alignment_items, system.adaptive_tuner.config.smallest_range_items);
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
