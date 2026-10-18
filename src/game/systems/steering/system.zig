// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Steering and local avoidance system.
//! Consumes high-level navigation intents, pathfinding status, and steering
//! component data, then emits final movement intents and path requests for NPC movement.
//! Thread-system stages, each with an inline path: `agents` (runtime tick, agent snapshot,
//! movement-index refresh), `select_resolve` and `select_claim` (one intent per steering
//! row), `directions` (path status and base direction), `grid_bucket` and `grid_sort` (the
//! agent grid in sampled cell-key bands), and the avoidance pass. Worker jobs read immutable
//! slices and write their range's window, or the steering rows or band slice they own. The
//! main thread keeps per-range and per-band bookkeeping, the band splitters, and the rekey
//! of runtime rows a commit moved.

const std = @import("std");
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../../../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const PaddedSlot = @import("../../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../../app/thread_system.zig").SlotList;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const band_tuner_config = @import("../../../app/thread_system.zig").band_tuner_config;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const setRowCount = @import("../../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const simd = @import("../../../core/simd.zig");
const ConstScopeColumnsSlice = @import("../../data_system.zig").ConstScopeColumnsSlice;
const ConstSteeringAgentSlice = @import("../../data_system.zig").ConstSteeringAgentSlice;
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const StructuralChange = @import("../../data_system.zig").StructuralChange;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const StageTimer = runtime_perf_log.StageTimer;
const NavigationIntent = @import("../../simulation.zig").NavigationIntent;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const PathfindingSystem = @import("../pathfinding.zig").PathfindingSystem;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const ColliderView = @import("../static_colliders.zig").ColliderView;
const HotF32Slice = @import("../../data_system.zig").HotF32Slice;
const ConstHotF32Slice = @import("../../data_system.zig").ConstHotF32Slice;
const selectIntents = @import("selection.zig").selectIntents;
const IntentRow = @import("selection.zig").IntentRow;
const Claim = @import("selection.zig").Claim;
const prepareDirections = @import("directions.zig").prepareDirections;
const SelectedWindow = @import("directions.zig").SelectedWindow;
const DirectionsTally = @import("directions.zig").DirectionsTally;
const buildAgentGrid = @import("agent_grid.zig").buildAgentGrid;
const GridSortTally = @import("agent_grid.zig").GridSortTally;
const AgentGridDirectory = @import("agent_grid.zig").AgentGridDirectory;
const SpatialCellEntry = @import("agent_grid.zig").SpatialCellEntry;
const SpatialCellRange = @import("agent_grid.zig").SpatialCellRange;
const writeMovementIntents = @import("avoidance.zig").writeMovementIntents;
const MovementTally = @import("avoidance.zig").MovementTally;

pub const steering_range_alignment_items: usize = @import("../../data_system.zig").movement_range_alignment_items;

// Range alignment only; batch time gate comes from AdaptiveWorkTunerConfig defaults.
const steering_adaptive_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = steering_range_alignment_items,
    .smallest_range_items = steering_range_alignment_items,
};

fn hotStoreCapacity(min_len: usize) usize {
    return std.mem.alignForwardAnyAlign(usize, min_len, steering_range_alignment_items);
}

/// Prefer the dense movement scope level (kept in sync with world_level) when the
/// caller already has a movement row index — avoids a second entity slot resolve.
pub fn movementScopeLevel(scope: ConstScopeColumnsSlice, movement_index: usize) u16 {
    if (movement_index >= scope.level.len) return 0;
    return scope.level[movement_index];
}

const invalid_index = std.math.maxInt(usize);

// The most steering rows or navigation intents one step can hold, so every row and intent
// index is a u32 below `no_row`. Steering rows stay within it by the steering store's u32
// row cap; navigation intents come one per AI cognition row, and AI rows and live entities
// stay within it by their stores' u32 caps (`createEntity` refuses past it).
const max_step_items: usize = std.math.maxInt(u32);

pub const min_spatial_cell_size: f32 = 1.0;

// Partition width of the band stages, not a capacity: results are independent of the band
// count, and a range's band histogram stays on the worker stack.
pub const max_bands: usize = 64;

pub const SteeringConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

// Threading for one update's stages: the thread system and the caller's control config.
pub const StageThreads = @import("../../../app/thread_system.zig").StageThreads(SteeringConfig);

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
    /// The avoidance pass.
    batch: BatchStats = .{},
    // Wall time (ns) of the prepare stages, inline or dispatched: selection, the agents stage
    // with its rekey, directions, and the agent grid; zero when perf logging is disabled.
    select_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    directions_ns: u64 = 0,
    grid_ns: u64 = 0,
    perf: Perf = .{},

    /// The prepare stages' batches, kept only with `runtime_perf_log.enabled`. The claim and
    /// grid sort batches hold zero items on the serial path, where selection and the grid run
    /// their single pass.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        agents_batch: BatchStats = .{},
        select_resolve_batch: BatchStats = .{},
        select_claim_batch: BatchStats = .{},
        directions_batch: BatchStats = .{},
        grid_bucket_batch: BatchStats = .{},
        grid_sort_batch: BatchStats = .{},
    } else struct {};
};

