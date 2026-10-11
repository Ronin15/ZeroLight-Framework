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
const simd = @import("../../../core/simd.zig");
const logging = @import("../../../core/logging.zig");
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const BatchSelection = @import("../../../app/thread_system.zig").BatchSelection;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const JobFn = @import("../../../app/thread_system.zig").JobFn;
const ParallelForOptions = @import("../../../app/thread_system.zig").ParallelForOptions;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
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
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const ColliderView = @import("../static_colliders.zig").ColliderView;
const ColliderChange = @import("../static_colliders.zig").ColliderChange;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavExtent = @import("nav_graph.zig").NavExtent;
const NavUpdateThreads = @import("nav_graph.zig").NavUpdateThreads;
const NavGrid = @import("nav_grid.zig").NavGrid;
const GroupField = @import("group_field.zig").GroupField;
const group_field_cell_limit = @import("group_field.zig").group_field_cell_limit;
const initialPoolBlocks = @import("group_field.zig").initialPoolBlocks;
const SearchScratch = @import("scratch.zig").SearchScratch;
const Tier1Scratch = @import("scratch.zig").Tier1Scratch;
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
const NavMark = types.NavMark;
const NavUpdateStats = types.NavUpdateStats;
const PendingRequest = types.PendingRequest;
const PendingRing = types.PendingRing;
const IntakeRecord = types.IntakeRecord;
const GroupKeyCount = types.GroupKeyCount;
const IntakeTally = types.IntakeTally;
const intake_range_alignment_items = types.intake_range_alignment_items;
const thread_shared_record_alignment = types.thread_shared_record_alignment;
const resizeList = types.resizeList;
const PathSolveResult = types.PathSolveResult;
const GroupRequestTally = types.GroupRequestTally;
const PhaseTimer = types.PhaseTimer;
const emptyKey = types.emptyKey;
const keysEqual = types.keysEqual;
const setLen = types.setLen;
const resizeArrayList = types.resizeArrayList;
const resizeFilledArrayList = types.resizeFilledArrayList;
const no_parent = types.no_parent;
const no_cell = types.no_cell;
const min_capacity_floor = types.min_capacity_floor;
const default_max_agent_budget = types.default_max_agent_budget;
const cached_results_per_agent = types.cached_results_per_agent;
const default_max_solves_per_frame = types.default_max_solves_per_frame;
const deriveCapacity = types.deriveCapacity;
const default_goal_projection_radius = types.default_goal_projection_radius;
const pathfinding_range_alignment_items = types.pathfinding_range_alignment_items;
const GridCell = types.GridCell;

// `fallback_tier1_slot` entry of a tier-0 admission.
const no_tier1_slot: u32 = std.math.maxInt(u32);

const IntakeRecordList = std.ArrayListAligned(IntakeRecord, .fromByteUnits(thread_shared_record_alignment));
const GroupKeyCountList = std.ArrayListAligned(GroupKeyCount, .fromByteUnits(thread_shared_record_alignment));
const IntakeTallyList = std.ArrayListAligned(IntakeTally, .fromByteUnits(thread_shared_record_alignment));
const NavMarkList = std.ArrayListAligned(NavMark, .fromByteUnits(thread_shared_record_alignment));
const NavMarkTallyList = std.ArrayListAligned(NavMarkTally, .fromByteUnits(thread_shared_record_alignment));

// One `nav_mark` range's mark count, padded to its own cache line.
const NavMarkTally = struct {
    count: usize align(thread_shared_record_alignment) = 0,
};

// `nav_mark` range alignment: every range's staging window (one mark slot per event)
// starts on a cache line.
const nav_mark_range_alignment_items: usize = 4 * simd.lane_count;

comptime {
    std.debug.assert((nav_mark_range_alignment_items * @sizeOf(NavMark)) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(NavMarkTally) % thread_shared_record_alignment == 0);
}

