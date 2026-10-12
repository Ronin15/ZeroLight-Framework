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
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BandPartition = @import("../../app/thread_system.zig").BandPartition;
const BatchSelection = @import("../../app/thread_system.zig").BatchSelection;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const JobFn = @import("../../app/thread_system.zig").JobFn;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const band_tuner_config = @import("../../app/thread_system.zig").band_tuner_config;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const ConstScopeColumnsSlice = @import("../data_system.zig").ConstScopeColumnsSlice;
const ConstSteeringAgentSlice = @import("../data_system.zig").ConstSteeringAgentSlice;
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
// An intent with no steering row, or a claim field not yet written this step.
const no_row: u32 = std.math.maxInt(u32);
// The most steering rows or navigation intents one step can hold, so every row and intent
// index is a u32 below `no_row`. Steering rows stay within it by the steering store's u32
// row cap; navigation intents come one per AI cognition row, and AI rows and live entities
// stay within it by their stores' u32 caps (`createEntity` refuses past it).
const max_step_items: usize = std.math.maxInt(u32);
const min_spatial_cell_size: f32 = 1.0;
const max_agent_candidate_checks: u16 = 64;
// Per-agent obstacle query budgets: the query stops after this many static boxes meeting
// the query box (each a push candidate), or after `max_obstacle_work` probes and entry
// reads.
const max_obstacle_hits: u16 = 64;
const max_obstacle_work: u16 = 512;
const direction_epsilon: f32 = 0.0001;

