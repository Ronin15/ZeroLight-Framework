// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! PathfindingSystem orchestrator: owns the transient request queues, goal-keyed
//! caches, per-level nav graph, group flow fields, per-worker scratch, and the
//! elastic capacity policy. Drives the fixed-step accept -> group-service -> solve ->
//! publish pipeline (serial and threaded), delegating the request intake to intake.zig,
//! solves to solve.zig, the publish and path registry to publish.zig, the group-field
//! service to group_service.zig, and the scoped eviction of a nav change to eviction.zig.

const std = @import("std");
const stamped_table = @import("../../stamped_table.zig");
const builtin = @import("builtin");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const logging = @import("../../../core/logging.zig");
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const Dispatch = @import("../../../app/thread_system.zig").Dispatch;
const StageControls = @import("../../../app/thread_system.zig").StageControls;
const StageShape = @import("../../../app/thread_system.zig").StageShape;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const inlineBatch = @import("../../../app/thread_system.zig").inlineBatch;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const stageShape = @import("../../../app/thread_system.zig").stageShape;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const ChunkGridError = @import("../../world/system.zig").ChunkGridError;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const PathRequest = @import("../../simulation.zig").PathRequest;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;
const NavInvalidationReason = @import("../../simulation.zig").NavInvalidationReason;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../../data_system.zig").EntityTemplate;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const ColliderChange = @import("../static_colliders.zig").ColliderChange;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavExtent = @import("nav_graph.zig").NavExtent;
const NavUpdateThreads = @import("nav_graph.zig").NavUpdateThreads;
const NavStageTuners = @import("nav_graph.zig").NavStageTuners;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ChunkListMap = @import("../chunk_list_map.zig").ChunkListMap;
const assertFieldsClassified = @import("../chunk_list_map.zig").assertFieldsClassified;
const GroupField = @import("group_field.zig").GroupField;
const group_field_cell_limit = @import("group_field.zig").group_field_cell_limit;
const SearchScratch = @import("scratch.zig").SearchScratch;
const Tier1Scratch = @import("scratch.zig").Tier1Scratch;
const CorridorScratch = @import("scratch.zig").CorridorScratch;
const ResultCache = @import("caches.zig").ResultCache;
const ResizeMove = @import("caches.zig").ResizeMove;
const KeySet = @import("caches.zig").KeySet;
const GroupKeyMap = @import("caches.zig").GroupKeyMap;
const waypointFromPath = @import("caches.zig").waypointFromPath;
const waypointFromStitched = @import("caches.zig").waypointFromStitched;
const solve = @import("solve.zig");
const publish = @import("publish.zig");
const group_service = @import("group_service.zig");
const intake = @import("intake.zig");
const eviction = @import("eviction.zig");
const EvictItemList = @import("eviction.zig").EvictItemList;
const HitList = @import("eviction.zig").HitList;
const IntakeRecordList = @import("intake.zig").IntakeRecordList;
const GroupKeyCountList = @import("intake.zig").GroupKeyCountList;
const IntakeTallyList = @import("intake.zig").IntakeTallyList;
const RegRecordList = @import("publish.zig").RegRecordList;
const PublishBandList = @import("publish.zig").PublishBandList;
const PublishBand = @import("publish.zig").PublishBand;
const FlushTally = @import("publish.zig").FlushTally;
const flush_pair_count = @import("publish.zig").flush_pair_count;
const solveOne = @import("solve.zig").solveOne;
const solveJob = @import("solve.zig").solveJob;
const SolveJobContext = @import("solve.zig").SolveJobContext;
const reach = @import("connectivity.zig").reach;
const Reach = @import("connectivity.zig").Reach;
const goal_table = @import("goal_table.zig");
const GoalTable = @import("goal_table.zig").GoalTable;
const goalRef = @import("goal_table.zig").goalRef;
const types = @import("types.zig");
const listBytesBound = @import("nav_graph.zig").listBytesBound;
const PathfindingCapacity = @import("types.zig").PathfindingCapacity;
const PathfindingConfig = @import("types.zig").PathfindingConfig;
// Threading for the request-side stages of one update: the thread system and the caller's
// control config. Absent in `updateSerial`, where every stage runs inline.
const StageThreads = @import("../../../app/thread_system.zig").StageThreads(PathfindingConfig);
const PathfindingStats = @import("types.zig").PathfindingStats;
const PathView = @import("types.zig").PathView;
const PathQueryKey = @import("types.zig").PathQueryKey;
const NavMark = @import("types.zig").NavMark;
const NavUpdateStats = @import("types.zig").NavUpdateStats;
const PendingRequest = @import("types.zig").PendingRequest;
const shouldShrinkCapacity = @import("types.zig").shouldShrinkCapacity;
const IntakeRecord = @import("types.zig").IntakeRecord;
const GroupKeyCount = @import("types.zig").GroupKeyCount;
const IntakeTally = @import("types.zig").IntakeTally;
const intake_range_alignment_items = @import("types.zig").intake_range_alignment_items;
const resizeList = @import("types.zig").resizeList;
const resizeUnwritten = @import("types.zig").resizeUnwritten;
const PathSolveResult = @import("types.zig").PathSolveResult;
const GroupRequestTally = @import("types.zig").GroupRequestTally;
const StageTimer = @import("../../../app/runtime_perf_log.zig").StageTimer;
const emptyKey = @import("types.zig").emptyKey;
const no_owner = @import("types.zig").no_owner;
const RegRecord = @import("types.zig").RegRecord;
const EvictItem = @import("types.zig").EvictItem;
const registry_shard_count = @import("types.zig").registry_shard_count;
const reg_window_alignment_items = @import("types.zig").reg_window_alignment_items;
const hit_window_alignment_items = @import("types.zig").hit_window_alignment_items;
const min_capacity_floor = @import("types.zig").min_capacity_floor;
const default_max_agent_budget = @import("types.zig").default_max_agent_budget;
const cached_results_per_agent = @import("types.zig").cached_results_per_agent;
const default_max_solves_per_frame = @import("types.zig").default_max_solves_per_frame;
const default_goal_projection_radius = @import("types.zig").default_goal_projection_radius;
const pathfinding_range_alignment_items = @import("types.zig").pathfinding_range_alignment_items;
const GridCell = @import("types.zig").GridCell;
const TraversalClass = @import("types.zig").TraversalClass;
const traversalOf = @import("types.zig").traversalOf;
const GoalResolveStats = @import("types.zig").GoalResolveStats;
const no_cell = @import("types.zig").no_cell;

// A nav build's failures: memory (an exhausted id pool included), or a budget or level grid
// past its index widths. A nav apply's: memory, an exhausted id pool included.
const NavBuildError = error{OutOfMemory} || types.BudgetError || ChunkGridError;
const NavApplyError = error{OutOfMemory};

// `solve_tier1_slot` entry of a tier-0 admission.
const no_tier1_slot: u32 = std.math.maxInt(u32);