pub const PathfindingSystem = struct {
    allocator: std.mem.Allocator,
    capacity: PathfindingCapacity = .{},
    step_counter: u32 = 0,
    graph: NavGraph,
    pending: PendingRing = .{},
    // `path_intake` staging: one record and one group-key slot per admitted request (each
    // range writes only its own window) and one padded tally per range. Reserved at the
    // capacity seam from max_frame_requests.
    intake_records: IntakeRecordList = .empty,
    intake_group_counts: GroupKeyCountList = .empty,
    intake_tallies: IntakeTallyList = .empty,
    // Indexed by fallback ordinal (the solve batch's item index).
    solve_results: std.ArrayList(PathSolveResult) = .empty,
    fallback_indices: std.ArrayList(usize) = .empty,
    completed: ResultCache = .{},
    unavailable: KeySet = .{},
    pending_keys: KeySet = .{},
    group_fields: std.ArrayList(GroupField) = .empty,
    // Field slots one `group_field_expand` pass expands, one field per item.
    group_field_slots: std.ArrayList(usize) = .empty,
    // Requested group goal keys this step (declared, never detected).
    group_requests: std.ArrayList(GroupRequestTally) = .empty,
    // O(1) key → group_requests slot-index lookup for recordGroupRequestCount.
    // Kept in sync with group_requests: insert on append, remove+updateIndex on swapRemove.
    group_key_map: GroupKeyMap = .{},
    // One search scratch slot per configured threaded participant (workers + 1), its
    // tables sized by the node budgets at the capacity seam, never by level cells.
    scratch_slots: std.ArrayList(SearchScratch) = .empty,
    /// Tier-1 corridor scratch, one entry per `max_escalated_solves_per_step`; an escalated
    /// solve runs in the entry of its escalated admission index this step.
    tier1_scratch: std.ArrayList(Tier1Scratch) = .empty,
    /// Per fallback ordinal: its `tier1_scratch` entry, or `no_tier1_slot` for a tier-0
    /// request. Written by `prepareSolvePhase`.
    fallback_tier1_slot: std.ArrayList(u32) = .empty,
    // Reconstructed paths by fallback ordinal, written into completed by the main thread
    // after the worker batch finishes.
    solved_paths: std.ArrayList(SolvedPath) = .empty,
    // Per-request solve output: one `resultBlockWords` stripe at the request's fallback
    // ordinal holding its plain or stitched path, so two requests never collide even
    // when one worker solves several in the same range.
    worker_path_pool: std.ArrayList(u32) = .empty,
    next_group_evict: usize = 0,
    // Nav changes recorded since the last nav batch, consumed and cleared by the next one;
    // kept across a failed batch so the retry applies them. Terrain writers record right
    // after their world write and the commit seam right after the collider sync, each into
    // room reserved before its write, so a written change is never lost.
    nav_marks: std.ArrayList(NavMark) = .empty,
    // `nav_mark` staging: one mark slot per event (each range writes only its own window)
    // and one padded tally per range. Reserved with the terrain record, before the write.
    nav_mark_staging: NavMarkList = .empty,
    nav_mark_tallies: NavMarkTallyList = .empty,
    // Batch shape of the most recent `nav_mark` stage, for bench and diagnostic reporting.
    last_mark_batch: BatchStats = .{},
    // Off-main time of the terrain records since the last reaction, folded into its stats.
    pending_mark_off_main_ns: u64 = 0,
    /// Telemetry: mark reserves that grew the mark buffer, the `nav_mark` staging, or its
    /// tallies; logged once.
    nav_mark_grows: u64 = 0,
    nav_mark_growth_logged: bool = false,
    // Every admitted solve runs in the worker-driven fallback batch; this tuner owns its
    // adaptive profile. The request-side stages own theirs.
    fallback_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    intake_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // The group-field advance and begin passes see different item counts, so each pass
    // owns a tuner.
    group_field_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    group_field_begin_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Re-dispatches of fields stalled for pool room see only those few fields, so they own
    // a tuner rather than skew the passes'.
    group_field_stall_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // The incremental nav update has two independently-timed threaded stages — remask + component
    // re-flood, and the abstract chunk patch — so each owns its own tuner (per docs: one tuner
    // per stage, never shared across work shapes).
    nav_remask_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    nav_patch_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // The `nav_mark` stage (structural events interpreted into nav marks) and the nav
    // batch's key plan each own a tuner.
    nav_mark_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    nav_plan_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
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
    /// Telemetry: publish reserves that grew the result cache's long-block pool.
    long_block_grows: u64 = 0,
    long_block_growth_logged: bool = false,
    /// Telemetry: group-field block pools reserved or grown (first builds and stalls), and
    /// growths that ran out of memory (the field stays stalled and retries next step);
    /// each logged once.
    group_field_pool_grows: u64 = 0,
    group_field_pool_growth_logged: bool = false,
    group_field_pool_failures: u64 = 0,
    group_field_pool_failure_logged: bool = false,
    // Reusable safe-point snapshot buffers. A resize preserves the live deferred work and
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
    /// Upper clamp for `groupFieldThreshold`: the configured agent ceiling, frozen at
    /// `reserve` (floored at `min_capacity_floor`), so a seam raise (`raiseAgentBudget`)
    /// never moves a per-query policy. Behavior follows configuration, not capacity history.
    group_field_threshold_ceiling: usize = default_max_agent_budget,

    const SolvedPath = struct {
        key: PathQueryKey,
        offset: usize,
        len: usize,
        // Stitched corridor cells in the same stripe; zero for a plain local solve, whose
        // cells are `len` words. A stitched result has `len` 0.
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
        for (self.tier1_scratch.items) |*entry| entry.deinit(self.allocator);
        for (self.group_fields.items) |*field| field.deinit(self.allocator);
        self.rotate_back_scratch.deinit(self.allocator);
        self.resize_group_snapshot.deinit(self.allocator);
        self.resize_pending_snapshot.deinit(self.allocator);
        self.nav_mark_tallies.deinit(self.allocator);
        self.nav_mark_staging.deinit(self.allocator);
        self.nav_marks.deinit(self.allocator);
        self.worker_path_pool.deinit(self.allocator);
        self.solved_paths.deinit(self.allocator);
        self.scratch_slots.deinit(self.allocator);
        self.tier1_scratch.deinit(self.allocator);
        self.group_requests.deinit(self.allocator);
        self.group_key_map.deinit(self.allocator);
        self.group_field_slots.deinit(self.allocator);
        self.group_fields.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.unavailable.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.fallback_tier1_slot.deinit(self.allocator);
        self.fallback_indices.deinit(self.allocator);
        self.solve_results.deinit(self.allocator);
        self.intake_tallies.deinit(self.allocator);
        self.intake_group_counts.deinit(self.allocator);
        self.intake_records.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.graph.deinit();
        self.* = undefined;
    }

    // The fixed per-query group-field threshold (see default_min_group_field_agents), never
    // derived from world size. Clamped to [1, group_field_threshold_ceiling]: the configured
    // max_agent_budget frozen at reserve, NOT live max_pending_requests (a small live crowd
    // never pulls the threshold down) and NOT the live ceiling a seam raise lifts (capacity
    // history never moves the policy). The threshold never demands more sharers than the
    // configured ceiling admits. A pin of 0 clamps to 1.
    pub fn groupFieldThreshold(self: *const PathfindingSystem) usize {
        return std.math.clamp(self.capacity.min_group_field_agents, 1, self.group_field_threshold_ceiling);
    }

    pub fn reserve(self: *PathfindingSystem, capacity: PathfindingCapacity) !void {
        // A field's bucket links pack its block ids, which stay below its cell cap.
        if (capacity.group_field_max_cells >= group_field_cell_limit) return error.OutOfMemory;
        self.group_field_threshold_ceiling = @max(min_capacity_floor, capacity.max_agent_budget);
        // Reserve modestly for the floor agent count, not the full ceiling, so the
        // elastic path can later grow and shrink. The ceiling/ratio/window knobs are
        // retained in self.capacity; per-step caps are derived and grown on demand.
        try self.applyDerivedCapacity(capacity, min_capacity_floor);
    }

    // Sizes every pool from caps derived for `agent_count`. Used by reserve() at init and
    // by adjustCapacityForAgentCount() at the safe point. ArrayList pools grow amortized
    // and shrink-and-free; the result cache and the negative set keep their entries (a
    // shrink evicts what no longer fits). The caller preserves the pending queue and group
    // tally, which these pools do not carry across.
    //
    // The logical limits (`self.capacity`, `effective_agent_capacity`) are committed only
    // after every pool fits them. On a mid-resize OOM each pool still holds its old or its
    // new storage (the resize helpers never free before the replacement exists), so the
    // limits and the search budgets fall back to the smaller of the two, which every pool
    // fits: an intake gate can never `appendAssumeCapacity` past a pool's real capacity, and
    // no solve writes past its path stripe.
    //
    // Search scratch and the tier-1 pool are sized by fixed budgets, never by level cells:
    // their reserves are no-ops at unchanged budgets (so an elastic resize never touches
    // them), each table is replaced only after its new storage exists, and an entry joins
    // its list only once reserved. Group fields get headers only; their pools follow the
    // chunks a build covers.
    fn applyDerivedCapacity(self: *PathfindingSystem, base: PathfindingCapacity, agent_count: usize) !void {
        const capacity = deriveCapacity(base, agent_count);
        errdefer {
            const previous_agents = self.effective_agent_capacity;
            var fallback = deriveCapacity(base, @min(agent_count, previous_agents));
            if (previous_agents == 0) {
                // Never reserved: nothing is guaranteed to fit, so admit nothing.
                fallback.max_frame_requests = 0;
                fallback.max_pending_requests = 0;
                fallback.max_cached_results = 0;
                fallback.max_solved_requests_per_step = 0;
                fallback.max_fallback_requests_per_step = 0;
            }
            // Escalated admissions never pass the reserved tier-1 entries.
            fallback.max_escalated_solves_per_step = @min(fallback.max_escalated_solves_per_step, self.tier1_scratch.items.len);
            // Each budget-sized table holds its committed or its requested budget, so the
            // smaller of the two fits every one (the path pool, resized last, still holds the
            // committed stripes), and every search clamps to it.
            const committed = self.capacity;
            fallback.max_explored_nodes = @min(committed.max_explored_nodes, capacity.max_explored_nodes);
            fallback.max_stored_path_cells = @min(committed.max_stored_path_cells, capacity.max_stored_path_cells);
            fallback.max_abstract_nodes = @min(committed.max_abstract_nodes, capacity.max_abstract_nodes);
            fallback.max_stitched_path_cells = @min(committed.max_stitched_path_cells, capacity.max_stitched_path_cells);
            fallback.tier0_abstract_node_cap = @min(committed.tier0_abstract_node_cap, capacity.tier0_abstract_node_cap);
            fallback.tier0_stitched_cell_cap = @min(committed.tier0_stitched_cell_cap, capacity.tier0_stitched_cell_cap);
            fallback.max_group_fields = @min(committed.max_group_fields, capacity.max_group_fields);
            fallback.group_field_max_cells = @min(committed.group_field_max_cells, capacity.group_field_max_cells);
            self.capacity = fallback;
            self.effective_agent_capacity = fallback.max_pending_requests;
        }
        try self.pending.reserve(self.allocator, capacity.max_pending_requests);
        try resizeList(&self.intake_records, self.allocator, capacity.max_frame_requests);
        try resizeList(&self.intake_group_counts, self.allocator, capacity.max_frame_requests);
        try resizeList(&self.intake_tallies, self.allocator, maxRangeCount(capacity.max_frame_requests, intake_range_alignment_items));
        try resizeArrayList(PathSolveResult, &self.solve_results, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(usize, &self.fallback_indices, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(u32, &self.fallback_tier1_slot, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(SolvedPath, &self.solved_paths, self.allocator, capacity.max_solved_requests_per_step);
        // Sized to the solve window: at most one front-window entry per solved slot can be
        // rotated to the back in a single compaction.
        try resizeArrayList(PendingRequest, &self.rotate_back_scratch, self.allocator, capacity.max_solved_requests_per_step);
        // Logical capacity only: every ProbeTable/ResultCache reserve internally doubles
        // physical slots for probe headroom, so callers pass the true entry-count ceiling,
        // never a caller-side multiplier (one load-factor policy, not two stacked).
        try self.completed.reserve(self.allocator, capacity.max_cached_results, capacity.max_stored_path_cells, types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells), self.step_counter);
        try self.unavailable.reserve(self.allocator, capacity.max_cached_results);
        try self.pending_keys.reserve(self.allocator, capacity.max_pending_requests);
        // Field slots first: every header appended at the end already has its slot, so no
        // failure point leaves more fields than slots. Headers hold no pool (a field
        // reserves its pool at its first build) and are never removed by a shrink.
        try self.group_field_slots.ensureTotalCapacity(self.allocator, @max(capacity.max_group_fields, self.group_fields.items.len));
        try self.group_fields.ensureTotalCapacity(self.allocator, capacity.max_group_fields);
        try resizeArrayList(GroupRequestTally, &self.group_requests, self.allocator, capacity.max_solved_requests_per_step);
        try self.group_key_map.reserve(self.allocator, capacity.max_solved_requests_per_step);
        // The steady-path mark high-water, with the `nav_mark` staging and tallies to record
        // as many events; the terrain record reserve grows them for a larger step.
        try self.nav_marks.ensureTotalCapacity(self.allocator, capacity.max_frame_requests);
        try self.nav_mark_staging.ensureTotalCapacity(self.allocator, capacity.max_frame_requests);
        try self.nav_mark_tallies.ensureTotalCapacity(self.allocator, maxRangeCount(capacity.max_frame_requests, nav_mark_range_alignment_items));
        // One scratch slot per threaded participant (workers + main), its corridor scratch
        // at the tier-0 caps (clamped to the tier-1 ceiling, as each solve clamps them).
        const scratch_slots = @max(@as(usize, 1), capacity.worker_participant_count);
        const tier0_abstract_nodes = @min(capacity.tier0_abstract_node_cap, capacity.max_abstract_nodes);
        const tier0_stitched_cells = @min(capacity.tier0_stitched_cell_cap, capacity.max_stitched_path_cells);
        try self.scratch_slots.ensureTotalCapacity(self.allocator, scratch_slots);
        for (self.scratch_slots.items) |*scratch| {
            try scratch.reserve(self.allocator, capacity.max_explored_nodes, tier0_abstract_nodes, tier0_stitched_cells);
        }
        while (self.scratch_slots.items.len < scratch_slots) {
            var scratch = SearchScratch{};
            errdefer scratch.deinit(self.allocator);
            try scratch.reserve(self.allocator, capacity.max_explored_nodes, tier0_abstract_nodes, tier0_stitched_cells);
            self.scratch_slots.appendAssumeCapacity(scratch);
        }
        // One tier-1 corridor entry per escalated solve a step admits, at the tier-1 caps.
        try self.tier1_scratch.ensureTotalCapacity(self.allocator, capacity.max_escalated_solves_per_step);
        for (self.tier1_scratch.items) |*entry| {
            try entry.corridor.reserve(self.allocator, capacity.max_abstract_nodes, capacity.max_stitched_path_cells);
        }
        while (self.tier1_scratch.items.len < capacity.max_escalated_solves_per_step) {
            var entry = Tier1Scratch{};
            errdefer entry.deinit(self.allocator);
            try entry.corridor.reserve(self.allocator, capacity.max_abstract_nodes, capacity.max_stitched_path_cells);
            self.tier1_scratch.appendAssumeCapacity(entry);
        }
        // One disjoint path stripe per solved request this step (indexed by the
        // dense fallback position), so workers never overwrite each other's
        // reconstructed paths even when one worker solves several requests.
        const pool_words = capacity.max_solved_requests_per_step * types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells);
        try resizeFilledArrayList(u32, &self.worker_path_pool, self.allocator, pool_words, no_cell);
        // Infallible, so a failed reserve never leaves more headers than its fallback.
        while (self.group_fields.items.len < capacity.max_group_fields) self.group_fields.appendAssumeCapacity(.{});
        self.capacity = capacity;
        self.effective_agent_capacity = capacity.max_pending_requests;
    }

    /// The live agent ceiling: `max_agent_budget`, floored at `min_capacity_floor`.
    pub fn agentBudget(self: *const PathfindingSystem) usize {
        return @max(min_capacity_floor, self.capacity.max_agent_budget);
    }

    /// O(1): true when the live pools and the ceiling already cover `agent_count` steering
    /// agents, so the population seam has no pathfinding growth to do.
    pub fn coversAgentCount(self: *const PathfindingSystem, agent_count: usize) bool {
        if (self.effective_agent_capacity == 0) return true;
        if (agent_count > self.agentBudget()) return false;
        return deriveCapacity(self.capacity, agent_count).max_pending_requests <= self.effective_agent_capacity;
    }

    /// Raises `max_agent_budget` to `requested` (never lowers it). Population is
    /// runtime-growing, so the raise is never refused. Main thread, population seam. Never writes
    /// `group_field_threshold_ceiling`: a raise lifts capacity, not policy.
    pub fn raiseAgentBudget(self: *PathfindingSystem, requested: usize) void {
        self.capacity.max_agent_budget = @max(self.capacity.max_agent_budget, requested);
    }

    /// Grow half of the elastic resize: when `agent_count` derives more than the live
    /// capacity, grows (at least 2x, clamped to `agentBudget()`) preserving live state.
    /// Called from the pipeline's population seam and from `beginUpdate`'s safety net.
    pub fn growForAgentCount(self: *PathfindingSystem, agent_count: usize) !void {
        if (self.effective_agent_capacity == 0) return; // not reserved yet
        const target = deriveCapacity(self.capacity, agent_count).max_pending_requests;
        const current = self.effective_agent_capacity;
        if (target <= current) return;
        self.low_load_steps = 0;
        // Amortized grow: at least double, clamped to the ceiling, so one realloc
        // covers many future spawns.
        const grown = @min(@max(target, current *| 2), self.agentBudget());
        try self.resizePreservingLiveState(grown);
    }

    // Adjusts the live capacity toward the agent count at the pre-dispatch safe
    // point: after the previous frame's results were published and before this
    // step's accept/solve, on the single thread, with no in-flight worker indices or
    // pool offsets. Grows fast (amortized ~2x) for a battle; shrinks only after a
    // sustained low-load window (hysteresis). The per-step solve loop never allocates
    // because capacity is already adequate by the time it runs.
    //
    // Index/pointer-stability invariant verified for every resized pool: at this
    // point the per-step scratch pools (intake staging, solve_results,
    // fallback_indices, solved_paths, worker_path_pool) are empty/cleared from last
    // step's prepare*, so no live offset spans the resize.
    // pending/pending_keys/group_requests/completed/unavailable hold cross-step state;
    // completed and unavailable keep their entries through the resize, while pending and
    // the group tally round-trip through reusable snapshots and pending_keys is rebuilt
    // from the restored pending. Search scratch, the tier-1 pool, and group fields follow
    // fixed budgets an elastic resize does not change, so their reserves are no-ops here.
    // No worker runs.
    fn adjustCapacityForAgentCount(self: *PathfindingSystem, agent_count: usize) !void {
        if (self.effective_agent_capacity == 0) return; // not reserved yet
        const target = deriveCapacity(self.capacity, agent_count).max_pending_requests;
        const current = self.effective_agent_capacity;
        if (target > current) return self.growForAgentCount(agent_count);
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

    // Re-sizes all pools to `agent_count` while preserving the live deferred-work queue
    // and group tally. The goal-keyed result cache and negative set keep their entries
    // (a shrink evicts only what no longer fits), so a resize costs no re-solves.
    fn resizePreservingLiveState(self: *PathfindingSystem, agent_count: usize) !void {
        self.resize_pending_snapshot.clearRetainingCapacity();
        try self.resize_pending_snapshot.ensureTotalCapacity(self.allocator, self.pending.len);
        for (0..self.pending.len) |index| self.resize_pending_snapshot.appendAssumeCapacity(self.pending.at(index));
        self.resize_group_snapshot.clearRetainingCapacity();
        try self.resize_group_snapshot.ensureTotalCapacity(self.allocator, self.group_requests.items.len);
        self.resize_group_snapshot.appendSliceAssumeCapacity(self.group_requests.items);

        // A failed resize still restores the live state, clamped to the fallback limits
        // `applyDerivedCapacity` installs on error, so accepted work and its dedup keys
        // stay consistent after a recovered OOM.
        errdefer self.restoreLiveStateAfterResize();
        try self.applyDerivedCapacity(self.capacity, agent_count);
        self.restoreLiveStateAfterResize();
    }

    fn restoreLiveStateAfterResize(self: *PathfindingSystem) void {
        // Restore live deferred work (dropping any beyond the new, smaller capacity),
        // rebuild pending_keys to match, and restore the surviving group tally. Clamped to
        // the LOGICAL caps applyDerivedCapacity just installed (self.capacity.*), not the
        // ArrayList's own physical .capacity: the allocator's size-class rounding can hand
        // back a physical capacity well above the requested logical one, and pending_keys/
        // group_key_map were reserved to the exact logical cap — retaining more entries in
        // `pending`/`group_requests` than that would silently drop their dedup registration
        // (a live entry that reads back `.missing` instead of `.pending`, inviting a
        // duplicate accept) while resize_dropped undercounts the real loss.
        self.pending.clear();
        const keep_pending = @min(self.resize_pending_snapshot.items.len, self.capacity.max_pending_requests);
        self.pending_keys.clear();
        for (self.resize_pending_snapshot.items[0..keep_pending]) |pending_request| {
            self.pending.push(pending_request);
            _ = self.pending_keys.insert(pending_request.key);
        }
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

    /// The extent of a world-less build: one level over the bounds rect in `cell_size` cells
    /// and `capacity.nav_chunk_tiles` chunks.
    pub fn boundsNavExtent(self: *const PathfindingSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) NavExtent {
        return .{ .bounds = .{
            .width = bounds_width,
            .height = bounds_height,
            .cell_size = cell_size,
            .chunk_tiles = self.capacity.nav_chunk_tiles,
        } };
    }

    /// The extent of a build over every level of `world`.
    pub fn worldNavExtent(world: *const WorldSystem) NavExtent {
        return .{ .world = world };
    }

    /// Builds world-less nav over the bounds rect with the statics `data` holds now, through
    /// a static-collider build discarded afterwards. A nav that later applies changes takes
    /// its colliders from the caller (`rebuildNavFromColliders`).
    pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) !void {
        try self.rebuildNavFromData(data, self.boundsNavExtent(bounds_width, bounds_height, cell_size), null);
    }

    /// Builds nav over every level of `world` with the statics `data` holds now, through a
    /// static-collider build discarded afterwards: nav cells are the world's tiles and nav
    /// chunks its chunks. Fails loudly (`ChunkGridError`) when the nav grid's index widths
    /// do not fit, before sizing anything from them.
    pub fn rebuildStaticNavGridWithWorld(self: *PathfindingSystem, data: *const DataSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !void {
        try self.rebuildNavFromData(data, .{ .world = world }, thread_system);
    }

    fn rebuildNavFromData(self: *PathfindingSystem, data: *const DataSystem, extent: NavExtent, thread_system: ?*ThreadSystem) !void {
        var colliders = StaticColliderSystem.init(self.allocator);
        defer colliders.deinit();
        try colliders.rebuild(data, try extent.colliderGeometry());
        try self.rebuildNavFromColliders(&colliders, extent, thread_system);
    }

    /// Builds nav over `extent` with `colliders`' rows, which must be placed on the
    /// extent's cell grid (`NavExtent.colliderGeometry`). Every later apply passes the same
    /// colliders, synced at the commit seam.
    pub fn rebuildNavFromColliders(self: *PathfindingSystem, colliders: *const StaticColliderSystem, extent: NavExtent, thread_system: ?*ThreadSystem) !void {
        if (self.scratch_slots.items.len == 0) {
            try self.reserve(self.capacity);
        }
        try self.graph.rebuild(colliders.view(), extent, self.navUpdateThreads(thread_system));
        // Search scratch and group fields follow budgets reserved at the capacity seam, never
        // the level's cell count, so the build sizes nothing for them.
        // Grid versions are part of query keys. A rebuild invalidates pending
        // work and caches instead of trying to remap old requests onto new cells.
        self.clearRuntimeState();
        self.nav_marks.clearRetainingCapacity();
        // A rebuild can change cell/chunk counts and thus the per-item work cost, so the
        // adaptive tuners' learned profiles no longer apply — reset them to relearn against
        // the new topology rather than acting on a stale cost model.
        self.fallback_tuner = AdaptiveWorkTuner.init(.{});
        self.intake_tuner = AdaptiveWorkTuner.init(.{});
        self.group_field_tuner = AdaptiveWorkTuner.init(.{});
        self.group_field_begin_tuner = AdaptiveWorkTuner.init(.{});
        self.group_field_stall_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_remask_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_patch_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_mark_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_plan_tuner = AdaptiveWorkTuner.init(.{});
    }

    fn navUpdateThreads(self: *PathfindingSystem, thread_system: ?*ThreadSystem) ?NavUpdateThreads {
        const threads = thread_system orelse return null;
        return .{
            .thread_system = threads,
            .plan_tuner = &self.nav_plan_tuner,
            .remask_tuner = &self.nav_remask_tuner,
            .patch_tuner = &self.nav_patch_tuner,
            .adaptive = self.nav_thread_adaptive,
            .items_per_range = self.nav_thread_items_per_range,
        };
    }

    /// Marks `edits` and applies them with every other pending nav change, serially. For
    /// tests, benches, and direct callers; play marks from committed events.
    pub fn applyNavUpdates(
        self: *PathfindingSystem,
        colliders: *const StaticColliderSystem,
        world: *const WorldSystem,
        edits: []const NavCellEdit,
    ) !NavUpdateStats {
        try self.reserveNavMarks(edits.len);
        for (edits) |edit| appendMergedMark(&self.nav_marks, tileMark(edit.level, edit.x, edit.y, edit.x, edit.y), self.graph.chunk_tiles);
        return self.applyBufferedNavUpdates(colliders, world, null);
    }

    /// Drops every recorded nav mark.
    pub fn clearNavDirty(self: *PathfindingSystem) void {
        self.nav_marks.clearRetainingCapacity();
    }

    /// Records one changed world tile for the next nav batch. Grows the mark buffer rather
    /// than dropping.
    pub fn markNavDirty(self: *PathfindingSystem, level: u16, x: u16, y: u16) !void {
        try self.reserveNavMarks(1);
        appendMergedMark(&self.nav_marks, tileMark(level, x, y, x, y), self.graph.chunk_tiles);
    }

    /// The commit seam's static mark reserve, before the structural commit: room for the
    /// old and new span of `change_bound` collider changes (the colliders' pending changes
    /// plus one per command). No mark may be recorded between it and
    /// `recordStaticColliderChanges`. On error nothing changes.
    pub fn reserveStaticColliderMarks(self: *PathfindingSystem, change_bound: usize) !void {
        try self.reserveNavMarks(2 * change_bound);
    }

    /// Records a successful collider sync's changes for the next nav batch: each change's
    /// old and new cell spans. O(1) per change; allocation-free after
    /// `reserveStaticColliderMarks` covered them.
    pub fn recordStaticColliderChanges(self: *PathfindingSystem, changes: []const ColliderChange) void {
        std.debug.assert(self.nav_marks.capacity - self.nav_marks.items.len >= 2 * changes.len);
        self.appendColliderMarks(changes);
    }

    /// A terrain writer's record reserve, before its world write: room to record
    /// `event_bound` events (the writer's `maxEventsPerStep`) into the pending marks and
    /// through the `nav_mark` stage's staging and tallies. Geometric and counted. On error
    /// nothing changes and the writer must not write.
    pub fn reserveTerrainNavRecord(self: *PathfindingSystem, event_bound: usize) !void {
        var grew = try self.growNavMarks(event_bound);
        if (event_bound > self.nav_mark_staging.capacity) {
            try self.nav_mark_staging.ensureTotalCapacity(self.allocator, event_bound);
            grew = true;
        }
        const tally_bound = maxRangeCount(event_bound, nav_mark_range_alignment_items);
        if (tally_bound > self.nav_mark_tallies.capacity) {
            try self.nav_mark_tallies.ensureTotalCapacity(self.allocator, tally_bound);
            grew = true;
        }
        if (grew) self.countNavMarkGrowth();
    }

    /// Records the events one terrain writer appended (`world_tile_changed`,
    /// `world_obstacle_changed`) as pending marks, right after its world write and even when
    /// the writer failed after writing, so a written change reaches nav at the next apply.
    /// Allocation-free after `reserveTerrainNavRecord` covering `events.len`, with no mark
    /// recorded in between. A non-null `thread_system` lets the `nav_mark` stage thread;
    /// main work is O(1) per mark.
    pub fn recordTerrainNavEvents(self: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) void {
        if (events.len == 0) return;
        if (std.debug.runtime_safety) for (events) |event| {
            std.debug.assert(event.payload == .world_tile_changed or event.payload == .world_obstacle_changed);
        };
        self.pending_mark_off_main_ns += self.markNavEvents(events, world, thread_system);
    }

    // Appends each change's old and new cell spans into reserved mark capacity.
    fn appendColliderMarks(self: *PathfindingSystem, changes: []const ColliderChange) void {
        for (changes) |change| {
            inline for (.{ change.old, change.new }) |side| {
                if (side) |placement| appendMergedMark(&self.nav_marks, .{
                    .level = placement.level,
                    .kind = .static_span,
                    .min_x = placement.cells.min_x,
                    .min_y = placement.cells.min_y,
                    .max_x = placement.cells.max_x,
                    .max_y = placement.cells.max_y,
                }, self.graph.chunk_tiles);
            }
        }
    }

    // Grows the mark buffer to hold `count` more marks: the mark seam. Geometric, counted.
    fn reserveNavMarks(self: *PathfindingSystem, count: usize) !void {
        if (try self.growNavMarks(count)) self.countNavMarkGrowth();
    }

    // Grows the mark buffer to hold `count` more marks, geometrically; true when it grew.
    fn growNavMarks(self: *PathfindingSystem, count: usize) !bool {
        const needed = self.nav_marks.items.len + count;
        if (needed <= self.nav_marks.capacity) return false;
        try self.nav_marks.ensureTotalCapacity(self.allocator, needed);
        return true;
    }

    fn countNavMarkGrowth(self: *PathfindingSystem) void {
        self.nav_mark_grows += 1;
        if (self.nav_mark_growth_logged) return;
        self.nav_mark_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test) logging.game.info(
            "nav mark storage grew to {d} marks and {d} staged events",
            .{ self.nav_marks.capacity, self.nav_mark_staging.capacity },
        );
    }

    /// Whether the next nav update has work: recorded marks, or (nav built over `world`) a
    /// level, a link, or a content revision nav has not applied. O(1).
    pub fn hasPendingNavUpdates(self: *const PathfindingSystem, world: *const WorldSystem) bool {
        if (self.nav_marks.items.len != 0) return true;
        if (!self.graph.world_backed) return false;
        return world.levelCount() != self.graph.levelCount() or
            world.levelLinks().len != self.graph.links_applied or
            world.contentRevision() != self.graph.built_world_revision;
    }

    /// Applies every pending nav change, each step its own transaction: builds the levels
    /// the world added, rebuilds the levels whose content revision moved, then applies the
    /// recorded marks and new links as one batch. A committed step stays on a later error;
    /// marks and the level, revision, and link gaps stay pending for the next call. The
    /// world-wide revision is compared once; levels are walked only when it moved. A
    /// non-null `thread_system` lets each stage thread under its tuner.
    pub fn applyBufferedNavUpdates(self: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !NavUpdateStats {
        var stats = NavUpdateStats{};
        const threads = self.navUpdateThreads(thread_system);
        const view = colliders.view();
        if (self.graph.world_backed) {
            while (self.graph.levelCount() < world.levelCount()) {
                try self.graph.buildLevel(view, world, @intCast(self.graph.levelCount()), threads, &stats);
            }
            if (world.contentRevision() != self.graph.built_world_revision) {
                for (0..self.graph.levelCount()) |level_index| {
                    const level: u16 = @intCast(level_index);
                    if (self.graph.level_graphs.items[level].built_revision == world.levelContentRevision(level)) continue;
                    try self.graph.buildLevel(view, world, level, threads, &stats);
                    // The level changed without per-cell spans: no cached result is known good.
                    self.completed.clear();
                    self.clearRequestStateKeepingCompleted();
                    self.dropGroupFields();
                }
                self.graph.built_world_revision = world.contentRevision();
            }
        }
        if (try self.graph.prepareMarks(world, view, self.nav_marks.items, threads, &stats)) |prepared| {
            const batch = self.graph.commitMarks(prepared, view, threads, &stats);
            if (batch.changed) {
                // Graph node ids never persist, so cached results stay keyed by cells: evict
                // only those crossing a changed span.
                self.completed.evictCrossing(&self.graph, batch.spans);
                self.clearRequestStateKeepingCompleted();
                self.dropGroupFields();
            }
        }
        self.nav_marks.clearRetainingCapacity();
        return stats;
    }

    /// The post-commit nav reaction: applies every pending nav change (the marks terrain
    /// writers and the collider sync recorded, and the world's level, link, and revision
    /// gaps) and emits one `nav_region_invalidated` when the graph changed. Runs after
    /// `colliders` synced this step's commit. A failed apply keeps the marks and gaps for the
    /// next step.
    pub fn reactToPostCommitNavEvents(self: *PathfindingSystem, frame: *SimulationFrame, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !NavUpdateStats {
        const mark_off_main_ns = self.pending_mark_off_main_ns;
        self.pending_mark_off_main_ns = 0;
        if (!self.hasPendingNavUpdates(world)) return .{ .off_main_stage_ns = mark_off_main_ns };
        try frame.events.ensureCanAppend(1);
        var stats = try self.applyBufferedNavUpdates(colliders, world, thread_system);
        stats.off_main_stage_ns += mark_off_main_ns;
        if (stats.incremental_rebuilds == 0 and stats.levels_built == 0) return stats;
        try frame.events.appendRequired(.{
            .stage = .domain_reaction,
            .payload = .{ .nav_region_invalidated = .{ .reason = NavInvalidationReason.static_obstacle_changed } },
        });
        return stats;
    }

    // `nav_mark`: interprets world events into marks; `reserveTerrainNavRecord` reserved one
    // mark, one staging slot per event, and the tallies. Inline (no thread system, or the
    // tuner keeps it inline) one pass appends in event order. Dispatched, each range writes
    // its events' marks into its staging window, merging consecutive tile boxes of one
    // (level, chunk), and the main thread appends the windows in range order with the same
    // merge, so the marks equal the inline pass for any partition. Main work is O(marks
    // after the merge). Returns the stage's off-main time.
    fn markNavEvents(self: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) u64 {
        self.last_mark_batch = .{};
        if (events.len == 0) return 0;
        const mark_bound = events.len;
        std.debug.assert(self.nav_marks.capacity - self.nav_marks.items.len >= mark_bound);
        const ts = thread_system orelse {
            self.appendEventMarks(world, events);
            self.last_mark_batch = inlineBatch(events.len, nav_mark_range_alignment_items);
            return 0;
        };
        std.debug.assert(self.nav_mark_staging.capacity >= mark_bound);
        std.debug.assert(self.nav_mark_tallies.capacity >= maxRangeCount(events.len, nav_mark_range_alignment_items));
        const selection = ts.selectBatchProfile(&self.nav_mark_tuner, .{
            .item_count = events.len,
            .items_per_range = self.nav_thread_items_per_range,
            .range_alignment_items = nav_mark_range_alignment_items,
            .adaptive = self.nav_thread_adaptive,
        });
        const options = self.navMarkDispatchOptions(selection);
        if (selection.worker_threads == 0) {
            // Inline on the main thread in range order; still dispatched so the tuner
            // records the batch.
            var direct = DirectNavMarkJob{ .system = self, .world = world, .events = events };
            self.last_mark_batch = ts.parallelForWithOptions(events.len, &direct, directNavMarkJob, options);
            return 0;
        }
        std.debug.assert(self.nav_mark_tallies.capacity >= selection.range_count);
        self.nav_mark_staging.items.len = mark_bound;
        self.nav_mark_tallies.items.len = selection.range_count;
        @memset(self.nav_mark_tallies.items, .{});
        var job = NavMarkJob{
            .chunk_tiles = self.graph.chunk_tiles,
            .world = world,
            .events = events,
            .items_per_range = selection.items_per_range,
            .staging = self.nav_mark_staging.items,
            .tallies = self.nav_mark_tallies.items,
        };
        const batch = ts.parallelForWithOptions(events.len, &job, navMarkJob, options);
        self.last_mark_batch = batch;
        for (self.nav_mark_tallies.items, 0..) |tally, range_index| {
            const window_start = range_index * selection.items_per_range;
            for (self.nav_mark_staging.items[window_start .. window_start + tally.count]) |mark| self.appendEventMark(mark);
        }
        return if (batch.ran_inline) 0 else batch.batch_duration_ns;
    }

    fn navMarkDispatchOptions(self: *const PathfindingSystem, selection: BatchSelection) ParallelForOptions {
        return .{
            .items_per_range = self.nav_thread_items_per_range,
            .range_alignment_items = nav_mark_range_alignment_items,
            .adaptive = self.nav_thread_adaptive,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        };
    }

    // The inline `nav_mark` pass: appends the events' marks in event order.
    fn appendEventMarks(self: *PathfindingSystem, world: *const WorldSystem, events: []const SimulationEvent) void {
        for (events) |event| {
            if (interpretNavEvent(world, event)) |mark| self.appendEventMark(mark);
        }
    }

    // Appends one event's mark into reserved capacity, merging a tile box into the previous
    // mark when both lie in one chunk.
    fn appendEventMark(self: *PathfindingSystem, mark: NavMark) void {
        appendMergedMark(&self.nav_marks, mark, self.graph.chunk_tiles);
    }

    /// Whether the post-commit nav reaction may run and emit its event this step: a pending
    /// structural command may change nav, or nav has recorded marks, levels, links, or a
    /// content revision still to apply. Callers reserve its event slot first.
    pub fn navReactionMayEmit(self: *const PathfindingSystem, data: *const DataSystem, frame: *const SimulationFrame, world: *const WorldSystem) bool {
        return structuralCommandsMayInvalidateNavigation(data, frame) or self.hasPendingNavUpdates(world);
    }

    // Whether a committed world event changes nav cells. Static colliders reach nav through
    // the collider sync's change list, not events.
    pub fn eventInvalidatesNavigation(event: SimulationEvent) bool {
        switch (event.payload) {
            .world_tile_changed => |changed| return changed.old_blocks_movement != changed.new_blocks_movement,
            .world_obstacle_changed => return true,
            else => return false,
        }
    }

    // Whether any pending structural command may invalidate navigation once applied.
    fn structuralCommandsMayInvalidateNavigation(data: *const DataSystem, frame: *const SimulationFrame) bool {
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
            .set_world_level => |set| data.isStaticNavigationObstacle(set.entity),
            else => false,
        };
    }

    pub fn templateCreatesStaticNavigationObstacle(template: EntityTemplate) bool {
        const response = template.collision_response orelse return false;
        return response.mobility == .static and
            template.movement_body != null and
            template.collision_bounds != null;
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
        self.pending.clear();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.fallback_tier1_slot.clearRetainingCapacity();
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
                // reached the start-level run): steer toward the corridor's first cell.
                const first_grid = self.graph.grid(stitched[0].level) orelse return .{ .status = .unavailable };
                return .{ .status = .available, .next_waypoint = first_grid.cellCenter(stitched[0].cell), .path_len = result.stitched_len };
            }
            const path = self.completed.pathSlice(slot, result.path_len);
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
    fn beginUpdate(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, threads: ?StageThreads, stats: *PathfindingStats) !usize {
        self.step_counter +%= 1;
        try self.adjustCapacityForAgentCount(agent_count);
        var accept_timer = PhaseTimer.begin();
        stats.* = self.acceptRequests(requests.mergedItems(), threads);
        // Fold in any requests an elastic shrink dropped (it ran before acceptRequests
        // reset the step stats), then clear the accumulator.
        stats.dropped_requests += self.resize_dropped;
        self.resize_dropped = 0;
        stats.accept_ns = accept_timer.lap();
        var group_timer = PhaseTimer.begin();
        self.serviceGroupFields(stats, threads);
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
    fn beginSolve(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, threads: ?StageThreads, stats: *PathfindingStats) !?usize {
        const solve_count = try self.beginUpdate(requests, agent_count, config, threads, stats);
        if (solve_count == 0) {
            stats.pending_requests = self.pending.len;
            stats.deferred_requests = self.pending.len;
            return null;
        }
        return solve_count;
    }

    // Shared publish + compaction epilogue; finalizes the pending/deferred counts. On a
    // publish-reserve OOM nothing is published and pending is left intact for retry.
    pub fn finishUpdate(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) !void {
        var publish_timer = PhaseTimer.begin();
        try self.reservePublish();
        self.publishSolvedResults(stats);
        self.compactPendingAfterSolve(solve_count, stats);
        stats.publish_ns = publish_timer.lap();
        stats.pending_requests = self.pending.len;
        stats.deferred_requests = self.pending.len;
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
        const threads = StageThreads{ .thread_system = thread_system, .config = config };
        const solve_count = (try self.beginSolve(requests, agent_count, config, threads, &stats)) orelse return stats;
        var solve_timer = PhaseTimer.begin();
        var system_config = config;
        self.prepareSolvePhase(solve_count, self.effectiveFallbackLimit(system_config), &stats);

        if (self.fallback_indices.items.len != 0) {
            if (system_config.adaptive and system_config.fallback_adaptive_tuner == null and system_config.items_per_range == null) {
                system_config.fallback_adaptive_tuner = &self.fallback_tuner;
            }
            // The configured participant count sized the search scratch at the capacity
            // seam. In a correct configuration scratch is sized to participantSlotCount
            // (the app/bench reserve with it), so the clamp below is a no-op. A Debug-gated
            // assert (never lowered to `unreachable` in ReleaseFast, unlike a plain
            // std.debug.assert) catches a reserve/thread-system mismatch loudly during
            // development; a release build silently clamps the worker fan-out to the
            // reserved scratch (below) so worker indices stay in range and pathfinding
            // degrades to fewer workers rather than failing the frame. The warn is dropped:
            // it sat on the per-fixed-step path and would spam every step under a
            // misconfiguration whose inputs are step-invariant. Scratch is never grown past
            // the memory-budgeted count, and the solve loop stays allocation-free.
            if (builtin.mode == .debug) std.debug.assert(thread_system.participantSlotCount() <= self.scratch_slots.items.len);
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
        try self.finishUpdate(solve_count, &stats);
        return stats;
    }

    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) !PathfindingStats {
        var stats: PathfindingStats = undefined;
        const solve_count = (try self.beginSolve(requests, agent_count, config, null, &stats)) orelse return stats;
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
            if (builtin.mode == .debug) std.debug.assert(self.scratch_slots.items.len != 0);
            if (self.scratch_slots.items.len != 0) {
                self.resetSolvedPaths();
                const scratch = &self.scratch_slots.items[0];
                for (self.fallback_indices.items, 0..) |pending_index, ordinal| {
                    self.solve_results.items[ordinal] = solveOne(self, pending_index, scratch, ordinal);
                }
            }
        }
        stats.fallback_batch = inlineBatch(self.fallback_indices.items.len, pathfinding_range_alignment_items);
        stats.solve_ns = solve_timer.lap();
        try self.finishUpdate(solve_count, &stats);
        return stats;
    }

    fn resetSolvedPaths(self: *PathfindingSystem) void {
        self.solved_paths.clearRetainingCapacity();
        for (0..self.solve_results.items.len) |_| {
            self.solved_paths.appendAssumeCapacity(.{ .key = emptyKey(self.graph.version), .offset = 0, .len = 0 });
        }
    }

    // Threading for the request-side stages of one update: the thread system and the
    // caller's control config. Absent in `updateSerial`, where every stage runs inline.
    const StageThreads = struct {
        thread_system: *ThreadSystem,
        config: PathfindingConfig,

        // Pre-selects the batch shape so a job can assert its range against the
        // dispatched range count. The stage's own tuner drives an adaptive config with
        // no fixed range size.
        fn select(self: StageThreads, owned_tuner: *AdaptiveWorkTuner, item_count: usize, range_alignment_items: usize) BatchSelection {
            const tuner: ?*AdaptiveWorkTuner = if (self.config.adaptive and self.config.items_per_range == null) owned_tuner else null;
            return self.thread_system.selectBatchProfile(tuner, .{
                .item_count = item_count,
                .items_per_range = self.config.items_per_range,
                .max_worker_threads = self.config.max_worker_threads,
                .range_alignment_items = range_alignment_items,
                .adaptive = self.config.adaptive,
            });
        }

        fn dispatch(self: StageThreads, item_count: usize, context: *anyopaque, job: JobFn, selection: BatchSelection, range_alignment_items: usize) BatchStats {
            return self.thread_system.parallelForWithOptions(item_count, context, job, .{
                .items_per_range = self.config.items_per_range,
                .max_worker_threads = self.config.max_worker_threads,
                .range_alignment_items = range_alignment_items,
                .adaptive = self.config.adaptive,
                .adaptive_tuner = selection.active_tuner,
                .selected_profile = selection.profile,
            });
        }
    };

    // `path_intake`. On the main thread (no thread system, or the tuner keeps the pass
    // inline) one direct pass classifies and accepts each request. Dispatched to workers,
    // ranges classify against step-start state into their windows (a record per new or
    // expired key, repeats folded; a group-key entry per key), then the main thread merges
    // the windows in range order: group tallies, expired-result removal, in-step
    // duplicates, the pending cap, and pending pushes, O(records + group keys). Both equal
    // the serial request-order loop for any partition. Acceptance is the only stage that
    // mutates the pending-key set; cached hits never enter pending work.
    fn acceptRequests(self: *PathfindingSystem, requests: []const PathRequest, threads: ?StageThreads) PathfindingStats {
        var stats = PathfindingStats{};
        // Cross-step decaying accumulation: halve every carried tally before this
        // step's requests fold in, so a SUSTAINED shared goal accumulates toward the
        // threshold (~2x per-step intake at equilibrium) while a transient burst
        // decays back to zero. Runs every step (even with no requests) so a crowd
        // that stops requesting decays away. Zero-count tallies are compacted after
        // threshold-service in serviceGroupFields.
        for (self.group_requests.items) |*tally| tally.count /= 2;
        stats.pending_requests = self.pending.len;
        if (requests.len == 0 or !self.graph.valid()) return stats;
        // Intake gates on the LOGICAL per-step cap, never the staging's physical capacity:
        // ensureTotalCapacity rounds up and shrink hysteresis keeps slack, so a physical
        // gate would make the accepted set depend on allocation history.
        const item_count = @min(requests.len, self.capacity.max_frame_requests);
        stats.dropped_requests += requests.len - item_count;
        if (item_count == 0) return stats;
        const admitted = requests[0..item_count];
        const stage = threads orelse {
            self.acceptDirect(admitted, &stats);
            stats.intake_batch = inlineBatch(item_count, intake_range_alignment_items);
            stats.pending_requests = self.pending.len;
            return stats;
        };
        const selection = stage.select(&self.intake_tuner, item_count, intake_range_alignment_items);
        if (selection.worker_threads == 0) {
            // Inline on the main thread in range order: one direct pass, no records. Still
            // dispatched so the tuner records the batch.
            var direct = DirectIntakeJob{ .system = self, .requests = admitted, .stats = &stats };
            stats.intake_batch = stage.dispatch(item_count, &direct, directIntakeJob, selection, intake_range_alignment_items);
            stats.pending_requests = self.pending.len;
            return stats;
        }
        std.debug.assert(self.intake_records.capacity >= item_count);
        std.debug.assert(self.intake_group_counts.capacity >= item_count);
        std.debug.assert(self.intake_tallies.capacity >= selection.range_count);
        self.intake_records.items.len = item_count;
        self.intake_group_counts.items.len = item_count;
        self.intake_tallies.items.len = selection.range_count;
        @memset(self.intake_tallies.items, .{});
        var job = IntakeJob{
            .system = self,
            .requests = admitted,
            .items_per_range = selection.items_per_range,
            .records = self.intake_records.items,
            .group_counts = self.intake_group_counts.items,
            .tallies = self.intake_tallies.items,
        };
        stats.intake_batch = stage.dispatch(item_count, &job, intakeJob, selection, intake_range_alignment_items);
        self.mergeIntake(selection.items_per_range, &stats);
        stats.pending_requests = self.pending.len;
        return stats;
    }

    // Single-pass intake for a pass on the main thread: classifies and accepts each
    // request in order, with the same results as the threaded classify-and-merge.
    fn acceptDirect(self: *PathfindingSystem, requests: []const PathRequest, stats: *PathfindingStats) void {
        // A valid graph has level 0, and every level shares its extent.
        const extent_grid = self.graph.grid(0).?;
        const level_count = self.graph.levelCount();
        var block_start: usize = 0;
        while (block_start < requests.len) : (block_start += simd.lane_count) {
            const block = requests[block_start..@min(block_start + simd.lane_count, requests.len)];
            var block_cells: [simd.lane_count]IntakeCells = undefined;
            intakeCells(extent_grid, block, block_cells[0..block.len]);
            for (block, block_cells[0..block.len]) |request, cells| {
                if (request.goal_level >= level_count or request.start_level >= level_count) {
                    stats.dropped_requests += 1;
                    continue;
                }
                const key = PathQueryKey{
                    .nav_version = self.graph.version,
                    .agent_class = request.agent_class,
                    .goal_level = request.goal_level,
                    .goal = cells.goal,
                };
                const goal_grid = self.graph.grid(request.goal_level).?;
                if (request.kind == .group) {
                    self.recordGroupRequestCount(key, 1);
                    if (request.start_level == request.goal_level and self.groupFieldServes(key, goal_grid, cells.start)) {
                        stats.group_field_samples += 1;
                        stats.duplicate_requests += 1;
                        continue;
                    }
                }
                if (self.completed.lookup(key, self.step_counter, types.default_cache_ttl_steps)) |found| {
                    if (found.fresh) {
                        stats.duplicate_requests += 1;
                        stats.cache_hits += 1;
                        stats.available_results += 1;
                        continue;
                    }
                    // Removes the expired result.
                    _ = self.completed.findFresh(key, self.step_counter, types.default_cache_ttl_steps);
                }
                if (self.unavailable.contains(key)) {
                    stats.duplicate_requests += 1;
                    stats.cache_hits += 1;
                    stats.unavailable_results += 1;
                    continue;
                }
                if (self.pending_keys.contains(key)) {
                    stats.duplicate_requests += 1;
                    continue;
                }
                if (self.pending.len >= self.capacity.max_pending_requests) {
                    stats.dropped_requests += 1;
                    continue;
                }
                const goal = projectGoal(goal_grid, key.goal);
                self.pending.push(.{
                    .entity = request.entity,
                    .key = key,
                    .start_level = request.start_level,
                    .start = cells.start,
                    .goal_index = goal.index,
                });
                _ = self.pending_keys.insert(key);
                stats.accepted_requests += 1;
                if (goal.projected) stats.goal_projected += 1;
            }
        }
    }

    // A ready group field answers only members on the goal level whose own cell it
    // covers; an off-level member or a sample miss falls through to an individual
    // request, mirroring statusForKeyAndStart.
    fn groupFieldServes(self: *const PathfindingSystem, key: PathQueryKey, goal_grid: *const NavGrid, start: GridCell) bool {
        const field = self.findGroupField(key) orelse return false;
        if (field.state != .ready) return false;
        const start_index = goal_grid.indexForCell(start) orelse return false;
        return field.sample(goal_grid, start_index) != null;
    }

    // Classifies `requests[start..end]` into the `[start, end)` windows of `records` and
    // `group_counts`. Reads only state the intake merge never changes, except expiry and
    // pending keys, which the records carry for the merge to resolve in request order.
    fn classifyIntakeRange(self: *const PathfindingSystem, requests: []const PathRequest, start: usize, end: usize, records: []IntakeRecord, group_counts: []GroupKeyCount) IntakeTally {
        var tally = IntakeTally{};
        // A valid graph has level 0, and every level shares its extent.
        const extent_grid = self.graph.grid(0).?;
        const level_count = self.graph.levelCount();
        const record_window = records[start..end];
        const group_window = group_counts[start..end];
        var recent_groups: RecentKeys = .{};
        var recent_records: RecentKeys = .{};
        var block_start = start;
        while (block_start < end) : (block_start += simd.lane_count) {
            const block = requests[block_start..@min(block_start + simd.lane_count, end)];
            var block_cells: [simd.lane_count]IntakeCells = undefined;
            intakeCells(extent_grid, block, block_cells[0..block.len]);
            for (block, block_cells[0..block.len]) |request, cells| {
                // Reject (drop, never clamp) an out-of-range level: the query path
                // rejects the same condition as unavailable, so a clamped solve could
                // never be read back by its requester.
                if (request.goal_level >= level_count or request.start_level >= level_count) {
                    tally.dropped_requests += 1;
                    continue;
                }
                const key = PathQueryKey{
                    .nav_version = self.graph.version,
                    .agent_class = request.agent_class,
                    .goal_level = request.goal_level,
                    .goal = cells.goal,
                };
                const goal_grid = self.graph.grid(request.goal_level).?;
                if (request.kind == .group) {
                    if (recent_groups.find(key)) |entry| {
                        group_window[entry].count += 1;
                    } else {
                        group_window[tally.group_key_count] = .{ .key = key, .count = 1 };
                        recent_groups.remember(key, tally.group_key_count);
                        tally.group_key_count += 1;
                    }
                    if (request.start_level == request.goal_level and self.groupFieldServes(key, goal_grid, cells.start)) {
                        tally.group_field_samples += 1;
                        tally.duplicate_requests += 1;
                        continue;
                    }
                }
                const cached = self.completed.lookup(key, self.step_counter, types.default_cache_ttl_steps);
                if (cached) |found| {
                    if (found.fresh) {
                        tally.duplicate_requests += 1;
                        tally.cache_hits += 1;
                        tally.available_results += 1;
                        continue;
                    }
                }
                var record = IntakeRecord{
                    .entity = request.entity,
                    .key = key,
                    .start_level = request.start_level,
                    .start = cells.start,
                    .goal_index = no_parent,
                    .expired = cached != null,
                    .candidate = false,
                    .projected = false,
                    .repeats = 0,
                };
                if (self.unavailable.contains(key)) {
                    tally.duplicate_requests += 1;
                    tally.cache_hits += 1;
                    tally.unavailable_results += 1;
                } else if (self.pending_keys.contains(key)) {
                    tally.duplicate_requests += 1;
                } else {
                    const goal = projectGoal(goal_grid, key.goal);
                    record.candidate = true;
                    record.goal_index = goal.index;
                    record.projected = goal.projected;
                }
                if (!record.candidate and !record.expired) continue;
                // A repeat of a key in this range classifies as its first record did, so it
                // folds into that record; only a candidate's repeats count in the merge.
                if (recent_records.find(key)) |entry| {
                    if (record.candidate) record_window[entry].repeats += 1;
                    continue;
                }
                recent_records.remember(key, tally.record_count);
                record_window[tally.record_count] = record;
                tally.record_count += 1;
            }
        }
        return tally;
    }

    // Main-thread intake merge in range order (see acceptRequests).
    fn mergeIntake(self: *PathfindingSystem, items_per_range: usize, stats: *PathfindingStats) void {
        for (self.intake_tallies.items, 0..) |tally, range_index| {
            const window_start = range_index * items_per_range;
            for (self.intake_group_counts.items[window_start..][0..tally.group_key_count]) |entry| {
                self.recordGroupRequestCount(entry.key, entry.count);
            }
            for (self.intake_records.items[window_start..][0..tally.record_count]) |record| {
                self.mergeIntakeRecord(record, stats);
            }
            stats.dropped_requests += tally.dropped_requests;
            stats.duplicate_requests += tally.duplicate_requests;
            stats.cache_hits += tally.cache_hits;
            stats.available_results += tally.available_results;
            stats.unavailable_results += tally.unavailable_results;
            stats.group_field_samples += tally.group_field_samples;
        }
    }

    fn mergeIntakeRecord(self: *PathfindingSystem, record: IntakeRecord, stats: *PathfindingStats) void {
        if (record.expired) {
            // Removes the result that expired before this step; a repeat finds none.
            const fresh = self.completed.findFresh(record.key, self.step_counter, types.default_cache_ttl_steps);
            std.debug.assert(fresh == null);
        }
        if (!record.candidate) return;
        // Repeats follow their first occurrence: pending cannot shrink during intake, so a
        // repeat after an accept or a duplicate is a duplicate and after a drop is a drop.
        if (self.pending_keys.contains(record.key)) {
            stats.duplicate_requests += 1 + record.repeats;
            return;
        }
        if (self.pending.len >= self.capacity.max_pending_requests) {
            stats.dropped_requests += 1 + record.repeats;
            return;
        }
        stats.duplicate_requests += record.repeats;
        self.pending.push(.{
            .entity = record.entity,
            .key = record.key,
            .start_level = record.start_level,
            .start = record.start,
            .goal_index = record.goal_index,
        });
        _ = self.pending_keys.insert(record.key);
        stats.accepted_requests += 1;
        if (record.projected) stats.goal_projected += 1;
    }

    // Adds `count` requests for `key` to the step's group tallies, in first-occurrence
    // order across the merge.
    fn recordGroupRequestCount(self: *PathfindingSystem, key: PathQueryKey, count: usize) void {
        if (self.group_key_map.find(key)) |group_index| {
            self.group_requests.items[group_index].count += count;
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
            self.group_requests.appendAssumeCapacity(.{ .key = key, .count = count });
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
    // equilibrium), not a single-step burst. `group_field_expand` runs the budgeted
    // expansions one field per item: the advance pass over fields building at step
    // start, then the main-thread decisions in tally order (they see the post-advance
    // states), then the begin pass over fields begun this step.
    fn serviceGroupFields(self: *PathfindingSystem, stats: *PathfindingStats, threads: ?StageThreads) void {
        if (!self.graph.valid()) return;
        const threshold = self.groupFieldThreshold();
        std.debug.assert(self.group_field_slots.capacity >= self.group_fields.items.len);
        self.group_field_slots.clearRetainingCapacity();
        for (self.group_fields.items, 0..) |*field, slot| {
            field.fresh_this_step = false;
            if (field.state == .building and self.graph.grid(field.key.goal_level) != null) {
                field.step_budget_left = self.capacity.group_field_build_budget;
                self.group_field_slots.appendAssumeCapacity(slot);
            }
        }
        stats.group_field_batch = self.expandGroupFieldSlots(threads, &self.group_field_tuner);
        for (self.group_requests.items) |tally| {
            // Only build/maintain a shared flow field once sustained demand for the
            // same goal amortizes its O(cells) build. Smaller groups already took an
            // individual A* solve during acceptance, so a handful of agents never pay
            // the flow-field cost — pathfinding stays cheap at low agent counts and
            // the field engages only at crowd scale.
            if (tally.count < threshold) continue;
            self.ensureGroupField(tally.key, stats);
        }
        self.group_field_slots.clearRetainingCapacity();
        for (self.group_fields.items, 0..) |*field, slot| {
            if (field.fresh_this_step and field.state == .building) {
                field.step_budget_left = self.capacity.group_field_build_budget;
                self.group_field_slots.appendAssumeCapacity(slot);
            }
        }
        stats.group_field_begin_batch = self.expandGroupFieldSlots(threads, &self.group_field_begin_tuner);
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

    // Expands every field in `group_field_slots` by the rest of its step budget; each item
    // writes only its own field. A field whose pool ran out of room stalls before its pop;
    // after the join the main thread grows each stalled field's pool (O(1) per field per
    // round, geometric, counted) and expands the stalled fields again, so a step's progress
    // never depends on pool capacity. A growth that runs out of memory leaves its field
    // stalled for the next step. Returns the first round's batch (later rounds happen only
    // while pools warm up).
    fn expandGroupFieldSlots(self: *PathfindingSystem, threads: ?StageThreads, tuner: *AdaptiveWorkTuner) BatchStats {
        var first: ?BatchStats = null;
        while (self.group_field_slots.items.len != 0) {
            const slots = self.group_field_slots.items;
            const round_tuner = if (first == null) tuner else &self.group_field_stall_tuner;
            const batch = if (threads) |stage| dispatched: {
                const selection = stage.select(round_tuner, slots.len, 1);
                var job = GroupFieldJob{ .system = self, .slots = slots, .range_count = selection.range_count };
                break :dispatched stage.dispatch(slots.len, &job, groupFieldExpandJob, selection, 1);
            } else serial: {
                for (slots) |slot| self.expandGroupField(slot);
                break :serial inlineBatch(slots.len, 1);
            };
            if (first == null) first = batch;
            var stalled: usize = 0;
            for (slots) |slot| {
                const field = &self.group_fields.items[slot];
                if (!field.stalled) continue;
                if (!self.growStalledField(field)) continue;
                slots[stalled] = slot;
                stalled += 1;
            }
            self.group_field_slots.shrinkRetainingCapacity(stalled);
        }
        return first orelse .{};
    }

    fn expandGroupField(self: *PathfindingSystem, slot: usize) void {
        const field = &self.group_fields.items[slot];
        _ = field.expand(self.graph.grid(field.key.goal_level).?, &field.step_budget_left);
    }

    // Grows a stalled field's pool on the main thread; false when it ran out of memory.
    fn growStalledField(self: *PathfindingSystem, field: *GroupField) bool {
        field.growForStall(self.allocator, self.graph.grid(field.key.goal_level).?) catch {
            self.recordGroupFieldPoolFailure();
            return false;
        };
        self.recordGroupFieldPoolGrowth(field);
        return true;
    }

    fn recordGroupFieldPoolGrowth(self: *PathfindingSystem, field: *const GroupField) void {
        self.group_field_pool_grows += 1;
        if (self.group_field_pool_growth_logged) return;
        self.group_field_pool_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test) logging.game.info(
            "group field block pool grew to {d} blocks",
            .{field.blocks.len},
        );
    }

    fn recordGroupFieldPoolFailure(self: *PathfindingSystem) void {
        self.group_field_pool_failures += 1;
        if (self.group_field_pool_failure_logged) return;
        self.group_field_pool_failure_logged = true;
        if (comptime logging.enabled(.warn) and !builtin.is_test) logging.game.warn(
            "group field block pool growth ran out of memory; the field retries next step",
            .{},
        );
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

    // Begins a build (O(1) on the main thread); the begin pass of `group_field_expand`
    // runs its first budgeted expansion.
    // A field's first build reserves its pool here; an out-of-memory leaves the field as it
    // was, and a later step's decision retries.
    fn buildGroupSlot(self: *PathfindingSystem, field: *GroupField, key: PathQueryKey, goal_index: usize, stats: *PathfindingStats) void {
        const grid = self.graph.grid(key.goal_level) orelse return;
        const max_cells = self.capacity.group_field_max_cells;
        const pool_blocks = field.blocks.len;
        field.reservePool(self.allocator, grid, max_cells, initialPoolBlocks(grid, max_cells, self.capacity.group_field_build_budget)) catch {
            self.recordGroupFieldPoolFailure();
            return;
        };
        if (field.blocks.len != pool_blocks) self.recordGroupFieldPoolGrowth(field);
        field.fresh_this_step = field.beginBuild(grid, key, goal_index, self.step_counter, max_cells);
        if (field.fresh_this_step) stats.group_fields_built += 1;
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

    fn effectiveSolveLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_solved_requests_per_step orelse self.capacity.max_solved_requests_per_step;
        return @min(
            self.pending.len,
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

    // Admits pending indices of the solve window [0, solve_count) into fallback_indices,
    // in increasing order, and sizes solve_results to one slot per admission: the
    // fallback ordinal is the solve batch's item index and every solve output's index.
    // A tier-1 (escalated) request is additionally capped at max_escalated_solves_per_step
    // admissions this step, since tier-1 uses the larger derived abstract-node/stitched-cell
    // ceiling and is the expensive attempt; a tier-1-ready request past the cap is simply
    // skipped (stays deferred, so compactPendingAfterSolve leaves it in place to retry next
    // step) without consuming a fallback_limit slot, so tier-0 requests keep filling the rest.
    // Each admission also records its tier-1 pool entry: the escalated admission index, so
    // admitted escalated solves of one step never share an entry.
    fn prepareSolvePhase(self: *PathfindingSystem, solve_count: usize, fallback_limit: usize, stats: *PathfindingStats) void {
        std.debug.assert(self.capacity.max_escalated_solves_per_step <= self.tier1_scratch.items.len);
        std.debug.assert(self.fallback_tier1_slot.capacity >= solve_count);
        self.fallback_indices.clearRetainingCapacity();
        self.fallback_tier1_slot.clearRetainingCapacity();
        var escalated_admitted: usize = 0;
        for (0..solve_count) |pending_index| {
            const is_escalated = self.pending.at(pending_index).tier != 0;
            if (is_escalated and escalated_admitted >= self.capacity.max_escalated_solves_per_step) {
                stats.escalated_deferred += 1;
                continue;
            }
            if (self.fallback_indices.items.len < fallback_limit) {
                self.fallback_indices.appendAssumeCapacity(pending_index);
                self.fallback_tier1_slot.appendAssumeCapacity(if (is_escalated) @intCast(escalated_admitted) else no_tier1_slot);
                if (is_escalated) {
                    escalated_admitted += 1;
                    stats.escalated_solves += 1;
                }
            } else {
                stats.fallback_deferred_requests += 1;
            }
        }
        self.solve_results.clearRetainingCapacity();
        for (0..self.fallback_indices.items.len) |_| {
            self.solve_results.appendAssumeCapacity(.{ .deferred = emptyKey(self.graph.version) });
        }
    }

    // The publish reserve: frees one result-cache long block per result this step that
    // does not fit an inline stripe, so publishing allocates nothing. O(solve count).
    fn reservePublish(self: *PathfindingSystem) !void {
        var long_results: usize = 0;
        for (self.solve_results.items, 0..) |result, ordinal| {
            if (result != .available) continue;
            const solved = self.solved_paths.items[ordinal];
            if (types.storedPathWords(solved.len, solved.stitched_len) > self.completed.inline_words) long_results += 1;
        }
        const blocks_before = self.completed.long_block_count;
        try self.completed.reserveLongBlocks(self.allocator, long_results);
        if (self.completed.long_block_count == blocks_before) return;
        self.long_block_grows += 1;
        if (!self.long_block_growth_logged) {
            self.long_block_growth_logged = true;
            if (comptime logging.enabled(.info) and !builtin.is_test) logging.game.info(
                "path cache long-block pool grew to {d} blocks",
                .{self.completed.long_block_count},
            );
        }
    }

    // Publishes in fallback-ordinal order, which is pending order (ordinals increase with
    // the pending index). Each path is copied whole; allocates nothing after reservePublish.
    fn publishSolvedResults(self: *PathfindingSystem, stats: *PathfindingStats) void {
        for (self.solve_results.items, 0..) |result, ordinal| {
            switch (result) {
                .available => |key| {
                    const solved = self.solved_paths.items[ordinal];
                    const stripe = self.worker_path_pool.items[solved.offset..];
                    const path = stripe[0..solved.len];
                    const stitched = types.stitchedCellsConst(stripe, solved.stitched_len);
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

    // Compacts the solve window [0, solve_count) of pending in O(solve_count). Solved
    // entries (available/unavailable/start_invalid) are removed. Deferred entries (not
    // admitted this frame, including a tier-1-ready request skipped by the escalated-solve
    // cap) keep their front order. A budget-exhausted entry follows the two-tier ladder:
    // tier 0 (the cheap, fixed-budget attempt) promotes to tier 1 and rotates to the BACK
    // of pending exactly once, so the untouched tail reaches the solve window before the
    // promoted entry retries at the larger — but still fixed, never derived from
    // world/graph size — tier-1 budget; a budget-exhausted AT tier 1 drops the entry
    // WITHOUT negative-caching (it does not fit either fixed budget, which is not the same
    // as a definitive "no path exists") — worst case exactly two solve attempts per
    // request, never an unbounded retry storm and never a false `.unavailable`.
    //
    // The window is walked back to front, each outcome recovered by merge-walking the
    // increasing fallback_indices; kept entries are written toward the window end (a
    // write never lands below its source), the ring head advances past everything else,
    // and the rotated entries are pushed at the tail. Resulting order: deferred, tail,
    // rotated. pending_keys loses the keys of solved and dropped entries only.
    fn compactPendingAfterSolve(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        if (solve_count == 0) return;
        self.rotate_back_scratch.clearRetainingCapacity();
        const admitted = self.fallback_indices.items;
        var ordinal = admitted.len;
        var write_index = solve_count;
        var pending_index = solve_count;
        while (pending_index > 0) {
            pending_index -= 1;
            const result: PathSolveResult = if (ordinal > 0 and admitted[ordinal - 1] == pending_index) admitted_result: {
                ordinal -= 1;
                break :admitted_result self.solve_results.items[ordinal];
            } else .{ .deferred = emptyKey(self.graph.version) };
            switch (result) {
                .deferred => {
                    write_index -= 1;
                    self.pending.ptr(write_index).* = self.pending.at(pending_index);
                },
                .budget_exhausted => |key| {
                    var request = self.pending.at(pending_index);
                    if (request.tier == 0) {
                        // First (tier-0) attempt exhausted its small fixed attempt cap: promote
                        // to tier 1 and rotate to the back so the untouched tail makes progress
                        // before this entry retries at the larger (still fixed) tier-1 budget.
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
                    self.pending_keys.remove(self.pending.at(pending_index).key);
                },
            }
        }
        std.debug.assert(ordinal == 0);
        self.pending.dropFront(write_index);
        // Aged spillers trail the untouched tail so the tail makes progress before they
        // retry; they were gathered back to front.
        var rotated = self.rotate_back_scratch.items.len;
        while (rotated > 0) {
            rotated -= 1;
            self.pending.push(self.rotate_back_scratch.items[rotated]);
        }
    }
};

fn tileMark(level: u16, min_x: u32, min_y: u32, max_x: u32, max_y: u32) NavMark {
    return .{ .level = level, .kind = .tile_box, .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

// An exclusive world-tile rect clamped to the world as an inclusive tile box; null when
// empty or fully outside.
fn tileRectMark(world: *const WorldSystem, level: u16, min_x: u16, min_y: u16, max_x_exclusive: u16, max_y_exclusive: u16) ?NavMark {
    const clamped_max_x = @min(max_x_exclusive, world.width);
    const clamped_max_y = @min(max_y_exclusive, world.height);
    if (min_x >= clamped_max_x or min_y >= clamped_max_y) return null;
    return tileMark(level, min_x, min_y, clamped_max_x - 1, clamped_max_y - 1);
}

// Whether two tile boxes lie in one `chunk_tiles` chunk of one level, so their bounding
// box covers exactly that chunk.
fn tileBoxesShareChunk(a: NavMark, b: NavMark, chunk_tiles: u16) bool {
    if (a.kind != .tile_box or b.kind != .tile_box or a.level != b.level) return false;
    const ct: u32 = @max(chunk_tiles, 1);
    const chunk_x = a.min_x / ct;
    const chunk_y = a.min_y / ct;
    return a.max_x / ct == chunk_x and a.max_y / ct == chunk_y and
        b.min_x / ct == chunk_x and b.max_x / ct == chunk_x and
        b.min_y / ct == chunk_y and b.max_y / ct == chunk_y;
}

// Writes `mark` after the first `count` marks of `marks`, merged into the last one when
// both are tile boxes in one chunk; returns the new count. Merging only with the last mark
// makes the result independent of how a mark sequence is split and rejoined.
fn foldMark(marks: []NavMark, count: usize, mark: NavMark, chunk_tiles: u16) usize {
    if (count != 0) {
        const last = &marks[count - 1];
        if (tileBoxesShareChunk(last.*, mark, chunk_tiles)) {
            last.min_x = @min(last.min_x, mark.min_x);
            last.min_y = @min(last.min_y, mark.min_y);
            last.max_x = @max(last.max_x, mark.max_x);
            last.max_y = @max(last.max_y, mark.max_y);
            return count;
        }
    }
    std.debug.assert(count < marks.len);
    marks[count] = mark;
    return count + 1;
}

// `foldMark` onto a list with reserved capacity.
fn appendMergedMark(list: *std.ArrayList(NavMark), mark: NavMark, chunk_tiles: u16) void {
    std.debug.assert(list.items.len < list.capacity);
    const count = foldMark(list.items.ptr[0..list.capacity], list.items.len, mark, chunk_tiles);
    list.items.len = count;
}

// One committed event's nav mark: a blocking tile flip becomes its tile, an obstacle rect
// its clamped tile box. Reads only the world, so ranges interpret in parallel.
fn interpretNavEvent(world: *const WorldSystem, event: SimulationEvent) ?NavMark {
    if (event.stage != .structural_commit) return null;
    if (!PathfindingSystem.eventInvalidatesNavigation(event)) return null;
    return switch (event.payload) {
        .world_tile_changed => |changed| tileMark(changed.level, changed.x, changed.y, changed.x, changed.y),
        .world_obstacle_changed => |changed| tileRectMark(world, changed.level, changed.min_x, changed.min_y, changed.max_x_exclusive, changed.max_y_exclusive),
        else => null,
    };
}

// One range of the `nav_mark` stage: its events' marks, folded, in its staging window.
const NavMarkJob = struct {
    chunk_tiles: u16,
    world: *const WorldSystem,
    events: []const SimulationEvent,
    items_per_range: usize,
    staging: []NavMark,
    tallies: []NavMarkTally,
};

fn navMarkJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *NavMarkJob = @ptrCast(@alignCast(context));
    // Dual worker asserts: range.index vs the dispatched tallies, and the window the merge
    // reads, inside the staging buffer.
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.events.len);
    std.debug.assert(range.end <= job.staging.len);
    const window = job.staging[range.start..range.end];
    var count: usize = 0;
    for (job.events[range.start..range.end]) |event| {
        if (interpretNavEvent(job.world, event)) |mark| count = foldMark(window, count, mark, job.chunk_tiles);
    }
    job.tallies[range.index] = .{ .count = count };
}

// `nav_mark` dispatched inline: each range, in order on the main thread, appends its marks.
const DirectNavMarkJob = struct {
    system: *PathfindingSystem,
    world: *const WorldSystem,
    events: []const SimulationEvent,
};

fn directNavMarkJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *DirectNavMarkJob = @ptrCast(@alignCast(context));
    std.debug.assert(worker_id.index == WorkerId.main.index);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.events.len);
    job.system.appendEventMarks(job.world, job.events[range.start..range.end]);
}

// One range of the `path_intake` stage.
const IntakeJob = struct {
    system: *const PathfindingSystem,
    requests: []const PathRequest,
    items_per_range: usize,
    records: []IntakeRecord,
    group_counts: []GroupKeyCount,
    tallies: []IntakeTally,
};

fn intakeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *IntakeJob = @ptrCast(@alignCast(context));
    // Dual worker asserts: range.index vs the dispatched tallies, and the range is the
    // window the merge reads, inside both staging buffers.
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.requests.len);
    std.debug.assert(range.end <= job.records.len and range.end <= job.group_counts.len);
    job.tallies[range.index] = job.system.classifyIntakeRange(job.requests, range.start, range.end, job.records, job.group_counts);
}

// `path_intake` dispatched inline: each range, in order on the main thread, runs the
// direct single pass.
const DirectIntakeJob = struct {
    system: *PathfindingSystem,
    requests: []const PathRequest,
    stats: *PathfindingStats,
};

fn directIntakeJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *DirectIntakeJob = @ptrCast(@alignCast(context));
    std.debug.assert(worker_id.index == WorkerId.main.index);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.requests.len);
    job.system.acceptDirect(job.requests[range.start..range.end], job.stats);
}

const ProjectedGoal = struct {
    // `no_parent` when no open cell is near the goal: a definitive unavailable.
    index: usize,
    projected: bool,
};

// Nearest-open goal projection on the goal level, resolved at intake so the solve
// reuses it.
fn projectGoal(goal_grid: *const NavGrid, goal: GridCell) ProjectedGoal {
    const index = goal_grid.indexForCell(goal) orelse return .{ .index = no_parent, .projected = false };
    if (!goal_grid.isBlockedIndex(index)) return .{ .index = index, .projected = false };
    const projected = goal_grid.projectToNearestOpen(goal, default_goal_projection_radius) orelse return .{ .index = no_parent, .projected = false };
    return .{ .index = projected, .projected = true };
}

// One range of a `group_field_expand` pass; slot indices are distinct by construction.
const GroupFieldJob = struct {
    system: *PathfindingSystem,
    slots: []const usize,
    range_count: usize,
};

fn groupFieldExpandJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *GroupFieldJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.slots.len);
    for (job.slots[range.start..range.end]) |slot| job.system.expandGroupField(slot);
}

// The window entry of each recently seen key in one intake range, so a repeat folds into
// its entry. A key evicted from this fixed table opens a new entry on its next
// occurrence; the merge handles both entries, so results stay exact.
const RecentKeys = struct {
    const slot_count = 8;

    keys: [slot_count]PathQueryKey = undefined,
    entries: [slot_count]usize = undefined,
    len: usize = 0,
    next_replace: usize = 0,

    fn find(self: *const RecentKeys, key: PathQueryKey) ?usize {
        for (self.keys[0..self.len], self.entries[0..self.len]) |recent_key, entry| {
            if (keysEqual(recent_key, key)) return entry;
        }
        return null;
    }

    fn remember(self: *RecentKeys, key: PathQueryKey, entry: usize) void {
        if (self.len < slot_count) {
            self.keys[self.len] = key;
            self.entries[self.len] = entry;
            self.len += 1;
        } else {
            self.keys[self.next_replace] = key;
            self.entries[self.next_replace] = entry;
            self.next_replace = (self.next_replace + 1) % slot_count;
        }
    }
};

const IntakeCells = struct {
    start: GridCell,
    goal: GridCell,
};

// Start and goal cells of each request, four requests per vector (positions packed from
// the AoS requests) with a scalar tail; bit-identical to `worldToCellClamped`. Every
// level shares one extent, so one grid converts for all of them.
fn intakeCells(grid: *const NavGrid, requests: []const PathRequest, out: []IntakeCells) void {
    std.debug.assert(out.len == requests.len);
    std.debug.assert(grid.width != 0 and grid.height != 0);
    const cell_size = simd.splatFloat4(grid.cell_size);
    const min_cell = simd.splatInt4(0);
    // Grid dimensions fit i32, as in worldToCellClamped.
    const max_x = simd.splatInt4(@intCast(grid.width - 1));
    const max_y = simd.splatInt4(@intCast(grid.height - 1));
    const vector_end = simd.vectorizedEnd(requests.len);
    var index: usize = 0;
    while (index < vector_end) : (index += simd.lane_count) {
        var start_x: [simd.lane_count]f32 = undefined;
        var start_y: [simd.lane_count]f32 = undefined;
        var goal_x: [simd.lane_count]f32 = undefined;
        var goal_y: [simd.lane_count]f32 = undefined;
        inline for (0..simd.lane_count) |lane| {
            const request = requests[index + lane];
            start_x[lane] = request.start.x;
            start_y[lane] = request.start.y;
            goal_x[lane] = request.goal.x;
            goal_y[lane] = request.goal.y;
        }
        const cell_start_x = simd.toIntArray(simd.clampInt4(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&start_x), cell_size)), min_cell, max_x));
        const cell_start_y = simd.toIntArray(simd.clampInt4(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&start_y), cell_size)), min_cell, max_y));
        const cell_goal_x = simd.toIntArray(simd.clampInt4(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&goal_x), cell_size)), min_cell, max_x));
        const cell_goal_y = simd.toIntArray(simd.clampInt4(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&goal_y), cell_size)), min_cell, max_y));
        inline for (0..simd.lane_count) |lane| {
            out[index + lane] = .{
                .start = .{ .x = cell_start_x[lane], .y = cell_start_y[lane] },
                .goal = .{ .x = cell_goal_x[lane], .y = cell_goal_y[lane] },
            };
        }
    }
    while (index < requests.len) : (index += 1) {
        out[index] = .{
            .start = grid.worldToCellClamped(requests[index].start),
            .goal = grid.worldToCellClamped(requests[index].goal),
        };
    }
}