pub const SteeringSystem = struct {
    allocator: std.mem.Allocator,
    // Per-agent cooldown, progress, and smoothing state outside DataSystem, one row per
    // steering row. A row follows its entity when a commit moves steering rows, starts
    // default for an entity new to its row, and goes with its entity's steering row.
    runtime_rows: std.MultiArrayList(RuntimeRow) = .{},
    // `agents` windows of the steering rows whose runtime row holds another entity.
    rekey_positions: RowList = .empty,
    rekey_moves: std.ArrayList(RekeyMove) = .empty,
    // Each intent's dense indices, `select_resolve`'s band-ordered intent windows, and per
    // steering row this step's first and best intent, current while its stamp equals
    // `claim_stamp`.
    intent_rows: std.MultiArrayList(IntentRow) = .{},
    intent_buckets: RowList = .empty,
    claims: std.MultiArrayList(Claim) = .{},
    claim_stamp: u32 = 0,
    // `directions` writes each intent range's selected intents into that range's window of
    // `selected` and `selected_work_rows`; `selected_windows` maps the windows onto the
    // selected order the avoidance pass walks. The avoidance pass writes `final_dir`.
    selected: SelectedList = .empty,
    selected_work_rows: std.MultiArrayList(SelectedWorkRow) = .{},
    selected_windows: std.ArrayList(SelectedWindow) = .empty,
    // Previous positions by steering row; a row without a movement body holds no entity.
    agent_snapshot_rows: std.MultiArrayList(AgentSnapshotRow) = .{},
    // The agent grid: entries sorted by (cell_y, cell_x, row), and per occupied cell its
    // entry range. Built in cell-key bands, each band's ranges in its own slice of
    // `agent_cell_ranges` (gaps between slices are unused); `agent_grid` finds a cell's band.
    // `grid_bucket` places each range's entries by band in its window of
    // `agent_cell_staging`, using its window of `agent_cell_entries` as scratch.
    agent_cell_entries: std.ArrayList(SpatialCellEntry) = .empty,
    agent_cell_ranges: std.ArrayList(SpatialCellRange) = .empty,
    agent_cell_staging: std.ArrayList(SpatialCellEntry) = .empty,
    agent_grid: AgentGridDirectory = .{},
    // Parallel to steering dense order: movement body dense index per steering row.
    // Rebuilt only when invalidated (structural create/destroy/component renumber),
    // not every cognition step — avoids per-agent slot resolve in the hot snapshot.
    steering_movement_index: std.ArrayList(usize) = .empty,
    steering_movement_index_valid: bool = false,
    spatial_cell_size: f32 = 64.0,
    // Per-range records, one padded slot per dispatched range of their stage.
    agents_tallies: SlotList(AgentsTally) = .empty,
    band_rows: SlotList(BandRow) = .empty,
    directions_tallies: SlotList(DirectionsTally) = .empty,
    movement_tallies: SlotList(MovementTally) = .empty,
    // One slot per band of `grid_sort`.
    grid_sort_tallies: SlotList(GridSortTally) = .empty,
    // One tuner per stage; `adaptive_tuner` drives the avoidance pass.
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),
    agents_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),
    select_resolve_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),
    select_claim_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(band_tuner_config),
    directions_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),
    grid_bucket_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(steering_adaptive_tuner_config),
    grid_sort_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(band_tuner_config),

    pub fn init(allocator: std.mem.Allocator) SteeringSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SteeringSystem) void {
        self.grid_sort_tallies.deinit(self.allocator);
        self.movement_tallies.deinit(self.allocator);
        self.directions_tallies.deinit(self.allocator);
        self.band_rows.deinit(self.allocator);
        self.agents_tallies.deinit(self.allocator);
        self.agent_cell_staging.deinit(self.allocator);
        self.agent_cell_ranges.deinit(self.allocator);
        self.agent_cell_entries.deinit(self.allocator);
        self.agent_snapshot_rows.deinit(self.allocator);
        self.steering_movement_index.deinit(self.allocator);
        self.selected_windows.deinit(self.allocator);
        self.selected_work_rows.deinit(self.allocator);
        self.selected.deinit(self.allocator);
        self.claims.deinit(self.allocator);
        self.intent_buckets.deinit(self.allocator);
        self.intent_rows.deinit(self.allocator);
        self.rekey_moves.deinit(self.allocator);
        self.rekey_positions.deinit(self.allocator);
        self.runtime_rows.deinit(self.allocator);
        self.* = undefined;
    }

    fn invalidateSteeringMovementIndexCache(self: *SteeringSystem) void {
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

    /// Pre-sizes every per-step buffer for `max_agents` steering rows and as many navigation
    /// intents, and each stage's per-range records for any partition of them, so a step
    /// within that population allocates nothing. Grow-only; re-run by the population seam.
    /// Steering rows and a step's navigation intents (AI cognition emits at most one per AI
    /// row) stay within `max_step_items` at any population, so their u32 indices never
    /// overflow.
    pub fn reserve(self: *SteeringSystem, max_agents: usize) !void {
        try ensureStepCapacity(self, max_agents, max_agents);
    }

    /// The last step's agent snapshot by steering row; a row without a movement body holds
    /// `EntityId.invalid`. Empty after a step with no navigation intents.
    pub fn agentSnapshotSliceConst(self: *const SteeringSystem) ConstAgentSnapshotSlice {
        const s = self.agent_snapshot_rows.slice();
        return .{
            .entity = s.items(.entity),
            .x = s.items(.x),
            .y = s.items(.y),
            .world_level = s.items(.world_level),
        };
    }

    /// One steering step. Every stage runs on `thread_system`'s workers as its tuner (or
    /// `config`) selects. Obstacle pushes read `colliders`' synced rows through a view taken
    /// once here.
    pub fn update(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        pathfinding: *const PathfindingSystem,
        colliders: *const StaticColliderSystem,
        config: SteeringConfig,
    ) !SteeringStats {
        return self.step(data, frame, .{ .thread_system = thread_system, .config = config }, pathfinding, colliders.view());
    }

    fn step(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        threads: StageThreads,
        pathfinding: *const PathfindingSystem,
        obstacles: ColliderView,
    ) !SteeringStats {
        const steering = data.steeringAgentSliceConst();
        const intents = frame.navigation_intents.mergedItems();
        // Unreachable in play (`max_step_items`); the error is the backstop where asserts
        // are compiled out.
        std.debug.assert(steering.entities.len <= max_step_items and intents.len <= max_step_items);
        if (steering.entities.len > max_step_items or intents.len > max_step_items) return error.Overflow;
        try ensureStepCapacity(self, steering.entities.len, intents.len);
        var stats = SteeringStats{ .navigation_intent_count = intents.len };

        var snapshot_timer = StageTimer.start();
        self.prepareAgents(data, steering, intents.len != 0, threads, &stats);
        stats.snapshot_ns = snapshot_timer.lap();
        if (intents.len == 0) return stats;

        var select_timer = StageTimer.start();
        selectIntents(self, data, steering.entities.len, intents, threads, &stats);
        stats.select_ns = select_timer.lap();

        var directions_timer = StageTimer.start();
        prepareDirections(self, data, steering, intents, pathfinding, threads, &stats);
        stats.directions_ns = directions_timer.lap();
        if (stats.selected_intent_count == 0) return stats;

        var grid_timer = StageTimer.start();
        buildAgentGrid(self, threads, &stats);
        stats.grid_ns = grid_timer.lap();

        try writeMovementIntents(self, frame, threads, obstacles, steering, &stats);
        return stats;
    }

    // The `agents` stage over every steering row, then on the main thread the cell size from
    // its tallies and the rekey of rows a commit moved.
    fn prepareAgents(
        self: *SteeringSystem,
        data: *const DataSystem,
        steering: ConstSteeringAgentSlice,
        build_snapshot: bool,
        threads: StageThreads,
        stats: *SteeringStats,
    ) void {
        const agent_count = steering.entities.len;
        const old_len = self.runtime_rows.len;
        // Added rows hold no entity, so `agents` reports them mismatched and the rekey
        // defaults them for their entity.
        while (self.runtime_rows.len < agent_count) self.runtime_rows.appendAssumeCapacity(.{ .entity = EntityId.invalid });
        self.resizeClaims(agent_count);
        const refresh_movement_index = !self.steering_movement_index_valid or self.steering_movement_index.items.len != agent_count;
        if (refresh_movement_index) {
            std.debug.assert(self.steering_movement_index.capacity >= agent_count);
            self.steering_movement_index.items.len = agent_count;
        }
        setRowCount(AgentSnapshotRow, &self.agent_snapshot_rows, if (build_snapshot) agent_count else 0);
        std.debug.assert(self.rekey_positions.capacity >= agent_count);
        self.rekey_positions.items.len = agent_count;

        const movement = data.movementBodySliceConst();
        const runtime = self.runtime_rows.slice();
        const snapshot = self.agent_snapshot_rows.slice();
        var job = AgentsJob{
            .data = data,
            .entities = steering.entities,
            .agent_radii = steering.agent_radii,
            .avoidance_radii = steering.avoidance_radii,
            .previous_x = movement.previous_x,
            .previous_y = movement.previous_y,
            .scope = data.scopeColumnsSliceConst(),
            .runtime_entity = runtime.items(.entity),
            .replan_cooldown = runtime.items(.replan_cooldown),
            .unavailable_backoff = runtime.items(.unavailable_backoff),
            .movement_index = self.steering_movement_index.items,
            .refresh_movement_index = refresh_movement_index,
            .build_snapshot = build_snapshot,
            .snapshot_entity = snapshot.items(.entity),
            .snapshot_x = snapshot.items(.x),
            .snapshot_y = snapshot.items(.y),
            .snapshot_level = snapshot.items(.world_level),
            .positions = self.rekey_positions.items,
            .items_per_range = agent_count,
            .tallies = &.{},
        };
        var range_count: usize = 0;
        if (agent_count != 0) {
            const agents = threads.stage(&self.agents_tuner);
            const selection = agents.select(agent_count, steering_range_alignment_items);
            setSlotCount(AgentsTally, &self.agents_tallies, selection.range_count);
            job.items_per_range = selection.items_per_range;
            job.tallies = self.agents_tallies.items;
            const agents_batch = agents.run(selection, agent_count, steering_range_alignment_items, &job, agentsJob);
            if (comptime runtime_perf_log.enabled) stats.perf.agents_batch = agents_batch;
            range_count = selection.range_count;
        }
        if (refresh_movement_index) self.steering_movement_index_valid = true;

        var largest_reach = min_spatial_cell_size;
        for (self.agents_tallies.items[0..range_count]) |slot| largest_reach = @max(largest_reach, slot.value.largest_reach);
        self.spatial_cell_size = largest_reach;
        self.rekeyRuntimeRows(data, steering.entities, old_len, range_count, job.items_per_range);
        self.advanceClaimStamp();
    }

    // Moves each runtime row whose entity now has another steering row to that row: the
    // `agents` windows in range order, then the rows past the steering count (ticked here,
    // as `agents` did not reach them). Every mismatched row first turns default for its
    // current entity; a row whose entity has no steering row is dropped. O(rows the commit
    // moved, added, or removed).
    fn rekeyRuntimeRows(self: *SteeringSystem, data: *const DataSystem, entities: []const EntityId, old_len: usize, range_count: usize, items_per_range: usize) void {
        const agent_count = entities.len;
        var rows = self.runtime_rows.slice();
        self.rekey_moves.clearRetainingCapacity();
        for (self.agents_tallies.items[0..range_count], 0..) |slot, range_index| {
            for (self.rekey_positions.items[range_index * items_per_range ..][0..slot.value.mismatches]) |row| {
                self.recordRekeyMove(data, rows, row, false);
            }
        }
        for (@min(agent_count, old_len)..old_len) |row| self.recordRekeyMove(data, rows, row, true);
        for (self.agents_tallies.items[0..range_count], 0..) |slot, range_index| {
            for (self.rekey_positions.items[range_index * items_per_range ..][0..slot.value.mismatches]) |row| {
                rows.set(row, .{ .entity = entities[row] });
            }
        }
        for (self.rekey_moves.items) |move| rows.set(move.target, move.row);
        self.runtime_rows.shrinkRetainingCapacity(agent_count);
    }

    fn recordRekeyMove(self: *SteeringSystem, data: *const DataSystem, rows: std.MultiArrayList(RuntimeRow).Slice, row: usize, tick: bool) void {
        var runtime = rows.get(row);
        if (!runtime.entity.isValid()) return;
        const target = data.steeringAgentDenseIndex(runtime.entity) orelse return;
        std.debug.assert(target != row and target < self.runtime_rows.len);
        if (tick) {
            runtime.replan_cooldown -|= 1;
            runtime.unavailable_backoff -|= 1;
        }
        // Targets are distinct steering rows, so the moves never pass the steering count.
        std.debug.assert(self.rekey_moves.items.len < self.rekey_moves.capacity);
        // Steering rows fit u32 (`max_step_items`).
        self.rekey_moves.appendAssumeCapacity(.{ .target = @intCast(target), .row = runtime });
    }

    fn resizeClaims(self: *SteeringSystem, agent_count: usize) void {
        if (agent_count < self.claims.len) self.claims.shrinkRetainingCapacity(agent_count);
        while (self.claims.len < agent_count) self.claims.appendAssumeCapacity(.{});
    }

    fn advanceClaimStamp(self: *SteeringSystem) void {
        if (self.claim_stamp == std.math.maxInt(u32)) {
            // A restarted stamp could equal a stale one: clear them once per 2^32 steps.
            @memset(self.claims.items(.stamp), 0);
            self.claim_stamp = 1;
            return;
        }
        self.claim_stamp += 1;
    }
};

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
        .request_prefix = s.items(.request_prefix),
        .emit_request = s.items(.emit_request),
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
        .request_prefix = s.items(.request_prefix),
        .emit_request = s.items(.emit_request),
    };
}