// Partition width of the band stages, not a capacity: results are independent of the band
// count, and a range's band histogram stays on the worker stack.
const max_bands: usize = 64;
// Steering rows per claim block; a band owns whole blocks.
const band_block_rows: usize = steering_range_alignment_items;

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
    /// The avoidance pass.
    batch: BatchStats = .{},
    agents_batch: BatchStats = .{},
    select_resolve_batch: BatchStats = .{},
    /// Zero items on the serial path, where selection runs its single pass.
    select_claim_batch: BatchStats = .{},
    directions_batch: BatchStats = .{},
    grid_bucket_batch: BatchStats = .{},
    /// Zero items on the serial path, where the grid runs its single sort.
    grid_sort_batch: BatchStats = .{},
    // Wall time (ns) of the prepare stages, inline or dispatched: selection, the agents stage
    // with its rekey and the agent grid, and directions; zero when perf logging is disabled.
    select_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    directions_ns: u64 = 0,
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

    /// Pre-sizes every per-step buffer for `max_agents` steering rows and as many navigation
    /// intents, and each stage's per-range records for any partition of them, so a step
    /// within that population allocates nothing. Grow-only; re-run by the population seam.
    /// Steering rows and a step's navigation intents (AI cognition emits at most one per AI
    /// row) stay within `max_step_items` at any population, so their u32 indices never
    /// overflow.
    pub fn reserve(self: *SteeringSystem, max_agents: usize) !void {
        try self.ensureStepCapacity(max_agents, max_agents);
    }

    fn selectedWorkSlice(self: *SteeringSystem) SelectedWorkSlice {
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

    fn selectedWorkSliceConst(self: *const SteeringSystem) ConstSelectedWorkSlice {
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

    /// One steering step with every stage inline on the calling thread.
    pub fn updateSerial(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        pathfinding: *const PathfindingSystem,
        colliders: *const StaticColliderSystem,
    ) !SteeringStats {
        return self.step(data, frame, null, pathfinding, colliders.view());
    }

    fn step(
        self: *SteeringSystem,
        data: *const DataSystem,
        frame: *SimulationFrame,
        threads: ?StageThreads,
        pathfinding: *const PathfindingSystem,
        obstacles: ColliderView,
    ) !SteeringStats {
        const steering = data.steeringAgentSliceConst();
        const intents = frame.navigation_intents.mergedItems();
        // Unreachable in play (`max_step_items`); the error is the backstop where asserts
        // are compiled out.
        std.debug.assert(steering.entities.len <= max_step_items and intents.len <= max_step_items);
        if (steering.entities.len > max_step_items or intents.len > max_step_items) return error.Overflow;
        try self.ensureStepCapacity(steering.entities.len, intents.len);
        var stats = SteeringStats{ .navigation_intent_count = intents.len };

        var snapshot_timer = StageTimer.start();
        self.prepareAgents(data, steering, intents.len != 0, threads, &stats);
        stats.snapshot_ns = snapshot_timer.lap();
        if (intents.len == 0) return stats;

        var select_timer = StageTimer.start();
        self.selectIntents(data, steering.entities.len, intents, threads, &stats);
        stats.select_ns = select_timer.lap();

        var directions_timer = StageTimer.start();
        self.prepareDirections(data, steering, intents, pathfinding, threads, &stats);
        stats.directions_ns = directions_timer.lap();
        if (stats.selected_intent_count == 0) return stats;

        var grid_timer = StageTimer.start();
        self.buildAgentGrid(threads, &stats);
        stats.snapshot_ns += grid_timer.lap();

        try self.writeMovementIntents(frame, threads, obstacles, steering, &stats);
        return stats;
    }

    // Grows every per-step buffer to `agent_count` steering rows and `intent_count`
    // navigation intents, and each stage's per-range records to the most ranges any
    // partition of those counts can have. Grow-only and before any mutation, so a failed
    // allocation leaves the system intact; within `reserve` it allocates nothing.
    fn ensureStepCapacity(self: *SteeringSystem, agent_count: usize, intent_count: usize) !void {
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

    // The `agents` stage over every steering row, then on the main thread the cell size from
    // its tallies and the rekey of rows a commit moved.
    fn prepareAgents(
        self: *SteeringSystem,
        data: *const DataSystem,
        steering: ConstSteeringAgentSlice,
        build_snapshot: bool,
        threads: ?StageThreads,
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
            if (threads) |stage| {
                const selection = stage.select(&self.agents_tuner, agent_count, steering_range_alignment_items, null);
                setSlotCount(AgentsTally, &self.agents_tallies, selection.range_count);
                job.items_per_range = selection.items_per_range;
                job.tallies = self.agents_tallies.items;
                stats.agents_batch = stage.dispatch(agent_count, &job, agentsJob, selection, steering_range_alignment_items);
                range_count = selection.range_count;
            } else {
                setSlotCount(AgentsTally, &self.agents_tallies, 1);
                job.tallies = self.agents_tallies.items;
                agentsJob(&job, .{ .index = 0, .start = 0, .end = agent_count }, WorkerId.main);
                stats.agents_batch = inlineBatch(agent_count, steering_range_alignment_items);
                range_count = 1;
            }
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

    // `select_resolve`, then `select_claim`. Serial (also when no stage can get a worker),
    // one source-order pass resolves and claims each intent. Threaded, each stage runs inline or on workers as its tuner
    // selects: ranges resolve their intents and place them by steering band in their window;
    // then each band claims, for the steering rows it owns, every range's band segment in
    // range order. The bands follow the steering rows only, never the resolve partition.
    // Either way each steering row gets its first intent in source order and its best by
    // priority, ties to the earlier.
    fn selectIntents(
        self: *SteeringSystem,
        data: *const DataSystem,
        agent_count: usize,
        intents: []const NavigationIntent,
        threads: ?StageThreads,
        stats: *SteeringStats,
    ) void {
        const intent_count = intents.len;
        setRowCount(IntentRow, &self.intent_rows, intent_count);
        const intent_rows = self.intent_rows.slice();
        const claims = claimColumns(self.claims.slice());
        const stage = stageWithWorkers(threads) orelse {
            resolveAndClaim(data, intents, 0, intent_count, intent_rows.items(.steering), intent_rows.items(.movement), claims, self.claim_stamp);
            stats.select_resolve_batch = inlineBatch(intent_count, steering_range_alignment_items);
            return;
        };
        const selection = stage.select(&self.select_resolve_tuner, intent_count, steering_range_alignment_items, null);
        const bands = AgentBands.init(agent_count);
        setSlotCount(BandRow, &self.band_rows, selection.range_count);
        std.debug.assert(self.intent_buckets.capacity >= intent_count);
        self.intent_buckets.items.len = intent_count;
        var resolve = ResolveJob{
            .data = data,
            .intents = intents,
            .intent_steering = intent_rows.items(.steering),
            .intent_movement = intent_rows.items(.movement),
            .buckets = self.intent_buckets.items,
            .bands = bands,
            .items_per_range = selection.items_per_range,
            .band_rows = self.band_rows.items,
        };
        stats.select_resolve_batch = stage.dispatch(intent_count, &resolve, resolveJob, selection, steering_range_alignment_items);

        // A fixed shape (an explicit range size) claims one band per range.
        const claim_selection = stage.select(&self.select_claim_tuner, bands.band_count, 1, if (stage.config.items_per_range != null) 1 else null);
        var claim = ClaimJob{
            .intents = intents,
            .intent_steering = intent_rows.items(.steering),
            .buckets = self.intent_buckets.items,
            .band_rows = self.band_rows.items,
            .resolve_items_per_range = selection.items_per_range,
            .bands = bands,
            .claims = claims,
            .stamp = self.claim_stamp,
            .range_count = claim_selection.range_count,
        };
        stats.select_claim_batch = stage.dispatch(bands.band_count, &claim, claimJob, claim_selection, 1);
    }

    // `directions` over the intents: each intent that is its steering row's first this step
    // emits the row's best intent into its range's window, then the main thread lays the
    // windows out in range order.
    fn prepareDirections(
        self: *SteeringSystem,
        data: *const DataSystem,
        steering: ConstSteeringAgentSlice,
        intents: []const NavigationIntent,
        pathfinding: *const PathfindingSystem,
        threads: ?StageThreads,
        stats: *SteeringStats,
    ) void {
        const intent_count = intents.len;
        std.debug.assert(self.selected.capacity >= intent_count);
        self.selected.items.len = intent_count;
        setRowCount(SelectedWorkRow, &self.selected_work_rows, intent_count);
        const movement = data.movementBodySliceConst();
        const intent_rows = self.intent_rows.slice();
        const claims = self.claims.slice();
        var job = DirectionsJob{
            .pathfinding = pathfinding,
            .intents = intents,
            .intent_steering = intent_rows.items(.steering),
            .intent_movement = intent_rows.items(.movement),
            .claim_stamps = claims.items(.stamp),
            .claim_first = claims.items(.first),
            .claim_best = claims.items(.best),
            .stamp = self.claim_stamp,
            .steering = steering,
            .previous_x = movement.previous_x,
            .previous_y = movement.previous_y,
            .scope = data.scopeColumnsSliceConst(),
            .runtime = self.runtime_rows.slice(),
            .selected = self.selected.items,
            .work = self.selectedWorkSlice(),
            .items_per_range = intent_count,
            .tallies = &.{},
        };
        var range_count: usize = 1;
        if (threads) |stage| {
            const selection = stage.select(&self.directions_tuner, intent_count, steering_range_alignment_items, null);
            setSlotCount(DirectionsTally, &self.directions_tallies, selection.range_count);
            job.items_per_range = selection.items_per_range;
            job.tallies = self.directions_tallies.items;
            stats.directions_batch = stage.dispatch(intent_count, &job, directionsJob, selection, steering_range_alignment_items);
            range_count = selection.range_count;
        } else {
            setSlotCount(DirectionsTally, &self.directions_tallies, 1);
            job.tallies = self.directions_tallies.items;
            directionsJob(&job, .{ .index = 0, .start = 0, .end = intent_count }, WorkerId.main);
            stats.directions_batch = inlineBatch(intent_count, steering_range_alignment_items);
        }

        self.selected_windows.clearRetainingCapacity();
        std.debug.assert(self.selected_windows.capacity >= range_count);
        var selected_count: usize = 0;
        var request_count: usize = 0;
        for (self.directions_tallies.items[0..range_count], 0..) |slot, range_index| {
            const tally = slot.value;
            self.selected_windows.appendAssumeCapacity(.{
                .start = range_index * job.items_per_range,
                .count = tally.count,
                .logical_base = selected_count,
                .request_base = request_count,
            });
            selected_count += tally.count;
            request_count += tally.requests;
            stats.path_available_count += tally.available;
            stats.path_pending_count += tally.pending;
            stats.path_unavailable_count += tally.unavailable;
            stats.replan_cooldown_count += tally.cooldowns;
            stats.unavailable_backoff_count += tally.backoffs;
            stats.stuck_replan_count += tally.stuck_replans;
        }
        stats.selected_intent_count = selected_count;
        stats.path_request_count = request_count;
    }

    // The agent grid over the snapshot's rows with a body: entries sorted by (cell_y, cell_x,
    // row) and one range per occupied cell. Serial (also when no stage can get a worker), one
    // fill and one sort in a single band. Threaded, the main thread samples the band splitters, `grid_bucket` places each range's
    // entries by band in its window, then `grid_sort` gathers, sorts, and splits each band in
    // its own slice; each stage runs inline or on workers as its tuner selects. A cell lies in
    // one band and the bands follow cell order, so every cell holds the same entries in the
    // same order for any splitters and partition.
    fn buildAgentGrid(self: *SteeringSystem, threads: ?StageThreads, stats: *SteeringStats) void {
        const stage = stageWithWorkers(threads) orelse {
            self.buildAgentGridDirect();
            stats.grid_bucket_batch = inlineBatch(self.agent_snapshot_rows.len, steering_range_alignment_items);
            return;
        };
        const splitters = chooseGridSplitters(self.agentSnapshotSliceConst(), self.spatial_cell_size);
        const selection = stage.select(&self.grid_bucket_tuner, self.agent_snapshot_rows.len, steering_range_alignment_items, null);
        self.buildAgentGridBanded(stage, selection, splitters, stats);
    }

    // The serial grid: one fill and one sort, every cell range in the directory's one band.
    fn buildAgentGridDirect(self: *SteeringSystem) void {
        const agent_count = self.agent_snapshot_rows.len;
        std.debug.assert(self.agent_cell_entries.capacity >= agent_count and self.agent_cell_ranges.capacity >= agent_count);
        self.agent_cell_entries.items.len = agent_count;
        self.agent_cell_ranges.items.len = agent_count;
        self.agent_cell_entries.items.len = fillCellEntries(self.agentSnapshotSliceConst(), self.spatial_cell_size, 0, agent_count, self.agent_cell_entries.items);
        const range_count = sortCellEntries(self.agent_cell_entries.items, self.agent_cell_ranges.items, 0);
        self.agent_cell_ranges.items.len = range_count;
        self.agent_grid = .{};
        self.agent_grid.bands[0] = .{ .start = 0, .range_count = range_count };
    }

    // `grid_bucket` over the snapshot rows in `selection`'s ranges into the `max_bands` bands
    // of `splitters` (nondecreasing), then `grid_sort` over the bands; the main thread lays
    // out the band slices and the band directory.
    fn buildAgentGridBanded(self: *SteeringSystem, stage: StageThreads, selection: BatchSelection, splitters: [max_bands - 1]CellKey, stats: *SteeringStats) void {
        const agent_count = self.agent_snapshot_rows.len;
        for (splitters[0 .. max_bands - 2], splitters[1..]) |lower, upper| std.debug.assert(!cellKeyLessThan(upper, lower));
        std.debug.assert(self.agent_cell_entries.capacity >= agent_count and self.agent_cell_ranges.capacity >= agent_count);
        std.debug.assert(self.agent_cell_staging.capacity >= agent_count);
        self.agent_cell_entries.items.len = agent_count;
        self.agent_cell_ranges.items.len = agent_count;
        self.agent_cell_staging.items.len = agent_count;
        setSlotCount(BandRow, &self.band_rows, selection.range_count);
        self.agent_grid = .{ .splitters = splitters, .splitter_count = max_bands - 1 };
        var bucket = BucketJob{
            .agents = self.agentSnapshotSliceConst(),
            .cell_size = self.spatial_cell_size,
            .grid = &self.agent_grid,
            .scratch = self.agent_cell_entries.items,
            .staging = self.agent_cell_staging.items,
            .items_per_range = selection.items_per_range,
            .band_rows = self.band_rows.items,
        };
        stats.grid_bucket_batch = stage.dispatch(agent_count, &bucket, bucketJob, selection, steering_range_alignment_items);

        // Each band's slice starts after every range's entries of the earlier bands.
        var band_start: [max_bands + 1]usize = @splat(0);
        for (self.band_rows.items) |slot| {
            for (&band_start, slot.value.offsets) |*start, range_offset| start.* += range_offset;
        }

        // A fixed shape (an explicit range size) sorts one band per range.
        const sort_selection = stage.select(&self.grid_sort_tuner, max_bands, 1, if (stage.config.items_per_range != null) 1 else null);
        setSlotCount(GridSortTally, &self.grid_sort_tallies, max_bands);
        var sort = SortJob{
            .staging = self.agent_cell_staging.items,
            .band_rows = self.band_rows.items,
            .bucket_items_per_range = selection.items_per_range,
            .band_start = band_start,
            .entries = self.agent_cell_entries.items,
            .ranges = self.agent_cell_ranges.items,
            .tallies = self.grid_sort_tallies.items,
            .range_count = sort_selection.range_count,
        };
        stats.grid_sort_batch = stage.dispatch(max_bands, &sort, sortJob, sort_selection, 1);

        self.agent_cell_entries.items.len = band_start[max_bands];
        for (&self.agent_grid.bands, self.grid_sort_tallies.items, band_start[0..max_bands]) |*band, slot, band_entry_start| {
            band.* = .{ .start = band_entry_start, .range_count = slot.value.range_count };
        }
    }

    // The avoidance pass over the selected intents in selected order: each range writes its
    // movement intents and the path requests its intents flagged, one range of each stream
    // per pass range, sized before dispatch from the directions' request prefixes. Both
    // streams therefore merge in selected order.
    fn writeMovementIntents(
        self: *SteeringSystem,
        frame: *SimulationFrame,
        threads: ?StageThreads,
        obstacles: ColliderView,
        steering: ConstSteeringAgentSlice,
        stats: *SteeringStats,
    ) !void {
        const count = stats.selected_intent_count;
        const selection: BatchSelection = if (threads) |stage|
            selectSteeringWork(stage.thread_system, count, stage.config, self)
        else
            .{ .profile = .{ .worker_threads = 0, .items_per_range = count }, .items_per_range = count, .worker_threads = 0, .range_count = 1 };
        const range_count = selection.range_count;
        const work = self.selectedWorkSliceConst();
        const intent_base = try frame.intents.appendRangeCounts(range_count);
        const request_base = try frame.path_requests.appendRangeCounts(range_count);
        for (0..range_count) |range_index| {
            const start = range_index * selection.items_per_range;
            const end = @min(start + selection.items_per_range, count);
            frame.intents.addCount(intent_base + range_index, end - start);
            const requests = requestsBefore(self.selected_windows.items, work.request_prefix, count, stats.path_request_count, end) -
                requestsBefore(self.selected_windows.items, work.request_prefix, count, stats.path_request_count, start);
            frame.path_requests.addCount(request_base + range_index, requests);
        }
        try frame.intents.prefixAppendedRanges(intent_base);
        try frame.path_requests.prefixAppendedRanges(request_base);
        setSlotCount(MovementTally, &self.movement_tallies, range_count);

        var context = SteeringJobContext{
            .windows = self.selected_windows.items,
            .selected = self.selected.items,
            .work = self.selectedWorkSlice(),
            .agents = self.agentSnapshotSliceConst(),
            .agent_radii = steering.agent_radii,
            .obstacles = obstacles,
            .agent_cell_entries = self.agent_cell_entries.items,
            .agent_cell_ranges = self.agent_cell_ranges.items,
            .agent_grid = &self.agent_grid,
            .spatial_cell_size = self.spatial_cell_size,
            .intents = &frame.intents,
            .requests = &frame.path_requests,
            .intent_range_base = intent_base,
            .request_range_base = request_base,
            .selected_count = count,
            .tallies = self.movement_tallies.items,
            .range_count = range_count,
        };
        if (threads) |stage| {
            stats.batch = stage.thread_system.parallelForWithOptions(count, &context, writeSteeringMovementJob, .{
                .items_per_range = selection.items_per_range,
                .max_worker_threads = selection.worker_threads,
                .range_alignment_items = steering_range_alignment_items,
                .adaptive_tuner = selection.active_tuner,
                .selected_profile = selection.profile,
            });
        } else {
            writeSteeringMovementJob(&context, .{ .index = 0, .start = 0, .end = count }, WorkerId.main);
            stats.batch = inlineBatch(count, steering_range_alignment_items);
        }
        frame.intents.finishWrite();
        frame.path_requests.finishWrite();

        for (self.movement_tallies.items) |slot| {
            stats.agent_neighbor_samples += slot.value.agent_samples;
            stats.obstacle_samples += slot.value.obstacle_samples;
            stats.agent_candidate_checks += slot.value.agent_checks;
            stats.obstacle_candidate_checks += slot.value.obstacle_checks;
        }
        stats.movement_intent_count = count;
    }
};

// Threading for one update's stages: the thread system and the caller's control config.
// Absent in `updateSerial`, where every stage runs inline.
const StageThreads = struct {
    thread_system: *ThreadSystem,
    config: SteeringConfig,

    // Pre-selects the batch shape so a job can assert its range against the dispatched
    // range count. The stage's own tuner drives an adaptive config with no fixed range size;
    // `fixed_items_per_range` replaces the config's range size for a stage whose items are
    // not agents or intents.
    fn select(self: StageThreads, owned_tuner: *AdaptiveWorkTuner, item_count: usize, range_alignment_items: usize, fixed_items_per_range: ?usize) BatchSelection {
        const items_per_range = fixed_items_per_range orelse self.config.items_per_range;
        const tuner: ?*AdaptiveWorkTuner = if (self.config.adaptive and items_per_range == null) owned_tuner else null;
        return self.thread_system.selectBatchProfile(tuner, .{
            .item_count = item_count,
            .items_per_range = items_per_range,
            .max_worker_threads = self.config.max_worker_threads,
            .range_alignment_items = range_alignment_items,
            .adaptive = self.config.adaptive,
        });
    }

    // False when the thread system has no workers or the config allows none, so every stage
    // runs inline whatever its tuner learns.
    fn mayUseWorkers(self: StageThreads) bool {
        const workers = self.thread_system.workerThreadCount();
        return @min(self.config.max_worker_threads orelse workers, workers) > 0;
    }

    fn dispatch(self: StageThreads, item_count: usize, context: *anyopaque, job: JobFn, selection: BatchSelection, range_alignment_items: usize) BatchStats {
        return self.thread_system.parallelForWithOptions(item_count, context, job, .{
            .items_per_range = selection.items_per_range,
            .max_worker_threads = self.config.max_worker_threads,
            .range_alignment_items = range_alignment_items,
            .adaptive = self.config.adaptive,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
    }
};

// `threads` when a stage there can get a worker, else null: the two-stage selection and
// grid would only add main-thread passes over the serial ones.
fn stageWithWorkers(threads: ?StageThreads) ?StageThreads {
    const stage = threads orelse return null;
    return if (stage.mayUseWorkers()) stage else null;
}

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
    /// Path requests emitted by the earlier selected intents of the same window.
    request_prefix: u32,
    emit_request: bool,
};

const AgentSnapshotRow = struct {
    entity: EntityId,
    x: f32,
    y: f32,
    world_level: u16,
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

// An intent's dense indices; `no_row` when its entity is not a steering agent with a body.
const IntentRow = struct {
    steering: u32 = no_row,
    movement: u32 = no_row,
};

// A steering row's first intent this step (source order) and its best (priority, ties to
// the earlier), valid while `stamp` equals the system's `claim_stamp`.
const Claim = struct {
    stamp: u32 = 0,
    first: u32 = 0,
    best: u32 = 0,
};

const ClaimColumns = struct {
    stamp: []u32,
    first: []u32,
    best: []u32,
};

fn claimColumns(claims: std.MultiArrayList(Claim).Slice) ClaimColumns {
    return .{ .stamp = claims.items(.stamp), .first = claims.items(.first), .best = claims.items(.best) };
}

// One directions range's selected intents: `count` from `start` in `selected`, at selected
// positions from `logical_base`, after `request_base` earlier path requests.
const SelectedWindow = struct {
    start: usize,
    count: usize,
    logical_base: usize,
    request_base: usize,
};

const SelectedList = std.ArrayListAligned(SelectedIntent, .fromByteUnits(thread_shared_record_alignment));
const RowList = std.ArrayListAligned(u32, .fromByteUnits(thread_shared_record_alignment));

const AgentsTally = struct {
    mismatches: usize = 0,
    // Largest avoidance plus agent radius in the range.
    largest_reach: f32 = min_spatial_cell_size,
};

// Per-band start offsets of a `select_resolve` range's intents, or a `grid_bucket` range's
// cell entries, within its window; entry `band_count` is the range's placed count.
const BandRow = struct {
    offsets: [max_bands + 1]u32 = @splat(0),
};

const DirectionsTally = struct {
    count: usize = 0,
    requests: usize = 0,
    available: usize = 0,
    pending: usize = 0,
    unavailable: usize = 0,
    cooldowns: usize = 0,
    backoffs: usize = 0,
    stuck_replans: usize = 0,
};

const MovementTally = struct {
    agent_samples: usize = 0,
    obstacle_samples: usize = 0,
    agent_checks: usize = 0,
    obstacle_checks: usize = 0,
};

const GridSortTally = struct {
    range_count: usize = 0,
};

comptime {
    for ([_]type{ AgentsTally, BandRow, DirectionsTally, MovementTally, GridSortTally }) |T| {
        std.debug.assert(@sizeOf(PaddedSlot(T)) % thread_shared_record_alignment == 0);
    }
}

// The partition of steering rows into bands of whole `band_block_rows` blocks.
const AgentBands = BandPartition(band_block_rows, max_bands);

// A spatial cell, ordered by (cell_y, cell_x).
const CellKey = struct {
    cell_y: i32,
    cell_x: i32,
};

fn cellKeyLessThan(lhs: CellKey, rhs: CellKey) bool {
    return cellLessThan(lhs.cell_x, lhs.cell_y, rhs.cell_x, rhs.cell_y);
}

// The largest cell key; splitters at it leave the bands after them empty.
const max_cell_key = CellKey{ .cell_y = std.math.maxInt(i32), .cell_x = std.math.maxInt(i32) };
// Snapshot rows sampled per step for the grid's band splitters: four per band, a fixed
// count. Balance only; the grid is the same for any splitters.
const grid_sample_count: usize = 4 * max_bands;
// The golden ratio's fractional part in 0.64 fixed point.
const grid_sample_fraction_step: u64 = 0x9E3779B97F4A7C15;

// One band's cell ranges: `range_count` from `start` in `agent_cell_ranges`.
const CellBand = struct {
    start: usize = 0,
    range_count: usize = 0,
};

// Which band holds a cell, and where each band's cell ranges are. A cell's band is the
// count of splitters at or below it; the splitters are nondecreasing, so the bands follow
// cell order and every cell lies in exactly one. Without splitters there is one band.
const AgentGridDirectory = struct {
    splitters: [max_bands - 1]CellKey = @splat(max_cell_key),
    // 0 for the serial grid's one band, else `max_bands - 1`.
    splitter_count: usize = 0,
    bands: [max_bands]CellBand = @splat(.{}),

    // Upper-bound binary search over the splitters.
    fn bandOfCell(self: *const AgentGridDirectory, cell_x: i32, cell_y: i32) usize {
        const cell = CellKey{ .cell_y = cell_y, .cell_x = cell_x };
        var low: usize = 0;
        var high: usize = self.splitter_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (cellKeyLessThan(cell, self.splitters[mid])) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    // The cell ranges of the band holding the cell, sorted by (cell_y, cell_x).
    fn rangesOfCell(self: *const AgentGridDirectory, ranges: []const SpatialCellRange, cell_x: i32, cell_y: i32) []const SpatialCellRange {
        const band = self.bands[self.bandOfCell(cell_x, cell_y)];
        return ranges[band.start..][0..band.range_count];
    }
};

const SelectedWorkSlice = struct {
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

    fn len(self: SelectedWorkSlice) usize {
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
const SelectedIntent = struct {
    entity: EntityId,
    intent: NavigationIntent,
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

fn resolveIntentRow(data: *const DataSystem, intent: NavigationIntent) IntentRow {
    // One slot resolve for both dense indices (not movement + steering separately).
    const indices = data.movementSteeringDenseIndices(intent.entity) orelse return .{};
    // Dense indices fit u32: steering rows by `max_step_items`, movement rows by their
    // store's u32 row cap.
    return .{ .steering = @intCast(indices.steering), .movement = @intCast(indices.movement) };
}

// Claims steering row `row` for intent `intent_index`: the row's first claim this step takes
// both first and best; a later one replaces best only at a higher priority, so ties keep
// the earlier source order. Claims of one row arrive in source order.
fn claimRow(claims: ClaimColumns, stamp: u32, row: usize, intent_index: u32, intents: []const NavigationIntent) void {
    if (claims.stamp[row] != stamp) {
        claims.stamp[row] = stamp;
        claims.first[row] = intent_index;
        claims.best[row] = intent_index;
        return;
    }
    std.debug.assert(intent_index > claims.best[row]);
    if (intents[intent_index].priority > intents[claims.best[row]].priority) claims.best[row] = intent_index;
}

// The single source-order pass over intents `[start, end)`.
fn resolveAndClaim(
    data: *const DataSystem,
    intents: []const NavigationIntent,
    start: usize,
    end: usize,
    intent_steering: []u32,
    intent_movement: []u32,
    claims: ClaimColumns,
    stamp: u32,
) void {
    for (start..end) |intent_index| {
        const resolved = resolveIntentRow(data, intents[intent_index]);
        intent_steering[intent_index] = resolved.steering;
        intent_movement[intent_index] = resolved.movement;
        if (resolved.steering == no_row) continue;
        // Intent indices fit u32 (`max_step_items`).
        claimRow(claims, stamp, resolved.steering, @intCast(intent_index), intents);
    }
}

// `select_resolve`: one range of intents.
const ResolveJob = struct {
    data: *const DataSystem,
    intents: []const NavigationIntent,
    intent_steering: []u32,
    intent_movement: []u32,
    // Range r's window starts at `r * items_per_range`.
    buckets: []u32,
    bands: AgentBands,
    items_per_range: usize,
    band_rows: []PaddedSlot(BandRow),
};

// Resolves the range's intents, then places each resolved intent's index in the range's
// window by steering band, in source order within a band, and records the band offsets.
fn resolveJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ResolveJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.band_rows.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.intents.len and range.end <= job.buckets.len);
    std.debug.assert(range.end <= job.intent_steering.len and range.end <= job.intent_movement.len);
    const band_count = job.bands.band_count;
    var offsets: [max_bands + 1]u32 = @splat(0);
    for (range.start..range.end) |intent_index| {
        const resolved = resolveIntentRow(job.data, job.intents[intent_index]);
        job.intent_steering[intent_index] = resolved.steering;
        job.intent_movement[intent_index] = resolved.movement;
        if (resolved.steering != no_row) offsets[job.bands.bandOfRow(resolved.steering) + 1] += 1;
    }
    for (1..band_count + 1) |band| offsets[band] += offsets[band - 1];
    job.band_rows[range.index].value.offsets = offsets;
    var cursor = offsets;
    for (range.start..range.end) |intent_index| {
        const row = job.intent_steering[intent_index];
        if (row == no_row) continue;
        const band = job.bands.bandOfRow(row);
        // Intent indices fit u32 (`max_step_items`).
        job.buckets[range.start + cursor[band]] = @intCast(intent_index);
        cursor[band] += 1;
    }
}

// `select_claim`: one range of bands.
const ClaimJob = struct {
    intents: []const NavigationIntent,
    intent_steering: []const u32,
    buckets: []const u32,
    band_rows: []const PaddedSlot(BandRow),
    resolve_items_per_range: usize,
    bands: AgentBands,
    claims: ClaimColumns,
    stamp: u32,
    range_count: usize,
};

// Each band claims its own steering rows from every resolve range's band segment in range
// order, which is source order.
fn claimJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ClaimJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.bands.band_count);
    // The range's bands own the claim rows below `firstRow(range.end)`.
    const claim_rows = job.claims.stamp.len;
    std.debug.assert(job.claims.first.len == claim_rows and job.claims.best.len == claim_rows);
    std.debug.assert(job.bands.firstRow(range.end) <= claim_rows);
    for (range.start..range.end) |band| {
        const first_row = job.bands.firstRow(band);
        const end_row = job.bands.firstRow(band + 1);
        for (job.band_rows, 0..) |slot, resolve_range| {
            const window = job.buckets[resolve_range * job.resolve_items_per_range ..];
            for (window[slot.value.offsets[band]..slot.value.offsets[band + 1]]) |intent_index| {
                const row = job.intent_steering[intent_index];
                std.debug.assert(row >= first_row and row < end_row);
                claimRow(job.claims, job.stamp, row, intent_index, job.intents);
            }
        }
    }
}

// `directions`: one range of intents.
const DirectionsJob = struct {
    pathfinding: *const PathfindingSystem,
    intents: []const NavigationIntent,
    intent_steering: []const u32,
    intent_movement: []const u32,
    claim_stamps: []const u32,
    claim_first: []const u32,
    claim_best: []const u32,
    stamp: u32,
    steering: ConstSteeringAgentSlice,
    previous_x: []const f32,
    previous_y: []const f32,
    scope: ConstScopeColumnsSlice,
    // Written only at the steering rows of the range's selected intents, each selected once.
    runtime: std.MultiArrayList(RuntimeRow).Slice,
    // Range r's window starts at `r * items_per_range`.
    selected: []SelectedIntent,
    work: SelectedWorkSlice,
    items_per_range: usize,
    tallies: []PaddedSlot(DirectionsTally),
};

// Each intent that is its steering row's first this step emits the row's best intent into
// the next slot of the range's window: path status and progress per intent (scalar: a
// cache probe, a field sample, and a waypoint walk), then the direction tail per block of
// four in lanes.
fn directionsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *DirectionsJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.intents.len and range.end <= job.intent_steering.len);
    std.debug.assert(range.end <= job.selected.len and range.end <= job.work.len());
    // Runtime rows are written at intents' steering rows, which index the claims.
    std.debug.assert(job.runtime.len == job.steering.entities.len and job.claim_first.len == job.runtime.len);
    var runtime = job.runtime;
    var tally = DirectionsTally{};
    var tail = DirectionTail{};
    const sink = DirectionTailSink{
        .base_x = job.work.base_dir_x,
        .base_y = job.work.base_dir_y,
        .prev_x = runtime.items(.prev_dir_x),
        .prev_y = runtime.items(.prev_dir_y),
        .has_prev = runtime.items(.has_prev_dir),
    };
    for (range.start..range.end) |intent_index| {
        const row = job.intent_steering[intent_index];
        if (row == no_row or job.claim_first[row] != intent_index) continue;
        std.debug.assert(job.claim_stamps[row] == job.stamp);
        const best = job.claim_best[row];
        const intent = job.intents[best];
        const movement_index = job.intent_movement[best];
        const slot = range.start + tally.count;
        const agent = steeringAgentAt(job.steering, row);
        const start = math.Vec2{ .x = job.previous_x[movement_index], .y = job.previous_y[movement_index] };
        const start_level = movementScopeLevel(job.scope, movement_index);

        var state = runtime.get(row);
        var emit_request = false;
        const path_dir = directionFromPathStatus(job.pathfinding, intent, start, start_level, agent, &state, &tally, &emit_request);
        updateProgress(&state, path_dir.progress_distance, agent, path_dir.status_allows_replan, &tally, &emit_request);
        runtime.set(row, state);

        job.selected[slot] = .{ .entity = intent.entity, .intent = intent };
        job.work.start_x[slot] = start.x;
        job.work.start_y[slot] = start.y;
        job.work.final_dir_x[slot] = 0;
        job.work.final_dir_y[slot] = 0;
        job.work.selected_agent_radii[slot] = agent.agent_radius;
        job.work.selected_avoidance_radii[slot] = agent.avoidance_radius;
        job.work.selected_avoidance_weights[slot] = agent.avoidance_weight;
        job.work.selected_max_neighbor_samples[slot] = agent.max_neighbor_samples;
        job.work.selected_world_level[slot] = start_level;
        // At most one request per intent, so the count fits u32 (`max_step_items`).
        job.work.request_prefix[slot] = @intCast(tally.requests);
        job.work.emit_request[slot] = emit_request;
        if (emit_request) tally.requests += 1;
        tally.count += 1;

        tail.push(slot, row, .{
            .has_path = path_dir.has_direction,
            .path_x = path_dir.direction.x,
            .path_y = path_dir.direction.y,
            .direct_x = intent.direct_direction_x,
            .direct_y = intent.direct_direction_y,
            .prev_x = state.prev_dir_x,
            .prev_y = state.prev_dir_y,
            .has_prev = state.has_prev_dir,
        });
        if (tail.count == simd.lane_count) tail.finish(sink);
    }
    tail.finish(sink);
    job.tallies[range.index].value = tally;
}

// One selected intent's inputs to the direction tail: the path direction when the path
// gives one, the intent's raw direct direction, and its runtime row's previous direction.
const DirectionTailInput = struct {
    has_path: bool,
    path_x: f32,
    path_y: f32,
    direct_x: f32,
    direct_y: f32,
    prev_x: f32,
    prev_y: f32,
    has_prev: bool,
};

// Where the tail writes: base directions by selected slot, previous directions by
// steering row.
const DirectionTailSink = struct {
    base_x: []f32,
    base_y: []f32,
    prev_x: []f32,
    prev_y: []f32,
    has_prev: []bool,
};

// Up to one lane block of pending direction tails.
const DirectionTail = struct {
    inputs: [simd.lane_count]DirectionTailInput = undefined,
    slots: [simd.lane_count]usize = undefined,
    rows: [simd.lane_count]usize = undefined,
    count: usize = 0,

    fn push(self: *DirectionTail, slot: usize, row: usize, input: DirectionTailInput) void {
        std.debug.assert(self.count < simd.lane_count);
        self.inputs[self.count] = input;
        self.slots[self.count] = slot;
        self.rows[self.count] = row;
        self.count += 1;
    }

    // Writes each pending base direction to its slot and makes it its row's previous
    // direction: a full block in lanes, a partial block per item.
    fn finish(self: *DirectionTail, sink: DirectionTailSink) void {
        var bases: [simd.lane_count]math.Vec2 = undefined;
        if (self.count == simd.lane_count) {
            bases = smoothDirectionLanes(&self.inputs);
        } else {
            for (self.inputs[0..self.count], bases[0..self.count]) |input, *base| base.* = smoothDirectionScalar(input);
        }
        for (bases[0..self.count], self.slots[0..self.count], self.rows[0..self.count]) |base, slot, row| {
            sink.base_x[slot] = base.x;
            sink.base_y[slot] = base.y;
            sink.prev_x[row] = base.x;
            sink.prev_y[row] = base.y;
            sink.has_prev[row] = true;
        }
        self.count = 0;
    }
};

// The base direction: the path direction, else the normalized direct direction, blended
// from the previous direction by `steering_turn_smoothing` and re-normalized, so a
// discrete flip in the chosen direction (path/direct toggle, waypoint replan, wander epoch
// change) becomes a bounded per-step turn. A row's first direction is used as-is (no
// startup lag). The caller stores the result as the row's previous direction.
fn smoothDirectionScalar(input: DirectionTailInput) math.Vec2 {
    const direct = math.normalizeOrZeroFinite(input.direct_x, input.direct_y, direction_epsilon);
    const target = if (input.has_path) math.Vec2{ .x = input.path_x, .y = input.path_y } else direct;
    if (!input.has_prev) return target;
    const blended = math.lerpVec2(.{ .x = input.prev_x, .y = input.prev_y }, target, steering_turn_smoothing);
    return math.normalizeOrDefaultFinite(blended.x, blended.y, direction_epsilon, target);
}

// `smoothDirectionScalar` over four inputs in lanes, equal to it bit for bit.
fn smoothDirectionLanes(inputs: *const [simd.lane_count]DirectionTailInput) [simd.lane_count]math.Vec2 {
    var has_path: [simd.lane_count]bool = undefined;
    var has_prev: [simd.lane_count]bool = undefined;
    var path_x: [simd.lane_count]f32 = undefined;
    var path_y: [simd.lane_count]f32 = undefined;
    var direct_x: [simd.lane_count]f32 = undefined;
    var direct_y: [simd.lane_count]f32 = undefined;
    var prev_x: [simd.lane_count]f32 = undefined;
    var prev_y: [simd.lane_count]f32 = undefined;
    for (inputs, 0..) |input, lane| {
        has_path[lane] = input.has_path;
        has_prev[lane] = input.has_prev;
        path_x[lane] = input.path_x;
        path_y[lane] = input.path_y;
        direct_x[lane] = input.direct_x;
        direct_y[lane] = input.direct_y;
        prev_x[lane] = input.prev_x;
        prev_y[lane] = input.prev_y;
    }
    const path_mask: simd.Mask4 = has_path;
    const prev_mask: simd.Mask4 = has_prev;
    const direct = simd.normalizeOrZeroFinite2Float4(simd.loadFloat4(&direct_x), simd.loadFloat4(&direct_y), direction_epsilon);
    const target = simd.Vec2x4{
        .x = simd.selectFloat4(path_mask, simd.loadFloat4(&path_x), direct.x),
        .y = simd.selectFloat4(path_mask, simd.loadFloat4(&path_y), direct.y),
    };
    const previous = simd.Vec2x4{ .x = simd.loadFloat4(&prev_x), .y = simd.loadFloat4(&prev_y) };
    const blended = simd.lerpVec2Float4(previous, target, simd.splatFloat4(steering_turn_smoothing));
    const smoothed = simd.normalizeOrDefaultFinite2Float4(blended.x, blended.y, direction_epsilon, target);
    const base_x = simd.toFloatArray(simd.selectFloat4(prev_mask, smoothed.x, target.x));
    const base_y = simd.toFloatArray(simd.selectFloat4(prev_mask, smoothed.y, target.y));
    var bases: [simd.lane_count]math.Vec2 = undefined;
    for (&bases, base_x, base_y) |*base, x, y| base.* = .{ .x = x, .y = y };
    return bases;
}

fn directionFromPathStatus(
    pathfinding: *const PathfindingSystem,
    intent: NavigationIntent,
    start: math.Vec2,
    start_level: u16,
    steering_agent: SteeringAgentView,
    runtime: *RuntimeRow,
    tally: *DirectionsTally,
    emit_request: *bool,
) PathDirection {
    // Missing paths request work, pending paths hold direction, unavailable
    // paths enter backoff, and available paths steer toward the next waypoint.
    const goal_distance = distance(start, intent.goal);
    const view = pathfinding.statusForWorld(start_level, start, intent.goal_level, intent.goal, intent.agent_class, &runtime.waypoint_hint);
    switch (view.status) {
        .available => {
            tally.available += 1;
            const to_waypoint = math.Vec2{
                .x = view.next_waypoint.x - start.x,
                .y = view.next_waypoint.y - start.y,
            };
            if (math.lengthSquared(to_waypoint) <= steering_agent.waypoint_tolerance * steering_agent.waypoint_tolerance) {
                // At the waypoint: steer straight to the goal, so progress is goal distance.
                return .{ .has_direction = true, .direction = math.normalizeOrZeroFinite(intent.goal.x - start.x, intent.goal.y - start.y, direction_epsilon), .status_allows_replan = true, .progress_distance = goal_distance };
            }
            // Following the path: progress is closing on the next waypoint, which a
            // detour reduces even while straight-line goal distance grows.
            return .{ .has_direction = true, .direction = math.normalizeOrZeroFinite(to_waypoint.x, to_waypoint.y, direction_epsilon), .status_allows_replan = true, .progress_distance = math.length(to_waypoint) };
        },
        .missing => {
            if (runtime.replan_cooldown == 0 and runtime.unavailable_backoff == 0) {
                emit_request.* = true;
                runtime.replan_cooldown = steering_agent.replan_cooldown_steps;
            } else {
                tally.cooldowns += 1;
            }
            return .{ .status_allows_replan = true, .progress_distance = goal_distance };
        },
        .pending => {
            tally.pending += 1;
            return .{ .progress_distance = goal_distance };
        },
        .unavailable => {
            tally.unavailable += 1;
            if (runtime.unavailable_backoff == 0) {
                runtime.unavailable_backoff = steering_agent.unavailable_backoff_steps;
            } else {
                tally.backoffs += 1;
            }
            return .{ .progress_distance = goal_distance };
        },
    }
}

fn updateProgress(
    runtime: *RuntimeRow,
    progress_distance: f32,
    steering_agent: SteeringAgentView,
    status_allows_replan: bool,
    tally: *DirectionsTally,
    emit_request: *bool,
) void {
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
        if (!emit_request.*) {
            emit_request.* = true;
            tally.stuck_replans += 1;
        }
    }
}

// `grid_bucket`: one range of snapshot rows.
const BucketJob = struct {
    agents: ConstAgentSnapshotSlice,
    cell_size: f32,
    // Its splitters, written before dispatch.
    grid: *const AgentGridDirectory,
    // Range r's windows start at `r * items_per_range`.
    scratch: []SpatialCellEntry,
    staging: []SpatialCellEntry,
    items_per_range: usize,
    band_rows: []PaddedSlot(BandRow),
};

// Fills the range's cell entries into its scratch window, then places them in its staging
// window by cell-key band, in row order within a band, and records the band offsets. The
// band search runs twice per entry rather than storing each band: scalar, a six-step
// binary search over two-field keys.
fn bucketJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *BucketJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.band_rows.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.agents.len());
    std.debug.assert(range.end <= job.scratch.len and range.end <= job.staging.len);
    std.debug.assert(job.grid.splitter_count == max_bands - 1);
    const filled = job.scratch[range.start..][0..fillCellEntries(job.agents, job.cell_size, range.start, range.end, job.scratch[range.start..range.end])];
    var offsets: [max_bands + 1]u32 = @splat(0);
    for (filled) |entry| offsets[job.grid.bandOfCell(entry.cell_x, entry.cell_y) + 1] += 1;
    for (1..max_bands + 1) |band| offsets[band] += offsets[band - 1];
    job.band_rows[range.index].value.offsets = offsets;
    var cursor = offsets;
    for (filled) |entry| {
        const band = job.grid.bandOfCell(entry.cell_x, entry.cell_y);
        job.staging[range.start + cursor[band]] = entry;
        cursor[band] += 1;
    }
}