// Batch stats of a stage that ran inline on the calling thread.
fn inlineBatch(item_count: usize, range_alignment_items: usize) BatchStats {
    const ranges: usize = if (item_count == 0) 0 else 1;
    return .{
        .item_count = item_count,
        .range_count = ranges,
        .items_per_range = item_count,
        .range_alignment_items = range_alignment_items,
        .main_thread_ranges = ranges,
        .ran_inline = true,
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

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
const no_colliders = &test_support.no_colliders;

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
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
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
    // intake/serviceGroupFields/ensureGroupField/sample path must not allocate —
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
    // this cap. recordGroupRequestCount must gate the new-group append on the LOGICAL cap, not
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
    system.recordGroupRequestCount(repeated, 1);
    system.recordGroupRequestCount(repeated, 2);

    // Drive more distinct goals than the logical cap in a single step.
    var made: usize = 0;
    while (made < logical_cap + 5) : (made += 1) {
        system.recordGroupRequestCount(.{ .nav_version = 1, .agent_class = .default, .goal = .{ .x = @intCast(made + 1), .y = 0 } }, 1);
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
    // Two-word inline stripes: every multi-cell path publishes into a long block.
    cap.max_stored_path_cells = 2;
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
    try std.testing.expect(stats.available_results > 0);
    // Every published result took a long block from the pool the warm step grew.
    try std.testing.expectEqual(stats.available_results, system.completed.long_block_count - system.completed.free_long_blocks.items.len);
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
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // No level link added: the two floors are disconnected.

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    var blocked_world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &blocked_world, null);
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
    var open_world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &open_world, null);
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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // Obstacle only on level 0 cell (5,5).
    _ = try world.addSparseTile(0, 5, 5, tree, 0, .obstacle);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    var world = try test_support.abstractTestWorld(&meta, 512, 512);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    var one_world = try test_support.abstractTestWorld(&meta, 512, 512);
    defer one_world.deinit();
    var one_system = PathfindingSystem.init(std.testing.allocator);
    defer one_system.deinit();
    try one_system.reserve(abstractCapacity());
    try one_system.rebuildStaticNavGridWithWorld(&one_data, &one_world, null);
    const one_level_start_portals = one_system.graph.levelLivePortalCount(0);

    var four_data = DataSystem.init(std.testing.allocator);
    defer four_data.deinit();
    var four_world = try test_support.abstractTestWorld(&meta, 512, 512);
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
    try four_system.rebuildStaticNavGridWithWorld(&four_data, &four_world, null);
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
        var world = try test_support.abstractTestWorld(&meta, extent, extent);
        defer world.deinit();
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    // via an individual cross-level corridor (no permanent stall).
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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    var world = try test_support.abstractTestWorld(&meta, 512, 512);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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

    var world = try test_support.abstractTestWorld(&meta, 512, 512);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(0).tier);
}

