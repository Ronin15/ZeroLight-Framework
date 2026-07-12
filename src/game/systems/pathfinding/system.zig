// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! PathfindingSystem orchestrator: owns the transient request queues, goal-keyed
//! caches, per-level nav graph, group flow fields, per-worker scratch, and the
//! elastic capacity policy. Drives the fixed-step accept -> group-service -> solve ->
//! publish pipeline (serial and threaded), delegating solves to solve.zig.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../../core/math.zig");
const logging = @import("../../../core/logging.zig");
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const PathRequest = @import("../../simulation.zig").PathRequest;
const PathRequestKind = @import("../../simulation.zig").PathRequestKind;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;
const NavInvalidationReason = @import("../../simulation.zig").NavInvalidationReason;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../../data_system.zig").EntityTemplate;
const ObstacleWorldRect = @import("../../data_system.zig").ObstacleWorldRect;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavUpdateThreads = @import("nav_graph.zig").NavUpdateThreads;
const NavGrid = @import("nav_grid.zig").NavGrid;
const nav_memory = @import("nav_memory.zig");
const GroupField = @import("group_field.zig").GroupField;
const SearchScratch = @import("scratch.zig").SearchScratch;
const ResultCache = @import("caches.zig").ResultCache;
const KeySet = @import("caches.zig").KeySet;
const GroupKeyMap = @import("caches.zig").GroupKeyMap;
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
const deriveCapacity = types.deriveCapacity;
const default_cells_per_group_agent = types.default_cells_per_group_agent;
const group_field_threshold_floor = types.group_field_threshold_floor;
const default_goal_projection_radius = types.default_goal_projection_radius;
const pathfinding_range_alignment_items = types.pathfinding_range_alignment_items;