// `grid_sort`: one range of the `max_bands` bands.
const SortJob = struct {
    staging: []const SpatialCellEntry,
    band_rows: []const PaddedSlot(BandRow),
    bucket_items_per_range: usize,
    // Band b's entries and cell ranges go to `[band_start[b], band_start[b + 1])`.
    band_start: [max_bands + 1]usize,
    entries: []SpatialCellEntry,
    ranges: []SpatialCellRange,
    tallies: []PaddedSlot(GridSortTally),
    range_count: usize,
};

// Each band gathers every bucket range's band segment in range order into its slice, sorts
// it, and writes its cell ranges into the same slice of the range list.
fn sortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SortJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= max_bands and max_bands <= job.tallies.len);
    std.debug.assert(job.band_start[range.end] <= job.entries.len and job.band_start[range.end] <= job.ranges.len);
    for (range.start..range.end) |band| {
        const start = job.band_start[band];
        const end = job.band_start[band + 1];
        var cursor = start;
        for (job.band_rows, 0..) |slot, bucket_range| {
            const window = job.staging[bucket_range * job.bucket_items_per_range ..];
            const segment = window[slot.value.offsets[band]..slot.value.offsets[band + 1]];
            @memcpy(job.entries[cursor..][0..segment.len], segment);
            cursor += segment.len;
        }
        std.debug.assert(cursor == end);
        job.tallies[band].value = .{ .range_count = sortCellEntries(job.entries[start..end], job.ranges[start..end], start) };
    }
}