// tier0_stitched_cell_cap and max_stitched_path_cells (the fixed tier-1 ceiling) are
// independently settable fields; a participant's stitched path is reserved to the smaller
// of the two. If a caller tunes tier0_stitched_cell_cap ABOVE the tier-1 ceiling, the
// tier-0 attempt cap clamps down to the reserved limit rather than handing stitchCorridor a
// logical cap the reserved buffer cannot back (an unguarded appendAssumeCapacity past the
// buffer's real capacity, which ReleaseFast does not catch). This pins that a
// deliberately-inverted config (tier0 far above tier1) still resolves cleanly.
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const stats = try solveStep(&system, requester, .{ .x = 16, .y = 176 }, .{ .x = 336, .y = 176 });
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.budget_exhausted);
}

// tier0_abstract_node_cap and max_abstract_nodes (the fixed tier-1 ceiling) are
// independently settable fields; a participant's abstract table is reserved for the
// smaller of the two. If a caller tunes tier0_abstract_node_cap ABOVE the tier-1 ceiling,
// the tier-0 attempt budget clamps down to the table's reserved limit rather than claiming
// past load 1/2. This pins that a deliberately-inverted config (tier0 far above tier1)
// still resolves cleanly.
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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

    var world = try test_support.abstractTestWorld(&meta, 512, 512);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(0).tier);

    // Force the SECOND (tier-1) attempt to also exhaust: max_abstract_nodes is the fixed
    // tier-1 ceiling, read fresh from live capacity on every tier-1 attempt, so shrinking
    // it here — after reserve sized the (larger) tier-1 pool — is a purely LOGICAL cap
    // tightening for the test, below the pool's reserved limit.
    system.capacity.max_abstract_nodes = 1;

    // Attempt 2 (tier 1): exhausts again -> dropped, NOT negative-cached.
    const second = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), second.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), second.pending_requests);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
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
    try std.testing.expectEqual(@as(usize, 4), system.pending.len);

    // Promote every pending entry to tier 1 (as if each had already spilled once).
    for (0..system.pending.len) |index| system.pending.ptr(index).tier = 1;

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const stats = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 2), stats.escalated_solves);
    try std.testing.expectEqual(@as(usize, 2), stats.escalated_deferred);
    // The two admitted tier-1 requests solved trivially (short, same-level, open goals);
    // the other two waited out this step and are still pending at tier 1.
    try std.testing.expectEqual(@as(usize, 2), system.pending.len);
    for (0..system.pending.len) |index| {
        try std.testing.expectEqual(@as(u8, 1), system.pending.at(index).tier);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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

    // A start chunk's record holds only its own portals; those sharing the start cell's
    // label (the seeds) all lie in that chunk with that component, and each seed set is a
    // strict subset of the level's portals.
    const left_chunk = grid.chunkOfCell(left_cell);
    const right_chunk = grid.chunkOfCell(right_cell);
    for ([_]struct { chunk: u32, cell: usize, component: u32 }{
        .{ .chunk = left_chunk, .cell = left_cell, .component = left_component },
        .{ .chunk = right_chunk, .cell = right_cell, .component = right_component },
    }) |start| {
        const portals = system.graph.chunkPortals(0, start.chunk);
        var seeds: usize = 0;
        for (portals.border) |portal| {
            if (portal.label != grid.labelAt(start.cell)) continue;
            const cell = system.graph.cellOfLocal(start.chunk, portal.local);
            try std.testing.expectEqual(start.component, grid.componentOf(cell));
            try std.testing.expectEqual(start.chunk, grid.chunkOfCell(cell));
            seeds += 1;
        }
        try std.testing.expect(seeds > 0);
        try std.testing.expect(seeds < system.graph.levelLivePortalCount(0));
    }

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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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
    var world = try test_support.abstractTestWorld(meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    // A pure incremental dig keeps nav_version stable; invalidation is scoped.
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);

    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_layer = try world.addDenseLayer(1, 0, .floor, grass);
    // A distinctive obstacle on level 1 cell (7,7) so we can confirm level 1 is
    // unchanged by an edit on level 0.
    _ = try world.setDenseTile(level1_layer, 7, 7, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Snapshot level 1's blocked count and component label of its obstacle cell.
    const level1_blocked_before = system.graph.grid(1).?.blocked_count;
    const level1_cell77 = system.graph.grid(1).?.indexForCell(.{ .x = 7, .y = 7 }).?;
    try std.testing.expect(system.graph.grid(1).?.isBlockedIndex(level1_cell77));

    // Edit a tile on LEVEL 0 only.
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    const changed = (try world.setDenseTile(obstacle_layer, 2, 2, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const version_before = system.graph.version;

    // An empty edit batch is a no-op: no version bump, no counters.
    const stats = try system.applyNavUpdates(no_colliders, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), stats.incremental_rebuilds);
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
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

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
    try std.testing.expect(system.hasPendingNavUpdates(&world));

    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The far block — marked last, the first a fixed cap would drop — reached the graph.
    const nav = system.graph.grid(0).?;
    fx = 13;
    while (fx < 16) : (fx += 1) try std.testing.expect(nav.isBlockedCell(.{ .x = @intCast(fx), .y = 13 }));
    // applyBuffered clears the buffer, so the next step starts empty.
    try std.testing.expect(!system.hasPendingNavUpdates(&world));

    // clearNavDirty drops a marking pass without applying it.
    try system.markNavDirty(0, 0, 0);
    system.clearNavDirty();
    try std.testing.expect(!system.hasPendingNavUpdates(&world));
}

test "nav over a world takes the world's chunk edge and tile size; a world-less build takes its config" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // World chunk 8 and a deliberately different config: nav chunk 16, cell size 8.
    var world = try @import("../../world_test_support.zig").demoWorldWithChunkSize(std.testing.allocator, &meta, 512, 256, 8);
    defer world.deinit();
    var capacity = baselineCapacity();
    capacity.nav_chunk_tiles = 16;

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try std.testing.expectEqual(world.chunk_size_tiles, system.graph.chunk_tiles);
    try std.testing.expectEqual(world.tile_size, system.graph.cell_size);
    try std.testing.expectEqual(@as(usize, world.width), system.graph.width);
    try std.testing.expectEqual(@as(usize, world.height), system.graph.height);
    const level_grid = system.graph.grid(0).?;
    try std.testing.expectEqual(world.chunk_size_tiles, level_grid.chunk_tiles);
    try std.testing.expectEqual(@as(usize, world.chunksX()), level_grid.chunksX());
    try std.testing.expectEqual(@as(usize, world.chunksY()), level_grid.chunksY());
    // Every tile's nav chunk is its world chunk.
    for (0..world.height) |y| {
        for (0..world.width) |x| {
            const tile_chunk = world.chunkCoordForCell(@intCast(x), @intCast(y));
            const expected: u32 = @intCast(tile_chunk.y * @as(i32, world.chunksX()) + tile_chunk.x);
            try std.testing.expectEqual(expected, level_grid.chunkOfCell(y * level_grid.width + x));
        }
    }

    try system.rebuildStaticNavGrid(&data, 512, 256, 8);
    try std.testing.expectEqual(capacity.nav_chunk_tiles, system.graph.chunk_tiles);
    try std.testing.expectEqual(@as(f32, 8), system.graph.cell_size);
}

test "nav build fails loudly when its chunk edge or index widths do not fit" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var bad_edge = baselineCapacity();
    bad_edge.nav_chunk_tiles = 3;
    var bad_edge_system = PathfindingSystem.init(std.testing.allocator);
    defer bad_edge_system.deinit();
    try bad_edge_system.reserve(bad_edge);
    try std.testing.expectError(error.InvalidChunkSize, bad_edge_system.rebuildStaticNavGrid(&data, 256, 256, 32));

    // Chunk edge 1 gives 2 labels per chunk: 65535 x 32769 cells crosses the label sentinel.
    var unit_edge = baselineCapacity();
    unit_edge.nav_chunk_tiles = 1;
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(unit_edge);
    try std.testing.expectError(error.ChunkLabelOverflow, system.rebuildStaticNavGrid(&data, 65535, 32769, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 1.0e6, 1.0e6, 1));
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    // A real committed tile edit that blocks movement.
    const changed = (try world.setDenseTile(obstacle, 2, 2, tree)) orelse return error.TestExpectedEqual;
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    try test_support.recordTerrainEvents(&system, frame.events.mergedItems(), &world);
    // Cap the events stream at its current size so this call's own ensureCanAppend(1) (for the
    // nav_region_invalidated event it would emit) fails deterministically, WITHOUT ever reaching
    // applyBufferedNavUpdates.
    frame.events.setCapacityLimit(frame.events.mergedItems().len);

    try std.testing.expectError(error.EventCapacityExceeded, system.reactToPostCommitNavEvents(&frame, no_colliders, &world, null));
    // The mark from this failed call must survive: no entry-clear on the next call may drop a
    // pending edit the world already committed but the nav graph has not yet learned about.
    try std.testing.expect(system.hasPendingNavUpdates(&world));
    try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));

    // Next step: no new committed events, room to append again. The leftover mark from the
    // failed step must still reach the graph.
    frame.events.setCapacityLimit(null);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expect(!system.hasPendingNavUpdates(&world));
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));
}