/// Grows every per-step buffer to `agent_count` steering rows and `intent_count`
/// navigation intents, and each stage's per-range records to the most ranges any
/// partition of those counts can have. Grow-only and before any mutation, so a failed
/// allocation leaves the system intact; within `reserve` it allocates nothing.
pub fn ensureStepCapacity(self: *SteeringSystem, agent_count: usize, intent_count: usize) !void {
    const allocator = self.allocator;
    try self.runtime_rows.ensureTotalCapacity(allocator, agent_count);
    try self.rekey_positions.ensureTotalCapacity(allocator, agent_count);
    try self.rekey_moves.ensureTotalCapacity(allocator, agent_count);
    try self.claims.ensureTotalCapacity(allocator, agent_count);
    try self.steering_movement_index.ensureTotalCapacity(allocator, agent_count);
    try self.agent_snapshot_rows.ensureTotalCapacity(allocator, hotStoreCapacity(agent_count));
    try self.agent_cell_entries.ensureTotalCapacity(allocator, agent_count);
    try self.agent_cell_ranges.ensureTotalCapacity(allocator, agent_count);
    try self.agent_cell_staging.ensureTotalCapacity(allocator, agent_count);
    const agent_ranges = maxRangeCount(agent_count, steering_range_alignment_items);
    try self.agents_tallies.ensureTotalCapacity(allocator, agent_ranges);
    try self.grid_sort_tallies.ensureTotalCapacity(allocator, max_bands);

    try self.intent_rows.ensureTotalCapacity(allocator, hotStoreCapacity(intent_count));
    try self.intent_buckets.ensureTotalCapacity(allocator, intent_count);
    try self.selected.ensureTotalCapacity(allocator, intent_count);
    try self.selected_work_rows.ensureTotalCapacity(allocator, hotStoreCapacity(intent_count));
    const intent_ranges = maxRangeCount(intent_count, steering_range_alignment_items);
    // `select_resolve` ranges, then `grid_bucket` ranges.
    try self.band_rows.ensureTotalCapacity(allocator, @max(intent_ranges, agent_ranges));
    try self.directions_tallies.ensureTotalCapacity(allocator, intent_ranges);
    try self.selected_windows.ensureTotalCapacity(allocator, intent_ranges);
    // The avoidance pass covers at most one selected intent per navigation intent.
    try self.movement_tallies.ensureTotalCapacity(allocator, intent_ranges);
}