const SteeringJobContext = struct {
    // Worker context is immutable input plus range-indexed output columns and
    // pre-prefixed SimulationFrame streams.
    windows: []const SelectedWindow,
    selected: []const SelectedIntent,
    work: SelectedWorkSlice,
    // By steering row.
    agents: ConstAgentSnapshotSlice,
    agent_radii: []const f32,
    /// The static colliders' synced rows, read-only for the whole dispatch.
    obstacles: ColliderView,
    agent_cell_entries: []const SpatialCellEntry,
    agent_cell_ranges: []const SpatialCellRange,
    agent_grid: *const AgentGridDirectory,
    spatial_cell_size: f32,
    intents: *RangeOutputStream(SimulationIntent),
    requests: *RangeOutputStream(PathRequest),
    intent_range_base: usize,
    request_range_base: usize,
    // Selected intents in selected order; the pass's item count.
    selected_count: usize,
    tallies: []PaddedSlot(MovementTally),
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

// Path requests flagged by the selected intents before selected position `logical`.
fn requestsBefore(windows: []const SelectedWindow, request_prefix: []const u32, selected_count: usize, request_count: usize, logical: usize) usize {
    if (logical >= selected_count) return request_count;
    const window = windows[windowContaining(windows, logical)];
    return window.request_base + request_prefix[window.start + logical - window.logical_base];
}

// The window holding selected position `logical` (below the selected count): the last
// window starting at or before it, which is never empty.
fn windowContaining(windows: []const SelectedWindow, logical: usize) usize {
    var low: usize = 0;
    var high: usize = windows.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (windows[mid].logical_base <= logical) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    std.debug.assert(low > 0);
    std.debug.assert(logical < windows[low - 1].logical_base + windows[low - 1].count);
    return low - 1;
}

fn writeSteeringMovementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    // Jobs never append outside their assigned output ranges, which keeps the
    // transient streams deterministic across serial and threaded runs.
    const job: *SteeringJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig).
    std.debug.assert(range.index < job.range_count and range.index < job.tallies.len);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.selected_count);
    var intents = job.intents.rangeWriter(job.intent_range_base + range.index);
    var requests = job.requests.rangeWriter(job.request_range_base + range.index);
    // One hit scratch per range, reused by every agent of the range.
    var obstacle_hits: ObstacleHitScratch = undefined;
    var tally = MovementTally{};
    if (range.start < range.end) {
        // A cursor from selected order onto the directions windows.
        var window = windowContaining(job.windows, range.start);
        for (range.start..range.end) |logical| {
            while (logical >= job.windows[window].logical_base + job.windows[window].count) window += 1;
            const index = job.windows[window].start + (logical - job.windows[window].logical_base);
            std.debug.assert(index < job.selected.len and index < job.work.len());
            const result = computeAvoidance(job, index, &obstacle_hits);
            job.work.final_dir_x[index] = result.direction.x;
            job.work.final_dir_y[index] = result.direction.y;
            tally.agent_samples += result.agent_samples;
            tally.obstacle_samples += result.obstacle_samples;
            tally.agent_checks += result.agent_candidate_checks;
            tally.obstacle_checks += result.obstacle_candidate_checks;
            const selected = job.selected[index];
            intents.write(.{ .movement = MovementIntent{
                .entity = selected.entity,
                .direction_x = result.direction.x,
                .direction_y = result.direction.y,
            } });
            if (job.work.emit_request[index]) requests.write(PathRequest{
                .entity = selected.entity,
                .agent_class = selected.intent.agent_class,
                .kind = selected.intent.kind,
                .start_level = job.work.selected_world_level[index],
                .goal_level = selected.intent.goal_level,
                .start = .{ .x = job.work.start_x[index], .y = job.work.start_y[index] },
                .goal = selected.intent.goal,
            });
        }
    }
    intents.finish();
    requests.finish();
    job.tallies[range.index].value = tally;
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

    // The serial grid is one band: its ranges are resolved once, not per probed cell.
    const one_band: ?[]const SpatialCellRange = if (job.agent_grid.splitter_count == 0)
        job.agent_cell_ranges[job.agent_grid.bands[0].start..][0..job.agent_grid.bands[0].range_count]
    else
        null;
    var cell_y = min_cell_y;
    while (cell_y <= max_cell_y and sample_count.* < max_samples and candidate_count.* < max_agent_candidate_checks) : (cell_y += 1) {
        var cell_x = min_cell_x;
        while (cell_x <= max_cell_x and sample_count.* < max_samples and candidate_count.* < max_agent_candidate_checks) : (cell_x += 1) {
            const band_ranges = one_band orelse job.agent_grid.rangesOfCell(job.agent_cell_ranges, cell_x, cell_y);
            const range = findCellRange(band_ranges, cell_x, cell_y) orelse continue;
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
                const combined_radius = avoidance_radius + job.agent_radii[other_index];
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

// Sorts `entries` by (cell_y, cell_x, row) and writes one range per occupied cell to
// `ranges`, its bounds offset by `base` (the slice's position in the entry list). Returns the
// range count, at most the entry count.
fn sortCellEntries(entries: []SpatialCellEntry, ranges: []SpatialCellRange, base: usize) usize {
    std.debug.assert(ranges.len >= entries.len);
    // pdqsort: agents move slowly so order is often nearly sorted; still O(n log n) worst case.
    std.sort.pdq(SpatialCellEntry, entries, {}, spatialCellEntryLessThan);
    var range_count: usize = 0;
    var entry_index: usize = 0;
    while (entry_index < entries.len) {
        const cell_x = entries[entry_index].cell_x;
        const cell_y = entries[entry_index].cell_y;
        const start = entry_index;
        while (entry_index < entries.len and entries[entry_index].cell_x == cell_x and entries[entry_index].cell_y == cell_y) {
            entry_index += 1;
        }
        ranges[range_count] = .{ .cell_x = cell_x, .cell_y = cell_y, .start = base + start, .end = base + entry_index };
        range_count += 1;
    }
    return range_count;
}

// The agent grid's `max_bands - 1` band splitters: the cells at the band quantiles of up to
// `grid_sample_count` snapshot rows (rows without a body skipped), sorted. Every row when
// they fit the sample, else rows at a golden-ratio sequence of fractions of the row count,
// which shares no period with a periodic row order. Fixed work on the main thread; with no
// sampled body every splitter is `max_cell_key`.
fn chooseGridSplitters(agents: ConstAgentSnapshotSlice, cell_size: f32) [max_bands - 1]CellKey {
    const row_count = agents.len();
    const sample_count: usize = @min(grid_sample_count, row_count);
    var samples: [grid_sample_count]SpatialCellEntry = undefined;
    var valid: usize = 0;
    // A 0.64 fixed-point fraction stepped by the golden ratio's fractional part.
    var fraction: u64 = 0;
    for (0..sample_count) |sample| {
        fraction +%= grid_sample_fraction_step;
        // The high word of fraction * row_count is below row_count, so it fits usize.
        const row: usize = if (row_count <= grid_sample_count) sample else @intCast(std.math.mulWide(u64, fraction, row_count) >> 64);
        if (!agents.entity[row].isValid()) continue;
        samples[valid] = .{ .cell_x = spatialCell(agents.x[row], cell_size), .cell_y = spatialCell(agents.y[row], cell_size), .index = row };
        valid += 1;
    }
    var splitters: [max_bands - 1]CellKey = @splat(max_cell_key);
    if (valid == 0) return splitters;
    std.sort.pdq(SpatialCellEntry, samples[0..valid], {}, spatialCellEntryLessThan);
    for (&splitters, 1..) |*splitter, band| {
        const sample = samples[band * valid / max_bands];
        splitter.* = .{ .cell_y = sample.cell_y, .cell_x = sample.cell_x };
    }
    return splitters;
}

// Writes a cell entry to `out` for each row of `[start, end)` with a body, in row order, and
// returns the count: cells over the snapshot's x/y columns in lanes with a scalar tail, bit
// for bit `spatialCell`.
fn fillCellEntries(agents: ConstAgentSnapshotSlice, cell_size: f32, start: usize, end: usize, out: []SpatialCellEntry) usize {
    std.debug.assert(start <= end and end <= agents.len() and out.len >= end - start);
    const cell_size_lanes = simd.splatFloat4(@max(cell_size, min_spatial_cell_size));
    var count: usize = 0;
    var row = start;
    const vector_end = start + simd.vectorizedEnd(end - start);
    while (row < vector_end) : (row += simd.lane_count) {
        const cell_x = simd.toIntArray(simd.floorToI4(simd.divFloat4(simd.loadFloat4(agents.x[row..]), cell_size_lanes)));
        const cell_y = simd.toIntArray(simd.floorToI4(simd.divFloat4(simd.loadFloat4(agents.y[row..]), cell_size_lanes)));
        inline for (0..simd.lane_count) |lane| {
            if (agents.entity[row + lane].isValid()) {
                out[count] = .{ .cell_x = cell_x[lane], .cell_y = cell_y[lane], .index = row + lane };
                count += 1;
            }
        }
    }
    while (row < end) : (row += 1) {
        if (!agents.entity[row].isValid()) continue;
        out[count] = .{ .cell_x = spatialCell(agents.x[row], cell_size), .cell_y = spatialCell(agents.y[row], cell_size), .index = row };
        count += 1;
    }
    return count;
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

fn expectAgentSnapshotColumnsAligned(rows: *const std.MultiArrayList(AgentSnapshotRow)) !void {
    const count = rows.len;
    const s = rows.slice();
    try std.testing.expectEqual(count, s.items(.entity).len);
    try std.testing.expectEqual(count, s.items(.x).len);
    try std.testing.expectEqual(count, s.items(.y).len);
    try std.testing.expectEqual(count, s.items(.world_level).len);
}

// Test-only fixtures for multi-level start_level regression (not production API).
const WorldSystem = @import("../world_system.zig").WorldSystem;
const loadTestWorldMeta = @import("pathfinding/test_support.zig").loadTestWorldMeta;
const worldColliders = @import("pathfinding/test_support.zig").worldColliders;
const StructuralCommand = @import("../data_system.zig").StructuralCommand;
const requireTestTile = @import("pathfinding/test_support.zig").requireTestTile;

test "steering agent snapshot holds each steering row's previous position, and no entity without a body" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const bodiless = try data.createEntity();
    try data.setSteeringAgent(bodiless, .{ .agent_radius = 8, .waypoint_tolerance = 4, .avoidance_radius = 48, .avoidance_weight = 1.5, .max_neighbor_samples = 8, .stuck_step_threshold = 3, .replan_cooldown_steps = 4, .unavailable_backoff_steps = 12 });
    const second = try addSteeredEntity(&data, .{ .x = 32, .y = 16 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4 });
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const missing_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), missing_stats.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), frame.path_requests.mergedItems().len);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);

    _ = try pathfinding.updateSerial(&frame.path_requests, 1, .{});

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    const available_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    const first = frame.intents.mergedItems()[0].movement;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), first.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), first.direction_y, 0.001);

    // Target direction flips a full 90 degrees to (0, 1). A hard snap would
    // jump straight to direction_y == 1; smoothing should only partially turn.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    const second = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(second.direction_y > 0.0);
    try std.testing.expect(second.direction_y < 0.9);
    try std.testing.expect(second.direction_x > 0.0);

    // Repeated steps toward the same (0, 1) target converge close to it.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        frame.beginStep();
        try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
        _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    }
    const converged = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(converged.direction_y > 0.95);
}