const NavMarkList = std.array_list.Aligned(NavMark, .fromByteUnits(thread_shared_record_alignment));
const NavMarkTallyList = std.array_list.Aligned(NavMarkTally, .fromByteUnits(thread_shared_record_alignment));

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
    // The committed configuration every pool fits: the caller's, with the search budgets
    // lowered to what the pools hold after a failed resize.
    capacity: PathfindingCapacity = .{},
    // The pool sizes derived from the live agent capacity (`deriveLimits`).
    limits: Limits = .{},
    // Words of one solve-output stripe and result long block at the committed budgets.
    stripe_words: usize = 0,
    step_counter: u32 = 0,
    graph: NavGraph,
    // Deferred requests in FIFO order: index 0 is the oldest. Main thread mutates; solve
    // workers only read through `at`.
    pending: std.Deque(PendingRequest) = .empty,
    // `path_intake` staging: one record and one group-key slot per admitted request (each
    // range writes only its own window) and one padded tally per range. Reserved at the
    // capacity seam from the frame request limit.
    intake_records: IntakeRecordList = .empty,
    intake_group_counts: GroupKeyCountList = .empty,
    intake_tallies: IntakeTallyList = .empty,
    // Indexed by solve ordinal (the solve batch's item index).
    solve_results: std.ArrayList(PathSolveResult) = .empty,
    // Per solve ordinal, the pending index it solves, increasing.
    solve_indices: std.ArrayList(usize) = .empty,
    completed: ResultCache = .{},
    // The path registry: per cached result, the chunk runs of its stored path, keyed by
    // chunk and sharded by key, owned by the result's cache owner id. Written only by
    // `registry_flush`; empty of ops whenever no system call is on the stack.
    path_index: [registry_shard_count]ChunkListMap,
    // The step's goal table: one live projection per distinct blocked goal of the step's
    // navigation intents (`resolveGoals`), read by status, intake, group fields, and solve;
    // invalidated by every grid change.
    goals: GoalTable = .{},
    pending_keys: KeySet = .{},
    group_fields: std.ArrayList(GroupField) = .empty,
    // Goal key -> slot of the non-empty group field built for it; at most one field per key.
    group_field_keys: GroupKeyMap = .{},
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
    /// Per solve ordinal: its `tier1_scratch` entry, or `no_tier1_slot` for a tier-0
    /// request. Written by `prepareSolvePhase`.
    solve_tier1_slot: std.ArrayList(u32) = .empty,
    // Reconstructed paths by solve ordinal, written into completed by the main thread
    // after the worker batch finishes.
    solved_paths: std.ArrayList(SolvedPath) = .empty,
    // Per-request solve output: one `stripe_words` stripe at the request's solve ordinal
    // holding its plain or stitched path, so two requests never collide even when one
    // worker solves several in the same range.
    worker_path_pool: std.ArrayList(u32) = .empty,
    // Per solve ordinal, in its stripe's window: the first cell index of each registry
    // run of its path.
    worker_run_starts: std.ArrayList(u16) = .empty,
    // Per solve ordinal, where the publish claimed its result (null: none).
    publish_records: std.ArrayList(?ResultCache.Claimed) = .empty,
    // `publish_copy` output: per range, its registration window's base and per-shard
    // counts, and the windows, shard-ordered within each range.
    publish_range_bases: std.ArrayList(usize) = .empty,
    publish_bands: PublishBandList = .empty,
    reg_buckets: RegRecordList = .empty,
    // Ranges of the last publish copy whose registrations the next flush adds.
    publish_ranges: usize = 0,
    flush_tallies: [flush_pair_count]FlushTally = @splat(.{}),
    // Owner heads past the cache's capacity wait for the flush that applies its shrink.
    registry_truncate_pending: bool = false,
    // Path eviction scratch: one item per changed key and the hit windows, reserved before
    // the batch commit; the eviction stage's shape is chosen with the windows.
    evict_items: EvictItemList = .empty,
    evict_hits: HitList = .empty,
    evict_shape: StageShape = .{},
    // A shrink's resize copy, for the next update's stats.
    last_resize_copy_batch: BatchStats = .{},
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
    // Off-main, inline, and main-section time of the terrain records since the last reaction,
    // folded into its stats.
    pending_mark_off_main_ns: u64 = 0,
    pending_mark_inline_ns: u64 = 0,
    pending_mark_main_ns: u64 = 0,
    tuners: Tuners = .{},
    // Range controls of every nav-reaction stage. Production runs adaptive with no cap (the
    // tuners decide range sizing); benches and tests pin a FIXED partition or a worker cap.
    nav_controls: StageControls = .{},
    // Live agent count the per-step/memory caps are currently sized for. Elastic
    // resize keeps this tracking the steering-agent crowd: grows fast for battles,
    // shrinks slowly after sustained low load. Zero until the first reserve.
    effective_agent_capacity: usize = 0,
    // Consecutive steps the agent count has stayed below half the live capacity.
    // Shrink fires only after this reaches capacity_shrink_window (hysteresis).
    low_load_steps: u32 = 0,
    /// Telemetry, each logged once: growths of the mark buffer, the `nav_mark` staging, or its
    /// tallies; long-block pages the publish reserves allocated; registry shard storage
    /// growths; eviction scratch growths; group-field block pools reserved or grown (first
    /// builds and stalls), and growths that ran out of memory (the field stays stalled and
    /// retries next step); goal table growths at a resolve's entry (intents past the
    /// population seam's reserve).
    nav_mark_growth: GrowthCounter = .{},
    long_block_growth: GrowthCounter = .{},
    registry_growth: GrowthCounter = .{},
    evict_growth: GrowthCounter = .{},
    group_field_pool_growth: GrowthCounter = .{},
    group_field_pool_failure: GrowthCounter = .{},
    goal_table_growth: GrowthCounter = .{},
    // Reusable safe-point snapshot buffers. A resize preserves the live deferred work and
    // group tally by round-tripping them through these. Allocated only at resize.
    resize_pending_snapshot: std.ArrayList(PendingRequest) = .empty,
    resize_group_snapshot: std.ArrayList(GroupRequestTally) = .empty,
    // Per-step scratch for pending entries rotated to the back of the queue by
    // compactPendingAfterSolve (chronic budget spillers aged out of the front window).
    rotate_back_scratch: std.ArrayList(PendingRequest) = .empty,
    // Requests a resize dropped (pending/group past a re-reserve's lowered ceiling; an
    // elastic shrink keeps them all). Accumulated here because a resize runs before
    // acceptRequests overwrites the step stats; folded into stats.dropped_requests in
    // beginUpdate and then cleared.
    resize_dropped: usize = 0,
    /// Upper clamp for `groupFieldThreshold`: the configured agent ceiling, frozen at
    /// `reserve` (floored at `min_capacity_floor`), so a seam raise (`raiseAgentBudget`)
    /// never moves a per-query policy. Behavior follows configuration, not capacity history.
    group_field_threshold_ceiling: usize = default_max_agent_budget,

    // The sizes every pool is reserved to: intake staging, the pending queue, cached results,
    // and the solve slots. The step's gates are `StepGates`; while the pools cover them, the
    // only limit-based clamps (intake's release-build memory guard, a re-reserve's restore
    // past a lowered configured ceiling) never drop a request.
    const Limits = struct {
        frame_requests: usize = 0,
        pending_requests: usize = 0,
        cached_results: usize = 0,
        solves_per_step: usize = 0,
    };

    /// One step's admission gates (`stepGates`): requests intake takes (a contract bound, at
    /// most one per steering agent), requests pending at once, and distinct group tallies.
    pub const StepGates = struct {
        frame_requests: usize,
        pending_requests: usize,
        group_tallies: usize,
    };

    // Every stage's tuner: the solve batch, intake, the group-field advance and begin passes
    // and their stall re-dispatches (they see different item counts), each nav batch stage,
    // `nav_mark`, the goal scan and projection, the publish copy, the registry flush, a
    // shrink's resize copy, and the eviction's bound count, halo walk, and flush.
    const Tuners = struct {
        solve: AdaptiveWorkTuner = .init(.{}),
        intake: AdaptiveWorkTuner = .init(.{}),
        group_field: AdaptiveWorkTuner = .init(.{}),
        group_field_begin: AdaptiveWorkTuner = .init(.{}),
        group_field_stall: AdaptiveWorkTuner = .init(.{}),
        nav: NavStageTuners = .initFill(.init(.{})),
        nav_mark: AdaptiveWorkTuner = .init(.{}),
        goal_scan: AdaptiveWorkTuner = .init(.{}),
        goal_project: AdaptiveWorkTuner = .init(.{}),
        publish_copy: AdaptiveWorkTuner = .init(.{}),
        registry_flush: AdaptiveWorkTuner = .init(.{}),
        resize_copy: AdaptiveWorkTuner = .init(.{}),
        nav_evict_count: AdaptiveWorkTuner = .init(.{}),
        nav_evict: AdaptiveWorkTuner = .init(.{}),
        evict_flush: AdaptiveWorkTuner = .init(.{}),
    };

    // A counted growth or failure and whether its one log line was written.
    const GrowthCounter = struct {
        count: u64 = 0,
        logged: bool = false,

        /// Adds `amount` and logs the first record at `level` through the game logger.
        pub fn record(self: *GrowthCounter, amount: u64, comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
            self.count += amount;
            if (self.logged) return;
            self.logged = true;
            if (comptime logging.enabled(level) and !builtin.is_test) @field(logging.game, @tagName(level))(format, args);
        }
    };

    /// One solved request's output in its solve ordinal's stripe.
    pub const SolvedPath = struct {
        offset: usize,
        len: usize,
        // Stitched corridor cells in the same stripe; zero for a plain local solve, whose
        // cells are `len` words. A stitched result has `len` 0.
        stitched_len: usize = 0,
        // Level the stored cells index into (start level for cross-level corridors).
        path_level: u16 = 0,
        // The path's last cell (`PathResult.end`).
        end: types.StitchedCell = .{ .level = 0, .cell = 0 },
        // The live goal cell the solve targeted (`PathResult.goal_cell`).
        goal_cell: u32 = no_cell,
        // Set when the solve routed through the abstract chunk-portal/link graph.
        via_abstract: bool = false,
        // Set when the chosen corridor crosses at least one inter-level link.
        cross_level: bool = false,
        // Registry runs in the ordinal's run-start window, and their keys per shard.
        run_count: u32 = 0,
        shard_counts: [registry_shard_count]u32 = @splat(0),
    };

    pub fn init(allocator: std.mem.Allocator) PathfindingSystem {
        var path_index: [registry_shard_count]ChunkListMap = undefined;
        for (&path_index) |*shard| {
            shard.* = ChunkListMap.init(allocator, "path registry shard");
            // The system logs the registry's first growth once for every shard.
            shard.growth_logged = true;
        }
        return .{
            .allocator = allocator,
            .graph = .{ .allocator = allocator },
            .path_index = path_index,
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
        self.evict_hits.deinit(self.allocator);
        self.evict_items.deinit(self.allocator);
        self.reg_buckets.deinit(self.allocator);
        self.publish_bands.deinit(self.allocator);
        self.publish_range_bases.deinit(self.allocator);
        self.publish_records.deinit(self.allocator);
        self.worker_run_starts.deinit(self.allocator);
        self.worker_path_pool.deinit(self.allocator);
        self.solved_paths.deinit(self.allocator);
        self.scratch_slots.deinit(self.allocator);
        self.tier1_scratch.deinit(self.allocator);
        self.group_requests.deinit(self.allocator);
        self.group_key_map.deinit(self.allocator);
        self.group_field_slots.deinit(self.allocator);
        self.group_field_keys.deinit(self.allocator);
        self.group_fields.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.goals.deinit(self.allocator);
        for (&self.path_index) |*shard| shard.deinit();
        self.completed.deinit(self.allocator);
        self.solve_tier1_slot.deinit(self.allocator);
        self.solve_indices.deinit(self.allocator);
        self.solve_results.deinit(self.allocator);
        self.intake_tallies.deinit(self.allocator);
        self.intake_group_counts.deinit(self.allocator);
        self.intake_records.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.graph.deinit();
        self.* = undefined;
    }

    pub const groupFieldThreshold = group_service.groupFieldThreshold;

    /// Sizes every pool for `capacity`, keeping cached results that fit: at the floor agent
    /// count before the first reserve (the elastic resize grows it with the crowd), else at
    /// the live agent capacity (clamped to the new ceiling), so a re-reserve drops nothing
    /// the new ceiling admits. On a live system the deferred requests and group tallies
    /// round-trip with their key tables as an elastic resize does, so they never desync.
    /// Fails with `PathfindingBudgetTooWide` when a field's cell cap or a result block is
    /// past what its indices hold. Returns with the path registry flushed.
    pub fn reserve(self: *PathfindingSystem, capacity: PathfindingCapacity) (types.BudgetError || error{OutOfMemory})!void {
        // A field's bucket links pack its block ids, which stay below its cell cap.
        if (capacity.group_field_max_cells >= group_field_cell_limit) return error.PathfindingBudgetTooWide;
        // Registry run starts index a result block as u16.
        if (types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells) > types.max_result_block_words) return error.PathfindingBudgetTooWide;
        self.group_field_threshold_ceiling = @max(min_capacity_floor, capacity.max_agent_budget);
        // A shrink of live entries logs owner ops: flushed here, so no reader sees them.
        defer _ = publish.flushRegistry(self, null, null);
        if (self.effective_agent_capacity != 0) return self.resizePreservingLiveState(capacity, @max(min_capacity_floor, self.effective_agent_capacity), null);
        // Never reserved: nothing was admitted, so the queue, the tallies, and their key
        // tables hold nothing to keep.
        std.debug.assert(self.pending.len == 0 and self.group_requests.items.len == 0);
        self.pending_keys.clear();
        self.group_key_map.clear();
        try self.applyDerivedCapacity(capacity, min_capacity_floor, null);
    }

    // Sizes every pool from the limits derived for `agent_count`. Used by reserve() and by
    // the elastic resize at the safe point. ArrayList pools grow amortized and
    // shrink-and-free; the result cache keeps its entries (a shrink evicts what no longer
    // fits). The caller preserves the pending queue and group tally, which these pools do
    // not carry across.
    //
    // The committed config (`self.capacity`), the limits, and `effective_agent_capacity` are
    // set only after every pool fits them. On a mid-resize OOM each pool still holds its old
    // or its new storage (the resize helpers never free before the replacement exists), so
    // the limits and the search budgets fall back to the smaller of the two, which every
    // pool fits: an intake gate can never `appendAssumeCapacity` past a pool's real capacity,
    // and no solve writes past its path stripe.
    //
    // Search scratch and the tier-1 pool are sized by fixed budgets, never by level cells:
    // their reserves are no-ops at unchanged budgets (so an elastic resize never touches
    // them), each table is replaced only after its new storage exists, and an entry joins
    // its list only once reserved. Group fields get headers only; their pools follow the
    // chunks a build covers.
    //
    // The registry's owner heads grow before the cache, so every cache owner id has a head;
    // a shrink's copies run (on `threads` when given) and its tail pages are freed before
    // anything else can fail, and its heads past the new capacity go after the next flush.
    fn applyDerivedCapacity(self: *PathfindingSystem, capacity: PathfindingCapacity, agent_count: usize, threads: ?StageThreads) error{OutOfMemory}!void {
        const limits = deriveLimits(capacity, agent_count);
        errdefer {
            const previous_agents = self.effective_agent_capacity;
            // Never reserved: nothing is guaranteed to fit, so admit nothing.
            const fallback_limits: Limits = if (previous_agents == 0) .{} else deriveLimits(capacity, @min(agent_count, previous_agents));
            var fallback = capacity;
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
            self.limits = fallback_limits;
            self.stripe_words = types.resultBlockWords(fallback.max_explored_nodes, fallback.max_stitched_path_cells);
            self.effective_agent_capacity = fallback_limits.pending_requests;
        }
        const stripe_words = types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells);
        try reservePending(&self.pending, self.allocator, limits.pending_requests);
        try resizeList(&self.intake_records, self.allocator, limits.frame_requests);
        try resizeList(&self.intake_group_counts, self.allocator, limits.frame_requests);
        try resizeList(&self.intake_tallies, self.allocator, maxRangeCount(limits.frame_requests, intake_range_alignment_items));
        try resizeList(&self.solve_results, self.allocator, limits.solves_per_step);
        try resizeList(&self.solve_indices, self.allocator, limits.solves_per_step);
        try resizeList(&self.solve_tier1_slot, self.allocator, limits.solves_per_step);
        try resizeList(&self.solved_paths, self.allocator, limits.solves_per_step);
        // Per solve slot: where its publish claimed, and the publish copy's range records.
        try resizeList(&self.publish_records, self.allocator, limits.solves_per_step);
        const publish_ranges = maxRangeCount(limits.solves_per_step, 1);
        try resizeList(&self.publish_range_bases, self.allocator, publish_ranges);
        try resizeList(&self.publish_bands, self.allocator, publish_ranges);
        // Sized to the solve window: at most one front-window entry per solved slot can be
        // rotated to the back in a single compaction.
        try resizeList(&self.rotate_back_scratch, self.allocator, limits.solves_per_step);
        // Logical capacity only: every ProbeTable/ResultCache reserve internally doubles
        // physical slots for probe headroom, so callers pass the true entry-count ceiling,
        // never a caller-side multiplier (one load-factor policy, not two stacked).
        try publish.reserveRegistryOwners(self, limits.cached_results);
        const path_shrinking = limits.cached_results < self.completed.logicalCapacity();
        if (path_shrinking) try prepareTruncate(&self.path_index, limits.cached_results);
        errdefer if (path_shrinking and !self.registry_truncate_pending) abortTruncate(&self.path_index);
        const outcome = try self.completed.reserve(self.allocator, limits.cached_results, capacity.max_stored_path_cells, stripe_words, self.step_counter);
        if (outcome == .rebuilt) publish.clearRegistry(self);
        self.last_resize_copy_batch = self.runResizeCopy(if (threads) |stage| stage.stage(&self.tuners.resize_copy) else null);
        if (path_shrinking) self.registry_truncate_pending = true;
        try self.pending_keys.reserve(self.allocator, limits.pending_requests);
        // Field slots first: every header appended at the end already has its slot, so no
        // failure point leaves more fields than slots. Headers hold no pool (a field
        // reserves its pool at its first build) and are never removed by a shrink.
        try self.group_field_slots.ensureTotalCapacity(self.allocator, @max(capacity.max_group_fields, self.group_fields.items.len));
        try self.group_fields.ensureTotalCapacity(self.allocator, capacity.max_group_fields);
        try self.group_field_keys.reserve(self.allocator, @max(capacity.max_group_fields, self.group_fields.items.len));
        try resizeList(&self.group_requests, self.allocator, limits.solves_per_step);
        try self.group_key_map.reserve(self.allocator, limits.solves_per_step);
        // The steady-path mark high-water, with the `nav_mark` staging and tallies to record
        // as many events; the terrain record reserve grows them for a larger step.
        try self.nav_marks.ensureTotalCapacity(self.allocator, limits.frame_requests);
        try self.nav_mark_staging.ensureTotalCapacity(self.allocator, limits.frame_requests);
        try self.nav_mark_tallies.ensureTotalCapacity(self.allocator, maxRangeCount(limits.frame_requests, nav_mark_range_alignment_items));
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
        // One disjoint path stripe and run-start window per solved request this step
        // (indexed by the dense solve ordinal), so workers never overwrite each other's
        // reconstructed paths even when one worker solves several requests. Nothing reads
        // past a written length, so neither is filled.
        const pool_words = limits.solves_per_step * stripe_words;
        try resizeUnwritten(&self.worker_run_starts, self.allocator, pool_words);
        try resizeUnwritten(&self.worker_path_pool, self.allocator, pool_words);
        // Infallible, so a failed reserve never leaves more headers than its fallback.
        while (self.group_fields.items.len < capacity.max_group_fields) self.group_fields.appendAssumeCapacity(.{});
        self.capacity = capacity;
        self.limits = limits;
        self.stripe_words = stripe_words;
        self.effective_agent_capacity = limits.pending_requests;
    }

    // The limits every pool is sized to for `agent_count` agents, clamped to
    // [min_capacity_floor, the agent ceiling]. Population scales the queue and the cache (a
    // request and `cached_results_per_agent` results per agent); per-step solve work does
    // not: the solve ceiling is a fixed count (default_max_solves_per_frame), clamped down
    // to the population so a tiny crowd caps low.
    fn deriveLimits(base: PathfindingCapacity, agent_count: usize) Limits {
        const clamped = std.math.clamp(agent_count, min_capacity_floor, @max(min_capacity_floor, base.max_agent_budget));
        return .{
            .frame_requests = clamped,
            .pending_requests = clamped,
            .cached_results = clamped *| cached_results_per_agent,
            .solves_per_step = @min(default_max_solves_per_frame, clamped),
        };
    }

    // The step's gates from the live steering-agent count and fixed constants only, so two
    // systems with the same crowd and the same queued work admit the same requests whatever
    // their pools grew or shrank through. O(1).
    fn stepGates(agent_count: usize) StepGates {
        const crowd = @max(agent_count, min_capacity_floor);
        return .{
            .frame_requests = crowd,
            .pending_requests = crowd,
            .group_tallies = @min(default_max_solves_per_frame, crowd),
        };
    }

    /// The request side's storage by part: per-participant search scratch, the tier-1
    /// corridor pool, the result cache with the solve slots' path stripes and records, the
    /// path registry with its registration windows, the goal table, the request queues and
    /// per-step lists (pending queue and keys, intake staging, solve slots, group tallies and
    /// field headers, publish windows, resize snapshots), and the nav change scratch (marks
    /// and their staging, the eviction scratch). With the graph and the group fields' pools,
    /// every allocation the system owns.
    pub const RequestStorage = struct {
        search: usize = 0,
        tier1: usize = 0,
        results: usize = 0,
        registry: usize = 0,
        goals: usize = 0,
        queues: usize = 0,
        change_scratch: usize = 0,
    };

    /// What sizes the request side for `requestStorageBytesBound`, beyond its capacity.
    pub const RequestShape = struct {
        /// The most cached results whose path outgrows the inline stripe at once.
        long_results: usize = std.math.maxInt(usize),
        /// The most registry runs (chunk-local stretches of a stored path) one result holds;
        /// null is one per stored cell, the most a plain or stitched path holds.
        runs_per_result: ?usize = null,
        /// Chunks over every level: a registry key is a chunk, so keys never pass it.
        chunks: usize = std.math.maxInt(usize),
        /// The most nav marks recorded between two nav batches (a terrain record's events or
        /// two per static change), and the most chunk keys one batch changes.
        marks: usize = 0,
        batch_keys: usize = 0,
    };

    comptime {
        // Every field is a part of `RequestStorage`, the graph, the group fields' pools, or
        // owns no allocation.
        assertFieldsClassified(PathfindingSystem, &.{
            "graph",                 "pending",             "intake_records",   "intake_group_counts",
            "intake_tallies",        "solve_results",       "solve_indices",    "completed",
            "path_index",            "goals",               "pending_keys",     "group_fields",
            "group_field_keys",      "group_field_slots",   "group_requests",   "group_key_map",
            "scratch_slots",         "tier1_scratch",       "solve_tier1_slot", "solved_paths",
            "worker_path_pool",      "worker_run_starts",   "publish_records",  "publish_range_bases",
            "publish_bands",         "reg_buckets",         "evict_items",      "evict_hits",
            "nav_marks",             "nav_mark_staging",    "nav_mark_tallies", "resize_pending_snapshot",
            "resize_group_snapshot", "rotate_back_scratch",
        }, &.{
            "allocator",                "capacity",               "limits",                        "stripe_words",
            "step_counter",             "publish_ranges",         "flush_tallies",                 "registry_truncate_pending",
            "evict_shape",              "last_resize_copy_batch", "last_mark_batch",               "pending_mark_off_main_ns",
            "pending_mark_inline_ns",   "pending_mark_main_ns",   "tuners",                        "nav_controls",
            "effective_agent_capacity", "low_load_steps",         "nav_mark_growth",               "long_block_growth",
            "registry_growth",          "evict_growth",           "group_field_pool_growth",       "group_field_pool_failure",
            "goal_table_growth",        "resize_dropped",         "group_field_threshold_ceiling",
        });
    }

    /// `RequestStorage` held now (allocated capacity). O(participants + shards + the result
    /// cache's pages).
    pub fn requestResidentBytes(self: *const PathfindingSystem) RequestStorage {
        var storage = RequestStorage{
            .search = self.scratch_slots.capacity * @sizeOf(SearchScratch),
            .tier1 = self.tier1_scratch.capacity * @sizeOf(Tier1Scratch),
            .results = self.completed.residentBytes() + self.worker_path_pool.capacity * @sizeOf(u32) +
                self.worker_run_starts.capacity * @sizeOf(u16) + self.solved_paths.capacity * @sizeOf(SolvedPath) +
                self.publish_records.capacity * @sizeOf(?ResultCache.Claimed),
            .registry = self.reg_buckets.capacity * @sizeOf(RegRecord),
            .goals = self.goals.residentBytes(),
            .queues = self.pending.buffer.len * @sizeOf(PendingRequest) + self.pending_keys.residentBytes() +
                self.intake_records.capacity * @sizeOf(IntakeRecord) + self.intake_group_counts.capacity * @sizeOf(GroupKeyCount) +
                self.intake_tallies.capacity * @sizeOf(IntakeTally) + self.solve_results.capacity * @sizeOf(PathSolveResult) +
                self.solve_indices.capacity * @sizeOf(usize) + self.solve_tier1_slot.capacity * @sizeOf(u32) +
                self.group_fields.capacity * @sizeOf(GroupField) + self.group_field_keys.residentBytes() +
                self.group_field_slots.capacity * @sizeOf(usize) + self.group_requests.capacity * @sizeOf(GroupRequestTally) +
                self.group_key_map.residentBytes() + self.publish_range_bases.capacity * @sizeOf(usize) +
                self.publish_bands.capacity * @sizeOf(PublishBand) + self.rotate_back_scratch.capacity * @sizeOf(PendingRequest) +
                self.resize_pending_snapshot.capacity * @sizeOf(PendingRequest) + self.resize_group_snapshot.capacity * @sizeOf(GroupRequestTally),
            .change_scratch = self.nav_marks.capacity * @sizeOf(NavMark) + self.nav_mark_staging.capacity * @sizeOf(NavMark) +
                self.nav_mark_tallies.capacity * @sizeOf(NavMarkTally) + self.evict_items.capacity * @sizeOf(EvictItem) +
                self.evict_hits.capacity * @sizeOf(u32),
        };
        for (self.scratch_slots.items) |*scratch| storage.search += scratch.residentBytes();
        for (self.tier1_scratch.items) |*entry| storage.tier1 += entry.corridor.residentBytes();
        for (&self.path_index) |*shard| storage.registry += shard.residentBytes();
        return storage;
    }

    /// An over-estimate of `requestResidentBytes` for a system never reserved past
    /// `capacity` (its pools at the limits of `max_agent_budget` agents), whose results and
    /// nav changes fit `shape`, and whose goal table grew from one intent per agent. Search
    /// scratch and the tier-1 pool follow the node budgets, never level cells. The registry
    /// is charged its shards' summed peaks at their pooled share: one key hash spreads any
    /// workload's runs over the shards alike, so the shards peak together. Saturates.
    pub fn requestStorageBytesBound(capacity: PathfindingCapacity, shape: RequestShape) RequestStorage {
        const limits = deriveLimits(capacity, capacity.max_agent_budget);
        const participants = @max(@as(usize, 1), capacity.worker_participant_count);
        const tier0_abstract_nodes = @min(capacity.tier0_abstract_node_cap, capacity.max_abstract_nodes);
        const tier0_stitched_cells = @min(capacity.tier0_stitched_cell_cap, capacity.max_stitched_path_cells);
        const stripe_words = types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells);
        const solves = limits.solves_per_step;
        const frames = limits.frame_requests;
        const pool_words = solves *| stripe_words;
        // A stored path holds at most one run per cell, plain or stitched.
        const runs_per_result = shape.runs_per_result orelse @max(capacity.max_stored_path_cells, capacity.max_stitched_path_cells);
        // A step registers at most its solves' runs, on top of the live results' runs; a
        // shard reserves table room for each, its live keys aside.
        const step_runs = solves *| runs_per_result;
        const live_runs = limits.cached_results *| runs_per_result +| step_runs;
        const windows = step_runs +| (reg_window_alignment_items - 1) *| maxRangeCount(solves, 1);
        const marks = @max(frames, shape.marks);
        // Per changed key, its halos' registrations (each halo owned by one key) and a slot per
        // group field, each range's window on a line.
        const hits = live_runs +| shape.batch_keys *| (capacity.max_group_fields +| hit_window_alignment_items);
        return .{
            .search = listBytesBound(SearchScratch, participants) +|
                participants *| SearchScratch.storageBytesBound(capacity.max_explored_nodes, tier0_abstract_nodes, tier0_stitched_cells),
            .tier1 = listBytesBound(Tier1Scratch, capacity.max_escalated_solves_per_step) +|
                capacity.max_escalated_solves_per_step *| CorridorScratch.storageBytesBound(capacity.max_abstract_nodes, capacity.max_stitched_path_cells),
            .results = ResultCache.storageBytesBound(limits.cached_results, capacity.max_stored_path_cells, stripe_words, shape.long_results) +|
                listBytesBound(u32, pool_words) +| listBytesBound(u16, pool_words) +| listBytesBound(SolvedPath, solves) +|
                listBytesBound(?ResultCache.Claimed, solves),
            .registry = ChunkListMap.pooledStorageBytesBound(registry_shard_count, @min(live_runs, shape.chunks +| step_runs), live_runs, limits.cached_results) +|
                RegRecordList.growCapacity(windows) *| @sizeOf(RegRecord),
            // A resolve past the limit doubles it, so one intent per agent reserves at most twice that.
            .goals = GoalTable.storageBytesBound(2 *| limits.pending_requests),
            .queues = limits.pending_requests *| @sizeOf(PendingRequest) +| KeySet.storageBytesBound(limits.pending_requests) +|
                IntakeRecordList.growCapacity(frames) *| @sizeOf(IntakeRecord) +| GroupKeyCountList.growCapacity(frames) *| @sizeOf(GroupKeyCount) +|
                IntakeTallyList.growCapacity(maxRangeCount(frames, intake_range_alignment_items)) *| @sizeOf(IntakeTally) +|
                listBytesBound(PathSolveResult, solves) +| listBytesBound(usize, solves) +| listBytesBound(u32, solves) +|
                listBytesBound(GroupField, capacity.max_group_fields) +| GroupKeyMap.storageBytesBound(capacity.max_group_fields) +|
                listBytesBound(usize, capacity.max_group_fields) +| listBytesBound(GroupRequestTally, solves) +|
                GroupKeyMap.storageBytesBound(solves) +| listBytesBound(usize, maxRangeCount(solves, 1)) +|
                PublishBandList.growCapacity(maxRangeCount(solves, 1)) *| @sizeOf(PublishBand) +| listBytesBound(PendingRequest, solves) +|
                listBytesBound(PendingRequest, limits.pending_requests) +| listBytesBound(GroupRequestTally, solves),
            .change_scratch = listBytesBound(NavMark, marks) +| NavMarkList.growCapacity(marks) *| @sizeOf(NavMark) +|
                NavMarkTallyList.growCapacity(maxRangeCount(marks, nav_mark_range_alignment_items)) *| @sizeOf(NavMarkTally) +|
                EvictItemList.growCapacity(shape.batch_keys) *| @sizeOf(EvictItem) +| HitList.growCapacity(hits) *| @sizeOf(u32),
        };
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
        return deriveLimits(self.capacity, agent_count).pending_requests <= self.effective_agent_capacity;
    }

    // The ceiling an update raises to for a crowd past it: 1.5x the crowd, the population
    // seam's growth factor (the seam also rounds up to its stores' alignment).
    fn grownAgentBudget(agent_count: usize) usize {
        return agent_count +| agent_count / 2;
    }

    /// Raises `max_agent_budget` to `requested` (never lowers it). Population is
    /// runtime-growing, so the raise is never refused. Main thread: pipeline init, the
    /// population seam, and an update whose crowd is past the ceiling. Never writes
    /// `group_field_threshold_ceiling`: a raise lifts capacity, not policy.
    pub fn raiseAgentBudget(self: *PathfindingSystem, requested: usize) void {
        self.capacity.max_agent_budget = @max(self.capacity.max_agent_budget, requested);
    }

    /// Grow half of the elastic resize: when `agent_count` derives more than the live
    /// capacity, grows (at least 2x, clamped to `agentBudget()`) preserving live state.
    /// Called from pipeline init (the committed steering agents), the population seam, and
    /// `beginUpdate`'s safety net (which first raises the ceiling past the crowd).
    pub fn growForAgentCount(self: *PathfindingSystem, agent_count: usize) error{OutOfMemory}!void {
        if (self.effective_agent_capacity == 0) return; // not reserved yet
        const target = deriveLimits(self.capacity, agent_count).pending_requests;
        const current = self.effective_agent_capacity;
        if (target <= current) return;
        self.low_load_steps = 0;
        // Amortized grow: at least double, clamped to the ceiling, so one realloc
        // covers many future spawns.
        const grown = @min(@max(target, current *| 2), self.agentBudget());
        try self.resizePreservingLiveState(self.capacity, grown, null);
        // A grow moves and evicts nothing, so it leaves no owner op for a flush.
        std.debug.assert(self.completed.core.ownerLog().len == 0);
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
    // solve_indices, solved_paths, worker_path_pool) are empty/cleared from last
    // step's prepare*, so no live offset spans the resize.
    // pending/pending_keys/group_requests/completed hold cross-step state;
    // completed keeps its entries through the resize, while pending and
    // the group tally round-trip through reusable snapshots and pending_keys is rebuilt
    // from the restored pending. Search scratch, the tier-1 pool, and group fields follow
    // fixed budgets an elastic resize does not change, so their reserves are no-ops here.
    // On success the pools cover `stepGates(agent_count)`. No worker runs. Returns whether a
    // resize ran.
    fn adjustCapacityForAgentCount(self: *PathfindingSystem, agent_count: usize, threads: ?StageThreads) error{OutOfMemory}!bool {
        if (self.effective_agent_capacity == 0) return false; // not reserved yet
        const current = self.effective_agent_capacity;
        if (!self.coversAgentCount(agent_count)) {
            // A crowd past the ceiling (a direct caller, or a seam raise that failed) raises
            // it geometrically past the crowd, so a ramp resizes O(log n) times; a failed
            // grow restores it.
            const previous_budget = self.capacity.max_agent_budget;
            errdefer self.capacity.max_agent_budget = previous_budget;
            if (agent_count > self.agentBudget()) self.raiseAgentBudget(grownAgentBudget(agent_count));
            try self.growForAgentCount(agent_count);
            return true;
        }
        // Shrink only after the agent count stays below half capacity for the window, and
        // never below the live queue and tallies, so a shrink drops no accepted work.
        if (agent_count * 2 < current) {
            self.low_load_steps +|= 1;
            if (self.low_load_steps >= self.capacity.capacity_shrink_window) {
                self.low_load_steps = 0;
                const keep = @max(agent_count, self.pending.len, self.group_requests.items.len);
                if (deriveLimits(self.capacity, keep).pending_requests >= current) return false;
                try self.resizePreservingLiveState(self.capacity, keep, threads);
                return true;
            }
        } else {
            self.low_load_steps = 0;
        }
        return false;
    }

    // Re-sizes all pools for `capacity` at `agent_count` while preserving the live
    // deferred-work queue and group tally. The goal-keyed result cache keeps its entries (a
    // shrink evicts only what no longer fits), so a resize costs no re-solves.
    fn resizePreservingLiveState(self: *PathfindingSystem, capacity: PathfindingCapacity, agent_count: usize, threads: ?StageThreads) error{OutOfMemory}!void {
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
        try self.applyDerivedCapacity(capacity, agent_count, threads);
        self.restoreLiveStateAfterResize();
    }

    fn restoreLiveStateAfterResize(self: *PathfindingSystem) void {
        // Restore live deferred work (dropping any beyond the new, smaller capacity),
        // rebuild pending_keys to match, and restore the surviving group tally. Clamped to
        // the logical limits applyDerivedCapacity just installed, not the lists' physical
        // .capacity: pending_keys/group_key_map were reserved to the exact logical limit, so
        // keeping more entries than it would drop their dedup registration (a live entry
        // that reads back `.missing` instead of `.pending`, inviting a duplicate accept)
        // while resize_dropped undercounts the real loss.
        clearPending(&self.pending);
        const keep_pending = @min(self.resize_pending_snapshot.items.len, self.limits.pending_requests);
        self.pending_keys.clear();
        for (self.resize_pending_snapshot.items[0..keep_pending]) |pending_request| {
            self.pending.pushBackAssumeCapacity(pending_request);
            _ = self.pending_keys.insert(pending_request.key);
        }
        self.group_requests.clearRetainingCapacity();
        const keep_group = @min(self.resize_group_snapshot.items.len, self.limits.solves_per_step);
        self.group_requests.appendSliceAssumeCapacity(self.resize_group_snapshot.items[0..keep_group]);
        // Rebuild the group key map to match the restored group_requests entries.
        self.group_key_map.clear();
        for (self.group_requests.items, 0..) |tally, idx| _ = self.group_key_map.insert(tally.key, idx);
        // A resize that drops live deferred work / group tally past the smaller capacity is
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
    pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) NavBuildError!void {
        try self.rebuildNavFromData(data, self.boundsNavExtent(bounds_width, bounds_height, cell_size), null);
    }

    /// Builds nav over every level of `world` with the statics `data` holds now, through a
    /// static-collider build discarded afterwards: nav cells are the world's tiles and nav
    /// chunks its chunks. Fails loudly (`ChunkGridError`) when the nav grid's index widths
    /// do not fit, before sizing anything from them.
    pub fn rebuildStaticNavGridWithWorld(self: *PathfindingSystem, data: *const DataSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) NavBuildError!void {
        try self.rebuildNavFromData(data, .{ .world = world }, thread_system);
    }

    fn rebuildNavFromData(self: *PathfindingSystem, data: *const DataSystem, extent: NavExtent, thread_system: ?*ThreadSystem) NavBuildError!void {
        var colliders = StaticColliderSystem.init(self.allocator);
        defer colliders.deinit();
        try colliders.rebuild(data, try extent.colliderGeometry());
        try self.rebuildNavFromColliders(&colliders, extent, thread_system);
    }

    /// Builds nav over `extent` with `colliders`' rows, which must be placed on the
    /// extent's cell grid (`NavExtent.colliderGeometry`). Every later apply passes the same
    /// colliders, synced at the commit seam.
    pub fn rebuildNavFromColliders(self: *PathfindingSystem, colliders: *const StaticColliderSystem, extent: NavExtent, thread_system: ?*ThreadSystem) NavBuildError!void {
        if (self.scratch_slots.items.len == 0) {
            try self.reserve(self.capacity);
        }
        self.goals.invalidate();
        _ = try self.graph.rebuild(colliders.view(), extent, self.navUpdateThreads(thread_system));
        // Search scratch and group fields follow budgets reserved at the capacity seam, never
        // the level's cell count, so the build sizes nothing for them.
        // Grid versions are part of query keys. A rebuild invalidates pending
        // work and caches instead of trying to remap old requests onto new cells.
        self.clearRuntimeState();
        self.nav_marks.clearRetainingCapacity();
        // A rebuild can change cell/chunk counts and thus the per-item work cost, so the
        // adaptive tuners' learned profiles no longer apply: they relearn against the new
        // topology.
        self.tuners = .{};
    }

    fn navUpdateThreads(self: *PathfindingSystem, thread_system: ?*ThreadSystem) ?NavUpdateThreads {
        const threads = thread_system orelse return null;
        return .{
            .thread_system = threads,
            .tuners = &self.tuners.nav,
            .controls = self.nav_controls,
        };
    }

    /// The commit seam's static mark reserve, before the structural commit: room for the
    /// old and new span of `change_bound` collider changes (the colliders' pending changes
    /// plus one per command). No mark may be recorded between it and
    /// `recordStaticColliderChanges`. On error nothing changes.
    pub fn reserveStaticColliderMarks(self: *PathfindingSystem, change_bound: usize) error{OutOfMemory}!void {
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
    pub fn reserveTerrainNavRecord(self: *PathfindingSystem, event_bound: usize) error{OutOfMemory}!void {
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
                }, self.graph.geometry.chunk_tiles);
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
        self.nav_mark_growth.record(1, .info, "nav mark storage grew to {d} marks and {d} staged events", .{ self.nav_marks.capacity, self.nav_mark_staging.capacity });
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
    /// the world added, rebuilds the levels whose content revision moved (evicting the
    /// results with a path run on each and its group fields), then applies the recorded marks
    /// and new links as one batch, evicting only the results and group fields it reaches;
    /// pending requests and group tallies survive both, since a solve re-checks its live goal
    /// and reach. Invalidates the step's goal table. A committed step stays on a later error;
    /// marks and the level, revision, and link gaps stay pending for the next call. The
    /// world-wide revision is compared once; levels are walked only when it moved. A
    /// non-null `thread_system` lets each stage thread under its tuner. Counts one step of
    /// the batch staging's release windows (`NavGraph.tickStagingStep`).
    pub fn applyBufferedNavUpdates(self: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) NavApplyError!NavUpdateStats {
        var stats = NavUpdateStats{};
        self.goals.invalidate();
        // The step's tick of the batch staging's release windows, before any batch; the
        // release, if the window closes, after every batch and level build of the step.
        self.graph.tickStagingStep(self.capacity.capacity_shrink_window);
        defer self.graph.finishStagingStep();
        const threads = self.navUpdateThreads(thread_system);
        // A level build's relocated closure blocks land even when a later build or the marks
        // batch fails, before the step's staging release.
        errdefer self.graph.landClosure(threads, &stats);
        const view = colliders.view();
        if (self.graph.world_backed) {
            // Every level build of the step shares one level-sized staging, freed once at the
            // step's end (`finishStagingStep`), after the marks batch.
            while (self.graph.levelCount() < world.levelCount()) {
                try self.graph.buildLevel(view, world, @intCast(self.graph.levelCount()), threads, &stats);
            }
            if (world.contentRevision() != self.graph.built_world_revision) {
                var rebuilt = false;
                // A failed level build still flushes the levels evicted before it, so no call
                // returns with owner ops logged.
                errdefer if (rebuilt) {
                    _ = eviction.flushRebuildEvictions(self, thread_system);
                };
                for (0..self.graph.levelCount()) |level_index| {
                    const level: u16 = @intCast(level_index);
                    if (self.graph.level_graphs.items[level].built_revision == world.levelContentRevision(level)) continue;
                    try self.graph.buildLevel(view, world, level, threads, &stats);
                    rebuilt = true;
                    // The level changed without per-cell changes: no result through it and none
                    // of its fields is known good.
                    const evict_timer = StageTimer.begin();
                    eviction.evictLevel(self, level, &stats);
                    stats.main.evict_ns += evict_timer.lap();
                }
                self.graph.built_world_revision = world.contentRevision();
                // One flush unlinks every rebuilt level's evictions, so the marks batch's
                // eviction starts flushed.
                if (rebuilt) stats.addStageTime(eviction.flushRebuildEvictions(self, thread_system));
            }
        }
        if (try self.graph.prepareMarks(world, view, self.nav_marks.items, threads, &stats)) |prepared| {
            {
                // Every eviction allocation precedes the commit; on error the batch and its
                // marks stay pending.
                errdefer self.graph.abortMarks(prepared);
                try eviction.prepareEviction(self, thread_system, &stats);
            }
            const batch = self.graph.commitMarks(prepared, view, threads, &stats);
            if (batch.changed) {
                // Graph node ids never persist, so cached results stay keyed by cells: evict
                // only those with a cell within one cell of a changed cell, and the fields
                // with a costed cell next to a changed cell.
                eviction.evictScoped(self, batch, thread_system, &stats);
            }
        }
        // The step's relocated closure blocks leave the batch tail, whatever built them.
        self.graph.landClosure(threads, &stats);
        self.nav_marks.clearRetainingCapacity();
        return stats;
    }

    /// The post-commit nav reaction: applies every pending nav change (the marks terrain
    /// writers and the collider sync recorded, and the world's level, link, and revision
    /// gaps) and emits one `nav_region_invalidated` when the graph changed. Runs after
    /// `colliders` synced this step's commit. A failed apply keeps the marks and gaps for the
    /// next step.
    pub fn reactToPostCommitNavEvents(self: *PathfindingSystem, frame: *SimulationFrame, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) (NavApplyError || error{EventCapacityExceeded})!NavUpdateStats {
        const mark_off_main_ns = self.pending_mark_off_main_ns;
        const mark_inline_ns = self.pending_mark_inline_ns;
        const mark_main_ns = self.pending_mark_main_ns;
        self.pending_mark_off_main_ns = 0;
        self.pending_mark_inline_ns = 0;
        self.pending_mark_main_ns = 0;
        if (!self.hasPendingNavUpdates(world)) {
            // A quiet step still counts toward the batch staging's release windows.
            self.graph.tickStagingStep(self.capacity.capacity_shrink_window);
            self.graph.finishStagingStep();
            return .{ .off_main_stage_ns = mark_off_main_ns, .inline_stage_ns = mark_inline_ns, .main = .{ .mark_ns = mark_main_ns } };
        }
        try frame.events.ensureCanAppend(1);
        var stats = try self.applyBufferedNavUpdates(colliders, world, thread_system);
        stats.off_main_stage_ns += mark_off_main_ns;
        stats.inline_stage_ns += mark_inline_ns;
        stats.main.mark_ns += mark_main_ns;
        if (stats.incremental_rebuilds == 0 and stats.levels_built == 0) return stats;
        try frame.events.appendRequired(.{
            .stage = .domain_reaction,
            .payload = .{ .nav_region_invalidated = .{ .reason = NavInvalidationReason.static_obstacle_changed } },
        });
        return stats;
    }

    // `nav_mark`: interprets world events into marks; `reserveTerrainNavRecord` reserved one
    // mark, one staging slot per event, and the tallies. Each range (one inline range without
    // a thread system or when the tuner keeps the stage inline) writes its events' marks into
    // its staging window, merging consecutive tile boxes of one (level, chunk), and the main
    // thread appends the windows in range order with the same merge, so the marks are equal
    // for any partition. Main work is O(marks after the merge). Returns the stage's off-main
    // time.
    fn markNavEvents(self: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) u64 {
        self.last_mark_batch = .{};
        if (events.len == 0) return 0;
        std.debug.assert(self.nav_marks.capacity - self.nav_marks.items.len >= events.len);
        var section = StageTimer.begin();
        const dispatch = navDispatch(self, thread_system, &self.tuners.nav_mark);
        const shape = stageShape(dispatch, events.len, nav_mark_range_alignment_items);
        std.debug.assert(self.nav_mark_staging.capacity >= events.len);
        std.debug.assert(self.nav_mark_tallies.capacity >= shape.range_count);
        self.nav_mark_staging.items.len = events.len;
        self.nav_mark_tallies.items.len = shape.range_count;
        @memset(self.nav_mark_tallies.items, .{});
        var job = NavMarkJob{
            .chunk_tiles = self.graph.geometry.chunk_tiles,
            .world = world,
            .events = events,
            .items_per_range = shape.items_per_range,
            .staging = self.nav_mark_staging.items,
            .tallies = self.nav_mark_tallies.items,
        };
        self.pending_mark_main_ns += section.lap();
        const batch = runShaped(dispatch, shape, events.len, nav_mark_range_alignment_items, &job, navMarkJob);
        section = StageTimer.begin();
        self.last_mark_batch = batch;
        for (self.nav_mark_tallies.items, 0..) |tally, range_index| {
            const window_start = range_index * shape.items_per_range;
            for (self.nav_mark_staging.items[window_start .. window_start + tally.count]) |mark| self.appendEventMark(mark);
        }
        self.pending_mark_main_ns += section.lap();
        if (batch.ran_inline) {
            self.pending_mark_inline_ns += batch.batch_duration_ns;
            return 0;
        }
        return batch.batch_duration_ns;
    }

    // Appends one event's mark into reserved capacity, merging a tile box into the previous
    // mark when both lie in one chunk.
    fn appendEventMark(self: *PathfindingSystem, mark: NavMark) void {
        appendMergedMark(&self.nav_marks, mark, self.graph.geometry.chunk_tiles);
    }

    /// Whether the post-commit nav reaction may run and emit its event this step: a pending
    /// structural command may change nav, or nav has recorded marks, levels, links, or a
    /// content revision still to apply. Callers reserve its event slot first.
    pub fn navReactionMayEmit(self: *const PathfindingSystem, data: *const DataSystem, frame: *const SimulationFrame, world: *const WorldSystem) bool {
        return structuralCommandsMayInvalidateNavigation(data, frame) or self.hasPendingNavUpdates(world);
    }

    // Whether a committed world event changes nav cells. Static colliders reach nav through
    // the collider sync's change list, not events.
    fn eventInvalidatesNavigation(event: SimulationEvent) bool {
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

    fn structuralCommandMayInvalidateNavigation(data: *const DataSystem, command: StructuralCommand) bool {
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

    fn templateCreatesStaticNavigationObstacle(template: EntityTemplate) bool {
        const response = template.collision_response orelse return false;
        return response.mobility == .static and
            template.movement_body != null and
            template.collision_bounds != null;
    }

    // Empties every request, result, and group field: a rebuilt graph's version and cells
    // match none of them.
    /// Empties the request side, keeping the graph, every reserved pool, and the tuners: the
    /// pending queue and its keys, the solve and publish slots, the group tallies, the result
    /// cache with its registry, and every group field. O(reserved capacity). Main thread,
    /// outside an update.
    pub fn clearRuntimeState(self: *PathfindingSystem) void {
        clearPending(&self.pending);
        self.pending_keys.clear();
        self.solve_results.clearRetainingCapacity();
        self.solve_indices.clearRetainingCapacity();
        self.solve_tier1_slot.clearRetainingCapacity();
        self.solved_paths.clearRetainingCapacity();
        self.group_requests.clearRetainingCapacity();
        self.group_key_map.clear();
        publish.clearCompleted(self);
        for (self.group_fields.items) |*field| field.state = .empty;
        self.group_field_keys.clear();
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

    // Group field first (when ready), then the live goal and, for an open start, reach,
    // then the individual cache (served only while it was solved toward the live goal; a
    // partial reads `.partial`), then pending. Missing means the caller may enqueue a
    // request. The start cell is interpreted on `start_level`; cached corridors derive
    // against the level their stored cells index into (start level for cross-level
    // corridors).
    fn statusForKeyAndStart(self: *const PathfindingSystem, key: PathQueryKey, start_level: u16, start_index: usize, waypoint_hint: ?*u32) PathView {
        if (group_service.groupFieldOf(self, key)) |field| {
            if (field.state == .ready and start_level == key.goal_level) {
                // The group field is built on the goal level; sample at the agent's cell.
                if (self.graph.grid(key.goal_level)) |goal_grid| {
                    if (field.sample(goal_grid, start_index)) |waypoint| {
                        return .{ .status = .available, .next_waypoint = waypoint, .path_len = 2 };
                    }
                }
                // Sample miss (or no grid): the field simply does not cover this cell (e.g. a
                // same-level but different-component agent) — not an unavailable goal. Fall
                // through to the individual answer below, mirroring the cross-level agent's
                // exemption: an individual abstract-corridor solve may still reach the goal
                // via a link this level-local field never routes through.
            }
        }
        const goal_grid = self.graph.grid(key.goal_level) orelse return .{ .status = .unavailable };
        const goal_index = self.liveGoal(key, goal_grid).cell orelse return .{ .status = .unavailable };
        if (self.reaches(key.agent_class, start_level, start_index, key.goal_level, goal_index) == .unreachable_goal) return .{ .status = .unavailable };
        if (self.completed.freshSlotIndex(key, self.step_counter, types.default_cache_ttl_steps)) |slot| {
            if (self.cachedView(slot, goal_index, start_level, start_index, waypoint_hint)) |view| return view;
        }
        if (self.pending_keys.contains(key)) return .{ .status = .pending };
        return .{ .status = .missing };
    }

    // The waypoint view of cached result `slot` for a start at `start_index` on
    // `start_level`; null unless the result was solved toward `goal_index`, so a result
    // solved toward an older projection is not served. A partial result reads `.partial`,
    // with `refresh` set inside its end's refresh window.
    fn cachedView(self: *const PathfindingSystem, slot: usize, goal_index: usize, start_level: u16, start_index: usize, waypoint_hint: ?*u32) ?PathView {
        const result = self.completed.resultAt(slot);
        if (result.goal_cell != goal_index) return null;
        const partial = result.isPartial();
        const status: PathStatus = if (partial) .partial else .available;
        const refresh = partial and types.inPartialRefreshWindow(self.graph.chunkGeometry(), result.end, start_level, start_index);
        const path_grid = self.graph.grid(result.path_level) orelse return .{ .status = .unavailable };
        // Abstract chunk/cross-level corridor: a full obstacle-aware stitched
        // (level,cell) path. Walk the run on the agent's CURRENT level cell by
        // cell (every consecutive pair is a traversable neighbor), so multi-hop
        // and cross-floor routes converge without any straight-line cut.
        if (result.stitched_len != 0) {
            const stitched = self.completed.stitchedSlice(slot, result.stitched_len);
            if (waypointFromStitched(&self.graph, stitched, start_level, start_index, waypoint_hint)) |waypoint| {
                return .{ .status = status, .next_waypoint = waypoint, .path_len = result.stitched_len, .refresh = refresh };
            }
            // Agent's level is not yet covered by the corridor (e.g. it has not
            // reached the start-level run): steer toward the corridor's first cell.
            const first_grid = self.graph.grid(stitched.levels[0]) orelse return .{ .status = .unavailable };
            return .{ .status = status, .next_waypoint = first_grid.cellCenter(stitched.cells[0]), .path_len = result.stitched_len, .refresh = refresh };
        }
        const path = self.completed.pathSlice(slot, result.path_len);
        // Plain same-component local solve: derive a forward waypoint from the
        // agent's current cell against the stored path.
        if (result.path_level == start_level) {
            if (waypointFromPath(path_grid, path, start_index, waypoint_hint)) |waypoint| {
                return .{ .status = status, .next_waypoint = waypoint, .path_len = result.path_len, .refresh = refresh };
            }
        }
        return .{ .status = status, .next_waypoint = path_grid.cellCenter(path[0]), .path_len = result.path_len, .refresh = refresh };
    }

    /// A key's live goal on `goal_grid`, its goal level's grid: the key's cell when open,
    /// else the nearest open cell within the projection radius, read from the step's goal
    /// table when it holds the key, else computed (`fallback`). `cell` null: no open cell,
    /// so every start reads unavailable. O(1) for an open cell or a table hit, O(radius²)
    /// for a fallback. Const; safe on workers while the table is read-only.
    pub fn liveGoal(self: *const PathfindingSystem, key: PathQueryKey, goal_grid: *const NavGrid) LiveGoal {
        const key_index = goal_grid.indexForCell(key.goal) orelse return .{};
        // `indexForCell` bounded the cell to the grid.
        if (!goal_grid.isBlockedXY(@intCast(key.goal.x), @intCast(key.goal.y))) return .{ .cell = key_index };
        if (self.goals.lookup(goalRef(traversalOf(key.agent_class), key.goal_level, key_index))) |live| {
            return .{ .cell = if (live == no_cell) null else live, .blocked = true };
        }
        return .{ .cell = goal_grid.projectToNearestOpen(key.goal, default_goal_projection_radius), .blocked = true, .fallback = true };
    }

    const LiveGoal = struct {
        cell: ?usize = null,
        // The key's cell was blocked: `cell` is its projection.
        blocked: bool = false,
        // The goal table did not hold the blocked key, so the projection was computed.
        fallback: bool = false,
    };

    /// Reach from `start_index` on `start_level` to `goal_index` on `goal_level` for agents of
    /// `class`, on its traversal's graph: `start_blocked` for a blocked start, else whether
    /// it reaches the goal. O(1) (`connectivity.reach`); const.
    pub fn reaches(self: *const PathfindingSystem, class: PathAgentClass, start_level: u16, start_index: usize, goal_level: u16, goal_index: usize) Reach {
        return reach(self.graphFor(traversalOf(class)), start_level, start_index, goal_level, goal_index);
    }

    // The nav graph agents of `traversal` move over: one arm per traversal.
    fn graphFor(self: *const PathfindingSystem, traversal: TraversalClass) *const NavGraph {
        return switch (traversal) {
            .walk => &self.graph,
        };
    }

    /// Sizes the goal table for `intent_count` intents per step: the population seam's
    /// reserve. Grow-only and failure-atomic at the old size.
    pub fn reserveGoals(self: *PathfindingSystem, intent_count: usize) error{OutOfMemory}!void {
        try self.goals.reserve(self.allocator, intent_count);
    }

    /// `path_goal_resolve`: builds the step's goal table from `intents` (any type with
    /// `agent_class`, `goal_level`, and a `goal` position), so every status query, intake
    /// request, group-field decision, and solve this step reads a blocked goal's projection
    /// from one entry. `goal_scan` dispatches over intents, each range writing its window of
    /// distinct blocked refs; the main thread merges the windows in range order (O(1) per
    /// entry); `goal_project` dispatches over the distinct goals, one projection each. Both
    /// stages run under their own tuners with `config`'s controls, inline without a thread
    /// system. Intents past the reserved limit grow the table here, before any table write,
    /// geometrically and counted; on error the table is invalid and its storage intact. The
    /// table is valid until the next grid change. Equal for any partition.
    pub fn resolveGoals(self: *PathfindingSystem, comptime Intent: type, intents: []const Intent, thread_system: ?*ThreadSystem, config: PathfindingConfig) error{OutOfMemory}!GoalResolveStats {
        var stats = GoalResolveStats{ .intents = intents.len };
        self.goals.invalidate();
        if (intents.len > self.goals.limit) {
            try self.goals.reserve(self.allocator, @max(intents.len, self.goals.limit *| 2));
            self.countGoalTableGrowth();
        }
        const threads: ?StageThreads = if (thread_system) |system| .{ .thread_system = system, .config = config } else null;
        if (!self.graph.valid()) {
            self.goals.beginScan(0, 0);
            _ = self.goals.mergeScan(1);
            self.goals.finish();
            return stats;
        }
        var graphs: goal_table.Graphs = undefined;
        for (std.enums.values(TraversalClass)) |traversal| graphs.set(traversal, self.graphFor(traversal));
        const scan_dispatch: ?Dispatch = if (threads) |stage| stage.stage(&self.tuners.goal_scan) else null;
        // An empty stage has no shape to select.
        const scan_shape: StageShape = if (intents.len == 0) .{} else stageShape(scan_dispatch, intents.len, goal_table.scan_range_alignment_items);
        self.goals.beginScan(intents.len, scan_shape.range_count);
        var scan = goal_table.ScanJob(Intent){
            .intents = intents,
            // Every level and traversal shares the world's extent.
            .extent = self.graph.grid(0).?,
            .graphs = graphs,
            .items_per_range = scan_shape.items_per_range,
            .refs = self.goals.scan_refs.items,
            .tallies = self.goals.scan_tallies.items,
        };
        stats.scan_batch = runShaped(scan_dispatch, scan_shape, intents.len, goal_table.scan_range_alignment_items, &scan, goal_table.ScanJob(Intent).run);
        stats.blocked = self.goals.mergeScan(scan_shape.items_per_range);
        const distinct = self.goals.refs.items.len;
        const project_dispatch: ?Dispatch = if (threads) |stage| stage.stage(&self.tuners.goal_project) else null;
        const project_shape: StageShape = if (distinct == 0) .{} else stageShape(project_dispatch, distinct, goal_table.project_range_alignment_items);
        var project = goal_table.ProjectJob{
            .refs = self.goals.refs.items,
            .live = self.goals.live.items,
            .graphs = graphs,
            .range_count = project_shape.range_count,
        };
        stats.project_batch = runShaped(project_dispatch, project_shape, distinct, goal_table.project_range_alignment_items, &project, goal_table.ProjectJob.run);
        self.goals.finish();
        stats.distinct = distinct;
        return stats;
    }

    fn countGoalTableGrowth(self: *PathfindingSystem) void {
        self.goal_table_growth.record(1, .info, "path goal table grew to {d} intents", .{self.goals.limit});
    }

    // Shared accept + group-service + solve-limit prologue for update/updateSerial.
    // Safe-point elastic resize runs here, after last frame's publish and before any
    // accept/solve, so no live worker index or pool offset spans it; a shrink's resize copy
    // threads under `threads`. A returned solve_count of 0 means no solve runs this step
    // (caller publishes the pending counts and returns).
    fn beginUpdate(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, threads: ?StageThreads, stats: *PathfindingStats) !usize {
        self.step_counter +%= 1;
        self.last_resize_copy_batch = .{};
        var resize_timer = StageTimer.begin();
        const resized = try self.adjustCapacityForAgentCount(agent_count, threads);
        const resize_ns = if (resized) resize_timer.lap() else 0;
        const gates = stepGates(agent_count);
        if (self.effective_agent_capacity != 0) {
            std.debug.assert(self.limits.frame_requests >= gates.frame_requests);
            std.debug.assert(self.limits.pending_requests >= gates.pending_requests);
            std.debug.assert(self.limits.solves_per_step >= gates.group_tallies);
        }
        var accept_timer = StageTimer.begin();
        stats.* = intake.acceptRequests(self, requests.mergedItems(), gates, threads);
        stats.resize_ns = resize_ns;
        stats.resize_copy_batch = self.last_resize_copy_batch;
        // Fold in any requests a resize dropped (it ran before acceptRequests reset the step
        // stats), then clear the accumulator.
        stats.dropped_requests += self.resize_dropped;
        self.resize_dropped = 0;
        stats.accept_ns = accept_timer.lap();
        var group_timer = StageTimer.begin();
        group_service.serviceGroupFields(self, stats, threads);
        stats.group_service_ns = group_timer.lap();
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
            return null;
        }
        return solve_count;
    }

    // Shared publish + compaction epilogue; finalizes the pending/deferred counts. On a
    // publish-reserve OOM nothing is claimed and pending is left intact for retry; the
    // caller's flush still applies the ops logged so far.
    fn finishUpdate(self: *PathfindingSystem, solve_count: usize, threads: ?StageThreads, stats: *PathfindingStats) !void {
        var publish_timer = StageTimer.begin();
        try publish.reservePublish(self);
        publish.claimPublish(self, stats);
        stats.publish_copy_batch = publish.publishCopy(self, if (threads) |stage| stage.stage(&self.tuners.publish_copy) else null);
        self.compactPendingAfterSolve(solve_count, stats);
        stats.publish_ns = publish_timer.lap();
        stats.pending_requests = self.pending.len;
        // Aggregate this step's worst per-worker stitch segment usage (see
        // SearchScratch.max_stitch_segments_used), then clear each worker's counter so
        // next step's aggregation reflects only next step's solves.
        for (self.scratch_slots.items) |*scratch| {
            if (scratch.max_stitch_segments_used > stats.max_stitch_segments_observed) {
                stats.max_stitch_segments_observed = scratch.max_stitch_segments_used;
            }
            scratch.max_stitch_segments_used = 0;
            stats.crossing_boxes_settled += scratch.crossing_boxes_settled;
            stats.crossing_budget_frozen += scratch.crossing_budget_frozen;
            scratch.crossing_boxes_settled = 0;
            scratch.crossing_budget_frozen = 0;
        }
    }

    /// One fixed-step update with its stages on `thread_system`. At most one request per
    /// steering agent: `requests` holds at most `max(agent_count, min_capacity_floor)`
    /// (asserted). Returns with the path registry flushed, on success and on error.
    pub fn update(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, thread_system: *ThreadSystem, config: PathfindingConfig) error{OutOfMemory}!PathfindingStats {
        const threads = StageThreads{ .thread_system = thread_system, .config = config };
        const flush = threads.stage(&self.tuners.registry_flush);
        var stats = PathfindingStats{};
        errdefer _ = publish.flushRegistry(self, flush, null);
        try self.updateThreaded(requests, agent_count, threads, &stats);
        stats.registry_flush_batch = publish.flushRegistry(self, flush, &stats);
        return stats;
    }

    fn updateThreaded(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, threads: StageThreads, stats: *PathfindingStats) !void {
        const thread_system = threads.thread_system;
        const config = threads.config;
        const solve_count = (try self.beginSolve(requests, agent_count, config, threads, stats)) orelse return;
        var solve_timer = StageTimer.begin();
        self.prepareSolvePhase(solve_count, effectiveAdmissionLimit(config), stats);

        if (self.solve_indices.items.len != 0) {
            // The configured participant count sized the search scratch at the capacity
            // seam, so a correct configuration's clamp below is a no-op. A Debug assert
            // catches a reserve/thread-system mismatch; a release build clamps the worker
            // fan-out to the reserved scratch, so worker indices stay in range and the
            // solve loop stays allocation-free.
            if (builtin.mode == .debug) std.debug.assert(thread_system.participantSlotCount() <= self.scratch_slots.items.len);
            const max_workers_for_scratch = self.scratch_slots.items.len -| 1;
            var stage = threads.stage(&self.tuners.solve);
            stage.max_worker_threads = if (config.max_worker_threads) |requested|
                @min(requested, max_workers_for_scratch)
            else
                max_workers_for_scratch;
            self.resetSolvedPaths();
            // Pre-select so the job context can dual-assert range.index against the
            // dispatched range count.
            const selection = stage.select(self.solve_indices.items.len, pathfinding_range_alignment_items);
            var context = SolveJobContext{ .system = self, .range_count = selection.range_count };
            stats.solve_batch = stage.run(selection, self.solve_indices.items.len, pathfinding_range_alignment_items, &context, solveJob);
        }
        stats.solve_ns = solve_timer.lap();
        try self.finishUpdate(solve_count, threads, stats);
    }

    /// One fixed-step update with every stage inline. At most one request per steering
    /// agent: `requests` holds at most `max(agent_count, min_capacity_floor)` (asserted).
    /// Returns with the path registry flushed, on success and on error.
    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) error{OutOfMemory}!PathfindingStats {
        var stats = PathfindingStats{};
        errdefer _ = publish.flushRegistry(self, null, null);
        try self.updateInline(requests, agent_count, config, &stats);
        stats.registry_flush_batch = publish.flushRegistry(self, null, &stats);
        return stats;
    }

    fn updateInline(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, stats: *PathfindingStats) !void {
        const solve_count = (try self.beginSolve(requests, agent_count, config, null, stats)) orelse return;
        var solve_timer = StageTimer.begin();
        self.prepareSolvePhase(solve_count, effectiveAdmissionLimit(config), stats);
        if (self.solve_indices.items.len != 0) {
            // reserve() always provisions at least one scratch slot, so none means an update
            // before reserve(): a Debug assert catches it, and a release build leaves every
            // admission `.deferred` for a retry instead of reading past the scratch.
            if (builtin.mode == .debug) std.debug.assert(self.scratch_slots.items.len != 0);
            if (self.scratch_slots.items.len != 0) {
                self.resetSolvedPaths();
                const scratch = &self.scratch_slots.items[0];
                for (self.solve_indices.items, 0..) |pending_index, ordinal| {
                    self.solve_results.items[ordinal] = solveOne(self, pending_index, scratch, ordinal);
                }
            }
        }
        stats.solve_batch = inlineBatch(self.solve_indices.items.len, pathfinding_range_alignment_items);
        stats.solve_ns = solve_timer.lap();
        try self.finishUpdate(solve_count, null, stats);
    }

    fn resetSolvedPaths(self: *PathfindingSystem) void {
        self.solved_paths.clearRetainingCapacity();
        for (0..self.solve_results.items.len) |_| self.solved_paths.appendAssumeCapacity(.{ .offset = 0, .len = 0 });
    }

    // The solve window: pending entries this step considers, at most the fixed per-step solve
    // count (a config narrows it). The solve pools hold the window, asserted rather than
    // gated: pending never outgrows its pool, whose solve slots cover min(pending, the count).
    fn effectiveSolveLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_solved_requests_per_step orelse default_max_solves_per_frame;
        const window = @min(self.pending.len, requested_limit, default_max_solves_per_frame);
        std.debug.assert(self.pending.len <= self.limits.pending_requests);
        std.debug.assert(window <= self.limits.solves_per_step);
        std.debug.assert(self.solve_results.capacity >= self.limits.solves_per_step and self.solve_indices.capacity >= self.limits.solves_per_step);
        return window;
    }

    // Admissions to the solve batch this step, at most the fixed per-step solve count (a
    // config narrows it).
    fn effectiveAdmissionLimit(config: PathfindingConfig) usize {
        const requested_limit = config.max_solve_admissions_per_step orelse default_max_solves_per_frame;
        return @min(requested_limit, default_max_solves_per_frame);
    }

    // Admits pending indices of the solve window [0, solve_count) into solve_indices,
    // in increasing order, and sizes solve_results to one slot per admission: the
    // solve ordinal is the solve batch's item index and every solve output's index.
    // A tier-1 (escalated) request is additionally capped at max_escalated_solves_per_step
    // admissions this step, since tier-1 uses the larger fixed abstract-node/stitched-cell
    // ceiling and is the expensive attempt; a tier-1-ready request past the cap is simply
    // skipped (stays deferred, so compactPendingAfterSolve leaves it in place to retry next
    // step) without consuming an admission, so tier-0 requests keep filling the rest.
    // Each admission also records its tier-1 pool entry: the escalated admission index, so
    // admitted escalated solves of one step never share an entry.
    fn prepareSolvePhase(self: *PathfindingSystem, solve_count: usize, admission_limit: usize, stats: *PathfindingStats) void {
        std.debug.assert(self.capacity.max_escalated_solves_per_step <= self.tier1_scratch.items.len);
        std.debug.assert(self.solve_tier1_slot.capacity >= solve_count);
        self.solve_indices.clearRetainingCapacity();
        self.solve_tier1_slot.clearRetainingCapacity();
        var escalated_admitted: usize = 0;
        for (0..solve_count) |pending_index| {
            const is_escalated = self.pending.at(pending_index).tier != 0;
            if (is_escalated and escalated_admitted >= self.capacity.max_escalated_solves_per_step) {
                stats.escalated_deferred += 1;
                continue;
            }
            if (self.solve_indices.items.len < admission_limit) {
                self.solve_indices.appendAssumeCapacity(pending_index);
                self.solve_tier1_slot.appendAssumeCapacity(if (is_escalated) @intCast(escalated_admitted) else no_tier1_slot);
                if (is_escalated) {
                    escalated_admitted += 1;
                    stats.escalated_solves += 1;
                }
            } else {
                stats.admission_deferred_requests += 1;
            }
        }
        self.solve_results.clearRetainingCapacity();
        for (0..self.solve_indices.items.len) |_| {
            self.solve_results.appendAssumeCapacity(.{ .deferred = emptyKey(self.graph.version) });
        }
    }

    // `resize_copy`: copies a shrink's pending path moves, threaded over moves, then frees
    // the pages the shrink left behind. Moves have distinct sources and destinations.
    fn runResizeCopy(self: *PathfindingSystem, dispatch: ?Dispatch) BatchStats {
        const moves = self.completed.pendingMoves();
        var batch = BatchStats{};
        if (moves.len != 0) {
            const shape = stageShape(dispatch, moves.len, 1);
            var job = ResizeCopyJob{ .cache = &self.completed, .moves = moves, .range_count = shape.range_count };
            batch = runShaped(dispatch, shape, moves.len, 1, &job, resizeCopyJob);
        }
        self.completed.finishResize(self.allocator);
        return batch;
    }

    // Compacts the solve window [0, solve_count) of pending in O(solve_count). Answered
    // entries (available/unavailable/start_invalid) are removed. Deferred entries (not
    // admitted this frame, including a tier-1-ready request skipped by the escalated-solve
    // cap) keep their front order. A budget-exhausted entry follows the two-tier ladder:
    // tier 0 (the cheap, fixed-budget attempt) promotes to tier 1 and rotates to the BACK
    // of pending exactly once, so the untouched tail reaches the solve window before the
    // promoted entry retries at the larger — but still fixed, never derived from
    // world/graph size — tier-1 budget; a budget-exhausted AT tier 1 drops the entry (the
    // goal is reachable, it just does not fit either fixed budget, so it is never
    // `.unavailable`) — worst case exactly two solve attempts per request, never an
    // unbounded retry storm.
    //
    // The window is walked back to front, each outcome recovered by merge-walking the
    // increasing solve_indices; kept entries are written toward the window end (a
    // write never lands below its source), the ring head advances past everything else,
    // and the rotated entries are pushed at the tail. Resulting order: deferred, tail,
    // rotated. pending_keys loses the keys of solved and dropped entries only.
    fn compactPendingAfterSolve(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        if (solve_count == 0) return;
        self.rotate_back_scratch.clearRetainingCapacity();
        const admitted = self.solve_indices.items;
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
                    self.pending.atPtr(write_index).* = self.pending.at(pending_index);
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
                        // Tier 1 (the larger fixed ceiling) still exhausted: the goal is
                        // reachable (solve checked), the request just did not fit either fixed
                        // budget. Drop it from pending, so the next status query falls through
                        // to `.missing` (retryable), never a false `.unavailable`: at most two
                        // solve attempts per request.
                        stats.escalated_dropped += 1;
                        self.pending_keys.remove(key);
                    }
                },
                else => {
                    // available/partial/unavailable/start_invalid: removed from pending. An
                    // unavailable or start_invalid entry is never cached; the next status
                    // query answers it again from reach, or reads `.missing` and the caller
                    // may re-request. A partial's next hop is a new tier-0 request.
                    self.pending_keys.remove(self.pending.at(pending_index).key);
                },
            }
        }
        std.debug.assert(ordinal == 0);
        dropPendingFront(&self.pending, write_index);
        // Aged spillers trail the untouched tail so the tail makes progress before they
        // retry; they were gathered back to front.
        var rotated = self.rotate_back_scratch.items.len;
        while (rotated > 0) {
            rotated -= 1;
            self.pending.pushBackAssumeCapacity(self.rotate_back_scratch.items[rotated]);
        }
    }
};