pub const SelectedWorkRow = struct {
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
    /// Path requests emitted by the earlier selected intents of the same window.
    request_prefix: u32,
    emit_request: bool,
};

pub const AgentSnapshotRow = struct {
    entity: EntityId,
    x: f32,
    y: f32,
    world_level: u16,
};

pub const RuntimeRow = struct {
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
    // target direction by the direction tail instead of snapping to it.
    prev_dir_x: f32 = 0,
    prev_dir_y: f32 = 0,
    has_prev_dir: bool = false,
};

// A runtime row bound for the steering row its entity moved to.
const RekeyMove = struct {
    target: u32,
    row: RuntimeRow,
};

const SelectedList = std.array_list.Aligned(SelectedIntent, .fromByteUnits(thread_shared_record_alignment));
const RowList = std.array_list.Aligned(u32, .fromByteUnits(thread_shared_record_alignment));

const AgentsTally = struct {
    mismatches: usize = 0,
    // Largest avoidance plus agent radius in the range.
    largest_reach: f32 = min_spatial_cell_size,
};

/// Per-band start offsets of a `select_resolve` range's intents, or a `grid_bucket` range's
/// cell entries, within its window; entry `band_count` is the range's placed count.
pub const BandRow = struct {
    offsets: [max_bands + 1]u32 = @splat(0),
};

comptime {
    for ([_]type{ AgentsTally, BandRow }) |T| {
        std.debug.assert(@sizeOf(PaddedSlot(T)) % thread_shared_record_alignment == 0);
    }
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
    request_prefix: []u32,
    emit_request: []bool,

    pub fn len(self: SelectedWorkSlice) usize {
        return self.start_x.len;
    }
};

const ConstSelectedWorkSlice = struct {
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
    request_prefix: []const u32,
    emit_request: []const bool,

    fn len(self: ConstSelectedWorkSlice) usize {
        return self.start_x.len;
    }
};

pub const ConstAgentSnapshotSlice = struct {
    entity: []const EntityId,
    x: ConstHotF32Slice,
    y: ConstHotF32Slice,
    world_level: []const u16,

    pub fn len(self: ConstAgentSnapshotSlice) usize {
        return self.entity.len;
    }
};

// A steering row's best intent this step.
pub const SelectedIntent = struct {
    entity: EntityId,
    intent: NavigationIntent,
};

// `agents`: one range of steering rows.
const AgentsJob = struct {
    data: *const DataSystem,
    entities: []const EntityId,
    agent_radii: []const f32,
    avoidance_radii: []const f32,
    previous_x: []const f32,
    previous_y: []const f32,
    scope: ConstScopeColumnsSlice,
    runtime_entity: []const EntityId,
    replan_cooldown: []u16,
    unavailable_backoff: []u16,
    movement_index: []usize,
    refresh_movement_index: bool,
    build_snapshot: bool,
    snapshot_entity: []EntityId,
    snapshot_x: []f32,
    snapshot_y: []f32,
    snapshot_level: []u16,
    // Range r's window of mismatched rows starts at `r * items_per_range`.
    positions: []u32,
    items_per_range: usize,
    tallies: []PaddedSlot(AgentsTally),
};

// Refreshes the range's movement-index cache when stale, records rows whose runtime row
// holds another entity, writes the snapshot (previous position and level, or no entity
// without a body), ticks the fixed-step cooldowns, and tallies the largest reach. The
// cooldown ticks keep path request cadence deterministic under variable render timing.
fn agentsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AgentsJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.entities.len and range.end <= job.positions.len);
    std.debug.assert(range.end <= job.runtime_entity.len and range.end <= job.movement_index.len);
    std.debug.assert(!job.build_snapshot or range.end <= job.snapshot_x.len);
    var mismatches: usize = 0;
    for (range.start..range.end) |row| {
        const entity = job.entities[row];
        if (job.refresh_movement_index) job.movement_index[row] = job.data.movementBodyDenseIndex(entity) orelse invalid_index;
        if (!job.runtime_entity[row].eql(entity)) {
            // Steering rows fit u32 (`max_step_items`).
            job.positions[range.start + mismatches] = @intCast(row);
            mismatches += 1;
        }
        if (job.build_snapshot) {
            // Gather through the movement index: scattered, with a skip.
            const movement_index = job.movement_index[row];
            if (movement_index < job.previous_x.len) {
                job.snapshot_entity[row] = entity;
                job.snapshot_x[row] = job.previous_x[movement_index];
                job.snapshot_y[row] = job.previous_y[movement_index];
                // Same-level gate as collision: scope.level is kept in sync with
                // world_level (setWorldLevel / setMovementBody).
                job.snapshot_level[row] = movementScopeLevel(job.scope, movement_index);
            } else {
                job.snapshot_entity[row] = EntityId.invalid;
                job.snapshot_x[row] = 0;
                job.snapshot_y[row] = 0;
                job.snapshot_level[row] = 0;
            }
        }
    }
    simd.decrementSaturatingU16(job.replan_cooldown[range.start..range.end]);
    simd.decrementSaturatingU16(job.unavailable_backoff[range.start..range.end]);
    job.tallies[range.index].value = .{
        .mismatches = mismatches,
        .largest_reach = largestReach(job.avoidance_radii[range.start..range.end], job.agent_radii[range.start..range.end]),
    };
}