// Level entity-driven static-obstacle nav events resolve against: only level 0 sources
// DataSystem collision bodies (NavGrid.markStaticBodies' own invariant — the demo's
// entities live on the ground floor). Named once here so a future entity-level feature
// changes one site instead of a hardcoded 0 re-derived independently at every call.
const entity_nav_level: u16 = 0;

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
    // O(1) key → group_requests slot-index lookup for recordGroupRequest.
    // Kept in sync with group_requests: insert on append, remove+updateIndex on swapRemove.
    group_key_map: GroupKeyMap = .{},
    // One per-cell A* scratch slot per configured threaded participant (workers + 1);
    // all O(cells) arrays are sized during the nav build, not lazily on first solve.
    scratch_slots: std.ArrayList(SearchScratch) = .empty,
    // Per-worker reconstructed paths, written into completed by the main thread
    // after the worker batch finishes.
    solved_paths: std.ArrayList(SolvedPath) = .empty,
    // Per-worker path pool. Each worker owns a disjoint stripe so reconstruction
    // never shares writable storage during the batch. Stripe index = fallback_index
    // (dense fan-out position, not pending_index), so two requests never collide
    // even when one worker solves several in the same range.
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
    // Per-edit changed nav-cell spans driving scoped cache eviction on incremental updates.
    nav_changed_spans: std.ArrayList(types.ChangedSpan) = .empty,
    // System-owned dirty nav-cell buffer for the per-step incremental update. Producers
    // (e.g. the gameplay state's post-commit reaction) interpret structural events into
    // changed cells and push them here via markNavDirty; applyBufferedNavUpdates coalesces
    // them to a per-chunk remask and clears the buffer. Grows rather than drops, so any
    // number of simultaneous diggers/obstacle edits in one step still reach the nav graph
    // (a dropped cell would leave the graph stale against the world). Reserved at capacity
    // so typical steps are allocation-free; a large step does one bounded amortized grow.
    nav_dirty_edits: std.ArrayList(NavCellEdit) = .empty,
    // Entity-driven obstacle-rect edits for this step, already resolved to nav-cell spans (see
    // markNavObstacleRectDirty). Bounded/reserved and cleared alongside nav_dirty_edits.
    nav_dirty_cell_spans: std.ArrayList(types.ChangedSpan) = .empty,
    // Levels to remask + repatch in full this step (deduped). Used when a change cannot be
    // localized to a cell — e.g. a destroyed/toggled static obstacle whose nav cell is no
    // longer resolvable from the entity — so the whole level is re-derived from the world.
    nav_dirty_levels: std.ArrayList(u16) = .empty,
    // Heap A* is the only worker-driven solver tier, so a single tuner owns its
    // adaptive batch profile.
    fallback_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // The incremental nav update has two independently-timed threaded stages — remask + component
    // re-flood, and the abstract chunk patch — so each owns its own tuner (per docs: one tuner
    // per stage, never shared across work shapes).
    nav_remask_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    nav_patch_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Threaded nav-update control config. Production runs adaptive (the tuners decide range
    // sizing); the nav-update benchmark pins these to a FIXED partition so the adaptive tuner
    // can be measured against fixed controls (the shared cross-bench theme).
    nav_thread_adaptive: bool = true,
    nav_thread_items_per_range: ?usize = null,
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
    // Per-step scratch for pending entries rotated to the back of the queue by
    // compactPendingAfterSolve (chronic budget spillers aged out of the front window).
    rotate_back_scratch: std.ArrayList(PendingRequest) = .empty,
    // Requests dropped by an elastic SHRINK (pending/group beyond the smaller capacity).
    // Accumulated here because the shrink runs in adjustCapacityForAgentCount before
    // acceptRequests overwrites the step stats; folded into stats.dropped_requests in
    // beginUpdate and then cleared.
    resize_dropped: usize = 0,

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
        // Tuners use their field defaults (AdaptiveWorkTuner.init(.{})); no need to re-set them.
        return .{
            .allocator = allocator,
            .graph = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *PathfindingSystem) void {
        for (self.scratch_slots.items) |*scratch| scratch.deinit(self.allocator);
        for (self.group_fields.items) |*field| field.deinit(self.allocator);
        self.rotate_back_scratch.deinit(self.allocator);
        self.resize_group_snapshot.deinit(self.allocator);
        self.resize_pending_snapshot.deinit(self.allocator);
        self.affected_levels.deinit(self.allocator);
        self.nav_changed_spans.deinit(self.allocator);
        self.nav_dirty_levels.deinit(self.allocator);
        self.nav_dirty_cell_spans.deinit(self.allocator);
        self.nav_dirty_edits.deinit(self.allocator);
        self.worker_stitched_pool.deinit(self.allocator);
        self.worker_path_pool.deinit(self.allocator);
        self.solved_paths.deinit(self.allocator);
        self.scratch_slots.deinit(self.allocator);
        self.group_requests.deinit(self.allocator);
        self.group_key_map.deinit(self.allocator);
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

    // Sizes every pool from caps derived for `agent_count`. Used by reserve() at init and
    // by adjustCapacityForAgentCount() at the safe point. ArrayList pools grow amortized
    // and shrink-and-free; the open-addressed caches are re-reserved (which wipes them —
    // reconstructable, and resizes are rare under hysteresis). The caller is responsible
    // for preserving any live cross-step state across the wipe.
    fn applyDerivedCapacity(self: *PathfindingSystem, base: PathfindingCapacity, agent_count: usize) !void {
        const capacity = deriveCapacity(base, agent_count);
        self.capacity = capacity;
        self.effective_agent_capacity = capacity.max_pending_requests;
        try resizeArrayList(PendingRequest, &self.pending, self.allocator, capacity.max_pending_requests);
        try resizeArrayList(PreparedRequest, &self.prepared_requests, self.allocator, capacity.max_frame_requests);
        try resizeArrayList(PathSolveResult, &self.solve_results, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(usize, &self.fallback_indices, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(SolvedPath, &self.solved_paths, self.allocator, capacity.max_solved_requests_per_step);
        // Sized to the solve window: at most one front-window entry per solved slot can be
        // rotated to the back in a single compaction.
        try resizeArrayList(PendingRequest, &self.rotate_back_scratch, self.allocator, capacity.max_solved_requests_per_step);
        // Logical capacity only: every ProbeTable/ResultCache reserve internally doubles
        // physical slots for probe headroom, so callers pass the true entry-count ceiling,
        // never a caller-side multiplier (one load-factor policy, not two stacked).
        try self.completed.reserve(self.allocator, capacity.max_cached_results, capacity.max_stored_path_cells, capacity.max_stitched_path_cells);
        try self.unavailable.reserve(self.allocator, capacity.max_cached_results);
        try self.pending_keys.reserve(self.allocator, capacity.max_pending_requests);
        try self.group_fields.ensureTotalCapacity(self.allocator, capacity.max_group_fields);
        while (self.group_fields.items.len < capacity.max_group_fields) {
            self.group_fields.appendAssumeCapacity(.{});
        }
        try resizeArrayList(GroupRequestTally, &self.group_requests, self.allocator, capacity.max_solved_requests_per_step);
        try self.group_key_map.reserve(self.allocator, capacity.max_solved_requests_per_step);
        // Pre-reserve the changed-span scratch so steady-path scoped eviction is alloc-free.
        try self.nav_changed_spans.ensureTotalCapacity(self.allocator, capacity.max_frame_requests);
        // Pre-reserve the dirty nav-cell buffer to the same steady-path high-water; it still
        // grows (never drops) for an unusually large structural step.
        try self.nav_dirty_edits.ensureTotalCapacity(self.allocator, capacity.max_frame_requests);
        // 2x nav_dirty_edits's bound: reactToPostCommitNavEvents's component_changed handling
        // appends up to two spans per structural change (old_obstacle_world_rect and
        // new_obstacle_world_rect) whenever a moving entity stays a static nav obstacle
        // across the change, not just one.
        try self.nav_dirty_cell_spans.ensureTotalCapacity(self.allocator, capacity.max_frame_requests * 2);
        // Deduped whole-level dirty set: at most one entry per level. Pre-reserve a
        // fixed small ceiling independent of map size so steady-path level marks are
        // allocation-free; grows on demand for an unusually multi-level world.
        try self.nav_dirty_levels.ensureTotalCapacity(self.allocator, @max(capacity.nav_full_relabel_level_threshold, @as(usize, 8)));
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
    fn adjustCapacityForAgentCount(self: *PathfindingSystem, agent_count: usize) !void {
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
    fn resizePreservingLiveState(self: *PathfindingSystem, agent_count: usize) !void {
        self.resize_pending_snapshot.clearRetainingCapacity();
        try self.resize_pending_snapshot.ensureTotalCapacity(self.allocator, self.pending.items.len);
        self.resize_pending_snapshot.appendSliceAssumeCapacity(self.pending.items);
        self.resize_group_snapshot.clearRetainingCapacity();
        try self.resize_group_snapshot.ensureTotalCapacity(self.allocator, self.group_requests.items.len);
        self.resize_group_snapshot.appendSliceAssumeCapacity(self.group_requests.items);

        try self.applyDerivedCapacity(self.capacity, agent_count);

        // Restore live deferred work (dropping any beyond the new, smaller capacity),
        // rebuild pending_keys to match, and restore the surviving group tally. Clamped to
        // the LOGICAL caps applyDerivedCapacity just installed (self.capacity.*), not the
        // ArrayList's own physical .capacity: the allocator's size-class rounding can hand
        // back a physical capacity well above the requested logical one, and pending_keys/
        // group_key_map were reserved to the exact logical cap — retaining more entries in
        // `pending`/`group_requests` than that would silently drop their dedup registration
        // (a live entry that reads back `.missing` instead of `.pending`, inviting a
        // duplicate accept) while resize_dropped undercounts the real loss.
        self.pending.clearRetainingCapacity();
        const keep_pending = @min(self.resize_pending_snapshot.items.len, self.capacity.max_pending_requests);
        self.pending.appendSliceAssumeCapacity(self.resize_pending_snapshot.items[0..keep_pending]);
        self.pending_keys.clear();
        for (self.pending.items) |pending_request| _ = self.pending_keys.insert(pending_request.key);
        self.group_requests.clearRetainingCapacity();
        const keep_group = @min(self.resize_group_snapshot.items.len, self.capacity.max_solved_requests_per_step);
        self.group_requests.appendSliceAssumeCapacity(self.resize_group_snapshot.items[0..keep_group]);
        // Rebuild the group key map to match the restored group_requests entries.
        self.group_key_map.clear();
        for (self.group_requests.items, 0..) |tally, idx| _ = self.group_key_map.insert(tally.key, idx);
        // A shrink that drops live deferred work / group tally past the smaller capacity is
        // a real loss of accepted requests; surface it instead of dropping silently.
        self.resize_dropped += (self.resize_pending_snapshot.items.len - keep_pending) +
            (self.resize_group_snapshot.items.len - keep_group);
    }

    pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) !void {
        try self.rebuildStaticNavGridWithWorld(data, null, bounds_width, bounds_height, cell_size, null);
    }

    pub fn rebuildStaticNavGridWithWorld(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        bounds_width: f32,
        bounds_height: f32,
        cell_size: f32,
        thread_system: ?*ThreadSystem,
    ) !void {
        if (self.scratch_slots.items.len == 0) {
            try self.reserve(self.capacity);
        }
        const level_count: usize = if (world) |world_system| @max(@as(usize, 1), world_system.levelCount()) else 1;
        const link_count: usize = if (world) |world_system| world_system.levelLinks().len else 0;
        // Gates against the elastic-CEILING caps (see budgetForCapacity), so a later
        // adjustCapacityForAgentCount growth can never reserve past the admitted budget.
        const budget = nav_memory.budgetForCapacity(self.capacity, level_count, link_count);
        try self.graph.rebuild(data, world, bounds_width, bounds_height, cell_size, self.capacity.nav_chunk_tiles, budget, thread_system);
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
        // A rebuild can change cell/chunk counts and thus the per-item work cost, so the
        // adaptive tuners' learned profiles no longer apply — reset them to relearn against
        // the new topology rather than acting on a stale cost model.
        self.fallback_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_remask_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_patch_tuner = AdaptiveWorkTuner.init(.{});
    }

    // Incrementally folds a batch of static-obstacle edits into the existing nav
    // graph at the main-thread post-commit reaction point (never on a worker). Only
    // affected levels' masks/components are recomputed; the abstract graph is rebuilt
    // once; `nav_version` bumps once so goal-keyed caches/pending entries re-solve.
    // Runtime request/result state is cleared (caches invalidate on the version bump),
    // while group fields are dropped to .empty so a stale field is never sampled. No
    // whole-world rebuild and no scratch reallocation occur on the steady path.
    // Serial incremental update over an explicit edit slice (tests, bench, direct callers).
    // Production uses the buffered path, which can thread the chunk patch.
    pub fn applyNavUpdates(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: *const WorldSystem,
        edits: []const NavCellEdit,
    ) !NavUpdateStats {
        return self.applyNavUpdatesImpl(data, world, edits, &.{}, &.{}, null);
    }

    fn applyNavUpdatesImpl(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: *const WorldSystem,
        edits: []const NavCellEdit,
        cell_edits: []const types.ChangedSpan,
        full_level_ids: []const u16,
        thread_system: ?*ThreadSystem,
    ) !NavUpdateStats {
        // The incremental update has two per-stage threaded processors (remask/re-flood and the
        // abstract patch), each fanned across workers by its own tuner: small digs run inline,
        // dig-storms thread. No fixed budget — the tuners are the work-sizing policy.
        const update_threads: ?NavUpdateThreads = if (thread_system) |ts|
            .{
                .thread_system = ts,
                .remask_tuner = &self.nav_remask_tuner,
                .patch_tuner = &self.nav_patch_tuner,
                .adaptive = self.nav_thread_adaptive,
                .items_per_range = self.nav_thread_items_per_range,
            }
        else
            null;
        const stats = try self.graph.applyNavUpdates(
            data,
            world,
            edits,
            cell_edits,
            full_level_ids,
            &self.affected_levels,
            self.capacity.nav_full_relabel_level_threshold,
            update_threads,
        );
        if (stats.version_bumps != 0) {
            // Full rebuild bumped nav_version: blunt-invalidate all work and group fields.
            self.clearTransientRequestsRetainingFields();
            self.dropGroupFields();
        } else if (stats.incremental_rebuilds != 0) {
            if (full_level_ids.len != 0) {
                // A whole-level remask is not bounded by edit spans, so scoped eviction cannot
                // find every stale path. Drop the entire completed cache instead. Graph node ids
                // are unchanged (no topology rebuild), so nav_version stays stable.
                self.completed.clear();
            } else {
                // Incremental edit: evict only cached paths that cross the changed cells.
                try self.evictCachedPathsCrossingEdits(world, edits, cell_edits);
            }
            // Short-lived pending/unavailable/group state is dropped and rebuilt.
            self.clearRequestStateKeepingCompleted();
            self.dropGroupFields();
        }
        return stats;
    }

    // Clears the system-owned dirty nav-cell buffer. Call once before a step's marking pass so
    // an error path that skips the apply never leaks stale edits into the next step.
    pub fn clearNavDirty(self: *PathfindingSystem) void {
        self.nav_dirty_edits.clearRetainingCapacity();
        self.nav_dirty_cell_spans.clearRetainingCapacity();
        self.nav_dirty_levels.clearRetainingCapacity();
    }

    // Records one changed nav cell for the next incremental update. Grows the buffer rather
    // than dropping: applyBufferedNavUpdates coalesces cells to a per-chunk remask, and a
    // dropped cell would leave the nav graph stale against the world.
    pub fn markNavDirty(self: *PathfindingSystem, level: u16, x: u16, y: u16) !void {
        try self.nav_dirty_edits.append(self.allocator, .{ .level = level, .x = x, .y = y });
    }

    // Records one entity-driven static-obstacle world-space rect for the next incremental
    // update, resolved to a nav-cell span immediately so the buffered batch never re-derives
    // it from a stale entity. A no-op when `level` has no built grid. Grows the buffer rather
    // than dropping, matching markNavDirty.
    pub fn markNavObstacleRectDirty(self: *PathfindingSystem, level: u16, rect: ObstacleWorldRect) !void {
        const grid = self.graph.grid(level) orelse return;
        const span = grid.cellSpanForWorldRect(rect.min_x, rect.min_y, rect.max_x, rect.max_y);
        try self.nav_dirty_cell_spans.append(self.allocator, .{ .level = level, .span = span });
    }

    // Records one exclusive world-tile rect (e.g. a `world_obstacle_changed` event) as a
    // single nav-cell span — O(1) append, not an O(tiles) NavCellEdit expand. A no-op when
    // the rect is empty, fully out of world bounds, or `level` has no built grid. Partial
    // overlap clamps to the world (mirrors perception dirty-rect clamping) so an
    // overshooting max corner still dirties the in-bounds portion. Grows rather than
    // dropping, matching markNavDirty / markNavObstacleRectDirty.
    pub fn markNavTileRectDirty(
        self: *PathfindingSystem,
        world: *const WorldSystem,
        level: u16,
        min_x: u16,
        min_y: u16,
        max_x_exclusive: u16,
        max_y_exclusive: u16,
    ) !void {
        // Clamp both ends to world so a rect that straddles the edge still dirties the
        // in-bounds slice; a fully OOB or inverted rect becomes empty and no-ops.
        const clamped_min_x = @min(min_x, world.width);
        const clamped_min_y = @min(min_y, world.height);
        const clamped_max_x = @min(max_x_exclusive, world.width);
        const clamped_max_y = @min(max_y_exclusive, world.height);
        if (clamped_min_x >= clamped_max_x or clamped_min_y >= clamped_max_y) return;
        // Corners are in-bounds by construction after the clamp above.
        const min_rect = world.cellRect(clamped_min_x, clamped_min_y) orelse return;
        const max_rect = world.cellRect(clamped_max_x - 1, clamped_max_y - 1) orelse return;
        try self.markNavObstacleRectDirty(level, .{
            .min_x = min_rect.x,
            .min_y = min_rect.y,
            .max_x = max_rect.x + max_rect.w,
            .max_y = max_rect.y + max_rect.h,
        });
    }

    // Marks a whole level for re-derivation next update. Use when a change cannot be reduced to
    // specific cells (e.g. a destroyed static obstacle whose nav cell is no longer resolvable):
    // the level's mask/components and abstract layer are rebuilt from the world. Deduped.
    // Steady-path marks (within the reserve ceiling) use appendAssumeCapacity so they stay
    // allocation-free after reserve; an unusually multi-level world grows past that ceiling.
    pub fn markNavLevelDirty(self: *PathfindingSystem, level: u16) !void {
        for (self.nav_dirty_levels.items) |existing| {
            if (existing == level) return;
        }
        if (self.nav_dirty_levels.items.len < self.nav_dirty_levels.capacity) {
            self.nav_dirty_levels.appendAssumeCapacity(level);
        } else {
            try self.nav_dirty_levels.append(self.allocator, level);
        }
    }

    // Defensive fallback for reactToPostCommitNavEvents: an entity-driven obstacle event that
    // invalidates navigation but carries no resolvable world-space rect. Should be unreachable
    // (isStaticNavigationObstacle requires movement_body + collision_bounds + collision_response,
    // exactly what staticObstacleWorldRect needs), so this is loud rather than a silent whole-level
    // rebuild, matching the edge-cap-fallback warn pattern in nav_graph.zig.
    fn markNavLevelDirtyWithFallbackWarn(self: *PathfindingSystem, level: u16) !void {
        if (comptime logging.enabled(.warn) and !builtin.is_test)
            logging.game.warn("nav obstacle invalidation with no resolvable world rect; falling back to whole-level dirty (level {})", .{level});
        try self.markNavLevelDirty(level);
    }

    // Whether any dirty nav cell, obstacle rect, or whole-level request is buffered for this step.
    pub fn hasPendingNavUpdates(self: *const PathfindingSystem) bool {
        return self.nav_dirty_edits.items.len != 0 or self.nav_dirty_cell_spans.items.len != 0 or self.nav_dirty_levels.items.len != 0;
    }

    // Applies the buffered dirty nav cells, obstacle rects, and whole-level requests as one
    // incremental update, then clears the buffers. Returns zero stats when nothing is
    // buffered. A non-null thread_system lets the chunk patch thread (tuner-gated); null keeps
    // it serial.
    pub fn applyBufferedNavUpdates(self: *PathfindingSystem, data: *const DataSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !NavUpdateStats {
        const stats = try self.applyNavUpdatesImpl(data, world, self.nav_dirty_edits.items, self.nav_dirty_cell_spans.items, self.nav_dirty_levels.items, thread_system);
        self.nav_dirty_edits.clearRetainingCapacity();
        self.nav_dirty_cell_spans.clearRetainingCapacity();
        self.nav_dirty_levels.clearRetainingCapacity();
        return stats;
    }

    // Reacts to committed structural events: interprets nav-invalidating world/obstacle changes
    // into dirty nav cells, folds them into the existing nav graph incrementally (affected levels
    // only), and emits one nav_region_invalidated domain-reaction event when the graph actually
    // changed. Cell-localizable tile/obstacle edits forward one dirty cell each; entity-driven
    // changes resolve their carried world-space rect to a nav-cell span and patch only the
    // affected chunks, same as tile edits. Returns the batch stats (zero when nothing was pending).
    //
    // Deliberately does NOT clear the dirty buffers at entry: applyBufferedNavUpdates only
    // clears them after a successful apply (see its doc comment), so an error here (e.g. this
    // function's own `try` on ensureCanAppend, or a propagated applyNavUpdatesImpl failure)
    // leaves this step's marks in the buffer for the NEXT call's marking pass to union with and
    // retry — matching the buffer's own "grows rather than drops" contract across a failed step,
    // not just within one. Re-applying an already-applied cell is always safe (a nav-cell edit
    // re-derives its blocked state from current data/world, never from a stale snapshot), so the
    // union is never wrong, only possibly redundant.
    pub fn reactToPostCommitNavEvents(self: *PathfindingSystem, frame: *SimulationFrame, data: *const DataSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !NavUpdateStats {
        for (frame.events.mergedItems()) |event| {
            if (event.stage != .structural_commit) continue;
            if (!eventInvalidatesNavigation(event)) continue;
            switch (event.payload) {
                .world_tile_changed => |changed| try self.markNavDirty(changed.level, changed.x, changed.y),
                // One ChangedSpan covering the exclusive tile rect — not an O(tiles)
                // NavCellEdit loop (markNavObstacleRectDirty path). Empty rects no-op.
                .world_obstacle_changed => |changed| try self.markNavTileRectDirty(
                    world,
                    changed.level,
                    changed.min_x,
                    changed.min_y,
                    changed.max_x_exclusive,
                    changed.max_y_exclusive,
                ),
                .entity_destroyed => |destroyed| {
                    if (destroyed.obstacle_world_rect) |rect| {
                        try self.markNavObstacleRectDirty(entity_nav_level, rect);
                    } else {
                        try self.markNavLevelDirtyWithFallbackWarn(entity_nav_level);
                    }
                },
                .component_changed => |changed| {
                    if (changed.old_obstacle_world_rect) |rect| {
                        try self.markNavObstacleRectDirty(entity_nav_level, rect);
                    } else if (changed.was_static_navigation_obstacle) {
                        try self.markNavLevelDirtyWithFallbackWarn(entity_nav_level);
                    }
                    if (changed.new_obstacle_world_rect) |rect| {
                        try self.markNavObstacleRectDirty(entity_nav_level, rect);
                    } else if (changed.is_static_navigation_obstacle) {
                        try self.markNavLevelDirtyWithFallbackWarn(entity_nav_level);
                    }
                },
                else => {},
            }
        }

        if (!self.hasPendingNavUpdates()) return .{};
        try frame.events.ensureCanAppend(1);
        const stats = try self.applyBufferedNavUpdates(data, world, thread_system);
        // Only signal invalidation when the batch actually changed the graph: an incremental dig
        // keeps nav_version stable, so gate on real work too, not just a full-rebuild version bump.
        if (stats.version_bumps == 0 and stats.incremental_rebuilds == 0) return stats;
        try frame.events.appendRequired(.{
            .stage = .domain_reaction,
            .payload = .{ .nav_region_invalidated = .{ .reason = NavInvalidationReason.static_obstacle_changed } },
        });
        return stats;
    }

    // Whether a committed structural event affects the static navigation graph.
    pub fn eventInvalidatesNavigation(event: SimulationEvent) bool {
        switch (event.payload) {
            .entity_destroyed => |destroyed| return destroyed.was_static_navigation_obstacle,
            .component_changed => |changed| switch (changed.component) {
                .movement_body, .collision_bounds => return changed.was_static_navigation_obstacle or changed.is_static_navigation_obstacle,
                .collision_response => return changed.was_static_navigation_obstacle != changed.is_static_navigation_obstacle,
                else => return false,
            },
            .world_tile_changed => |changed| return changed.old_blocks_movement != changed.new_blocks_movement,
            .world_obstacle_changed => return true,
            else => return false,
        }
    }

    // Whether any queued structural-commit event will drive a post-commit nav invalidation.
    // Mirrors reactToPostCommitNavEvents's stage/payload filter so a caller can reserve the one
    // appended event before mutation.
    pub fn pendingEventsMayInvalidateNavigation(frame: *const SimulationFrame) bool {
        for (frame.events.mergedItems()) |event| {
            if (event.stage != .structural_commit) continue;
            if (eventInvalidatesNavigation(event)) return true;
        }
        return false;
    }

    // Whether any pending structural command may invalidate navigation once applied.
    pub fn structuralCommandsMayInvalidateNavigation(data: *const DataSystem, frame: *const SimulationFrame) bool {
        for (frame.structural_commands.mergedItems()) |command| {
            if (structuralCommandMayInvalidateNavigation(data, command)) return true;
        }
        return false;
    }

    pub fn structuralCommandMayInvalidateNavigation(data: *const DataSystem, command: StructuralCommand) bool {
        return switch (command) {
            .create_entity => |template| templateCreatesStaticNavigationObstacle(template),
            .destroy_entity => |entity| data.isStaticNavigationObstacle(entity),
            .set_movement_body => |set| data.isAlive(set.entity),
            .set_collision_bounds => |set| data.isAlive(set.entity),
            .set_collision_response => |set| data.isAlive(set.entity),
            else => false,
        };
    }

    pub fn templateCreatesStaticNavigationObstacle(template: EntityTemplate) bool {
        const response = template.collision_response orelse return false;
        return response.mobility == .static and
            template.movement_body != null and
            template.collision_bounds != null;
    }

    // Evicts cached paths crossing this batch's changed-cell spans (tile edits plus
    // entity-driven obstacle-rect edits, already resolved to nav-cell spans).
    fn evictCachedPathsCrossingEdits(self: *PathfindingSystem, world: *const WorldSystem, edits: []const NavCellEdit, cell_edits: []const types.ChangedSpan) !void {
        try self.nav_changed_spans.ensureTotalCapacity(self.allocator, edits.len + cell_edits.len);
        self.nav_changed_spans.clearRetainingCapacity();
        for (edits) |edit| {
            const grid = self.graph.grid(edit.level) orelse continue;
            const span = grid.navSpanForTile(world, edit) orelse continue;
            self.appendChangedSpanWithHalo(edit.level, span, grid.width, grid.height);
        }
        for (cell_edits) |edit| {
            const grid = self.graph.grid(edit.level) orelse continue;
            self.appendChangedSpanWithHalo(edit.level, edit.span, grid.width, grid.height);
        }
        self.completed.evictCrossing(&self.graph, self.nav_changed_spans.items);
    }

    // One-cell halo: also evicts paths running ALONGSIDE the change so an agent beside a
    // newly-opened cell re-solves into the opening. Shared by the tile-edit and entity-driven
    // cell-edit passes above.
    fn appendChangedSpanWithHalo(self: *PathfindingSystem, level: u16, span: types.NavSpan, grid_width: usize, grid_height: usize) void {
        self.nav_changed_spans.appendAssumeCapacity(.{ .level = level, .span = .{
            .min_x = span.min_x -| 1,
            .min_y = span.min_y -| 1,
            .max_x = @min(span.max_x + 1, grid_width - 1),
            .max_y = @min(span.max_y + 1, grid_height - 1),
        } });
    }

    fn dropGroupFields(self: *PathfindingSystem) void {
        for (self.group_fields.items) |*field| field.state = .empty;
        self.next_group_evict = 0;
    }

    pub fn clearRuntimeState(self: *PathfindingSystem) void {
        self.clearTransientRequestsRetainingFields();
        // Plus drop group fields so a stale field is never sampled after a rebuild.
        self.dropGroupFields();
    }

    // Clears request/result state while keeping the nav grid and group fields.
    pub fn clearTransientRequestsRetainingFields(self: *PathfindingSystem) void {
        self.clearRequestStateKeepingCompleted();
        self.completed.clear();
    }

    // Clears short-lived request/result state but keeps the result cache for scoped eviction.
    fn clearRequestStateKeepingCompleted(self: *PathfindingSystem) void {
        self.pending.clearRetainingCapacity();
        self.prepared_requests.clearRetainingCapacity();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.solved_paths.clearRetainingCapacity();
        self.group_requests.clearRetainingCapacity();
        self.group_key_map.clear();
        self.unavailable.clear();
        self.pending_keys.clear();
    }

    // `waypoint_hint` (optional, in/out) is the caller's per-agent last-matched path
    // index; it lets the waypoint derivation probe a small forward window before a full
    // path scan. Pass null to skip the hint (full scan every call).
    pub fn statusForWorld(self: *const PathfindingSystem, start_level: u16, start: math.Vec2, goal_level: u16, goal: math.Vec2, agent_class: PathAgentClass, waypoint_hint: ?*u32) PathView {
        const key = self.graph.keyForWorld(goal_level, goal, agent_class) orelse return .{ .status = .unavailable };
        const start_grid = self.graph.grid(start_level) orelse return .{ .status = .unavailable };
        const start_cell = start_grid.worldToCellClamped(start);
        const start_index = start_grid.indexForCell(start_cell) orelse return .{ .status = .unavailable };
        return self.statusForKeyAndStart(key, start_level, start_index, waypoint_hint);
    }

    // Group field first (when ready), then individual cache, then negative cache,
    // then pending. Missing means the caller may enqueue a request. The start cell
    // is interpreted on `start_level`; cached corridors derive against the level
    // their stored cells index into (start level for cross-level corridors).
    fn statusForKeyAndStart(self: *const PathfindingSystem, key: PathQueryKey, start_level: u16, start_index: usize, waypoint_hint: ?*u32) PathView {
        if (self.findGroupField(key)) |field| {
            if (field.state == .ready and start_level == key.goal_level) {
                // The group field is built on the goal level; sample at the agent's cell.
                if (self.graph.grid(key.goal_level)) |goal_grid| {
                    if (field.sample(goal_grid, start_index)) |waypoint| {
                        return .{ .status = .available, .next_waypoint = waypoint, .path_len = 2 };
                    }
                }
                // Sample miss (or no grid): the field simply does not cover this cell (e.g. a
                // same-level but different-component agent) — not a definitive negative. Fall
                // through to the individual cache/pending/negative-cache path below, mirroring
                // the cross-level agent's exemption: an individual abstract-corridor solve may
                // still reach the goal via a link this level-local field never routes through.
            }
        }
        if (self.completed.freshSlotIndex(key, self.step_counter, types.default_cache_ttl_steps)) |slot| {
            const result = self.completed.resultAt(slot);
            const path_grid = self.graph.grid(result.path_level) orelse return .{ .status = .unavailable };
            const path = self.completed.pathSlice(slot, result.path_len);
            // Abstract chunk/cross-level corridor: a full obstacle-aware stitched
            // (level,cell) path. Walk the run on the agent's CURRENT level cell by
            // cell (every consecutive pair is a traversable neighbor), so multi-hop
            // and cross-floor routes converge without any straight-line cut.
            if (result.stitched_len != 0) {
                const stitched = self.completed.stitchedSlice(slot, result.stitched_len);
                if (waypointFromStitched(&self.graph, stitched, start_level, start_index, waypoint_hint)) |waypoint| {
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
                if (waypointFromPath(path_grid, path, start_index, waypoint_hint)) |waypoint| {
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
    fn beginUpdate(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, stats: *PathfindingStats) !usize {
        self.step_counter +%= 1;
        try self.adjustCapacityForAgentCount(agent_count);
        var accept_timer = PhaseTimer.begin();
        stats.* = self.acceptRequests(requests.mergedItems());
        // Fold in any requests an elastic shrink dropped (it ran before acceptRequests
        // reset the step stats), then clear the accumulator.
        stats.dropped_requests += self.resize_dropped;
        self.resize_dropped = 0;
        stats.accept_ns = accept_timer.lap();
        var group_timer = PhaseTimer.begin();
        self.serviceGroupFields(stats);
        stats.group_service_ns = group_timer.lap();
        // Diagnostic only: how many DISTINCT group keys were tallied this step, after
        // decay/compaction. Distinguishes "one goal whose build never catches up" (this
        // stays 1) from "several competing goals thrashing the group_fields slot table"
        // (this stays near/above max_group_fields) when reading a live capture.
        stats.distinct_group_keys = self.group_requests.items.len;
        return self.effectiveSolveLimit(config);
    }

    // Shared solve prologue for update/updateSerial: runs beginUpdate and handles the
    // no-solve early-out. Returns the solve count, or null when no solve runs this step (the
    // caller publishes the pending counts via `stats` and returns it unchanged).
    fn beginSolve(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, stats: *PathfindingStats) !?usize {
        const solve_count = try self.beginUpdate(requests, agent_count, config, stats);
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            stats.deferred_requests = self.pending.items.len;
            return null;
        }
        return solve_count;
    }

    // Shared publish + compaction epilogue; finalizes the pending/deferred counts.
    pub fn finishUpdate(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        var publish_timer = PhaseTimer.begin();
        self.publishSolvedResults(solve_count, stats);
        self.compactPendingAfterSolve(solve_count, stats);
        stats.publish_ns = publish_timer.lap();
        stats.pending_requests = self.pending.items.len;
        stats.deferred_requests = self.pending.items.len;
        // Aggregate this step's worst per-worker stitch segment usage (see
        // SearchScratch.max_stitch_segments_used), then clear each worker's counter so
        // next step's aggregation reflects only next step's solves.
        for (self.scratch_slots.items) |*scratch| {
            if (scratch.max_stitch_segments_used > stats.max_stitch_segments_observed) {
                stats.max_stitch_segments_observed = scratch.max_stitch_segments_used;
            }
            scratch.max_stitch_segments_used = 0;
        }
    }

    pub fn update(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, thread_system: *ThreadSystem, config: PathfindingConfig) !PathfindingStats {
        var stats: PathfindingStats = undefined;
        const solve_count = (try self.beginSolve(requests, agent_count, config, &stats)) orelse return stats;
        var solve_timer = PhaseTimer.begin();
        var system_config = config;
        self.prepareSolvePhase(solve_count, self.effectiveFallbackLimit(system_config), &stats);

        if (self.fallback_indices.items.len != 0) {
            if (system_config.adaptive and system_config.fallback_adaptive_tuner == null and system_config.items_per_range == null) {
                system_config.fallback_adaptive_tuner = &self.fallback_tuner;
            }
            // The configured participant count sized the per-cell scratch at the nav
            // build. In a correct configuration scratch is sized to participantSlotCount
            // (the app/bench reserve with it), so the clamp below is a no-op. A Debug-gated
            // assert (never lowered to `unreachable` in ReleaseFast, unlike a plain
            // std.debug.assert) catches a reserve/thread-system mismatch loudly during
            // development; a release build silently clamps the worker fan-out to the
            // reserved scratch (below) so worker indices stay in range and pathfinding
            // degrades to fewer workers rather than failing the frame. The warn is dropped:
            // it sat on the per-fixed-step path and would spam every step under a
            // misconfiguration whose inputs are step-invariant. Scratch is never grown past
            // the memory-budgeted count, and the solve loop stays allocation-free.
            if (builtin.mode == .Debug) std.debug.assert(thread_system.participantSlotCount() <= self.scratch_slots.items.len);
            const max_workers_for_scratch = self.scratch_slots.items.len -| 1;
            const scratch_clamped_workers = if (system_config.max_worker_threads) |requested|
                @min(requested, max_workers_for_scratch)
            else
                max_workers_for_scratch;
            self.resetSolvedPaths();
            // Pre-select so the job context can dual-assert range.index against
            // the dispatched range count (mirror affect.zig / collision.zig). Mirrors
            // parallelForWithOptions' `adaptive_tuner orelse &self.adaptive_tuner` fallback.
            const selection = thread_system.selectBatchProfile(system_config.fallback_adaptive_tuner orelse &thread_system.adaptive_tuner, .{
                .item_count = self.fallback_indices.items.len,
                .items_per_range = system_config.items_per_range,
                .max_worker_threads = scratch_clamped_workers,
                .range_alignment_items = pathfinding_range_alignment_items,
                .adaptive = system_config.adaptive,
            });
            var context = SolveJobContext{ .system = self, .range_count = selection.range_count };
            stats.fallback_batch = thread_system.parallelForWithOptions(self.fallback_indices.items.len, &context, solveFallbackJob, .{
                .items_per_range = system_config.items_per_range,
                .max_worker_threads = scratch_clamped_workers,
                .range_alignment_items = pathfinding_range_alignment_items,
                .adaptive = system_config.adaptive,
                .adaptive_tuner = selection.active_tuner,
                .selected_profile = selection.profile,
            });
        }
        stats.solve_ns = solve_timer.lap();
        self.finishUpdate(solve_count, &stats);
        return stats;
    }

    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) !PathfindingStats {
        var stats: PathfindingStats = undefined;
        const solve_count = (try self.beginSolve(requests, agent_count, config, &stats)) orelse return stats;
        var solve_timer = PhaseTimer.begin();
        self.prepareSolvePhase(solve_count, self.effectiveFallbackLimit(config), &stats);
        if (self.fallback_indices.items.len != 0) {
            // Mirrors the threaded path's misconfiguration contract (see update()'s
            // Debug-gated assert): reserve() always provisions at least one scratch slot
            // (applyDerivedCapacity's @max(1, ...)), so an empty scratch_slots here means
            // this was called before reserve() — a caller bug, not a runtime condition.
            // Debug-gated assert catches it loudly in development; a release build
            // degrades gracefully (every fallback entry stays .deferred and is retried
            // once initialized) instead of an OOB scratch read or a one-off named error.
            if (builtin.mode == .Debug) std.debug.assert(self.scratch_slots.items.len != 0);
            if (self.scratch_slots.items.len != 0) {
                self.resetSolvedPaths();
                const scratch = &self.scratch_slots.items[0];
                for (self.fallback_indices.items, 0..) |pending_index, path_slot| {
                    self.solve_results.items[pending_index] = solveOne(self, pending_index, scratch, path_slot);
                }
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

    fn resetSolvedPaths(self: *PathfindingSystem) void {
        self.solved_paths.clearRetainingCapacity();
        for (0..self.solve_results.items.len) |_| {
            self.solved_paths.appendAssumeCapacity(.{ .key = emptyKey(self.graph.version), .offset = 0, .len = 0 });
        }
    }

    // Acceptance is the only stage that mutates the pending-key set. Cached hits
    // never enter pending work. Group-declared requests are recorded so a field
    // can be (re)built lazily; they still get a per-agent fallback while building.
    fn acceptRequests(self: *PathfindingSystem, requests: []const PathRequest) PathfindingStats {
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
                // already on the goal level AND actually covered by it: the field is
                // built on the goal level and an off-level member cannot sample it. A
                // ready field for an off-level member must NOT short-circuit, or that
                // member would stall forever; it falls through to individual
                // cross-level acceptance and gets its own corridor across the link.
                // Same-level members must ALSO verify the field can sample their own
                // cell (not just that the field is ready): a different chunk-local
                // component reads as a sample miss, not "serviced" — short-circuiting
                // it anyway would drop the request with no individual solve ever
                // queued, matching statusForKeyAndStart's mirrored fall-through.
                if (prepared.start_level == prepared.key.goal_level) {
                    if (self.findGroupField(prepared.key)) |field| {
                        if (field.state == .ready) {
                            const sampled = if (self.graph.grid(prepared.key.goal_level)) |goal_grid|
                                if (goal_grid.indexForCell(prepared.start)) |start_index|
                                    field.sample(goal_grid, start_index) != null
                                else
                                    false
                            else
                                false;
                            if (sampled) {
                                stats.group_field_samples += 1;
                                stats.duplicate_requests += 1;
                                continue;
                            }
                        }
                    }
                }
            }
            if (self.completed.findFresh(prepared.key, self.step_counter, types.default_cache_ttl_steps) != null) {
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

    fn recordGroupRequest(self: *PathfindingSystem, key: PathQueryKey) void {
        if (self.group_key_map.find(key)) |group_index| {
            self.group_requests.items[group_index].count += 1;
            return;
        }
        // Gate on the LOGICAL cap, not group_requests' physical .capacity:
        // ensureTotalCapacity rounds up, so the ArrayList's physical capacity can
        // exceed max_solved_requests_per_step while group_key_map is reserved to
        // exactly that logical cap and refuses inserts beyond it. Appending into the
        // physical slack would then silently drop the map registration and desync the
        // two, splitting one goal's tally across duplicate slots.
        if (self.group_requests.items.len < self.capacity.max_solved_requests_per_step) {
            const new_index = self.group_requests.items.len;
            self.group_requests.appendAssumeCapacity(.{ .key = key, .count = 1 });
            if (!self.group_key_map.insert(key, new_index)) {
                // Registration refused (map full): roll back the tally append so
                // group_requests and group_key_map stay in lockstep and can never
                // diverge into duplicate, count-splitting slots.
                self.group_requests.items.len -= 1;
            }
        }
    }

    // Builds/advances managed shared-goal flow fields for declared group goals.
    // Lazy on first request, throttled on goal-cell change, budgeted per frame.
    // The threshold is checked against the cross-step accumulator (acceptRequests),
    // so it reflects SUSTAINED shared-goal demand (~2x per-step intake at
    // equilibrium), not a single-step burst.
    fn serviceGroupFields(self: *PathfindingSystem, stats: *PathfindingStats) void {
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
                const removed_key = self.group_requests.items[i].key;
                const last_index = self.group_requests.items.len - 1;
                _ = self.group_requests.swapRemove(i);
                self.group_key_map.remove(removed_key);
                // If the removed slot was not the last, the entry formerly at last_index
                // was moved to i; update its stored index in the map.
                if (i < last_index) self.group_key_map.updateIndex(self.group_requests.items[i].key, i);
            } else {
                i += 1;
            }
        }
    }

    fn ensureGroupField(self: *PathfindingSystem, key: PathQueryKey, stats: *PathfindingStats) void {
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
            // An in-progress build is NEVER interrupted by a rekey, regardless of the
            // throttle: restarting it discards every cell it has already flooded for no
            // benefit (the caller still gets a stale-but-progressing field either way),
            // and a build whose natural completion time exceeds the throttle window would
            // otherwise restart forever without ever reaching `.ready` — a permanent
            // stall, not a transient staleness. The field keeps advancing every step via
            // serviceGroupFields' own "still building" loop regardless of this early-out.
            if (field.state == .building) {
                stats.group_field_rebuild_throttled += 1;
                return;
            }
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

    fn buildGroupSlot(self: *PathfindingSystem, field: *GroupField, key: PathQueryKey, goal_index: usize, stats: *PathfindingStats) void {
        const grid = self.graph.grid(key.goal_level) orelse return;
        if (field.beginBuild(grid, key, goal_index, self.step_counter, self.capacity.group_field_max_cells)) {
            _ = field.expand(grid, self.capacity.group_field_build_budget);
            field.fresh_this_step = true;
            stats.group_fields_built += 1;
        }
    }

    // True when `key` is still a live above-threshold group request this step,
    // i.e. its own crowd is actively being serviced. Such a slot represents a
    // distinct concurrent goal, not a moved-away one, so it must never be rekeyed
    // out from under its crowd.
    fn isActiveGroupGoal(self: *const PathfindingSystem, key: PathQueryKey) bool {
        const index = self.group_key_map.find(key) orelse return false;
        return self.group_requests.items[index].count >= self.groupFieldThreshold();
    }

    // A stale slot targets the same agent class/version/goal-level but a different
    // goal cell whose own crowd is no longer an active above-threshold request —
    // the moving-goal case (the declared goal crossed into a new cell, orphaning
    // the old field), NOT a second live crowd. Skipping still-active goals is what
    // stops two distinct same-class goals from evicting each other's field while
    // free slots exist. When several orphaned slots qualify, the one whose stored
    // goal is nearest the new goal cell is chosen so rebuild selection is
    // deterministic and reuses the most relevant field rather than an arbitrary
    // first match.
    fn staleGroupSlot(self: *PathfindingSystem, key: PathQueryKey) ?usize {
        var best_index: ?usize = null;
        var best_dist: i64 = std.math.maxInt(i64);
        for (self.group_fields.items, 0..) |field, index| {
            if (field.state == .empty) continue;
            if (keysEqual(field.key, key)) continue;
            if (field.key.agent_class != key.agent_class) continue;
            if (field.key.nav_version != key.nav_version) continue;
            if (field.key.goal_level != key.goal_level) continue;
            if (self.isActiveGroupGoal(field.key)) continue;
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

    fn findGroupField(self: *const PathfindingSystem, key: PathQueryKey) ?*const GroupField {
        for (self.group_fields.items) |*field| {
            if (field.state != .empty and keysEqual(field.key, key)) return field;
        }
        return null;
    }

    fn findGroupFieldMut(self: *PathfindingSystem, key: PathQueryKey) ?*GroupField {
        for (self.group_fields.items) |*field| {
            if (field.state != .empty and keysEqual(field.key, key)) return field;
        }
        return null;
    }

    fn prepareRequestKeys(self: *PathfindingSystem, requests: []const PathRequest, stats: *PathfindingStats) void {
        self.prepared_requests.clearRetainingCapacity();
        if (!self.graph.valid()) return;
        const capacity = self.prepared_requests.capacity;
        const limit = @min(requests.len, capacity);
        stats.dropped_requests += requests.len - limit;
        // Reject (drop, never clamp) an out-of-range level: the query path
        // (statusForWorld -> NavGraph.grid) already rejects the same condition as
        // unavailable, so clamping here would accept and solve/cache a request against
        // level 0 that the requester's own later query can never read back (it queries
        // its real, still out-of-range level and gets unavailable) — a wasted solve that
        // silently burns a fallback slot every step. Matching the query path's rejection
        // means the caller sees dropped_requests reflect the real, unusable request.
        const level_count: u16 = @intCast(self.graph.levelCount());
        for (requests[0..limit]) |request| {
            if (request.goal_level >= level_count or request.start_level >= level_count) {
                stats.dropped_requests += 1;
                continue;
            }
            const goal_grid = self.graph.grid(request.goal_level).?;
            const start_grid = self.graph.grid(request.start_level).?;
            self.prepared_requests.appendAssumeCapacity(.{
                .entity = request.entity,
                .kind = request.kind,
                .start_level = request.start_level,
                .key = .{
                    .nav_version = self.graph.version,
                    .agent_class = request.agent_class,
                    .goal_level = request.goal_level,
                    .goal = goal_grid.worldToCellClamped(request.goal),
                },
                .start = start_grid.worldToCellClamped(request.start),
            });
        }
    }

    fn prepareSolveBuffers(self: *PathfindingSystem, solve_count: usize) void {
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        for (0..solve_count) |_| {
            self.solve_results.appendAssumeCapacity(.{ .deferred = emptyKey(self.graph.version) });
        }
    }

    // Shared solve-phase setup for the threaded and serial paths. The Debug check
    // asserts the strict-increase invariant the fallback dispatch relies on; the
    // len > 1 guard keeps the [1..] slice in-bounds when the list is empty or single.
    fn prepareSolvePhase(self: *PathfindingSystem, solve_count: usize, fallback_limit: usize, stats: *PathfindingStats) void {
        self.prepareSolveBuffers(solve_count);
        self.prepareFallbackIndices(solve_count, fallback_limit, stats);
        if (builtin.mode == .Debug and self.fallback_indices.items.len > 1) {
            for (self.fallback_indices.items[1..], 0..) |idx, i| {
                std.debug.assert(self.fallback_indices.items[i] < idx);
            }
        }
    }

    fn effectiveSolveLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_solved_requests_per_step orelse self.capacity.max_solved_requests_per_step;
        return @min(
            self.pending.items.len,
            @min(
                @min(requested_limit, self.capacity.max_solved_requests_per_step),
                @min(self.solve_results.capacity, self.fallback_indices.capacity),
            ),
        );
    }

    fn effectiveFallbackLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_fallback_requests_per_step orelse self.capacity.max_fallback_requests_per_step;
        return @min(requested_limit, self.capacity.max_fallback_requests_per_step);
    }

    // Emits pending indices into fallback_indices for the heap A* batch. Indices come
    // from a sequential scan of 0..solve_count, so the list is strictly increasing and
    // every entry is distinct. Concurrent solveFallbackJob writes use these as
    // solve_results indices; disjointness of those writes depends on this uniqueness.
    // A tier-1 (escalated) request is additionally capped at max_escalated_solves_per_step
    // admissions this step, since tier-1 uses the larger derived abstract-node/stitched-cell
    // ceiling and is the expensive attempt; a tier-1-ready request past the cap is simply
    // skipped (stays .deferred, so compactPendingAfterSolve leaves it in place to retry next
    // step) without consuming a fallback_limit slot, so tier-0 requests keep filling the rest.
    fn prepareFallbackIndices(self: *PathfindingSystem, solve_count: usize, fallback_limit: usize, stats: *PathfindingStats) void {
        var escalated_admitted: usize = 0;
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            if (result != .deferred) continue;
            const is_escalated = self.pending.items[pending_index].tier != 0;
            if (is_escalated and escalated_admitted >= self.capacity.max_escalated_solves_per_step) {
                stats.escalated_deferred += 1;
                continue;
            }
            if (self.fallback_indices.items.len < fallback_limit) {
                self.fallback_indices.appendAssumeCapacity(pending_index);
                if (is_escalated) {
                    escalated_admitted += 1;
                    stats.escalated_solves += 1;
                }
            } else {
                stats.fallback_deferred_requests += 1;
            }
        }
    }

    fn publishSolvedResults(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            switch (result) {
                .available => |key| {
                    const solved = self.solved_paths.items[pending_index];
                    const path = self.worker_path_pool.items[solved.offset .. solved.offset + solved.len];
                    const stitched = self.worker_stitched_pool.items[solved.stitched_offset .. solved.stitched_offset + solved.stitched_len];
                    self.completed.put(key, path, stitched, solved.path_level, self.step_counter, stats);
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
                // Start-side failure: dropped in compactPendingAfterSolve without
                // negative-caching; the next status query falls through to `.missing`.
                .start_invalid => {
                    stats.start_invalid_dropped += 1;
                },
                .deferred => continue,
            }
        }
        stats.fallback_requests = self.fallback_indices.items.len;
    }

    // Compacts pending after a solve. Solved entries (available/unavailable) are removed.
    // Deferred entries (not attempted this frame, including a tier-1-ready request skipped
    // by the escalated-solve cap) keep their front order. A budget-exhausted entry follows
    // the two-tier ladder: tier 0 (the cheap, fixed-budget attempt) promotes to tier 1 and
    // rotates to the BACK of pending exactly once, so the untouched tail reaches the solve
    // window before the promoted entry retries at the larger — but still fixed, never
    // derived from world/graph size — tier-1 budget; a budget-exhausted AT tier 1 drops the
    // entry WITHOUT negative-caching (it does not fit either fixed budget, which is not the
    // same as a definitive "no path exists") — worst case exactly two solve attempts per
    // request, never an unbounded retry storm and never a false `.unavailable`. Solve-window
    // writes target indices <= their source, so the in-place rewrite never clobbers an
    // unread entry; the rotated copies live in rotate_back_scratch. pending_keys is updated
    // in-place: keys for solved/dropped entries are removed individually; deferred,
    // rotating, and tail keys stay.
    fn compactPendingAfterSolve(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        if (solve_count == 0) return;
        self.rotate_back_scratch.clearRetainingCapacity();
        var write_index: usize = 0;
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            switch (result) {
                .deferred => {
                    self.pending.items[write_index] = self.pending.items[pending_index];
                    write_index += 1;
                },
                .budget_exhausted => |key| {
                    var request = self.pending.items[pending_index];
                    if (request.tier == 0) {
                        // First (tier-0) attempt exhausted its small fixed attempt cap: promote
                        // to tier 1 and rotate to the back so the untouched tail makes progress
                        // before this entry retries at the larger (still fixed, not derived
                        // from world/graph size) tier-1 budget.
                        request.tier = 1;
                        self.rotate_back_scratch.appendAssumeCapacity(request);
                    } else {
                        // Tier 1 (the larger fixed ceiling) still exhausted: this is NOT a
                        // definitive negative — it only means the request did not fit either
                        // fixed budget, not that no path exists (`unavailable` is reserved for
                        // structural negatives: disconnected component, no corridor). Drop it
                        // from pending WITHOUT negative-caching, so the next status query falls
                        // through to `.missing` (statusForKeyAndStart's fallthrough) rather than
                        // a false "no path". The caller (steering) already treats `.missing` the
                        // same as `.pending`/`.unavailable` for movement (direct-fallback steering
                        // toward the goal, see steering.zig's directionFromPathStatus) and
                        // re-requests after its own replan cooldown, so a genuinely-hard case
                        // costs at most two solve attempts per replan cycle, not a permanent
                        // wrong answer or an unbounded retry storm.
                        stats.escalated_dropped += 1;
                        self.pending_keys.remove(key);
                    }
                },
                else => {
                    // available/unavailable/start_invalid: removed from pending. A
                    // start_invalid entry was never negative-cached, so its next
                    // status query is `.missing` and the caller may re-request.
                    self.pending_keys.remove(self.pending.items[pending_index].key);
                },
            }
        }
        for (self.pending.items[solve_count..]) |pending_request| {
            self.pending.items[write_index] = pending_request;
            write_index += 1;
        }
        // Aged spillers trail the untouched tail so the tail makes progress before they retry.
        for (self.rotate_back_scratch.items) |pending_request| {
            self.pending.items[write_index] = pending_request;
            write_index += 1;
        }
        self.pending.items.len = write_index;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const GridCell = types.GridCell;
const PathStatus = types.PathStatus;
const GroupFieldState = @import("group_field.zig").GroupFieldState;
const no_component = types.no_component;
const test_support = @import("test_support.zig");
const addNavBody = test_support.addNavBody;
const appendPathRequest = test_support.appendPathRequest;
const baselineCapacity = test_support.baselineCapacity;
const abstractCapacity = test_support.abstractCapacity;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const requireTestTile = test_support.requireTestTile;

test "pathfinding individual solve produces deterministic available path and waypoint" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);

    const view = system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 96, .y = 96 }, .default, null);
    try std.testing.expectEqual(PathStatus.available, view.status);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.x);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.y);
    try std.testing.expect(view.path_len >= 2);
}

test "pathfinding blocked start drops without poisoning the goal for other agents" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // A static body covers cell (0,0), so an agent standing there has a blocked start.
    _ = try addNavBody(&data, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 8 }, true);
    const blocked_agent = try addNavBody(&data, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 8 }, false);
    const open_agent = try addNavBody(&data, .{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    // The blocked agent requests first: a start-side drop, never a goal negative.
    var blocked_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer blocked_stream.deinit();
    try appendPathRequest(&blocked_stream, .{ .entity = blocked_agent, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });
    const blocked_stats = try system.updateSerial(&blocked_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), blocked_stats.start_invalid_dropped);
    try std.testing.expectEqual(@as(usize, 0), blocked_stats.unavailable_results);

    // The goal must read missing (retryable) from an open start, not unavailable.
    const probe = system.statusForWorld(0, .{ .x = 40, .y = 40 }, 0, .{ .x = 96, .y = 96 }, .default, null);
    try std.testing.expectEqual(PathStatus.missing, probe.status);

    // The open agent's request for the SAME goal succeeds on the next step.
    var open_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer open_stream.deinit();
    try appendPathRequest(&open_stream, .{ .entity = open_agent, .start = .{ .x = 40, .y = 40 }, .goal = .{ .x = 96, .y = 96 } });
    const open_stats = try system.updateSerial(&open_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), open_stats.available_results);
    const view = system.statusForWorld(0, .{ .x = 40, .y = 40 }, 0, .{ .x = 96, .y = 96 }, .default, null);
    try std.testing.expectEqual(PathStatus.available, view.status);
}

test "pathfinding zero fallback budget leaves an empty fallback list without panicking" {
    // A zero fallback budget with pending work yields an empty fallback_indices, which
    // must not panic the strict-increase verification slice (items[1..]) in either path.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // worker_participant_count=4 (workers + main) matches the threaded section's real
    // ThreadSystem below (max_worker_threads=2 -> up to 3 participants): reserving at
    // baselineCapacity's serial default (1) would violate update()'s reserve/thread-system
    // assert, but this test's zero fallback budget happens to keep fallback_indices empty
    // every call, skipping that assert entirely and masking the mismatch instead of
    // genuinely satisfying the contract.
    var capacity = baselineCapacity();
    capacity.worker_participant_count = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var serial_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer serial_stream.deinit();
    try appendPathRequest(&serial_stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });
    const serial_stats = try system.updateSerial(&serial_stream, 8, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 0), serial_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), serial_stats.deferred_requests);

    if (!builtin.single_threaded) {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
        defer threads.deinit();
        var threaded_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer threaded_stream.deinit();
        try appendPathRequest(&threaded_stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 64, .y = 64 } });
        const threaded_stats = try system.update(&threaded_stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1, .max_fallback_requests_per_step = 0 });
        try std.testing.expectEqual(@as(usize, 0), threaded_stats.available_results);
    }
}