/// One stage of the nav reaction under its own tuner and the nav controls; null without a
/// thread system.
pub fn navDispatch(self: *const PathfindingSystem, thread_system: ?*ThreadSystem, tuner: *AdaptiveWorkTuner) ?Dispatch {
    const threads = thread_system orelse return null;
    return Dispatch.init(threads, tuner, self.nav_controls);
}

// Resizes `pending` to `slot_count` slots and empties it; an OOM leaves its storage and
// contents as they were. Below half the slots it reallocates, else it keeps them.
fn reservePending(pending: *std.Deque(PendingRequest), allocator: std.mem.Allocator, slot_count: usize) !void {
    if (shouldShrinkCapacity(pending.buffer.len, slot_count)) {
        const fresh: std.Deque(PendingRequest) = try .initCapacity(allocator, slot_count);
        pending.deinit(allocator);
        pending.* = fresh;
        return;
    }
    try pending.ensureTotalCapacityPrecise(allocator, slot_count);
    clearPending(pending);
}

// Empties `pending`, keeping its slots (std.Deque has no clear).
fn clearPending(pending: *std.Deque(PendingRequest)) void {
    pending.head = 0;
    pending.len = 0;
}

// Removes the first `count` entries in O(1) (std.Deque drops only one at a time).
fn dropPendingFront(pending: *std.Deque(PendingRequest), count: usize) void {
    std.debug.assert(count <= pending.len);
    if (count == 0) return;
    pending.head = (pending.head + count) % pending.buffer.len;
    pending.len -= count;
}

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