// The largest `avoidance + agent` radius, at least the minimum cell size: lanes, then a
// scalar tail. A maximum is order-free, so any range split gives the same cell size.
fn largestReach(avoidance_radii: []const f32, agent_radii: []const f32) f32 {
    std.debug.assert(avoidance_radii.len == agent_radii.len);
    var largest_lanes = simd.splatFloat4(min_spatial_cell_size);
    var index: usize = 0;
    const vector_end = simd.vectorizedEnd(avoidance_radii.len);
    while (index < vector_end) : (index += simd.lane_count) {
        largest_lanes = simd.maxFloat4(largest_lanes, simd.addFloat4(simd.loadFloat4(avoidance_radii[index..]), simd.loadFloat4(agent_radii[index..])));
    }
    var largest = min_spatial_cell_size;
    for (simd.toFloatArray(largest_lanes)) |lane| largest = @max(largest, lane);
    while (index < avoidance_radii.len) : (index += 1) largest = @max(largest, avoidance_radii[index] + agent_radii[index]);
    return largest;
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

const math = @import("../../../core/math.zig");
const MovementIntent = @import("../../simulation.zig").MovementIntent;
const PathRequest = @import("../../simulation.zig").PathRequest;
const AgentBands = @import("selection.zig").AgentBands;
const requestsBefore = @import("avoidance.zig").requestsBefore;
const expectEveryStageThreaded = @import("test_support.zig").expectEveryStageThreaded;
const updateSteeringInline = @import("test_support.zig").updateSteeringInline;
const updatePathfindingInline = @import("../pathfinding/test_support.zig").updatePathfindingInline;
const selectionIntent = @import("test_support.zig").selectionIntent;
const addSteeredEntity = @import("test_support.zig").addSteeredEntity;
const addStaticObstacle = @import("test_support.zig").addStaticObstacle;
const appendNavigationIntent = @import("test_support.zig").appendNavigationIntent;
const appendNavigationIntents = @import("test_support.zig").appendNavigationIntents;
const testColliders = @import("test_support.zig").testColliders;
const commitStaticsForTest = @import("test_support.zig").commitStaticsForTest;
const parity_statics = @import("test_support.zig").parity_statics;
const expectParityStaticsSpread = @import("test_support.zig").expectParityStaticsSpread;

fn expectAgentSnapshotColumnsAligned(rows: *const std.MultiArrayList(AgentSnapshotRow)) !void {
    const count = rows.len;
    const s = rows.slice();
    try std.testing.expectEqual(count, s.items(.entity).len);
    try std.testing.expectEqual(count, s.items(.x).len);
    try std.testing.expectEqual(count, s.items(.y).len);
    try std.testing.expectEqual(count, s.items(.world_level).len);
}

test "steering agent snapshot holds each steering row's previous position, and no entity without a body" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const bodiless = try data.createEntity();
    try data.setSteeringAgent(bodiless, .{ .agent_radius = 8, .waypoint_tolerance = 4, .avoidance_radius = 48, .avoidance_weight = 1.5, .max_neighbor_samples = 8, .stuck_step_threshold = 3, .replan_cooldown_steps = 4, .unavailable_backoff_steps = 12 });
    const second = try addSteeredEntity(&data, .{ .x = 32, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    // Never rebuilt: no rows.
    var colliders = StaticColliderSystem.init(std.testing.allocator);
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
        .{ .entity = first, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
        .{ .entity = bodiless, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
        .{ .entity = second, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
    });
    const stats = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    // The bodiless agent's intent resolves no movement row.
    try std.testing.expectEqual(@as(usize, 2), stats.selected_intent_count);

    try expectAgentSnapshotColumnsAligned(&steering.agent_snapshot_rows);
    const snapshot = steering.agentSnapshotSliceConst();
    try std.testing.expectEqual(@as(usize, 3), snapshot.len());
    for ([_]EntityId{ first, bodiless, second }, [_]math.Vec2{ .{}, .{}, .{ .x = 32, .y = 16 } }) |entity, position| {
        const row = data.steeringAgentDenseIndex(entity).?;
        const expected = if (entity.eql(bodiless)) EntityId.invalid else entity;
        try std.testing.expect(snapshot.entity[row].eql(expected));
        try std.testing.expectEqual(position, math.Vec2{ .x = snapshot.x[row], .y = snapshot.y[row] });
    }
}

test "steering movement index cache rebuilds only after structural invalidate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
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
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expect(steering.steering_movement_index_valid);
    try std.testing.expectEqual(@as(usize, 1), steering.steering_movement_index.items.len);
    const cached_mi = steering.steering_movement_index.items[0];
    try std.testing.expectEqual(data.movementBodyDenseIndex(agent).?, cached_mi);

    // Second step without structural events reuses the cache.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
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
    try pathfinding.reserve(.{ .max_group_fields = 4, .worker_participant_count = 1 });
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
    const serial_stats = try updateSteeringInline(&serial_system, &data, &serial_frame, &pathfinding, &colliders);
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
    try pathfinding.reserve(.{ .max_group_fields = 4, .worker_participant_count = 1 });
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
    _ = try updateSteeringInline(&serial_system, &data, &serial_frame, &pathfinding, &colliders);
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
    const other = try addSteeredEntity(&data, .{ .x = 24, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 32, .y = -12 }, .{ .x = 16, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
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

    const stats = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
    try std.testing.expect(stats.obstacle_samples > 0);

    // A churn step within the reserve: the first agent goes (its steering row takes the
    // last one's) and a new agent comes, so the rekey both moves and defaults rows.
    try std.testing.expect(data.destroyEntity(agent));
    const newcomer = try addSteeredEntity(&data, .{ .x = 64, .y = 0 });
    steering.invalidateSteeringMovementIndexCache();
    frame.beginStep();
    try appendNavigationIntents(&frame, &.{
        .{ .entity = newcomer, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
        .{ .entity = other, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
    });
    const churn = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 2), churn.movement_intent_count);
    try std.testing.expectEqual(@as(usize, 2), steering.runtime_rows.len);
}

test "steering threaded multi-worker update is allocation-free after reserves from the first step (FailingAllocator)" {
    if (!runtime_perf_log.enabled) return error.SkipZigTest;
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
        .max_group_fields = 1,
        .worker_participant_count = 1,
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

    // No warm-up step: a first-step allocation, or an in-place resize, means `reserve`
    // misses a term of the threaded partition.
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

    // One batched append: each appendNavigationIntent prepareRangeCounts-clears
    // the stream, so a per-agent loop would leave only the last intent and collapse
    // the batch to a single-range inline path.
    var step_intents: [agents.len]NavigationIntent = undefined;
    for (&step_intents, agents) |*slot, agent| {
        slot.* = .{ .entity = agent, .goal = .{ .x = 200, .y = 0 }, .direct_direction_x = 1 };
    }
    // The first step, then a steady one with the movement-index cache valid.
    for (0..2) |_| {
        frame.beginStep();
        try appendNavigationIntents(&frame, &step_intents);
        const stats = try steering.update(&data, &frame, &threads, &pathfinding, &colliders, cfg);
        try expectEveryStageThreaded(stats);
        try std.testing.expectEqual(agents.len, stats.movement_intent_count);
        try std.testing.expect(stats.obstacle_samples > 0);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }

    // A churn step within the reserve: one agent goes (its steering row takes the last
    // one's) and a new agent takes its place in the intents, so the rekey moves and
    // defaults rows.
    try std.testing.expect(data.destroyEntity(agents[5]));
    agents[5] = try addSteeredEntity(&data, .{ .x = 8, .y = 200 });
    step_intents[5].entity = agents[5];
    steering.invalidateSteeringMovementIndexCache();
    frame.beginStep();
    try appendNavigationIntents(&frame, &step_intents);
    const churn = try steering.update(&data, &frame, &threads, &pathfinding, &colliders, cfg);
    try expectEveryStageThreaded(churn);
    try std.testing.expectEqual(agents.len, churn.movement_intent_count);
    try std.testing.expectEqual(agents.len, steering.runtime_rows.len);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "steering runtime rows go with destroyed entities within a one-agent reserve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
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
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), steering.runtime_rows.len);

    try std.testing.expect(data.destroyEntity(agent));
    frame.beginStep();
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), steering.runtime_rows.len);
}