test "pathfinding goal-keyed dedup reuses one accepted request under start drift" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var accepted_total: usize = 0;
    const steps: usize = 6;
    for (0..steps) |i| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        // The agent's start cell drifts toward a fixed goal each step.
        const start_x: f32 = 8.0 + @as(f32, @floatFromInt(i)) * 40.0;
        try appendPathRequest(&stream, .{
            .entity = requester,
            .start = .{ .x = start_x, .y = 8 },
            .goal = .{ .x = 480, .y = 480 },
        });
        const stats = try system.updateSerial(&stream, 8, .{});
        accepted_total += stats.accepted_requests;
    }
    // Exactly one A* solve was accepted; later drifting starts reuse the cache.
    try std.testing.expectEqual(@as(usize, 1), accepted_total);
}

test "pathfinding projects goal in obstacle to nearest open cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    // Block the single cell containing the goal.
    _ = try addNavBody(&data, .{ .x = 96, .y = 96 }, .{ .x = 32, .y = 32 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 3, .y = 3 }));

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    // Goal world position falls inside the blocked cell.
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 104, .y = 104 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.goal_projected);
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 104, .y = 104 }, .default, null).status);
}

test "pathfinding spills to pending when node budget is exhausted" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    // A tiny node budget cannot explore the open grid to the far goal.
    capacity.max_explored_nodes = 20;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 488, .y = 488 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
    const view = system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 488, .y = 488 }, .default, null);
    try std.testing.expectEqual(PathStatus.pending, view.status);
}

