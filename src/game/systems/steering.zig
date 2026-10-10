// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Steering and local avoidance system.
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
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const ConstScopeColumnsSlice = @import("../data_system.zig").ConstScopeColumnsSlice;
const ConstSteeringAgentSlice = @import("../data_system.zig").ConstSteeringAgentSlice;
const Component = @import("../data_system.zig").Component;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const StructuralChange = @import("../data_system.zig").StructuralChange;
const StageTimer = runtime_perf_log.StageTimer;
const MovementIntent = @import("../simulation.zig").MovementIntent;
const NavigationIntent = @import("../simulation.zig").NavigationIntent;
const PathRequest = @import("../simulation.zig").PathRequest;
const SimulationIntent = @import("../simulation.zig").SimulationIntent;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const PathfindingSystem = @import("pathfinding.zig").PathfindingSystem;
const StaticColliderSystem = @import("static_colliders.zig").StaticColliderSystem;
const ColliderView = @import("static_colliders.zig").ColliderView;
const BoxHits = @import("static_colliders.zig").BoxHits;

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

/// Prefer the dense movement scope level (kept in sync with world_level) when the
/// caller already has a movement row index — avoids a second entity slot resolve.
fn movementScopeLevel(scope: ConstScopeColumnsSlice, movement_index: usize) u16 {
    if (movement_index >= scope.level.len) return 0;
    return scope.level[movement_index];
}