// `nav_mark` takes only what a terrain writer appends.
fn assertTerrainNavEvent(event: SimulationEvent) void {
    std.debug.assert(event.payload == .world_tile_changed or event.payload == .world_obstacle_changed);
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
        assertTerrainNavEvent(event);
        if (interpretNavEvent(job.world, event)) |mark| count = foldMark(window, count, mark, job.chunk_tiles);
    }
    job.tallies[range.index] = .{ .count = count };
}

// Each shard's owner heads for a shrink to `capacity`, installed by the flush that applies
// the shrink's ops; allocated before the shrink commits. On error none is prepared.
fn prepareTruncate(shards: *[registry_shard_count]ChunkListMap, capacity: usize) !void {
    errdefer abortTruncate(shards);
    for (shards) |*shard| try shard.prepareTruncate(capacity);
}

fn abortTruncate(shards: *[registry_shard_count]ChunkListMap) void {
    for (shards) |*shard| shard.abortTruncate();
}

// One range of `resize_copy`: its moves' stored paths.
const ResizeCopyJob = struct {
    cache: *const ResultCache,
    moves: []const ResizeMove,
    range_count: usize,
};

// SIMD verdict: `@memcpy` per move.
fn resizeCopyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ResizeCopyJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.moves.len);
    for (job.moves[range.start..range.end]) |move| job.cache.copyMove(move);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const PathStatus = @import("types.zig").PathStatus;
const GroupFieldState = @import("group_field.zig").GroupFieldState;
const test_support = @import("test_support.zig");
const addNavBody = @import("test_support.zig").addNavBody;
const appendPathRequest = @import("test_support.zig").appendPathRequest;
const baselineCapacity = @import("test_support.zig").baselineCapacity;
const abstractCapacity = @import("test_support.zig").abstractCapacity;
const loadTestWorldMeta = @import("test_support.zig").loadTestWorldMeta;
const requireTestTile = @import("test_support.zig").requireTestTile;
const tileCenter = @import("test_support.zig").tileCenter;
const cellWorld = @import("test_support.zig").cellWorld;
const appendIndividual = @import("test_support.zig").appendIndividual;
const solveIndividualGoals = @import("test_support.zig").solveIndividualGoals;
const cachedPathCells = @import("test_support.zig").cachedPathCells;
const RegistryWorld = @import("test_support.zig").RegistryWorld;
const registryWorld = @import("test_support.zig").registryWorld;
const registrySystem = @import("test_support.zig").registrySystem;
const registrySystemWith = @import("test_support.zig").registrySystemWith;
const registryRoute = @import("test_support.zig").registryRoute;
const registryRouteKey = @import("test_support.zig").registryRouteKey;
const solveRegistryRoutes = @import("test_support.zig").solveRegistryRoutes;
const storedPath = @import("test_support.zig").storedPath;
const expectRegistryMatchesCache = @import("test_support.zig").expectRegistryMatchesCache;
const expectSameRegistry = @import("test_support.zig").expectSameRegistry;
const expectSameCache = @import("test_support.zig").expectSameCache;
const setRegistryCells = @import("test_support.zig").setRegistryCells;
const setSystemAllocators = @import("test_support.zig").setSystemAllocators;
const fixed_threads_config = @import("test_support.zig").fixed_threads_config;
const flushUnits = @import("test_support.zig").flushUnits;
const shrinkFixture = @import("test_support.zig").shrinkFixture;
const intake_test_agents = @import("test_support.zig").intake_test_agents;
const expectRequestStatsEqual = @import("test_support.zig").expectRequestStatsEqual;
const expectQueuesEqual = @import("test_support.zig").expectQueuesEqual;
const writeGroupGoals = @import("test_support.zig").writeGroupGoals;
const expectGroupFieldsEqual = @import("test_support.zig").expectGroupFieldsEqual;
const stallingFieldCapacity = @import("test_support.zig").stallingFieldCapacity;
const stalling_field_goals = @import("test_support.zig").stalling_field_goals;
const pocket_world_side = @import("test_support.zig").pocket_world_side;
const pocket_cells = @import("test_support.zig").pocket_cells;
const pocketWorld = @import("test_support.zig").pocketWorld;
const pocketGoal = @import("test_support.zig").pocketGoal;
const solveFrom = @import("test_support.zig").solveFrom;
const navMarkTestEvents = @import("test_support.zig").navMarkTestEvents;
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

    // The blocked agent requests first: a start-side drop, never an unavailable goal.
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

test "pathfinding zero admission budget leaves an empty solve batch without panicking" {
    // A zero admission budget with pending work yields an empty solve_indices, which
    // must not panic the strict-increase verification slice (items[1..]) in either path.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // worker_participant_count=4 (workers + main) matches the threaded section's real
    // ThreadSystem below (max_worker_threads=2 -> up to 3 participants): reserving at
    // baselineCapacity's serial default (1) would violate update()'s reserve/thread-system
    // assert, but this test's zero admission budget happens to keep solve_indices empty
    // every call, skipping that assert entirely and masking the mismatch instead of
    // genuinely satisfying the contract.
    var capacity = baselineCapacity();
    capacity.worker_participant_count = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var serial_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer serial_stream.deinit();
    try appendPathRequest(&serial_stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });
    const serial_stats = try system.updateSerial(&serial_stream, 8, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 0), serial_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), serial_stats.pending_requests);

    if (!builtin.single_threaded) {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
        defer threads.deinit();
        var threaded_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer threaded_stream.deinit();
        try appendPathRequest(&threaded_stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 64, .y = 64 } });
        const threaded_stats = try system.update(&threaded_stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1, .max_solve_admissions_per_step = 0 });
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

    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 128, .y = 8 }, .default, null).status);
    const stats = try system.updateSerial(&stream, 8, .{});
    // Start and goal are different labels of the level's one chunk: reach answers at intake,
    // with no solve and nothing cached.
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), stats.solved_requests + system.pending.len + system.completed.count());
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

test "pathfinding pending_requests equals post-compaction pending in the serial update path" {
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
    try std.testing.expectEqual(system.pending.len, stats.pending_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.pending_requests);
}

test "pathfinding pending_requests equals post-compaction pending in the threaded update path" {
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
    try std.testing.expectEqual(system.pending.len, stats.pending_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
}

test "pathfinding same-level group agent falls through on a field-sample miss instead of a hard unavailable" {
    // A ready field does not cover every same-level cell (e.g. one blocked by a body added
    // after the field built): a sample miss there must fall through to the individual
    // live-goal/reach/cache/pending path, exactly like an off-level member already does —
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

    // Clear the goal-keyed cache the first step's individual solve populated, and
    // simulate an in-flight solve for it, so the only remaining fallthrough signal is
    // pending_keys — isolating the field-sample-miss branch from the unrelated cache hit.
    publish.clearCompleted(&system);
    const key = system.graph.keyForWorld(0, goal, .default).?;
    _ = system.pending_keys.insert(key);

    const blocked_start = math.Vec2{ .x = 240, .y = 240 };
    const view = system.statusForWorld(0, blocked_start, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.pending, view.status);
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

    // Warm multi-worker solve path (must not run inline).
    const warmup = try system.update(&stream, count, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!warmup.solve_batch.ran_inline);
    try std.testing.expect(warmup.solve_batch.active_worker_threads > 0);

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
    // multi-worker solve path under the failing allocator.
    system.clearRuntimeState();
    const stats = try system.update(&stream, count, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!stats.solve_batch.ran_inline);
    try std.testing.expect(stats.solve_batch.item_count > 0);
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
    const serial_cap = baselineCapacity();
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

    // One step warms the path registry's storage at its publish reserve; the same solve
    // and publish after a cache clear allocates nothing.
    _ = try system.updateSerial(&stream, 8, .{});
    system.clearRuntimeState();
    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, 8, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding request storage stays within its bound after reserve, solves, and a goal resolve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // 384px = 12x12 nav cells in 4-cell chunks: every route below crosses chunks.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    var capacity = abstractCapacity();
    capacity.max_agent_budget = 16;
    capacity.worker_participant_count = 2;
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    // A stored path of 12x12 cells holds at most one run per cell.
    const shape = PathfindingSystem.RequestShape{ .runs_per_result = 144, .chunks = 9 };
    try expectRequestStorageWithin(&system, capacity, shape);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    var requests: [8]PathRequest = undefined;
    for (&requests, 0..) |*request, index| {
        const row: f32 = @floatFromInt(index);
        request.* = .{ .entity = try data.createEntity(), .start = .{ .x = 16, .y = 16 + 32 * row }, .goal = .{ .x = 368, .y = 368 - 32 * row } };
        try appendPathRequest(&stream, request.*);
    }
    _ = try system.updateSerial(&stream, requests.len, .{});
    _ = try system.resolveGoals(PathRequest, &requests, null, .{});
    try std.testing.expect(system.completed.count() != 0);
    try expectRequestStorageWithin(&system, capacity, shape);
}

fn expectRequestStorageWithin(system: *const PathfindingSystem, capacity: PathfindingCapacity, shape: PathfindingSystem.RequestShape) !void {
    const resident = system.requestResidentBytes();
    const bound = PathfindingSystem.requestStorageBytesBound(capacity, shape);
    inline for (@typeInfo(PathfindingSystem.RequestStorage).@"struct".field_names) |name| {
        try std.testing.expect(@field(resident, name) <= @field(bound, name));
    }
    try std.testing.expect(resident.search != 0 and resident.results != 0);
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
    // nav_version and the link becomes live.
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
    const capacity = abstractCapacity();
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
    const one_level_start_portals = test_support.levelLivePortalCount(&one_system.graph, 0);

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
    const four_level_start_portals = test_support.levelLivePortalCount(&four_system.graph, 0);

    try std.testing.expect(one_level_start_portals > 0);
    // The extra open levels add many total portals, but the start level's seeded
    // count is unchanged: seeding never touches the other levels' portals.
    try std.testing.expect(test_support.totalPortals(&four_system.graph) > four_level_start_portals);
    try std.testing.expectEqual(one_level_start_portals, four_level_start_portals);

    // The per-query abstract search completes within the node budget regardless of
    // world size: a long diagonal solve never surfaces saturation as unavailable.
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
    const capacity = abstractCapacity();
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
    // Saturation spills to a later frame: counted as budget_exhausted, never unavailable,
    // and the status reads pending (retryable).
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

// A tier-1 (already-escalated) budget_exhausted drops the request: it does not fit either
// fixed budget, which is not the same as "no path exists" (unavailable is reserved for an
// unreachable goal). The next query falls through to `.missing` (retryable — steering
// re-requests after its own cooldown) rather than a permanent false unavailable, and the
// request cost at most two
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

    // Attempt 2 (tier 1): exhausts again -> dropped, never unavailable.
    const second = try system.updateSerial(&stream, 8, .{});
    // It drops through seeding saturation: the start chunk's second seed passes the one-node
    // budget before any node is expanded, so no least-estimate node exists to publish toward.
    const tier1_abstract = &system.tier1_scratch.items[0].corridor.abstract;
    for (tier1_abstract.slots) |slot| try std.testing.expect(slot.stamp >> 1 != tier1_abstract.generation or slot.stamp & 1 == 0);
    try std.testing.expectEqual(@as(usize, 1), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), second.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), second.pending_requests);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    // Exactly two solve attempts total across the two steps.
    try std.testing.expectEqual(@as(usize, 2), first.budget_exhausted + second.budget_exhausted);

    // Dropped: the next query reads .missing (retryable), never .unavailable for a goal
    // that may be reachable.
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
    // this step (a zero admission budget defers every one), so all four land in `pending`
    // at the default tier 0.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester_a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 40, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = requester_b, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 72, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = requester_c, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 104, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = requester_d, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 136, .y = 8 } });
    _ = try system.updateSerial(&stream, 8, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 4), system.pending.len);

    // Promote every pending entry to tier 1 (as if each had already spilled once).
    for (0..system.pending.len) |index| system.pending.atPtr(index).tier = 1;

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
    const left_component = grid.chunkLabelAt(left_cell);
    const right_component = grid.chunkLabelAt(right_cell);
    // The two cells sit in different chunks AND different regions.
    try std.testing.expect(left_component.label != 0);
    try std.testing.expect(right_component.label != 0);
    try std.testing.expect(!std.meta.eql(left_component, right_component));

    // A start chunk's record holds only its own portals; those sharing the start cell's
    // label (the seeds) all lie in that chunk with that component, and each seed set is a
    // strict subset of the level's portals.
    const left_chunk = grid.geometry.chunkOfCell(left_cell);
    const right_chunk = grid.geometry.chunkOfCell(right_cell);
    for ([_]struct { chunk: u32, cell: usize, component: NavGrid.ChunkLabel }{
        .{ .chunk = left_chunk, .cell = left_cell, .component = left_component },
        .{ .chunk = right_chunk, .cell = right_cell, .component = right_component },
    }) |start| {
        const portals = system.graph.chunkPortals(0, start.chunk);
        var seeds: usize = 0;
        for (portals.border) |portal| {
            if (portal.label != grid.labelAt(start.cell)) continue;
            const cell = test_support.cellOfLocal(system.graph.geometry, start.chunk, portal.local);
            try std.testing.expectEqual(start.component, grid.chunkLabelAt(cell));
            try std.testing.expectEqual(start.chunk, grid.geometry.chunkOfCell(cell));
            seeds += 1;
        }
        try std.testing.expect(seeds > 0);
        try std.testing.expect(seeds < test_support.levelLivePortalCount(&system.graph, 0));
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
    // the heap: scratch and corridor stripes were warmed at reserve/rebuild, and the path
    // registry by one publish of the same solve before a cache clear.
    _ = try system.updateSerial(&stream, 8, .{});
    system.clearRuntimeState();
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
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);

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
        const stitched = system.completed.stitchedSlice(slot, result.stitched_len);
        for (stitched.cells, stitched.levels) |cell, level| {
            if (level == 0 and cell == target) return true;
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
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The cached path crossed the now-closed gap (5,3), so it was evicted, and reach answers
    // the re-request unavailable, not a stale cached available, with no solve.
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, start, 0, goal, .default, null).status);
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), after.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), after.solved_requests);
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
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
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
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
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
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);

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
    const stats = try test_support.applyTileEdits(&system, no_colliders, &world, &.{});
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
            try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = nx, .y = ny }});
            marked += 1;
        }
    }
    var fx: u16 = 13;
    while (fx < 16) : (fx += 1) {
        _ = (try world.setDenseTile(obstacle, fx, 13, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = fx, .y = 13 }});
        marked += 1;
    }
    try std.testing.expect(marked > system.limits.frame_requests);
    try std.testing.expect(system.hasPendingNavUpdates(&world));

    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The far block — marked last, the first a fixed cap would drop — reached the graph.
    const nav = system.graph.grid(0).?;
    fx = 13;
    while (fx < 16) : (fx += 1) try std.testing.expect(nav.isBlockedCell(.{ .x = @intCast(fx), .y = 13 }));
    // applyBuffered clears the buffer, so the next step starts empty.
    try std.testing.expect(!system.hasPendingNavUpdates(&world));
}

test "nav over a world takes the world's chunk edge and tile size; a world-less build takes its config" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // World chunk 8 and a deliberately different config: nav chunk 16, cell size 8.
    var world = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, &meta, 512, 256, 8);
    defer world.deinit();
    var capacity = baselineCapacity();
    capacity.nav_chunk_tiles = 16;

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try std.testing.expectEqual(world.chunk_size_tiles, system.graph.geometry.chunk_tiles);
    try std.testing.expectEqual(world.tile_size, system.graph.cell_size);
    try std.testing.expectEqual(@as(usize, world.width), system.graph.geometry.width);
    try std.testing.expectEqual(@as(usize, world.height), system.graph.geometry.height);
    const level_grid = system.graph.grid(0).?;
    try std.testing.expectEqual(world.chunk_size_tiles, level_grid.geometry.chunk_tiles);
    try std.testing.expectEqual(@as(u32, world.chunksX()), level_grid.geometry.chunks_x);
    try std.testing.expectEqual(@as(u32, world.chunksY()), level_grid.geometry.chunks_y);
    // Every tile's nav chunk is its world chunk.
    for (0..world.height) |y| {
        for (0..world.width) |x| {
            const tile_chunk = world.chunkCoordForCell(@intCast(x), @intCast(y));
            const expected: u32 = @intCast(tile_chunk.y * @as(i32, world.chunksX()) + tile_chunk.x);
            try std.testing.expectEqual(expected, level_grid.geometry.chunkOfCell(y * level_grid.geometry.width + x));
        }
    }

    try system.rebuildStaticNavGrid(&data, 512, 256, 8);
    try std.testing.expectEqual(capacity.nav_chunk_tiles, system.graph.geometry.chunk_tiles);
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
    // A side past 2^32 cells, a side past usize, and a subnormal cell size's inf quotient each
    // reach the validator rather than trapping in the float conversion.
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 0x1p33, 1, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 1.0e30, 1.0e30, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 1, 1, std.math.floatTrueMin(f32)));
    const huge_extent = system.boundsNavExtent(1.0e30, 1, 1);
    try std.testing.expectError(error.LevelCellIndexOverflow, system.graph.rebuild(.{}, huge_extent, null));
}

test "a nav update reports its marks batch's remask, and an update without marks reports none" {
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

    const changed = (try world.setDenseTile(obstacle, 2, 2, tree)) orelse return error.TestExpectedEqual;
    const stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expect(stats.remask_batch.item_count > 0);
    try std.testing.expectEqual(stats.dirty_chunks, stats.remask_batch.item_count);

    // The graph keeps its last remask; an update with no batch must not report it again.
    const idle = try test_support.applyTileEdits(&system, no_colliders, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), idle.incremental_rebuilds);
    try std.testing.expectEqual(BatchStats{}, idle.remask_batch);

    // A batch whose only mark misses every built level commits without changing the graph.
    const unbuilt = try test_support.applyTileEdits(&system, no_colliders, &world, &.{.{ .level = 99, .x = 2, .y = 2 }});
    try std.testing.expectEqual(@as(usize, 0), unbuilt.incremental_rebuilds);
    try std.testing.expectEqual(BatchStats{}, unbuilt.remask_batch);
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
    try std.testing.expect(grid.geometry.width >= 8);
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
    const high_water = test_support.totalPortals(&system.graph);
    try std.testing.expect(high_water > 0);

    // Warmup: the same block and reopen, so every batch buffer and record pool reaches
    // its steady capacity.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        const warm = (try world.setDenseTile(built.wall_layer, 5, 3, tile)) orelse return error.TestExpectedEqual;
        _ = try test_support.applyTileChange(&system, no_colliders, &world, warm);
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
    const block_stats = try test_support.applyTileChange(&system, no_colliders, &world, blocked);
    try std.testing.expectEqual(@as(usize, 1), block_stats.incremental_rebuilds);

    // Reopen the same gap: re-adds portals back to <= the init high-water count, so it
    // reuses retained capacity and allocates nothing.
    const opened = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    const open_stats = try test_support.applyTileChange(&system, no_colliders, &world, opened);
    try std.testing.expectEqual(@as(usize, 1), open_stats.incremental_rebuilds);
    try std.testing.expect(test_support.totalPortals(&system.graph) <= high_water);

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
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };

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
            try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
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
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
    }
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    // Every stage must have actually threaded, not fallen back to the inline slot-0 path —
    // otherwise this would silently retest the already-covered serial path. A plan over
    // several ranges merges through the plan order set into its reserved key lists.
    try std.testing.expect(!stats.remask_batch.ran_inline);
    try std.testing.expect(!stats.patch_batch.ran_inline);
    try std.testing.expect(!stats.plan_batch.ran_inline);
    try std.testing.expect(system.graph.plan_tallies.items.len > 1);

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
    try std.testing.expectEqual(@as(usize, 0), test_support.totalPortals(&system.graph));

    // Open a 6x6 block spanning chunk borders, creating records past the (zero) init pool.
    var edits = std.ArrayList(test_support.TileEdit).empty;
    defer edits.deinit(std.testing.allocator);
    y = 2;
    while (y < 8) : (y += 1) {
        var x: u16 = 2;
        while (x < 8) : (x += 1) {
            const opened = (try world.setDenseTile(wall_layer, x, y, grass)) orelse continue;
            try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
        }
    }
    const stats = try test_support.applyTileEdits(&system, no_colliders, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The opened block holds portals.
    try std.testing.expect(test_support.totalPortals(&system.graph) > 0);

    // A subsequent edit within the NEW high-water mark (a cell of a chunk already mixed, so
    // no new block) is allocation-free again.
    const closed = (try world.setDenseTile(wall_layer, 3, 3, tree)) orelse return error.TestExpectedEqual;
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const close_stats = try test_support.applyTileChange(&system, no_colliders, &world, closed);
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
    // dense tile API (which emits a WorldTileChangedEvent that drives the nav update).
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
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
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
    try std.testing.expect(system.limits.pending_requests >= 40);
    try std.testing.expect(system.completed.core.slots.items.len >= 40 * cached_results_per_agent);
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
    // per-frame A* solve and admission budgets stay pinned to the fixed amortization
    // ceiling so a diverse-goal burst spreads across frames.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 480, .y = 480 } });
    _ = try system.updateSerial(&stream, 4096, .{});

    try std.testing.expectEqual(@as(usize, 4096), system.limits.pending_requests);
    try std.testing.expectEqual(@as(usize, 4096), system.limits.frame_requests);
    try std.testing.expectEqual(@as(usize, 4096 * cached_results_per_agent), system.limits.cached_results);
    // Solve/admission budgets capped at the fixed per-frame ceiling, NOT population.
    try std.testing.expectEqual(default_max_solves_per_frame, system.limits.solves_per_step);
    try std.testing.expectEqual(default_max_solves_per_frame, system.limits.solves_per_step);
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
    const steady_pending = system.pending.buffer.len;
    const steady_cache = system.completed.core.slots.items.len;
    const steady_pool = system.worker_path_pool.items.len;
    // A constant agent count holds capacity (and every pool's backing) fixed across
    // many steps, so the per-step solve loop never reallocates after warmup.
    for (0..30) |_| {
        _ = try driveAgentCount(&system, &requesters, 16);
        try std.testing.expectEqual(steady_cap, system.effective_agent_capacity);
        try std.testing.expectEqual(steady_pending, system.pending.buffer.len);
        try std.testing.expectEqual(steady_cache, system.completed.core.slots.items.len);
        try std.testing.expectEqual(steady_pool, system.worker_path_pool.items.len);
    }
}