test "reactToPostCommitNavEvents maps world_obstacle_changed to one mark (not O(tiles) marks)" {
    // A multi-tile world_obstacle_changed must record one tile-box mark, not one mark per
    // tile. Multi-chunk fixture
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
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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
    try test_support.recordTerrainEvents(&system, frame.events.mergedItems(), &world);

    // Record only (don't apply): inspect the recorded marks by
    // forcing ensureCanAppend to fail before applyBufferedNavUpdates, same pattern
    // as the preserve-buffered-marks test above.
    frame.events.setCapacityLimit(frame.events.mergedItems().len);
    try std.testing.expectError(error.EventCapacityExceeded, system.reactToPostCommitNavEvents(&frame, no_colliders, &world, null));

    // One mark covering the rect: O(1) per event, not O(tiles).
    try std.testing.expectEqual(@as(usize, 1), system.nav_marks.items.len);
    const mark = system.nav_marks.items[0];
    try std.testing.expectEqual(@as(u16, 0), mark.level);
    try std.testing.expectEqual(expected_span, grid.cellSpanForTileBox(&world, mark.min_x, mark.min_y, mark.max_x, mark.max_y).?);

    // Apply the leftover mark: dirty tiles block; control cell in the untouched chunk stays open.
    frame.events.setCapacityLimit(null);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &world, null);
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

test "a recorded obstacle-rect event past the world edge marks its in-world part" {
    // A rect whose max corner is past the world edge still dirties the in-bounds
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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

    // min in-bounds, max far past the edge.
    try test_support.recordTerrainEvents(&system, &.{obstacleRectEvent(0, in_min_x, in_min_y, 1000, 1000)}, &world);
    try std.testing.expectEqual(@as(usize, 1), system.nav_marks.items.len);

    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
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
    try test_support.recordTerrainEvents(&system, &.{obstacleRectEvent(0, world.width, world.height, 1000, 1000)}, &world);
    try std.testing.expectEqual(@as(usize, 0), system.nav_marks.items.len);
}

fn obstacleRectEvent(level: u16, min_x: u16, min_y: u16, max_x_exclusive: u16, max_y_exclusive: u16) SimulationEvent {
    return .{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = level,
        .min_x = min_x,
        .min_y = min_y,
        .max_x_exclusive = max_x_exclusive,
        .max_y_exclusive = max_y_exclusive,
    } } };
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const high_water = system.graph.totalPortals();
    try std.testing.expect(high_water > 0);

    // Warmup: the same block and reopen, so every batch buffer and record pool reaches
    // its steady capacity.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        const warm = (try world.setDenseTile(built.wall_layer, 5, 3, tile)) orelse return error.TestExpectedEqual;
        _ = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = warm.level, .x = warm.x, .y = warm.y }});
    }

    // The failing allocator must cover BOTH the system AND the nav graph (which holds
    // its own captured allocator copy): every batch buffer and record pool flows through
    // graph.allocator, so swapping only system.allocator would let a graph allocation slip
    // through undetected.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    // Block an existing open gap: removes portals, stays within high-water.
    const blocked = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const block_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = blocked.level, .x = blocked.x, .y = blocked.y }});
    try std.testing.expectEqual(@as(usize, 1), block_stats.incremental_rebuilds);

    // Reopen the same gap: re-adds portals back to <= the init high-water count, so it
    // reuses retained capacity and allocates nothing.
    const opened = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    const open_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = opened.level, .x = opened.x, .y = opened.y }});
    try std.testing.expectEqual(@as(usize, 1), open_stats.incremental_rebuilds);
    try std.testing.expect(system.graph.totalPortals() <= high_water);

    system.graph.allocator = original;
    system.allocator = original;
}

test "pathfinding threaded incremental nav update is allocation-free at steady state" {
    // The serial allocation-free tests above only cover the inline stages. Only
    // applyBufferedNavUpdates/reactToPostCommitNavEvents with a real ThreadSystem drive the
    // plan, remask, and patch jobs, the remask indexing a per-participant scratch slot. Five
    // edits in five distinct chunks, adaptive=false/items_per_range=1 to force every stage
    // off the inline path, under a failing allocator on both system.allocator and
    // system.graph.allocator.
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline.
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk
    // set and the patch set exceed one chunk and actually fan out across workers.
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    // Warmup: block and reopen the cells through the threaded path.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        for (cells) |cell| {
            _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tile)) orelse return error.TestExpectedEqual;
            try system.markNavDirty(0, cell.x, cell.y);
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
    }

    // The failing allocator must cover BOTH the system AND the nav graph (which holds its own
    // captured allocator copy): every per-participant remask scratch slot, plus every batch
    // buffer and record pool, flows through graph.allocator.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

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

test "a fully walled level opened past its prior records grows at the reserve and the next apply allocates nothing" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // Start fully walled so the init build holds no record. Opening a block grows the
    // record pools at the batch reserve with the real allocator.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), system.graph.totalPortals());

    // Open a 6x6 block spanning chunk borders, creating records past the (zero) init pool.
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
    const stats = try system.applyNavUpdates(no_colliders, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The opened block holds portals.
    try std.testing.expect(system.graph.totalPortals() > 0);

    // A subsequent edit within the NEW high-water mark is allocation-free again.
    const closed = (try world.setDenseTile(wall_layer, 4, 4, tree)) orelse return error.TestExpectedEqual;
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const close_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = closed.level, .x = closed.x, .y = closed.y }});
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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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

    // Open the endpoint cell (2,2) on level 1 via the world tile API + incremental update:
    // the endpoint's record gains the link, so the same cross-level goal is now reachable.
    const changed = (try world.setDenseTile(level1_obstacle, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
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
    try std.testing.expectEqual(default_max_solves_per_frame * types.resultBlockWords(system.capacity.max_explored_nodes, system.capacity.max_stitched_path_cells), system.worker_path_pool.items.len);
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
    const steady_pending = system.pending.slotCount();
    const steady_cache = system.completed.slots.items.len;
    const steady_pool = system.worker_path_pool.items.len;
    // A constant agent count holds capacity (and every pool's backing) fixed across
    // many steps, so the per-step solve loop never reallocates after warmup.
    for (0..30) |_| {
        _ = try driveAgentCount(&system, &requesters, 16);
        try std.testing.expectEqual(steady_cap, system.effective_agent_capacity);
        try std.testing.expectEqual(steady_pending, system.pending.slotCount());
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
    try std.testing.expectEqual(@as(usize, pending_count), system.pending.len);
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
    const survivor_count = system.pending.len;
    try std.testing.expectEqual(min_capacity_floor, survivor_count);
    try std.testing.expectEqual(pending_count - survivor_count, last_stats.dropped_requests);

    // The surviving entries (snapshot order, so the first survivor_count original requests)
    // keep their key and tier intact; pending_keys is rebuilt to match exactly them.
    for (0..survivor_count) |i| {
        try std.testing.expectEqual(@as(u8, 0), system.pending.at(i).tier);
        try std.testing.expect(system.pending_keys.contains(system.pending.at(i).key));
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goals[i], .default, null).status);
    }
    // The dropped entries' goals now read missing (retryable), never a stale "still pending".
    for (survivor_count..pending_count) |i| {
        try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goals[i], .default, null).status);
    }
}

/// Submits `count` same-goal requests (one shared goal key) from `requesters`, starts laid
/// out on a 15-wide grid of distinct cells, with the fallback budget at 0 so the accepted
/// request stays pending (observable) instead of solving this step.
fn submitSharedGoalBurst(system: *PathfindingSystem, requesters: []const EntityId, count: usize, agent_count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    for (requesters[0..count], 0..) |entity, i| {
        const start = math.Vec2{
            .x = 8.0 + @as(f32, @floatFromInt(i % 15)) * 32.0,
            .y = 8.0 + @as(f32, @floatFromInt(i / 15)) * 32.0,
        };
        try appendPathRequest(&stream, .{ .entity = entity, .start = start, .goal = .{ .x = 480, .y = 480 } });
    }
    return system.updateSerial(&stream, agent_count, .{ .max_fallback_requests_per_step = 0 });
}

fn updateEmpty(system: *PathfindingSystem, agent_count: usize) !void {
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    _ = try system.updateSerial(&empty, agent_count, .{});
}

/// A system grown 8 -> 40 agents on a `side` x `side` world with a 2-step shrink window.
fn intakeTestSystem(data: *const DataSystem, side: f32) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    capacity.capacity_shrink_window = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, side, side, 32);
    return system;
}

test "pathfinding intake drops past the logical frame cap regardless of capacity history" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [45]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt((i % 15) * 32), .y = @floatFromInt((i / 15) * 32) }, .{ .x = 8, .y = 8 }, false);
    }

    // A: grown directly 8 -> 40, then given extra physical slack on the intake list.
    var direct = try intakeTestSystem(&data, 512);
    defer direct.deinit();
    try updateEmpty(&direct, 40);
    try direct.intake_records.ensureTotalCapacity(std.testing.allocator, 160);

    // B: grown 8 -> 128, then shrunk to 40 after the 2-step low-load window.
    var history = try intakeTestSystem(&data, 512);
    defer history.deinit();
    try updateEmpty(&history, 128);
    try std.testing.expectEqual(@as(usize, 128), history.capacity.max_frame_requests);
    try updateEmpty(&history, 40);
    try updateEmpty(&history, 40);

    // Same logical cap, physical capacity above it on both (by different histories).
    inline for (.{ &direct, &history }) |system| {
        try std.testing.expectEqual(@as(usize, 40), system.capacity.max_frame_requests);
        try std.testing.expect(system.intake_records.capacity > 45);
    }

    const direct_stats = try submitSharedGoalBurst(&direct, &requesters, requesters.len, 40);
    const history_stats = try submitSharedGoalBurst(&history, &requesters, requesters.len, 40);
    inline for (.{ direct_stats, history_stats }) |stats| {
        try std.testing.expectEqual(@as(usize, 5), stats.dropped_requests);
        try std.testing.expectEqual(@as(usize, 1), stats.accepted_requests);
        try std.testing.expectEqual(@as(usize, 39), stats.duplicate_requests);
    }
    try std.testing.expectEqual(@as(usize, 1), direct.pending.len);
    try std.testing.expectEqual(@as(usize, 1), history.pending.len);
    try std.testing.expectEqual(requesters[0], direct.pending.at(0).entity);
    try std.testing.expectEqual(direct.pending.at(0).entity, history.pending.at(0).entity);
}

test "pathfinding intake drop count is independent of world size" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [45]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt((i % 15) * 32), .y = @floatFromInt((i / 15) * 32) }, .{ .x = 8, .y = 8 }, false);
    }

    // One 16-cell nav chunk (16x16 cells) vs four (32x32 cells), same 8 -> 40 history.
    var small = try intakeTestSystem(&data, 512);
    defer small.deinit();
    var large = try intakeTestSystem(&data, 1024);
    defer large.deinit();
    try std.testing.expectEqual(@as(usize, 16 * 16), small.graph.cellCount());
    try std.testing.expectEqual(@as(usize, 32 * 32), large.graph.cellCount());
    try updateEmpty(&small, 40);
    try updateEmpty(&large, 40);

    const small_stats = try submitSharedGoalBurst(&small, &requesters, requesters.len, 40);
    const large_stats = try submitSharedGoalBurst(&large, &requesters, requesters.len, 40);
    try std.testing.expectEqual(@as(usize, 5), small_stats.dropped_requests);
    try std.testing.expectEqual(small_stats.dropped_requests, large_stats.dropped_requests);
    try std.testing.expectEqual(small_stats.accepted_requests, large_stats.accepted_requests);
}

/// Every pool the intake/solve/publish paths `appendAssumeCapacity` into fits the
/// committed logical limits.
fn expectPoolsFitLogicalCaps(system: *const PathfindingSystem) !void {
    const cap = system.capacity;
    try std.testing.expect(system.pending.slotCount() >= cap.max_pending_requests);
    try std.testing.expect(system.intake_records.capacity >= cap.max_frame_requests);
    try std.testing.expect(system.intake_group_counts.capacity >= cap.max_frame_requests);
    try std.testing.expect(system.intake_tallies.capacity >= maxRangeCount(cap.max_frame_requests, intake_range_alignment_items));
    try std.testing.expect(system.solve_results.capacity >= cap.max_solved_requests_per_step);
    try std.testing.expect(system.fallback_indices.capacity >= cap.max_solved_requests_per_step);
    try std.testing.expect(system.solved_paths.capacity >= cap.max_solved_requests_per_step);
    try std.testing.expect(system.rotate_back_scratch.capacity >= cap.max_solved_requests_per_step);
    try std.testing.expect(system.group_requests.capacity >= cap.max_solved_requests_per_step);
    try std.testing.expect(system.worker_path_pool.items.len >= cap.max_solved_requests_per_step * types.resultBlockWords(cap.max_explored_nodes, cap.max_stitched_path_cells));
    try std.testing.expect(system.completed.long_block_words >= types.resultBlockWords(cap.max_explored_nodes, cap.max_stitched_path_cells));
    try std.testing.expect(system.fallback_tier1_slot.capacity >= cap.max_solved_requests_per_step);
    try std.testing.expect(system.tier1_scratch.items.len >= cap.max_escalated_solves_per_step);
    for (system.tier1_scratch.items) |*entry| {
        try std.testing.expect(entry.corridor.abstract.node_limit >= cap.max_abstract_nodes);
        try std.testing.expect(entry.corridor.stitched_limit >= cap.max_stitched_path_cells);
    }
    try std.testing.expect(system.scratch_slots.items.len >= @max(@as(usize, 1), cap.worker_participant_count));
    for (system.scratch_slots.items) |*scratch| {
        try std.testing.expect(scratch.explored_limit >= cap.max_explored_nodes);
        try std.testing.expect(scratch.corridor.abstract.node_limit >= @min(cap.tier0_abstract_node_cap, cap.max_abstract_nodes));
        try std.testing.expect(scratch.corridor.stitched_limit >= @min(cap.tier0_stitched_cell_cap, cap.max_stitched_path_cells));
    }
    try std.testing.expect(system.group_field_slots.capacity >= system.group_fields.items.len);
    try std.testing.expectEqual(cap.max_pending_requests, system.effective_agent_capacity);
}

/// Submits `count` requests with distinct goals (one goal cell each), fallback budget 0.
fn submitDistinctGoalBurst(system: *PathfindingSystem, requesters: []const EntityId, count: usize, agent_count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    for (requesters[0..count], 0..) |entity, i| {
        try appendPathRequest(&stream, .{
            .entity = entity,
            .start = .{ .x = 8, .y = 8 },
            .goal = .{ .x = 8.0 + @as(f32, @floatFromInt(i + 1)) * 32.0, .y = 200 },
        });
    }
    return system.updateSerial(&stream, agent_count, .{ .max_fallback_requests_per_step = 0 });
}

test "growForAgentCount grows at least 2x from the floor and keeps the shrink path" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = try intakeTestSystem(&data, 512);
    defer system.deinit();
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);

    try system.growForAgentCount(12);
    try std.testing.expectEqual(@as(usize, 16), system.effective_agent_capacity);
    try expectPoolsFitLogicalCaps(&system);
    // Already covered: no further growth.
    try system.growForAgentCount(12);
    try std.testing.expectEqual(@as(usize, 16), system.effective_agent_capacity);
}

test "coversAgentCount compares the live pools and the ceiling" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var unreserved = PathfindingSystem.init(std.testing.allocator);
    defer unreserved.deinit();
    try std.testing.expect(unreserved.coversAgentCount(1000));

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    try std.testing.expect(system.coversAgentCount(0));
    try std.testing.expect(system.coversAgentCount(8));
    // Past the ceiling: the seam must raise it.
    try std.testing.expect(!system.coversAgentCount(9));

    system.raiseAgentBudget(64);
    try std.testing.expectEqual(@as(usize, 64), system.agentBudget());
    try std.testing.expect(!system.coversAgentCount(9));
    try system.growForAgentCount(9);
    try std.testing.expect(system.coversAgentCount(9));
    try std.testing.expect(system.coversAgentCount(16));
    try std.testing.expect(!system.coversAgentCount(17));
}