test "steering sources path request start level from movement scope level" {
    // The avoidance pass's path request takes its start level from the selected intent's
    // movementScopeLevel, which `directions` records (scope.level, kept in sync with
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
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);

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
    const first = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), first.path_request_count);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const second = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), second.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), second.replan_cooldown_count);
    try std.testing.expectEqual(@as(usize, 0), frame.path_requests.mergedItems().len);
}

test "steering reads an unreachable goal unavailable from status on the first step and backs off on the next, never requesting" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    // A wall on cell column 3, the last column of the first 4-cell chunk, seals the goal's
    // side off the agent's.
    _ = try addStaticObstacle(&data, .{ .x = 96, .y = 0 }, .{ .x = 32, .y = 160 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 4, .nav_chunk_tiles = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    const grid = pathfinding.graph.grid(0).?;
    try std.testing.expect(grid.isBlockedCell(.{ .x = 3, .y = 0 }) and !grid.isBlockedCell(.{ .x = 2, .y = 0 }) and !grid.isBlockedCell(.{ .x = 4, .y = 0 }));
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
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 144, .y = 0 }, .direct_direction_x = 1 });
    const first = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), first.path_unavailable_count);
    try std.testing.expectEqual(@as(usize, 0), first.path_request_count);
    try std.testing.expectEqual(@as(usize, 0), first.unavailable_backoff_count);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 144, .y = 0 }, .direct_direction_x = 1 });
    const second = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), second.path_unavailable_count);
    try std.testing.expectEqual(@as(usize, 1), second.unavailable_backoff_count);
    try std.testing.expectEqual(@as(usize, 0), second.path_request_count);
}