test "pathfinding rejects disconnected goals" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 160 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 8 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 128, .y = 8 }, .default, null).status);
}

test "pathfinding drops an out-of-range level request instead of clamping and solving a goal it can never read back" {
    // The query path (statusForWorld -> NavGraph.grid) rejects an out-of-range level as
    // unavailable; the accept path must match that rejection instead of silently clamping
    // to level 0 and burning a solve on a goal the requester's own later query (against its
    // real, still out-of-range level) can never observe.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    // Single-level grid: level 1 is out of range.
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);
    try std.testing.expectEqual(@as(usize, 1), system.graph.levelCount());

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .goal_level = 1, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), system.pending.items.len);
}

test "pathfinding deferred_requests equals post-compaction pending in both update paths" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 200, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 200, .y = 40 } });
    try appendPathRequest(&stream, .{ .entity = c, .start = .{ .x = 72, .y = 8 }, .goal = .{ .x = 200, .y = 72 } });

    // Per-step solve budget of 1 (config override) throttles to one solve/step.
    const stats = try system.updateSerial(&stream, 3, .{ .max_solved_requests_per_step = 1 });
    try std.testing.expectEqual(@as(usize, 1), stats.solved_requests);
    try std.testing.expectEqual(stats.pending_requests, stats.deferred_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.pending_requests);
}

test "pathfinding deferred_requests equals pending in threaded update path" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.worker_participant_count = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(2, 2);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 200, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 200, .y = 40 } });

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    const stats = try system.update(&stream, 2, &threads, .{ .adaptive = false, .items_per_range = 1, .max_solved_requests_per_step = 1 });
    try std.testing.expectEqual(stats.pending_requests, stats.deferred_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
}

test "pathfinding group mode builds one shared field sampled by all agents" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    const goal = math.Vec2{ .x = 200, .y = 200 };
    try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });

    // First step: the field does not exist yet during acceptance, so the shared
    // goal dedups to exactly one individual fallback solve while the field is
    // built (and finishes, given the default budget) this same step.
    const first_stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 1), first_stats.accepted_requests);
    var ready_field_count: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready_field_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ready_field_count);

    // Second step: the ready field answers all three; no individual solves, and
    // every agent samples the one shared field.
    const second_stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), second_stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, 0), second_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 3), second_stats.group_field_samples);

    const view = system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.available, view.status);
}

test "pathfinding same-level group agent falls through on a field-sample miss instead of a hard unavailable" {
    // A ready field does not cover every same-level cell (e.g. one blocked by a body added
    // after the field built): a sample miss there must fall through to the individual
    // cache/pending/negative-cache path, exactly like an off-level member already does —
    // never a blind `.unavailable` that starves the agent of any real solve attempt.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    // A cell the field will never reach: a static body wholly covering it, present from
    // the initial build so no mid-test incremental rebuild is needed.
    _ = try addNavBody(&data, .{ .x = 224, .y = 224 }, .{ .x = 32, .y = 32 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    const goal = math.Vec2{ .x = 200, .y = 200 };
    try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });

    // Builds and readies the shared field (mirrors "pathfinding group mode builds one
    // shared field sampled by all agents").
    _ = try system.updateSerial(&stream, 8, .{});
    var ready_field_count: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready_field_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ready_field_count);

    // Clear the goal-keyed cache the first step's individual fallback solve populated, and
    // simulate an in-flight solve for it, so the only remaining fallthrough signal is
    // pending_keys — isolating the field-sample-miss branch from the unrelated cache hit.
    system.completed.clear();
    const key = system.graph.keyForWorld(0, goal, .default).?;
    _ = system.pending_keys.insert(key);

    const blocked_start = math.Vec2{ .x = 240, .y = 240 };
    const view = system.statusForWorld(0, blocked_start, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.pending, view.status);
}

test "pathfinding warmed group-field request/sample step is allocation-free" {
    // Mirrors the first step of "pathfinding group mode builds one shared field sampled by
    // all agents": once the field reaches .ready, every subsequent step's
    // recordGroupRequest/serviceGroupFields/ensureGroupField/sample path must not allocate —
    // it was previously uncovered by any FailingAllocator proof.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    const goal = math.Vec2{ .x = 200, .y = 200 };
    try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });

    // Unmeasured warm-up step: builds the field to .ready (allocation is expected here).
    const first_stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first_stats.group_fields_built);

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const second_stats = try system.updateSerial(&stream, 8, .{});
    system.allocator = original;

    try std.testing.expectEqual(@as(usize, 0), second_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 3), second_stats.group_field_samples);
}

test "pathfinding skips the group flow field below the agent threshold" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Require three same-goal agents before a shared field is built.
    var capacity = baselineCapacity();
    capacity.min_group_field_agents = 3;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    const goal = math.Vec2{ .x = 200, .y = 200 };

    // Two agents (< threshold): no field builds; the shared goal still resolves via
    // one individual A* solve, so a small group never pays the flow-field cost.
    var below = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer below.deinit();
    try below.reserve(3, 3);
    try appendPathRequest(&below, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&below, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    const below_stats = try system.updateSerial(&below, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), below_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 1), below_stats.accepted_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goal, .default, null).status);

    // Three agents (== threshold): the shared field now builds.
    var at = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer at.deinit();
    try at.reserve(3, 3);
    try appendPathRequest(&at, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&at, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&at, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });
    const at_stats = try system.updateSerial(&at, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), at_stats.group_fields_built);
}

test "pathfinding builds no group field when no group requests arrive" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 200, .y = 200 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.group_fields_built);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
    }
}

test "pathfinding group field reuses within a nav cell and throttles cross-cell rebuilds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.group_field_rebuild_min_steps = 5;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var rebuild_count: usize = 0;
    const steps: usize = 12;
    for (0..steps) |i| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        // The goal moves a few pixels each step but stays mostly within one nav
        // cell; cross into a new cell occasionally.
        const goal_x: f32 = 100.0 + @as(f32, @floatFromInt(i)) * 10.0;
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = goal_x, .y = 100 } });
        const stats = try system.updateSerial(&stream, 8, .{});
        rebuild_count += stats.group_fields_built;
    }
    // Without throttle a moving goal would rebuild every cell crossing; the
    // throttle bounds rebuilds well below the step count.
    try std.testing.expect(rebuild_count >= 1);
    try std.testing.expect(rebuild_count <= steps / capacity.group_field_rebuild_min_steps + 2);
}

test "pathfinding distinct same-class group goals keep separate fields without ping-pong" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    // Three slots for two distinct goals: a free slot must remain, never a steal.
    capacity.max_group_fields = 3;
    capacity.min_group_field_agents = 1;
    // A short throttle so the slot-stealing bug (if present) would rebuild every
    // step and be plainly visible in the build count.
    capacity.group_field_rebuild_min_steps = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    // Two persistent same-class group goals in distinct nav cells (32px cells):
    // (100,100) -> cell (3,3), (220,100) -> cell (6,3).
    const goal_a = math.Vec2{ .x = 100, .y = 100 };
    const goal_b = math.Vec2{ .x = 220, .y = 100 };

    var built_total: usize = 0;
    for (0..4) |_| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try stream.reserve(2, 2);
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal_a });
        try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal_b });
        const stats = try system.updateSerial(&stream, 8, .{});
        built_total += stats.group_fields_built;
    }

    // Each distinct goal holds its own ready field simultaneously — the second
    // goal takes the free empty slot rather than evicting the first.
    var ready: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ready);
    // Exactly one build per goal. Under the slot-stealing bug the two live goals
    // would rekey each other's slot every throttle window, so the running build
    // count would climb well past two.
    try std.testing.expectEqual(@as(usize, 2), built_total);
}

test "pathfinding group field latches via cross-step accumulation when intake is staggered" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Threshold of 3, but only 2 same-goal requests arrive per step (below the
    // threshold per step). The decaying accumulator equilibrates near ~2x intake,
    // so sustained demand crosses the threshold within a couple of steps.
    var capacity = baselineCapacity();
    capacity.min_group_field_agents = 3;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    const goal = math.Vec2{ .x = 200, .y = 200 };
    var built: usize = 0;
    for (0..4) |_| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try stream.reserve(2, 2);
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
        try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
        const stats = try system.updateSerial(&stream, 8, .{});
        built += stats.group_fields_built;
    }
    // No single step ever delivered the threshold count, yet accumulation latched.
    try std.testing.expect(built >= 1);
    var ready: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ready);
}

test "pathfinding sub-threshold transient crowd decays back to no group field" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Threshold of 4: a single 2-agent burst never reaches it and then stops, so
    // the accumulator decays back to zero and the tally is compacted out.
    var capacity = baselineCapacity();
    capacity.min_group_field_agents = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    const goal = math.Vec2{ .x = 200, .y = 200 };
    var burst = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer burst.deinit();
    try burst.reserve(2, 2);
    try appendPathRequest(&burst, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&burst, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    const burst_stats = try system.updateSerial(&burst, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), burst_stats.group_fields_built);

    // No further group requests: the carried tally halves to zero and compacts away,
    // and no field is ever built.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..3) |_| {
        const stats = try system.updateSerial(&empty, 8, .{});
        try std.testing.expectEqual(@as(usize, 0), stats.group_fields_built);
    }
    try std.testing.expectEqual(@as(usize, 0), system.group_requests.items.len);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
    }
}

test "pathfinding group tally refuses over-cap distinct keys without desyncing the map" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    // The logical per-step cap governs how many distinct group tallies may register:
    // group_requests is reserved to it, but group_key_map refuses inserts past exactly
    // this cap. recordGroupRequest must gate the new-group append on the LOGICAL cap, not
    // the ArrayList's physical .capacity — otherwise appends into physical slack outrun the
    // dropped map registrations and split one goal's count across duplicate slots.
    const logical_cap = system.capacity.max_solved_requests_per_step;
    try std.testing.expect(logical_cap >= 2);

    // Force physical slack above the logical cap so the logical/physical divergence is
    // exercised deterministically regardless of the allocator's size-class rounding.
    try system.group_requests.ensureTotalCapacity(system.allocator, logical_cap * 4);
    try std.testing.expect(system.group_requests.capacity > logical_cap);

    // A repeated key must accumulate in ONE slot, never spawn duplicates.
    const repeated = PathQueryKey{ .nav_version = 1, .agent_class = .default, .goal = .{ .x = 0, .y = 0 } };
    system.recordGroupRequest(repeated);
    system.recordGroupRequest(repeated);
    system.recordGroupRequest(repeated);

    // Drive more distinct goals than the logical cap in a single step.
    var made: usize = 0;
    while (made < logical_cap + 5) : (made += 1) {
        system.recordGroupRequest(.{ .nav_version = 1, .agent_class = .default, .goal = .{ .x = @intCast(made + 1), .y = 0 } });
    }

    // The tally never overflows the logical cap into the ArrayList's physical slack.
    try std.testing.expectEqual(logical_cap, system.group_requests.items.len);

    // Every registered tally is keyed to exactly one slot: no two entries share a key, and
    // group_key_map round-trips each key back to its own slot index.
    var seen = std.AutoHashMap(PathQueryKey, void).init(std.testing.allocator);
    defer seen.deinit();
    for (system.group_requests.items, 0..) |tally, idx| {
        const gop = try seen.getOrPut(tally.key);
        try std.testing.expect(!gop.found_existing);
        try std.testing.expectEqual(@as(?usize, idx), system.group_key_map.find(tally.key));
    }

    // The repeated key accumulated all three requests in its single slot.
    const repeated_index = system.group_key_map.find(repeated) orelse return error.RepeatedKeyMissing;
    try std.testing.expectEqual(@as(usize, 3), system.group_requests.items[repeated_index].count);
}