const invalid_index = std.math.maxInt(usize);
const min_spatial_cell_size: f32 = 1.0;
const max_agent_candidate_checks: u16 = 64;
// Per-agent obstacle query budgets: the query stops after this many static boxes meeting
// the query box (each a push candidate), or after `max_obstacle_work` probes and entry
// reads.
const max_obstacle_hits: u16 = 64;
const max_obstacle_work: u16 = 512;

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
    /// Static-collider query entries read.
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
    spatial_cell_size: f32 = 64.0,
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),

    pub fn init(allocator: std.mem.Allocator) SteeringSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SteeringSystem) void {
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

    pub fn invalidateSteeringMovementIndexCache(self: *SteeringSystem) void {
        self.steering_movement_index_valid = false;
    }

    /// Post-commit reaction: invalidates the steering-to-movement index cache when the
    /// step's entity changes can renumber or drop those dense pairs. Reads only the
    /// entity change list, so a step without entity changes costs O(1). Allocation-free.
    pub fn reactToPostCommitSteeringEvents(self: *SteeringSystem, frame: *const SimulationFrame) void {
        const stats = frame.events.stats;
        if (stats.entity_created + stats.entity_destroyed + stats.component_changed == 0) return;
        for (frame.structural_changes_scratch.items) |change| {
            if (changeInvalidatesSteeringMovementIndexCache(change)) {
                self.invalidateSteeringMovementIndexCache();
                return;
            }
        }
    }

    pub fn reserve(self: *SteeringSystem, max_agents: usize) !void {
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
            .selected_world_level = s.items(.selected_world_level),
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
            .selected_world_level = s.items(.selected_world_level),
        };
    }

    pub fn agentSnapshotSliceConst(self: *const SteeringSystem) ConstAgentSnapshotSlice {
        const s = self.agent_snapshot_rows.slice();
        return .{
            .entity = s.items(.entity),
            .x = s.items(.x),
            .y = s.items(.y),
            .radius = s.items(.radius),
            .world_level = s.items(.world_level),
        };
    }

    /// One steering step. Obstacle pushes read `colliders`' synced rows through a view
    /// taken once here; the movement job runs on `thread_system`'s workers.
    pub fn update(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        pathfinding: *const PathfindingSystem,
        colliders: *const StaticColliderSystem,
        config: SteeringConfig,
    ) !SteeringStats {
        var stats = try self.prepareUpdate(data, frame, pathfinding, config);
        try self.writePathRequests(data, frame, stats.path_request_count);
        stats.batch = try self.writeMovementIntentsThreaded(frame, thread_system, colliders.view(), config);
        self.finishStats(&stats);
        return stats;
    }

    pub fn updateSerial(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        pathfinding: *const PathfindingSystem,
        colliders: *const StaticColliderSystem,
        config: SteeringConfig,
    ) !SteeringStats {
        var stats = try self.prepareUpdate(data, frame, pathfinding, config);
        try self.writePathRequests(data, frame, stats.path_request_count);
        stats.batch = try self.writeMovementIntentsSerial(frame, colliders.view());
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
        try self.gatherWorldSnapshot(data, movement, steering);
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
        const scope = data.scopeColumnsSliceConst();
        std.debug.assert(movement_indices.len == steering.entities.len);
        for (steering.entities, movement_indices, 0..) |entity, movement_index, steering_index| {
            if (movement_index == invalid_index) continue;
            if (movement_index >= movement.previous_x.len) continue;
            appendMalRow(AgentSnapshotRow, &self.agent_snapshot_rows, &agent_row_slice, .{
                .entity = entity,
                .x = movement.previous_x[movement_index],
                .y = movement.previous_y[movement_index],
                .radius = steering.agent_radii[steering_index],
                // Same-level gate as collision: scope.level is kept in sync with
                // world_level (setWorldLevel / setMovementBody).
                .world_level = movementScopeLevel(scope, movement_index),
            });
        }
        try self.fillAgentCellEntriesDense(cell_size);
        try buildCellRanges(self.agent_cell_entries.items, &self.agent_cell_ranges, self.allocator);
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
                .selected_world_level = start_level,
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
        obstacles: ColliderView,
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

        var context = self.jobContext(frame, obstacles, range_base, work.range_count);
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

    fn writeMovementIntentsSerial(self: *SteeringSystem, frame: *SimulationFrame, obstacles: ColliderView) !BatchStats {
        const count = self.selected.items.len;
        if (count == 0) return .{};
        const range_base = try frame.intents.appendRangeCounts(1);
        frame.intents.addCount(range_base, count);
        try frame.intents.prefixAppendedRanges(range_base);
        var context = self.jobContext(frame, obstacles, range_base, 1);
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

    fn jobContext(self: *SteeringSystem, frame: *SimulationFrame, obstacles: ColliderView, range_base: usize, range_count: usize) SteeringJobContext {
        return .{
            .selected = self.selected.items,
            .work = self.selectedWorkSlice(),
            .agents = self.agentSnapshotSliceConst(),
            .obstacles = obstacles,
            .agent_cell_entries = self.agent_cell_entries.items,
            .agent_cell_ranges = self.agent_cell_ranges.items,
            .spatial_cell_size = self.spatial_cell_size,
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
    /// Movement-scope world level for same-level local avoidance gating.
    selected_world_level: u16,
};

const AgentSnapshotRow = struct {
    entity: EntityId,
    x: f32,
    y: f32,
    radius: f32,
    world_level: u16,
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
    selected_world_level: []u16,

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
    selected_world_level: []const u16,

    pub fn len(self: ConstSelectedWorkSlice) usize {
        return self.start_x.len;
    }
};

pub const ConstAgentSnapshotSlice = struct {
    entity: []const EntityId,
    x: ConstHotF32Slice,
    y: ConstHotF32Slice,
    radius: ConstHotF32Slice,
    world_level: []const u16,

    pub fn len(self: ConstAgentSnapshotSlice) usize {
        return self.entity.len;
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
    /// The static colliders' synced rows, read-only for the whole dispatch.
    obstacles: ColliderView,
    agent_cell_entries: []const SpatialCellEntry,
    agent_cell_ranges: []const SpatialCellRange,
    spatial_cell_size: f32,
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
    // One hit scratch per range, reused by every agent of the range.
    var obstacle_hits: ObstacleHitScratch = undefined;
    for (range.start..range.end) |index| {
        const result = computeAvoidance(job, index, &obstacle_hits);
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

fn computeAvoidance(job: *const SteeringJobContext, index: usize, obstacle_hits: *ObstacleHitScratch) AvoidanceResult {
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

    const start_x = job.work.start_x[index];
    const start_y = job.work.start_y[index];
    const radius = job.work.selected_avoidance_radii[index] + job.work.selected_agent_radii[index];
    const weight = job.work.selected_avoidance_weights[index];
    // Statics on the agent's level whose box meets the query box: every static that can
    // push lies within `radius` of the agent, so inside the box.
    const box = math.Aabb{ .min_x = start_x - radius, .min_y = start_y - radius, .max_x = start_x + radius, .max_y = start_y + radius };
    const query = job.obstacles.queryBox(job.work.selected_world_level[index], box, .{
        .max_hits = max_obstacle_hits,
        .max_work = max_obstacle_work,
    }, obstacle_hits.boxHits());
    var push = ObstaclePush{ .ax = ax, .ay = ay };
    pushObstacles(obstacle_hits, query.hits, start_x, start_y, radius, weight, &push);

    return .{
        .direction = math.normalizeOrZeroFinite(push.ax, push.ay, 0.0001),
        .agent_samples = sample_count,
        .obstacle_samples = push.samples,
        .agent_candidate_checks = agent_candidate_count,
        .obstacle_candidate_checks = query.entries,
    };
}

// One agent's obstacle hit boxes, packed by `ColliderView.queryBox` for the SIMD push.
const ObstacleHitScratch = struct {
    min_x: [max_obstacle_hits]f32,
    min_y: [max_obstacle_hits]f32,
    max_x: [max_obstacle_hits]f32,
    max_y: [max_obstacle_hits]f32,

    fn boxHits(self: *ObstacleHitScratch) BoxHits {
        return .{ .min_x = &self.min_x, .min_y = &self.min_y, .max_x = &self.max_x, .max_y = &self.max_y };
    }
};

// The accumulated steering direction and the obstacle pushes added to it.
const ObstaclePush = struct {
    ax: f32,
    ay: f32,
    samples: u16 = 0,
};

// Adds the push of each of the first `count` hit boxes, in hit order, to `push`: four boxes
// per lane group with a scalar tail. Lanes add in lane order and a lane out of range is
// skipped (never added as zero, which would turn -0.0 into +0.0), so the result equals
// `pushObstacleScalar` over every box bit for bit.
fn pushObstacles(hits: *const ObstacleHitScratch, count: usize, start_x: f32, start_y: f32, radius: f32, weight: f32, push: *ObstaclePush) void {
    std.debug.assert(count <= max_obstacle_hits);
    const start_x_lanes = simd.splatFloat4(start_x);
    const start_y_lanes = simd.splatFloat4(start_y);
    const radius_lanes = simd.splatFloat4(radius);
    const radius2_lanes = simd.splatFloat4(radius * radius);
    const weight_lanes = simd.splatFloat4(weight);
    const min_dist2_lanes = simd.splatFloat4(obstacle_min_dist2);
    const half = simd.splatFloat4(0.5);
    const one = simd.splatFloat4(1);
    const zero = simd.splatFloat4(0);
    var at: usize = 0;
    const vector_end = simd.vectorizedEnd(count);
    while (at < vector_end) : (at += simd.lane_count) {
        const min_x = simd.loadFloat4(hits.min_x[at..]);
        const min_y = simd.loadFloat4(hits.min_y[at..]);
        const max_x = simd.loadFloat4(hits.max_x[at..]);
        const max_y = simd.loadFloat4(hits.max_y[at..]);
        const edge_dx = start_x_lanes - simd.clampFloat4(start_x_lanes, min_x, max_x);
        const edge_dy = start_y_lanes - simd.clampFloat4(start_y_lanes, min_y, max_y);
        // Inside the box: push away from its center.
        const inside = simd.equalFloat4(edge_dx, zero) & simd.equalFloat4(edge_dy, zero);
        const dx = simd.selectFloat4(inside, start_x_lanes - (min_x + max_x) * half, edge_dx);
        const dy = simd.selectFloat4(inside, start_y_lanes - (min_y + max_y) * half, edge_dy);
        const dist2 = simd.lengthSquared2Float4(dx, dy);
        const in_range = simd.greaterThanFloat4(dist2, min_dist2_lanes) & simd.lessThanFloat4(dist2, radius2_lanes);
        const length_direction = simd.lengthDirection2Float4(dx, dy, 0);
        const strength = (one - length_direction.length / radius_lanes) * weight_lanes;
        const push_x = length_direction.direction.x * strength;
        const push_y = length_direction.direction.y * strength;
        inline for (0..simd.lane_count) |lane| {
            if (in_range[lane]) {
                push.ax += push_x[lane];
                push.ay += push_y[lane];
                push.samples += 1;
            }
        }
    }
    while (at < count) : (at += 1) {
        pushObstacleScalar(hits.min_x[at], hits.min_y[at], hits.max_x[at], hits.max_y[at], start_x, start_y, radius, weight, push);
    }
}

// Squared distances at or below this push nothing (no stable direction).
const obstacle_min_dist2: f32 = 0.0001;

// One box's push toward its closest point's opposite side, or from its center when the
// agent is inside it, falling off linearly to zero at `radius`.
fn pushObstacleScalar(min_x: f32, min_y: f32, max_x: f32, max_y: f32, start_x: f32, start_y: f32, radius: f32, weight: f32, push: *ObstaclePush) void {
    var dx = start_x - math.clampMinMax(start_x, min_x, max_x);
    var dy = start_y - math.clampMinMax(start_y, min_y, max_y);
    if (dx == 0 and dy == 0) {
        dx = start_x - (min_x + max_x) * 0.5;
        dy = start_y - (min_y + max_y) * 0.5;
    }
    const dist2 = dx * dx + dy * dy;
    if (dist2 > obstacle_min_dist2 and dist2 < radius * radius) {
        const length_direction = math.lengthDirection(dx, dy, 0);
        const strength = (1.0 - length_direction.length / radius) * weight;
        push.ax += length_direction.direction.x * strength;
        push.ay += length_direction.direction.y * strength;
        push.samples += 1;
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
                // Match collision's sameWorldLevel gate: pure-XY overlap across
                // floors must not produce a lateral push.
                if (job.agents.world_level[other_index] != job.work.selected_world_level[index]) continue;
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

/// Whether a committed entity change can renumber or drop steering-to-movement dense
/// index pairs (swap-remove, destroy, add/remove components), forcing a rebuild of
/// `steering_movement_index` before the next snapshot.
fn changeInvalidatesSteeringMovementIndexCache(change: StructuralChange) bool {
    return switch (change) {
        .entity_destroyed, .entity_created => true,
        .component_changed => |changed| switch (changed.component) {
            .movement_body, .steering_agent => true,
            else => false,
        },
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
    try std.testing.expectEqual(count, s.items(.world_level).len);
}

// Test-only fixtures for multi-level start_level regression (not production API).
const WorldSystem = @import("../world_system.zig").WorldSystem;
const loadTestWorldMeta = @import("pathfinding/test_support.zig").loadTestWorldMeta;
const worldColliders = @import("pathfinding/test_support.zig").worldColliders;
const StructuralCommand = @import("../data_system.zig").StructuralCommand;
const requireTestTile = @import("pathfinding/test_support.zig").requireTestTile;

test "steering agent snapshot rows keep MAL columns compact after gather" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addSteeredEntity(&data, .{ .x = 32, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    // Never rebuilt: no rows.
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});

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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const missing_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 1), missing_stats.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), frame.path_requests.mergedItems().len);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);

    _ = try pathfinding.updateSerial(&frame.path_requests, 1, .{});

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    const available_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

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
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const first = frame.intents.mergedItems()[0].movement;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), first.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), first.direction_y, 0.001);

    // Target direction flips a full 90 degrees to (0, 1). A hard snap would
    // jump straight to direction_y == 1; smoothing should only partially turn.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const second = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(second.direction_y > 0.0);
    try std.testing.expect(second.direction_y < 0.9);
    try std.testing.expect(second.direction_x > 0.0);

    // Repeated steps toward the same (0, 1) target converge close to it.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        frame.beginStep();
        try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
        _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    }
    const converged = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(converged.direction_y > 0.95);
}