test "steering production stage tuners use the central gate and their stage's range alignment" {
    var system = SteeringSystem.init(std.testing.allocator);
    defer system.deinit();
    const agent_and_intent_tuners = [_]*const AdaptiveWorkTuner{ &system.adaptive_tuner, &system.agents_tuner, &system.select_resolve_tuner, &system.directions_tuner, &system.grid_bucket_tuner };
    for (agent_and_intent_tuners) |tuner| {
        try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, tuner.config.threaded_batch_ns);
        try std.testing.expectEqual(steering_range_alignment_items, tuner.config.initial_range_items);
        try std.testing.expectEqual(steering_range_alignment_items, tuner.config.smallest_range_items);
    }
    // The claim and the grid sort dispatch bands, one item each.
    for ([_]*const AdaptiveWorkTuner{ &system.select_claim_tuner, &system.grid_sort_tuner }) |tuner| {
        try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, tuner.config.threaded_batch_ns);
        try std.testing.expectEqual(@as(usize, 1), tuner.config.initial_range_items);
        try std.testing.expectEqual(@as(usize, 1), tuner.config.smallest_range_items);
    }
}

test "steering threaded prepare equals serial across range splits and worker counts" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var serial = ParityTrace{};
    defer serial.deinit();
    try runParityScenario(null, .{}, &serial);
    // The scenario covers requests, served paths, duplicate intents, and churn.
    try std.testing.expect(serial.requests.items.len > 0);
    try std.testing.expect(serial.stats.items[1].path_available_count > 0);
    for (serial.stats.items) |stats| try std.testing.expect(stats.selected_intent_count < stats.navigation_intent_count);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 3,
        .items_per_range = steering_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    for ([_]usize{ 16, 32, 48, 128 }) |items_per_range| {
        for ([_]usize{ 1, 2, 3 }) |workers| {
            var threaded = ParityTrace{};
            defer threaded.deinit();
            try runParityScenario(&threads, .{ .items_per_range = items_per_range, .max_worker_threads = workers, .adaptive = false }, &threaded);
            try expectTracesEqual(&serial, &threaded);
        }
    }
}

test "steering with no worker to give runs the serial selection and grid and matches serial" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var serial = ParityTrace{};
    defer serial.deinit();
    try runParityScenario(null, .{}, &serial);

    var no_workers = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer no_workers.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_workers.workerThreadCount());
    for ([_]SteeringConfig{ .{ .adaptive = true }, .{ .items_per_range = 32, .adaptive = false } }) |config| {
        var trace = ParityTrace{};
        defer trace.deinit();
        try runParityScenario(&no_workers, config, &trace);
        try expectTracesEqual(&serial, &trace);
    }

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var capped = ParityTrace{};
    defer capped.deinit();
    try runParityScenario(&threads, .{ .items_per_range = 32, .max_worker_threads = 0, .adaptive = false }, &capped);
    try expectTracesEqual(&serial, &capped);
}

test "steering runtime state follows its entity across swap-removes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    const threaded_config: SteeringConfig = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 2, .adaptive = false };
    for ([_]bool{ false, true }) |threaded| {
        if (threaded and threads.workerThreadCount() == 0) return error.SkipZigTest;
        const thread_system: ?*ThreadSystem = if (threaded) &threads else null;
        var control = RekeyOutcome{};
        defer control.deinit();
        try runRekeyScenario(thread_system, threaded_config, .none, &control);
        var churned = RekeyOutcome{};
        defer churned.deinit();
        try runRekeyScenario(thread_system, threaded_config, .destroy_and_create, &churned);

        // Surviving agents request exactly as without the churn (their cooldowns came
        // along, the row taken from past the steering count ticked once), then the new
        // agent from its fresh row.
        try std.testing.expect(control.requesters.items.len > 0);
        try std.testing.expectEqual(control.requesters.items.len + 1, churned.requesters.items.len);
        for (control.requesters.items, churned.requesters.items[0..control.requesters.items.len]) |expected, actual| {
            try std.testing.expect(expected.eql(actual));
        }
        try std.testing.expect(churned.requesters.items[control.requesters.items.len].eql(churned.newcomer));
        // Every surviving agent steers exactly as without the churn: its smoothing state
        // came along.
        var survivors: usize = 0;
        for (churned.movements.items) |movement| {
            if (movement.entity.eql(churned.newcomer)) {
                // A fresh row: the new direct direction as-is.
                try std.testing.expectApproxEqAbs(@as(f32, 1), movement.direction_y, 0.00001);
                continue;
            }
            const expected = for (control.movements.items) |candidate| {
                if (candidate.entity.eql(movement.entity)) break candidate;
            } else return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u32, @bitCast(expected.direction_x)), @as(u32, @bitCast(movement.direction_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(expected.direction_y)), @as(u32, @bitCast(movement.direction_y)));
            survivors += 1;
        }
        try std.testing.expectEqual(rekey_agent_count - 2, survivors);
    }
}

test "steering stages kept inline by their tuners run the threaded stage jobs inline" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var serial = ParityTrace{};
    defer serial.deinit();
    try runParityScenario(null, .{}, &serial);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    // Fresh adaptive tuners learn inline for a whole sample window, so every tuned stage
    // stays on the main thread for a scenario no longer than one window.
    try std.testing.expect(parity_step_count <= steering_adaptive_tuner_config.sample_window);
    try std.testing.expect(parity_step_count <= band_tuner_config.sample_window);
    var tuned = ParityTrace{};
    defer tuned.deinit();
    try runParityScenario(&threads, .{ .max_worker_threads = 3, .adaptive = true }, &tuned);
    try expectTracesEqual(&serial, &tuned);
}

// A step whose stage tuners all kept their stages inline still ran every stage job: the
// claim over its steering bands and the grid sort over every band.
fn expectTunedStagesInline(stats: SteeringStats, agent_count: usize) !void {
    for ([_]BatchStats{ stats.perf.agents_batch, stats.perf.select_resolve_batch, stats.perf.select_claim_batch, stats.perf.directions_batch, stats.perf.grid_bucket_batch, stats.perf.grid_sort_batch }) |batch| {
        try std.testing.expect(batch.ran_inline);
    }
    try std.testing.expectEqual(AgentBands.init(agent_count).band_count, stats.perf.select_claim_batch.item_count);
    try std.testing.expectEqual(max_bands, stats.perf.grid_sort_batch.item_count);
}

// A step that could give no stage a worker resolved and claimed in one pass and built the
// grid in one band, so neither the claim nor the grid sort ran.
fn expectSerialSelectionAndGrid(stats: SteeringStats) !void {
    try std.testing.expect(stats.perf.select_resolve_batch.ran_inline and stats.perf.grid_bucket_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), stats.perf.select_claim_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.perf.grid_sort_batch.item_count);
}

// A step's stats without batch shapes and timings, which follow the partition.
fn behaviorStats(stats: SteeringStats) SteeringStats {
    var behavior = stats;
    behavior.batch = .{};
    behavior.perf.agents_batch = .{};
    behavior.perf.select_resolve_batch = .{};
    behavior.perf.select_claim_batch = .{};
    behavior.perf.directions_batch = .{};
    behavior.perf.grid_bucket_batch = .{};
    behavior.perf.grid_sort_batch = .{};
    behavior.select_ns = 0;
    behavior.snapshot_ns = 0;
    behavior.directions_ns = 0;
    behavior.grid_ns = 0;
    return behavior;
}