test "steering reads a goal its start cannot reach unavailable from status every step and never requests it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 160 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    // One chunk holds the agent and the goal, on two of its labels.
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

    // Past the agent's replan cooldown and unavailable backoff, so a re-request would show.
    for (0..16) |_| {
        frame.beginStep();
        try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 128, .y = 0 }, .direct_direction_x = 1 });
        const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
        try std.testing.expectEqual(@as(usize, 1), stats.path_unavailable_count);
        try std.testing.expectEqual(@as(usize, 0), stats.path_request_count);
        const solve = try pathfinding.updateSerial(&frame.path_requests, 1, .{});
        try std.testing.expectEqual(@as(usize, 0), solve.solved_requests + solve.accepted_requests);
    }
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 3), stats.navigation_intent_count);
    try std.testing.expectEqual(@as(usize, 1), stats.selected_intent_count);
    const intent = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(intent.direction_y > 0.9);
    try std.testing.expect(@abs(intent.direction_x) < 0.01);
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const cross_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const same_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const serial_stats = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, &colliders);
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
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expect(steering.steering_movement_index_valid);
    try std.testing.expectEqual(@as(usize, 1), steering.steering_movement_index.items.len);
    const cached_mi = steering.steering_movement_index.items[0];
    try std.testing.expectEqual(data.movementBodyDenseIndex(agent).?, cached_mi);

    // Second step without structural events reuses the cache.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const parked_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const moved_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);

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
    const serial_stats = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, &colliders);
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
    _ = try serial_system.updateSerial(&data, &serial_frame, &pathfinding, &colliders);
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

    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const churn = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 2), churn.movement_intent_count);
    try std.testing.expectEqual(@as(usize, 2), steering.runtime_rows.len);
}

test "steering threaded multi-worker update is allocation-free after reserves from the first step (FailingAllocator)" {
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
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), steering.runtime_rows.len);

    try std.testing.expect(data.destroyEntity(agent));
    frame.beginStep();
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), steering.runtime_rows.len);
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    // Every co-located static meets the query box, so each entry read is a hit: the walk
    // stops at the hit cap after reading `max_obstacle_hits` of the 128 entries.
    try std.testing.expectEqual(@as(usize, max_obstacle_hits), stats.obstacle_candidate_checks);
    try std.testing.expect(stats.obstacle_samples <= max_obstacle_hits);
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
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

test "steering threaded arbitration keeps the first appearance and the best intent across ranges" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Far enough apart that no agent pushes another.
    var agents: [40]EntityId = undefined;
    for (&agents, 0..) |*agent, index| {
        agent.* = try addSteeredEntity(&data, .{ .x = @floatFromInt(index % 8 * 200), .y = @floatFromInt(index / 8 * 200) });
    }
    // No nav grid: every path is unavailable, so each agent steers along its intent's
    // direct direction.
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 64, .max_pending_requests = 64, .max_cached_results = 64, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 64 });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    // Six 16-intent ranges. Every agent's first intent comes in agent order; a second
    // intent per agent a range or more later beats it (priority 2), ties it (1, the first
    // keeps), or loses (0); a third for the first 16 agents ties a priority-2 second or
    // beats the rest.
    var intents: [96]NavigationIntent = undefined;
    for (0..40) |index| intents[index] = selectionIntent(agents[index], index, 0, 1);
    for (0..40) |index| {
        const agent = index * 7 % 40;
        intents[40 + index] = selectionIntent(agents[agent], agent, 1, @as(i16, 2) - @as(i16, @intCast(index % 3)));
    }
    for (0..16) |index| intents[80 + index] = selectionIntent(agents[index], index, 2, 2);
    // The reference: per agent the highest priority, ties to the earliest.
    var best: [40]usize = undefined;
    for (&best, 0..) |*slot, index| slot.* = index;
    for (intents[40..], 40..) |intent, source_order| {
        const agent = for (agents, 0..) |candidate, index| {
            if (candidate.eql(intent.entity)) break index;
        } else unreachable;
        if (intent.priority > intents[best[agent]].priority) best[agent] = source_order;
    }

    var outputs: [2][40]MovementIntent = undefined;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    for (&outputs, 0..) |*output, run| {
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(8, 0, intents.len, 0, 0, 0);
        try frame.reservePathRequests(8, intents.len);
        var steering = SteeringSystem.init(std.testing.allocator);
        defer steering.deinit();
        try steering.reserve(intents.len);
        frame.beginStep();
        try appendNavigationIntents(&frame, &intents);
        const stats = if (run == 0)
            try steering.updateSerial(&data, &frame, &pathfinding, &colliders)
        else
            try steering.update(&data, &frame, &threads, &pathfinding, &colliders, .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 2, .adaptive = false });
        if (run == 1) try expectEveryStageThreaded(stats);
        try std.testing.expectEqual(@as(usize, 40), stats.selected_intent_count);
        // First appearance order, each agent steering along its best intent.
        for (output, frame.intents.mergedItems(), agents, best) |*slot, merged, agent, best_index| {
            slot.* = merged.movement;
            try std.testing.expect(slot.entity.eql(agent));
            const expected = math.normalizeOrZeroFinite(intents[best_index].direct_direction_x, intents[best_index].direct_direction_y, direction_epsilon);
            try std.testing.expectApproxEqAbs(expected.x, slot.direction_x, 0.00001);
            try std.testing.expectApproxEqAbs(expected.y, slot.direction_y, 0.00001);
        }
    }
    for (outputs[0], outputs[1]) |serial, threaded| {
        try std.testing.expectEqual(@as(u32, @bitCast(serial.direction_x)), @as(u32, @bitCast(threaded.direction_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(serial.direction_y)), @as(u32, @bitCast(threaded.direction_y)));
    }
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

test "steering direction tail lanes equal the scalar smoothing" {
    var prng = std.Random.DefaultPrng.init(0x0d1e_c7ed);
    const random = prng.random();
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    // Zero, NaN, and inf direct directions; a NaN previous direction; a blend landing at
    // zero length; opposite previous and target.
    const crafted = [_]DirectionTailInput{
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = 0, .direct_y = 0, .prev_x = 1, .prev_y = 0, .has_prev = true },
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = nan, .direct_y = 1, .prev_x = 0, .prev_y = 1, .has_prev = true },
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = inf, .direct_y = 0, .prev_x = 0, .prev_y = 0, .has_prev = false },
        .{ .has_path = true, .path_x = 1, .path_y = 0, .direct_x = 0, .direct_y = 1, .prev_x = nan, .prev_y = 0, .has_prev = true },
        .{ .has_path = true, .path_x = 17, .path_y = 0, .direct_x = 0, .direct_y = 0, .prev_x = -3, .prev_y = 0, .has_prev = true },
        .{ .has_path = true, .path_x = -1, .path_y = 0, .direct_x = 1, .direct_y = 1, .prev_x = 1, .prev_y = 0, .has_prev = true },
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = -0.00001, .direct_y = 0.00001, .prev_x = 0.6, .prev_y = 0.8, .has_prev = true },
    };
    var inputs: [9]DirectionTailInput = undefined;
    for (0..64) |round| {
        for (&inputs, 0..) |*input, index| {
            const pick = (round * inputs.len + index) % (crafted.len * 3);
            input.* = if (pick < crafted.len) crafted[pick] else .{
                .has_path = random.boolean(),
                .path_x = random.float(f32) * 2 - 1,
                .path_y = random.float(f32) * 2 - 1,
                .direct_x = random.float(f32) * 4 - 2,
                .direct_y = random.float(f32) * 4 - 2,
                .prev_x = random.float(f32) * 2 - 1,
                .prev_y = random.float(f32) * 2 - 1,
                .has_prev = random.boolean(),
            };
        }
        for (1..inputs.len + 1) |count| {
            var base_x: [9]f32 = @splat(0);
            var base_y: [9]f32 = @splat(0);
            var prev_x: [9]f32 = @splat(0);
            var prev_y: [9]f32 = @splat(0);
            var has_prev: [9]bool = @splat(false);
            const sink = DirectionTailSink{ .base_x = &base_x, .base_y = &base_y, .prev_x = &prev_x, .prev_y = &prev_y, .has_prev = &has_prev };
            var tail = DirectionTail{};
            for (inputs[0..count], 0..) |input, index| {
                tail.push(index, index, input);
                if (tail.count == simd.lane_count) tail.finish(sink);
            }
            tail.finish(sink);
            for (inputs[0..count], 0..) |input, index| {
                const expected = smoothDirectionScalar(input);
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(base_x[index])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(base_y[index])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(prev_x[index])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(prev_y[index])));
                try std.testing.expect(has_prev[index]);
            }
        }
    }
}