test "steering sources path request start level from movement scope level" {
    // writePathRequests reads movementScopeLevel (scope.level, kept in sync with
    // world_level via setWorldLevel). Exercised through a full updateSerial so a
    // future edit cannot quietly hardcode start_level back to 0. Multi-level nav
    // is required: statusForWorld treats an out-of-range start level as
    // unavailable and never emits a request (not missing).
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const surface = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const underground = try addSteeredEntity(&data, .{ .x = 0, .y = 32 });
    try data.setWorldLevel(underground, 2);

    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 160, 160);
    defer world.deinit();
    // initDemoFromMeta owns level 0; add two more so start_level 2 has a grid.
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(2, 0, .floor, grass);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 2, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGridWithWorld(&data, &world, null);
    var colliders = try worldColliders(&data, &world);
    defer colliders.deinit();
    try std.testing.expect(pathfinding.graph.levelCount() >= 3);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    // Fresh entities (no replan cooldown): both missing-path agents emit in one step.
    frame.beginStep();
    try appendNavigationIntents(&frame, &.{
        .{ .entity = surface, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
        .{ .entity = underground, .goal_level = 2, .goal = .{ .x = 96, .y = 32 }, .direct_direction_x = 1 },
    });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});

    const requests = frame.path_requests.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), requests.len);

    var saw_surface = false;
    var saw_underground = false;
    for (requests) |request| {
        if (request.entity.eql(surface)) {
            try std.testing.expectEqual(@as(u16, 0), request.start_level);
            saw_surface = true;
        } else if (request.entity.eql(underground)) {
            try std.testing.expectEqual(@as(u16, 2), request.start_level);
            try std.testing.expectEqual(@as(u16, 2), request.goal_level);
            saw_underground = true;
        }
    }
    try std.testing.expect(saw_surface);
    try std.testing.expect(saw_underground);
    try std.testing.expectEqual(
        @as(u16, 2),
        data.scopeColumnsSliceConst().level[data.movementBodyDenseIndex(underground).?],
    );
}