test "pathfinding a capacity shrink keeps every live pending request and group tally" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const pending_count = 200;
    var requesters: [pending_count]EntityId = undefined;
    for (&requesters) |*slot| slot.* = try data.createEntity();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = pending_count;
    capacity.capacity_shrink_window = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    const no_admission = PathfindingConfig{ .max_solve_admissions_per_step = 0 };

    // 200 distinct goals stay pending (no admission).
    const fill_stats = try submitGoalWalk(&system, &requesters, .{}, pending_count, no_admission);
    try std.testing.expectEqual(@as(usize, pending_count), fill_stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, pending_count), system.effective_agent_capacity);

    // A low-load window at one agent: a shrink would size below the live queue, so none runs.
    var stats: PathfindingStats = undefined;
    for (0..capacity.capacity_shrink_window) |_| {
        stats = try updateNoRequests(&system, 1, no_admission);
        try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
        try expectPoolsFitLogicalCaps(&system);
    }
    try std.testing.expectEqual(@as(usize, pending_count), system.effective_agent_capacity);
    try std.testing.expectEqual(@as(usize, pending_count), system.pending.len);
    for (0..pending_count) |index| {
        const entry = system.pending.at(index);
        try std.testing.expectEqual(requesters[index], entry.entity);
        try std.testing.expect(system.pending_keys.contains(entry.key));
    }

    // One step drains the queue.
    stats = try updateNoRequests(&system, 1, .{});
    try std.testing.expectEqual(@as(usize, pending_count), stats.solved_requests);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);

    // Four group requests per drained goal: cache hits, so 50 tallies outnumber the empty
    // queue, and their count outlives the window's halvings.
    const tally_keys = pending_count / 4;
    _ = try submitGoalWalk(&system, &requesters, .{ .per_goal = 4, .group = true }, pending_count, .{});
    try std.testing.expectEqual(@as(usize, tally_keys), system.group_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);

    // A window at one agent shrinks to the live tallies, never below them: none drop.
    for (0..capacity.capacity_shrink_window) |_| {
        stats = try updateNoRequests(&system, 1, .{});
        try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
        try expectPoolsFitLogicalCaps(&system);
    }
    try std.testing.expectEqual(@as(usize, tally_keys), system.effective_agent_capacity);
    try std.testing.expectEqual(@as(usize, tally_keys), system.group_requests.items.len);
    for (system.group_requests.items, 0..) |tally, index| {
        try std.testing.expectEqual(@as(?usize, index), system.group_key_map.find(tally.key));
    }

    // Once the tallies decay away, a further window shrinks to the floor.
    for (0..2 * capacity.capacity_shrink_window) |_| {
        stats = try updateNoRequests(&system, 1, .{});
        try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
        try expectPoolsFitLogicalCaps(&system);
    }
    try std.testing.expectEqual(@as(usize, 0), system.group_requests.items.len);
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
}

test "pathfinding a capacity shrink to the live queue keeps every pending entry in order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const pending_count = 30;
    var requesters: [pending_count]EntityId = undefined;
    for (&requesters) |*slot| slot.* = try data.createEntity();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 200;
    capacity.capacity_shrink_window = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    try system.growForAgentCount(200);
    try std.testing.expectEqual(@as(usize, 200), system.effective_agent_capacity);

    // 30 distinct goals stay pending (no admission), then a low-load window at one agent
    // shrinks to the queue: it resizes, and keeps every entry.
    const no_admission = PathfindingConfig{ .max_solve_admissions_per_step = 0 };
    _ = try submitGoalWalk(&system, &requesters, .{}, pending_count, no_admission);
    try std.testing.expectEqual(@as(usize, pending_count), system.pending.len);
    for (0..capacity.capacity_shrink_window) |_| {
        const stats = try updateNoRequests(&system, 1, no_admission);
        try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
        try expectPoolsFitLogicalCaps(&system);
    }
    try std.testing.expectEqual(@as(usize, pending_count), system.effective_agent_capacity);
    try std.testing.expectEqual(@as(usize, pending_count), system.pending.len);
    for (0..pending_count) |index| {
        const entry = system.pending.at(index);
        try std.testing.expectEqual(requesters[index], entry.entity);
        try std.testing.expect(system.pending_keys.contains(entry.key));
    }
}

fn updateNoRequests(system: *PathfindingSystem, agent_count: usize, config: PathfindingConfig) !PathfindingStats {
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    return system.updateSerial(&empty, agent_count, config);
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

/// A system at ceiling `budget` with the default shrink window on a `side` x `side` world.
fn gateTestSystem(data: *const DataSystem, side: f32, budget: usize) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = budget;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, side, side, 32);
    return system;
}

/// Goals walked row by row over a `width_cells`-wide grid from goal index `first`, `per_goal`
/// requests each; every request starts one cell beside its goal, so each solve is one step.
const GoalWalk = struct {
    first: usize = 0,
    per_goal: usize = 1,
    width_cells: usize = 16,
    group: bool = false,
};

/// Submits one request per requester along `walk`.
fn submitGoalWalk(system: *PathfindingSystem, requesters: []const EntityId, walk: GoalWalk, agent_count: usize, config: PathfindingConfig) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(requesters.len, requesters.len);
    for (requesters, 0..) |entity, index| {
        const goal_index = walk.first + index / walk.per_goal;
        const x: i32 = @intCast(goal_index % walk.width_cells);
        const y: i32 = @intCast(goal_index / walk.width_cells);
        try appendPathRequest(&stream, .{
            .entity = entity,
            .kind = if (walk.group) .group else .individual,
            .start = cellWorld(if (x == 0) 1 else x - 1, y),
            .goal = cellWorld(x, y),
        });
    }
    return system.updateSerial(&stream, agent_count, config);
}

/// Same step stats, pending queue, group tallies, and cached key set. Probe slots and owner
/// ids are layout, which differs between differently sized caches, so only keys compare.
fn expectGatedStateEqual(expected: *const PathfindingSystem, expected_stats: PathfindingStats, actual: *const PathfindingSystem, actual_stats: PathfindingStats) !void {
    try expectRequestStatsEqual(expected_stats, actual_stats);
    try std.testing.expectEqual(expected_stats.solved_requests, actual_stats.solved_requests);
    try std.testing.expectEqual(expected_stats.admission_deferred_requests, actual_stats.admission_deferred_requests);
    try expectQueuesEqual(expected, actual);
    try std.testing.expectEqual(expected.completed.count(), actual.completed.count());
    const core = &expected.completed.core;
    for (core.records.items, 0..) |record, owner| {
        if (!record.live) continue;
        try std.testing.expect(actual.completed.slotIndex(core.keyOf(@intCast(owner))) != null);
    }
}

test "pathfinding gates follow the live agent count, never capacity history" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agents = 40;
    var requesters: [agents]EntityId = undefined;
    for (&requesters) |*slot| slot.* = try data.createEntity();

    // Capacity 40 freshly sized, 64 grown through 12 and 20, and 128 held inside the shrink
    // window (40 agents are under half of it).
    var fresh = try gateTestSystem(&data, 512, 256);
    defer fresh.deinit();
    try fresh.growForAgentCount(agents);
    var grown = try gateTestSystem(&data, 512, 256);
    defer grown.deinit();
    for ([_]usize{ 12, 20, agents }) |count| try grown.growForAgentCount(count);
    var held = try gateTestSystem(&data, 512, 256);
    defer held.deinit();
    try held.growForAgentCount(128);
    try std.testing.expectEqual(@as(usize, 40), fresh.effective_agent_capacity);
    try std.testing.expectEqual(@as(usize, 64), grown.effective_agent_capacity);
    try std.testing.expectEqual(@as(usize, 128), held.effective_agent_capacity);

    const no_admission = PathfindingConfig{ .max_solve_admissions_per_step = 0 };
    const Step = struct { walk: GoalWalk, config: PathfindingConfig, accepted: usize, dropped: usize };
    const steps = [_]Step{
        // 40 goals stay pending.
        .{ .walk = .{}, .config = no_admission, .accepted = agents, .dropped = 0 },
        // 40 new goals: the pending gate binds.
        .{ .walk = .{ .first = agents }, .config = no_admission, .accepted = 0, .dropped = agents },
        // The same goals again drop while the first 40 solve.
        .{ .walk = .{ .first = agents }, .config = .{}, .accepted = 0, .dropped = agents },
        // Accepted and solved.
        .{ .walk = .{ .first = agents }, .config = .{}, .accepted = agents, .dropped = 0 },
        // 40 group goals stay pending, each tallied.
        .{ .walk = .{ .first = 2 * agents, .group = true }, .config = no_admission, .accepted = agents, .dropped = 0 },
        // 40 more group goals while the step-5 tallies are listed: the pending and tally
        // gates bind.
        .{ .walk = .{ .first = 3 * agents, .group = true }, .config = no_admission, .accepted = 0, .dropped = agents },
    };
    for (steps) |step| {
        const fresh_stats = try submitGoalWalk(&fresh, &requesters, step.walk, agents, step.config);
        try std.testing.expectEqual(step.accepted, fresh_stats.accepted_requests);
        try std.testing.expectEqual(step.dropped, fresh_stats.dropped_requests);
        inline for (.{ &grown, &held }) |system| {
            const stats = try submitGoalWalk(system, &requesters, step.walk, agents, step.config);
            try expectGatedStateEqual(&fresh, fresh_stats, system, stats);
        }
    }
    // The last goals got no tally, and the step-5 tallies decayed away.
    try std.testing.expectEqual(@as(usize, 0), fresh.group_requests.items.len);
    // No eviction ran in the smallest cache.
    try std.testing.expect(fresh.completed.count() < fresh.completed.logicalCapacity());
}

test "pathfinding a backlog past 512 agents admits the same requests at any capacity history" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agents = 600;
    var requesters: [agents]EntityId = undefined;
    for (&requesters) |*slot| slot.* = try data.createEntity();

    // 64x64 cells; capacity 600 freshly sized and 800 grown through 400.
    var fresh = try gateTestSystem(&data, 2048, 2048);
    defer fresh.deinit();
    try fresh.growForAgentCount(agents);
    var grown = try gateTestSystem(&data, 2048, 2048);
    defer grown.deinit();
    try grown.growForAgentCount(400);
    try grown.growForAgentCount(agents);
    try std.testing.expectEqual(@as(usize, 600), fresh.effective_agent_capacity);
    try std.testing.expectEqual(@as(usize, 800), grown.effective_agent_capacity);

    const Step = struct { walk: GoalWalk, accepted: usize, dropped: usize };
    const steps = [_]Step{
        // 600 goals: 512 solve and 88 wait.
        .{ .walk = .{ .width_cells = 64 }, .accepted = agents, .dropped = 0 },
        // 600 new goals: the gate admits 512 beside the 88 waiting.
        .{ .walk = .{ .first = agents, .width_cells = 64 }, .accepted = 512, .dropped = 88 },
        // The same goals: the 88 dropped ones are accepted.
        .{ .walk = .{ .first = agents, .width_cells = 64 }, .accepted = 88, .dropped = 0 },
    };
    for (steps) |step| {
        const fresh_stats = try submitGoalWalk(&fresh, &requesters, step.walk, agents, .{});
        try std.testing.expectEqual(step.accepted, fresh_stats.accepted_requests);
        try std.testing.expectEqual(step.dropped, fresh_stats.dropped_requests);
        const grown_stats = try submitGoalWalk(&grown, &requesters, step.walk, agents, .{});
        try expectGatedStateEqual(&fresh, fresh_stats, &grown, grown_stats);
    }
    try std.testing.expect(fresh.completed.count() < fresh.completed.logicalCapacity());
}

test "pathfinding an update past the agent ceiling raises it past the crowd and restores it on OOM (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [12]EntityId = undefined;
    for (&requesters) |*slot| slot.* = try data.createEntity();
    const no_admission = PathfindingConfig{ .max_solve_admissions_per_step = 0 };

    // Sweep the failure point across the update's allocations; only its grow allocates.
    var failed_updates: usize = 0;
    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var system = try gateTestSystem(&data, 512, min_capacity_floor);
        defer system.deinit();
        // Eight goals pending at the ceiling.
        _ = try submitGoalWalk(&system, requesters[0..min_capacity_floor], .{}, min_capacity_floor, no_admission);
        try std.testing.expectEqual(min_capacity_floor, system.pending.len);
        const real_allocator = system.allocator;
        var failing = std.testing.FailingAllocator.init(real_allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        system.allocator = failing.allocator();
        const result = submitGoalWalk(&system, &requesters, .{}, requesters.len, no_admission);
        system.allocator = real_allocator;
        if (result) |stats| {
            // The ceiling rises 1.5x past the crowd (18); the pools double from 8 to 16.
            try std.testing.expectEqual(PathfindingSystem.grownAgentBudget(requesters.len), system.agentBudget());
            try std.testing.expectEqual(@as(usize, 18), system.agentBudget());
            try std.testing.expectEqual(@as(usize, 16), system.effective_agent_capacity);
            try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
            try std.testing.expectEqual(requesters.len - min_capacity_floor, stats.accepted_requests);
            try std.testing.expectEqual(requesters.len, system.pending.len);
            try expectPoolsFitLogicalCaps(&system);
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_updates += 1;
            // The ceiling, the limits, and the queue are as before the update.
            try std.testing.expectEqual(min_capacity_floor, system.agentBudget());
            try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
            try expectPoolsFitLogicalCaps(&system);
            try std.testing.expectEqual(min_capacity_floor, system.pending.len);
            for (0..min_capacity_floor) |index| {
                try std.testing.expectEqual(requesters[index], system.pending.at(index).entity);
                try std.testing.expect(system.pending_keys.contains(system.pending.at(index).key));
            }
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failed_updates > 1);
}

test "pathfinding pending-gate drops are independent of world size" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [40]EntityId = undefined;
    for (&requesters) |*slot| slot.* = try data.createEntity();

    // One 16-cell nav chunk (16x16 cells) vs four (32x32 cells), the same goals in both.
    var small = try intakeTestSystem(&data, 512);
    defer small.deinit();
    var large = try intakeTestSystem(&data, 1024);
    defer large.deinit();
    try std.testing.expectEqual(@as(usize, 16 * 16), small.graph.cellCount());
    try std.testing.expectEqual(@as(usize, 32 * 32), large.graph.cellCount());

    // 40 goals fill the pending gate at 40 agents; the next 40 drop.
    const no_admission = PathfindingConfig{ .max_solve_admissions_per_step = 0 };
    inline for (.{ &small, &large }) |system| {
        const fill = try submitGoalWalk(system, &requesters, .{}, requesters.len, no_admission);
        try std.testing.expectEqual(requesters.len, fill.accepted_requests);
        const past_gate = try submitGoalWalk(system, &requesters, .{ .first = requesters.len }, requesters.len, no_admission);
        try std.testing.expectEqual(requesters.len, past_gate.dropped_requests);
        try std.testing.expectEqual(@as(usize, 0), past_gate.accepted_requests);
    }
}

// Empties every request and cached result, keeping the group fields.
fn clearRequestsKeepingFields(system: *PathfindingSystem) void {
    clearPending(&system.pending);
    system.pending_keys.clear();
    system.group_requests.clearRetainingCapacity();
    system.group_key_map.clear();
    publish.clearCompleted(system);
}

/// Every pool the intake/solve/publish paths `appendAssumeCapacity` into fits the
/// committed logical limits.
fn expectPoolsFitLogicalCaps(system: *const PathfindingSystem) !void {
    const cap = system.capacity;
    const limits = system.limits;
    try std.testing.expect(system.pending.buffer.len >= limits.pending_requests);
    try std.testing.expect(system.intake_records.capacity >= limits.frame_requests);
    try std.testing.expect(system.intake_group_counts.capacity >= limits.frame_requests);
    try std.testing.expect(system.intake_tallies.capacity >= maxRangeCount(limits.frame_requests, intake_range_alignment_items));
    try std.testing.expect(system.solve_results.capacity >= limits.solves_per_step);
    try std.testing.expect(system.solve_indices.capacity >= limits.solves_per_step);
    try std.testing.expect(system.solved_paths.capacity >= limits.solves_per_step);
    try std.testing.expect(system.rotate_back_scratch.capacity >= limits.solves_per_step);
    try std.testing.expect(system.group_requests.capacity >= limits.solves_per_step);
    try std.testing.expectEqual(types.resultBlockWords(cap.max_explored_nodes, cap.max_stitched_path_cells), system.stripe_words);
    try std.testing.expect(system.worker_path_pool.items.len >= limits.solves_per_step * system.stripe_words);
    try std.testing.expect(system.completed.long_block_words >= system.stripe_words);
    try std.testing.expect(system.solve_tier1_slot.capacity >= limits.solves_per_step);
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
    try std.testing.expectEqual(limits.pending_requests, system.effective_agent_capacity);
}

/// Submits `count` requests with distinct goals (one goal cell each), admission budget 0.
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
    return system.updateSerial(&stream, agent_count, .{ .max_solve_admissions_per_step = 0 });
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
    var succeeded = false;
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
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_grows += 1;
            // Falls back to the pre-grow limits, which every pool still fits.
            try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
            try std.testing.expectEqual(min_capacity_floor, system.limits.frame_requests);
            try expectPoolsFitLogicalCaps(&system);
            // The next update runs safely at the old limits (no grow at 8 agents).
            const stats = try submitDistinctGoalBurst(&system, requesters[0..min_capacity_floor], min_capacity_floor, min_capacity_floor);
            try std.testing.expectEqual(@as(usize, 0), stats.dropped_requests);
            try std.testing.expectEqual(min_capacity_floor, stats.accepted_requests);
        }
    }
    try std.testing.expect(succeeded);
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

// A full-height wall with a single far gap forces the longest possible detour — the
// shape of the reported water/lake FPS-collapse bug. Runs the SAME scenario at two
// scales against the corrected fixed-budget two-tier ladder, asserting a DIFFERENT
// expected outcome at each: the reported bug's exact scale must solve cleanly, and a
// genuinely harder one must gracefully degrade (its tier-1 stitch past the cell cap publishes
// a partial prefix) — proving graceful degradation actually triggers rather than the fixed
// tier-1 budget happening to be big enough for every case.
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
        if (stats.available_results != 0 or stats.partial_results != 0 or stats.escalated_dropped != 0) {
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
    try std.testing.expectEqual(@as(usize, 1), harder.partial_results);
    try std.testing.expectEqual(@as(usize, 0), harder.escalated_dropped);
    try std.testing.expect(harder.budget_exhausted <= 2);
}

// The reported-bug-scale detour above solves cleanly under the default segment cap
// (its corridor needs more than one stitched segment, but comfortably under
// default_max_stitch_segments). Forcing max_stitch_segments down to 1 must make that
// SAME scale degrade the same graceful way the harder scale degrades above (a partial
// prefix of one segment) — proving max_stitch_segments is a genuine, independently-enforced
// ceiling on stitching work, not merely inferred from the abstract-node or stitched-cell
// budgets.
test "pathfinding max_stitch_segments bounds stitching independent of corridor length" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.max_stitch_segments = 1;
    try system.reserve(capacity);
    const result = try runLakeDetourScenario(&system, 256, 5);
    try std.testing.expectEqual(@as(usize, 0), result.available_results);
    try std.testing.expectEqual(@as(usize, 1), result.partial_results);
    try std.testing.expectEqual(@as(usize, 0), result.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 1), result.max_stitch_segments_observed);
}

// ---- Partial results ---------------------------------------------------------------

// An open one-level strip of 128 x 16 cells in 16-cell chunks: a route along it leaves its
// start's chunk, so it stitches through the abstract search.
const partial_strip_width: usize = 128;
const partial_strip_height: usize = 16;
const partial_start = tileCenter(1, 8);
const partial_goal = tileCenter(120, 8);

// Tier-0 and tier-1 stitched caps far below the strip's route: tier 0 promotes, tier 1
// publishes a 32-cell prefix.
fn partialCapacity() PathfindingCapacity {
    var capacity = baselineCapacity();
    capacity.tier0_stitched_cell_cap = 16;
    capacity.max_stitched_path_cells = 32;
    return capacity;
}

fn partialStripSystem(data: *DataSystem, capacity: PathfindingCapacity) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    const side: f32 = 32;
    try system.rebuildStaticNavGrid(data, @as(f32, @floatFromInt(partial_strip_width)) * side, @as(f32, @floatFromInt(partial_strip_height)) * side, side);
    return system;
}

// The cached result for `goal` on level 0.
fn cachedResult(system: *const PathfindingSystem, goal: math.Vec2) ?types.PathResult {
    const key = system.graph.keyForWorld(0, goal, .default) orelse return null;
    const slot = system.completed.freshSlotIndex(key, system.step_counter, types.default_cache_ttl_steps) orelse return null;
    return system.completed.resultAt(slot);
}

fn cellCenterOf(system: *const PathfindingSystem, cell: u32) math.Vec2 {
    return system.graph.grid(0).?.cellCenter(cell);
}

// One request from `start` for `goal` (its tier-0 attempt), then a step without requests
// (the tier-1 attempt when tier 0 promoted). Returns the second step's stats.
fn solveHop(system: *PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2) !PathfindingStats {
    const first = try solveStep(system, requester, start, goal);
    if (first.budget_exhausted == 0) return first;
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    return system.updateSerial(&empty, 8, .{});
}

test "a tier-1 stitch past its cell cap publishes the uncapped stitch's prefix as partial" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = try partialStripSystem(&data, partialCapacity());
    defer system.deinit();
    var reference_capacity = baselineCapacity();
    reference_capacity.max_stitched_path_cells = 256;
    var reference = try partialStripSystem(&data, reference_capacity);
    defer reference.deinit();

    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&reference, requester, partial_start, partial_goal)).available_results);
    const full = cachedStitched(&reference, 0, partial_goal);
    try std.testing.expect(full.len() > 32);

    const first = try solveStep(&system, requester, partial_start, partial_goal);
    try std.testing.expectEqual(@as(usize, 1), first.budget_exhausted);
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(0).tier);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const second = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), second.escalated_solves);
    try std.testing.expectEqual(@as(usize, 1), second.partial_results);
    try std.testing.expectEqual(@as(usize, 0), second.available_results);
    try std.testing.expectEqual(@as(usize, 0), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.solved_requests);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expect(!system.pending_keys.contains(system.graph.keyForWorld(0, partial_goal, .default).?));

    const prefix = cachedStitched(&system, 0, partial_goal);
    try std.testing.expectEqual(@as(usize, 32), prefix.len());
    try std.testing.expectEqualSlices(u32, full.cells[0..32], prefix.cells);
    try std.testing.expectEqualSlices(u16, full.levels[0..32], prefix.levels);
    const result = cachedResult(&system, partial_goal).?;
    const goal_cell: u32 = @intCast(system.graph.grid(0).?.indexForCell(result.key.goal).?);
    try std.testing.expectEqual(goal_cell, result.goal_cell);
    try std.testing.expect(result.isPartial());
    try std.testing.expect(!cachedResult(&reference, partial_goal).?.isPartial());
}

test "a partial answers no request from inside its end window" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = try partialStripSystem(&data, partialCapacity());
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try solveHop(&system, requester, partial_start, partial_goal)).partial_results);
    const hop = cachedResult(&system, partial_goal).?;
    const end_position = cellCenterOf(&system, hop.end.cell);

    const at_start = system.statusForWorld(0, partial_start, 0, partial_goal, .default, null);
    try std.testing.expectEqual(PathStatus.partial, at_start.status);
    try std.testing.expect(!at_start.refresh);
    const at_end = system.statusForWorld(0, end_position, 0, partial_goal, .default, null);
    try std.testing.expectEqual(PathStatus.partial, at_end.status);
    try std.testing.expect(at_end.refresh);

    // From the start (outside the window): served by the partial.
    const from_start = try solveStep(&system, requester, partial_start, partial_goal);
    try std.testing.expectEqual(@as(usize, 1), from_start.cache_hits);
    try std.testing.expectEqual(@as(usize, 0), from_start.accepted_requests);
    try std.testing.expectEqual(@as(usize, 0), from_start.solve_admissions);

    // From the end (inside the window): a new request, its tier-0 attempt promoting.
    const from_end = try solveStep(&system, requester, end_position, partial_goal);
    try std.testing.expectEqual(@as(usize, 1), from_end.accepted_requests);
    try std.testing.expectEqual(@as(usize, 0), from_end.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), from_end.budget_exhausted);
    // The old partial still serves while the hop solves.
    try std.testing.expectEqual(PathStatus.partial, system.statusForWorld(0, end_position, 0, partial_goal, .default, null).status);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try system.updateSerial(&empty, 8, .{})).partial_results);

    const next = cachedResult(&system, partial_goal).?;
    try std.testing.expectEqual(hop.end, cachedStitched(&system, 0, partial_goal).at(0));
    try std.testing.expect(!types.inPartialRefreshWindow(system.graph.chunkGeometry(), hop.end, next.end.level, next.end.cell));
}

test "an agent reaches the goal through partial hops" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = try partialStripSystem(&data, partialCapacity());
    defer system.deinit();
    const capacity = partialCapacity();
    const window = system.graph.chunkGeometry().chunk_tiles;
    // The route runs 119 cells along the strip; each hop advances past its start's window.
    const route_cells: usize = 119;
    const hop_bound = (route_cells + capacity.max_stitched_path_cells - window - 1) / (capacity.max_stitched_path_cells - window) + 1;
    var position = partial_start;
    var hops: usize = 0;
    while (true) {
        _ = try solveHop(&system, requester, position, partial_goal);
        hops += 1;
        const view = system.statusForWorld(0, position, 0, partial_goal, .default, null);
        if (view.status == .available) break;
        try std.testing.expectEqual(PathStatus.partial, view.status);
        if (hops >= hop_bound) return error.TestUnexpectedResult;
        position = cellCenterOf(&system, cachedResult(&system, partial_goal).?.end.cell);
        try std.testing.expect(system.statusForWorld(0, position, 0, partial_goal, .default, null).refresh);
    }
    try std.testing.expect(hops > 2);
    const last = cachedResult(&system, partial_goal).?;
    try std.testing.expect(!last.isPartial());
    try std.testing.expectEqual(last.goal_cell, last.end.cell);
}