test "an agent budget raise admits the whole crowd" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [12]EntityId = undefined;
    for (&requesters, 0..) |*slot, i| {
        slot.* = try addNavBody(&data, .{ .x = @floatFromInt(i * 32), .y = 400 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    system.raiseAgentBudget(48);
    try std.testing.expectEqual(@as(usize, 48), system.agentBudget());
    // A raise never lowers the ceiling.
    system.raiseAgentBudget(16);
    try std.testing.expectEqual(@as(usize, 48), system.agentBudget());
    try system.growForAgentCount(requesters.len);
    try std.testing.expect(system.coversAgentCount(requesters.len));

    // All 12 distinct requests are accepted; none drop.
    const stats = try submitDistinctGoalBurst(&system, &requesters, requesters.len, requesters.len);
    try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
    try std.testing.expectEqual(@as(usize, 12), stats.accepted_requests);
}

test "a grow that runs out of memory mid-resize keeps logical limits within every pool" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [12]EntityId = undefined;
    for (&requesters, 0..) |*slot, i| {
        slot.* = try addNavBody(&data, .{ .x = @floatFromInt(i * 32), .y = 400 }, .{ .x = 8, .y = 8 }, false);
    }

    // Sweep the failure point across every allocation of the 8 -> 40 grow.
    var failed_grows: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var system = try intakeTestSystem(&data, 512);
        defer system.deinit();
        const real_allocator = system.allocator;
        var failing = std.testing.FailingAllocator.init(real_allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        system.allocator = failing.allocator();
        const result = system.growForAgentCount(40);
        system.allocator = real_allocator;
        if (result) |_| {
            try std.testing.expectEqual(@as(usize, 40), system.effective_agent_capacity);
            try expectPoolsFitLogicalCaps(&system);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_grows += 1;
            // Falls back to the pre-grow limits, which every pool still fits.
            try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
            try std.testing.expectEqual(min_capacity_floor, system.capacity.max_frame_requests);
            try expectPoolsFitLogicalCaps(&system);
            // The next update runs safely at the old limits (no grow at 8 agents).
            const stats = try submitDistinctGoalBurst(&system, &requesters, requesters.len, min_capacity_floor);
            try std.testing.expectEqual(@as(usize, 4), stats.dropped_requests);
        }
    }
    try std.testing.expect(failed_grows > 1);
}

test "a budget re-reserve that runs out of memory keeps every solve inside its path stripe (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var small = baselineCapacity();
    small.max_explored_nodes = 8;
    small.max_stitched_path_cells = 2;
    small.tier0_stitched_cell_cap = 2;
    var large = small;
    large.max_explored_nodes = 1024;
    // A 13-cell straight hop inside one chunk: longer than the small stripe, so a search
    // past the small budget would write past its stripe.
    const start = math.Vec2{ .x = 8, .y = 8 };
    const goal = math.Vec2{ .x = 392, .y = 8 };
    try std.testing.expect(13 > types.resultBlockWords(small.max_explored_nodes, small.max_stitched_path_cells));

    // Sweep the failure point across a budget grow and a budget shrink.
    for ([_][2]PathfindingCapacity{ .{ small, large }, .{ large, small } }) |change| {
        var failed_reserves: usize = 0;
        var fail_index: usize = 0;
        while (fail_index < 256) : (fail_index += 1) {
            var system = PathfindingSystem.init(std.testing.allocator);
            defer system.deinit();
            try system.reserve(change[0]);
            try system.rebuildStaticNavGrid(&data, 512, 512, 32);
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
            system.allocator = failing.allocator();
            const result = system.reserve(change[1]);
            system.allocator = std.testing.allocator;
            if (result) |_| {
                try std.testing.expectEqual(change[1].max_explored_nodes, system.capacity.max_explored_nodes);
                try expectPoolsFitLogicalCaps(&system);
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failed_reserves += 1;
                try std.testing.expectEqual(small.max_explored_nodes, system.capacity.max_explored_nodes);
                try expectPoolsFitLogicalCaps(&system);
                // The solve spills at the small budget in whichever scratch it runs.
                var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
                defer stream.deinit();
                try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
                const stats = try system.updateSerial(&stream, 8, .{});
                try std.testing.expectEqual(@as(usize, 1), stats.budget_exhausted);
                try std.testing.expectEqual(@as(usize, 0), stats.available_results);
            }
        }
        try std.testing.expect(failed_reserves > 1);
    }
}

test "group-field threshold is independent of world size" {
    // The default threshold is the fixed 1024 on a 1024-cell grid and on a
    // 262,144-cell grid.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var large = PathfindingSystem.init(std.testing.allocator);
    defer large.deinit();
    try large.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 4096 });
    try large.rebuildStaticNavGrid(&data, 16384, 16384, 32);
    try std.testing.expectEqual(@as(usize, 512 * 512), large.graph.cellCount());

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 4096 });
    try system.rebuildStaticNavGrid(&data, 1024, 1024, 32);
    try std.testing.expectEqual(@as(usize, 32 * 32), system.graph.cellCount());

    try std.testing.expectEqual(@as(usize, 1024), large.groupFieldThreshold());
    try std.testing.expectEqual(large.groupFieldThreshold(), system.groupFieldThreshold());

    // A small same-goal group never reaches the threshold, so no O(cells) flow field is
    // built (the demo's few agents stay on individual A*).
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

test "group-field threshold is capped by the population ceiling" {
    // With max_agent_budget = 8 the default 1024 clamps to 8, so the threshold never
    // demands more sharers than can ever exist. No graph is needed: the threshold no
    // longer reads the grid.
    var capped = PathfindingSystem.init(std.testing.allocator);
    defer capped.deinit();
    try capped.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 8 });
    try std.testing.expectEqual(@as(usize, 8), capped.groupFieldThreshold());
}

test "a seam raise never moves the group-field threshold" {
    // Below min_group_field_agents the threshold clamps to the configured ceiling (8). A
    // seam raise lifts the live agent ceiling, but the threshold stays on the
    // ceiling frozen at reserve, so group-field policy never follows capacity history.
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 8 });
    try std.testing.expectEqual(@as(usize, 8), system.groupFieldThreshold());
    system.raiseAgentBudget(48);
    try std.testing.expectEqual(@as(usize, 48), system.agentBudget());
    try std.testing.expectEqual(@as(usize, 8), system.groupFieldThreshold());
}

test "group-field threshold pin is clamped" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .max_agent_budget = 4096, .min_group_field_agents = 0 });
    // A pin of 0 (formerly "derive from the grid") clamps to 1.
    try std.testing.expectEqual(@as(usize, 1), system.groupFieldThreshold());
    // A pin above the population ceiling clamps to the ceiling.
    system.capacity.min_group_field_agents = 5000;
    try std.testing.expectEqual(@as(usize, 4096), system.groupFieldThreshold());
    // An in-range pin is returned unchanged.
    system.capacity.min_group_field_agents = 2000;
    try std.testing.expectEqual(@as(usize, 2000), system.groupFieldThreshold());
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

    // Was 512 before border portals were consolidated to one per contiguous open
    // boundary run: the abstract graph is now far sparser
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

// ---- Request-side stages (path_intake, group_field_expand, pending ring) ----------

const intake_test_agents: usize = 40;

fn cellWorld(x: i32, y: i32) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(x)) * 32.0 + 16.0, .y = @as(f32, @floatFromInt(y)) * 32.0 + 16.0 };
}

fn appendIndividual(stream: *RangeOutputStream(PathRequest), entity: EntityId, goal: math.Vec2) !void {
    try appendPathRequest(stream, .{ .entity = entity, .start = cellWorld(1, 2), .goal = goal });
}

const IntakeGoals = struct {
    const hit = cellWorld(1, 1);
    const expired = cellWorld(2, 1);
    const expired_negative = cellWorld(3, 1);
    const negative = cellWorld(4, 1);
    const field = cellWorld(8, 8);
    const group = cellWorld(12, 5);
    // Inside the static body below: projected to an open cell.
    const blocked = cellWorld(10, 4);

    fn prefilled(index: usize) math.Vec2 {
        return cellWorld(@intCast(index % 16), @intCast(15 - index / 16));
    }

    fn distinct(index: usize) math.Vec2 {
        return cellWorld(@intCast(index % 16), @intCast(10 + index / 16));
    }
};

const intake_prefilled_count: usize = 30;

/// A 16x16-cell system at `intake_test_agents` agents holding, before the step under
/// test: 31 pending entries, a ready group field, one fresh and three expired cached
/// results (one of them also negative-cached, one also pending), and one negative.
fn intakeScenarioSystem(data: *const DataSystem, requester: EntityId, participant_count: usize) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.worker_participant_count = participant_count;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (0..intake_prefilled_count) |index| try appendIndividual(&stream, requester, IntakeGoals.prefilled(index));
    for (0..3) |index| {
        try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = cellWorld(@intCast(index), 3), .goal = IntakeGoals.field });
    }
    _ = try system.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(intake_prefilled_count + 1, system.pending.len);

    const step = system.step_counter;
    var put_stats = PathfindingStats{};
    const path = [_]u32{ 17, 18 };
    const key = struct {
        fn of(s: *const PathfindingSystem, goal: math.Vec2) PathQueryKey {
            return s.graph.keyForWorld(0, goal, .default).?;
        }
    }.of;
    system.completed.put(key(&system, IntakeGoals.hit), &path, &.{}, 0, step, &put_stats);
    system.completed.put(key(&system, IntakeGoals.expired), &path, &.{}, 0, step -% 400, &put_stats);
    system.completed.put(key(&system, IntakeGoals.expired_negative), &path, &.{}, 0, step -% 400, &put_stats);
    system.completed.put(key(&system, IntakeGoals.prefilled(0)), &path, &.{}, 0, step -% 400, &put_stats);
    _ = system.unavailable.insert(key(&system, IntakeGoals.negative));
    _ = system.unavailable.insert(key(&system, IntakeGoals.expired_negative));
    return system;
}

// Forty requests crossing every intake class, with repeats in different ranges.
fn writeIntakeScenarioRequests(stream: *RangeOutputStream(PathRequest), entity: EntityId) !void {
    const Kind = enum { hit, expired, negative, field, out_of_range, blocked, expired_negative, prefilled, group, distinct };
    const Item = struct { kind: Kind, index: usize = 0 };
    const items = [_]Item{
        .{ .kind = .hit },                   .{ .kind = .expired },               .{ .kind = .negative },              .{ .kind = .field },
        .{ .kind = .out_of_range },          .{ .kind = .blocked },               .{ .kind = .expired_negative },      .{ .kind = .distinct },
        .{ .kind = .prefilled, .index = 1 }, .{ .kind = .group },                 .{ .kind = .prefilled },             .{ .kind = .distinct, .index = 1 },
        .{ .kind = .distinct, .index = 2 },  .{ .kind = .distinct, .index = 3 },  .{ .kind = .prefilled, .index = 2 }, .{ .kind = .distinct, .index = 4 },
        .{ .kind = .distinct, .index = 5 },  .{ .kind = .distinct, .index = 6 },  .{ .kind = .field },                 .{ .kind = .distinct, .index = 7 },
        .{ .kind = .distinct, .index = 8 },  .{ .kind = .distinct, .index = 9 },  .{ .kind = .distinct, .index = 10 }, .{ .kind = .distinct, .index = 11 },
        .{ .kind = .hit },                   .{ .kind = .prefilled, .index = 3 }, .{ .kind = .distinct, .index = 12 }, .{ .kind = .distinct, .index = 13 },
        .{ .kind = .group },                 .{ .kind = .distinct, .index = 14 }, .{ .kind = .expired },               .{ .kind = .negative },
        .{ .kind = .distinct, .index = 15 }, .{ .kind = .group },                 .{ .kind = .blocked },               .{ .kind = .distinct, .index = 16 },
        .{ .kind = .distinct, .index = 17 }, .{ .kind = .distinct, .index = 18 }, .{ .kind = .distinct },              .{ .kind = .distinct, .index = 19 },
    };
    comptime std.debug.assert(items.len == intake_test_agents);
    for (items, 0..) |item, position| {
        var request = PathRequest{ .entity = entity, .start = cellWorld(@intCast(position % 6), 2), .goal = undefined };
        request.goal = switch (item.kind) {
            .hit => IntakeGoals.hit,
            .expired => IntakeGoals.expired,
            .negative => IntakeGoals.negative,
            .field => IntakeGoals.field,
            .out_of_range => IntakeGoals.hit,
            .blocked => IntakeGoals.blocked,
            .expired_negative => IntakeGoals.expired_negative,
            .prefilled => IntakeGoals.prefilled(item.index),
            .group => IntakeGoals.group,
            .distinct => IntakeGoals.distinct(item.index),
        };
        if (item.kind == .out_of_range) request.goal_level = 3;
        if (item.kind == .field or item.kind == .group) request.kind = .group;
        try appendPathRequest(stream, request);
    }
}

fn expectRequestStatsEqual(expected: PathfindingStats, actual: PathfindingStats) !void {
    inline for (.{
        "accepted_requests", "duplicate_requests",  "pending_requests",    "dropped_requests",
        "cache_hits",        "available_results",   "unavailable_results", "group_field_samples",
        "goal_projected",    "group_fields_built",  "group_field_reuses",  "group_field_rebuild_throttled",
        "cache_evictions",   "distinct_group_keys", "deferred_requests",
    }) |name| {
        try std.testing.expectEqual(@field(expected, name), @field(actual, name));
    }
}

fn expectRequestStateEqual(expected: *const PathfindingSystem, actual: *const PathfindingSystem) !void {
    try std.testing.expectEqual(expected.pending.len, actual.pending.len);
    for (0..expected.pending.len) |index| {
        try std.testing.expectEqualDeep(expected.pending.at(index), actual.pending.at(index));
        try std.testing.expect(actual.pending_keys.contains(expected.pending.at(index).key));
    }
    try std.testing.expectEqual(expected.group_requests.items.len, actual.group_requests.items.len);
    for (expected.group_requests.items, actual.group_requests.items) |expected_tally, actual_tally| {
        try std.testing.expectEqualDeep(expected_tally, actual_tally);
    }
    try std.testing.expectEqual(expected.completed.slots.items.len, actual.completed.slots.items.len);
    for (expected.completed.slots.items, actual.completed.slots.items) |expected_slot, actual_slot| {
        try std.testing.expectEqualDeep(expected_slot, actual_slot);
    }
}

test "threaded request intake equals serial intake across range sizes and worker counts" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, IntakeGoals.blocked, .{ .x = 32, .y = 32 }, true);
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeIntakeScenarioRequests(&stream, requester);

    var serial = try intakeScenarioSystem(&data, requester, 1);
    defer serial.deinit();
    const serial_stats = try serial.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
    // The scenario reaches every class.
    try std.testing.expectEqual(@as(usize, 2), serial_stats.group_field_samples);
    try std.testing.expectEqual(@as(usize, 2), serial_stats.available_results);
    try std.testing.expectEqual(@as(usize, 3), serial_stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), serial_stats.goal_projected);
    try std.testing.expect(serial_stats.dropped_requests > 1);
    try std.testing.expectEqual(intake_test_agents, serial.pending.len);
    try std.testing.expect(serial.completed.slotIndex(serial.graph.keyForWorld(0, IntakeGoals.expired, .default).?) == null);
    try std.testing.expect(serial.completed.slotIndex(serial.graph.keyForWorld(0, IntakeGoals.expired_negative, .default).?) == null);
    try std.testing.expect(serial.completed.slotIndex(serial.graph.keyForWorld(0, IntakeGoals.prefilled(0), .default).?) == null);

    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 8 });
        defer threads.deinit();
        for ([_]usize{ 8, 16, intake_test_agents }) |items_per_range| {
            var threaded = try intakeScenarioSystem(&data, requester, threads.participantSlotCount());
            defer threaded.deinit();
            const stats = try threaded.update(&stream, intake_test_agents, &threads, .{
                .adaptive = false,
                .items_per_range = items_per_range,
                .max_fallback_requests_per_step = 0,
            });
            // Several ranges take the classify-and-merge path; one range the direct pass.
            if (items_per_range < intake_test_agents and threads.workerThreadCount() > 0) {
                try std.testing.expect(!stats.intake_batch.ran_inline);
            } else {
                try std.testing.expect(stats.intake_batch.ran_inline);
            }
            try expectRequestStatsEqual(serial_stats, stats);
            try expectRequestStateEqual(&serial, &threaded);
        }
    }
}

fn repeatsTestSystem(data: *const DataSystem, participant_count: usize, filler: ?*const RangeOutputStream(PathRequest)) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.worker_participant_count = participant_count;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, 512, 512, 32);
    if (filler) |stream| {
        _ = try system.updateSerial(stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
        try std.testing.expectEqual(intake_test_agents, system.pending.len);
    }
    return system;
}

test "threaded intake folds a new goal's repeats per range and equals serial when accepted and when pending is full" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var repeated = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer repeated.deinit();
    for (0..intake_test_agents) |index| {
        try appendPathRequest(&repeated, .{ .entity = requester, .start = cellWorld(@intCast(index % 6), 2), .goal = cellWorld(9, 9) });
    }
    var filler = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer filler.deinit();
    for (0..intake_test_agents) |index| try appendIndividual(&filler, requester, IntakeGoals.distinct(index));
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 8 });
    defer threads.deinit();

    for ([_]bool{ false, true }) |pending_full| {
        const prefill: ?*const RangeOutputStream(PathRequest) = if (pending_full) &filler else null;
        var serial = try repeatsTestSystem(&data, 1, prefill);
        defer serial.deinit();
        const serial_stats = try serial.updateSerial(&repeated, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
        if (pending_full) {
            try std.testing.expectEqual(intake_test_agents, serial_stats.dropped_requests);
            try std.testing.expectEqual(@as(usize, 0), serial_stats.accepted_requests);
        } else {
            try std.testing.expectEqual(@as(usize, 1), serial_stats.accepted_requests);
            try std.testing.expectEqual(intake_test_agents - 1, serial_stats.duplicate_requests);
        }

        var threaded = try repeatsTestSystem(&data, threads.participantSlotCount(), prefill);
        defer threaded.deinit();
        const stats = try threaded.update(&repeated, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 8, .max_fallback_requests_per_step = 0 });
        try expectRequestStatsEqual(serial_stats, stats);
        try expectRequestStateEqual(&serial, &threaded);
        // One record per range reaches the merge, not one per request.
        var merged_records: usize = 0;
        for (threaded.intake_tallies.items) |tally| merged_records += tally.record_count;
        try std.testing.expectEqual(threaded.intake_tallies.items.len, merged_records);
        try std.testing.expectEqual(intake_test_agents / 8, threaded.intake_tallies.items.len);
    }
}

test "intake cell conversion in four lanes equals worldToCellClamped" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 512, 320, 32);
    const grid = system.graph.grid(0).?;
    const inf = std.math.inf(f32);
    const positions = [_]math.Vec2{
        .{ .x = 16, .y = 16 },               .{ .x = -5, .y = 40 },    .{ .x = 9000, .y = 9000 }, .{ .x = 511.9, .y = 319.9 },
        .{ .x = std.math.nan(f32), .y = 3 }, .{ .x = inf, .y = -inf }, .{ .x = 31.999, .y = 32 }, .{ .x = -0.0, .y = 1e30 },
        .{ .x = 100, .y = -1e30 },
    };
    const entity = try data.createEntity();
    var requests: [positions.len]PathRequest = undefined;
    for (&requests, 0..) |*request, index| {
        request.* = .{ .entity = entity, .start = positions[index], .goal = positions[positions.len - 1 - index] };
    }
    for (0..requests.len + 1) |len| {
        var cells: [positions.len]IntakeCells = undefined;
        intakeCells(grid, requests[0..len], cells[0..len]);
        for (requests[0..len], cells[0..len]) |request, cell| {
            try std.testing.expectEqualDeep(grid.worldToCellClamped(request.start), cell.start);
            try std.testing.expectEqualDeep(grid.worldToCellClamped(request.goal), cell.goal);
        }
    }
}

test "request intake after reserve allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 8 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, IntakeGoals.blocked, .{ .x = 32, .y = 32 }, true);
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeIntakeScenarioRequests(&stream, requester);

    var system = try intakeScenarioSystem(&data, requester, threads.participantSlotCount());
    defer system.deinit();
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    const stats = try system.update(&stream, intake_test_agents, &threads, .{
        .adaptive = false,
        .items_per_range = 8,
        .max_fallback_requests_per_step = 0,
    });
    try std.testing.expect(!stats.intake_batch.ran_inline);
    try std.testing.expect(stats.intake_batch.range_count > 1);
    try std.testing.expect(stats.accepted_requests > 0);
}

test "group tallies keep first-occurrence order and exact counts with more than eight keys per range" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    // Twelve group keys, then the first four again (evicted from the eight-entry
    // recent table by then), then key 11 again (still recent).
    const sequence = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 1, 2, 3, 11, 0 };
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (sequence) |key_index| {
        try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = cellWorld(1, 2), .goal = cellWorld(@intCast(key_index), 12) });
    }
    var expected_counts: [12]usize = @splat(0);
    for (sequence) |key_index| expected_counts[key_index] += 1;

    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    // Above every count, so no field builds and the tallies stay as merged.
    capacity.min_group_field_agents = 64;
    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(capacity);
    try serial.rebuildStaticNavGrid(&data, 512, 512, 32);
    const serial_stats = try serial.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 12), serial_stats.distinct_group_keys);
    for (serial.group_requests.items, 0..) |tally, key_index| {
        try std.testing.expectEqualDeep(serial.graph.keyForWorld(0, cellWorld(@intCast(key_index), 12), .default).?, tally.key);
        try std.testing.expectEqual(expected_counts[key_index], tally.count);
    }

    if (builtin.single_threaded) return;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();
    capacity.worker_participant_count = threads.participantSlotCount();
    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    try threaded.reserve(capacity);
    try threaded.rebuildStaticNavGrid(&data, 512, 512, 32);
    const stats = try threaded.update(&stream, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 8, .max_fallback_requests_per_step = 0 });
    try expectRequestStatsEqual(serial_stats, stats);
    try expectRequestStateEqual(&serial, &threaded);
}

fn groupFieldServiceSystem(data: *const DataSystem, participant_count: usize) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.max_group_fields = 4;
    capacity.group_field_build_budget = 64;
    capacity.group_field_rebuild_min_steps = 1;
    capacity.worker_participant_count = participant_count;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, 512, 512, 32);
    return system;
}

// Each goal requested by three agents; the schedule's step `step` uses `goals[step]`.
fn writeGroupGoals(stream: *RangeOutputStream(PathRequest), entity: EntityId, goals: []const math.Vec2) !void {
    stream.clearRetainingCapacity();
    for (goals) |goal| {
        for (0..3) |member| {
            try appendPathRequest(stream, .{ .entity = entity, .kind = .group, .start = cellWorld(@intCast(member), 2), .goal = goal });
        }
    }
}

fn expectGroupFieldsEqual(expected: *const PathfindingSystem, actual: *const PathfindingSystem) !void {
    try std.testing.expectEqual(expected.next_group_evict, actual.next_group_evict);
    for (expected.group_fields.items, actual.group_fields.items) |*expected_field, *actual_field| {
        try std.testing.expectEqual(expected_field.state, actual_field.state);
        try std.testing.expectEqualDeep(expected_field.key, actual_field.key);
        try std.testing.expectEqual(expected_field.goal_index, actual_field.goal_index);
        try std.testing.expectEqual(expected_field.generation, actual_field.generation);
        try std.testing.expectEqual(expected_field.current_distance, actual_field.current_distance);
        try std.testing.expectEqual(expected_field.pushed_count, actual_field.pushed_count);
        try std.testing.expectEqual(expected_field.fresh_this_step, actual_field.fresh_this_step);
        try std.testing.expectEqual(expected_field.last_build_step, actual_field.last_build_step);
        try std.testing.expectEqual(expected_field.used_blocks, actual_field.used_blocks);
        const grid = expected.graph.grid(expected_field.key.goal_level) orelse continue;
        for (0..grid.cellCount()) |cell| {
            try std.testing.expectEqualDeep(expected_field.lookup(grid, cell), actual_field.lookup(grid, cell));
        }
    }
}