test "pathfinding group field within the same nav cell reuses without rebuilding" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    // First request builds a field for goal cell (1,1) (32px cells).
    var first = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer first.deinit();
    try appendPathRequest(&first, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 40, .y = 40 } });
    const first_stats = try system.updateSerial(&first, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first_stats.group_fields_built);

    // A goal that stays inside the same nav cell reuses the field, no rebuild.
    var second = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer second.deinit();
    try appendPathRequest(&second, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 56, .y = 56 } });
    const reuse_stats = try system.updateSerial(&second, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), reuse_stats.group_fields_built);
    try std.testing.expect(reuse_stats.group_field_reuses >= 1);
}

test "pathfinding group field reports building across frames under tiny budget" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    // One cell expanded per frame: the field cannot finish in a single frame.
    capacity.group_field_build_budget = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goal = math.Vec2{ .x = 240, .y = 240 };
    try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    _ = try system.updateSerial(&stream, 8, .{});

    const key = system.graph.keyForWorld(0, goal, .default).?;
    const field_after_first = system.findGroupField(key).?;
    try std.testing.expectEqual(GroupFieldState.building, field_after_first.state);

    // Advance frames until the field completes; it must finish within the cell
    // count given a positive budget.
    var guard: usize = 0;
    while (system.findGroupField(key).?.state == .building and guard < system.graph.cellCount() + 1) : (guard += 1) {
        var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer empty.deinit();
        try empty.reserve(1, 0);
        try empty.prepareRangeCounts(0);
        try empty.prefix();
        empty.finishWrite();
        _ = try system.updateSerial(&empty, 8, .{});
    }
    try std.testing.expect(guard > 0);
    try std.testing.expectEqual(GroupFieldState.ready, system.findGroupField(key).?.state);
}

test "pathfinding threaded solve matches serial solve" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 64, .y = 32 }, .{ .x = 32, .y = 96 }, true);

    var serial_system = PathfindingSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(baselineCapacity());
    try serial_system.rebuildStaticNavGrid(&data, 160, 160, 32);
    var threaded_system = PathfindingSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    var threaded_capacity = baselineCapacity();
    threaded_capacity.worker_participant_count = 3;
    try threaded_system.reserve(threaded_capacity);
    try threaded_system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 16, .y = 16 }, .goal = .{ .x = 144, .y = 144 } });

    _ = try serial_system.updateSerial(&stream, 8, .{});
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    _ = try threaded_system.update(&stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });

    const serial_view = serial_system.statusForWorld(0, .{ .x = 16, .y = 16 }, 0, .{ .x = 144, .y = 144 }, .default, null);
    const threaded_view = threaded_system.statusForWorld(0, .{ .x = 16, .y = 16 }, 0, .{ .x = 144, .y = 144 }, .default, null);
    try std.testing.expectEqual(serial_view.status, threaded_view.status);
    try std.testing.expectEqual(serial_view.next_waypoint.x, threaded_view.next_waypoint.x);
    try std.testing.expectEqual(serial_view.next_waypoint.y, threaded_view.next_waypoint.y);
}

test "pathfinding threaded multi-worker solve has no steady-state allocation after warmup (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const count = 8;
    var entities: [count]EntityId = undefined;
    for (0..count) |i| {
        entities[i] = try addNavBody(&data, .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * 32.0 }, .{ .x = 8, .y = 8 }, false);
    }

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = baselineCapacity();
    cap.max_frame_requests = count;
    cap.max_pending_requests = count;
    cap.max_solved_requests_per_step = count;
    cap.max_fallback_requests_per_step = count;
    cap.max_cached_results = count * 2;
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    for (0..count) |i| {
        const gy: f32 = @as(f32, @floatFromInt(i)) * 32.0 + 8.0;
        try appendPathRequest(&stream, .{
            .entity = entities[i],
            .start = .{ .x = 8, .y = gy },
            .goal = .{ .x = 400, .y = gy },
        });
    }

    // Warm multi-worker solve path (must not be the inline fallback).
    const warmup = try system.update(&stream, count, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!warmup.fallback_batch.ran_inline);
    try std.testing.expect(warmup.fallback_batch.active_worker_threads > 0);

    // Steady-state re-solve under a failing allocator on system + graph (scratch
    // and path stripes already reserved; no new capacity growth).
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }

    // Drop all cached/pending solve state so the same goals re-enter the
    // multi-worker fallback path under the failing allocator.
    system.clearRuntimeState();
    const stats = try system.update(&stream, count, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!stats.fallback_batch.ran_inline);
    try std.testing.expect(stats.fallback_batch.item_count > 0);
}

test "pathfinding threaded multi-goal solve keeps disjoint per-request paths" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const count = 8;
    var entities: [count]EntityId = undefined;
    for (0..count) |i| {
        entities[i] = try addNavBody(&data, .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * 32.0 }, .{ .x = 8, .y = 8 }, false);
    }

    var serial_system = PathfindingSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    var serial_cap = baselineCapacity();
    serial_cap.max_frame_requests = count;
    serial_cap.max_pending_requests = count;
    serial_cap.max_solved_requests_per_step = count;
    serial_cap.max_fallback_requests_per_step = count;
    serial_cap.max_cached_results = count * 2;
    try serial_system.reserve(serial_cap);
    try serial_system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var threaded_system = PathfindingSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    var threaded_cap = serial_cap;
    threaded_cap.worker_participant_count = 4;
    try threaded_system.reserve(threaded_cap);
    try threaded_system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    // Each agent has a distinct goal cell, forcing a distinct individual solve.
    for (0..count) |i| {
        const gy: f32 = @as(f32, @floatFromInt(i)) * 32.0 + 8.0;
        try appendPathRequest(&stream, .{
            .entity = entities[i],
            .start = .{ .x = 8, .y = gy },
            .goal = .{ .x = 480, .y = gy },
        });
    }

    _ = try serial_system.updateSerial(&stream, 8, .{});
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    _ = try threaded_system.update(&stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });

    // Every distinct goal must resolve to the same waypoint serially and
    // threaded; a shared worker path stripe would corrupt all-but-one.
    for (0..count) |i| {
        const gy: f32 = @as(f32, @floatFromInt(i)) * 32.0 + 8.0;
        const serial_view = serial_system.statusForWorld(0, .{ .x = 8, .y = gy }, 0, .{ .x = 480, .y = gy }, .default, null);
        const threaded_view = threaded_system.statusForWorld(0, .{ .x = 8, .y = gy }, 0, .{ .x = 480, .y = gy }, .default, null);
        try std.testing.expectEqual(PathStatus.available, serial_view.status);
        try std.testing.expectEqual(serial_view.status, threaded_view.status);
        try std.testing.expectEqual(serial_view.next_waypoint.x, threaded_view.next_waypoint.x);
        try std.testing.expectEqual(serial_view.next_waypoint.y, threaded_view.next_waypoint.y);
    }
}

test "pathfinding warmed individual update does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });

    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, 8, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding cross-level link steers an off-level agent toward the start-level endpoint" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    // 384px = 12x12 nav cells; level 0 and level 1 both open grass floors.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // Bidirectional link from level 0 cell (10,10) to level 1 cell (2,2).
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    // Agent on level 0 wants a goal on level 1: must route across the link.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), stats.cross_level_solves);
    try std.testing.expectEqual(@as(usize, 1), stats.abstract_solves);

    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default, null);
    try std.testing.expectEqual(PathStatus.available, view.status);
    // First waypoint steers toward the level-0 link endpoint (10,10) center area,
    // i.e. to the right/down of the start cell (0,0).
    try std.testing.expect(view.next_waypoint.x > 16);
    try std.testing.expect(view.next_waypoint.y > 16);

    const link_world = cellCenterWorld(.{ .x = 10, .y = 10 });
    const at_link = system.statusForWorld(0, link_world, 1, .{ .x = 304, .y = 304 }, .default, null);
    try std.testing.expectEqual(PathStatus.available, at_link.status);
}

test "pathfinding cross-level goal with no link is unavailable, not pending forever" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // No level link added: the two floors are disconnected.

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_requests);
    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default, null);
    try std.testing.expectEqual(PathStatus.unavailable, view.status);
}

test "pathfinding blocked link endpoint excludes the link until unblocked and rebuilt" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // World with the level-1 link endpoint cell (2,2) blocked: the link is not live.
    var blocked_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer blocked_world.deinit();
    _ = try blocked_world.addLevel(0);
    _ = try blocked_world.addDenseLayer(1, 0, .floor, grass);
    try blocked_world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });
    _ = try blocked_world.addSparseTile(1, 2, 2, tree, 0, .obstacle);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &blocked_world, 384, 384, 32, null);
    const blocked_version = system.graph.version;

    var blocked_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer blocked_stream.deinit();
    try appendPathRequest(&blocked_stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const blocked_stats = try system.updateSerial(&blocked_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), blocked_stats.unavailable_results);

    // Identical world but the endpoint is open. Rebuilding the same system bumps
    // nav_version (invalidating the prior negative) and the link becomes live.
    var open_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer open_world.deinit();
    _ = try open_world.addLevel(0);
    _ = try open_world.addDenseLayer(1, 0, .floor, grass);
    try open_world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });
    try system.rebuildStaticNavGridWithWorld(&data, &open_world, 384, 384, 32, null);
    try std.testing.expect(system.graph.version != blocked_version);

    var open_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer open_stream.deinit();
    try appendPathRequest(&open_stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const open_stats = try system.updateSerial(&open_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), open_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), open_stats.cross_level_solves);
}

test "pathfinding per-level obstacle independence: level 0 obstacle is absent on level 1" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // Obstacle only on level 0 cell (5,5).
    _ = try world.addSparseTile(0, 5, 5, tree, 0, .obstacle);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    // Cell (5,5) is blocked on level 0 but open on level 1.
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 5, .y = 5 }));
    try std.testing.expect(!system.graph.grid(1).?.isBlockedCell(.{ .x = 5, .y = 5 }));

    // A level-1 solve through (5,5) ignores the level-0 obstacle.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 1,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 176, .y = 176 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    const view = system.statusForWorld(1, .{ .x = 16, .y = 16 }, 1, .{ .x = 176, .y = 176 }, .default, null);
    try std.testing.expectEqual(PathStatus.available, view.status);
}

test "pathfinding multi-hop same-level corridor travels obstacle-free past a concave wall" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    // 512px = 16x16 cells. A full wall at x=8 splits level 0 into left/right
    // components; a same-level teleport bridges (7,8)->(9,8). In the RIGHT component a
    // short CONCAVE wall (column x=11, y=7..10) sits directly between the teleport
    // exit (9,8) and the goal (13,8), so NO straight line connects them -- the path
    // must detour up and over. The right region stays one component (the wall is
    // local), so a corridor exists. Driving the agent in single CELL steps toward each
    // returned waypoint and FAILING on any step into a blocked or non-adjacent cell
    // proves continuous obstacle-free travel -- not a straight-line snap.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    for (0..16) |y| {
        _ = try world.addSparseTile(0, 8, @intCast(y), tree, 0, .obstacle);
    }
    var wy: u16 = 7;
    while (wy <= 10) : (wy += 1) {
        _ = try world.addSparseTile(0, 11, wy, tree, 0, .obstacle);
    }
    try world.addLevelLink(.{
        .kind = .teleport,
        .level_a = 0,
        .cell_a = .{ .x = 7, .y = 8 },
        .level_b = 0,
        .cell_b = .{ .x = 9, .y = 8 },
        .traversal_cost = 1,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.max_cached_results = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    const link_near = GridCell{ .x = 7, .y = 8 };
    const link_far = GridCell{ .x = 9, .y = 8 };
    const goal_cell = GridCell{ .x = 13, .y = 8 };
    const grid = system.graph.grid(0).?;

    var agent = GridCell{ .x = 1, .y = 8 };
    var reached = false;
    var first_via_abstract = false;
    var step: usize = 0;
    while (step < 256) : (step += 1) {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        const start_world = cellCenterWorld(agent);
        try appendPathRequest(&stream, .{
            .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
            .start = start_world,
            .goal = cellCenterWorld(goal_cell),
        });
        const stats = try system.updateSerial(&stream, 8, .{});
        if (step == 0 and stats.abstract_solves != 0) first_via_abstract = true;
        const view = system.statusForWorld(0, start_world, 0, cellCenterWorld(goal_cell), .default, null);
        if (view.status == .unavailable) return error.TestUnexpectedResult;
        if (view.status != .available) continue;
        if (agent.x == goal_cell.x and agent.y == goal_cell.y) {
            reached = true;
            break;
        }
        const target = grid.worldToCellClamped(view.next_waypoint);
        if (target.x == agent.x and target.y == agent.y) continue;
        // Discrete teleport jump is allowed only at the link endpoint; otherwise the
        // returned waypoint must be a physically ADJACENT OPEN cell. A grid-adjacent
        // stitched path yields exactly that; a straight-line cut would produce a
        // non-adjacent or blocked heading and fail here.
        if (agent.x == link_near.x and agent.y == link_near.y and target.x == link_far.x and target.y == link_far.y) {
            agent = link_far;
            continue;
        }
        if (@abs(target.x - agent.x) > 1 or @abs(target.y - agent.y) > 1) return error.TestUnexpectedResult;
        if (grid.isBlockedCell(target)) return error.TestUnexpectedResult;
        agent = target;
    }
    try std.testing.expect(first_via_abstract);
    try std.testing.expect(reached);
}

fn cellCenterWorld(cell: GridCell) math.Vec2 {
    return .{
        .x = @as(f32, @floatFromInt(cell.x)) * 32 + 16,
        .y = @as(f32, @floatFromInt(cell.y)) * 32 + 16,
    };
}

test "pathfinding abstract seeding scans only the start level and stays within budget" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    // Build a single-level and a multi-level world of the SAME size and identical
    // level-0 topology. Seeding scans only the start level's portals, so level 0's
    // seeded portal count must be IDENTICAL regardless of how many other levels and
    // how many total portals exist. This proves seeding is per-level-bounded.
    var one_data = DataSystem.init(std.testing.allocator);
    defer one_data.deinit();
    var one_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer one_world.deinit();
    var one_system = PathfindingSystem.init(std.testing.allocator);
    defer one_system.deinit();
    try one_system.reserve(abstractCapacity());
    try one_system.rebuildStaticNavGridWithWorld(&one_data, &one_world, 512, 512, 32, null);
    const one_level_start_portals = one_system.graph.levelLivePortalCount(0);

    var four_data = DataSystem.init(std.testing.allocator);
    defer four_data.deinit();
    var four_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer four_world.deinit();
    _ = try four_world.addLevel(0);
    _ = try four_world.addLevel(0);
    _ = try four_world.addLevel(0);
    _ = try four_world.addDenseLayer(1, 0, .floor, grass);
    _ = try four_world.addDenseLayer(2, 0, .floor, grass);
    _ = try four_world.addDenseLayer(3, 0, .floor, grass);
    var four_system = PathfindingSystem.init(std.testing.allocator);
    defer four_system.deinit();
    try four_system.reserve(abstractCapacity());
    try four_system.rebuildStaticNavGridWithWorld(&four_data, &four_world, 512, 512, 32, null);
    const four_level_start_portals = four_system.graph.levelLivePortalCount(0);

    try std.testing.expect(one_level_start_portals > 0);
    // The extra open levels add many total portals, but the start level's seeded
    // count is unchanged: seeding never touches the other levels' portals.
    try std.testing.expect(four_system.graph.totalPortals() > four_level_start_portals);
    try std.testing.expectEqual(one_level_start_portals, four_level_start_portals);

    // The per-query abstract search completes within the node budget regardless of
    // world size: a long diagonal solve never surfaces saturation as a hard negative.
    const extents = [_]f32{ 512, 1024 };
    for (extents) |extent| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
        defer world.deinit();
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try appendPathRequest(&stream, .{
            .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
            .start = .{ .x = 16, .y = 16 },
            .goal = .{ .x = extent - 16, .y = extent - 16 },
        });
        const stats = try system.updateSerial(&stream, 8, .{});
        try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    }
}