test "steering missing path requests respect replan cooldown" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 2, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const first = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 1), first.path_request_count);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const second = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 128, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const solve = try pathfinding.updateSerial(&frame.path_requests, 1, .{});
    try std.testing.expectEqual(@as(usize, 1), solve.unavailable_results);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 128, .y = 0 }, .direct_direction_x = 1 });
    const unavailable = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{ .max_selected_intents = 1 });
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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 1), steering.runtime_rows.items.len);

    try std.testing.expect(data.destroyEntity(agent));
    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
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
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const movement = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(stats.agent_neighbor_samples > 0);
    try std.testing.expect(stats.obstacle_samples > 0);
    try std.testing.expect(movement.direction_x < 1);
}

test "steering local agent avoidance ignores XY overlap across different world_levels" {
    // Two agents fully overlap in XY but sit on different floors. Without a
    // same-level gate the neighbor would push the steerer; with it, samples
    // stay zero and the direct direction is unchanged.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const other = try addSteeredEntity(&data, .{ .x = 20, .y = 0 });
    try data.setWorldLevel(agent, 0);
    try data.setWorldLevel(other, 1);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const movement = frame.intents.mergedItems()[0].movement;
    try std.testing.expectEqual(@as(usize, 0), stats.agent_neighbor_samples);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), movement.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), movement.direction_y, 0.001);
}

test "steering static obstacle avoidance ignores XY overlap across different world_levels" {
    // A level-1 agent overlaps a level-0 static box in XY: the box is never read and does
    // not push. Moving the box to level 1 through a committed `.world_level` change and
    // the collider sync makes it push on the next step.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const obstacle = try addStaticObstacle(&data, .{ .x = 4, .y = -12 }, .{ .x = 20, .y = 20 });
    try data.setWorldLevel(agent, 1);
    try data.setWorldLevel(obstacle, 0);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const cross_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const cross = frame.intents.mergedItems()[0].movement;
    // The other level's lists are never walked.
    try std.testing.expectEqual(@as(usize, 0), cross_stats.obstacle_candidate_checks);
    try std.testing.expectEqual(@as(usize, 0), cross_stats.obstacle_samples);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cross.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cross.direction_y, 0.001);

    frame.beginStep();
    try commitStaticsForTest(&frame, &data, &colliders, &.{.{ .set_world_level = .{ .entity = obstacle, .level = 1 } }});
    steering.reactToPostCommitSteeringEvents(&frame);
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const same_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    const same = frame.intents.mergedItems()[0].movement;
    try std.testing.expectEqual(@as(usize, 1), same_stats.obstacle_candidate_checks);
    try std.testing.expectEqual(@as(usize, 1), same_stats.obstacle_samples);
    try std.testing.expect(same.direction_x < 1);
}