const group_service_schedule = [_][]const math.Vec2{
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
};

test "threaded group-field service equals serial for four fields building, finishing, rekeyed, and evicted" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try groupFieldServiceSystem(&data, 1);
    defer serial.deinit();
    var threaded = try groupFieldServiceSystem(&data, threads.participantSlotCount());
    defer threaded.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();

    var totals = PathfindingStats{};
    var threaded_passes: usize = 0;
    for (group_service_schedule) |goals| {
        try writeGroupGoals(&stream, requester, goals);
        const serial_stats = try serial.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
        const stats = try threaded.update(&stream, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 1, .max_fallback_requests_per_step = 0 });
        try expectRequestStatsEqual(serial_stats, stats);
        try expectGroupFieldsEqual(&serial, &threaded);
        try expectRequestStateEqual(&serial, &threaded);
        for ([_]BatchStats{ stats.group_field_batch, stats.group_field_begin_batch }) |batch| {
            if (!batch.ran_inline and batch.item_count > 1) threaded_passes += 1;
        }
        totals.group_fields_built += serial_stats.group_fields_built;
        totals.cache_evictions += serial_stats.cache_evictions;
        totals.group_field_rebuild_throttled += serial_stats.group_field_rebuild_throttled;
    }
    // The schedule builds four fields, finishes them, rekeys the moved goal, and evicts.
    var ready: usize = 0;
    for (serial.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
    try std.testing.expect(ready > 0);
    try std.testing.expect(totals.group_fields_built > 4);
    try std.testing.expect(totals.cache_evictions > 0);
    if (threads.workerThreadCount() > 0) try std.testing.expect(threaded_passes > 0);
}

test "group-field service allocates nothing on workers (FailingAllocator, multi-worker)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = try groupFieldServiceSystem(&data, threads.participantSlotCount());
    defer system.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(16, 16);
    const config = PathfindingConfig{ .adaptive = false, .items_per_range = 1, .max_fallback_requests_per_step = 0 };
    // Warm-up: build the four goals to ready in their slots, so each field's pool reaches
    // its high-water size, then drop every field and request (pools are kept).
    try writeGroupGoals(&stream, requester, group_service_schedule[0]);
    var ready: usize = 0;
    var guard: usize = 0;
    while (ready < 4 and guard < 256) : (guard += 1) {
        _ = try system.update(&stream, intake_test_agents, &threads, config);
        ready = 0;
        for (system.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
    }
    try std.testing.expectEqual(@as(usize, 4), ready);
    system.clearRuntimeState();
    try writeGroupGoals(&stream, requester, group_service_schedule[0][0..2]);
    _ = try system.update(&stream, intake_test_agents, &threads, config);

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    // Two fields still building advance; two new goals begin.
    try writeGroupGoals(&stream, requester, group_service_schedule[0]);
    const stats = try system.update(&stream, intake_test_agents, &threads, config);
    try std.testing.expectEqual(@as(usize, 2), stats.group_field_batch.item_count);
    try std.testing.expect(!stats.group_field_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 2), stats.group_field_begin_batch.item_count);
    try std.testing.expect(!stats.group_field_begin_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 2), stats.group_fields_built);
}

// A 64x64-cell system in 4-cell nav chunks whose fields cross many chunks, so cold field
// pools stall and grow while they build.
fn stallingFieldCapacity(participant_count: usize) PathfindingCapacity {
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.max_group_fields = 4;
    capacity.group_field_build_budget = 64;
    capacity.group_field_rebuild_min_steps = 1;
    capacity.nav_chunk_tiles = 4;
    capacity.worker_participant_count = participant_count;
    return capacity;
}

const stalling_field_goals = [_]math.Vec2{ cellWorld(5, 58), cellWorld(58, 58), cellWorld(58, 5), cellWorld(30, 30) };

test "an unbuilt group field holds no memory after reserve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(stallingFieldCapacity(1));
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    try std.testing.expectEqual(@as(usize, 4), system.group_fields.items.len);
    for (system.group_fields.items) |field| try std.testing.expectEqual(@as(usize, 0), field.residentBytes());
    try std.testing.expectEqual(@as(u64, 0), system.group_field_pool_grows);
}

test "a field cell cap at the slot-id width fails the reserve" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.group_field_max_cells = group_field_cell_limit;
    try std.testing.expectError(error.OutOfMemory, system.reserve(capacity));
    capacity.group_field_max_cells = group_field_cell_limit - 1;
    try system.reserve(capacity);
}

test "a field-budget re-reserve out of memory never leaves more fields than field slots (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeGroupGoals(&stream, requester, &stalling_field_goals);

    var small = stallingFieldCapacity(1);
    small.max_group_fields = 2;
    small.group_field_max_cells = 300;
    var large = small;
    large.max_group_fields = 4;
    large.group_field_max_cells = 1200;
    for ([_][2]PathfindingCapacity{ .{ small, large }, .{ large, small } }) |change| {
        var failed_reserves: usize = 0;
        var fail_index: usize = 0;
        while (fail_index < 256) : (fail_index += 1) {
            var system = PathfindingSystem.init(std.testing.allocator);
            defer system.deinit();
            try system.reserve(change[0]);
            try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
            system.allocator = failing.allocator();
            const result = system.reserve(change[1]);
            system.allocator = std.testing.allocator;
            try std.testing.expect(system.group_field_slots.capacity >= system.group_fields.items.len);
            var expected_capacity = change[1];
            if (result) |_| {} else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failed_reserves += 1;
                expected_capacity.max_group_fields = @min(change[0].max_group_fields, change[1].max_group_fields);
                expected_capacity.group_field_max_cells = @min(change[0].group_field_max_cells, change[1].group_field_max_cells);
                try std.testing.expectEqual(expected_capacity.max_group_fields, system.capacity.max_group_fields);
                try std.testing.expectEqual(expected_capacity.group_field_max_cells, system.capacity.group_field_max_cells);
            }
            // The fields build exactly as in a system reserved directly at those budgets.
            var reference = PathfindingSystem.init(std.testing.allocator);
            defer reference.deinit();
            try reference.reserve(change[0]);
            try reference.reserve(expected_capacity);
            try reference.rebuildStaticNavGrid(&data, 2048, 2048, 32);
            for (0..6) |_| {
                _ = try system.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
                _ = try reference.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
                try expectGroupFieldsEqual(&reference, &system);
            }
            if (result) |_| break else |_| {}
        }
        try std.testing.expect(failed_reserves > 1);
    }
}

test "threaded group-field service with stall rounds equals serial and runs on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(stallingFieldCapacity(1));
    try serial.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    try threaded.reserve(stallingFieldCapacity(threads.participantSlotCount()));
    try threaded.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeGroupGoals(&stream, requester, &stalling_field_goals);
    // A system whose pools already hold every field: its builds never stall.
    var warm = PathfindingSystem.init(std.testing.allocator);
    defer warm.deinit();
    try warm.reserve(stallingFieldCapacity(1));
    try warm.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    for (0..80) |_| _ = try warm.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
    warm.clearRuntimeState();
    const warm_grows = warm.group_field_pool_grows;

    var threaded_passes: usize = 0;
    for (0..80) |_| {
        const serial_stats = try serial.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
        const stats = try threaded.update(&stream, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 1, .max_fallback_requests_per_step = 0 });
        _ = try warm.updateSerial(&stream, intake_test_agents, .{ .max_fallback_requests_per_step = 0 });
        try expectRequestStatsEqual(serial_stats, stats);
        try expectGroupFieldsEqual(&serial, &threaded);
        // Stalled fields resume in the same step: per-step progress never depends on pools.
        for (serial.group_fields.items, warm.group_fields.items) |cold_field, warm_field| {
            try std.testing.expectEqual(warm_field.state, cold_field.state);
            try std.testing.expectEqual(warm_field.pushed_count, cold_field.pushed_count);
            try std.testing.expectEqual(warm_field.current_distance, cold_field.current_distance);
        }
        for ([_]BatchStats{ stats.group_field_batch, stats.group_field_begin_batch }) |batch| {
            if (!batch.ran_inline and batch.item_count > 1) threaded_passes += 1;
        }
    }
    // Pools grew past their first-build size on both, by the same steps; never when warm.
    try std.testing.expectEqual(warm_grows, warm.group_field_pool_grows);
    try std.testing.expect(serial.group_field_pool_grows > 4);
    try std.testing.expectEqual(serial.group_field_pool_grows, threaded.group_field_pool_grows);
    var ready: usize = 0;
    for (serial.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
    try std.testing.expectEqual(@as(usize, 4), ready);
    if (threads.workerThreadCount() > 0) try std.testing.expect(threaded_passes > 0);
}

test "a first group-field build that cannot allocate builds nothing and retries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeGroupGoals(&stream, requester, stalling_field_goals[0..1]);
    const config = PathfindingConfig{ .max_fallback_requests_per_step = 0 };

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try writeGroupGoals(&empty, requester, &.{});

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(stallingFieldCapacity(1));
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    // A request-free step sizes the per-step pools for the agent count first.
    _ = try system.updateSerial(&empty, intake_test_agents, config);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    const failed = try system.updateSerial(&stream, intake_test_agents, config);
    system.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), failed.group_fields_built);
    try std.testing.expectEqual(@as(u64, 1), system.group_field_pool_failures);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
        try std.testing.expectEqual(@as(usize, 0), field.residentBytes());
    }

    // The next step builds the same field a fresh system builds on its first step.
    const retried = try system.updateSerial(&stream, intake_test_agents, config);
    try std.testing.expectEqual(@as(usize, 1), retried.group_fields_built);
    var fresh = PathfindingSystem.init(std.testing.allocator);
    defer fresh.deinit();
    try fresh.reserve(stallingFieldCapacity(1));
    try fresh.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    _ = try fresh.updateSerial(&empty, intake_test_agents, config);
    _ = try fresh.updateSerial(&stream, intake_test_agents, config);
    const grid = system.graph.grid(0).?;
    const field = &system.group_fields.items[0];
    const expected = &fresh.group_fields.items[0];
    try std.testing.expectEqual(GroupFieldState.building, field.state);
    try std.testing.expectEqual(expected.pushed_count, field.pushed_count);
    try std.testing.expectEqual(expected.used_blocks, field.used_blocks);
    for (0..grid.cellCount()) |cell| try std.testing.expectEqualDeep(expected.lookup(grid, cell), field.lookup(grid, cell));
}

test "solve results land at their fallback ordinal and publish in pending order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 3), cellWorld(6, 5), cellWorld(6, 7) };
    for (goals) |goal| try appendIndividual(&stream, requester, goal);
    _ = try system.updateSerial(&stream, 8, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(goals.len, system.pending.len);
    // Pending 0 and 1 are escalated: the one-per-step tier-1 cap admits 0 and defers 1,
    // so ordinals 0, 1, 2 hold pending 0, 2, 3.
    system.pending.ptr(0).tier = 1;
    system.pending.ptr(1).tier = 1;
    var keys: [goals.len]PathQueryKey = undefined;
    for (&keys, 0..) |*key, index| key.* = system.pending.at(index).key;

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const stats = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.escalated_deferred);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, system.fallback_indices.items);
    try std.testing.expectEqual(@as(usize, 3), system.solve_results.items.len);
    const stride = types.resultBlockWords(system.capacity.max_explored_nodes, system.capacity.max_stitched_path_cells);
    for (system.solve_results.items, system.solved_paths.items, 0..) |result, solved, ordinal| {
        const key = keys[system.fallback_indices.items[ordinal]];
        try std.testing.expectEqualDeep(key, result.available);
        try std.testing.expectEqualDeep(key, solved.key);
        try std.testing.expectEqual(ordinal * stride, solved.offset);
    }
    // Published results serve their own goals; the deferred one stays pending first.
    for ([_]usize{ 0, 2, 3 }) |index| {
        const view = system.statusForWorld(0, cellWorld(1, 2), 0, goals[index], .default, null);
        try std.testing.expectEqual(PathStatus.available, view.status);
        const path = system.completed.pathSlice(system.completed.slotIndex(keys[index]).?, system.completed.resultAt(system.completed.slotIndex(keys[index]).?).path_len);
        try std.testing.expectEqual(@as(u32, @intCast(system.graph.grid(0).?.indexForCell(keys[index].goal).?)), path[path.len - 1]);
    }
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try std.testing.expectEqualDeep(keys[1], system.pending.at(0).key);
}

test "pending compaction keeps deferred, tail, and rotated order across a ring wrap" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    try std.testing.expectEqual(@as(usize, 8), system.pending.slotCount());

    // Seven entries starting at physical slot 6, so logical 2.. wrap to slot 0.
    system.pending.clear();
    system.pending.head = 6;
    var keys: [7]PathQueryKey = undefined;
    for (&keys, 0..) |*key, index| {
        key.* = system.graph.keyForWorld(0, cellWorld(@intCast(index), 4), .default).?;
        system.pending.push(.{ .entity = try data.createEntity(), .key = key.*, .start_level = 0, .start = .{ .x = 0, .y = 0 }, .goal_index = 0 });
        _ = system.pending_keys.insert(key.*);
    }
    system.pending.ptr(3).tier = 1;
    var entities: [7]EntityId = undefined;
    for (&entities, 0..) |*entity, index| entity.* = system.pending.at(index).entity;

    // Window [0, 5): 1 was not admitted (deferred); 0 solved; 2 and 4 spilled at tier 0
    // (rotate); 3 spilled at tier 1 (dropped). 5 and 6 are the tail.
    system.fallback_indices.clearRetainingCapacity();
    system.fallback_indices.appendSliceAssumeCapacity(&.{ 0, 2, 3, 4 });
    system.solve_results.clearRetainingCapacity();
    system.solve_results.appendSliceAssumeCapacity(&.{
        .{ .available = keys[0] },
        .{ .budget_exhausted = keys[2] },
        .{ .budget_exhausted = keys[3] },
        .{ .budget_exhausted = keys[4] },
    });
    var stats = PathfindingStats{};
    system.compactPendingAfterSolve(5, &stats);

    const expected_order = [_]usize{ 1, 5, 6, 2, 4 };
    try std.testing.expectEqual(expected_order.len, system.pending.len);
    for (expected_order, 0..) |source, logical| {
        try std.testing.expectEqual(entities[source], system.pending.at(logical).entity);
        try std.testing.expect(system.pending_keys.contains(keys[source]));
    }
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(3).tier);
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(4).tier);
    try std.testing.expectEqual(@as(u8, 0), system.pending.at(0).tier);
    try std.testing.expect(!system.pending_keys.contains(keys[0]));
    try std.testing.expect(!system.pending_keys.contains(keys[3]));
    try std.testing.expectEqual(@as(usize, 1), stats.escalated_dropped);
}

// Solves `goals` from cellWorld(1, 2) in one serial step with the default budgets.
fn solveIndividualGoals(system: *PathfindingSystem, requester: EntityId, goals: []const math.Vec2, agent_count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (goals) |goal| try appendIndividual(&stream, requester, goal);
    return system.updateSerial(&stream, agent_count, .{});
}

// The stored cells of `goal`'s cached plain path, copied out.
fn cachedPathCells(system: *const PathfindingSystem, goal: math.Vec2) !std.ArrayList(u32) {
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const slot = system.completed.slotIndex(key) orelse return error.TestExpectedCachedPath;
    var cells: std.ArrayList(u32) = .empty;
    errdefer cells.deinit(std.testing.allocator);
    try cells.appendSlice(std.testing.allocator, system.completed.pathSlice(slot, system.completed.resultAt(slot).path_len));
    return cells;
}

test "pathfinding an elastic grow and shrink keep cached paths, negatives, and pending" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = try intakeTestSystem(&data, 512);
    defer system.deinit();
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
    const no_fallback = PathfindingConfig{ .max_fallback_requests_per_step = 0 };

    // Two paths cached at the floor capacity, two more after a grow to 40 agents (their
    // payloads sit above the floor's cache limit, so the shrink must move them).
    const cached_goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4), cellWorld(3, 13) };
    try std.testing.expectEqual(@as(usize, 2), (try solveIndividualGoals(&system, requester, cached_goals[0..2], 8)).available_results);
    var before: [cached_goals.len]std.ArrayList(u32) = undefined;
    var copied: usize = 0;
    defer for (before[0..copied]) |*cells| cells.deinit(std.testing.allocator);
    for (cached_goals[0..2]) |goal| {
        before[copied] = try cachedPathCells(&system, goal);
        copied += 1;
    }

    try system.growForAgentCount(40);
    try std.testing.expect(system.effective_agent_capacity >= 40);
    for (cached_goals[0..2], before[0..2]) |goal, cells| {
        var after = try cachedPathCells(&system, goal);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u32, cells.items, after.items);
    }
    try std.testing.expectEqual(@as(usize, 2), (try solveIndividualGoals(&system, requester, cached_goals[2..4], 40)).available_results);
    for (cached_goals[2..4]) |goal| {
        before[copied] = try cachedPathCells(&system, goal);
        copied += 1;
    }

    // A definitive negative and two requests left pending.
    const negative_goal = cellWorld(14, 14);
    _ = system.unavailable.insert(system.graph.keyForWorld(0, negative_goal, .default).?);
    const pending_goals = [_]math.Vec2{ cellWorld(9, 12), cellWorld(2, 7) };
    var pending_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer pending_stream.deinit();
    for (pending_goals) |goal| try appendIndividual(&pending_stream, requester, goal);
    _ = try system.updateSerial(&pending_stream, 40, no_fallback);

    // Sustained low load shrinks back to the floor.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..system.capacity.capacity_shrink_window) |_| _ = try system.updateSerial(&empty, 1, no_fallback);
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);

    for (cached_goals, before) |goal, cells| {
        var after = try cachedPathCells(&system, goal);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u32, cells.items, after.items);
        try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, cellWorld(1, 2), 0, negative_goal, .default, null).status);
    for (pending_goals) |goal| {
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }

    // Re-requesting the cached goals hits the cache: no re-solve.
    var again = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer again.deinit();
    for (cached_goals) |goal| try appendIndividual(&again, requester, goal);
    const again_stats = try system.updateSerial(&again, 8, no_fallback);
    try std.testing.expectEqual(cached_goals.len, again_stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 0), again_stats.solved_requests);
}

test "pathfinding result publish after its reserve allocates nothing (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Two-word inline stripes: every multi-cell path is a long result.
    var capacity = baselineCapacity();
    capacity.max_stored_path_cells = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4), cellWorld(3, 13) };

    // Warm: the first publish grows the long pool at its reserve.
    try std.testing.expectEqual(goals.len, (try solveIndividualGoals(&system, requester, &goals, 8)).available_results);
    try std.testing.expect(system.completed.long_block_count >= goals.len);
    const grows = system.long_block_grows;
    try std.testing.expect(grows >= 1);

    // Cleared (every block free again), the same results publish on a failing allocator.
    system.completed.clear();
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    const stats = try solveIndividualGoals(&system, requester, &goals, 8);
    try std.testing.expectEqual(goals.len, stats.available_results);
    try std.testing.expectEqual(grows, system.long_block_grows);
    for (goals) |goal| {
        var cells = try cachedPathCells(&system, goal);
        defer cells.deinit(std.testing.allocator);
        // Stored whole: the path runs from the start cell to the goal cell, past the stripe.
        const grid = system.graph.grid(0).?;
        try std.testing.expect(cells.items.len > capacity.max_stored_path_cells);
        try std.testing.expectEqual(@as(u32, @intCast(grid.indexForCell(grid.worldToCellClamped(cellWorld(1, 2))).?)), cells.items[0]);
        try std.testing.expectEqual(@as(u32, @intCast(grid.indexForCell(grid.worldToCellClamped(goal)).?)), cells.items[cells.items.len - 1]);
    }
}

test "pathfinding a publish reserve out of memory publishes nothing and leaves pending for retry (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Two-word inline stripes: every multi-cell path is a long result.
    var capacity = baselineCapacity();
    capacity.max_stored_path_cells = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // Warm the step on a one-cell (inline) result, then clear: the long pool stays empty.
    try std.testing.expectEqual(@as(usize, 1), (try solveIndividualGoals(&system, requester, &.{cellWorld(1, 2)}, 8)).available_results);
    system.completed.clear();
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);

    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4) };
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const failed = solveIndividualGoals(&system, requester, &goals, 8);
    system.allocator = original;
    system.graph.allocator = original;
    try std.testing.expectError(error.OutOfMemory, failed);

    try std.testing.expectEqual(@as(usize, 0), system.completed.len);
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    try std.testing.expectEqual(goals.len, system.pending.len);
    for (goals) |goal| {
        try std.testing.expect(system.pending_keys.contains(system.graph.keyForWorld(0, goal, .default).?));
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }

    // With memory back, the next step publishes the same requests without new intake.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const retry = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), retry.accepted_requests);
    try std.testing.expectEqual(goals.len, retry.available_results);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expect(system.long_block_grows >= 1);
    for (goals) |goal| {
        try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }
}

test "a static mark record after its reserve allocates nothing (FailingAllocator)" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // A move, a create, and a destroy: four spans.
    const changes = [_]ColliderChange{
        .{ .entity = try EntityId.init(1, 1), .old = .{ .level = 0, .cells = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 } }, .new = .{ .level = 0, .cells = .{ .min_x = 4, .min_y = 0, .max_x = 5, .max_y = 1 } } },
        .{ .entity = try EntityId.init(2, 1), .old = null, .new = .{ .level = 1, .cells = .{ .min_x = 2, .min_y = 2, .max_x = 2, .max_y = 2 } } },
        .{ .entity = try EntityId.init(3, 1), .old = .{ .level = 2, .cells = .{ .min_x = 7, .min_y = 7, .max_x = 9, .max_y = 8 } }, .new = null },
    };
    try system.reserveStaticColliderMarks(changes.len);
    system.allocator = std.testing.failing_allocator;
    defer system.allocator = std.testing.allocator;
    system.recordStaticColliderChanges(&changes);
    try std.testing.expectEqual(@as(usize, 4), system.nav_marks.items.len);
    for (system.nav_marks.items) |mark| try std.testing.expectEqual(types.NavMarkKind.static_span, mark.kind);
    try std.testing.expectEqual(@as(u32, 4), system.nav_marks.items[1].min_x);
    try std.testing.expectEqual(@as(u16, 2), system.nav_marks.items[3].level);
}