// Every step's movement intents, path requests, stats, and runtime rows.
const ParityTrace = struct {
    movements: std.ArrayList(MovementIntent) = .empty,
    requests: std.ArrayList(PathRequest) = .empty,
    stats: std.ArrayList(SteeringStats) = .empty,
    runtime: std.ArrayList(RuntimeRow) = .empty,

    fn deinit(self: *ParityTrace) void {
        self.runtime.deinit(std.testing.allocator);
        self.stats.deinit(std.testing.allocator);
        self.requests.deinit(std.testing.allocator);
        self.movements.deinit(std.testing.allocator);
    }

    fn record(self: *ParityTrace, frame: *const SimulationFrame, stats: SteeringStats, system: *const SteeringSystem) !void {
        for (frame.intents.mergedItems()) |intent| try self.movements.append(std.testing.allocator, intent.movement);
        try self.requests.appendSlice(std.testing.allocator, frame.path_requests.mergedItems());
        try self.stats.append(std.testing.allocator, behaviorStats(stats));
        for (0..system.runtime_rows.len) |row| try self.runtime.append(std.testing.allocator, system.runtime_rows.get(row));
    }
};

fn expectTracesEqual(expected: *const ParityTrace, actual: *const ParityTrace) !void {
    try std.testing.expectEqual(expected.movements.items.len, actual.movements.items.len);
    for (expected.movements.items, actual.movements.items) |want, got| {
        try std.testing.expect(want.entity.eql(got.entity));
        try std.testing.expectEqual(@as(u32, @bitCast(want.direction_x)), @as(u32, @bitCast(got.direction_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(want.direction_y)), @as(u32, @bitCast(got.direction_y)));
    }
    try std.testing.expectEqualSlices(PathRequest, expected.requests.items, actual.requests.items);
    try std.testing.expectEqualSlices(SteeringStats, expected.stats.items, actual.stats.items);
    try std.testing.expectEqual(expected.runtime.items.len, actual.runtime.items.len);
    for (expected.runtime.items, actual.runtime.items) |want, got| try expectRuntimeRowsEqual(want, got);
}

// Runtime rows equal bit for bit.
fn expectRuntimeRowsEqual(want: RuntimeRow, got: RuntimeRow) !void {
    try std.testing.expect(want.entity.eql(got.entity));
    try std.testing.expectEqual(@as(u32, @bitCast(want.previous_progress_distance)), @as(u32, @bitCast(got.previous_progress_distance)));
    try std.testing.expectEqual(@as(u32, @bitCast(want.prev_dir_x)), @as(u32, @bitCast(got.prev_dir_x)));
    try std.testing.expectEqual(@as(u32, @bitCast(want.prev_dir_y)), @as(u32, @bitCast(got.prev_dir_y)));
    try std.testing.expectEqual(want.has_previous_distance, got.has_previous_distance);
    try std.testing.expectEqual(want.has_prev_dir, got.has_prev_dir);
    try std.testing.expectEqual(want.stuck_steps, got.stuck_steps);
    try std.testing.expectEqual(want.replan_cooldown, got.replan_cooldown);
    try std.testing.expectEqual(want.unavailable_backoff, got.unavailable_backoff);
    try std.testing.expectEqual(want.waypoint_hint, got.waypoint_hint);
}

// At every selected position, the request count the avoidance pass sizes its ranges from
// equals the flagged intents before it, walking the windows in selected order.
fn expectRequestPrefixesCount(system: *const SteeringSystem, stats: SteeringStats) !void {
    const work = selectedWorkSliceConst(system);
    const windows = system.selected_windows.items;
    var flagged: usize = 0;
    var logical: usize = 0;
    for (windows) |window| {
        try std.testing.expectEqual(logical, window.logical_base);
        for (window.start..window.start + window.count) |slot| {
            try std.testing.expectEqual(flagged, requestsBefore(windows, work.request_prefix, stats.selected_intent_count, stats.path_request_count, logical));
            flagged += @intFromBool(work.emit_request[slot]);
            logical += 1;
        }
    }
    try std.testing.expectEqual(stats.selected_intent_count, logical);
    try std.testing.expectEqual(stats.path_request_count, flagged);
    try std.testing.expectEqual(flagged, requestsBefore(windows, work.request_prefix, stats.selected_intent_count, stats.path_request_count, logical));
}

const parity_crowd_count: usize = 144;

// Agent `index` of a 12-wide grid 14 units apart, close enough to push each other.
fn parityAgentPosition(index: usize) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(index % 12)) * 14.0 + 8.0, .y = @as(f32, @floatFromInt(index / 12)) * 14.0 + 8.0 };
}

// Each agent's intent in agent order with priority by index and a goal kept across steps,
// an intent for a bodiless steering agent, then for every third agent a second intent
// ranges later, its goal moving each step, that beats, ties, or loses to its first; then
// intents for a body without steering and a destroyed entity, which select nothing.
fn buildParityIntents(intents: *std.ArrayList(NavigationIntent), agents: []const EntityId, bodiless: EntityId, bystander: EntityId, stale: EntityId, step_index: usize) !void {
    intents.clearRetainingCapacity();
    const step: f32 = @floatFromInt(step_index);
    for (agents, 0..) |agent, index| {
        const spread: f32 = @floatFromInt(index % 4);
        try intents.append(std.testing.allocator, .{
            .entity = agent,
            .goal = .{ .x = 400 + spread * 20, .y = 300 },
            .direct_direction_x = if (index % 2 == 0) 1 else -1,
            .direct_direction_y = if (index % 3 == 0) 0.25 else -0.15,
            .priority = @intCast(index % 3),
        });
    }
    try intents.append(std.testing.allocator, .{ .entity = bodiless, .goal = .{ .x = 100, .y = 100 }, .direct_direction_x = 1 });
    for (agents, 0..) |agent, index| {
        if (index % 3 != 0) continue;
        try intents.append(std.testing.allocator, .{
            .entity = agent,
            .goal = .{ .x = 60, .y = 420 - step * 10 },
            .direct_direction_x = 0.3,
            .direct_direction_y = 1,
            .priority = @intCast(index / 3 % 3),
        });
    }
    try intents.append(std.testing.allocator, .{ .entity = bystander, .goal = .{ .x = 100, .y = 100 }, .direct_direction_x = 1 });
    try intents.append(std.testing.allocator, .{ .entity = stale, .goal = .{ .x = 100, .y = 100 }, .direct_direction_x = 1 });
}

const parity_step_count: usize = 3;