test "steering multi-level obstacle gate matches between serial and real threaded workers" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Alternating agent levels over one static box per level at overlapping XY:
    // each agent may only react to its own floor's box, identically under every
    // worker split.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var intents = std.ArrayList(NavigationIntent).empty;
    defer intents.deinit(std.testing.allocator);
    try intents.ensureTotalCapacity(std.testing.allocator, 128);

    for (0..128) |index| {
        const x: f32 = @floatFromInt(index % 16);
        const y: f32 = @floatFromInt(index / 16);
        const entity = try addSteeredEntity(&data, .{ .x = x * 14.0, .y = y * 14.0 });
        try data.setWorldLevel(entity, @intCast(index % 2));
        intents.appendAssumeCapacity(.{
            .entity = entity,
            .goal = .{ .x = 420, .y = 220 },
            .direct_direction_x = if (index % 2 == 0) 1 else -1,
            .direct_direction_y = if (index % 3 == 0) 0.25 else -0.15,
            .priority = 1,
        });
    }
    // Statics of several size classes over both chunk columns, alternating levels.
    for (parity_statics, 0..) |placement, index| {
        const entity = try addStaticObstacle(&data, placement[0], placement[1]);
        try data.setWorldLevel(entity, @intCast(index % 2));
    }

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 128, .max_pending_requests = 128, .max_cached_results = 256, .max_group_fields = 4, .worker_participant_count = 1, .max_solved_requests_per_step = 128 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();
    try expectParityStaticsSpread(&colliders);

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(16, 0, 128, 0, 0, 0);
    try serial_frame.reservePathRequests(16, 128);
    serial_frame.beginStep();
    try appendNavigationIntents(&serial_frame, intents.items);
    var serial_system = SteeringSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(128);
    const serial_stats = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, &colliders, .{});
    const serial = serial_frame.intents.mergedItems();
    try std.testing.expect(serial.len > 0);
    try std.testing.expect(serial_stats.obstacle_samples > 0);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = steering_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = steering_range_alignment_items, .workers = 2 },
        .{ .items_per_range = steering_range_alignment_items * 3, .workers = 4 },
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
        const threaded_stats = try threaded_system.update(&data, &threaded_frame, &threads, &pathfinding, &colliders, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        try std.testing.expect(threaded_stats.batch.active_worker_threads > 0);
        try std.testing.expectEqual(serial_stats.obstacle_samples, threaded_stats.obstacle_samples);
        try std.testing.expectEqual(serial_stats.obstacle_candidate_checks, threaded_stats.obstacle_candidate_checks);
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

test "steering movement index cache rebuilds only after structural invalidate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(8);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expect(steering.steering_movement_index_valid);
    try std.testing.expectEqual(@as(usize, 1), steering.steering_movement_index.items.len);
    const cached_mi = steering.steering_movement_index.items[0];
    try std.testing.expectEqual(data.movementBodyDenseIndex(agent).?, cached_mi);

    // Second step without structural events reuses the cache.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expect(steering.steering_movement_index_valid);
    try std.testing.expectEqual(cached_mi, steering.steering_movement_index.items[0]);

    // A step whose commit changed only tiles keeps the cache.
    const other = try addSteeredEntity(&data, .{ .x = 40, .y = 0 });
    frame.beginStep();
    try frame.events.ensureCanAppend(1);
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = .{
        .level = 0,
        .x = 1,
        .y = 1,
        .old_tile_id = 0,
        .new_tile_id = 0,
        .old_blocks_movement = false,
        .new_blocks_movement = true,
    } } });
    steering.reactToPostCommitSteeringEvents(&frame);
    try std.testing.expect(steering.steering_movement_index_valid);

    // A committed destroy of a different entity invalidates it (renumber risk).
    frame.beginStep();
    try commitStaticsForTest(&frame, &data, &colliders, &.{.{ .destroy_entity = other }});
    steering.reactToPostCommitSteeringEvents(&frame);
    try std.testing.expect(!steering.steering_movement_index_valid);
}

