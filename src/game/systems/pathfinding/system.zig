// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! PathfindingSystem orchestrator: owns the transient request queues, goal-keyed
//! caches, per-level nav graph, group flow fields, per-worker scratch, and the
//! elastic capacity policy. Drives the fixed-step accept -> group-service -> solve ->
//! publish pipeline (serial and threaded), delegating solves to solve.zig.

const std = @import("std");
const math = @import("../../../core/math.zig");
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const PathRequest = @import("../../simulation.zig").PathRequest;
const PathRequestKind = @import("../../simulation.zig").PathRequestKind;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavMemoryBudget = @import("nav_memory.zig").NavMemoryBudget;
const GroupField = @import("group_field.zig").GroupField;
const SearchScratch = @import("scratch.zig").SearchScratch;
const ResultCache = @import("caches.zig").ResultCache;
const KeySet = @import("caches.zig").KeySet;
const waypointFromPath = @import("caches.zig").waypointFromPath;
const waypointFromStitched = @import("caches.zig").waypointFromStitched;
const solve = @import("solve.zig");
const solveOne = solve.solveOne;
const solveFallbackJob = solve.solveFallbackJob;
const SolveJobContext = solve.SolveJobContext;
const types = @import("types.zig");
const PathfindingCapacity = types.PathfindingCapacity;
const PathfindingConfig = types.PathfindingConfig;
const PathfindingStats = types.PathfindingStats;
const PathView = types.PathView;
const PathQueryKey = types.PathQueryKey;
const NavCellEdit = types.NavCellEdit;
const NavUpdateStats = types.NavUpdateStats;
const PendingRequest = types.PendingRequest;
const PreparedRequest = types.PreparedRequest;
const PathSolveResult = types.PathSolveResult;
const GroupRequestTally = types.GroupRequestTally;
const StitchedCell = types.StitchedCell;
const PhaseTimer = types.PhaseTimer;
const emptyKey = types.emptyKey;
const keysEqual = types.keysEqual;
const setLen = types.setLen;
const resizeArrayList = types.resizeArrayList;
const resizeFilledArrayList = types.resizeFilledArrayList;
const no_parent = types.no_parent;
const no_cell = types.no_cell;
const min_capacity_floor = types.min_capacity_floor;
const cached_results_per_agent = types.cached_results_per_agent;
const default_max_solves_per_frame = types.default_max_solves_per_frame;
const default_cells_per_group_agent = types.default_cells_per_group_agent;
const group_field_threshold_floor = types.group_field_threshold_floor;
const default_goal_projection_radius = types.default_goal_projection_radius;
const pathfinding_range_alignment_items = types.pathfinding_range_alignment_items;