test "a terrain nav record reserve counts each growth of the marks, staging, or tallies once, and a covered reserve none" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    // The capacity seam reserves the steady high-water uncounted; a record within it grows
    // nothing.
    try system.reserveTerrainNavRecord(system.capacity.max_frame_requests);
    try std.testing.expectEqual(@as(u64, 0), system.nav_mark_grows);
    try std.testing.expect(!system.nav_mark_growth_logged);

    // Room for the marks, so only the staging and tallies grow: one growth.
    const staging_bound = system.nav_mark_staging.capacity + 1;
    try system.nav_marks.ensureTotalCapacity(system.allocator, 2 * staging_bound);
    try system.reserveTerrainNavRecord(staging_bound);
    try std.testing.expectEqual(@as(u64, 1), system.nav_mark_grows);
    try std.testing.expect(system.nav_mark_growth_logged);

    // All three grow in one reserve: still one growth.
    const all_bound = @max(system.nav_marks.capacity, system.nav_mark_staging.capacity) + 1;
    try system.reserveTerrainNavRecord(all_bound);
    try std.testing.expectEqual(@as(u64, 2), system.nav_mark_grows);
    try std.testing.expect(system.nav_mark_staging.capacity >= all_bound);
    try std.testing.expect(system.nav_mark_tallies.capacity >= maxRangeCount(all_bound, nav_mark_range_alignment_items));
}

// The terrain record's reserve, then `nav_mark` over `events`, which may hold events nav
// ignores (so it bypasses `recordTerrainNavEvents`'s terrain-only check).
fn markEventsForTest(system: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) !u64 {
    try system.reserveTerrainNavRecord(events.len);
    return system.markNavEvents(events, world, thread_system);
}

// A dense multi-chunk edit's committed events: runs of tile flips that straddle range
// boundaries, obstacle rects, and events nav ignores (entity changes, which reach nav
// through the collider sync, and a non-commit-stage rect).
fn navMarkTestEvents(allocator: std.mem.Allocator, world: *const WorldSystem) !std.ArrayList(SimulationEvent) {
    var events: std.ArrayList(SimulationEvent) = .empty;
    errdefer events.deinit(allocator);
    for (0..world.height) |y| for (0..world.width) |x| {
        if ((x + y) % 3 == 0) continue;
        try events.append(allocator, .{ .stage = .structural_commit, .payload = .{ .world_tile_changed = .{
            .level = @intCast((x / 6) % 2),
            .x = @intCast(x),
            .y = @intCast(y),
            .old_tile_id = 0,
            .new_tile_id = 1,
            .old_blocks_movement = false,
            .new_blocks_movement = (x + y) % 5 != 0,
        } } });
        if (x == 5 and y % 4 == 0) {
            try events.append(allocator, .{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{ .level = 0, .min_x = 1, .min_y = @intCast(y), .max_x_exclusive = 9, .max_y_exclusive = @intCast(y + 2) } } });
            try events.append(allocator, .{ .stage = .structural_commit, .payload = .{ .component_changed = .{
                .entity = try EntityId.init(@intCast(y), 1),
                .component = .movement_body,
                .was_static_navigation_obstacle = true,
                .is_static_navigation_obstacle = true,
            } } });
            try events.append(allocator, .{ .stage = .domain_reaction, .payload = .{ .world_obstacle_changed = .{ .level = 1, .min_x = 0, .min_y = 0, .max_x_exclusive = 12, .max_y_exclusive = 12 } } });
        }
    };
    try events.append(allocator, .{ .stage = .structural_commit, .payload = .{ .component_changed = .{
        .entity = try EntityId.init(99, 1),
        .component = .collision_response,
        .was_static_navigation_obstacle = true,
        .is_static_navigation_obstacle = false,
        .level = 1,
    } } });
    return events;
}

test "threaded nav mark interpretation equals serial for a dense multi-chunk edit with runs straddling ranges and mixed tile and obstacle events" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(-16);
    var events = try navMarkTestEvents(std.testing.allocator, &world);
    defer events.deinit(std.testing.allocator);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(abstractCapacity());
    try serial.rebuildStaticNavGridWithWorld(&data, &world, null);
    _ = try markEventsForTest(&serial, events.items, &world, null);
    // The merge folds same-chunk tile runs, so there are fewer marks than events.
    try std.testing.expect(serial.nav_marks.items.len < events.items.len);
    for (serial.nav_marks.items) |mark| try std.testing.expectEqual(types.NavMarkKind.tile_box, mark.kind);

    for ([_]usize{ 8, 16, 24 }) |items_per_range| {
        var threaded = PathfindingSystem.init(std.testing.allocator);
        defer threaded.deinit();
        try threaded.reserve(abstractCapacity());
        try threaded.rebuildStaticNavGridWithWorld(&data, &world, null);
        threaded.nav_thread_adaptive = false;
        threaded.nav_thread_items_per_range = items_per_range;
        const off_main = try markEventsForTest(&threaded, events.items, &world, &threads);
        try std.testing.expect(off_main != 0);
        try std.testing.expectEqual(serial.nav_marks.items.len, threaded.nav_marks.items.len);
        for (serial.nav_marks.items, threaded.nav_marks.items) |a, b| try std.testing.expectEqual(a, b);
    }
}

test "a terrain nav record after its reserve allocates nothing on a multi-worker ThreadSystem and equals the inline record; an out-of-memory reserve records no mark (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(-16);
    var mixed = try navMarkTestEvents(std.testing.allocator, &world);
    defer mixed.deinit(std.testing.allocator);
    // A terrain writer appends only tile and obstacle events.
    var events: std.ArrayList(SimulationEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    for (mixed.items) |event| switch (event.payload) {
        .world_tile_changed, .world_obstacle_changed => try events.append(std.testing.allocator, event),
        else => {},
    };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var inline_system = PathfindingSystem.init(std.testing.allocator);
    defer inline_system.deinit();
    try inline_system.reserve(abstractCapacity());
    try inline_system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try test_support.recordTerrainEvents(&inline_system, events.items, &world);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 8;

    // A reserve past the steady capacity that runs out of memory records nothing.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, system.reserveTerrainNavRecord(events.items.len));
    try std.testing.expectEqual(@as(usize, 0), system.nav_marks.items.len);
    system.allocator = std.testing.allocator;

    // Reserve, then record across several worker ranges with every allocation failing.
    try system.reserveTerrainNavRecord(events.items.len);
    var steady = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = steady.allocator();
    system.recordTerrainNavEvents(events.items, &world, &threads);
    system.allocator = std.testing.allocator;
    try std.testing.expect(!steady.has_induced_failure);
    try std.testing.expect(system.last_mark_batch.range_count > 1 and !system.last_mark_batch.ran_inline);
    try std.testing.expectEqual(inline_system.nav_marks.items.len, system.nav_marks.items.len);
    for (inline_system.nav_marks.items, system.nav_marks.items) |a, b| try std.testing.expectEqual(a, b);
}

// The stitched cells of `goal`'s cached result on `goal_level`, or an empty slice.
fn cachedStitched(system: *const PathfindingSystem, goal_level: u16, goal: math.Vec2) []const types.StitchedCell {
    const key = system.graph.keyForWorld(goal_level, goal, .default) orelse return &.{};
    const slot = system.completed.freshSlotIndex(key, system.step_counter, types.default_cache_ttl_steps) orelse return &.{};
    return system.completed.stitchedSlice(slot, system.completed.resultAt(slot).stitched_len);
}

// Accepts one request per goal (requester `i` to `goals[i]`) without solving, then sets
// pending entry `i`'s tier to `tiers[i]` (1 = escalated).
fn queueWithTiers(system: *PathfindingSystem, requesters: []const EntityId, start: math.Vec2, goals: []const math.Vec2, tiers: []const u8) !void {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(goals.len, goals.len);
    for (requesters[0..goals.len], goals) |requester, goal| try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    _ = try system.updateSerial(&stream, 8, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(goals.len, system.pending.len);
    for (tiers, 0..) |tier, index| system.pending.ptr(index).tier = tier;
}

// Goals east of `buildCorridorWorld`'s wall, reached from `tileCenter(1, 1)` by abstract solves.
const escalation_goals = [_]math.Vec2{
    tileCenter(10, 0), tileCenter(10, 1), tileCenter(10, 2), tileCenter(10, 3),
    tileCenter(10, 4), tileCenter(10, 5), tileCenter(10, 6), tileCenter(10, 7),
};

test "the same path explores the same nodes at 64² and 256²" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    for ([_]usize{ 4096, 8 }) |budget| {
        var stats: [2]PathfindingStats = undefined;
        var explored: [2]usize = undefined;
        for ([_]f32{ 64 * 32, 256 * 32 }, &stats, &explored) |side, *step_stats, *step_explored| {
            var system = PathfindingSystem.init(std.testing.allocator);
            defer system.deinit();
            var capacity = baselineCapacity();
            capacity.max_explored_nodes = budget;
            capacity.group_field_max_cells = 16;
            try system.reserve(capacity);
            try system.rebuildStaticNavGrid(&data, side, side, 32);
            // Start and goal share the first 16-cell chunk: one local A* search.
            step_stats.* = try solveStep(&system, requester, tileCenter(1, 1), tileCenter(14, 13));
            step_explored.* = system.scratch_slots.items[0].explored;
            try std.testing.expectEqual(try types.hashTableSlots(budget), system.scratch_slots.items[0].slots.len);
        }
        try std.testing.expectEqual(stats[0].available_results, stats[1].available_results);
        try std.testing.expectEqual(stats[0].budget_exhausted, stats[1].budget_exhausted);
        try std.testing.expectEqual(explored[0], explored[1]);
        if (budget == 8) {
            try std.testing.expectEqual(@as(usize, 1), stats[0].budget_exhausted);
            try std.testing.expectEqual(@as(usize, 8), explored[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 1), stats[0].available_results);
        }
    }
}

test "tier-1 scratch is sized per escalated solve, not per participant" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.worker_participant_count = 3;
    capacity.max_escalated_solves_per_step = 2;
    capacity.group_field_max_cells = 16;
    try system.reserve(capacity);

    try std.testing.expectEqual(@as(usize, 3), system.scratch_slots.items.len);
    try std.testing.expectEqual(@as(usize, 2), system.tier1_scratch.items.len);
    const tier0_nodes = @min(capacity.tier0_abstract_node_cap, capacity.max_abstract_nodes);
    const tier0_cells = @min(capacity.tier0_stitched_cell_cap, capacity.max_stitched_path_cells);
    try std.testing.expect(tier0_nodes < capacity.max_abstract_nodes);
    for (system.scratch_slots.items) |*scratch| {
        try std.testing.expectEqual(tier0_nodes, scratch.corridor.abstract.node_limit);
        try std.testing.expectEqual(try types.hashTableSlots(tier0_nodes), scratch.corridor.abstract.slots.len);
        try std.testing.expectEqual(tier0_cells, scratch.corridor.stitched_limit);
    }
    for (system.tier1_scratch.items) |*entry| {
        try std.testing.expectEqual(capacity.max_abstract_nodes, entry.corridor.abstract.node_limit);
        try std.testing.expectEqual(try types.hashTableSlots(capacity.max_abstract_nodes), entry.corridor.abstract.slots.len);
        try std.testing.expectEqual(capacity.max_stitched_path_cells, entry.corridor.stitched_limit);
    }
}

test "an escalated solve through the tier-1 pool equals a participant reference" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const built = try buildCorridorWorld(&meta, &.{ 2, 9 });
    var world = built.world;
    defer world.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    // Pool: tier-0 caps too small for any corridor, so every request escalates once and
    // solves in tier-1 pool entry 0. Reference: tier-0 caps equal to the tier-1 caps, so the
    // same search runs in the participant scratch.
    var pool_capacity = abstractCapacity();
    pool_capacity.group_field_max_cells = 16;
    pool_capacity.tier0_abstract_node_cap = 2;
    pool_capacity.tier0_stitched_cell_cap = 4;
    var reference_capacity = pool_capacity;
    reference_capacity.tier0_abstract_node_cap = reference_capacity.max_abstract_nodes;
    reference_capacity.tier0_stitched_cell_cap = reference_capacity.max_stitched_path_cells;
    var pool = PathfindingSystem.init(std.testing.allocator);
    defer pool.deinit();
    try pool.reserve(pool_capacity);
    try pool.rebuildStaticNavGridWithWorld(&data, &world, null);
    var reference = PathfindingSystem.init(std.testing.allocator);
    defer reference.deinit();
    try reference.reserve(reference_capacity);
    try reference.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Two goals in turn reuse the same pool entry.
    for ([_]math.Vec2{ tileCenter(10, 11), tileCenter(9, 0) }) |goal| {
        const reference_stats = try solveStep(&reference, requester, tileCenter(1, 1), goal);
        try std.testing.expectEqual(@as(usize, 1), reference_stats.available_results);
        const first = try solveStep(&pool, requester, tileCenter(1, 1), goal);
        try std.testing.expectEqual(@as(usize, 1), first.budget_exhausted);
        try std.testing.expectEqual(@as(u8, 1), pool.pending.at(0).tier);
        var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer empty.deinit();
        const second = try pool.updateSerial(&empty, 8, .{});
        try std.testing.expectEqual(@as(usize, 1), second.escalated_solves);
        try std.testing.expectEqual(@as(usize, 1), second.available_results);
        const expected = cachedStitched(&reference, 0, goal);
        try std.testing.expect(expected.len > 1);
        try std.testing.expectEqualSlices(types.StitchedCell, expected, cachedStitched(&pool, 0, goal));
        try std.testing.expectEqual(reference.scratch_slots.items[0].corridor.abstract.nodes_used, pool.tier1_scratch.items[0].corridor.abstract.nodes_used);
    }
}

test "threaded escalated solves take distinct tier-1 slots and equal serial" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const built = try buildCorridorWorld(&meta, &.{ 2, 9 });
    var world = built.world;
    defer world.deinit();
    var requesters: [escalation_goals.len]EntityId = undefined;
    for (&requesters) |*requester| requester.* = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 16;
    capacity.max_escalated_solves_per_step = 4;
    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(capacity);
    try serial.rebuildStaticNavGridWithWorld(&data, &world, null);
    capacity.worker_participant_count = threads.participantSlotCount();
    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    try threaded.reserve(capacity);
    try threaded.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Escalated requests at odd ordinals: an ordinal-based pool index would pass the pool.
    const tiers = [_]u8{ 0, 1, 0, 1, 0, 1, 0, 1 };
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try queueWithTiers(&serial, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
    const serial_stats = try serial.updateSerial(&empty, 8, .{});
    try queueWithTiers(&threaded, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
    const stats = try threaded.update(&empty, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });

    try std.testing.expect(!stats.fallback_batch.ran_inline);
    try std.testing.expect(stats.fallback_batch.range_count > 1);
    try std.testing.expectEqual(@as(usize, 4), stats.escalated_solves);
    try std.testing.expectEqual(serial_stats.escalated_solves, stats.escalated_solves);
    try std.testing.expectEqual(serial_stats.available_results, stats.available_results);
    try std.testing.expectEqual(escalation_goals.len, stats.available_results);
    // Each escalated admission holds its own pool entry, in admission order.
    try std.testing.expectEqual(tiers.len, threaded.fallback_tier1_slot.items.len);
    var next_entry: u32 = 0;
    for (threaded.fallback_tier1_slot.items, tiers) |entry, tier| {
        if (tier == 0) {
            try std.testing.expectEqual(no_tier1_slot, entry);
        } else {
            try std.testing.expectEqual(next_entry, entry);
            next_entry += 1;
        }
    }
    for (escalation_goals) |goal| {
        const expected = cachedStitched(&serial, 0, goal);
        try std.testing.expect(expected.len > 1);
        try std.testing.expectEqualSlices(types.StitchedCell, expected, cachedStitched(&threaded, 0, goal));
    }
}

test "threaded cross-level solves equal serial" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    // Three open 16x16 levels in 4-tile chunks: ramps join consecutive levels, and a long
    // teleport joins level 0 to level 2.
    var world = try test_support.abstractTestWorld(&meta, 512, 512);
    defer world.deinit();
    for (1..3) |level| {
        _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
    }
    try world.addLevelLink(.{ .kind = .ramp, .level_a = 0, .cell_a = .{ .x = 2, .y = 2 }, .level_b = 1, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    try world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 13, .y = 2 }, .level_b = 2, .cell_b = .{ .x = 13, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 1, .y = 14 }, .level_b = 2, .cell_b = .{ .x = 14, .y = 14 }, .traversal_cost = 1, .bidirectional = true });
    var requesters: [8]EntityId = undefined;
    for (&requesters) |*requester| requester.* = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 16;
    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(capacity);
    try serial.rebuildStaticNavGridWithWorld(&data, &world, null);
    capacity.worker_participant_count = threads.participantSlotCount();
    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    try threaded.reserve(capacity);
    try threaded.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Level-2 goals on both sides of the level: some route by ramps, some by the teleport.
    const goals = [_]math.Vec2{
        tileCenter(14, 12), tileCenter(12, 15), tileCenter(15, 9), tileCenter(10, 13),
        tileCenter(13, 5),  tileCenter(8, 2),   tileCenter(15, 3), tileCenter(11, 6),
    };
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(goals.len, goals.len);
    for (requesters, goals) |requester, goal| {
        try appendPathRequest(&stream, .{ .entity = requester, .start_level = 0, .goal_level = 2, .start = tileCenter(1, 1), .goal = goal });
    }
    const serial_stats = try serial.updateSerial(&stream, 8, .{});
    const stats = try threaded.update(&stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });

    try std.testing.expect(!stats.fallback_batch.ran_inline);
    try std.testing.expect(stats.fallback_batch.range_count > 1);
    try std.testing.expectEqual(goals.len, serial_stats.available_results);
    try std.testing.expectEqual(goals.len, stats.available_results);
    var via_teleport: usize = 0;
    var via_ramps: usize = 0;
    for (goals) |goal| {
        const expected = cachedStitched(&serial, 2, goal);
        try std.testing.expect(expected.len > 1);
        try std.testing.expectEqualSlices(types.StitchedCell, expected, cachedStitched(&threaded, 2, goal));
        var jumps_two_levels = false;
        for (expected[0 .. expected.len - 1], expected[1..]) |from, to| jumps_two_levels = jumps_two_levels or (from.level == 0 and to.level == 2);
        if (jumps_two_levels) via_teleport += 1 else via_ramps += 1;
    }
    try std.testing.expect(via_teleport > 0 and via_ramps > 0);

    // The warmed threaded re-solve, heuristic and box scans included, allocates nothing.
    const original = threaded.allocator;
    threaded.allocator = std.testing.failing_allocator;
    threaded.graph.allocator = std.testing.failing_allocator;
    defer {
        threaded.allocator = original;
        threaded.graph.allocator = original;
    }
    threaded.clearRuntimeState();
    const warmed = try threaded.update(&stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!warmed.fallback_batch.ran_inline);
    try std.testing.expectEqual(goals.len, warmed.available_results);
    for (goals) |goal| try std.testing.expectEqualSlices(types.StitchedCell, cachedStitched(&serial, 2, goal), cachedStitched(&threaded, 2, goal));
}

test "a reserved threaded solve with escalations allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const built = try buildCorridorWorld(&meta, &.{ 2, 9 });
    var world = built.world;
    defer world.deinit();
    var requesters: [escalation_goals.len]EntityId = undefined;
    for (&requesters) |*requester| requester.* = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 16;
    capacity.max_escalated_solves_per_step = 4;
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    const tiers = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0 };
    const config = PathfindingConfig{ .adaptive = false, .items_per_range = 1 };
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try empty.reserve(1, 0);
    // No warm step: every stitched result fits its inline stripe, so nothing past the
    // capacity seam's reserve may allocate.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    try queueWithTiers(&system, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
    const stats = try system.update(&empty, 8, &threads, config);
    try std.testing.expect(!stats.fallback_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), stats.escalated_solves);
    try std.testing.expectEqual(escalation_goals.len, stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
}

test "a pool reserve out of memory clamps escalated admissions to the reserved pool (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const built = try buildCorridorWorld(&meta, &.{ 2, 9 });
    var world = built.world;
    defer world.deinit();
    var requesters: [3]EntityId = undefined;
    for (&requesters) |*requester| requester.* = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 16;
    capacity.max_escalated_solves_per_step = 1;
    var grown = capacity;
    grown.max_escalated_solves_per_step = 3;
    // Sweep the failure point across the pool's growth from one entry to three.
    var partial_pools: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        system.allocator = failing.allocator();
        const result = system.reserve(grown);
        system.allocator = std.testing.allocator;
        if (result) |_| {
            try std.testing.expectEqual(@as(usize, 3), system.tier1_scratch.items.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const pool_entries = system.tier1_scratch.items.len;
            try std.testing.expect(pool_entries < 3);
            try std.testing.expectEqual(pool_entries, system.capacity.max_escalated_solves_per_step);
            partial_pools += 1;
            // Three escalated requests: only as many as the pool holds run this step.
            try queueWithTiers(&system, &requesters, tileCenter(1, 1), escalation_goals[0..3], &.{ 1, 1, 1 });
            var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
            defer empty.deinit();
            const stats = try system.updateSerial(&empty, 8, .{});
            try std.testing.expectEqual(pool_entries, stats.escalated_solves);
            try std.testing.expectEqual(3 - pool_entries, stats.escalated_deferred);
            try std.testing.expectEqual(pool_entries, stats.available_results);
        }
    }
    try std.testing.expect(partial_pools > 1);
}

test "an elastic resize keeps a building group field building" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.group_field_build_budget = 1;
    capacity.group_field_max_cells = 1024;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goal = math.Vec2{ .x = 240, .y = 240 };
    try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    _ = try system.updateSerial(&stream, 8, .{});
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const field = system.findGroupField(key).?;
    try std.testing.expectEqual(GroupFieldState.building, field.state);
    const pushed = field.pushed_count;
    const generation = field.generation;
    const cost_column = field.columns.cost.ptr;

    try system.growForAgentCount(40);
    try std.testing.expectEqual(@as(usize, 40), system.effective_agent_capacity);
    const resized = system.findGroupField(key).?;
    try std.testing.expectEqual(GroupFieldState.building, resized.state);
    try std.testing.expectEqual(pushed, resized.pushed_count);
    try std.testing.expectEqual(generation, resized.generation);
    try std.testing.expectEqual(cost_column, resized.columns.cost.ptr);
    try std.testing.expectEqual(@as(u32, 0), resized.lookup(system.graph.grid(0).?, resized.goal_index).?.cost);
    try expectPoolsFitLogicalCaps(&system);
}