test "steering pushes from a static's committed position the step after its move commits" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const parked = math.Vec2{ .x = 0, .y = 400 };
    const box = try addStaticObstacle(&data, parked, .{ .x = 20, .y = 20 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 640, 640, 32);
    var colliders = try testColliders(&pathfinding, &data, 640, 640, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const parked_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 0), parked_stats.obstacle_samples);
    try std.testing.expectApproxEqAbs(@as(f32, 0), frame.intents.mergedItems()[0].movement.direction_y, 0.001);

    // The commit moves the box above the agent; its previous position stays parked, so
    // only the committed position can push.
    frame.beginStep();
    try commitStaticsForTest(&frame, &data, &colliders, &.{.{ .set_movement_body = .{
        .entity = box,
        .body = .{ .position = .{ .x = 8, .y = -32 }, .previous_position = parked, .velocity = .{}, .speed = 0 },
    } }});
    steering.reactToPostCommitSteeringEvents(&frame);
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const moved_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 1), moved_stats.obstacle_samples);
    // Pushed away from the box, toward +y.
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_y > 0.05);
}

test "steering obstacle pushes equal a scalar push over the query's hits" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Agents far enough apart that no agent pushes another.
    const agent_positions = [_]math.Vec2{ .{ .x = 60, .y = 60 }, .{ .x = 260, .y = 60 }, .{ .x = 60, .y = 260 }, .{ .x = 500, .y = 300 } };
    var agents: [agent_positions.len]EntityId = undefined;
    for (&agents, agent_positions) |*agent, position| agent.* = try addSteeredEntity(&data, position);
    // Several size classes; a chunk-border box the second agent stands inside; negative,
    // outside-the-level, larger-than-the-level, and sub-unit boxes; a cluster giving the
    // first agent more hits than one SIMD lane group; and an overlapping box on another
    // level.
    const placements = [_][2]math.Vec2{
        .{ .{ .x = 40, .y = 40 }, .{ .x = 10, .y = 10 } },
        .{ .{ .x = 70, .y = 30 }, .{ .x = 40, .y = 40 } },
        .{ .{ .x = 250, .y = 50 }, .{ .x = 12, .y = 12 } },
        .{ .{ .x = 240, .y = 10 }, .{ .x = 100, .y = 20 } },
        .{ .{ .x = -20, .y = 240 }, .{ .x = 30, .y = 30 } },
        .{ .{ .x = 520, .y = 280 }, .{ .x = 30, .y = 30 } },
        .{ .{ .x = 480, .y = 320 }, .{ .x = 600, .y = 10 } },
        .{ .{ .x = 60, .y = 250 }, .{ .x = 0.5, .y = 0.5 } },
        .{ .{ .x = 20, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 32, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 44, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 56, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 68, .y = 75 }, .{ .x = 8, .y = 8 } },
    };
    for (placements) |placement| _ = try addStaticObstacle(&data, placement[0], placement[1]);
    const other_level = try addStaticObstacle(&data, .{ .x = 50, .y = 50 }, .{ .x = 20, .y = 20 });
    try data.setWorldLevel(other_level, 1);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    var intents: [agents.len]NavigationIntent = undefined;
    for (&intents, agents) |*intent, agent| intent.* = .{ .entity = agent, .goal = .{ .x = 999, .y = 0 }, .direct_direction_x = 1 };
    frame.beginStep();
    try appendNavigationIntents(&frame, &intents);
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});

    // The reference: the direct direction plus the scalar push of each hit in query order.
    const view = colliders.view();
    var hits: ObstacleHitScratch = undefined;
    var samples: usize = 0;
    var max_hits: u16 = 0;
    for (frame.intents.mergedItems(), agent_positions) |intent, position| {
        const radius: f32 = 48 + 8;
        const box = math.Aabb{ .min_x = position.x - radius, .min_y = position.y - radius, .max_x = position.x + radius, .max_y = position.y + radius };
        const query = view.queryBox(0, box, .{ .max_hits = max_obstacle_hits, .max_work = max_obstacle_work }, hits.boxHits());
        max_hits = @max(max_hits, query.hits);
        var push = ObstaclePush{ .ax = 1, .ay = 0 };
        for (0..query.hits) |at| pushObstacleScalar(hits.min_x[at], hits.min_y[at], hits.max_x[at], hits.max_y[at], position.x, position.y, radius, 1.5, &push);
        samples += push.samples;
        const expected = math.normalizeOrZeroFinite(push.ax, push.ay, 0.0001);
        try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(intent.movement.direction_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(intent.movement.direction_y)));
    }
    try std.testing.expectEqual(samples, stats.obstacle_samples);
    try std.testing.expect(samples >= agents.len);
    try std.testing.expect(max_hits > simd.lane_count);
}