test "pathfinding cross-level group member falls back to an individual corridor" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const on_level = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const off_level = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const goal = math.Vec2{ .x = 304, .y = 304 }; // goal on level 1

    // Step 1: a level-1 group member declares the goal so the field builds on
    // level 1; the off-level member (start_level 0) also requests.
    var first = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer first.deinit();
    try first.reserve(2, 2);
    try appendPathRequest(&first, .{ .entity = on_level, .kind = .group, .start_level = 1, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
    try appendPathRequest(&first, .{ .entity = off_level, .kind = .group, .start_level = 0, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
    _ = try system.updateSerial(&first, 8, .{});

    // Advance until the group field is ready on level 1.
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        var ready = false;
        for (system.group_fields.items) |field| {
            if (field.state == .ready) ready = true;
        }
        if (ready) break;
        var step_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer step_stream.deinit();
        try step_stream.reserve(2, 2);
        try appendPathRequest(&step_stream, .{ .entity = on_level, .kind = .group, .start_level = 1, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        try appendPathRequest(&step_stream, .{ .entity = off_level, .kind = .group, .start_level = 0, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        _ = try system.updateSerial(&step_stream, 8, .{});
    }

    // The on-level member samples the ready group field.
    const on_view = system.statusForWorld(1, .{ .x = 16, .y = 16 }, 1, goal, .default, null);
    try std.testing.expectEqual(PathStatus.available, on_view.status);

    // After the field is ready, the off-level member must still reach .available
    // via an individual cross-level corridor (pins C1: no permanent stall).
    var reached = false;
    var off_guard: usize = 0;
    while (off_guard < 64) : (off_guard += 1) {
        const off_view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, goal, .default, null);
        if (off_view.status == .available) {
            reached = true;
            break;
        }
        try std.testing.expect(off_view.status != .unavailable);
        var step_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer step_stream.deinit();
        try step_stream.reserve(2, 2);
        try appendPathRequest(&step_stream, .{ .entity = on_level, .kind = .group, .start_level = 1, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        try appendPathRequest(&step_stream, .{ .entity = off_level, .kind = .group, .start_level = 0, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        _ = try system.updateSerial(&step_stream, 8, .{});
    }
    try std.testing.expect(reached);
}

test "pathfinding directed link traverses one way only" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // Directed (non-bidirectional) link: level 0 -> level 1 only.
    try world.addLevelLink(.{
        .kind = .teleport,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 1,
        .bidirectional = false,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    // A -> B (0 -> 1) succeeds.
    var forward = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer forward.deinit();
    try appendPathRequest(&forward, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const forward_stats = try system.updateSerial(&forward, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), forward_stats.available_results);

    // B -> A (1 -> 0) fails: no reverse edge.
    var backward = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer backward.deinit();
    try appendPathRequest(&backward, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 1,
        .goal_level = 0,
        .start = .{ .x = 80, .y = 80 },
        .goal = .{ .x = 16, .y = 16 },
    });
    const backward_stats = try system.updateSerial(&backward, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), backward_stats.unavailable_results);
}

test "pathfinding cross-level corridor stays obstacle-free on the destination level" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // Level 0 open; level 1 open except a concave wall between the link exit (2,2)
    // and the goal (13,8), forcing the destination-level segment to route around it.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    var wy: u16 = 0;
    while (wy <= 10) : (wy += 1) {
        _ = try world.addSparseTile(1, 6, wy, tree, 0, .obstacle); // wall x=6, y=0..10
    }
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 2, .y = 2 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 1,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.max_cached_results = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    const link0 = GridCell{ .x = 2, .y = 2 };
    const link1 = GridCell{ .x = 2, .y = 2 };
    const goal_cell = GridCell{ .x = 13, .y = 8 };
    const grid1 = system.graph.grid(1).?;

    // Phase 1: walk level 0 to the link, in single open cell steps.
    var agent = GridCell{ .x = 14, .y = 14 };
    var level: u16 = 0;
    var reached = false;
    var crossed_link = false;
    var step: usize = 0;
    while (step < 256) : (step += 1) {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        const start_world = cellCenterWorld(agent);
        try appendPathRequest(&stream, .{
            .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
            .start_level = level,
            .goal_level = 1,
            .start = start_world,
            .goal = cellCenterWorld(goal_cell),
        });
        _ = try system.updateSerial(&stream, 8, .{});
        const view = system.statusForWorld(level, start_world, 1, cellCenterWorld(goal_cell), .default, null);
        if (view.status == .unavailable) return error.TestUnexpectedResult;
        if (view.status != .available) continue;
        if (level == 1 and agent.x == goal_cell.x and agent.y == goal_cell.y) {
            reached = true;
            break;
        }
        // At the level-0 link endpoint, cross to level 1's endpoint (discrete jump).
        if (level == 0 and agent.x == link0.x and agent.y == link0.y) {
            level = 1;
            agent = link1;
            crossed_link = true;
            continue;
        }
        const grid = system.graph.grid(level).?;
        const target = grid.worldToCellClamped(view.next_waypoint);
        if (target.x == agent.x and target.y == agent.y) continue;
        // On level 1, every heading must be an adjacent OPEN cell (obstacle-free).
        if (@abs(target.x - agent.x) > 1 or @abs(target.y - agent.y) > 1) return error.TestUnexpectedResult;
        if (level == 1 and grid1.isBlockedCell(target)) return error.TestUnexpectedResult;
        agent = target;
    }
    try std.testing.expect(crossed_link);
    try std.testing.expect(reached);
}

test "pathfinding abstract saturation returns pending, not a cached unavailable" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // A live cross-level link so a corridor genuinely exists to be searched.
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    // A tiny tier-0 abstract-node ATTEMPT cap saturates the search before it can reach
    // the goal-level portal, even though a corridor exists. max_abstract_nodes itself is
    // NOT the right knob here — it is the fixed tier-1 ceiling, large enough that this
    // tiny world's first attempt would heal long before it saturates.
    capacity.tier0_abstract_node_cap = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    // Saturation spills to a later frame: counted as budget_exhausted, NOT cached
    // as a hard negative, and the status reads pending (retryable).
    try std.testing.expect(stats.budget_exhausted >= 1);
    try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default, null);
    try std.testing.expectEqual(PathStatus.pending, view.status);
    // The two-tier ladder: the FIRST (tier-0) exhaustion promotes to tier 1 immediately
    // (not retried at tier 0 repeatedly).
    try std.testing.expectEqual(@as(u8, 1), system.pending.items[0].tier);
}

// tier0_stitched_cell_cap and max_stitched_path_cells (the fixed tier-1 ceiling) are
// independently settable fields, but stitched_scratch is physically reserved to
// max_stitched_path_cells only (SearchScratch.reserve) — never to the tier-0 field. If a
// caller tunes tier0_stitched_cell_cap ABOVE the tier-1 ceiling, solveOne must clamp the
// tier-0 attempt cap down to the physical size rather than handing stitchCorridor a
// logical cap the reserved buffer cannot back (an unguarded appendAssumeCapacity past the
// buffer's real capacity is exactly the "unproven reserve" hazard this repo's coding
// standards call out for ReleaseFast, which strips the backing assert). This pins that a
// deliberately-inverted config (tier0 far above tier1) still resolves cleanly instead of
// tripping the reserve invariant.
test "pathfinding tier0_stitched_cell_cap above the tier-1 ceiling still solves cleanly" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const built = try buildCorridorWorld(&meta, &.{5});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    // Deliberately inverted: far above the fixed tier-1 ceiling (abstractCapacity's own
    // max_stitched_path_cells override).
    capacity.tier0_stitched_cell_cap = 5000;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const stats = try solveStep(&system, requester, .{ .x = 16, .y = 176 }, .{ .x = 336, .y = 176 });
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.budget_exhausted);
}

// tier0_abstract_node_cap and max_abstract_nodes (the fixed tier-1 ceiling) are
// independently settable fields, but AbstractScratch.reserve physically sizes
// slot_capacity from max_abstract_nodes only (max(16, max_abstract_nodes * 2)) —
// never from the tier-0 field. If a caller tunes tier0_abstract_node_cap ABOVE the
// tier-1 ceiling, solveOne must clamp the tier-0 attempt cap down to the tier-1
// ceiling rather than handing abstractCorridor a logical budget the physical slot
// table cannot back (nodes_used would race past slot_capacity via slotFor's
// linear-probe loop, saturating far short of the configured cap instead of via the
// intended budget check). This pins that a deliberately-inverted config (tier0 far
// above tier1) still resolves cleanly instead of tripping that asymmetry.
test "pathfinding tier0_abstract_node_cap above the tier-1 ceiling still solves cleanly" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const built = try buildCorridorWorld(&meta, &.{5});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    // Deliberately inverted: far above the fixed tier-1 ceiling (abstractCapacity's own
    // max_abstract_nodes default).
    capacity.tier0_abstract_node_cap = 500_000;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const stats = try solveStep(&system, requester, .{ .x = 16, .y = 176 }, .{ .x = 336, .y = 176 });
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.budget_exhausted);
}

// A tier-1 (already-escalated) budget_exhausted drops the request WITHOUT
// negative-caching: it does not fit either fixed budget, which is not the same as a
// definitive "no path exists" (unavailable is reserved for structural negatives). The
// next query falls through to `.missing` (retryable — steering re-requests after its own
// cooldown) rather than a permanent false negative, and the request cost at most two
// solve attempts, never an unbounded retry storm. Forces both tiers to exhaust via
// explicit PathfindingCapacity overrides (tier0_abstract_node_cap for the first attempt,
// then a direct post-rebuild shrink of the live max_abstract_nodes for the second) on the
// SAME small fixture as the tier-0 promotion test above — not the full production map.
test "pathfinding tier-1 budget_exhausted drops to missing (not a false unavailable) after exactly two attempts" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.tier0_abstract_node_cap = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });

    // Attempt 1 (tier 0): exhausts and promotes to tier 1.
    const first = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), system.pending.items.len);
    try std.testing.expectEqual(@as(u8, 1), system.pending.items[0].tier);

    // Force the SECOND (tier-1) attempt to also exhaust: max_abstract_nodes is the fixed
    // tier-1 ceiling, read fresh from live capacity on every tier-1 attempt, so shrinking
    // it here — after the rebuild already sized the (larger) physical scratch — is a
    // safe, purely LOGICAL cap tightening for the test, not an undersized-buffer hazard.
    system.capacity.max_abstract_nodes = 1;

    // Attempt 2 (tier 1): exhausts again -> dropped, NOT negative-cached.
    const second = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), second.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), second.pending_requests);
    try std.testing.expectEqual(@as(usize, 0), system.pending.items.len);
    // Exactly two solve attempts total across the two steps (never the old 32-retry storm).
    try std.testing.expectEqual(@as(usize, 2), first.budget_exhausted + second.budget_exhausted);

    // Dropped, not negative-cached: the next query reads .missing (retryable), never a
    // false definitive .unavailable for a goal that may genuinely be reachable.
    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default, null);
    try std.testing.expectEqual(PathStatus.missing, view.status);
}

// max_escalated_solves_per_step caps how many tier-1-ready pending requests are admitted
// into one step's solve batch; the rest simply wait for a later step (still pending, tier
// unchanged) rather than all attempting the expensive escalated solve in the same step.
test "pathfinding max_escalated_solves_per_step caps tier-1 admission to exactly N per step" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester_a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const requester_b = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const requester_c = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const requester_d = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_escalated_solves_per_step = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    // Four distinct, trivially-reachable requests, accepted into pending WITHOUT solving
    // this step (a zero fallback budget defers every one), so all four land in `pending`
    // at the default tier 0.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester_a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 40, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = requester_b, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 72, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = requester_c, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 104, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = requester_d, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 136, .y = 8 } });
    _ = try system.updateSerial(&stream, 8, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 4), system.pending.items.len);

    // Promote every pending entry to tier 1 (as if each had already spilled once).
    for (system.pending.items) |*pending_request| pending_request.tier = 1;

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const stats = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 2), stats.escalated_solves);
    try std.testing.expectEqual(@as(usize, 2), stats.escalated_deferred);
    // The two admitted tier-1 requests solved trivially (short, same-level, open goals);
    // the other two waited out this step and are still pending at tier 1.
    try std.testing.expectEqual(@as(usize, 2), system.pending.items.len);
    for (system.pending.items) |pending_request| {
        try std.testing.expectEqual(@as(u8, 1), pending_request.tier);
    }
}

// max_abstract_nodes/max_stitched_path_cells (the tier-1 ceiling) are FIXED constants —
// never derived from or scaled to world/graph size (see their doc comments in types.zig).
// Pins that reserve() with no override lands on those fixed defaults regardless of world
// size, i.e. two systems built over different-sized worlds get the IDENTICAL tier-1
// budget, not one scaled to its own map.
test "pathfinding tier-1 abstract/stitched budgets are fixed constants, not scaled to world size" {
    var small_data = DataSystem.init(std.testing.allocator);
    defer small_data.deinit();
    var small = PathfindingSystem.init(std.testing.allocator);
    defer small.deinit();
    try small.reserve(baselineCapacity());
    try small.rebuildStaticNavGrid(&small_data, 256, 256, 32);

    var large_data = DataSystem.init(std.testing.allocator);
    defer large_data.deinit();
    var large = PathfindingSystem.init(std.testing.allocator);
    defer large.deinit();
    try large.reserve(baselineCapacity());
    try large.rebuildStaticNavGrid(&large_data, 2048, 2048, 32);

    try std.testing.expectEqual(types.default_tier1_abstract_node_cap, small.capacity.max_abstract_nodes);
    try std.testing.expectEqual(types.default_tier1_stitched_cell_cap, small.capacity.max_stitched_path_cells);
    try std.testing.expectEqual(small.capacity.max_abstract_nodes, large.capacity.max_abstract_nodes);
    try std.testing.expectEqual(small.capacity.max_stitched_path_cells, large.capacity.max_stitched_path_cells);
}

test "pathfinding chunk-local portal seeding scans only the start chunk's local component" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    // A 12x12-cell world split into TWO disconnected open regions by a SOLID vertical
    // tree wall at column 5 (no gaps). Left (cols 0..4) and right (cols 6..11) span
    // several 4-tile chunks, so the chunk-local labels of cells in different chunks
    // differ even within one region.
    const built = try buildCorridorWorld(&meta, &.{});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const grid = system.graph.grid(0).?;
    const left_cell = grid.indexForCell(.{ .x = 1, .y = 5 }).?;
    const right_cell = grid.indexForCell(.{ .x = 9, .y = 5 }).?;
    const left_component = grid.componentOf(left_cell);
    const right_component = grid.componentOf(right_cell);
    // Chunk-local labels: the two cells sit in different chunks AND different regions,
    // so their encoded labels differ.
    try std.testing.expect(left_component != no_component);
    try std.testing.expect(right_component != no_component);
    try std.testing.expect(left_component != right_component);

    // levelComponentPortals returns exactly the start CHUNK's local-component portals:
    // every returned portal shares the queried encoded label (hence the same chunk and
    // the same chunk-local component), and the two query results are disjoint.
    const left_chunk = grid.chunkOfCell(left_cell);
    const right_chunk = grid.chunkOfCell(right_cell);
    const left_portals = system.graph.levelComponentPortals(0, left_component);
    const right_portals = system.graph.levelComponentPortals(0, right_component);
    try std.testing.expect(left_portals.len > 0);
    try std.testing.expect(right_portals.len > 0);
    const level0_graph = system.graph.levelGraph(0).?;
    for (left_portals) |node| {
        const cell = level0_graph.portals.items[node].cell_index;
        try std.testing.expectEqual(left_component, grid.componentOf(cell));
        try std.testing.expectEqual(left_chunk, grid.chunkOfCell(cell));
    }
    for (right_portals) |node| {
        const cell = level0_graph.portals.items[node].cell_index;
        try std.testing.expectEqual(right_component, grid.componentOf(cell));
        try std.testing.expectEqual(right_chunk, grid.chunkOfCell(cell));
    }
    // The two slices are disjoint (different labels), and each is a strict subset of the
    // level's full portal set (chunk-local seeding never scans the whole border).
    try std.testing.expect(left_portals.len < system.graph.levelLivePortalCount(0));
    try std.testing.expect(right_portals.len < system.graph.levelLivePortalCount(0));

    // Correctness preserved: a cross-component goal (no link) is unavailable, and a
    // same-component goal stays reachable.
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const cross = try solveStep(&system, requester, tileCenter(1, 5), tileCenter(9, 5));
    try std.testing.expectEqual(@as(usize, 1), cross.unavailable_results);
    const same = try solveStep(&system, requester, tileCenter(1, 1), tileCenter(1, 10));
    try std.testing.expectEqual(@as(usize, 1), same.available_results);
}

test "pathfinding warmed cross-level abstract solve does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });

    // A multi-hop abstract+stitched solve under the failing allocator must not touch
    // the heap (all scratch and corridor stripes were warmed at reserve/rebuild).
    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, 8, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), stats.abstract_solves);
    try std.testing.expectEqual(@as(usize, 1), stats.cross_level_solves);
}

// ----------------------------------------------------------------------------
// Incremental nav update tests
// ----------------------------------------------------------------------------

// World center (px) of tile cell (cx, cy) at the demo 32px tile size, used to seed
// requests/queries at a known nav cell.
fn tileCenter(cx: u16, cy: u16) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(cx)) * 32 + 16, .y = @as(f32, @floatFromInt(cy)) * 32 + 16 };
}

// Builds a 12x12-tile single-level world with a vertical tree wall at column 5 that
// leaves open gaps at the given rows. The base floor is open grass, so the only way
// across the wall is through a gap. Returns the world plus the obstacle layer index
// so a test can flip the gap cells.
fn buildCorridorWorld(meta: *const @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta, open_rows: []const u16) !struct { world: WorldSystem, wall_layer: usize } {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, meta, 384, 384);
    errdefer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var open = false;
        for (open_rows) |row| {
            if (row == y) open = true;
        }
        if (open) continue;
        _ = try world.setDenseTile(wall_layer, 5, y, tree);
    }
    return .{ .world = world, .wall_layer = wall_layer };
}

fn solveStep(system: *PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    return system.updateSerial(&stream, 8, .{});
}

test "pathfinding incremental update reroutes when a corridor gap is flipped to blocking" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    // Two gaps in the wall: the nearer (row 3) is used first; closing it forces a
    // reroute through the far gap (row 9).
    const built = try buildCorridorWorld(&meta, &.{ 3, 9 });
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    const before = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), before.available_results);
    const view_before = system.statusForWorld(0, start, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.available, view_before.status);

    // The cached path must cross the wall through exactly one of the two gaps: which one
    // the abstract search prefers is a cost-estimate detail (consolidated boundary portals
    // change the abstract graph's cost landscape without changing which corridors exist),
    // not the invariant under test — the invariant is that blocking whichever gap was used
    // forces a reroute through the other.
    const used_near = cachedPathTouchesCell(&system, start, goal, 5, 3);
    const used_far = cachedPathTouchesCell(&system, start, goal, 5, 9);
    try std.testing.expect(used_near != used_far);
    const used_row: u16 = if (used_near) 3 else 9;
    const other_row: u16 = if (used_near) 9 else 3;

    const version_before = system.graph.version;

    // Flip the gap the path actually used to a tree (now blocking) via the world tile API.
    const changed = (try world.setDenseTile(built.wall_layer, 5, used_row, tree)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement != changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    // A pure incremental dig keeps nav_version stable; invalidation is scoped.
    try std.testing.expectEqual(@as(usize, 0), nav_stats.version_bumps);
    try std.testing.expect(system.graph.version == version_before);
    // The cached path crossed the now-blocked gap, so it was evicted: missing.
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);

    // Next solve produces a DIFFERENT path that avoids the now-blocked gap and routes
    // through the other one.
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), after.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, used_row));
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, other_row));
}