// `parity_step_count` steering steps over the parity crowd among the parity statics, with agents
// destroyed and created between steps and each step's path requests served before the
// next. A fixed range size of one alignment unit asserts every stage threaded.
fn runParityScenario(thread_system: ?*ThreadSystem, config: SteeringConfig, trace: *ParityTrace) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var agents = std.ArrayList(EntityId).empty;
    defer agents.deinit(std.testing.allocator);
    for (0..parity_crowd_count) |index| try agents.append(std.testing.allocator, try addSteeredEntity(&data, parityAgentPosition(index)));
    const bodiless = try data.createEntity();
    try data.setSteeringAgent(bodiless, .{ .agent_radius = 8, .waypoint_tolerance = 4, .avoidance_radius = 48, .avoidance_weight = 1.5, .max_neighbor_samples = 8, .stuck_step_threshold = 3, .replan_cooldown_steps = 4, .unavailable_backoff_steps = 12 });
    const bystander = try data.createEntity();
    try data.setMovementBody(bystander, .{ .position = .{ .x = 30, .y = 30 }, .previous_position = .{ .x = 30, .y = 30 }, .velocity = .{}, .speed = 0 });
    for (parity_statics) |placement| _ = try addStaticObstacle(&data, placement[0], placement[1]);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 4, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(32, 0, 512, 0, 0, 0);
    try frame.reservePathRequests(32, 512);
    var system = SteeringSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(256);
    var intents = std.ArrayList(NavigationIntent).empty;
    defer intents.deinit(std.testing.allocator);

    var stale = EntityId.invalid;
    for (0..parity_step_count) |step_index| {
        if (step_index != 0) {
            // Destroys move the last steering rows into the holes; creates append rows.
            const removals: []const usize = if (step_index == 1) &.{ 40, 3 } else &.{0};
            for (removals) |index| {
                stale = agents.orderedRemove(index);
                try std.testing.expect(data.destroyEntity(stale));
            }
            try agents.append(std.testing.allocator, try addSteeredEntity(&data, parityAgentPosition(parity_crowd_count + step_index)));
            system.invalidateSteeringMovementIndexCache();
        }
        try buildParityIntents(&intents, agents.items, bodiless, bystander, stale, step_index);
        frame.beginStep();
        try appendNavigationIntents(&frame, intents.items);
        const stats = if (thread_system) |threads|
            try system.update(&data, &frame, threads, &pathfinding, &colliders, config)
        else
            try updateSteeringInline(&system, &data, &frame, &pathfinding, &colliders);
        if (thread_system) |threads| {
            if (comptime !runtime_perf_log.enabled) {
                // The prepare stages' batches are kept only with the perf log.
            } else if (threads.workerThreadCount() == 0 or (config.max_worker_threads orelse 1) == 0) {
                try expectSerialSelectionAndGrid(stats);
            } else if (config.items_per_range == steering_range_alignment_items) {
                try expectEveryStageThreaded(stats);
            } else if (config.adaptive and config.items_per_range == null) {
                try expectTunedStagesInline(stats, data.steeringAgentSliceConst().entities.len);
            }
        }
        try expectRequestPrefixesCount(&system, stats);
        try trace.record(&frame, stats, &system);
        _ = try updatePathfindingInline(&pathfinding, &frame.path_requests, agents.items.len, .{});
    }
}

const rekey_agent_count: usize = 40;

// How `runRekeyScenario` changes the agents between its steps.
const RekeyChurn = enum {
    none,
    // Two agents destroyed (the last two steering rows move into their rows, one of them
    // from past the new steering count) and one created.
    destroy_and_create,
};

// The second step's movement intents, path requesters, and runtime rows, and the agent
// the churn created.
const RekeyOutcome = struct {
    movements: std.ArrayList(MovementIntent) = .empty,
    requesters: std.ArrayList(EntityId) = .empty,
    runtime: std.ArrayList(RuntimeRow) = .empty,
    newcomer: EntityId = EntityId.invalid,

    fn deinit(self: *RekeyOutcome) void {
        self.runtime.deinit(std.testing.allocator);
        self.requesters.deinit(std.testing.allocator);
        self.movements.deinit(std.testing.allocator);
    }
};

// Two steps over agents far apart, each with its own replan cooldown (one step for every
// fifth agent, the last included, so those request again on the second step) and a
// first-step direction of its own, with `churn` between them; the second step turns
// every agent toward +y.
fn runRekeyScenario(thread_system: ?*ThreadSystem, config: SteeringConfig, churn: RekeyChurn, outcome: *RekeyOutcome) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var agents = std.ArrayList(EntityId).empty;
    defer agents.deinit(std.testing.allocator);
    for (0..rekey_agent_count) |index| {
        const agent = try addSteeredEntity(&data, .{ .x = @floatFromInt(index % 8 * 200 + 50), .y = @floatFromInt(index / 8 * 200 + 50) });
        try data.setSteeringAgent(agent, .{ .agent_radius = 8, .waypoint_tolerance = 4, .avoidance_radius = 48, .avoidance_weight = 1.5, .max_neighbor_samples = 8, .stuck_step_threshold = 3, .replan_cooldown_steps = @intCast(1 + (index + 1) % 5), .unavailable_backoff_steps = 12 });
        try agents.append(std.testing.allocator, agent);
    }
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    // Every path stays missing: no request is ever served.
    try pathfinding.rebuildStaticNavGrid(&data, 1700, 1100, 32);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(8, 0, 64, 0, 0, 0);
    try frame.reservePathRequests(8, 64);
    var system = SteeringSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(64);
    var intents = std.ArrayList(NavigationIntent).empty;
    defer intents.deinit(std.testing.allocator);

    for (agents.items, 0..) |agent, index| try intents.append(std.testing.allocator, selectionIntent(agent, index, 0, 0));
    frame.beginStep();
    try appendNavigationIntents(&frame, intents.items);
    const first = if (thread_system) |threads| try system.update(&data, &frame, threads, &pathfinding, &colliders, config) else try updateSteeringInline(&system, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(rekey_agent_count, first.path_request_count);

    switch (churn) {
        .none => {},
        .destroy_and_create => {
            for ([_]usize{ 10, 3 }) |index| try std.testing.expect(data.destroyEntity(agents.orderedRemove(index)));
            outcome.newcomer = try addSteeredEntity(&data, .{ .x = 1650, .y = 1050 });
            try agents.append(std.testing.allocator, outcome.newcomer);
            system.invalidateSteeringMovementIndexCache();
        },
    }
    intents.clearRetainingCapacity();
    for (agents.items) |agent| try intents.append(std.testing.allocator, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_y = 1 });
    frame.beginStep();
    try appendNavigationIntents(&frame, intents.items);
    const second = if (thread_system) |threads| try system.update(&data, &frame, threads, &pathfinding, &colliders, config) else try updateSteeringInline(&system, &data, &frame, &pathfinding, &colliders);
    if (comptime runtime_perf_log.enabled) if (thread_system != null) try expectEveryStageThreaded(second);
    // Each runtime row holds its steering row's entity.
    const steering_entities = data.steeringAgentSliceConst().entities;
    try std.testing.expectEqual(steering_entities.len, system.runtime_rows.len);
    for (steering_entities, system.runtime_rows.items(.entity)) |entity, runtime_entity| try std.testing.expect(entity.eql(runtime_entity));
    for (frame.intents.mergedItems()) |merged| try outcome.movements.append(std.testing.allocator, merged.movement);
    for (frame.path_requests.mergedItems()) |request| try outcome.requesters.append(std.testing.allocator, request.entity);
    for (0..system.runtime_rows.len) |row| try outcome.runtime.append(std.testing.allocator, system.runtime_rows.get(row));
}

fn setCollidersAllocator(colliders: *StaticColliderSystem, allocator: std.mem.Allocator) void {
    colliders.allocator = allocator;
    colliders.chunk_lists.allocator = allocator;
    colliders.query_lists.allocator = allocator;
}