test "a segment-cap prefix at tier 1 is partial; a segment node-budget spill still drops after two attempts" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var reference_capacity = baselineCapacity();
    reference_capacity.max_stitched_path_cells = 256;
    var reference = try partialStripSystem(&data, reference_capacity);
    defer reference.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&reference, requester, partial_start, partial_goal)).available_results);
    const full = cachedStitched(&reference, 0, partial_goal);

    // Four segment searches leave the start; the fifth is refused.
    var segment_capacity = reference_capacity;
    segment_capacity.max_stitch_segments = 4;
    var segments = try partialStripSystem(&data, segment_capacity);
    defer segments.deinit();
    const capped = try solveHop(&segments, requester, partial_start, partial_goal);
    try std.testing.expectEqual(@as(usize, 1), capped.partial_results);
    try std.testing.expectEqual(@as(usize, 0), capped.escalated_dropped);
    const prefix = cachedStitched(&segments, 0, partial_goal);
    try std.testing.expect(prefix.len() > 1 and prefix.len() < full.len());
    try std.testing.expectEqualSlices(u32, full.cells[0..prefix.len()], prefix.cells);
    try std.testing.expect(cachedResult(&segments, partial_goal).?.isPartial());

    // A wall across the third chunk, open only at its bottom row: the stitch reaches past the
    // start's window before that chunk's segment search spends its node budget.
    var walled_data = DataSystem.init(std.testing.allocator);
    defer walled_data.deinit();
    const walled_requester = try addNavBody(&walled_data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    for (0..partial_strip_height - 1) |y| {
        _ = try addNavBody(&walled_data, .{ .x = 40 * 32, .y = @as(f32, @floatFromInt(y)) * 32 }, .{ .x = 32, .y = 32 }, true);
    }
    var spill_capacity = reference_capacity;
    spill_capacity.max_explored_nodes = 64;
    var spill = try partialStripSystem(&walled_data, spill_capacity);
    defer spill.deinit();
    const first = try solveStep(&spill, walled_requester, partial_start, partial_goal);
    try std.testing.expectEqual(@as(usize, 1), first.budget_exhausted);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const second = try spill.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), second.partial_results);
    // The tier-1 stitch had left the start (and its window) when it spilled.
    const spilled = spill.tier1_scratch.items[0].corridor.stitched.items;
    const start_index = spill.graph.grid(0).?.indexForCell(spill.graph.grid(0).?.worldToCellClamped(partial_start)).?;
    try std.testing.expect(!types.inPartialRefreshWindow(spill.graph.chunkGeometry(), spilled[spilled.len - 1], 0, start_index));
    try std.testing.expectEqual(PathStatus.missing, spill.statusForWorld(0, partial_start, 0, partial_goal, .default, null).status);
}

test "a route folding back around a wall reaches its goal through a partial that ends near its start" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    // A one-cell wall on row 16 from x = 0 to 31 of a 48 x 33-cell level: start and goal sit
    // on either side of it, two cells apart, and the route turns at its open end.
    for (0..32) |x| {
        _ = try addNavBody(&data, .{ .x = @as(f32, @floatFromInt(x)) * 32 + 1, .y = 16 * 32 + 1 }, .{ .x = 30, .y = 30 }, true);
    }
    var capacity = baselineCapacity();
    capacity.tier0_stitched_cell_cap = 16;
    capacity.max_stitched_path_cells = 64;
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 48 * 32, 33 * 32, 32);
    const start = tileCenter(1, 15);
    const goal = tileCenter(1, 17);
    const grid = system.graph.grid(0).?;
    const start_index = grid.indexForCell(grid.worldToCellClamped(start)).?;

    try std.testing.expectEqual(@as(usize, 1), (try solveHop(&system, requester, start, goal)).partial_results);
    const hop = cachedResult(&system, goal).?;
    // The prefix advanced its whole cap yet ends back inside its start's window.
    try std.testing.expectEqual(@as(u32, 64), hop.stitched_len);
    try std.testing.expect(types.inPartialRefreshWindow(system.graph.chunkGeometry(), hop.end, 0, start_index));
    var position = start;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        const view = system.statusForWorld(0, position, 0, goal, .default, null);
        if (view.status == .available) break;
        try std.testing.expectEqual(PathStatus.partial, view.status);
        if (hops == 4) return error.TestUnexpectedResult;
        position = cellCenterOf(&system, cachedResult(&system, goal).?.end.cell);
        _ = try solveHop(&system, requester, position, goal);
    }
    const last = cachedResult(&system, goal).?;
    try std.testing.expect(!last.isPartial());
}

// One request from `start` on `start_level` for `goal` on `goal_level`, then a step without
// requests. Returns the second step's stats, or the first's when it did not promote.
fn solveLevelsHop(system: *PathfindingSystem, requester: EntityId, start_level: u16, start: math.Vec2, goal_level: u16, goal: math.Vec2) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start_level = start_level, .goal_level = goal_level, .start = start, .goal = goal });
    const first = try system.updateSerial(&stream, 8, .{});
    if (first.budget_exhausted == 0) return first;
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    return system.updateSerial(&empty, 8, .{});
}

test "a partial capped at or just past a link refreshes only on its end's level, at status and intake alike" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    // Two open 16x16-cell levels in 4-cell chunks, joined by a stair beside the start.
    var world = try test_support.abstractTestWorld(&meta, 512, 512);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    try world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 2, .y = 2 }, .level_b = 1, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 5, .bidirectional = true });
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const start = tileCenter(1, 1);
    const goal = tileCenter(14, 14);

    var reference = PathfindingSystem.init(std.testing.allocator);
    defer reference.deinit();
    try reference.reserve(abstractCapacity());
    try reference.rebuildStaticNavGridWithWorld(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), (try solveLevelsHop(&reference, requester, 0, start, 1, goal)).available_results);
    const full = cachedStitched(&reference, 1, goal);
    // The jump: the first stored cell on level 1.
    const jump = std.mem.indexOfScalar(u16, full.levels, 1).?;
    try std.testing.expect(jump >= 2 and jump + 1 < full.len());

    // A cap of `jump + 1` keeps the jump's far end; a cap of `jump` stops at the jump itself.
    for ([_]usize{ jump + 1, jump }) |cap| {
        var capacity = abstractCapacity();
        capacity.tier0_stitched_cell_cap = cap;
        capacity.max_stitched_path_cells = cap;
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        try std.testing.expectEqual(@as(usize, 1), (try solveLevelsHop(&system, requester, 0, start, 1, goal)).partial_results);
        const prefix = cachedStitched(&system, 1, goal);
        try std.testing.expectEqual(cap, prefix.len());
        try std.testing.expectEqualSlices(u32, full.cells[0..cap], prefix.cells);
        try std.testing.expectEqualSlices(u16, full.levels[0..cap], prefix.levels);
        const end = prefix.at(cap - 1);
        const end_position = system.graph.grid(end.level).?.cellCenter(end.cell);
        const past_jump = cap == jump + 1;
        try std.testing.expectEqual(@as(u16, if (past_jump) 1 else 0), end.level);

        // At the start, on level 0: a refresh only when the end lies on level 0.
        const at_start = system.statusForWorld(0, start, 1, goal, .default, null);
        try std.testing.expectEqual(PathStatus.partial, at_start.status);
        try std.testing.expectEqual(!past_jump, at_start.refresh);
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try appendPathRequest(&stream, .{ .entity = requester, .start_level = 0, .goal_level = 1, .start = start, .goal = goal });
        const from_start = try system.updateSerial(&stream, 8, .{});
        try std.testing.expectEqual(@as(usize, @intFromBool(at_start.refresh)), from_start.accepted_requests);
        try std.testing.expectEqual(@as(usize, @intFromBool(!at_start.refresh)), from_start.cache_hits);
        if (!past_jump) continue;

        // At the far end, on level 1: a refresh, and a request re-solves.
        const at_end = system.statusForWorld(1, end_position, 1, goal, .default, null);
        try std.testing.expectEqual(PathStatus.partial, at_end.status);
        try std.testing.expect(at_end.refresh);
        stream.clearRetainingCapacity();
        try appendPathRequest(&stream, .{ .entity = requester, .start_level = 1, .goal_level = 1, .start = end_position, .goal = goal });
        const from_end = try system.updateSerial(&stream, 8, .{});
        try std.testing.expectEqual(@as(usize, 1), from_end.accepted_requests);
        try std.testing.expectEqual(@as(usize, 0), from_end.cache_hits);
    }
}

test "status refreshes a partial exactly where intake re-solves it: one chunk side from its end, not one past" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = try partialStripSystem(&data, partialCapacity());
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try solveHop(&system, requester, partial_start, partial_goal)).partial_results);
    const end = cachedResult(&system, partial_goal).?.end;
    const side = system.graph.chunkGeometry().chunk_tiles;
    const end_x = end.cell % partial_strip_width;
    const end_y = end.cell / partial_strip_width;
    try std.testing.expect(end_x > side);
    // One past the window first: its hit leaves the cache as it was.
    for ([_]usize{ side + 1, side }) |distance| {
        const position = tileCenter(@intCast(end_x - distance), @intCast(end_y));
        const view = system.statusForWorld(0, position, 0, partial_goal, .default, null);
        try std.testing.expectEqual(PathStatus.partial, view.status);
        try std.testing.expectEqual(distance == side, view.refresh);
        const stats = try solveStep(&system, requester, position, partial_goal);
        try std.testing.expectEqual(@as(usize, @intFromBool(view.refresh)), stats.accepted_requests);
        try std.testing.expectEqual(@as(usize, @intFromBool(!view.refresh)), stats.cache_hits);
    }
}

test "a partial solved toward an older goal projection is not served after the projection moves" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 48);
    defer fixture.world.deinit();
    // A 5x5 block around the goal key (20, 20): its projection is the ring-3 corner (17, 17).
    for (18..23) |y| {
        for (18..23) |x| _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), @intCast(y), fixture.tree);
    }
    const requester = try data.createEntity();
    var capacity = abstractCapacity();
    capacity.max_stitched_path_cells = 8;
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &fixture.world, null);
    try system.growForAgentCount(16);
    const start = tileCenter(2, 2);
    const goal = tileCenter(20, 20);
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const grid = system.graph.grid(0).?;

    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, start, goal, .{})).budget_exhausted);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try system.updateSerial(&empty, 16, .{})).partial_results);
    const hop = system.completed.resultAt(system.completed.slotIndex(key).?);
    try std.testing.expect(hop.isPartial());
    try std.testing.expectEqual(@as(u32, 17 * 48 + 17), hop.goal_cell);
    try std.testing.expectEqual(PathStatus.partial, system.statusForWorld(0, start, 0, goal, .default, null).status);

    // A notch to the key's neighbour (20, 19) moves the projection there; the partial stays.
    try setRegistryCells(&system, &fixture, &.{ .{ 20, 18 }, .{ 20, 19 } }, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(system.completed.slotIndex(key) != null);
    try std.testing.expectEqual(@as(?usize, 19 * 48 + 20), system.liveGoal(key, grid).cell);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);
    const again = try solveFrom(&system, requester, start, goal, .{});
    try std.testing.expectEqual(@as(usize, 0), again.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), again.accepted_requests);
}

// The partial strip under abstract caps short of its route: tier 0 claims at most two nodes and
// tier 1 at most `nodes`, so a tier-1 search far from the goal saturates.
fn saturatingStripCapacity(nodes: usize) PathfindingCapacity {
    var capacity = baselineCapacity();
    capacity.tier0_abstract_node_cap = 2;
    capacity.max_abstract_nodes = nodes;
    return capacity;
}

// The search's estimate on the strip (one level, no links): the octile from `cell` to `goal`.
fn stripEstimate(system: *const PathfindingSystem, cell: u32, goal: u32) u32 {
    const width = system.graph.geometry.width;
    return types.octileU32(cell % width, cell / width, goal % width, goal / width);
}

fn stripCellOf(system: *const PathfindingSystem, position: math.Vec2) u32 {
    const grid = system.graph.grid(0).?;
    // In range: a strip cell index.
    return @intCast(grid.indexForCell(grid.worldToCellClamped(position)).?);
}

test "a saturated tier-1 search publishes a partial ending on its least-estimate node, and hops from each end reach the goal with a strictly falling estimate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = try partialStripSystem(&data, saturatingStripCapacity(6));
    defer system.deinit();
    const goal_cell = stripCellOf(&system, partial_goal);
    var position = partial_start;
    var start_cell = stripCellOf(&system, position);
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops == 16) return error.TestUnexpectedResult;
        const stats = try solveHop(&system, requester, position, partial_goal);
        if (stats.available_results == 1) break;
        // The saturated tier-1 search publishes instead of dropping.
        try std.testing.expectEqual(@as(usize, 1), stats.escalated_solves);
        try std.testing.expectEqual(@as(usize, 1), stats.partial_results);
        try std.testing.expectEqual(@as(usize, 0), stats.escalated_dropped);
        const hop = cachedResult(&system, partial_goal).?;
        try std.testing.expect(hop.isPartial());
        // Its end is the corridor's last node, the least-estimate node the search expanded.
        const corridor = system.tier1_scratch.items[0].corridor.abstract.corridor.items;
        try std.testing.expectEqual(types.packRef(0, hop.end.cell), corridor[corridor.len - 1]);
        try std.testing.expect(stripEstimate(&system, hop.end.cell, goal_cell) < stripEstimate(&system, start_cell, goal_cell));
        try std.testing.expectEqual(PathStatus.partial, system.statusForWorld(0, position, 0, partial_goal, .default, null).status);
        start_cell = hop.end.cell;
        position = cellCenterOf(&system, start_cell);
    }
    try std.testing.expect(hops >= 2);
    const last = cachedResult(&system, partial_goal).?;
    try std.testing.expect(!last.isPartial());
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, position, 0, partial_goal, .default, null).status);
}

test "a saturated tier-1 search with no expanded node below its start's estimate still drops to missing" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    // A wall on column 32 open only on the bottom row: from (31, 8), right against it, every
    // node the capped search expands lies farther from the goal than the start.
    for (0..partial_strip_height - 1) |y| {
        _ = try addNavBody(&data, .{ .x = 32 * 32 + 1, .y = @as(f32, @floatFromInt(y)) * 32 + 1 }, .{ .x = 30, .y = 30 }, true);
    }
    var system = try partialStripSystem(&data, saturatingStripCapacity(3));
    defer system.deinit();
    const start = tileCenter(31, 8);
    const first = try solveStep(&system, requester, start, partial_goal);
    try std.testing.expectEqual(@as(usize, 1), first.budget_exhausted);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const second = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), second.escalated_solves);
    try std.testing.expectEqual(@as(usize, 1), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), second.partial_results);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, partial_goal, .default, null).status);
    // The search expanded nodes, none of them below the start's estimate.
    const abstract = &system.tier1_scratch.items[0].corridor.abstract;
    const start_h = stripEstimate(&system, stripCellOf(&system, start), stripCellOf(&system, partial_goal));
    var expanded: usize = 0;
    for (abstract.slots) |slot| {
        if (slot.stamp >> 1 != abstract.generation or slot.stamp & 1 == 0) continue;
        expanded += 1;
        try std.testing.expect(types.octileU32(slot.x, slot.y, 120, 8) >= start_h);
    }
    try std.testing.expect(expanded >= 1);
}

// A 64 x 64-cell level with a wall on column 32 open only on row 0.
fn northGapSystem(data: *DataSystem, abstract_nodes: usize, stitched_cells: usize) !PathfindingSystem {
    for (1..64) |y| {
        _ = try addNavBody(data, .{ .x = 32 * 32 + 1, .y = @as(f32, @floatFromInt(y)) * 32 + 1 }, .{ .x = 30, .y = 30 }, true);
    }
    var capacity = baselineCapacity();
    capacity.tier0_abstract_node_cap = 2;
    capacity.max_abstract_nodes = abstract_nodes;
    capacity.max_stitched_path_cells = stitched_cells;
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, 64 * 32, 64 * 32, 32);
    return system;
}

// The estimate from cell `cell` of a 64-cell-wide level to (60, 56), the north-gap goal.
fn northGapEstimate(cell: u32) u32 {
    return types.octileU32(cell % 64, cell / 64, 60, 56);
}

test "a capped stitch toward the least-estimate node is cut to its last cell below the start's estimate, and drops when none lies past the start" {
    // Tier-1 caps of 32 abstract nodes, which saturate past the wall, and 40 stitched cells,
    // which stop the prefix on its climb to the gap; the reference holds the whole stitch.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const stitched_cap: usize = 40;
    var system = try northGapSystem(&data, 32, stitched_cap);
    defer system.deinit();
    var reference = try northGapSystem(&data, 32, 2048);
    defer reference.deinit();
    const goal = tileCenter(60, 56);

    // From (20, 56) the stitch first nears the goal, then climbs above the start's estimate.
    const descending = tileCenter(20, 56);
    const descending_h = northGapEstimate(stripCellOf(&system, descending));
    try std.testing.expectEqual(@as(usize, 1), (try solveHop(&reference, requester, descending, goal)).partial_results);
    const whole = cachedStitched(&reference, 0, goal);
    try std.testing.expect(whole.len() > stitched_cap);
    try std.testing.expect(northGapEstimate(whole.cells[whole.len() - 1]) < descending_h);
    var last_below: usize = 0;
    for (1..stitched_cap) |index| {
        if (northGapEstimate(whole.cells[index]) < descending_h) last_below = index;
    }
    // The capped prefix ends above the start's estimate, with a cell below it earlier.
    try std.testing.expect(northGapEstimate(whole.cells[stitched_cap - 1]) >= descending_h);
    try std.testing.expect(last_below > 0 and last_below + 1 < stitched_cap);
    const cut_stats = try solveHop(&system, requester, descending, goal);
    try std.testing.expectEqual(@as(usize, 1), cut_stats.partial_results);
    try std.testing.expectEqual(@as(usize, 0), cut_stats.escalated_dropped);
    const cut = cachedStitched(&system, 0, goal);
    try std.testing.expectEqualSlices(u32, whole.cells[0 .. last_below + 1], cut.cells);

    // From (31, 56), against the wall, every cell of the capped prefix past the start lies at or
    // above the start's estimate, though the whole stitch ends below it.
    // Dropped caches: a cached partial would serve this start.
    publish.clearCompleted(&reference);
    publish.clearCompleted(&system);
    const climbing = tileCenter(31, 56);
    const climbing_h = northGapEstimate(stripCellOf(&system, climbing));
    try std.testing.expectEqual(@as(usize, 1), (try solveHop(&reference, requester, climbing, goal)).partial_results);
    const climb = cachedStitched(&reference, 0, goal);
    try std.testing.expect(northGapEstimate(climb.cells[climb.len() - 1]) < climbing_h);
    for (climb.cells[1..stitched_cap]) |cell| try std.testing.expect(northGapEstimate(cell) >= climbing_h);
    const dropped = try solveHop(&system, requester, climbing, goal);
    try std.testing.expectEqual(@as(usize, 1), dropped.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), dropped.partial_results);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, climbing, 0, goal, .default, null).status);
}

test "threaded least-estimate partials equal serial for any range size and worker count" {
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

    // Four abstract nodes per attempt: every search saturates; each tier-1 one publishes toward
    // its least-estimate node and each tier-0 one promotes.
    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 16;
    capacity.max_escalated_solves_per_step = 4;
    capacity.max_abstract_nodes = 4;
    const tiers = [_]u8{ 0, 1, 0, 1, 0, 1, 0, 1 };
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(capacity);
    try serial.rebuildStaticNavGridWithWorld(&data, &world, null);
    try queueWithTiers(&serial, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
    const serial_stats = try serial.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 4), serial_stats.partial_results);
    try std.testing.expectEqual(@as(usize, 0), serial_stats.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 4), serial_stats.budget_exhausted);
    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        if (threads.workerThreadCount() == 0) return error.SkipZigTest;
        for ([_]usize{ 1, 2, 3 }) |items_per_range| {
            var threaded_capacity = capacity;
            threaded_capacity.worker_participant_count = threads.participantSlotCount();
            var threaded = PathfindingSystem.init(std.testing.allocator);
            defer threaded.deinit();
            try threaded.reserve(threaded_capacity);
            try threaded.rebuildStaticNavGridWithWorld(&data, &world, null);
            try queueWithTiers(&threaded, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
            const stats = try threaded.update(&empty, 8, &threads, .{ .adaptive = false, .items_per_range = items_per_range });
            if (items_per_range == 1) try std.testing.expect(!stats.solve_batch.ran_inline and stats.solve_batch.range_count > 1);
            try expectSameCache(&serial, &threaded);
            try std.testing.expectEqual(serial_stats.partial_results, stats.partial_results);
            try std.testing.expectEqual(serial_stats.budget_exhausted, stats.budget_exhausted);
            try std.testing.expectEqual(serial_stats.escalated_dropped, stats.escalated_dropped);
            try std.testing.expectEqual(serial_stats.escalated_solves, stats.escalated_solves);
            try std.testing.expectEqual(serial.pending.len, threaded.pending.len);
            for (0..serial.pending.len) |index| {
                try std.testing.expect(std.meta.eql(serial.pending.at(index), threaded.pending.at(index)));
            }
        }
    }
}

// ---- Request-side stages (group_field_expand, pending ring) ----------

test "an unbuilt group field holds no memory after reserve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(stallingFieldCapacity(1));
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    try std.testing.expectEqual(@as(usize, 4), system.group_fields.items.len);
    for (system.group_fields.items) |field| try std.testing.expectEqual(@as(usize, 0), field.residentBytes());
    try std.testing.expectEqual(@as(u64, 0), system.group_field_pool_growth.count);
}

test "a field cell cap at the slot-id width fails the reserve" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.group_field_max_cells = group_field_cell_limit;
    try std.testing.expectError(error.PathfindingBudgetTooWide, system.reserve(capacity));
    capacity.group_field_max_cells = group_field_cell_limit - 1;
    try system.reserve(capacity);
}

test "a result block past the run-start width fails the reserve with PathfindingBudgetTooWide" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    // A local path of one cell per explored node fills the block.
    capacity.max_explored_nodes = types.max_result_block_words + 1;
    try std.testing.expectError(error.PathfindingBudgetTooWide, system.reserve(capacity));
    try std.testing.expectEqual(@as(usize, 0), system.effective_agent_capacity);
    // A stitched path's cells and packed levels fill the block too.
    capacity.max_explored_nodes = 64;
    capacity.max_stitched_path_cells = types.max_result_block_words / 3 * 2 + 2;
    try std.testing.expect(types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells) > types.max_result_block_words);
    try std.testing.expectError(error.PathfindingBudgetTooWide, system.reserve(capacity));
    capacity.max_explored_nodes = types.max_result_block_words;
    capacity.max_stitched_path_cells = 2048;
    try system.reserve(capacity);
    try std.testing.expectEqual(types.max_result_block_words * system.limits.solves_per_step, system.worker_run_starts.items.len);
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
                _ = try system.updateSerial(&stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
                _ = try reference.updateSerial(&stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
                try expectGroupFieldsEqual(&reference, &system);
            }
            if (result) |_| break else |_| {}
        }
        try std.testing.expect(failed_reserves > 1);
    }
}

test "pending reserve keeps its slots down to half, reallocates below it, and an out-of-memory shrink keeps slots and entries (FailingAllocator)" {
    var pending: std.Deque(PendingRequest) = .empty;
    defer pending.deinit(std.testing.allocator);
    try reservePending(&pending, std.testing.allocator, 64);
    try std.testing.expectEqual(@as(usize, 64), pending.buffer.len);
    try reservePending(&pending, std.testing.allocator, 40);
    try std.testing.expectEqual(@as(usize, 64), pending.buffer.len);
    try reservePending(&pending, std.testing.allocator, 16);
    try std.testing.expectEqual(@as(usize, 16), pending.buffer.len);

    var requests: [3]PendingRequest = undefined;
    for (&requests, 0..) |*request, index| {
        var key = emptyKey(1);
        key.goal.x = @intCast(index);
        request.* = .{ .entity = try EntityId.init(@intCast(index), 1), .key = key, .start_level = 0, .start = .{ .x = @intCast(index), .y = 0 } };
        pending.pushBackAssumeCapacity(request.*);
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, reservePending(&pending, failing.allocator(), 4));
    try std.testing.expectEqual(@as(usize, 16), pending.buffer.len);
    try std.testing.expectEqual(requests.len, pending.len);
    for (requests, 0..) |request, index| try std.testing.expectEqualDeep(request, pending.at(index));
}

test "pending compaction keeps deferred, tail, and rotated order across a ring wrap" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    try std.testing.expectEqual(@as(usize, 8), system.pending.buffer.len);

    // Seven entries starting at physical slot 6, so logical 2.. wrap to slot 0.
    clearPending(&system.pending);
    system.pending.head = 6;
    var keys: [7]PathQueryKey = undefined;
    for (&keys, 0..) |*key, index| {
        key.* = system.graph.keyForWorld(0, cellWorld(@intCast(index), 4), .default).?;
        system.pending.pushBackAssumeCapacity(.{ .entity = try data.createEntity(), .key = key.*, .start_level = 0, .start = .{ .x = 0, .y = 0 } });
        _ = system.pending_keys.insert(key.*);
    }
    system.pending.atPtr(3).tier = 1;
    var entities: [7]EntityId = undefined;
    for (&entities, 0..) |*entity, index| entity.* = system.pending.at(index).entity;

    // Window [0, 5): 1 was not admitted (deferred); 0 solved; 2 and 4 spilled at tier 0
    // (rotate); 3 spilled at tier 1 (dropped). 5 and 6 are the tail.
    system.solve_indices.clearRetainingCapacity();
    system.solve_indices.appendSliceAssumeCapacity(&.{ 0, 2, 3, 4 });
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