// Returns whether the cached completed (or stitched) path for the goal includes the
// nav cell at tile (cx, cy). Walks the stored cells directly; used to assert a route
// crosses a specific corridor gap.
fn cachedPathTouchesCell(system: *const PathfindingSystem, start: math.Vec2, goal: math.Vec2, cx: u16, cy: u16) bool {
    const key = system.graph.keyForWorld(0, goal, .default) orelse return false;
    _ = start;
    const slot = system.completed.slotIndex(key) orelse return false;
    const result = system.completed.resultAt(slot);
    const grid = system.graph.grid(0) orelse return false;
    const target = grid.indexForCell(.{ .x = @intCast(cx), .y = @intCast(cy) }) orelse return false;
    if (result.stitched_len != 0) {
        for (system.completed.stitchedSlice(slot, result.stitched_len)) |sc| {
            if (sc.level == 0 and sc.cell == target) return true;
        }
        return false;
    }
    for (system.completed.pathSlice(slot, result.path_len)) |cell| {
        if (cell == target) return true;
    }
    return false;
}

test "pathfinding incremental update disconnects a goal when the last gap is closed" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    // A single gap at row 3 is the only crossing.
    const built = try buildCorridorWorld(&meta, &.{3});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);

    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The cached path crossed the now-closed gap (5,3), so it was evicted and the
    // re-solve is a definitive unavailable, not a stale cached available.
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), after.unavailable_results);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, start, 0, goal, .default, null).status);
}

test "pathfinding incremental update retains a still-valid cached path when an off-path tile is unblocked" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    // Start with only the far gap (row 9) open; the near gap (row 3) is a tree.
    const built = try buildCorridorWorld(&meta, &.{9});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);
    // Path crosses only at row 9 (the near gap is closed).
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 9));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 3));

    // Unblock the near gap (5,3): a cell the cached path (via row 9) does not cross, so
    // it is retained. Opening a shortcut does not re-route existing agents.
    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), nav_stats.version_bumps);

    // The path survived: still available and still routing through the far gap (row 9).
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 9));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 3));
}

test "pathfinding incremental update blocking an off-path cell keeps the cached path as a cache hit" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    const built = try buildCorridorWorld(&meta, &.{3});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);
    // The cached route crosses the row-3 gap and never visits the far corner (9,11).
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 3));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 9, 11));

    // Block an off-path cell far from the route: the cached path is left intact (an edit
    // elsewhere does not invalidate unrelated cached paths).
    const changed = (try world.setDenseTile(built.wall_layer, 9, 11, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), nav_stats.version_bumps);

    // The same goal is served from the surviving cache (a hit): nothing re-solved.
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 0), after.accepted_requests);
    try std.testing.expectEqual(@as(usize, 1), after.cache_hits);
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 3));
}

test "pathfinding incremental update leaves an unaffected second level untouched" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_layer = try world.addDenseLayer(1, 0, .floor, grass);
    // A distinctive obstacle on level 1 cell (7,7) so we can confirm level 1 is
    // unchanged by an edit on level 0.
    _ = try world.setDenseTile(level1_layer, 7, 7, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    // Snapshot level 1's blocked count and component label of its obstacle cell.
    const level1_blocked_before = system.graph.grid(1).?.blocked_count;
    const level1_cell77 = system.graph.grid(1).?.indexForCell(.{ .x = 7, .y = 7 }).?;
    try std.testing.expect(system.graph.grid(1).?.isBlockedIndex(level1_cell77));

    // Edit a tile on LEVEL 0 only.
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    const changed = (try world.setDenseTile(obstacle_layer, 2, 2, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), nav_stats.full_relabel);
    // Level 1's mask is byte-for-byte what it was: the incremental update never
    // re-marked it. Its obstacle cell and blocked count are intact.
    try std.testing.expectEqual(level1_blocked_before, system.graph.grid(1).?.blocked_count);
    try std.testing.expect(system.graph.grid(1).?.isBlockedIndex(level1_cell77));
    // Level 0 gained the new obstacle.
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));
}

test "pathfinding incremental update with no real change does no work" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const version_before = system.graph.version;

    // An empty edit batch is a no-op: no version bump, no counters.
    const stats = try system.applyNavUpdates(&data, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
    try std.testing.expectEqual(version_before, system.graph.version);
}

test "pathfinding buffered nav updates grow without dropping and clear after apply" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 512 extent at cell_size 32 is 16 nav cells/side; with 4-tile chunks that is a 4x4 chunk
    // grid, so the far block below lands in the opposite-corner chunk from the near block.
    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    // Mark far more dirty cells than the steady-path reserve (max_frame_requests = 8): a 24-cell
    // near block, then a 3-cell far block in the opposite-corner chunk LAST. A drop-on-cap would
    // lose the far block and its chunk would never remask; the grow-don't-drop buffer must carry
    // every cell so the far chunk still ends blocked.
    var marked: usize = 0;
    var ny: u16 = 0;
    while (ny < 6) : (ny += 1) {
        var nx: u16 = 0;
        while (nx < 4) : (nx += 1) {
            _ = (try world.setDenseTile(obstacle, nx, ny, tree)) orelse return error.TestExpectedEqual;
            try system.markNavDirty(0, nx, ny);
            marked += 1;
        }
    }
    var fx: u16 = 13;
    while (fx < 16) : (fx += 1) {
        _ = (try world.setDenseTile(obstacle, fx, 13, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, fx, 13);
        marked += 1;
    }
    try std.testing.expect(marked > abstractCapacity().max_frame_requests);
    try std.testing.expect(system.hasPendingNavUpdates());

    const stats = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The far block — marked last, the first a fixed cap would drop — reached the graph.
    const nav = system.graph.grid(0).?;
    fx = 13;
    while (fx < 16) : (fx += 1) try std.testing.expect(nav.isBlockedCell(.{ .x = @intCast(fx), .y = 13 }));
    // applyBuffered clears the buffer, so the next step starts empty.
    try std.testing.expect(!system.hasPendingNavUpdates());

    // clearNavDirty drops a marking pass without applying it.
    try system.markNavDirty(0, 0, 0);
    system.clearNavDirty();
    try std.testing.expect(!system.hasPendingNavUpdates());
}

test "reactToPostCommitNavEvents preserves buffered marks across a failed apply instead of dropping them" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 128, 128);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 128, 128, 32, null);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    // A real committed tile edit that blocks movement.
    const changed = (try world.setDenseTile(obstacle, 2, 2, tree)) orelse return error.TestExpectedEqual;
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    // Cap the events stream at its current size so this call's own ensureCanAppend(1) (for the
    // nav_region_invalidated event it would emit) fails deterministically, WITHOUT ever reaching
    // applyBufferedNavUpdates.
    frame.events.setCapacityLimit(frame.events.mergedItems().len);

    try std.testing.expectError(error.EventCapacityExceeded, system.reactToPostCommitNavEvents(&frame, &data, &world, null));
    // The mark from this failed call must survive: no entry-clear on the next call may drop a
    // pending edit the world already committed but the nav graph has not yet learned about.
    try std.testing.expect(system.hasPendingNavUpdates());
    try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));

    // Next step: no new committed events, room to append again. The leftover mark from the
    // failed step must still reach the graph.
    frame.events.setCapacityLimit(null);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expect(!system.hasPendingNavUpdates());
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));
}

test "reactToPostCommitNavEvents maps world_obstacle_changed to one cell-span (not O(tiles) edits)" {
    // M15: a multi-tile world_obstacle_changed must append a single ChangedSpan via
    // markNavTileRectDirty, not one NavCellEdit per tile. Multi-chunk fixture
    // (nav_chunk_tiles=4) so the dirty rect spans ≥2 abstract chunks and a control
    // cell in an untouched chunk stays open.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // 256 world units / 32 cell size = 8 nav cells; with nav_chunk_tiles=4 that is a
    // 2×2 chunk grid so a rect crossing x=4 spans two chunks on the same row.
    const extent: f32 = 256;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
    const grid = system.graph.grid(0).?;
    try std.testing.expect(grid.width >= 8);
    try std.testing.expectEqual(@as(u16, 4), system.capacity.nav_chunk_tiles);

    // Paint a rect that crosses the chunk boundary at x=4 (tiles 2..5 inclusive).
    const min_x: u16 = 2;
    const min_y: u16 = 1;
    const max_x_exclusive: u16 = 6;
    const max_y_exclusive: u16 = 3;
    // Control tile in the bottom-right chunk — never part of the dirty rect.
    const control_x: u16 = 6;
    const control_y: u16 = 6;
    var y: u16 = min_y;
    while (y < max_y_exclusive) : (y += 1) {
        var x: u16 = min_x;
        while (x < max_x_exclusive) : (x += 1) {
            _ = (try world.setDenseTile(obstacle, x, y, tree)) orelse return error.TestExpectedEqual;
        }
    }

    // Expected span = union of per-tile world-rect spans (must match the O(1) mark).
    var expected_span = grid.cellSpanForWorldRect(0, 0, 0, 0);
    var first_tile = true;
    y = min_y;
    while (y < max_y_exclusive) : (y += 1) {
        var x: u16 = min_x;
        while (x < max_x_exclusive) : (x += 1) {
            const rect = world.cellRect(x, y).?;
            const tile_span = grid.cellSpanForWorldRect(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h);
            if (first_tile) {
                expected_span = tile_span;
                first_tile = false;
            } else {
                expected_span.min_x = @min(expected_span.min_x, tile_span.min_x);
                expected_span.min_y = @min(expected_span.min_y, tile_span.min_y);
                expected_span.max_x = @max(expected_span.max_x, tile_span.max_x);
                expected_span.max_y = @max(expected_span.max_y, tile_span.max_y);
            }
        }
    }
    // The union itself must cross a nav-chunk boundary (otherwise the multi-chunk claim is vacuous).
    const ct: usize = system.capacity.nav_chunk_tiles;
    try std.testing.expect(expected_span.min_x / ct != expected_span.max_x / ct);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = 0,
        .min_x = min_x,
        .min_y = min_y,
        .max_x_exclusive = max_x_exclusive,
        .max_y_exclusive = max_y_exclusive,
    } } });

    // Mark only (don't apply): inspect the dirty buffers after the event walk by
    // forcing ensureCanAppend to fail before applyBufferedNavUpdates, same pattern
    // as the preserve-buffered-marks test above.
    frame.events.setCapacityLimit(frame.events.mergedItems().len);
    try std.testing.expectError(error.EventCapacityExceeded, system.reactToPostCommitNavEvents(&frame, &data, &world, null));

    // One span, zero per-tile edits — O(1) dirty expand, not O(tiles).
    try std.testing.expectEqual(@as(usize, 0), system.nav_dirty_edits.items.len);
    try std.testing.expectEqual(@as(usize, 1), system.nav_dirty_cell_spans.items.len);
    try std.testing.expectEqual(@as(u16, 0), system.nav_dirty_cell_spans.items[0].level);
    try std.testing.expectEqual(expected_span, system.nav_dirty_cell_spans.items[0].span);

    // Apply the leftover mark: dirty tiles block; control cell in the untouched chunk stays open.
    frame.events.setCapacityLimit(null);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    y = min_y;
    while (y < max_y_exclusive) : (y += 1) {
        var x: u16 = min_x;
        while (x < max_x_exclusive) : (x += 1) {
            const rect = world.cellRect(x, y).?;
            const cell = grid.worldToCellClamped(.{
                .x = rect.x + rect.w * 0.5,
                .y = rect.y + rect.h * 0.5,
            });
            try std.testing.expect(grid.isBlockedCell(cell));
        }
    }
    {
        const control_rect = world.cellRect(control_x, control_y).?;
        const control_cell = grid.worldToCellClamped(.{
            .x = control_rect.x + control_rect.w * 0.5,
            .y = control_rect.y + control_rect.h * 0.5,
        });
        try std.testing.expect(!grid.isBlockedCell(control_cell));
    }
}

test "markNavTileRectDirty clamps partial OOB rects instead of dropping them" {
    // L7: a rect whose max corner is past the world edge still dirties the in-bounds
    // portion (perception-style clamp), rather than all-or-nothing no-op on cellRect miss.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // 128 / tile_size ≈ 4 tiles on a side — small enough that max=100 is clearly OOB.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 128, 128);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 128, 128, 32, null);
    const grid = system.graph.grid(0).?;

    // Paint the last two columns so the clamped in-bounds slice actually flips blocked.
    const in_min_x: u16 = world.width - 2;
    const in_min_y: u16 = 0;
    var y: u16 = 0;
    while (y < world.height) : (y += 1) {
        var x: u16 = in_min_x;
        while (x < world.width) : (x += 1) {
            _ = (try world.setDenseTile(obstacle, x, y, tree)) orelse return error.TestExpectedEqual;
        }
    }

    // min in-bounds, max far past the edge — pre-fix dropped the whole mark.
    try system.markNavTileRectDirty(&world, 0, in_min_x, in_min_y, 1000, 1000);
    try std.testing.expectEqual(@as(usize, 1), system.nav_dirty_cell_spans.items.len);

    const stats = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    // Every in-bounds tile of the painted strip is blocked after the clamped dirty apply.
    y = 0;
    while (y < world.height) : (y += 1) {
        var x: u16 = in_min_x;
        while (x < world.width) : (x += 1) {
            const rect = world.cellRect(x, y).?;
            const cell = grid.worldToCellClamped(.{
                .x = rect.x + rect.w * 0.5,
                .y = rect.y + rect.h * 0.5,
            });
            try std.testing.expect(grid.isBlockedCell(cell));
        }
    }

    // Fully OOB / empty after clamp still no-ops.
    try system.markNavTileRectDirty(&world, 0, world.width, world.height, 1000, 1000);
    try std.testing.expectEqual(@as(usize, 0), system.nav_dirty_cell_spans.items.len);
}

test "markNavLevelDirty is allocation-free up to the reserved ceiling (FailingAllocator)" {
    // R14 / L1: reserve pre-warms nav_dirty_levels; marks up to that ceiling must not
    // allocate. One past the physical capacity still grows (grows-rather-than-drops).
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    const reserved_cap = system.nav_dirty_levels.capacity;
    try std.testing.expect(reserved_cap >= 8);

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;

    var level: u16 = 0;
    while (level < reserved_cap) : (level += 1) {
        try system.markNavLevelDirty(level);
    }
    try std.testing.expectEqual(reserved_cap, system.nav_dirty_levels.items.len);
    // Dedup within the reserved set must also stay allocation-free.
    try system.markNavLevelDirty(0);
    try std.testing.expectEqual(reserved_cap, system.nav_dirty_levels.items.len);

    system.allocator = original;

    // Past the physical capacity: grow path uses the real allocator (still never drops).
    try system.markNavLevelDirty(@intCast(reserved_cap));
    try std.testing.expectEqual(reserved_cap + 1, system.nav_dirty_levels.items.len);
}

test "pathfinding incremental update is allocation-free at steady state (within init high-water mark)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // The corridor world opens its gaps at the INIT build, so the abstract buffers
    // reach their high-water capacity during rebuild. Blocking an existing open gap
    // (removes portals) and reopening it (re-adds <= the init count) both stay WITHIN
    // that high-water mark — the real steady-state contract.
    const built = try buildCorridorWorld(&meta, &.{ 3, 9 });
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const high_water = system.graph.totalPortals();
    try std.testing.expect(high_water > 0);

    // The failing allocator must cover BOTH the system AND the nav graph (which holds
    // its own captured allocator copy): every graph-rebuild buffer (portals/edges/
    // cell_to_portal/build scratch) flows through graph.allocator, so swapping only
    // system.allocator would let a graph allocation slip through undetected.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    // Block an existing open gap: removes portals, stays within high-water.
    const blocked = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const block_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = blocked.level, .x = blocked.x, .y = blocked.y }});
    try std.testing.expectEqual(@as(usize, 1), block_stats.incremental_rebuilds);

    // Reopen the same gap: re-adds portals back to <= the init high-water count, so it
    // reuses retained capacity and allocates nothing.
    const opened = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    const open_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = opened.level, .x = opened.x, .y = opened.y }});
    try std.testing.expectEqual(@as(usize, 1), open_stats.incremental_rebuilds);
    try std.testing.expect(system.graph.totalPortals() <= high_water);

    system.graph.allocator = original;
    system.allocator = original;
}

test "pathfinding threaded incremental nav update is allocation-free at steady state" {
    // The serial-path allocation-free tests above (and applyNavUpdates itself, which always
    // passes thread_system=null) only prove the INLINE remask/patch scratch (slot 0) is reused
    // without allocating. Only applyBufferedNavUpdates/reactToPostCommitNavEvents with a real
    // ThreadSystem drive patchChunkJob/remaskChunkJob, which index a PER-WORKER
    // ChunkPatchScratch/ChunkRemaskScratch slot (nav_graph.zig's patch_scratch/remask_scratch,
    // sized at rebuild). That fan-out path had zero allocation coverage. Mirrors "incremental
    // nav update forced-parallel remask and patch match a serial full rebuild" in nav_graph.zig
    // (five edits in five distinct chunks, adaptive=false/items_per_range=1 to force both stages
    // off the inline path) but under a failing allocator on both system.allocator and
    // system.graph.allocator, matching the steady-state test above.
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline.
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

    // The failing allocator must cover BOTH the system AND the nav graph (which holds its own
    // captured allocator copy): every per-worker patch/remask scratch slot, plus every
    // graph-rebuild buffer, flows through graph.allocator, so swapping only system.allocator
    // would let a graph allocation slip through undetected.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk
    // set and the patch dirty set exceed one chunk and actually fan out across workers.
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    const stats = try system.applyBufferedNavUpdates(&data, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);

    // Both stages must have actually threaded, not fallen back to the inline slot-0 path —
    // otherwise this would silently retest the already-covered serial path.
    try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);

    for (cells) |cell| {
        try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = cell.x, .y = cell.y }));
    }

    system.graph.allocator = original;
    system.allocator = original;
}