test "steering claims stay correct across the claim stamp wrap" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var agents: [6]EntityId = undefined;
    for (&agents, 0..) |*agent, index| agent.* = try addSteeredEntity(&data, .{ .x = @floatFromInt(index * 200), .y = 0 });
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 8, .max_pending_requests = 8, .max_cached_results = 8, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 8 });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    // Steps 1 and 3 claim the same rows with different intents, around a wrap.
    const steps = [_][]const NavigationIntent{
        &.{ selectionIntent(agents[0], 0, 0, 1), selectionIntent(agents[1], 1, 0, 1), selectionIntent(agents[2], 2, 0, 1), selectionIntent(agents[0], 0, 1, 3) },
        &.{ selectionIntent(agents[3], 3, 0, 1), selectionIntent(agents[4], 4, 0, 1) },
        &.{ selectionIntent(agents[5], 5, 2, 0), selectionIntent(agents[2], 2, 2, 1), selectionIntent(agents[1], 1, 2, 0), selectionIntent(agents[0], 0, 2, 1), selectionIntent(agents[1], 1, 3, 2) },
    };
    var outputs: [2][steps.len][5]MovementIntent = undefined;
    var counts: [2][steps.len]usize = undefined;
    for (0..2) |run| {
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(2, 0, 8, 0, 0, 0);
        try frame.reservePathRequests(2, 8);
        var steering = SteeringSystem.init(std.testing.allocator);
        defer steering.deinit();
        try steering.reserve(8);
        for (steps, 0..) |step_intents, step_index| {
            // The second run's middle step takes the last stamp, so its third step wraps.
            if (run == 1 and step_index == 1) steering.claim_stamp = std.math.maxInt(u32) - 1;
            frame.beginStep();
            try appendNavigationIntents(&frame, step_intents);
            const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
            counts[run][step_index] = stats.selected_intent_count;
            for (frame.intents.mergedItems(), 0..) |merged, index| outputs[run][step_index][index] = merged.movement;
        }
        if (run == 1) try std.testing.expectEqual(@as(u32, 1), steering.claim_stamp);
    }
    try std.testing.expectEqual(counts[0], counts[1]);
    try std.testing.expectEqual(@as(usize, 4), counts[1][2]);
    for (counts[0], outputs[0], outputs[1]) |count, control, wrapped| {
        for (control[0..count], wrapped[0..count]) |expected, actual| {
            try std.testing.expect(expected.entity.eql(actual.entity));
            try std.testing.expectEqual(@as(u32, @bitCast(expected.direction_x)), @as(u32, @bitCast(actual.direction_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(expected.direction_y)), @as(u32, @bitCast(actual.direction_y)));
        }
    }
}

test "steering banded agent grid gives every cell the same entries as one band" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 3, .adaptive = false } };
    const inline_ranges = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 0, .adaptive = false } };

    for (std.meta.tags(GridTestLayout)) |layout| {
        var system = SteeringSystem.init(std.testing.allocator);
        defer system.deinit();
        try fillGridTestSnapshot(&system, layout);
        var stats = SteeringStats{};
        system.buildAgentGrid(null, &stats);
        try std.testing.expectEqual(@as(usize, 0), system.agent_grid.splitter_count);
        var reference = try GridTestCells.capture(&system);
        defer reference.deinit();
        try std.testing.expectEqual(layout == .one_cell, reference.ranges.items.len == 1);

        // Both stages inline in their ranges on the main thread.
        const inline_selection = inline_ranges.select(&system.grid_bucket_tuner, system.agent_snapshot_rows.len, steering_range_alignment_items, null);
        system.buildAgentGridBanded(inline_ranges, inline_selection, chooseGridSplitters(system.agentSnapshotSliceConst(), system.spatial_cell_size), &stats);
        try std.testing.expect(stats.grid_bucket_batch.ran_inline and stats.grid_bucket_batch.range_count > 1);
        try std.testing.expect(stats.grid_sort_batch.ran_inline);
        try std.testing.expectEqual(max_bands, stats.grid_sort_batch.item_count);
        try expectGridMatches(&system, &reference);

        // A config that allows no worker builds the serial grid.
        stats = .{};
        system.buildAgentGrid(inline_ranges, &stats);
        try std.testing.expectEqual(@as(usize, 0), system.agent_grid.splitter_count);
        try std.testing.expectEqual(@as(usize, 0), stats.grid_sort_batch.item_count);
        try expectGridMatches(&system, &reference);

        // Explicit splitter sets over the same bucket ranges.
        const selection = threaded.select(&system.grid_bucket_tuner, system.agent_snapshot_rows.len, steering_range_alignment_items, null);
        for (std.meta.tags(GridTestSplitters)) |set| {
            system.buildAgentGridBanded(threaded, selection, gridTestSplitters(set, reference.ranges.items), &stats);
            try std.testing.expect(!stats.grid_bucket_batch.ran_inline);
            try std.testing.expectEqual(max_bands, stats.grid_sort_batch.item_count);
            try expectGridMatches(&system, &reference);
        }

        // The production splitters.
        system.buildAgentGrid(threaded, &stats);
        try std.testing.expect(!stats.grid_bucket_batch.ran_inline and !stats.grid_sort_batch.ran_inline);
        try std.testing.expectEqual(max_bands, stats.grid_sort_batch.item_count);
        try expectGridMatches(&system, &reference);
    }
}

test "steering agent grid splits a one-row corridor and a cluster with a far outlier across bands" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 3, .adaptive = false } };

    for ([_]GridTestLayout{ .one_row, .cluster_outlier }) |layout| {
        var system = SteeringSystem.init(std.testing.allocator);
        defer system.deinit();
        try fillGridTestSnapshot(&system, layout);
        var stats = SteeringStats{};
        system.buildAgentGrid(threaded, &stats);
        const entry_count = system.agent_cell_entries.items.len;
        try std.testing.expect(entry_count > 0);
        try std.testing.expect(largestBandEntries(&system) <= entry_count / 8);
    }
}

test "steering agent grid splits rows that alternate between two clusters across bands" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 3, .adaptive = false } };

    // Row counts at and near power-of-two multiples of the sample count, with the clusters
    // alternating every row and every 16 rows.
    const cases = [_]struct { row_count: usize, period: usize }{
        .{ .row_count = 1024, .period = 2 },
        .{ .row_count = 1030, .period = 2 },
        .{ .row_count = 8192, .period = 32 },
    };
    for (cases) |case| {
        var system = SteeringSystem.init(std.testing.allocator);
        defer system.deinit();
        try fillAlternatingClustersSnapshot(&system, case.row_count, case.period);
        var stats = SteeringStats{};
        system.buildAgentGrid(threaded, &stats);
        try std.testing.expectEqual(case.row_count, system.agent_cell_entries.items.len);
        try std.testing.expect(largestBandEntries(&system) <= case.row_count / 8);
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

test "steering claim band count does not follow the resolve partition" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Far enough apart that no agent pushes another.
    var agents: [40]EntityId = undefined;
    for (&agents, 0..) |*agent, index| {
        agent.* = try addSteeredEntity(&data, .{ .x = @floatFromInt(index % 8 * 200), .y = @floatFromInt(index / 8 * 200) });
    }
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_frame_requests = 64, .max_pending_requests = 64, .max_cached_results = 64, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 64 });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    // Each agent's first intent, then a second that beats, ties, or loses to it.
    var intents: [80]NavigationIntent = undefined;
    for (0..40) |index| intents[index] = selectionIntent(agents[index], index, 0, 1);
    for (0..40) |index| {
        const agent = index * 7 % 40;
        intents[40 + index] = selectionIntent(agents[agent], agent, 1, @as(i16, 2) - @as(i16, @intCast(index % 3)));
    }

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    // Serial, then five and two resolve ranges.
    const resolve_ranges = [_]?usize{ null, 16, 48 };
    var outputs: [resolve_ranges.len][40]MovementIntent = undefined;
    var claims: [resolve_ranges.len][40]Claim = undefined;
    for (resolve_ranges, &outputs, &claims) |items_per_range, *output, *claim| {
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(8, 0, intents.len, 0, 0, 0);
        try frame.reservePathRequests(8, intents.len);
        var steering = SteeringSystem.init(std.testing.allocator);
        defer steering.deinit();
        try steering.reserve(intents.len);
        frame.beginStep();
        try appendNavigationIntents(&frame, &intents);
        const stats = if (items_per_range) |range_items|
            try steering.update(&data, &frame, &threads, &pathfinding, &colliders, .{ .items_per_range = range_items, .max_worker_threads = 2, .adaptive = false })
        else
            try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
        if (items_per_range) |range_items| {
            try std.testing.expectEqual((intents.len + range_items - 1) / range_items, stats.select_resolve_batch.range_count);
            // Three 16-row claim blocks over 40 steering rows, whatever the resolve ranges.
            try std.testing.expectEqual(@as(usize, 3), stats.select_claim_batch.item_count);
        }
        try std.testing.expectEqual(@as(usize, 40), stats.selected_intent_count);
        for (output, frame.intents.mergedItems()) |*slot, merged| slot.* = merged.movement;
        for (claim, 0..) |*slot, row| slot.* = steering.claims.get(row);
    }
    for (outputs[1..], claims[1..]) |threaded_output, threaded_claims| {
        for (outputs[0], threaded_output) |want, got| {
            try std.testing.expect(want.entity.eql(got.entity));
            try std.testing.expectEqual(@as(u32, @bitCast(want.direction_x)), @as(u32, @bitCast(got.direction_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(want.direction_y)), @as(u32, @bitCast(got.direction_y)));
        }
        for (claims[0], threaded_claims) |want, got| {
            try std.testing.expectEqual(want.first, got.first);
            try std.testing.expectEqual(want.best, got.best);
        }
    }
}

// Agent grid test layouts: every row in one cell row across about 200 cells; spread over
// many cell rows; at negative coordinates with a NaN y, a -inf x, a +inf y, and a -inf y;
// every row in one cell; and a 10x10-cell cluster with one row far outside it.
const GridTestLayout = enum { one_row, spread, negative, one_cell, cluster_outlier };
const grid_test_rows: usize = 1000;
// A row with a body (`fillGridTestSnapshot` drops every seventh from row 3).
const grid_test_outlier_row: usize = grid_test_rows - 1;