test "steering obstacle SIMD push equals the scalar push" {
    var prng = std.Random.DefaultPrng.init(0x0b57);
    const random = prng.random();
    var hits: ObstacleHitScratch = undefined;
    // An agent at the origin with radius 10: boxes holding it (off center and centered),
    // one exactly on the radius, one closer than the push epsilon, then random boxes.
    const crafted = [_][4]f32{
        .{ -1, -1, 3, 3 },
        .{ 10, -2, 12, 2 },
        .{ 0.005, -1, 2, 1 },
        .{ -1, -1, 1, 1 },
        .{ 2, 2, 4, 5 },
    };
    for (0..max_obstacle_hits) |at| {
        const box: [4]f32 = if (at < crafted.len) crafted[at] else blk: {
            const min_x = random.float(f32) * 24 - 12;
            const min_y = random.float(f32) * 24 - 12;
            break :blk .{ min_x, min_y, min_x + random.float(f32) * 6, min_y + random.float(f32) * 6 };
        };
        hits.min_x[at] = box[0];
        hits.min_y[at] = box[1];
        hits.max_x[at] = box[2];
        hits.max_y[at] = box[3];
    }
    for ([_]usize{ 0, 1, 3, 4, 5, 8, 9, 64 }) |count| {
        // -0.0 stays -0.0 unless a push is added.
        var lanes = ObstaclePush{ .ax = 0.25, .ay = -0.0 };
        pushObstacles(&hits, count, 0, 0, 10, 1.5, &lanes);
        var scalar = ObstaclePush{ .ax = 0.25, .ay = -0.0 };
        for (0..count) |at| pushObstacleScalar(hits.min_x[at], hits.min_y[at], hits.max_x[at], hits.max_y[at], 0, 0, 10, 1.5, &scalar);
        try std.testing.expectEqual(scalar.samples, lanes.samples);
        try std.testing.expectEqual(@as(u32, @bitCast(scalar.ax)), @as(u32, @bitCast(lanes.ax)));
        try std.testing.expectEqual(@as(u32, @bitCast(scalar.ay)), @as(u32, @bitCast(lanes.ay)));
    }
    // The crafted on-radius, sub-epsilon, and centered boxes push nothing.
    var crafted_push = ObstaclePush{ .ax = 0, .ay = 0 };
    pushObstacles(&hits, crafted.len, 0, 0, 10, 1.5, &crafted_push);
    try std.testing.expectEqual(@as(u16, 2), crafted_push.samples);
}