pub const PathfindingSystem = struct {
    allocator: std.mem.Allocator,
    capacity: PathfindingCapacity = .{},
    step_counter: u32 = 0,
    graph: NavGraph,
    pending: std.ArrayList(PendingRequest) = .empty,
    prepared_requests: std.ArrayList(PreparedRequest) = .empty,
    solve_results: std.ArrayList(PathSolveResult) = .empty,
    fallback_indices: std.ArrayList(usize) = .empty,
    completed: ResultCache = .{},
    unavailable: KeySet = .{},
    pending_keys: KeySet = .{},
    group_fields: std.ArrayList(GroupField) = .empty,
    // Requested group goal keys this step (declared, never detected).
    group_requests: std.ArrayList(GroupRequestTally) = .empty,
    // One per-cell A* scratch slot per configured threaded participant (workers + 1);
    // all O(cells) arrays are sized during the nav build, not lazily on first solve.
    scratch_slots: std.ArrayList(SearchScratch) = .empty,
    // Per-worker reconstructed paths, written into completed by the main thread
    // after the worker batch finishes.
    solved_paths: std.ArrayList(SolvedPath) = .empty,
    // Per-worker path pool. Each worker owns a disjoint stripe so reconstruction
    // never shares writable storage during the batch.
    worker_path_pool: std.ArrayList(u32) = .empty,
    // Per-solved-request disjoint stitched-path stripe, mirroring worker_path_pool,
    // so a worker's stitched corridor never overwrites another request's during the
    // batch. Plain local solves leave their stripe unused (stitched_len 0).
    worker_stitched_pool: std.ArrayList(StitchedCell) = .empty,
    next_group_evict: usize = 0,
    // Pre-reserved per-level affected-flag scratch for incremental nav updates. Sized
    // to the level count at rebuild so `applyNavUpdates` allocates nothing per edit on
    // the steady path; it is the main-thread post-commit reaction, never a worker.
    affected_levels: std.ArrayList(bool) = .empty,
    // Heap A* is the only worker-driven solver tier, so a single tuner owns its
    // adaptive batch profile.
    fallback_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Live agent count the per-step/memory caps are currently sized for. Elastic
    // resize keeps this tracking the steering-agent crowd: grows fast for battles,
    // shrinks slowly after sustained low load. Zero until the first reserve.
    effective_agent_capacity: usize = 0,
    // Consecutive steps the agent count has stayed below half the live capacity.
    // Shrink fires only after this reaches capacity_shrink_window (hysteresis).
    low_load_steps: u32 = 0,
    // Reusable safe-point snapshot buffers. A resize wipes the goal-keyed caches
    // (reconstructable) but preserves the non-reconstructable live deferred work and
    // group tally by round-tripping them through these. Allocated only at resize.
    resize_pending_snapshot: std.ArrayList(PendingRequest) = .empty,
    resize_group_snapshot: std.ArrayList(GroupRequestTally) = .empty,

    const SolvedPath = struct {
        key: PathQueryKey,
        offset: usize,
        len: usize,
        // Disjoint corridor stripe (offset/len into worker_stitched_pool) for this
        // solved request. Zero len means a plain local solve with no corridor.
        stitched_offset: usize = 0,
        stitched_len: usize = 0,
        // Level the stored cells index into (start level for cross-level corridors).
        path_level: u16 = 0,
        // Set when the solve routed through the abstract chunk-portal/link graph.
        via_abstract: bool = false,
        // Set when the chosen corridor crosses at least one inter-level link.
        cross_level: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) PathfindingSystem {
        return .{
            .allocator = allocator,
            .graph = .{ .allocator = allocator },
            .fallback_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *PathfindingSystem) void {
        for (self.scratch_slots.items) |*scratch| scratch.deinit(self.allocator);
        for (self.group_fields.items) |*field| field.deinit(self.allocator);
        self.resize_group_snapshot.deinit(self.allocator);
        self.resize_pending_snapshot.deinit(self.allocator);
        self.affected_levels.deinit(self.allocator);
        self.worker_stitched_pool.deinit(self.allocator);
        self.worker_path_pool.deinit(self.allocator);
        self.solved_paths.deinit(self.allocator);
        self.scratch_slots.deinit(self.allocator);
        self.group_requests.deinit(self.allocator);
        self.group_fields.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.unavailable.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.fallback_indices.deinit(self.allocator);
        self.solve_results.deinit(self.allocator);
        self.prepared_requests.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.graph.deinit();
        self.* = undefined;
    }

    // Derives the per-step/memory caps from an agent count, clamped to [floor,
    // max_agent_budget ceiling]. Population scales the QUEUE and CACHE (frame/pending
    // requests, 4n cached results) so every agent can be queued and every path
    // cached. Per-frame A* SOLVE work does NOT scale with population: the solve and
    // fallback budgets are pinned to a fixed amortization ceiling (clamped down to
    // the population so a tiny crowd caps low), so frame time stays bounded as the
    // army grows. Algorithm/memory sizing (scratch, path strides, chunk size, group
    // field count) is left untouched.
    pub fn deriveCapacity(base: PathfindingCapacity, agent_count: usize) PathfindingCapacity {
        var cap = base;
        const clamped = std.math.clamp(agent_count, min_capacity_floor, @max(min_capacity_floor, base.max_agent_budget));
        cap.max_frame_requests = clamped;
        cap.max_pending_requests = clamped;
        cap.max_cached_results = clamped *| cached_results_per_agent;
        // Fixed per-frame solve/fallback ceiling, capped down to the population (fallback
        // <= solves). Independent of crowd size; the adaptive tuner operates under it.
        const solve_ceiling = @min(default_max_solves_per_frame, clamped);
        cap.max_solved_requests_per_step = solve_ceiling;
        cap.max_fallback_requests_per_step = solve_ceiling;
        return cap;
    }

    // See default_cells_per_group_agent for the model. Capped by max_agent_budget (the
    // hard ceiling), NOT live max_pending_requests, or the small live crowd would pull
    // the threshold to demo scale. A sub-floor budget can cap below the floor; cellCount
    // 0 (no graph yet) yields the floor.
    pub fn groupFieldThreshold(self: *const PathfindingSystem) usize {
        if (self.capacity.min_group_field_agents != 0) return self.capacity.min_group_field_agents;
        const derived = self.graph.cellCount() / default_cells_per_group_agent;
        const ceiling = @max(min_capacity_floor, self.capacity.max_agent_budget);
        return @min(@max(derived, group_field_threshold_floor), ceiling);
    }

    pub fn reserve(self: *PathfindingSystem, capacity: PathfindingCapacity) !void {
        // Reserve modestly for the floor agent count, not the full ceiling, so the
        // elastic path can later grow and shrink. The ceiling/ratio/window knobs are
        // retained in self.capacity; per-step caps are derived and grown on demand.
        try self.applyDerivedCapacity(capacity, min_capacity_floor);
    }

    // Sizes every pool from caps derived for `agent_count`. Used by reserve() at init
    // and by adjustCapacityForAgentCount() at the safe point. ArrayList pools grow
    // amortized and shrink-and-free; the open-addressed caches are re-reserved (which
    // wipes them — reconstructable, and resizes are rare under hysteresis). The
    // caller is responsible for preserving any live cross-step state across the wipe.
    pub fn applyDerivedCapacity(self: *PathfindingSystem, base: PathfindingCapacity, agent_count: usize) !void {
        const capacity = deriveCapacity(base, agent_count);
        self.capacity = capacity;
        self.effective_agent_capacity = capacity.max_pending_requests;
        try resizeArrayList(PendingRequest, &self.pending, self.allocator, capacity.max_pending_requests);
        try resizeArrayList(PreparedRequest, &self.prepared_requests, self.allocator, capacity.max_frame_requests);
        try resizeArrayList(PathSolveResult, &self.solve_results, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(usize, &self.fallback_indices, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(SolvedPath, &self.solved_paths, self.allocator, capacity.max_solved_requests_per_step);
        try self.completed.reserve(self.allocator, capacity.max_cached_results, capacity.max_stored_path_cells, capacity.max_stitched_path_cells);
        try self.unavailable.reserve(self.allocator, capacity.max_cached_results);
        try self.pending_keys.reserve(self.allocator, capacity.max_pending_requests * 2);
        try self.group_fields.ensureTotalCapacity(self.allocator, capacity.max_group_fields);
        while (self.group_fields.items.len < capacity.max_group_fields) {
            self.group_fields.appendAssumeCapacity(.{});
        }
        try resizeArrayList(GroupRequestTally, &self.group_requests, self.allocator, capacity.max_solved_requests_per_step);
        // One scratch slot per threaded participant (workers + main). The configured
        // count is fixed; the slots' O(cells) arrays are sized in the nav build, not
        // lazily on first solve.
        const scratch_slots = @max(@as(usize, 1), capacity.worker_participant_count);
        try self.scratch_slots.ensureTotalCapacity(self.allocator, scratch_slots);
        while (self.scratch_slots.items.len < scratch_slots) {
            self.scratch_slots.appendAssumeCapacity(.{});
        }
        // One disjoint path stripe per solved request this step (indexed by the
        // dense fallback position), so workers never overwrite each other's
        // reconstructed paths even when one worker solves several requests.
        const pool_cells = capacity.max_solved_requests_per_step * capacity.max_stored_path_cells;
        try resizeFilledArrayList(u32, &self.worker_path_pool, self.allocator, pool_cells, no_cell);
        const pool_stitched = capacity.max_solved_requests_per_step * capacity.max_stitched_path_cells;
        try resizeFilledArrayList(StitchedCell, &self.worker_stitched_pool, self.allocator, pool_stitched, .{ .level = 0, .cell = no_cell });
    }

    // Adjusts the live capacity toward the agent count at the pre-dispatch safe
    // point: after the previous frame's results were published and before this
    // step's accept/solve, on the single thread, with no in-flight worker indices or
    // pool offsets. Grows fast (amortized ~2x) for a battle; shrinks only after a
    // sustained low-load window (hysteresis). The per-step solve loop never allocates
    // because capacity is already adequate by the time it runs.
    //
    // Index/pointer-stability invariant verified for every resized pool: at this
    // point the per-step scratch pools (prepared_requests, solve_results,
    // fallback_indices, solved_paths, worker_path_pool, worker_stitched_pool) are
    // empty/cleared from last step's prepare*, so no live offset spans the resize.
    // pending/pending_keys/group_requests/completed/unavailable hold cross-step state;
    // resize wipes the reconstructable caches and round-trips the non-reconstructable
    // pending deferred work + group tally through reusable snapshots, then rebuilds
    // pending_keys from the restored pending. The scratch_slots count is the fixed
    // configured participant count (unchanged by an elastic resize) and its per-cell
    // arrays were sized at the nav build, so this never touches them. No worker runs.
    pub fn adjustCapacityForAgentCount(self: *PathfindingSystem, agent_count: usize) !void {
        if (self.effective_agent_capacity == 0) return; // not reserved yet
        const target = deriveCapacity(self.capacity, agent_count).max_pending_requests;
        const current = self.effective_agent_capacity;
        if (target > current) {
            self.low_load_steps = 0;
            // Amortized grow: at least double, clamped to the ceiling, so one realloc
            // covers many future spawns.
            const grown = @min(@max(target, current *| 2), @max(min_capacity_floor, self.capacity.max_agent_budget));
            try self.resizePreservingLiveState(grown);
            return;
        }
        // Shrink only after the agent count stays below half capacity for the window.
        if (agent_count * 2 < current) {
            self.low_load_steps +|= 1;
            if (self.low_load_steps >= self.capacity.capacity_shrink_window) {
                self.low_load_steps = 0;
                try self.resizePreservingLiveState(target);
            }
        } else {
            self.low_load_steps = 0;
        }
    }

    // Re-sizes all pools to `agent_count` while preserving the non-reconstructable
    // live deferred-work queue and group tally. The goal-keyed caches are wiped (a
    // resize behaves like a routine cache miss; re-requests re-solve), exactly as a
    // nav rebuild already does.
    pub fn resizePreservingLiveState(self: *PathfindingSystem, agent_count: usize) !void {
        self.resize_pending_snapshot.clearRetainingCapacity();
        try self.resize_pending_snapshot.ensureTotalCapacity(self.allocator, self.pending.items.len);
        self.resize_pending_snapshot.appendSliceAssumeCapacity(self.pending.items);
        self.resize_group_snapshot.clearRetainingCapacity();
        try self.resize_group_snapshot.ensureTotalCapacity(self.allocator, self.group_requests.items.len);
        self.resize_group_snapshot.appendSliceAssumeCapacity(self.group_requests.items);

        try self.applyDerivedCapacity(self.capacity, agent_count);

        // Restore live deferred work (dropping any beyond the new, smaller capacity),
        // rebuild pending_keys to match, and restore the surviving group tally.
        self.pending.clearRetainingCapacity();
        const keep_pending = @min(self.resize_pending_snapshot.items.len, self.pending.capacity);
        self.pending.appendSliceAssumeCapacity(self.resize_pending_snapshot.items[0..keep_pending]);
        self.pending_keys.clear();
        for (self.pending.items) |pending_request| _ = self.pending_keys.insert(pending_request.key);
        self.group_requests.clearRetainingCapacity();
        const keep_group = @min(self.resize_group_snapshot.items.len, self.group_requests.capacity);
        self.group_requests.appendSliceAssumeCapacity(self.resize_group_snapshot.items[0..keep_group]);
    }

    pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) !void {
        try self.rebuildStaticNavGridWithWorld(data, null, bounds_width, bounds_height, cell_size);
    }

    pub fn rebuildStaticNavGridWithWorld(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        bounds_width: f32,
        bounds_height: f32,
        cell_size: f32,
    ) !void {
        if (self.scratch_slots.items.len == 0) {
            try self.reserve(self.capacity);
        }
        const level_count: usize = if (world) |world_system| @max(@as(usize, 1), world_system.levelCount()) else 1;
        const link_count: usize = if (world) |world_system| world_system.levelLinks().len else 0;
        const budget = NavMemoryBudget{
            .max_bytes = self.capacity.max_nav_memory_bytes,
            .level_count = level_count,
            // group field per-cell: cost(u32) + flow(u8) + stamp(u32) + the Dial's
            // bucket-queue links bucket_next/bucket_prev(u32) + queued_stamp(u32).
            .group_field_bytes_per_cell = @sizeOf(u32) + 1 + 4 * @sizeOf(u32),
            .max_group_fields = self.capacity.max_group_fields,
            .max_explored_nodes = self.capacity.max_explored_nodes,
            .max_stored_path_cells = self.capacity.max_stored_path_cells,
            .worker_participant_count = @max(@as(usize, 1), self.capacity.worker_participant_count),
            .max_cached_results = self.capacity.max_cached_results,
            .max_solved_requests_per_step = self.capacity.max_solved_requests_per_step,
            .max_stitched_path_cells = self.capacity.max_stitched_path_cells,
            .chunk_tiles = @max(@as(usize, 1), self.capacity.nav_chunk_tiles),
            .link_count = link_count,
        };
        try self.graph.rebuild(data, world, bounds_width, bounds_height, cell_size, self.capacity.nav_chunk_tiles, budget);
        // The init per-level builds (inside rebuild) grow each level's portal/edge
        // buffers to their real size; clearRetainingCapacity keeps that high-water mark.
        // A later incremental applyNavUpdates within the high-water mark allocates nothing; a
        // genuine topology expansion past it does one bounded amortized growth (a cold,
        // event-triggered main-thread path — see applyNavUpdates). No O(cells)
        // pre-reserve, so large SPARSE worlds (few portals) stay cheap and pass the gate.
        const cell_count = self.graph.cellCount();
        for (self.group_fields.items) |*field| {
            try field.reserve(self.allocator, cell_count);
        }
        // Per-cell A* scratch is O(cells) per slot. The participant count is a fixed
        // configured property, so size EVERY participant slot here as part of the build
        // (the O(cells) memset hides in this one-time build cost) — no lazy per-frame
        // sizing. Resident scratch is bounded by participant count, not any slot cap.
        // A nav rebuild with a new cell_count re-sizes all slots the same way.
        for (self.scratch_slots.items) |*scratch| {
            try scratch.reserve(self.allocator, self.capacity.max_explored_nodes, self.capacity.max_stored_path_cells, self.capacity.max_abstract_nodes, self.capacity.max_stitched_path_cells, cell_count);
        }
        // Pre-reserve the per-level affected-flag scratch so a steady-path
        // applyNavUpdates allocates nothing per edit.
        try setLen(&self.affected_levels, self.allocator, self.graph.levelCount());
        // Grid versions are part of query keys. A rebuild invalidates pending
        // work and caches instead of trying to remap old requests onto new cells.
        self.clearRuntimeState();
    }

    // Incrementally folds a batch of static-obstacle edits into the existing nav
    // graph at the main-thread post-commit reaction point (never on a worker). Only
    // affected levels' masks/components are recomputed; the abstract graph is rebuilt
    // once; `nav_version` bumps once so goal-keyed caches/pending entries re-solve.
    // Runtime request/result state is cleared (caches invalidate on the version bump),
    // while group fields are dropped to .empty so a stale field is never sampled. No
    // whole-world rebuild and no scratch reallocation occur on the steady path.
    pub fn applyNavUpdates(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        edits: []const NavCellEdit,
    ) !NavUpdateStats {
        const stats = try self.graph.applyNavUpdates(
            data,
            world,
            edits,
            &self.affected_levels,
            self.capacity.nav_full_relabel_level_threshold,
        );
        if (stats.version_bumps != 0) {
            // The version bump invalidated every goal-keyed key; drop stale work and
            // group fields so the next request re-solves against the new mask.
            self.clearTransientRequestsRetainingFields();
            for (self.group_fields.items) |*field| field.state = .empty;
            self.next_group_evict = 0;
        }
        return stats;
    }

    pub fn clearRuntimeState(self: *PathfindingSystem) void {
        self.clearTransientRequestsRetainingFields();
        // Plus drop group fields so a stale field is never sampled after a rebuild.
        for (self.group_fields.items) |*field| field.state = .empty;
        self.next_group_evict = 0;
    }

    // Clears request/result state while keeping the nav grid and group fields.
    pub fn clearTransientRequestsRetainingFields(self: *PathfindingSystem) void {
        self.pending.clearRetainingCapacity();
        self.prepared_requests.clearRetainingCapacity();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.solved_paths.clearRetainingCapacity();
        self.group_requests.clearRetainingCapacity();
        self.completed.clear();
        self.unavailable.clear();
        self.pending_keys.clear();
    }

    pub fn statusForWorld(self: *const PathfindingSystem, start_level: u16, start: math.Vec2, goal_level: u16, goal: math.Vec2, agent_class: PathAgentClass) PathView {
        const key = self.graph.keyForWorld(goal_level, goal, agent_class) orelse return .{ .status = .unavailable };
        const start_grid = self.graph.grid(start_level) orelse return .{ .status = .unavailable };
        const start_cell = start_grid.worldToCellClamped(start);
        const start_index = start_grid.indexForCell(start_cell) orelse return .{ .status = .unavailable };
        return self.statusForKeyAndStart(key, start_level, start_index);
    }

    pub fn statusForEntityWorld(self: *const PathfindingSystem, entity: EntityId, start_level: u16, start: math.Vec2, goal_level: u16, goal: math.Vec2, agent_class: PathAgentClass) PathView {
        _ = entity;
        return self.statusForWorld(start_level, start, goal_level, goal, agent_class);
    }

    pub fn statusForKey(self: *const PathfindingSystem, key: PathQueryKey) PathView {
        const goal_grid = self.graph.grid(key.goal_level) orelse return .{ .status = .unavailable };
        if (goal_grid.indexForCell(key.goal)) |goal_index| {
            return self.statusForKeyAndStart(key, key.goal_level, goal_index);
        }
        return self.statusForKeyAndStart(key, key.goal_level, 0);
    }

    // Group field first (when ready), then individual cache, then negative cache,
    // then pending. Missing means the caller may enqueue a request. The start cell
    // is interpreted on `start_level`; cached corridors derive against the level
    // their stored cells index into (start level for cross-level corridors).
    pub fn statusForKeyAndStart(self: *const PathfindingSystem, key: PathQueryKey, start_level: u16, start_index: usize) PathView {
        if (self.findGroupField(key)) |field| {
            if (field.state == .ready) {
                // The group field is built on the goal level. Sample at the agent's
                // cell when it is on that level; otherwise the field is not its
                // refinement (a cross-level agent uses the individual corridor).
                if (start_level == key.goal_level) {
                    if (self.graph.grid(key.goal_level)) |goal_grid| {
                        if (field.sample(goal_grid, start_index)) |waypoint| {
                            return .{ .status = .available, .next_waypoint = waypoint, .path_len = 2 };
                        }
                    }
                    return .{ .status = .unavailable };
                }
            }
        }
        if (self.completed.slotIndex(key)) |slot| {
            const result = self.completed.slots.items[slot].result;
            const path_grid = self.graph.grid(result.path_level) orelse return .{ .status = .unavailable };
            const path = self.completed.pathSlice(slot, result.path_len);
            // Abstract chunk/cross-level corridor: a full obstacle-aware stitched
            // (level,cell) path. Walk the run on the agent's CURRENT level cell by
            // cell (every consecutive pair is a traversable neighbor), so multi-hop
            // and cross-floor routes converge without any straight-line cut.
            if (result.stitched_len != 0) {
                const stitched = self.completed.stitchedSlice(slot, result.stitched_len);
                if (waypointFromStitched(&self.graph, stitched, start_level, start_index)) |waypoint| {
                    return .{ .status = .available, .next_waypoint = waypoint, .path_len = result.stitched_len };
                }
                // Agent's level is not yet covered by the corridor (e.g. it has not
                // reached the start-level run): steer toward the stored first cell.
                if (path.len != 0) {
                    return .{ .status = .available, .next_waypoint = path_grid.cellCenter(path[0]), .path_len = result.path_len };
                }
                return .{ .status = .unavailable };
            }
            // Plain same-component local solve: derive a forward waypoint from the
            // agent's current cell against the stored path.
            if (result.path_level == start_level) {
                if (waypointFromPath(path_grid, path, start_index)) |waypoint| {
                    return .{ .status = .available, .next_waypoint = waypoint, .path_len = result.path_len };
                }
            }
            if (path.len != 0) {
                return .{ .status = .available, .next_waypoint = path_grid.cellCenter(path[0]), .path_len = result.path_len };
            }
            return .{ .status = .unavailable };
        }
        if (self.unavailable.contains(key)) return .{ .status = .unavailable };
        if (self.pending_keys.contains(key)) return .{ .status = .pending };
        return .{ .status = .missing };
    }

    // Shared accept + group-service + solve-limit prologue for update/updateSerial.
    // Safe-point elastic resize runs single-threaded here, after last frame's publish
    // and before any accept/solve, so no live worker index or pool offset spans it.
    // A returned solve_count of 0 means no solve runs this step (caller publishes the
    // pending counts and returns).
    pub fn beginUpdate(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, stats: *PathfindingStats) !usize {
        self.step_counter +%= 1;
        try self.adjustCapacityForAgentCount(agent_count);
        var accept_timer = PhaseTimer.begin();
        stats.* = self.acceptRequests(requests.mergedItems());
        stats.accept_ns = accept_timer.lap();
        var group_timer = PhaseTimer.begin();
        self.serviceGroupFields(stats);
        stats.group_service_ns = group_timer.lap();
        return self.effectiveSolveLimit(config);
    }

    // Shared publish + compaction epilogue; finalizes the pending/deferred counts.
    pub fn finishUpdate(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        var publish_timer = PhaseTimer.begin();
        self.publishSolvedResults(solve_count, stats);
        self.compactPendingAfterSolve(solve_count);
        stats.publish_ns = publish_timer.lap();
        stats.pending_requests = self.pending.items.len;
        stats.deferred_requests = self.pending.items.len;
    }

    pub fn update(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, thread_system: *ThreadSystem, config: PathfindingConfig) !PathfindingStats {
        var stats: PathfindingStats = undefined;
        const solve_count = try self.beginUpdate(requests, agent_count, config, &stats);
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            stats.deferred_requests = self.pending.items.len;
            return stats;
        }
        var solve_timer = PhaseTimer.begin();
        var system_config = config;
        self.prepareSolveBuffers(solve_count);
        self.prepareFallbackIndices(solve_count, self.effectiveFallbackLimit(system_config), &stats);

        if (self.fallback_indices.items.len != 0) {
            if (system_config.adaptive and system_config.fallback_adaptive_tuner == null and system_config.items_per_range == null) {
                system_config.fallback_adaptive_tuner = &self.fallback_tuner;
            }
            // The configured participant count sized the per-cell scratch at the nav
            // build; this is the safety assertion that the live thread system never
            // exceeds it. No allocation here — the solve loop is allocation-free.
            const participants = thread_system.participantSlotCount();
            if (participants > self.scratch_slots.items.len) return error.PathfindingScratchCapacityExceeded;
            self.resetSolvedPaths();
            var context = SolveJobContext{ .system = self };
            stats.fallback_batch = thread_system.parallelForWithOptions(self.fallback_indices.items.len, &context, solveFallbackJob, .{
                .items_per_range = system_config.items_per_range,
                .max_worker_threads = system_config.max_worker_threads,
                .range_alignment_items = pathfinding_range_alignment_items,
                .adaptive = system_config.adaptive,
                .adaptive_tuner = system_config.fallback_adaptive_tuner,
            });
        }
        stats.solve_ns = solve_timer.lap();
        self.finishUpdate(solve_count, &stats);
        return stats;
    }

    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) !PathfindingStats {
        var stats: PathfindingStats = undefined;
        const solve_count = try self.beginUpdate(requests, agent_count, config, &stats);
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            stats.deferred_requests = self.pending.items.len;
            return stats;
        }
        var solve_timer = PhaseTimer.begin();
        self.prepareSolveBuffers(solve_count);
        self.prepareFallbackIndices(solve_count, self.effectiveFallbackLimit(config), &stats);
        if (self.fallback_indices.items.len != 0) {
            if (self.scratch_slots.items.len == 0) return error.PathfindingScratchCapacityExceeded;
            self.resetSolvedPaths();
            const scratch = &self.scratch_slots.items[0];
            for (self.fallback_indices.items, 0..) |pending_index, path_slot| {
                self.solve_results.items[pending_index] = solveOne(self, pending_index, scratch, path_slot);
            }
        }
        stats.fallback_batch = .{
            .item_count = self.fallback_indices.items.len,
            .range_count = if (self.fallback_indices.items.len == 0) 0 else 1,
            .items_per_range = self.fallback_indices.items.len,
            .range_alignment_items = pathfinding_range_alignment_items,
            .main_thread_ranges = if (self.fallback_indices.items.len == 0) 0 else 1,
            .ran_inline = true,
        };
        stats.solve_ns = solve_timer.lap();
        self.finishUpdate(solve_count, &stats);
        return stats;
    }

    pub fn resetSolvedPaths(self: *PathfindingSystem) void {
        self.solved_paths.clearRetainingCapacity();
        for (0..self.solve_results.items.len) |_| {
            self.solved_paths.appendAssumeCapacity(.{ .key = emptyKey(self.graph.version), .offset = 0, .len = 0 });
        }
    }

    // Acceptance is the only stage that mutates the pending-key set. Cached hits
    // never enter pending work. Group-declared requests are recorded so a field
    // can be (re)built lazily; they still get a per-agent fallback while building.
    pub fn acceptRequests(self: *PathfindingSystem, requests: []const PathRequest) PathfindingStats {
        var stats = PathfindingStats{};
        // Cross-step decaying accumulation: halve every carried tally before this
        // step's requests fold in, so a SUSTAINED shared goal accumulates toward the
        // threshold (~2x per-step intake at equilibrium) while a transient burst
        // decays back to zero. Runs every step (even with no requests) so a crowd
        // that stops requesting decays away. Zero-count tallies are compacted after
        // threshold-service in serviceGroupFields.
        for (self.group_requests.items) |*tally| tally.count /= 2;
        if (requests.len == 0 or !self.graph.valid()) return stats;
        self.prepareRequestKeys(requests, &stats);
        for (self.prepared_requests.items) |prepared| {
            if (prepared.kind == .group) {
                self.recordGroupRequest(prepared.key);
                // A ready group field is the authoritative answer ONLY for members
                // already on the goal level: the field is built on the goal level
                // and an off-level member cannot sample it. A ready field for an
                // off-level member must NOT short-circuit, or that member would stall
                // forever; it falls through to individual cross-level acceptance and
                // gets its own corridor across the link.
                if (prepared.start_level == prepared.key.goal_level) {
                    if (self.findGroupField(prepared.key)) |field| {
                        if (field.state == .ready) {
                            stats.group_field_samples += 1;
                            stats.duplicate_requests += 1;
                            continue;
                        }
                    }
                }
            }
            if (self.completed.find(prepared.key) != null) {
                stats.duplicate_requests += 1;
                stats.cache_hits += 1;
                stats.available_results += 1;
                continue;
            }
            if (self.unavailable.contains(prepared.key)) {
                stats.duplicate_requests += 1;
                stats.cache_hits += 1;
                stats.unavailable_results += 1;
                continue;
            }
            if (self.pending_keys.contains(prepared.key)) {
                stats.duplicate_requests += 1;
                continue;
            }
            if (self.pending.items.len >= self.capacity.max_pending_requests) {
                stats.dropped_requests += 1;
                continue;
            }
            // Nearest-open goal projection happens once at acceptance, on the GOAL
            // level, so the counter is deterministic and the worker solve reuses it.
            const goal_grid = self.graph.grid(prepared.key.goal_level);
            var goal_index: usize = no_parent;
            if (goal_grid) |grid| {
                if (grid.indexForCell(prepared.key.goal)) |index| {
                    if (grid.isBlockedIndex(index)) {
                        if (grid.projectToNearestOpen(prepared.key.goal, default_goal_projection_radius)) |projected| {
                            goal_index = projected;
                            stats.goal_projected += 1;
                        }
                    } else {
                        goal_index = index;
                    }
                }
            }
            self.pending.appendAssumeCapacity(.{
                .entity = prepared.entity,
                .key = prepared.key,
                .start_level = prepared.start_level,
                .start = prepared.start,
                .goal_index = goal_index,
            });
            _ = self.pending_keys.insert(prepared.key);
            stats.accepted_requests += 1;
        }
        stats.pending_requests = self.pending.items.len;
        return stats;
    }

    pub fn recordGroupRequest(self: *PathfindingSystem, key: PathQueryKey) void {
        for (self.group_requests.items) |*existing| {
            if (keysEqual(existing.key, key)) {
                existing.count += 1;
                return;
            }
        }
        if (self.group_requests.items.len < self.group_requests.capacity) {
            self.group_requests.appendAssumeCapacity(.{ .key = key, .count = 1 });
        }
    }

    // Builds/advances managed shared-goal flow fields for declared group goals.
    // Lazy on first request, throttled on goal-cell change, budgeted per frame.
    // The threshold is checked against the cross-step accumulator (acceptRequests),
    // so it reflects SUSTAINED shared-goal demand (~2x per-step intake at
    // equilibrium), not a single-step burst.
    pub fn serviceGroupFields(self: *PathfindingSystem, stats: *PathfindingStats) void {
        if (!self.graph.valid()) return;
        const threshold = self.groupFieldThreshold();
        // Advance any field still building, on its own goal level.
        for (self.group_fields.items) |*field| {
            field.fresh_this_step = false;
            if (field.state == .building) {
                if (self.graph.grid(field.key.goal_level)) |grid| {
                    _ = field.expand(grid, self.capacity.group_field_build_budget);
                }
            }
        }
        for (self.group_requests.items) |tally| {
            // Only build/maintain a shared flow field once sustained demand for the
            // same goal amortizes its O(cells) build. Smaller groups already took an
            // individual A* solve during acceptance, so a handful of agents never pay
            // the flow-field cost — pathfinding stays cheap at low agent counts and
            // the field engages only at crowd scale.
            if (tally.count < threshold) continue;
            self.ensureGroupField(tally.key, stats);
        }
        // Compact out tallies that decayed to zero this step (they received no new
        // request to keep them alive), so a transient crowd releases its slot.
        var i: usize = 0;
        while (i < self.group_requests.items.len) {
            if (self.group_requests.items[i].count == 0) {
                _ = self.group_requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn ensureGroupField(self: *PathfindingSystem, key: PathQueryKey, stats: *PathfindingStats) void {
        if (self.group_fields.items.len == 0) return;
        // Exact goal cell already has a field: reuse it (build is still advancing
        // if it has not finished). The goal did not cross into a new cell.
        if (self.findGroupFieldMut(key)) |field| {
            if (!field.fresh_this_step) stats.group_field_reuses += 1;
            return;
        }
        const goal_grid = self.graph.grid(key.goal_level) orelse return;
        const goal_index = goal_grid.projectToNearestOpen(key.goal, default_goal_projection_radius) orelse return;
        // Same agent class targeting a different (now stale) cell: the declared
        // goal crossed into a new nav cell. Rebuild only if throttle elapsed.
        if (self.staleGroupSlot(key)) |slot_index| {
            const field = &self.group_fields.items[slot_index];
            const elapsed = self.step_counter -% field.last_build_step;
            if (elapsed < self.capacity.group_field_rebuild_min_steps) {
                // Throttled: keep the slightly stale field for general direction.
                stats.group_field_rebuild_throttled += 1;
                return;
            }
            self.buildGroupSlot(field, key, goal_index, stats);
            return;
        }
        // Allocate an empty slot, else evict deterministically.
        for (self.group_fields.items) |*field| {
            if (field.state == .empty) {
                self.buildGroupSlot(field, key, goal_index, stats);
                return;
            }
        }
        const index = self.next_group_evict;
        self.next_group_evict = (self.next_group_evict + 1) % self.group_fields.items.len;
        const field = &self.group_fields.items[index];
        self.buildGroupSlot(field, key, goal_index, stats);
        stats.cache_evictions += 1;
    }

    pub fn buildGroupSlot(self: *PathfindingSystem, field: *GroupField, key: PathQueryKey, goal_index: usize, stats: *PathfindingStats) void {
        const grid = self.graph.grid(key.goal_level) orelse return;
        if (field.beginBuild(grid, key, goal_index, self.step_counter)) {
            _ = field.expand(grid, self.capacity.group_field_build_budget);
            field.fresh_this_step = true;
            stats.group_fields_built += 1;
        }
    }

    // A stale slot targets the same agent class/version/goal-level but a different
    // goal cell. When several such slots exist, the one whose stored goal is
    // nearest the new goal cell is chosen so rebuild selection is deterministic and
    // reuses the most relevant field rather than an arbitrary first match.
    pub fn staleGroupSlot(self: *PathfindingSystem, key: PathQueryKey) ?usize {
        var best_index: ?usize = null;
        var best_dist: i64 = std.math.maxInt(i64);
        for (self.group_fields.items, 0..) |field, index| {
            if (field.state == .empty) continue;
            if (keysEqual(field.key, key)) continue;
            if (field.key.agent_class != key.agent_class) continue;
            if (field.key.nav_version != key.nav_version) continue;
            if (field.key.goal_level != key.goal_level) continue;
            const dx: i64 = field.key.goal.x - key.goal.x;
            const dy: i64 = field.key.goal.y - key.goal.y;
            const dist = dx * dx + dy * dy;
            // Tie-break on lower slot index for full determinism.
            if (dist < best_dist or (dist == best_dist and (best_index == null or index < best_index.?))) {
                best_dist = dist;
                best_index = index;
            }
        }
        return best_index;
    }

    pub fn findGroupField(self: *const PathfindingSystem, key: PathQueryKey) ?*const GroupField {
        for (self.group_fields.items) |*field| {
            if (field.state != .empty and keysEqual(field.key, key)) return field;
        }
        return null;
    }

    pub fn findGroupFieldMut(self: *PathfindingSystem, key: PathQueryKey) ?*GroupField {
        for (self.group_fields.items) |*field| {
            if (field.state != .empty and keysEqual(field.key, key)) return field;
        }
        return null;
    }

    pub fn prepareRequestKeys(self: *PathfindingSystem, requests: []const PathRequest, stats: *PathfindingStats) void {
        self.prepared_requests.clearRetainingCapacity();
        if (!self.graph.valid()) return;
        const capacity = self.prepared_requests.capacity;
        const limit = @min(requests.len, capacity);
        stats.dropped_requests += requests.len - limit;
        // Clamp levels to the built range so a stray level never indexes out of
        // bounds; an unknown level resolves to level 0's mask (fail-safe).
        const level_count: u16 = @intCast(self.graph.levelCount());
        for (requests[0..limit]) |request| {
            const goal_level = if (request.goal_level < level_count) request.goal_level else 0;
            const start_level = if (request.start_level < level_count) request.start_level else 0;
            const goal_grid = self.graph.grid(goal_level).?;
            const start_grid = self.graph.grid(start_level).?;
            self.prepared_requests.appendAssumeCapacity(.{
                .entity = request.entity,
                .kind = request.kind,
                .start_level = start_level,
                .key = .{
                    .nav_version = self.graph.version,
                    .agent_class = request.agent_class,
                    .goal_level = goal_level,
                    .goal = goal_grid.worldToCellClamped(request.goal),
                },
                .start = start_grid.worldToCellClamped(request.start),
            });
        }
    }

    pub fn prepareSolveBuffers(self: *PathfindingSystem, solve_count: usize) void {
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        for (0..solve_count) |_| {
            self.solve_results.appendAssumeCapacity(.{ .deferred = emptyKey(self.graph.version) });
        }
    }

    pub fn effectiveSolveLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_solved_requests_per_step orelse self.capacity.max_solved_requests_per_step;
        return @min(
            self.pending.items.len,
            @min(
                @min(requested_limit, self.capacity.max_solved_requests_per_step),
                @min(self.solve_results.capacity, self.fallback_indices.capacity),
            ),
        );
    }

    pub fn effectiveFallbackLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_fallback_requests_per_step orelse self.capacity.max_fallback_requests_per_step;
        return @min(requested_limit, self.capacity.max_fallback_requests_per_step);
    }

    pub fn prepareFallbackIndices(self: *PathfindingSystem, solve_count: usize, fallback_limit: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            if (result == .deferred) {
                if (self.fallback_indices.items.len < fallback_limit) {
                    self.fallback_indices.appendAssumeCapacity(pending_index);
                } else {
                    stats.fallback_deferred_requests += 1;
                }
            }
        }
    }

    pub fn publishSolvedResults(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            switch (result) {
                .available => |key| {
                    const solved = self.solved_paths.items[pending_index];
                    const path = self.worker_path_pool.items[solved.offset .. solved.offset + solved.len];
                    const stitched = self.worker_stitched_pool.items[solved.stitched_offset .. solved.stitched_offset + solved.stitched_len];
                    self.completed.put(key, path, stitched, solved.path_level, stats);
                    stats.solved_requests += 1;
                    stats.available_results += 1;
                    if (solved.via_abstract) stats.abstract_solves += 1;
                    if (solved.cross_level) stats.cross_level_solves += 1;
                },
                .unavailable => |key| {
                    if (!self.unavailable.insert(key)) stats.cache_evictions += 1;
                    stats.solved_requests += 1;
                    stats.unavailable_results += 1;
                },
                .budget_exhausted => {
                    stats.budget_exhausted += 1;
                },
                .deferred => continue,
            }
        }
        stats.fallback_requests = self.fallback_indices.items.len;
    }

    // Deferred and budget-exhausted entries keep relative order. Solved entries
    // (available/unavailable) are removed, then pending_keys is rebuilt to match.
    pub fn compactPendingAfterSolve(self: *PathfindingSystem, solve_count: usize) void {
        if (solve_count == 0) return;
        var write_index: usize = 0;
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            const keep = switch (result) {
                .deferred, .budget_exhausted => true,
                else => false,
            };
            if (!keep) continue;
            self.pending.items[write_index] = self.pending.items[pending_index];
            write_index += 1;
        }
        for (self.pending.items[solve_count..]) |pending_request| {
            self.pending.items[write_index] = pending_request;
            write_index += 1;
        }
        self.pending.items.len = write_index;
        self.pending_keys.clear();
        for (self.pending.items) |pending_request| {
            _ = self.pending_keys.insert(pending_request.key);
        }
    }
};