// A snapshot of `grid_test_rows` rows in `layout`, every seventh row without a body.
fn fillGridTestSnapshot(system: *SteeringSystem, layout: GridTestLayout) !void {
    try system.ensureStepCapacity(grid_test_rows, 0);
    setRowCount(AgentSnapshotRow, &system.agent_snapshot_rows, grid_test_rows);
    const rows = system.agent_snapshot_rows.slice();
    system.spatial_cell_size = 20;
    var prng = std.Random.DefaultPrng.init(0x6e1d_b4d5);
    const random = prng.random();
    for (rows.items(.entity), rows.items(.x), rows.items(.y), rows.items(.world_level), 0..) |*entity, *x, *y, *level, row| {
        entity.* = if (row % 7 == 3) EntityId.invalid else try EntityId.init(@intCast(row), 1);
        level.* = 0;
        switch (layout) {
            .one_row => {
                x.* = random.float(f32) * 4000;
                y.* = 3 + random.float(f32) * 6;
            },
            .spread => {
                x.* = random.float(f32) * 120;
                y.* = random.float(f32) * 640;
            },
            .negative => {
                x.* = random.float(f32) * 120 - 300;
                y.* = -20 - random.float(f32) * 640;
                if (row == 500) y.* = std.math.nan(f32);
                if (row == 501) x.* = -std.math.inf(f32);
                if (row == 502) y.* = std.math.inf(f32);
                if (row == 503) y.* = -std.math.inf(f32);
            },
            .one_cell => {
                x.* = 1 + random.float(f32) * 18;
                y.* = 1 + random.float(f32) * 18;
            },
            .cluster_outlier => {
                x.* = random.float(f32) * 200;
                y.* = random.float(f32) * 200;
                if (row == grid_test_outlier_row) {
                    x.* = 1e6;
                    y.* = 1e6;
                }
            },
        }
    }
    std.debug.assert(rows.items(.entity)[grid_test_outlier_row].isValid());
}

// `row_count` rows with a body, alternating every `period / 2` rows between two far
// clusters; each cluster's rows fill its block of cells, 32 wide, in row order.
fn fillAlternatingClustersSnapshot(system: *SteeringSystem, row_count: usize, period: usize) !void {
    std.debug.assert(period >= 2 and period % 2 == 0);
    try system.ensureStepCapacity(row_count, 0);
    setRowCount(AgentSnapshotRow, &system.agent_snapshot_rows, row_count);
    const rows = system.agent_snapshot_rows.slice();
    system.spatial_cell_size = 20;
    const run = period / 2;
    for (rows.items(.entity), rows.items(.x), rows.items(.y), rows.items(.world_level), 0..) |*entity, *x, *y, *level, row| {
        entity.* = try EntityId.init(@intCast(row), 1);
        level.* = 0;
        const member = row / period * run + row % run;
        const cluster_y: f32 = if (row % period < run) 0 else 100_000;
        x.* = @floatFromInt(member % 32 * 20 + 10);
        y.* = cluster_y + @as(f32, @floatFromInt(member / 32 * 20 + 10));
    }
}

// The most entries any band of `system`'s grid holds.
fn largestBandEntries(system: *const SteeringSystem) usize {
    var largest: usize = 0;
    for (system.agent_grid.bands) |band| {
        var band_entries: usize = 0;
        for (system.agent_cell_ranges.items[band.start..][0..band.range_count]) |range| band_entries += range.end - range.start;
        largest = @max(largest, band_entries);
    }
    return largest;
}

// Explicit band splitter sets, each nondecreasing: all past every cell; all one occupied
// cell; occupied cells at a stride (63 distinct when the grid has as many); the i32 extremes
// around occupied cells; and occupied cells in equal pairs.
const GridTestSplitters = enum { all_max, one_cell, stride, extremes, pairs };

fn gridTestSplitters(set: GridTestSplitters, cells: []const SpatialCellRange) [max_bands - 1]CellKey {
    std.debug.assert(cells.len > 0);
    const min_key = CellKey{ .cell_y = std.math.minInt(i32), .cell_x = std.math.minInt(i32) };
    var splitters: [max_bands - 1]CellKey = @splat(max_cell_key);
    for (&splitters, 0..) |*splitter, index| {
        const pick: usize = switch (set) {
            .all_max => continue,
            .one_cell => cells.len / 2,
            .stride, .extremes => index * cells.len / (max_bands - 1),
            .pairs => (index / 2) * cells.len / (max_bands / 2),
        };
        splitter.* = .{ .cell_y = cells[pick].cell_y, .cell_x = cells[pick].cell_x };
        if (set == .extremes and index < 8) splitter.* = min_key;
        if (set == .extremes and index >= max_bands - 9) splitter.* = max_cell_key;
    }
    return splitters;
}

// A copy of a grid's entries and cell ranges.
const GridTestCells = struct {
    entries: std.ArrayList(SpatialCellEntry) = .empty,
    ranges: std.ArrayList(SpatialCellRange) = .empty,

    fn capture(system: *const SteeringSystem) !GridTestCells {
        var cells = GridTestCells{};
        errdefer cells.deinit();
        try cells.entries.appendSlice(std.testing.allocator, system.agent_cell_entries.items);
        try cells.ranges.appendSlice(std.testing.allocator, system.agent_cell_ranges.items);
        return cells;
    }

    fn deinit(self: *GridTestCells) void {
        self.ranges.deinit(std.testing.allocator);
        self.entries.deinit(std.testing.allocator);
    }
};

// `system`'s grid, looked up through its band directory, holds exactly the reference's cells,
// each with the same entries in the same order.
fn expectGridMatches(system: *const SteeringSystem, reference: *const GridTestCells) !void {
    const grid = &system.agent_grid;
    const band_count: usize = if (grid.splitter_count == 0) 1 else max_bands;
    var range_count: usize = 0;
    for (grid.bands[0..band_count]) |band| range_count += band.range_count;
    try std.testing.expectEqual(reference.ranges.items.len, range_count);
    try std.testing.expectEqualSlices(SpatialCellEntry, reference.entries.items, system.agent_cell_entries.items);
    for (reference.ranges.items) |cell| {
        const band_ranges = grid.rangesOfCell(system.agent_cell_ranges.items, cell.cell_x, cell.cell_y);
        const found = findCellRange(band_ranges, cell.cell_x, cell.cell_y) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(cell.start, found.start);
        try std.testing.expectEqual(cell.end, found.end);
    }
}

fn expectEveryStageThreaded(stats: SteeringStats) !void {
    for ([_]BatchStats{ stats.agents_batch, stats.select_resolve_batch, stats.select_claim_batch, stats.directions_batch, stats.grid_bucket_batch, stats.grid_sort_batch, stats.batch }) |batch| {
        try std.testing.expect(!batch.ran_inline);
        try std.testing.expect(batch.active_worker_threads > 0);
    }
}

// A step whose stage tuners all kept their stages inline still ran every stage job: the
// claim over its steering bands and the grid sort over every band.
fn expectTunedStagesInline(stats: SteeringStats, agent_count: usize) !void {
    for ([_]BatchStats{ stats.agents_batch, stats.select_resolve_batch, stats.select_claim_batch, stats.directions_batch, stats.grid_bucket_batch, stats.grid_sort_batch }) |batch| {
        try std.testing.expect(batch.ran_inline);
    }
    try std.testing.expectEqual(AgentBands.init(agent_count).band_count, stats.select_claim_batch.item_count);
    try std.testing.expectEqual(max_bands, stats.grid_sort_batch.item_count);
}

// A step that could give no stage a worker resolved and claimed in one pass and built the
// grid in one band, so neither the claim nor the grid sort ran.
fn expectSerialSelectionAndGrid(stats: SteeringStats) !void {
    try std.testing.expect(stats.select_resolve_batch.ran_inline and stats.grid_bucket_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), stats.select_claim_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.grid_sort_batch.item_count);
}

// An intent for `agent` (the `agent_index`th) whose direct direction is unique to the
// agent and `variant`.
fn selectionIntent(agent: EntityId, agent_index: usize, variant: usize, priority: i16) NavigationIntent {
    const angle = @as(f32, @floatFromInt(agent_index)) * 0.13 + @as(f32, @floatFromInt(variant)) * 1.7;
    return .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = @cos(angle), .direct_direction_y = @sin(angle), .priority = priority };
}

// A step's stats without batch shapes and timings, which follow the partition.
fn behaviorStats(stats: SteeringStats) SteeringStats {
    var behavior = stats;
    behavior.batch = .{};
    behavior.agents_batch = .{};
    behavior.select_resolve_batch = .{};
    behavior.select_claim_batch = .{};
    behavior.directions_batch = .{};
    behavior.grid_bucket_batch = .{};
    behavior.grid_sort_batch = .{};
    behavior.select_ns = 0;
    behavior.snapshot_ns = 0;
    behavior.directions_ns = 0;
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
    const work = system.selectedWorkSliceConst();
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
    try pathfinding.reserve(.{ .max_frame_requests = 256, .max_pending_requests = 256, .max_cached_results = 512, .max_group_fields = 4, .worker_participant_count = 1, .max_solved_requests_per_step = 256 });
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
            try system.updateSerial(&data, &frame, &pathfinding, &colliders);
        if (thread_system) |threads| {
            if (threads.workerThreadCount() == 0 or (config.max_worker_threads orelse 1) == 0) {
                try expectSerialSelectionAndGrid(stats);
            } else if (config.items_per_range == steering_range_alignment_items) {
                try expectEveryStageThreaded(stats);
            } else if (config.adaptive and config.items_per_range == null) {
                try expectTunedStagesInline(stats, data.steeringAgentSliceConst().entities.len);
            }
        }
        try expectRequestPrefixesCount(&system, stats);
        try trace.record(&frame, stats, &system);
        _ = try pathfinding.updateSerial(&frame.path_requests, agents.items.len, .{});
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
    try pathfinding.reserve(.{ .max_frame_requests = 64, .max_pending_requests = 64, .max_cached_results = 64, .max_group_fields = 1, .worker_participant_count = 1, .max_solved_requests_per_step = 64 });
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
    const first = if (thread_system) |threads| try system.update(&data, &frame, threads, &pathfinding, &colliders, config) else try system.updateSerial(&data, &frame, &pathfinding, &colliders);
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
    const second = if (thread_system) |threads| try system.update(&data, &frame, threads, &pathfinding, &colliders, config) else try system.updateSerial(&data, &frame, &pathfinding, &colliders);
    if (thread_system != null) try expectEveryStageThreaded(second);
    // Each runtime row holds its steering row's entity.
    const steering_entities = data.steeringAgentSliceConst().entities;
    try std.testing.expectEqual(steering_entities.len, system.runtime_rows.len);
    for (steering_entities, system.runtime_rows.items(.entity)) |entity, runtime_entity| try std.testing.expect(entity.eql(runtime_entity));
    for (frame.intents.mergedItems()) |merged| try outcome.movements.append(std.testing.allocator, merged.movement);
    for (frame.path_requests.mergedItems()) |request| try outcome.requesters.append(std.testing.allocator, request.entity);
    for (0..system.runtime_rows.len) |row| try outcome.runtime.append(std.testing.allocator, system.runtime_rows.get(row));
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
    const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expect(stats.obstacle_candidate_checks <= max_obstacle_work);
    return stats.obstacle_samples;
}