test "steering stops the obstacle walk at the work budget in query order" {
    // Co-located tiny statics in a cell the walk reaches before the one pushing static,
    // none meeting the query box: past the work budget they hide the near static.
    try std.testing.expectEqual(@as(usize, 0), try obstacleSamplesBehindFarEntries(600));
    try std.testing.expectEqual(@as(usize, 1), try obstacleSamplesBehindFarEntries(400));
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
    // Statics of several size classes over both chunk columns.
    for (parity_statics) |placement| _ = try addStaticObstacle(&data, placement[0], placement[1]);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 128, .max_pending_requests = 128, .max_cached_results = 256, .max_group_fields = 4, .worker_participant_count = 1, .max_solved_requests_per_step = 128 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();
    try expectParityStaticsSpread(&colliders);

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(16, 0, 128, 0, 0, 0);
    try serial_frame.reservePathRequests(16, 128);
    serial_frame.beginStep();
    try appendNavigationIntents(&serial_frame, intents.items);
    var serial_system = SteeringSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(128);
    const serial_stats = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, &colliders, .{});
    const serial = serial_frame.intents.mergedItems();
    try std.testing.expect(serial_stats.obstacle_samples > 0);

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
    const threaded_stats = try threaded_system.update(&data, &threaded_frame, &threads, &pathfinding, &colliders, .{
        .items_per_range = steering_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    const threaded = threaded_frame.intents.mergedItems();

    try std.testing.expect(threaded_stats.batch.active_worker_threads > 0);
    try std.testing.expectEqual(serial_stats.obstacle_samples, threaded_stats.obstacle_samples);
    try std.testing.expectEqual(serial_stats.obstacle_candidate_checks, threaded_stats.obstacle_candidate_checks);
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
    // Statics of several size classes over both chunk columns.
    for (parity_statics) |placement| _ = try addStaticObstacle(&data, placement[0], placement[1]);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 128, .max_pending_requests = 128, .max_cached_results = 256, .max_group_fields = 4, .worker_participant_count = 1, .max_solved_requests_per_step = 128 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();
    try expectParityStaticsSpread(&colliders);

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(16, 0, 128, 0, 0, 0);
    try serial_frame.reservePathRequests(16, 128);
    serial_frame.beginStep();
    try appendNavigationIntents(&serial_frame, intents.items);
    var serial_system = SteeringSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(128);
    _ = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, &colliders, .{});
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
        const threaded_stats = try threaded_system.update(&data, &threaded_frame, &threads, &pathfinding, &colliders, .{
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

test "steering update is allocation-free after reserves from the first step" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addSteeredEntity(&data, .{ .x = 24, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 32, .y = -12 }, .{ .x = 16, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });

    // No warm-up step: a first-step allocation means `reserve` misses a term.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_system_allocator = steering.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    const original_intent_allocator = frame.intents.allocator;
    const original_path_allocator = frame.path_requests.allocator;
    steering.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    frame.intents.allocator = failing.allocator();
    frame.path_requests.allocator = failing.allocator();
    setCollidersAllocator(&colliders, failing.allocator());
    defer {
        steering.allocator = original_system_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
        frame.intents.allocator = original_intent_allocator;
        frame.path_requests.allocator = original_path_allocator;
        setCollidersAllocator(&colliders, std.testing.allocator);
    }

    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
    try std.testing.expect(stats.obstacle_samples > 0);
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
    // Across the chunk border at x = 256, and a box larger than a chunk.
    _ = try addStaticObstacle(&data, .{ .x = 240, .y = 40 }, .{ .x = 40, .y = 20 });
    _ = try addStaticObstacle(&data, .{ .x = 100, .y = 30 }, .{ .x = 300, .y = 8 });

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
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();

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
    const warmup = try steering.update(&data, &frame, &threads, &pathfinding, &colliders, cfg);
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
    setCollidersAllocator(&colliders, failing.allocator());
    defer {
        steering.allocator = original_system_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
        frame.intents.allocator = original_intent_allocator;
        frame.path_requests.allocator = original_path_allocator;
        setCollidersAllocator(&colliders, std.testing.allocator);
    }

    frame.beginStep();
    try appendNavigationIntents(&frame, &warmup_intents);
    const stats = try steering.update(&data, &frame, &threads, &pathfinding, &colliders, cfg);
    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expectEqual(agents.len, stats.movement_intent_count);
    try std.testing.expect(stats.obstacle_samples > 0);
}

test "steering prunes runtime rows for destroyed entities" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(1);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expectEqual(@as(usize, 1), steering.runtime_rows.items.len);

    try std.testing.expect(data.destroyEntity(agent));
    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
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
    var colliders = try testColliders(&pathfinding, &data, 256, 256, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(129);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expect(stats.agent_candidate_checks <= max_agent_candidate_checks);
    try std.testing.expect(stats.agent_neighbor_samples <= 256);
    try std.testing.expect(stats.agent_candidate_checks > 0);
}

test "steering stops the obstacle walk at the hit cap among dense co-located statics" {
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
    var colliders = try testColliders(&pathfinding, &data, 256, 256, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(1);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    // Every co-located static meets the query box, so each entry read is a hit: the walk
    // stops at the hit cap after reading `max_obstacle_hits` of the 128 entries.
    try std.testing.expectEqual(@as(usize, max_obstacle_hits), stats.obstacle_candidate_checks);
    try std.testing.expect(stats.obstacle_samples <= max_obstacle_hits);
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

// Static colliders of `data`'s statics on the cell grid of `pathfinding`'s world-less build
// over `width` x `height`.
fn testColliders(pathfinding: *const PathfindingSystem, data: *const DataSystem, width: f32, height: f32, cell_size: f32) !StaticColliderSystem {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    errdefer colliders.deinit();
    try colliders.rebuild(data, try pathfinding.boundsNavExtent(width, height, cell_size).colliderGeometry());
    return colliders;
}

fn setCollidersAllocator(colliders: *StaticColliderSystem, allocator: std.mem.Allocator) void {
    colliders.allocator = allocator;
    colliders.chunk_lists.allocator = allocator;
    colliders.query_lists.allocator = allocator;
}

// The commit seam for statics in this step: the collider reserve, the commit of
// `commands`, the capture, and the sync.
fn commitStaticsForTest(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand) !void {
    try colliders.reserveForCommit(data, commands.len);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(data);
    colliders.capture(frame);
    try colliders.sync(data, null);
}

// Parity statics on a 512-unit level of 16-unit cells (2 x 2 chunks): boxes of size
// classes 0 through the top, one across the chunk border at x = 256, near the parity
// agents' 224 x 112 grid.
const parity_statics = [_][2]math.Vec2{
    .{ .{ .x = 72, .y = 32 }, .{ .x = 36, .y = 96 } },
    .{ .{ .x = 96, .y = 20 }, .{ .x = 48, .y = 60 } },
    .{ .{ .x = 30, .y = 70 }, .{ .x = 8, .y = 8 } },
    .{ .{ .x = 140, .y = 40 }, .{ .x = 20, .y = 20 } },
    .{ .{ .x = 200, .y = 60 }, .{ .x = 70, .y = 12 } },
    .{ .{ .x = 180, .y = 90 }, .{ .x = 300, .y = 30 } },
};

// The parity statics span at least two query classes and two chunks.
fn expectParityStaticsSpread(colliders: *const StaticColliderSystem) !void {
    try std.testing.expect(colliders.query_class_mask.count() >= 2);
    const view = colliders.view();
    try std.testing.expect(view.chunkHasRows(0, 0) and view.chunkHasRows(0, 1));
}

// One agent at (300, 300) with a static pushing it from below-right, behind `far_count`
// co-located one-unit statics just outside its query box in an earlier walked cell.
// Returns the agent's obstacle pushes.
fn obstacleSamplesBehindFarEntries(far_count: usize) !usize {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 300, .y = 300 });
    for (0..far_count) |_| _ = try addStaticObstacle(&data, .{ .x = 224, .y = 224 }, .{ .x = 1, .y = 1 });
    _ = try addStaticObstacle(&data, .{ .x = 320, .y = 290 }, .{ .x = 10, .y = 10 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
    var colliders = try testColliders(&pathfinding, &data, 640, 640, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(1);
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 300 }, .direct_direction_x = 1 });
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders, .{});
    try std.testing.expect(stats.obstacle_candidate_checks <= max_obstacle_work);
    return stats.obstacle_samples;
}