test "pathfinding an elastic grow and shrink keep cached paths and pending" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = try intakeTestSystem(&data, 512);
    defer system.deinit();
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
    const no_admission = PathfindingConfig{ .max_solve_admissions_per_step = 0 };

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

    // Two requests left pending.
    const pending_goals = [_]math.Vec2{ cellWorld(9, 12), cellWorld(2, 7) };
    var pending_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer pending_stream.deinit();
    for (pending_goals) |goal| try appendIndividual(&pending_stream, requester, goal);
    _ = try system.updateSerial(&pending_stream, 40, no_admission);

    // Sustained low load shrinks back to the floor.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..system.capacity.capacity_shrink_window) |_| _ = try system.updateSerial(&empty, 1, no_admission);
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);

    for (cached_goals, before) |goal, cells| {
        var after = try cachedPathCells(&system, goal);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u32, cells.items, after.items);
        try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }
    for (pending_goals) |goal| {
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }

    // Re-requesting the cached goals hits the cache: no re-solve.
    var again = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer again.deinit();
    for (cached_goals) |goal| try appendIndividual(&again, requester, goal);
    const again_stats = try system.updateSerial(&again, 8, no_admission);
    try std.testing.expectEqual(cached_goals.len, again_stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 0), again_stats.solved_requests);
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
    try system.reserveTerrainNavRecord(system.limits.frame_requests);
    try std.testing.expectEqual(@as(u64, 0), system.nav_mark_growth.count);
    try std.testing.expect(!system.nav_mark_growth.logged);

    // Room for the marks, so only the staging and tallies grow: one growth.
    const staging_bound = system.nav_mark_staging.capacity + 1;
    try system.nav_marks.ensureTotalCapacity(system.allocator, 2 * staging_bound);
    try system.reserveTerrainNavRecord(staging_bound);
    try std.testing.expectEqual(@as(u64, 1), system.nav_mark_growth.count);
    try std.testing.expect(system.nav_mark_growth.logged);

    // All three grow in one reserve: still one growth.
    const all_bound = @max(system.nav_marks.capacity, system.nav_mark_staging.capacity) + 1;
    try system.reserveTerrainNavRecord(all_bound);
    try std.testing.expectEqual(@as(u64, 2), system.nav_mark_growth.count);
    try std.testing.expect(system.nav_mark_staging.capacity >= all_bound);
    try std.testing.expect(system.nav_mark_tallies.capacity >= maxRangeCount(all_bound, nav_mark_range_alignment_items));
}

// The terrain record's reserve, then `nav_mark` over `events`, returning its off-main time.
fn markEventsForTest(system: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) !u64 {
    try system.reserveTerrainNavRecord(events.len);
    return system.markNavEvents(events, world, thread_system);
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
        threaded.nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
        const off_main = try markEventsForTest(&threaded, events.items, &world, &threads);
        try std.testing.expect(off_main != 0);
        try std.testing.expectEqual(serial.nav_marks.items.len, threaded.nav_marks.items.len);
        for (serial.nav_marks.items, threaded.nav_marks.items) |a, b| try std.testing.expectEqual(a, b);
    }
}

test "a terrain nav record after its reserve allocates nothing inline and on a multi-worker ThreadSystem, threaded equal to inline; an out-of-memory reserve records no mark (FailingAllocator)" {
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

    var inline_system = PathfindingSystem.init(std.testing.allocator);
    defer inline_system.deinit();
    try inline_system.reserve(abstractCapacity());
    try inline_system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try inline_system.reserveTerrainNavRecord(events.items.len);
    var inline_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    inline_system.allocator = inline_failing.allocator();
    inline_system.recordTerrainNavEvents(events.items, &world, null);
    inline_system.allocator = std.testing.allocator;
    try std.testing.expect(!inline_failing.has_induced_failure);
    try std.testing.expect(inline_system.last_mark_batch.ran_inline);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    system.nav_controls = .{ .adaptive = false, .items_per_range = 8 };

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

// The stitched cells of `goal`'s cached result on `goal_level`, or an empty path.
fn cachedStitched(system: *const PathfindingSystem, goal_level: u16, goal: math.Vec2) types.StitchedView {
    const empty = types.StitchedView{ .cells = &.{}, .levels = &.{} };
    const key = system.graph.keyForWorld(goal_level, goal, .default) orelse return empty;
    const slot = system.completed.freshSlotIndex(key, system.step_counter, types.default_cache_ttl_steps) orelse return empty;
    return system.completed.stitchedSlice(slot, system.completed.resultAt(slot).stitched_len);
}

fn expectSameStitched(expected: types.StitchedView, actual: types.StitchedView) !void {
    try std.testing.expectEqualSlices(u32, expected.cells, actual.cells);
    try std.testing.expectEqualSlices(u16, expected.levels, actual.levels);
}

// Accepts one request per goal (requester `i` to `goals[i]`) without solving, then sets
// pending entry `i`'s tier to `tiers[i]` (1 = escalated).
fn queueWithTiers(system: *PathfindingSystem, requesters: []const EntityId, start: math.Vec2, goals: []const math.Vec2, tiers: []const u8) !void {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(goals.len, goals.len);
    for (requesters[0..goals.len], goals) |requester, goal| try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    _ = try system.updateSerial(&stream, 8, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(goals.len, system.pending.len);
    for (tiers, 0..) |tier, index| system.pending.atPtr(index).tier = tier;
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
            try std.testing.expectEqual(try stamped_table.hashTableSlots(budget), system.scratch_slots.items[0].slots.len);
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
        try std.testing.expectEqual(try stamped_table.hashTableSlots(tier0_nodes), scratch.corridor.abstract.slots.len);
        try std.testing.expectEqual(tier0_cells, scratch.corridor.stitched_limit);
    }
    for (system.tier1_scratch.items) |*entry| {
        try std.testing.expectEqual(capacity.max_abstract_nodes, entry.corridor.abstract.node_limit);
        try std.testing.expectEqual(try stamped_table.hashTableSlots(capacity.max_abstract_nodes), entry.corridor.abstract.slots.len);
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
        try std.testing.expect(expected.len() > 1);
        try expectSameStitched(expected, cachedStitched(&pool, 0, goal));
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

    try std.testing.expect(!stats.solve_batch.ran_inline);
    try std.testing.expect(stats.solve_batch.range_count > 1);
    try std.testing.expectEqual(@as(usize, 4), stats.escalated_solves);
    try std.testing.expectEqual(serial_stats.escalated_solves, stats.escalated_solves);
    try std.testing.expectEqual(serial_stats.available_results, stats.available_results);
    try std.testing.expectEqual(escalation_goals.len, stats.available_results);
    // Each escalated admission holds its own pool entry, in admission order.
    try std.testing.expectEqual(tiers.len, threaded.solve_tier1_slot.items.len);
    var next_entry: u32 = 0;
    for (threaded.solve_tier1_slot.items, tiers) |entry, tier| {
        if (tier == 0) {
            try std.testing.expectEqual(no_tier1_slot, entry);
        } else {
            try std.testing.expectEqual(next_entry, entry);
            next_entry += 1;
        }
    }
    for (escalation_goals) |goal| {
        const expected = cachedStitched(&serial, 0, goal);
        try std.testing.expect(expected.len() > 1);
        try expectSameStitched(expected, cachedStitched(&threaded, 0, goal));
    }

    // An 8-cell stitched cap: each tier-1 solve publishes its prefix as a partial, or drops
    // when the prefix never leaves its start, and each tier-0 solve promotes. The
    // threaded publish equals serial for any range size and worker count.
    var partial_capacity = capacity;
    partial_capacity.worker_participant_count = 1;
    partial_capacity.max_stitched_path_cells = 8;
    var partial_serial = PathfindingSystem.init(std.testing.allocator);
    defer partial_serial.deinit();
    try partial_serial.reserve(partial_capacity);
    try partial_serial.rebuildStaticNavGridWithWorld(&data, &world, null);
    try queueWithTiers(&partial_serial, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
    const partial_stats = try partial_serial.updateSerial(&empty, 8, .{});
    try std.testing.expect(partial_stats.partial_results != 0);
    try std.testing.expectEqual(@as(usize, 4), partial_stats.partial_results + partial_stats.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 4) + partial_stats.escalated_dropped, partial_stats.budget_exhausted);
    for ([_]usize{ 1, 3 }) |workers| {
        var partial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer partial_threads.deinit();
        if (partial_threads.workerThreadCount() == 0) return error.SkipZigTest;
        for ([_]usize{ 1, 2, 3 }) |items_per_range| {
            var threaded_capacity = partial_capacity;
            threaded_capacity.worker_participant_count = partial_threads.participantSlotCount();
            var partial_threaded = PathfindingSystem.init(std.testing.allocator);
            defer partial_threaded.deinit();
            try partial_threaded.reserve(threaded_capacity);
            try partial_threaded.rebuildStaticNavGridWithWorld(&data, &world, null);
            try queueWithTiers(&partial_threaded, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
            const threaded_stats = try partial_threaded.update(&empty, 8, &partial_threads, .{ .adaptive = false, .items_per_range = items_per_range });
            if (items_per_range == 1) try std.testing.expect(!threaded_stats.solve_batch.ran_inline and threaded_stats.solve_batch.range_count > 1);
            try expectSameCache(&partial_serial, &partial_threaded);
            try std.testing.expectEqual(partial_stats.partial_results, threaded_stats.partial_results);
            try std.testing.expectEqual(partial_stats.available_results, threaded_stats.available_results);
            try std.testing.expectEqual(partial_stats.budget_exhausted, threaded_stats.budget_exhausted);
            try std.testing.expectEqual(partial_stats.escalated_dropped, threaded_stats.escalated_dropped);
            try std.testing.expectEqual(partial_stats.escalated_solves, threaded_stats.escalated_solves);
            try std.testing.expectEqual(partial_serial.pending.len, partial_threaded.pending.len);
            for (0..partial_serial.pending.len) |index| {
                try std.testing.expect(std.meta.eql(partial_serial.pending.at(index), partial_threaded.pending.at(index)));
            }
        }
    }
}

// Queues one request per goal from (1, 1) on level 0 to `goal_level` without solving, then
// sets the pending tiers.
fn queueCrossLevelWithTiers(system: *PathfindingSystem, requesters: []const EntityId, goal_level: u16, goals: []const math.Vec2, tiers: []const u8) !void {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(goals.len, goals.len);
    for (requesters[0..goals.len], goals) |requester, goal| try appendPathRequest(&stream, .{ .entity = requester, .start_level = 0, .goal_level = goal_level, .start = tileCenter(1, 1), .goal = goal });
    _ = try system.updateSerial(&stream, goals.len, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(goals.len, system.pending.len);
    for (tiers, 0..) |tier, index| system.pending.atPtr(index).tier = tier;
}

test "threaded cross-level solves equal serial, at tier 0 and through the tier-1 pool, their crossing searches included" {
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

    try std.testing.expect(!stats.solve_batch.ran_inline);
    try std.testing.expect(stats.solve_batch.range_count > 1);
    try std.testing.expectEqual(goals.len, serial_stats.available_results);
    try std.testing.expectEqual(goals.len, stats.available_results);
    var via_teleport: usize = 0;
    var via_ramps: usize = 0;
    for (goals) |goal| {
        const expected = cachedStitched(&serial, 2, goal);
        try std.testing.expect(expected.len() > 1);
        try expectSameStitched(expected, cachedStitched(&threaded, 2, goal));
        var jumps_two_levels = false;
        for (expected.levels[0 .. expected.len() - 1], expected.levels[1..]) |from, to| jumps_two_levels = jumps_two_levels or (from == 0 and to == 2);
        if (jumps_two_levels) via_teleport += 1 else via_ramps += 1;
    }
    try std.testing.expect(via_teleport > 0 and via_ramps > 0);
    // The heuristic's crossing searches ran, and their work sums alike across workers.
    try std.testing.expect(serial_stats.crossing_boxes_settled != 0);
    try std.testing.expectEqual(serial_stats.crossing_boxes_settled, stats.crossing_boxes_settled);
    try std.testing.expectEqual(serial_stats.crossing_budget_frozen, stats.crossing_budget_frozen);

    // Half the requests through the tier-1 pool, whose entries run their own crossing search.
    const tiers = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0 };
    serial.clearRuntimeState();
    threaded.clearRuntimeState();
    try queueCrossLevelWithTiers(&serial, &requesters, 2, &goals, &tiers);
    try queueCrossLevelWithTiers(&threaded, &requesters, 2, &goals, &tiers);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try empty.reserve(1, 0);
    const serial_tiered = try serial.updateSerial(&empty, 8, .{});
    const tiered = try threaded.update(&empty, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!tiered.solve_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), tiered.escalated_solves);
    try std.testing.expectEqual(goals.len, serial_tiered.available_results);
    try std.testing.expectEqual(goals.len, tiered.available_results);
    try std.testing.expectEqual(serial_tiered.crossing_boxes_settled, tiered.crossing_boxes_settled);
    // Every pool entry the step used ran its own crossing search.
    for (threaded.tier1_scratch.items[0..tiered.escalated_solves]) |*entry| try std.testing.expect(entry.corridor.abstract.crossing.settles != 0);
    for (goals) |goal| try expectSameStitched(cachedStitched(&serial, 2, goal), cachedStitched(&threaded, 2, goal));

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
    try std.testing.expect(!warmed.solve_batch.ran_inline);
    try std.testing.expectEqual(goals.len, warmed.available_results);
    for (goals) |goal| try expectSameStitched(cachedStitched(&serial, 2, goal), cachedStitched(&threaded, 2, goal));
    // And so does a warmed tier-1 re-solve through the pool.
    threaded.clearRuntimeState();
    try queueCrossLevelWithTiers(&threaded, &requesters, 2, &goals, &tiers);
    const warmed_tiered = try threaded.update(&empty, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });
    try std.testing.expectEqual(@as(usize, 4), warmed_tiered.escalated_solves);
    try std.testing.expectEqual(goals.len, warmed_tiered.available_results);
    try std.testing.expectEqual(serial_tiered.crossing_boxes_settled, warmed_tiered.crossing_boxes_settled);
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

    // The second pass's 8-cell stitched cap makes the escalated solves publish partials.
    for ([_]usize{ abstractCapacity().max_stitched_path_cells, 8 }) |stitched_cells| {
        var capacity = abstractCapacity();
        capacity.group_field_max_cells = 16;
        capacity.max_escalated_solves_per_step = 4;
        capacity.max_stitched_path_cells = stitched_cells;
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
        // Every stitched result fits its inline stripe; one warm publish sizes the path
        // registry, so after a cache clear nothing allocates.
        try queueWithTiers(&system, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
        _ = try system.update(&empty, 8, &threads, config);
        _ = try system.update(&empty, 8, &threads, config);
        system.clearRuntimeState();
        const original = system.allocator;
        system.allocator = std.testing.failing_allocator;
        system.graph.allocator = std.testing.failing_allocator;
        defer {
            system.allocator = original;
            system.graph.allocator = original;
        }
        try queueWithTiers(&system, &requesters, tileCenter(1, 1), &escalation_goals, &tiers);
        const stats = try system.update(&empty, 8, &threads, config);
        try std.testing.expect(!stats.solve_batch.ran_inline);
        try std.testing.expectEqual(@as(usize, 4), stats.escalated_solves);
        if (stitched_cells == 8) {
            try std.testing.expect(stats.partial_results != 0);
            try std.testing.expectEqual(@as(usize, 4), stats.partial_results + stats.escalated_dropped);
        } else {
            try std.testing.expectEqual(escalation_goals.len, stats.available_results);
        }
        try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    }
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
    const field = group_service.groupFieldOf(&system, key).?;
    try std.testing.expectEqual(GroupFieldState.building, field.state);
    const pushed = field.pushed_count;
    const generation = field.generation;
    const cost_column = field.columns.cost.ptr;

    try system.growForAgentCount(40);
    try std.testing.expectEqual(@as(usize, 40), system.effective_agent_capacity);
    const resized = group_service.groupFieldOf(&system, key).?;
    try std.testing.expectEqual(GroupFieldState.building, resized.state);
    try std.testing.expectEqual(pushed, resized.pushed_count);
    try std.testing.expectEqual(generation, resized.generation);
    try std.testing.expectEqual(cost_column, resized.columns.cost.ptr);
    try std.testing.expectEqual(@as(u32, 0), resized.lookup(system.graph.grid(0).?, resized.goal_index).?.cost);
    try expectPoolsFitLogicalCaps(&system);
}

// ---- Path registry, publish split, and resize ------------------------------------

const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;

// Fills `system`'s 64-entry cache with routes [0, 64), then publishes routes [64, 80) into
// the full cache inline without flushing: the flush has victims in the log and adds in
// every publish band.
fn prepareMixedFlush(system: *PathfindingSystem, requester: EntityId) !void {
    for (0..4) |batch| try solveRegistryRoutes(system, requester, 24, batch * 16, 16, 16, null, .{});
    try std.testing.expectEqual(@as(usize, 64), system.completed.count());
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (64..80) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    var stats = PathfindingStats{};
    try system.updateInline(&stream, 16, .{}, &stats);
    try std.testing.expect(stats.cache_evictions != 0);
    try std.testing.expect(system.completed.core.ownerLog().len != 0 and system.publish_ranges != 0);
}

// Logs every op kind into `system`'s owner log without flushing: a shrink to the floor's
// 32 entries (victims and renames), a re-put, and two claims on the full cache (victims);
// then removes the three claimed entries again, so after a flush the registry matches the
// cache.
fn logEveryOpKind(system: *PathfindingSystem) !void {
    try system.resizePreservingLiveState(system.capacity, 1, null);
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    var stats = PathfindingStats{};
    system.completed.core.beginPublish();
    const reput = system.completed.core.keyOf(0);
    var fresh = [_]PathQueryKey{ reput, emptyKey(system.graph.version), emptyKey(system.graph.version) };
    fresh[1].goal = .{ .x = 0, .y = 30 };
    fresh[2].goal = .{ .x = 1, .y = 30 };
    for (fresh) |key| {
        const claimed = system.completed.claim(key, 1, 0, 0, .{ .level = 0, .cell = 0 }, 0, system.step_counter, &stats);
        system.completed.destination(claimed)[0] = 0;
    }
    try std.testing.expectEqual(@as(usize, 2), stats.cache_evictions);
    for (fresh) |key| system.completed.removeAt(system.completed.slotIndex(key).?);
}

test "threaded registry flush equals serial with victims, re-puts, and renames in the log" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var systems: [2]PathfindingSystem = undefined;
    var built: usize = 0;
    defer for (systems[0..built]) |*system| system.deinit();
    for (&systems) |*system| {
        system.* = try registrySystem(&data, &fixture.world, 16);
        built += 1;
        for (0..4) |batch| try solveRegistryRoutes(system, requester, 24, batch * 16, 16, 16, null, .{});
        try std.testing.expectEqual(@as(usize, 64), system.completed.count());
        try logEveryOpKind(system);
    }
    const ops = systems[0].completed.core.ownerLog();
    var renames: usize = 0;
    for (ops) |op| renames += @intFromBool(op.new != no_owner);
    try std.testing.expect(renames != 0 and renames < ops.len);
    try std.testing.expectEqual(@as(usize, 0), systems[1].publish_ranges);
    // One unit per range: a range per unit, most with no pair starting in it.
    const units = flushUnits(ops.len, 0);
    var serial_stats = PathfindingStats{};
    const serial_batch = publish.flushRegistry(&systems[0], null, &serial_stats);
    try std.testing.expectEqual(units, serial_batch.item_count);
    var threaded_stats = PathfindingStats{};
    const stage = (StageThreads{ .thread_system = &threads, .config = fixed_threads_config }).stage(&systems[1].tuners.registry_flush);
    const batch = publish.flushRegistry(&systems[1], stage, &threaded_stats);
    try std.testing.expect(!batch.ran_inline);
    try std.testing.expectEqual(units, batch.item_count);
    try std.testing.expectEqual(units, batch.range_count);
    try std.testing.expectEqual(serial_stats.registrations_removed, threaded_stats.registrations_removed);
    try std.testing.expect(serial_stats.registrations_removed != 0);
    try expectSameRegistry(&systems[0], &systems[1]);
    for (&systems) |*system| try expectRegistryMatchesCache(system);
}

test "threaded registry flush over unit-weighted pairs equals serial across range sizes and worker counts, on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var serial = try registrySystem(&data, &fixture.world, 16);
    defer serial.deinit();
    try prepareMixedFlush(&serial, requester);
    const ops = serial.completed.core.ownerLog().len;
    var serial_stats = PathfindingStats{};
    const serial_batch = publish.flushRegistry(&serial, null, &serial_stats);
    try std.testing.expect(serial_stats.registrations_removed != 0 and serial_stats.registrations_added != 0);
    const units = flushUnits(ops, serial_stats.registrations_added);
    try std.testing.expectEqual(units, serial_batch.item_count);
    try expectRegistryMatchesCache(&serial);
    // The widest pool has more workers than pairs.
    for ([_]usize{ 1, 3, flush_pair_count + 4 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        if (threads.workerThreadCount() == 0) return error.SkipZigTest;
        var worker_ranges: usize = 0;
        // Ranges far smaller than a pair (most hold no pair start), ranges that cut pairs,
        // and two ranges of several pairs each.
        for ([_]usize{ 1, 3, 7, 40, (units + 1) / 2 }) |items_per_range| {
            var threaded = try registrySystem(&data, &fixture.world, 16);
            defer threaded.deinit();
            try prepareMixedFlush(&threaded, requester);
            var stats = PathfindingStats{};
            const config = PathfindingConfig{ .adaptive = false, .items_per_range = items_per_range };
            const stage = (StageThreads{ .thread_system = &threads, .config = config }).stage(&threaded.tuners.registry_flush);
            const batch = publish.flushRegistry(&threaded, stage, &stats);
            try std.testing.expect(!batch.ran_inline and batch.active_worker_threads != 0);
            try std.testing.expect(batch.active_worker_threads <= flush_pair_count - 1);
            worker_ranges += batch.worker_thread_ranges;
            try std.testing.expectEqual(units, batch.item_count);
            try std.testing.expectEqual((units + items_per_range - 1) / items_per_range, batch.range_count);
            try std.testing.expectEqual(serial_stats.registrations_added, stats.registrations_added);
            try std.testing.expectEqual(serial_stats.registrations_removed, stats.registrations_removed);
            try expectSameCache(&serial, &threaded);
            try expectSameRegistry(&serial, &threaded);
            try expectRegistryMatchesCache(&threaded);
        }
        try std.testing.expect(worker_ranges != 0);
    }
}

test "an elastic grow and shrink keep cached paths and registrations, and a renamed owner is evicted by a change on its path" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    try solveRegistryRoutes(&system, requester, 24, 0, 8, 8, null, .{});
    try system.growForAgentCount(40);
    try expectRegistryMatchesCache(&system);
    try solveRegistryRoutes(&system, requester, 24, 8, 30, 40, null, .{});
    try expectRegistryMatchesCache(&system);
    // The last route's owner sits past the floor's 32 entries.
    const moved_key = registryRouteKey(&system, 37, 24);
    const owner_before = system.completed.core.ownerOf(moved_key).?;
    try std.testing.expect(owner_before >= 32);
    var cells: std.ArrayList(u32) = .empty;
    defer cells.deinit(std.testing.allocator);
    try cells.appendSlice(std.testing.allocator, storedPath(&system, owner_before).cells);

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..system.capacity.capacity_shrink_window) |_| _ = try system.updateSerial(&empty, 1, .{});
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    const owner_after = system.completed.core.ownerOf(moved_key).?;
    try std.testing.expect(owner_after < 32);
    try std.testing.expectEqualSlices(u32, cells.items, storedPath(&system, owner_after).cells);
    try expectRegistryMatchesCache(&system);

    // A dig on the moved path's middle cell evicts it under its new owner id.
    const middle = cells.items[cells.items.len / 2];
    try setRegistryCells(&system, &fixture, &.{.{ @intCast(middle % 24), @intCast(middle / 24) }}, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(system.completed.slotIndex(moved_key) == null);
    try expectRegistryMatchesCache(&system);
}

test "threaded resize copy equals serial for inline and long moves, and runs on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var serial = try shrinkFixture(&data, &fixture, requester, 1);
    defer serial.deinit();
    var threaded = try shrinkFixture(&data, &fixture, requester, threads.participantSlotCount());
    defer threaded.deinit();
    // The youngest 32 survive: their records and long blocks sit past the new capacity
    // and the live long blocks' pages, so both pools move.
    var inline_moves: usize = 0;
    var long_moves: usize = 0;
    for (serial.completed.core.records.items[32..]) |record| {
        if (!record.live) continue;
        if (record.extra.long_block == std.math.maxInt(u32)) inline_moves += 1 else long_moves += 1;
    }
    try std.testing.expect(inline_moves != 0 and long_moves != 0);
    try serial.resizePreservingLiveState(serial.capacity, 1, null);
    try threaded.resizePreservingLiveState(threaded.capacity, 1, StageThreads{ .thread_system = &threads, .config = fixed_threads_config });
    try std.testing.expect(serial.last_resize_copy_batch.ran_inline);
    try std.testing.expect(!threaded.last_resize_copy_batch.ran_inline and threaded.last_resize_copy_batch.range_count > 1);
    try std.testing.expectEqual(serial.last_resize_copy_batch.item_count, threaded.last_resize_copy_batch.item_count);
    _ = publish.flushRegistry(&serial, null, null);
    _ = publish.flushRegistry(&threaded, null, null);
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
}