test "pathfinding incremental update expands beyond init high-water mark with bounded growth" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // Start fully walled so the init build has zero portals (minimal high-water).
    // Opening a block later expands the abstract graph past it. This is the documented
    // amortized-growth exception (a cold, event-triggered path), NOT the alloc-free
    // contract: it must SUCCEED and produce the new topology, using the real allocator.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, tree);
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var x: u16 = 0;
        while (x < 12) : (x += 1) {
            _ = try world.setDenseTile(wall_layer, x, y, tree);
        }
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try std.testing.expectEqual(@as(usize, 0), system.graph.totalPortals());

    // Open a 6x6 block spanning chunk borders, creating new portals past the (zero)
    // init high-water mark. The growth is allowed and the build completes correctly.
    var edits = std.ArrayList(NavCellEdit).empty;
    defer edits.deinit(std.testing.allocator);
    y = 2;
    while (y < 8) : (y += 1) {
        var x: u16 = 2;
        while (x < 8) : (x += 1) {
            const opened = (try world.setDenseTile(wall_layer, x, y, grass)) orelse continue;
            try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
        }
    }
    // Border-run consolidation (nav_graph.zig's discoverChunkPortals) means the opened
    // block no longer produces enough edges on its own to exceed chunk_edge_floor, so this
    // scenario alone would land within the (still-zero-derived) window rather than forcing
    // the growth this test exercises. Force it directly instead, the same way
    // "compactChunkEdges zeroes the chunk's edge counts on overflow..." does — the point
    // under test is the growth/no-further-allocation CONTRACT, not this specific
    // geometry's edge count.
    for (system.graph.chunk_edge_cap.items) |*cap| cap.* = 0;
    const stats = try system.applyNavUpdates(&data, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 1), stats.version_bumps);
    // The expansion produced new portals (the abstract graph grew past init).
    try std.testing.expect(system.graph.totalPortals() > 0);

    // A subsequent edit within the NEW high-water mark is allocation-free again.
    const closed = (try world.setDenseTile(wall_layer, 4, 4, tree)) orelse return error.TestExpectedEqual;
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const close_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = closed.level, .x = closed.x, .y = closed.y }});
    system.graph.allocator = original;
    system.allocator = original;
    try std.testing.expectEqual(@as(usize, 1), close_stats.incremental_rebuilds);
}

test "pathfinding incremental update flips cross-level link liveness when the endpoint cell changes" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_floor = try world.addDenseLayer(1, 0, .floor, grass);
    // Obstacle layer on level 1 so the link endpoint cell (2,2) can be flipped via the
    // dense tile API (which emits a WorldTileChangedEvent that drives applyNavUpdates).
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = level1_floor;
    _ = try world.setDenseTile(level1_obstacle, 2, 2, tree); // endpoint blocked
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    // Blocked endpoint: the link is not live, so the cross-level goal is unavailable.
    var blocked_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer blocked_stream.deinit();
    try appendPathRequest(&blocked_stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    try std.testing.expectEqual(@as(usize, 1), (try system.updateSerial(&blocked_stream, 8, .{})).unavailable_results);

    // Open the endpoint cell (2,2) on level 1 via the world tile API + incremental
    // update. buildLinkEdges re-derives link liveness against the current masks, so
    // the link becomes live and the same cross-level goal is now reachable.
    const changed = (try world.setDenseTile(level1_obstacle, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    // Incremental edit keeps nav_version stable; the prior unavailable entry is dropped,
    // so the same cross-level goal re-solves as live.
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    var open_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer open_stream.deinit();
    try appendPathRequest(&open_stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const open_stats = try system.updateSerial(&open_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), open_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), open_stats.cross_level_solves);
}

// Drives `count` simultaneous single-goal individual requests in one step, one per
// requester, returning the step stats. Used by the elastic-capacity tests.
fn driveAgentCount(system: *PathfindingSystem, requesters: []const EntityId, count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    for (requesters[0..count], 0..) |entity, i| {
        const start_x: f32 = 8.0 + @as(f32, @floatFromInt(i)) * 32.0;
        try appendPathRequest(&stream, .{ .entity = entity, .start = .{ .x = start_x, .y = 8 }, .goal = .{ .x = 480, .y = 480 } });
    }
    return system.updateSerial(&stream, count, .{});
}

test "pathfinding capacity grows when agent count jumps past the current cap" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [40]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // Floored at the initial reserve (min_capacity_floor = 8).
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);

    // A jump to 40 agents grows the live capacity amortized to at least 40 and the
    // per-step caps follow; every distinct goal still solves (here all share one).
    const stats = try driveAgentCount(&system, &requesters, 40);
    try std.testing.expect(system.effective_agent_capacity >= 40);
    try std.testing.expect(system.capacity.max_pending_requests >= 40);
    try std.testing.expect(system.completed.slots.items.len >= 40 * cached_results_per_agent);
    try std.testing.expectEqual(@as(usize, 1), stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding per-frame solve budget stays fixed while queue and cache scale to population" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 4096;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // A 4096-agent population grows the queue and cache to population, but the
    // per-frame A* solve and fallback budgets stay pinned to the fixed amortization
    // ceiling so a diverse-goal burst spreads across frames.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 480, .y = 480 } });
    _ = try system.updateSerial(&stream, 4096, .{});

    try std.testing.expectEqual(@as(usize, 4096), system.capacity.max_pending_requests);
    try std.testing.expectEqual(@as(usize, 4096), system.capacity.max_frame_requests);
    try std.testing.expectEqual(@as(usize, 4096 * cached_results_per_agent), system.capacity.max_cached_results);
    // Solve/fallback budgets capped at the fixed per-frame ceiling, NOT population.
    try std.testing.expectEqual(default_max_solves_per_frame, system.capacity.max_solved_requests_per_step);
    try std.testing.expectEqual(default_max_solves_per_frame, system.capacity.max_fallback_requests_per_step);
    // The worker path-pool stride sizes off the fixed solve ceiling, not population.
    try std.testing.expectEqual(default_max_solves_per_frame * system.capacity.max_stored_path_cells, system.worker_path_pool.items.len);
    try std.testing.expect(system.solve_results.capacity <= default_max_solves_per_frame * 2);
}

test "pathfinding capacity shrinks only after the sustained low-load window" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [40]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    capacity.capacity_shrink_window = 5;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    _ = try driveAgentCount(&system, &requesters, 40);
    const grown = system.effective_agent_capacity;
    try std.testing.expect(grown >= 40);

    // Low load (1 agent, below half capacity) for fewer than the window steps: the
    // hysteresis holds capacity steady, no shrink yet.
    for (0..capacity.capacity_shrink_window - 1) |_| {
        _ = try driveAgentCount(&system, &requesters, 1);
        try std.testing.expectEqual(grown, system.effective_agent_capacity);
    }
    // The window-th sustained low-load step shrinks toward the floor.
    _ = try driveAgentCount(&system, &requesters, 1);
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
}

test "pathfinding capacity stays unchanged across a steady-state solve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [16]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // Grow once to a steady 16-agent load.
    _ = try driveAgentCount(&system, &requesters, 16);
    const steady_cap = system.effective_agent_capacity;
    const steady_pending = system.pending.capacity;
    const steady_cache = system.completed.slots.items.len;
    const steady_pool = system.worker_path_pool.items.len;
    // A constant agent count holds capacity (and every pool's backing) fixed across
    // many steps, so the per-step solve loop never reallocates after warmup.
    for (0..30) |_| {
        _ = try driveAgentCount(&system, &requesters, 16);
        try std.testing.expectEqual(steady_cap, system.effective_agent_capacity);
        try std.testing.expectEqual(steady_pending, system.pending.capacity);
        try std.testing.expectEqual(steady_cache, system.completed.slots.items.len);
        try std.testing.expectEqual(steady_pool, system.worker_path_pool.items.len);
    }
}

test "pathfinding capacity shrink preserves surviving pending keys/tiers and counts the rest as dropped" {
    // Live deferred (never-solved) pending requests must survive a resize with their key and
    // tier intact, and pending_keys must be rebuilt to match exactly the survivors — a drop
    // past the new smaller capacity is real lost work and must be counted via resize_dropped,
    // not silently discarded. Previously uncovered by any test.
    //
    // pending_count is deliberately large (not derived from min_capacity_floor): resizeArrayList
    // shrinks-and-frees to 0 then re-reserves the floor capacity, and the allocator's own
    // size-class rounding can hand back a live capacity well above the requested floor. A large
    // pending_count guarantees an actual truncation regardless of that rounding, so the test
    // reads the real post-resize survivor count rather than asserting one derived in advance.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const pending_count = 200;
    var requesters: [pending_count]EntityId = undefined;
    for (0..pending_count) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = pending_count;
    capacity.capacity_shrink_window = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 8192, 8192, 32);

    // Zero fallback budget (a per-call PathfindingConfig override, NOT PathfindingCapacity —
    // deriveCapacity unconditionally overwrites the capacity-level field every step): every
    // accepted request stays .deferred (never solved), so all pending_count entries remain
    // live across every subsequent step, matching "pathfinding zero fallback budget leaves an
    // empty fallback list without panicking"'s pattern.
    const no_fallback = PathfindingConfig{ .max_fallback_requests_per_step = 0 };

    // Distinct goals so every request is its own pending entry (no goal-keyed dedup).
    var fill_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer fill_stream.deinit();
    try fill_stream.reserve(pending_count, pending_count);
    var goals: [pending_count]math.Vec2 = undefined;
    for (0..pending_count) |i| {
        goals[i] = .{ .x = 8 + @as(f32, @floatFromInt(i)) * 32, .y = 4000 };
        try appendPathRequest(&fill_stream, .{ .entity = requesters[i], .start = .{ .x = 8, .y = 8 }, .goal = goals[i] });
    }
    // Grows capacity to pending_count in the same step the requests are accepted, so nothing
    // is dropped here — the snapshot taken by this grow is of the still-empty queue.
    const fill_stats = try system.updateSerial(&fill_stream, pending_count, no_fallback);
    try std.testing.expectEqual(@as(usize, pending_count), fill_stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, pending_count), system.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), fill_stats.dropped_requests);

    // Sustained low load (agent_count 1, no new requests) shrinks the derived capacity to the
    // floor once the hysteresis window elapses.
    var empty_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty_stream.deinit();
    var last_stats: PathfindingStats = undefined;
    for (0..capacity.capacity_shrink_window) |_| {
        last_stats = try system.updateSerial(&empty_stream, 1, no_fallback);
    }
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
    // Survivors are clamped to the LOGICAL floor cap (min_capacity_floor), not pending's
    // physical (allocator-rounded) ArrayList capacity, which can run well above it — the
    // exact bug this test was written to catch: pending_keys is reserved to the logical cap,
    // so retaining more than that would silently break dedup for the excess entries.
    const survivor_count = system.pending.items.len;
    try std.testing.expectEqual(min_capacity_floor, survivor_count);
    try std.testing.expectEqual(pending_count - survivor_count, last_stats.dropped_requests);

    // The surviving entries (snapshot order, so the first survivor_count original requests)
    // keep their key and tier intact; pending_keys is rebuilt to match exactly them.
    for (0..survivor_count) |i| {
        try std.testing.expectEqual(@as(u8, 0), system.pending.items[i].tier);
        try std.testing.expect(system.pending_keys.contains(system.pending.items[i].key));
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goals[i], .default, null).status);
    }
    // The dropped entries' goals now read missing (retryable), never a stale "still pending".
    for (survivor_count..pending_count) |i| {
        try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goals[i], .default, null).status);
    }
}

test "pathfinding group-field threshold derives from grid size, not population" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // No explicit min_group_field_agents (derive from grid). Budget large enough that
    // the grid-derived threshold, not the population cap, governs on the demo grid.
    try system.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 4096 });
    // 512x512 px / 32 px cell = 16x16 = 256 cells... use the demo's nav resolution:
    // a 512x512-cell grid (512x512 world at 1px cells) gives 262144 cells.
    try system.rebuildStaticNavGrid(&data, 16384, 16384, 32);
    try std.testing.expectEqual(@as(usize, 512 * 512), system.graph.cellCount());

    // 262144 / 256 = 1024 same-goal sharers required before the field builds.
    try std.testing.expectEqual(@as(usize, 1024), system.groupFieldThreshold());

    // A small same-goal group at this grid size never reaches the threshold, so no
    // O(cells) flow field is built (the demo's 8 agents stay on individual A*).
    const goal = math.Vec2{ .x = 400, .y = 400 };
    var built: usize = 0;
    for (0..8) |_| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try stream.reserve(2, 2);
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
        try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
        const stats = try system.updateSerial(&stream, 2, .{});
        built += stats.group_fields_built;
    }
    try std.testing.expectEqual(@as(usize, 0), built);
}

test "pathfinding group-field threshold floors on a tiny grid and caps by population" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 4096 });
    // A 32x32-cell grid (1024 cells) would derive 1024/256 = 4, below the floor (64),
    // so the floor governs.
    try system.rebuildStaticNavGrid(&data, 1024, 1024, 32);
    try std.testing.expectEqual(@as(usize, 32 * 32), system.graph.cellCount());
    try std.testing.expectEqual(group_field_threshold_floor, system.groupFieldThreshold());

    // With a tiny budget (max possible population 8) below the floor, the budget cap
    // wins so the threshold never demands more sharers than can ever exist.
    var capped = PathfindingSystem.init(std.testing.allocator);
    defer capped.deinit();
    try capped.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 8 });
    try capped.rebuildStaticNavGrid(&data, 1024, 1024, 32);
    try std.testing.expectEqual(@as(usize, 8), capped.groupFieldThreshold());
}

// A full-height wall with a single far gap forces the longest possible detour — the
// shape of the reported water/lake FPS-collapse bug. Runs the SAME scenario at two
// scales against the corrected fixed-budget two-tier ladder, asserting a DIFFERENT
// expected outcome at each: the reported bug's exact scale must solve cleanly, and a
// genuinely harder one must gracefully degrade — proving graceful degradation actually
// triggers rather than the fixed tier-1 budget happening to be big enough for every case.
// Either way, never more than 2 solve attempts (never the old unbounded retry storm).
fn runLakeDetourScenario(system: *PathfindingSystem, side: usize, gap_offset: usize) !PathfindingStats {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const wall_x: usize = side / 2;
    const gap_y: usize = side - gap_offset;
    for (0..side) |y| {
        if (y == gap_y) continue;
        _ = try addNavBody(&data, .{ .x = @as(f32, @floatFromInt(wall_x)) * 32.0, .y = @as(f32, @floatFromInt(y)) * 32.0 }, .{ .x = 32, .y = 32 }, true);
    }
    const extent = @as(f32, @floatFromInt(side)) * 32.0;
    try system.rebuildStaticNavGrid(&data, extent, extent, 32);

    const start = math.Vec2{ .x = 8, .y = 8 * 32.0 + 8 };
    const goal = math.Vec2{ .x = @as(f32, @floatFromInt(side - 1)) * 32.0 + 8, .y = 8 * 32.0 + 8 };
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();

    var total_attempts: usize = 0;
    var frame: usize = 0;
    while (frame < 5) : (frame += 1) {
        const stats = try system.updateSerial(if (frame == 0) &stream else &empty, 8, .{});
        total_attempts += stats.budget_exhausted;
        if (stats.available_results != 0 or stats.escalated_dropped != 0) {
            var result = stats;
            result.budget_exhausted = total_attempts;
            return result;
        }
    }
    return error.TestUnexpectedResult;
}

test "pathfinding lake detour: reported-bug scale solves, a harder scale degrades gracefully, both bounded to 2 attempts" {
    var reported_scale = PathfindingSystem.init(std.testing.allocator);
    defer reported_scale.deinit();
    var reported_capacity = baselineCapacity();
    reported_capacity.max_agent_budget = 64;
    try reported_scale.reserve(reported_capacity);
    const reported = try runLakeDetourScenario(&reported_scale, 256, 5);
    try std.testing.expectEqual(@as(usize, 1), reported.available_results);
    try std.testing.expectEqual(@as(usize, 0), reported.escalated_dropped);
    try std.testing.expect(reported.budget_exhausted <= 2);

    // Was 512 before nav_graph.zig's discoverChunkPortals consolidated per-cell portals
    // into one per contiguous open boundary run: the abstract graph is now far sparser
    // (each fixed abstract-node budget covers much more physical distance per node
    // explored), so 512 no longer exhausts the tier-1 budget — this scale is retuned to
    // the smallest that still genuinely degrades under the new, sparser graph.
    var harder_scale = PathfindingSystem.init(std.testing.allocator);
    defer harder_scale.deinit();
    var harder_capacity = baselineCapacity();
    harder_capacity.max_agent_budget = 64;
    try harder_scale.reserve(harder_capacity);
    const harder = try runLakeDetourScenario(&harder_scale, 1024, 5);
    try std.testing.expectEqual(@as(usize, 0), harder.available_results);
    try std.testing.expectEqual(@as(usize, 1), harder.escalated_dropped);
    try std.testing.expect(harder.budget_exhausted <= 2);
}

// The reported-bug-scale detour above solves cleanly under the default segment cap
// (its corridor needs more than one stitched segment, but comfortably under
// default_max_stitch_segments). Forcing max_stitch_segments down to 1 must make that
// SAME scale degrade the same graceful way the untouched harder (512) scale degrades
// above — proving max_stitch_segments is a genuine, independently-enforced ceiling on
// stitching work, not merely inferred from the abstract-node or stitched-cell budgets.
test "pathfinding max_stitch_segments bounds stitching independent of corridor length" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.max_stitch_segments = 1;
    try system.reserve(capacity);
    const result = try runLakeDetourScenario(&system, 256, 5);
    try std.testing.expectEqual(@as(usize, 0), result.available_results);
    try std.testing.expectEqual(@as(usize, 1), result.escalated_dropped);
}