test "a shrink's resize copy allocates nothing after its prepare on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = try shrinkFixture(&data, &fixture, requester, threads.participantSlotCount());
    defer system.deinit();
    const capacity = system.capacity;
    // The prepares (the registry's owner heads, then the cache) and the commit; then the
    // copy, the page release, the flush with its owner head install, and the release of
    // the old heads on a failing allocator.
    try prepareTruncate(&system.path_index, 32);
    _ = try system.completed.reserve(system.allocator, 32, capacity.max_stored_path_cells, types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells), system.step_counter);
    system.registry_truncate_pending = true;
    try std.testing.expect(system.completed.pendingMoves().len > 1);
    try std.testing.expectEqual(@as(usize, 0), system.publish_ranges);
    const units = flushUnits(system.completed.core.ownerLog().len, 0);
    // Every allocation and every in-place resize fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const stage = (StageThreads{ .thread_system = &threads, .config = fixed_threads_config });
    const batch = system.runResizeCopy(stage.stage(&system.tuners.resize_copy));
    const flush = publish.flushRegistry(&system, stage.stage(&system.tuners.registry_flush), null);
    setSystemAllocators(&system, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(!batch.ran_inline and batch.range_count > 1);
    try std.testing.expect(!flush.ran_inline);
    try std.testing.expectEqual(units, flush.item_count);
    try std.testing.expectEqual(units, flush.range_count);
    for (&system.path_index) |*shard| try std.testing.expectEqual(@as(usize, 32), shard.owner_heads.capacity);
    try std.testing.expectEqual(@as(usize, 0), system.completed.pendingMoves().len);
    for (&system.path_index) |*shard| try std.testing.expectEqual(@as(usize, 32), shard.owner_heads.items.len);
    try expectRegistryMatchesCache(&system);
}

test "reserve() with live entries returns with an empty owner log and no owner past the new capacity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    for (0..3) |batch| try solveRegistryRoutes(&system, requester, 24, batch * 16, 16, 16, null, .{});
    try std.testing.expectEqual(@as(usize, 48), system.completed.count());
    // A reserve at the floor's ceiling drops back to its 32 entries, evicting and moving.
    var floor_capacity = system.capacity;
    floor_capacity.max_agent_budget = min_capacity_floor;
    try system.reserve(floor_capacity);
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    try std.testing.expectEqual(@as(usize, 0), system.completed.core.ownerLog().len);
    for (&system.path_index) |*shard| try std.testing.expect(shard.owner_heads.items.len <= 32);
    try expectRegistryMatchesCache(&system);
}

test "a resize at unchanged budgets leaves the solve-output pool unwritten" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    @memset(system.worker_path_pool.items, 0xabcd);
    @memset(system.worker_run_starts.items, 0x5a5a);
    const pool_len = system.worker_path_pool.items.len;
    try system.reserve(baselineCapacity());
    try std.testing.expectEqual(pool_len, system.worker_path_pool.items.len);
    for (system.worker_path_pool.items) |word| try std.testing.expectEqual(@as(u32, 0xabcd), word);
    for (system.worker_run_starts.items) |start| try std.testing.expectEqual(@as(u16, 0x5a5a), start);
}

// ---------------------------------------------------------------------------------------
// Reach at intake, status, and solve.
// ---------------------------------------------------------------------------------------

// Starts outside the pocket, clear of the far decoration of a 32-tile world.
fn outsideStart(index: usize) math.Vec2 {
    return tileCenter(@intCast(1 + index % 20), @intCast(pocket_cells + 4 + index / 20));
}

// Requests pocket goals [first, first + count), each from its own outside start, in one
// update (on `threads` when given).
fn requestPocketGoals(system: *PathfindingSystem, requester: EntityId, first: usize, count: usize, agent_count: usize, threads: ?*ThreadSystem, config: PathfindingConfig) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (first..first + count) |index| try appendPathRequest(&stream, .{ .entity = requester, .start = outsideStart(index - first), .goal = pocketGoal(index) });
    if (threads) |thread_system| return system.update(&stream, agent_count, thread_system, config);
    return system.updateSerial(&stream, agent_count, config);
}

test "an agent sealed in a pocket reads its goal unavailable from reach, and an agent outside still reaches it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const goal = tileCenter(20, 20);
    // The sealed-in agent's start cannot reach the goal: answered at intake, never pending.
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, pocketGoal(11), 0, goal, .default, null).status);
    const sealed = try solveFrom(&system, requester, pocketGoal(11), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), sealed.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), sealed.accepted_requests + sealed.solved_requests);
    try std.testing.expectEqual(@as(usize, 0), system.completed.count());
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
    // The outside agent reaches the same goal.
    const outside = try solveFrom(&system, requester, outsideStart(0), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), outside.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
}

test "a goal sealed in a pocket is unavailable at status and intake to agents outside it, with no pending or solve, inline and threaded, and an agent inside still gets a path" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var system = try registrySystemWith(&data, &fixture.world, 16, .{ .participants = threads.participantSlotCount() });
    defer system.deinit();
    const goal = pocketGoal(55);
    // Before any request, every outside start reads unavailable.
    for (0..6) |index| try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(index * 7), 0, goal, .default, null).status);
    const inline_stats = try solveFrom(&system, requester, outsideStart(3), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), inline_stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), inline_stats.accepted_requests + inline_stats.solved_requests + system.pending.len);
    // Threaded intake: requests to every pocket goal from outside, over several ranges.
    const threaded = try requestPocketGoals(&system, requester, 0, 16, 16, &threads, .{ .adaptive = false, .items_per_range = 8 });
    try std.testing.expect(!threaded.intake_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 16), threaded.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), threaded.accepted_requests + threaded.solved_requests + system.pending.len);
    try std.testing.expectEqual(@as(usize, 0), system.completed.count());
    // A start inside the pocket reaches it.
    const inside_start = pocketGoal(2);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, inside_start, 0, goal, .default, null).status);
    const inside = try solveFrom(&system, requester, inside_start, goal, .{});
    try std.testing.expectEqual(@as(usize, 1), inside.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, inside_start, 0, goal, .default, null).status);
    // The cached path does not answer an outside start.
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(3), 0, goal, .default, null).status);
}

// Solves `request` alone at solve ordinal 0 on the first participant's scratch.
fn solveRequest(system: *PathfindingSystem, request: PendingRequest) PathSolveResult {
    clearPending(&system.pending);
    system.pending.pushBackAssumeCapacity(request);
    var stats = PathfindingStats{};
    system.prepareSolvePhase(1, 1, &stats);
    system.resetSolvedPaths();
    // A search claims nodes in it; an answer without one leaves it empty.
    system.scratch_slots.items[0].corridor.abstract.reset();
    return solveOne(system, 0, &system.scratch_slots.items[0], 0);
}

fn pocketRequest(system: *const PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2) PendingRequest {
    const grid = system.graph.grid(0).?;
    const key = system.graph.keyForWorld(0, goal, .default).?;
    return .{ .entity = requester, .key = key, .start_level = 0, .start = grid.worldToCellClamped(start) };
}

// Abstract nodes the first participant's tier-0 search claimed in its last solve.
fn lastSolveNodes(system: *const PathfindingSystem) usize {
    return system.scratch_slots.items[0].corridor.abstract.nodes_used;
}

test "each solve outcome: an invalid graph, a missing goal level, no live goal, and no reach are unavailable without a search; a blocked start is dropped; reachable searches past their caps retry" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    {
        // An unbuilt graph.
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        const result = solveRequest(&system, .{ .entity = requester, .key = emptyKey(0), .start_level = 0, .start = .{ .x = 0, .y = 0 } });
        try std.testing.expect(result == .unavailable);
    }
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    // A goal level the graph lacks.
    var missing_level = pocketRequest(&system, requester, outsideStart(0), tileCenter(20, 20));
    missing_level.key.goal_level = 7;
    try std.testing.expect(solveRequest(&system, missing_level) == .unavailable);
    // No path from outside into the pocket: answered from reach, no search.
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, outsideStart(0), pocketGoal(12))) == .unavailable);
    try std.testing.expectEqual(@as(usize, 0), lastSolveNodes(&system));
    // No path out of the pocket either.
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, pocketGoal(12), tileCenter(20, 20))) == .unavailable);
    try std.testing.expectEqual(@as(usize, 0), lastSolveNodes(&system));
    // A blocked start.
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(pocket_cells, 3), tileCenter(20, 20))) == .start_invalid);
    // A corridor found but its stitch past the cap: retried.
    system.capacity.tier0_stitched_cell_cap = 2;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(14, 20), tileCenter(28, 28))) == .budget_exhausted);
    system.capacity.tier0_stitched_cell_cap = abstractCapacity().max_stitched_path_cells;
    // A same-component hop past the local budget: retried.
    system.capacity.max_explored_nodes = 2;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(12, 12), tileCenter(15, 15))) == .budget_exhausted);
    system.capacity.max_explored_nodes = abstractCapacity().max_explored_nodes;
    // A saturated reachable search: retried, its claims within the cap (no goal flood).
    system.capacity.tier0_abstract_node_cap = 8;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(12, 12), tileCenter(28, 28))) == .budget_exhausted);
    try std.testing.expect(lastSolveNodes(&system) <= 8);
    system.capacity.tier0_abstract_node_cap = abstractCapacity().tier0_abstract_node_cap;
    // Published: every unavailable is counted, never cached and never solved.
    clearRequestsKeepingFields(&system);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = outsideStart(0), .goal = tileCenter(20, 20), .goal_level = 0 });
    _ = try system.updateSerial(&stream, 16, .{ .max_solve_admissions_per_step = 0 });
    const goal_key = system.graph.keyForWorld(0, tileCenter(20, 20), .default).?;
    try std.testing.expect(system.pending_keys.contains(goal_key));
    // The pending request's goal sealed off before its solve.
    try setRegistryCells(&system, &fixture, &.{ .{ 19, 19 }, .{ 20, 19 }, .{ 21, 19 }, .{ 19, 20 }, .{ 21, 20 }, .{ 19, 21 }, .{ 20, 21 }, .{ 21, 21 } }, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    system.scratch_slots.items[0].corridor.abstract.reset();
    const answered = try system.updateSerial(&empty, 16, .{});
    try std.testing.expectEqual(@as(usize, 1), answered.solve_admissions);
    try std.testing.expectEqual(@as(usize, 1), answered.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), answered.solved_requests);
    try std.testing.expectEqual(@as(usize, 0), lastSolveNodes(&system));
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expectEqual(@as(?usize, null), system.completed.slotIndex(goal_key));
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(0), 0, tileCenter(20, 20), .default, null).status);
}

test "a goal with no open cell within the projection radius is unavailable for every start at status and intake, never pending or cached" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 48);
    defer fixture.world.deinit();
    for (0..40) |y| {
        for (0..40) |x| _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), @intCast(y), fixture.tree);
    }
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const goal = tileCenter(20, 20);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, tileCenter(45, 45), 0, goal, .default, null).status);
    const stats = try solveFrom(&system, requester, tileCenter(45, 45), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), stats.accepted_requests + stats.solved_requests + system.pending.len + system.completed.count());
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, tileCenter(1, 45), 0, goal, .default, null).status);
}

// A 48-tile registry world with rock over [0, 40)² except a sealed 2x2 pocket at (1..2,
// 1..2): a goal key on the blocked cell (14, 1) projects into the pocket.
fn projectionWorld(meta: *const WorldTilesetMeta) !RegistryWorld {
    var fixture = try registryWorld(meta, 48);
    errdefer fixture.world.deinit();
    for (0..40) |y| {
        for (0..40) |x| {
            if (x >= 1 and x <= 2 and y >= 1 and y <= 2) continue;
            _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), @intCast(y), fixture.tree);
        }
    }
    return fixture;
}

// Opens row 1 from x = `first` to x = 39, joining the open world east of the rock.
fn digProjectionTunnel(system: *PathfindingSystem, fixture: *RegistryWorld, first: u16) !void {
    for (first..40) |x| try setRegistryCells(system, fixture, &.{.{ @intCast(x), 1 }}, fixture.grass);
}

test "a blocked goal whose projection lies in a sealed area is unavailable at status and intake, and reads its new projection's answer after a nearer cell opens outside" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try projectionWorld(&meta);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const start = tileCenter(45, 45);
    const goal = tileCenter(14, 1);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, start, 0, goal, .default, null).status);
    const sealed = try solveFrom(&system, requester, start, goal, .{});
    try std.testing.expectEqual(@as(usize, 1), sealed.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), sealed.accepted_requests + sealed.solved_requests);
    // A tunnel stopping one cell short of the key's still-blocked cell: its projection is
    // now (15, 1), reachable.
    try digProjectionTunnel(&system, &fixture, 15);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);
    const solved = try solveFrom(&system, requester, start, goal, .{});
    try std.testing.expectEqual(@as(usize, 1), solved.available_results);
    try std.testing.expectEqual(@as(usize, 1), solved.goal_projected);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
}

test "a dig opening a sealed pocket makes its goals reachable after that step's reaction, and a fill sealing it answers a pending request at solve with no search" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const goal = pocketGoal(55);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
    // Dig a gap in the pocket's wall column.
    try setRegistryCells(&system, &fixture, &.{.{ pocket_cells, 3 }}, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
    // Accepted and left pending, then the gap filled before its solve.
    _ = try solveFrom(&system, requester, outsideStart(0), goal, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try setRegistryCells(&system, &fixture, &.{.{ pocket_cells, 3 }}, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    system.scratch_slots.items[0].corridor.abstract.reset();
    const answered = try system.updateSerial(&empty, 16, .{});
    try std.testing.expectEqual(@as(usize, 1), answered.solve_admissions);
    try std.testing.expectEqual(@as(usize, 1), answered.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), answered.solved_requests);
    try std.testing.expectEqual(@as(usize, 0), lastSolveNodes(&system));
    try std.testing.expectEqual(@as(usize, 0), system.pending.len + system.completed.count());
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
}

// The stored end of `key`'s cached result, checked against its stored path's last cell.
fn expectStoredEnd(system: *const PathfindingSystem, key: PathQueryKey) !types.StitchedCell {
    const slot = system.completed.slotIndex(key) orelse return error.TestExpectedEntry;
    const result = system.completed.resultAt(slot);
    const last = if (result.stitched_len != 0)
        system.completed.stitchedSlice(slot, result.stitched_len).at(result.stitched_len - 1)
    else
        types.StitchedCell{ .level = result.path_level, .cell = system.completed.pathSlice(slot, result.path_len)[result.path_len - 1] };
    try std.testing.expectEqual(last, result.end);
    try std.testing.expectEqual(last, system.completed.lookup(key, system.step_counter, 0).?.end);
    return result.end;
}

test "a solved result stores its path's last cell as its end, plain and stitched" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 48);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const start = tileCenter(1, 1);
    // A same-chunk hop stores a plain path; a cross-chunk route a stitched one.
    for ([_][2]u16{ .{ 2, 2 }, .{ 40, 41 } }, [_]bool{ false, true }) |goal_tile, stitched| {
        const goal = tileCenter(goal_tile[0], goal_tile[1]);
        try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, start, goal, .{})).available_results);
        const key = system.graph.keyForWorld(0, goal, .default).?;
        try std.testing.expectEqual(stitched, system.completed.find(key).?.stitched_len != 0);
        const end = try expectStoredEnd(&system, key);
        try std.testing.expectEqual(types.StitchedCell{ .level = 0, .cell = @as(u32, goal_tile[1]) * 48 + goal_tile[0] }, end);
    }
}

test "a cached path to an older projection is not served after the projection moves: status reads missing, intake makes a candidate, and the publish re-puts the entry" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 48);
    defer fixture.world.deinit();
    // A 5x5 block around the goal key (20, 20): its projection is the ring-3 corner (17, 17).
    for (18..23) |y| {
        for (18..23) |x| _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), @intCast(y), fixture.tree);
    }
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const start = tileCenter(2, 2);
    const goal = tileCenter(20, 20);
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const grid = system.graph.grid(0).?;
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, start, goal, .{})).available_results);
    try std.testing.expectEqual(@as(u32, 17 * 48 + 17), (try expectStoredEnd(&system, key)).cell);
    // A notch from the block's top edge to the key's neighbour (20, 19): the projection moves
    // there, more than one cell from the cached path.
    try setRegistryCells(&system, &fixture, &.{ .{ 20, 18 }, .{ 20, 19 } }, fixture.grass);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 0), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(key) != null);
    try std.testing.expectEqual(@as(?usize, 19 * 48 + 20), system.liveGoal(key, grid).cell);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);
    const again = try solveFrom(&system, requester, start, goal, .{});
    try std.testing.expectEqual(@as(usize, 0), again.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), again.accepted_requests);
    try std.testing.expectEqual(@as(usize, 1), again.available_results);
    try std.testing.expectEqual(@as(usize, 1), system.completed.count());
    try std.testing.expectEqual(@as(u32, 19 * 48 + 20), (try expectStoredEnd(&system, key)).cell);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
    try expectRegistryMatchesCache(&system);
}

test "a one-way teleport into a sealed pocket solves forward, answers the reverse unavailable with no search, and closing its source flips the forward answer the same step" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 20, .y = 20 }, .level_b = 0, .cell_b = .{ .x = 3, .y = 3 }, .traversal_cost = 1, .bidirectional = false });
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const outside = outsideStart(0);
    const inside_goal = pocketGoal(55);
    const inside_start = pocketGoal(2);
    const outside_goal = tileCenter(24, 24);
    // Forward, along the link.
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, outside, 0, inside_goal, .default, null).status);
    const forward = try solveFrom(&system, requester, outside, inside_goal, .{});
    try std.testing.expectEqual(@as(usize, 1), forward.available_results);
    try std.testing.expectEqual(@as(usize, 1), forward.abstract_solves);
    // The reverse: unavailable at status and intake, never searched.
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, inside_start, 0, outside_goal, .default, null).status);
    const reverse = try solveFrom(&system, requester, inside_start, outside_goal, .{});
    try std.testing.expectEqual(@as(usize, 1), reverse.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), reverse.solved_requests + system.pending.len);
    // Closing the link's source cell: the forward goal reads unavailable after the reaction.
    try setRegistryCells(&system, &fixture, &.{.{ 20, 20 }}, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outside, 0, inside_goal, .default, null).status);
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, outside, inside_goal, .{})).unavailable_results);
}

test "a crowd at one blocked unreachable goal shares one projection: the resolve projects once, intake answers every request from the table, and every status reads unavailable" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try projectionWorld(&meta);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    const crowd = 64;
    var system = try registrySystem(&data, &fixture.world, crowd);
    defer system.deinit();
    try system.reserveGoals(crowd);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goal = tileCenter(14, 1);
    for (0..crowd) |index| try appendPathRequest(&stream, .{ .entity = requester, .start = tileCenter(@intCast(40 + index % 8), @intCast(10 + index / 8)), .goal = goal });
    const resolve = try system.resolveGoals(PathRequest, stream.mergedItems(), null, .{});
    try std.testing.expectEqual(@as(usize, crowd), resolve.blocked);
    try std.testing.expectEqual(@as(usize, 1), resolve.distinct);
    try std.testing.expectEqual(@as(usize, 1), resolve.distinct);
    for (stream.mergedItems()) |request| try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, request.start, 0, goal, .default, null).status);
    const stats = try system.updateSerial(&stream, crowd, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.goal_fallbacks);
    try std.testing.expectEqual(@as(usize, crowd), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), stats.accepted_requests + system.pending.len);
}

test "the default class walks, and reach by class equals connectivity reach on the walk graph" {
    try std.testing.expectEqual(TraversalClass.walk, traversalOf(.default));
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    const grid = system.graph.grid(0).?;
    var prng = std.Random.DefaultPrng.init(0x7c2);
    const random = prng.random();
    var reachable: usize = 0;
    for (0..400) |_| {
        const from = random.uintLessThan(usize, grid.cellCount());
        const to = random.uintLessThan(usize, grid.cellCount());
        if (grid.isBlockedIndex(from) or grid.isBlockedIndex(to)) continue;
        const expected = reach(&system.graph, 0, from, 0, to);
        try std.testing.expectEqual(expected, system.reaches(.default, 0, from, 0, to));
        reachable += @intFromBool(expected == .reaches);
    }
    try std.testing.expect(reachable != 0);
}

// Cells reachable from `start` on `grid`: orthogonal moves between open cells, diagonal
// moves through two open orthogonal cells, two-way links both ways and one-way links
// forward, each with both ends open.
fn referenceReachable(allocator: std.mem.Allocator, grid: *const NavGrid, links: []const @import("../../world/system.zig").LevelLink, start: usize, reached: []bool) !void {
    @memset(reached, false);
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    reached[start] = true;
    try queue.append(allocator, start);
    var head: usize = 0;
    const width = grid.geometry.width;
    while (head < queue.items.len) : (head += 1) {
        const cell = queue.items[head];
        const x: isize = @intCast(cell % width);
        const y: isize = @intCast(cell / width);
        var neighbours: [12]usize = undefined;
        var count: usize = 0;
        for ([_][2]isize{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } }) |step| {
            const nx = x + step[0];
            const ny = y + step[1];
            if (nx < 0 or ny < 0 or nx >= @as(isize, @intCast(width)) or ny >= @as(isize, @intCast(grid.geometry.height))) continue;
            if (grid.isBlockedXY(@intCast(nx), @intCast(ny))) continue;
            if (step[0] != 0 and step[1] != 0 and (grid.isBlockedXY(@intCast(nx), @intCast(y)) or grid.isBlockedXY(@intCast(x), @intCast(ny)))) continue;
            neighbours[count] = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
            count += 1;
        }
        for (links) |link| {
            const a = @as(usize, link.cell_a.y) * width + link.cell_a.x;
            const b = @as(usize, link.cell_b.y) * width + link.cell_b.x;
            if (grid.isBlockedIndex(a) or grid.isBlockedIndex(b) or count == neighbours.len) continue;
            if (cell == a) {
                neighbours[count] = b;
                count += 1;
            } else if (cell == b and link.bidirectional) {
                neighbours[count] = a;
                count += 1;
            }
        }
        for (neighbours[0..count]) |next| {
            if (reached[next]) continue;
            reached[next] = true;
            try queue.append(allocator, next);
        }
    }
}

test "status and intake read unavailable exactly when a reference directed search does not reach the goal, over random walls and one-way and two-way links, and solve only reachable pairs" {
    const allocator = std.testing.allocator;
    var meta = try loadTestWorldMeta(allocator);
    defer meta.deinit();
    var prng = std.Random.DefaultPrng.init(0x7c22);
    const random = prng.random();
    for (0..3) |_| {
        var data = DataSystem.init(allocator);
        defer data.deinit();
        var fixture = try registryWorld(&meta, 16);
        defer fixture.world.deinit();
        for (0..16) |y| {
            for (0..16) |x| {
                if (random.uintLessThan(u8, 100) < 35) _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), @intCast(y), fixture.tree);
            }
        }
        for (0..6) |index| {
            try fixture.world.addLevelLink(.{
                .kind = .teleport,
                .level_a = 0,
                .cell_a = .{ .x = random.uintLessThan(u16, 16), .y = random.uintLessThan(u16, 16) },
                .level_b = 0,
                .cell_b = .{ .x = random.uintLessThan(u16, 16), .y = random.uintLessThan(u16, 16) },
                .traversal_cost = 1,
                .bidirectional = index % 3 == 0,
            });
        }
        const requester = try data.createEntity();
        var system = try registrySystem(&data, &fixture.world, 16);
        defer system.deinit();
        const grid = system.graph.grid(0).?;
        const reached = try allocator.alloc(bool, grid.cellCount());
        defer allocator.free(reached);
        var solved_pairs: usize = 0;
        var unreachable_pairs: usize = 0;
        for (0..grid.cellCount()) |from| {
            if (grid.isBlockedIndex(from)) continue;
            try referenceReachable(allocator, grid, fixture.world.levelLinks(), from, reached);
            const start = grid.cellCenter(from);
            for (0..grid.cellCount()) |to| {
                if (grid.isBlockedIndex(to)) continue;
                const status = system.statusForWorld(0, start, 0, grid.cellCenter(to), .default, null).status;
                try std.testing.expectEqual(!reached[to], status == .unavailable);
                unreachable_pairs += @intFromBool(!reached[to]);
            }
            // Intake and solve on a few goals per start.
            for (0..3) |_| {
                const to = random.uintLessThan(usize, grid.cellCount());
                if (grid.isBlockedIndex(to)) continue;
                clearRequestsKeepingFields(&system);
                const stats = try solveFrom(&system, requester, start, grid.cellCenter(to), .{});
                if (reached[to]) {
                    try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
                    try std.testing.expectEqual(@as(usize, 1), stats.available_results + stats.budget_exhausted);
                    solved_pairs += stats.solved_requests;
                } else {
                    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
                    try std.testing.expectEqual(@as(usize, 0), stats.solved_requests + stats.accepted_requests);
                }
            }
        }
        try std.testing.expect(solved_pairs != 0 and unreachable_pairs != 0);
    }
}

test "a reserve on a live system keeps the deferred requests and group tallies in step with their key tables" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = cellWorld(1, 1), .goal = cellWorld(12, 12) });
    try appendIndividual(&stream, requester, cellWorld(9, 3));
    // No admission: both requests stay deferred, and the group goal holds a tally.
    _ = try system.updateSerial(&stream, 8, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 2), system.pending.len);
    try std.testing.expectEqual(@as(usize, 1), system.group_requests.items.len);

    try system.reserve(system.capacity);
    try std.testing.expectEqual(@as(usize, 2), system.pending.len);
    for (0..system.pending.len) |index| try std.testing.expect(system.pending_keys.contains(system.pending.at(index).key));
    const group_key = system.graph.keyForWorld(0, cellWorld(12, 12), .default).?;
    try std.testing.expectEqual(@as(?usize, 0), system.group_key_map.find(group_key));
    try std.testing.expectEqualDeep(group_key, system.group_requests.items[0].key);

    // The next step folds the repeats into the live entries and solves both.
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.duplicate_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.solved_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, cellWorld(1, 2), 0, cellWorld(9, 3), .default, null).status);
}

test "a reserve on a grown live system keeps its agent capacity and drops no deferred request" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    // 20 distinct deferred goals at a 40-agent crowd: past the floor's 8-request limits.
    for (0..20) |index| try appendIndividual(&stream, requester, cellWorld(@intCast(2 + index % 12), @intCast(3 + index / 12)));
    _ = try system.updateSerial(&stream, 40, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 20), system.pending.len);
    const agents = system.effective_agent_capacity;
    const cached = system.completed.logicalCapacity();
    try std.testing.expect(agents >= 40);

    try system.reserve(system.capacity);
    try std.testing.expectEqual(agents, system.effective_agent_capacity);
    try std.testing.expectEqual(cached, system.completed.logicalCapacity());
    try std.testing.expectEqual(@as(usize, 20), system.pending.len);
    try std.testing.expectEqual(@as(usize, 0), system.resize_dropped);
}
