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
const dilateChanged3x3 = @import("nav_grid.zig").dilateChanged3x3;
const NavBatchResult = @import("nav_graph.zig").NavBatchResult;
const ChunkBits = @import("../../world_terrain.zig").ChunkBits;
const ChunkListMap = @import("../chunk_list_map.zig").ChunkListMap;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const superchunkKey = @import("../chunk_list_map.zig").superchunkKey;
const levelKey = @import("../chunk_list_map.zig").levelKey;
const world_key = @import("../chunk_list_map.zig").world_key;
const superchunk_edge = @import("../chunk_list_map.zig").superchunk_edge;
const no_entry = @import("../chunk_list_map.zig").no_entry;
const GroupField = @import("group_field.zig").GroupField;
const group_field_cell_limit = @import("group_field.zig").group_field_cell_limit;
const initialPoolBlocks = @import("group_field.zig").initialPoolBlocks;
const SearchScratch = @import("scratch.zig").SearchScratch;
const Tier1Scratch = @import("scratch.zig").Tier1Scratch;
const ResultCache = @import("caches.zig").ResultCache;
const NegativeCache = @import("caches.zig").NegativeCache;
const ResizeMove = @import("caches.zig").ResizeMove;
const KeySet = @import("caches.zig").KeySet;
const GroupKeyMap = @import("caches.zig").GroupKeyMap;
const waypointFromPath = @import("caches.zig").waypointFromPath;
const waypointFromStitched = @import("caches.zig").waypointFromStitched;
const solve = @import("solve.zig");
const solveOne = solve.solveOne;
const solveFallbackJob = solve.solveFallbackJob;
const SolveJobContext = solve.SolveJobContext;
const RunGeometry = solve.RunGeometry;
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
const resizeUnwritten = types.resizeUnwritten;
const PathSolveResult = types.PathSolveResult;
const GroupRequestTally = types.GroupRequestTally;
const PhaseTimer = types.PhaseTimer;
const emptyKey = types.emptyKey;
const keysEqual = types.keysEqual;
const setLen = types.setLen;
const resizeArrayList = types.resizeArrayList;
const OwnerOp = types.OwnerOp;
const no_owner = types.no_owner;
const RegRecord = types.RegRecord;
const EvictItem = types.EvictItem;
const Enclosure = types.Enclosure;
const no_changed_index = types.no_changed_index;
const evict_owns_superchunk = types.evict_owns_superchunk;
const evict_owns_level = types.evict_owns_level;
const evict_owns_world = types.evict_owns_world;
const CellCursor = types.CellCursor;
const registry_shard_count = types.registry_shard_count;
const registryShard = types.registryShard;
const evict_range_alignment_items = types.evict_range_alignment_items;
const reg_window_alignment_items = types.reg_window_alignment_items;
const hit_window_alignment_items = types.hit_window_alignment_items;
const no_parent = types.no_parent;
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
const RegRecordList = std.ArrayListAligned(RegRecord, .fromByteUnits(thread_shared_record_alignment));
const PublishBandList = std.ArrayListAligned(PublishBand, .fromByteUnits(thread_shared_record_alignment));
const EvictItemList = std.ArrayListAligned(EvictItem, .fromByteUnits(thread_shared_record_alignment));
const HitList = std.ArrayListAligned(u32, .fromByteUnits(thread_shared_record_alignment));

// `registry_flush` work pairs (registry index, shard), index-major: pair `p` is shard
// `p % registry_shard_count` of index `p / registry_shard_count`. The path registry is
// index 0, the negative registry index 1.
const registry_index_count: usize = 2;
const flush_pair_count = registry_index_count * registry_shard_count;
const negative_pair_base = registry_shard_count;

// One `publish_copy` range's registrations per flush pair, padded to its own cache line.
const PublishBand = struct {
    counts: [flush_pair_count]u32 align(thread_shared_record_alignment) = @splat(0),
};

// `publish_records` long block of a claimed negative, which stores no path.
const negative_claim_block: u32 = std.math.maxInt(u32);

// One `registry_flush` pair's entries removed and added, padded to its own cache line.
const FlushTally = struct {
    removed: usize align(thread_shared_record_alignment) = 0,
    added: usize = 0,
};

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
    std.debug.assert(@sizeOf(PublishBand) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(FlushTally) % thread_shared_record_alignment == 0);
    // A publish band counts each flush pair's registrations.
    std.debug.assert(@typeInfo(@FieldType(PublishBand, "counts")).array.len == flush_pair_count);
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
    // The path registry: per cached result, the chunk runs of its stored path, keyed by
    // chunk and sharded by key, owned by the result's cache owner id. Written only by
    // `registry_flush`; empty of ops whenever no system call is on the stack.
    path_index: [registry_shard_count]ChunkListMap,
    // Proven negatives, and their registry: per negative, the keys of its `NegativeKeys`
    // (chunk, superchunk, level, or world tier), sharded and flushed as the path registry.
    negatives: NegativeCache = .{},
    negative_index: [registry_shard_count]ChunkListMap,
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
    // Per fallback ordinal, in its stripe's window: the first cell index of each registry
    // run of its path.
    worker_run_starts: std.ArrayList(u16) = .empty,
    // Per fallback ordinal, where the publish claimed its result (null: none).
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
    // The publish byte copy, the registry flush, and a shrink's resize copy each own a
    // tuner; so do the eviction's bound count, halo walk, and flush.
    publish_copy_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    registry_flush_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    resize_copy_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    nav_evict_count_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    nav_evict_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    evict_flush_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
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
    /// Telemetry: long-block pages the publish reserves allocated.
    long_block_grows: u64 = 0,
    long_block_growth_logged: bool = false,
    /// Telemetry: registry shard storage growths, and eviction scratch growths; each
    /// logged once.
    registry_grows: u64 = 0,
    registry_growth_logged: bool = false,
    evict_reserve_grows: u64 = 0,
    evict_growth_logged: bool = false,
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

    /// One solved request's output in its fallback ordinal's stripe.
    pub const SolvedPath = struct {
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
        // Registry runs in the ordinal's run-start window, or a negative's keys, and their
        // keys per shard.
        run_count: u32 = 0,
        shard_counts: [registry_shard_count]u32 = @splat(0),
        // An `.unavailable` result's registry keys, the box its proof leaves out, and
        // whether it was proven after its search exhausted its budget.
        negative: solve.NegativeKeys = .{},
        enclosure: Enclosure = .{},
        negative_after_exhaustion: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) PathfindingSystem {
        // Tuners use their field defaults (AdaptiveWorkTuner.init(.{})); no need to re-set them.
        var path_index: [registry_shard_count]ChunkListMap = undefined;
        var negative_index: [registry_shard_count]ChunkListMap = undefined;
        for (&path_index, &negative_index) |*shard, *negative_shard| {
            shard.* = ChunkListMap.init(allocator, "path registry shard");
            negative_shard.* = ChunkListMap.init(allocator, "negative registry shard");
            // The system logs the registries' first growth once for every shard.
            shard.growth_logged = true;
            negative_shard.growth_logged = true;
        }
        return .{
            .allocator = allocator,
            .graph = .{ .allocator = allocator },
            .path_index = path_index,
            .negative_index = negative_index,
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
        self.group_fields.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        for (&self.negative_index) |*shard| shard.deinit();
        self.negatives.deinit(self.allocator);
        for (&self.path_index) |*shard| shard.deinit();
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

    /// Sizes every pool for `capacity` at the floor agent count, keeping cached results that
    /// fit. Fails with `PathfindingBudgetTooWide` when a field's cell cap or a result block
    /// is past what its indices hold. Returns with the path registry flushed.
    pub fn reserve(self: *PathfindingSystem, capacity: PathfindingCapacity) (types.BudgetError || error{OutOfMemory})!void {
        // A field's bucket links pack its block ids, which stay below its cell cap.
        if (capacity.group_field_max_cells >= group_field_cell_limit) return error.PathfindingBudgetTooWide;
        // Registry run starts index a result block as u16.
        if (types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells) > types.max_result_block_words) return error.PathfindingBudgetTooWide;
        self.group_field_threshold_ceiling = @max(min_capacity_floor, capacity.max_agent_budget);
        // A shrink of live entries logs owner ops: flushed here, so no reader sees them.
        defer _ = self.flushRegistry(null, null);
        // Reserve modestly for the floor agent count, not the full ceiling, so the
        // elastic path can later grow and shrink. The ceiling/ratio/window knobs are
        // retained in self.capacity; per-step caps are derived and grown on demand.
        try self.applyDerivedCapacity(capacity, min_capacity_floor, null);
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
    //
    // The registry's owner heads grow before the cache, so every cache owner id has a head;
    // a shrink's copies run (on `threads` when given) and its tail pages are freed before
    // anything else can fail, and its heads past the new capacity go after the next flush.
    fn applyDerivedCapacity(self: *PathfindingSystem, base: PathfindingCapacity, agent_count: usize, threads: ?StageThreads) !void {
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
        // Per solve slot: where its publish claimed, and the publish copy's range records.
        try resizeArrayList(?ResultCache.Claimed, &self.publish_records, self.allocator, capacity.max_solved_requests_per_step);
        const publish_ranges = maxRangeCount(capacity.max_solved_requests_per_step, 1);
        try resizeArrayList(usize, &self.publish_range_bases, self.allocator, publish_ranges);
        try resizeList(&self.publish_bands, self.allocator, publish_ranges);
        // Sized to the solve window: at most one front-window entry per solved slot can be
        // rotated to the back in a single compaction.
        try resizeArrayList(PendingRequest, &self.rotate_back_scratch, self.allocator, capacity.max_solved_requests_per_step);
        // Logical capacity only: every ProbeTable/ResultCache reserve internally doubles
        // physical slots for probe headroom, so callers pass the true entry-count ceiling,
        // never a caller-side multiplier (one load-factor policy, not two stacked).
        try self.reserveRegistryOwners(capacity.max_cached_results);
        const path_shrinking = capacity.max_cached_results < self.completed.logicalCapacity();
        const negative_shrinking = capacity.max_cached_results < self.negatives.logicalCapacity();
        if (path_shrinking) try prepareTruncate(&self.path_index, capacity.max_cached_results);
        errdefer if (path_shrinking and !self.registry_truncate_pending) abortTruncate(&self.path_index);
        if (negative_shrinking) try prepareTruncate(&self.negative_index, capacity.max_cached_results);
        errdefer if (negative_shrinking and !self.registry_truncate_pending) abortTruncate(&self.negative_index);
        // The negative cache's storage before the result cache commits, so both caches take
        // the new capacity or neither does.
        var negative_resize: ?NegativeCache.Resize = if (capacity.max_cached_results != self.negatives.logicalCapacity())
            try self.negatives.prepareResize(self.allocator, capacity.max_cached_results)
        else
            null;
        // A no-op once committed.
        errdefer if (negative_resize) |*resize| self.negatives.abortResize(self.allocator, resize);
        const outcome = try self.completed.reserve(self.allocator, capacity.max_cached_results, capacity.max_stored_path_cells, types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells), self.step_counter);
        if (negative_resize) |*resize| self.negatives.commitResize(self.allocator, resize, self.step_counter);
        if (outcome == .rebuilt) self.clearRegistry();
        self.last_resize_copy_batch = self.runResizeCopy(if (threads) |stage| stage.stage(&self.resize_copy_tuner) else null);
        if (path_shrinking or negative_shrinking) self.registry_truncate_pending = true;
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
        // One disjoint path stripe and run-start window per solved request this step
        // (indexed by the dense fallback position), so workers never overwrite each other's
        // reconstructed paths even when one worker solves several requests. Nothing reads
        // past a written length, so neither is filled.
        const pool_words = capacity.max_solved_requests_per_step * types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells);
        try resizeUnwritten(&self.worker_run_starts, self.allocator, pool_words);
        try resizeUnwritten(&self.worker_path_pool, self.allocator, pool_words);
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
        try self.resizePreservingLiveState(grown, null);
        // A grow moves and evicts nothing, so it leaves no owner op for a flush.
        std.debug.assert(self.completed.core.ownerLog().len == 0 and self.negatives.core.ownerLog().len == 0);
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
    // pending/pending_keys/group_requests/completed/negatives hold cross-step state;
    // completed and negatives keep their entries through the resize, while pending and
    // the group tally round-trip through reusable snapshots and pending_keys is rebuilt
    // from the restored pending. Search scratch, the tier-1 pool, and group fields follow
    // fixed budgets an elastic resize does not change, so their reserves are no-ops here.
    // No worker runs.
    fn adjustCapacityForAgentCount(self: *PathfindingSystem, agent_count: usize, threads: ?StageThreads) !void {
        if (self.effective_agent_capacity == 0) return; // not reserved yet
        const target = deriveCapacity(self.capacity, agent_count).max_pending_requests;
        const current = self.effective_agent_capacity;
        if (target > current) return self.growForAgentCount(agent_count);
        // Shrink only after the agent count stays below half capacity for the window.
        if (agent_count * 2 < current) {
            self.low_load_steps +|= 1;
            if (self.low_load_steps >= self.capacity.capacity_shrink_window) {
                self.low_load_steps = 0;
                try self.resizePreservingLiveState(target, threads);
            }
        } else {
            self.low_load_steps = 0;
        }
    }

    // Re-sizes all pools to `agent_count` while preserving the live deferred-work queue
    // and group tally. The goal-keyed result cache and negative set keep their entries
    // (a shrink evicts only what no longer fits), so a resize costs no re-solves.
    fn resizePreservingLiveState(self: *PathfindingSystem, agent_count: usize, threads: ?StageThreads) !void {
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
        try self.applyDerivedCapacity(self.capacity, agent_count, threads);
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
        self.publish_copy_tuner = AdaptiveWorkTuner.init(.{});
        self.registry_flush_tuner = AdaptiveWorkTuner.init(.{});
        self.resize_copy_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_evict_count_tuner = AdaptiveWorkTuner.init(.{});
        self.nav_evict_tuner = AdaptiveWorkTuner.init(.{});
        self.evict_flush_tuner = AdaptiveWorkTuner.init(.{});
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
    /// the world added (evicting the negatives of the world key), rebuilds the levels whose
    /// content revision moved, then applies the recorded marks and new links as one batch,
    /// evicting only the results, negatives, and group fields it reaches; pending requests
    /// and group tallies survive it. A committed step stays on a later error; marks and the
    /// level, revision, and link gaps stay pending for the next call. The world-wide revision
    /// is compared once; levels are walked only when it moved. A non-null `thread_system`
    /// lets each stage thread under its tuner.
    pub fn applyBufferedNavUpdates(self: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !NavUpdateStats {
        var stats = NavUpdateStats{};
        const threads = self.navUpdateThreads(thread_system);
        const view = colliders.view();
        if (self.graph.world_backed) {
            const levels_before = self.graph.levelCount();
            while (self.graph.levelCount() < world.levelCount()) {
                try self.graph.buildLevel(view, world, @intCast(self.graph.levelCount()), threads, &stats);
            }
            if (self.graph.levelCount() != levels_before) self.evictWorldNegatives(&stats);
            if (world.contentRevision() != self.graph.built_world_revision) {
                for (0..self.graph.levelCount()) |level_index| {
                    const level: u16 = @intCast(level_index);
                    if (self.graph.level_graphs.items[level].built_revision == world.levelContentRevision(level)) continue;
                    try self.graph.buildLevel(view, world, level, threads, &stats);
                    // The level changed without per-cell changes: no cached result is known good.
                    self.clearCompleted();
                    self.clearRequestStateKeepingCompleted();
                    self.dropGroupFields();
                }
                self.graph.built_world_revision = world.contentRevision();
            }
        }
        if (try self.graph.prepareMarks(world, view, self.nav_marks.items, threads, &stats)) |prepared| {
            {
                // Every eviction allocation precedes the commit; on error the batch and its
                // marks stay pending.
                errdefer self.graph.abortMarks(prepared);
                try self.prepareEviction(thread_system, &stats);
            }
            const batch = self.graph.commitMarks(prepared, view, threads, &stats);
            if (batch.changed) {
                stats.remask_batch = self.graph.last_remask_batch;
                // Graph node ids never persist, so cached results stay keyed by cells: evict
                // only those with a cell within one cell of a changed cell, the negatives
                // registered on a dirty key's lists, and the fields with a costed cell next
                // to a changed cell.
                self.evictScoped(batch, thread_system, &stats);
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

    // Eviction before the batch commit, one item per dirty key (a changed chunk or a new
    // link's endpoint chunk): `nav_evict_count` gives each changed key the halo keys it owns
    // (each key of a changed key's 3x3 block is owned by exactly one of them) and their
    // registrations, and each dirty key the negatives on its chunk list and on the
    // superchunk, level, and world lists it owns (the first dirty key in each); the main
    // thread then sizes the hit windows (paths, negatives, and a slot per group field for a
    // changed key) for the walk's selected shape and reserves them, O(1) per key. Reads only
    // the batch's keys and the registries. On error the graph, caches, and registries are as
    // they were.
    fn prepareEviction(self: *PathfindingSystem, thread_system: ?*ThreadSystem, stats: *NavUpdateStats) !void {
        // Every update and reaction ends flushed, so every registration names a live entry.
        std.debug.assert(self.completed.core.ownerLog().len == 0 and self.negatives.core.ownerLog().len == 0 and self.publish_ranges == 0);
        const keys = self.graph.dirty_keys.items;
        self.evict_items.clearRetainingCapacity();
        self.evict_hits.clearRetainingCapacity();
        self.evict_shape = .{};
        if (keys.len == 0) return;
        if (keys.len > self.evict_items.capacity) {
            try self.evict_items.ensureTotalCapacity(self.allocator, keys.len);
            self.countEvictGrowth();
        }
        self.evict_items.items.len = keys.len;
        @memset(self.evict_items.items, .{});
        const count_dispatch = self.navDispatch(thread_system, &self.nav_evict_count_tuner);
        const count_shape = stageShape(count_dispatch, keys.len, evict_range_alignment_items);
        var job = EvictCountJob{
            .keys = keys,
            .changed_keys = self.graph.changed_keys.items,
            .readers = self.registryReaders(),
            .negative_readers = self.negativeReaders(),
            .chunks = self.chunkGrid(),
            .items = self.evict_items.items,
            .range_count = count_shape.range_count,
        };
        stats.evict_count_batch = runShaped(count_dispatch, count_shape, keys.len, evict_range_alignment_items, &job, evictCountJob);
        // The walk's shape now, so each of its ranges' hit windows starts on a line.
        self.evict_shape = stageShape(self.navDispatch(thread_system, &self.nav_evict_tuner), keys.len, evict_range_alignment_items);
        const field_count = self.group_fields.items.len;
        var total: usize = 0;
        for (self.evict_items.items, 0..) |*item, index| {
            if (index % self.evict_shape.items_per_range == 0) total = std.mem.alignForward(usize, total, hit_window_alignment_items);
            // Hits are registrations of distinct keys and field slots, fewer than the
            // registries' u32 ids.
            item.base = @intCast(total);
            total += item.bound + item.negative_bound;
            if (item.changed_index != no_changed_index) total += field_count;
        }
        if (total > self.evict_hits.capacity) {
            try self.evict_hits.ensureTotalCapacity(self.allocator, total);
            self.countEvictGrowth();
        }
        self.evict_hits.items.len = total;
    }

    // Eviction after the batch commit: `nav_evict` walks, per dirty key, each owned halo
    // key's registrations, testing each run's cells from its start against the cells within
    // one cell of a changed cell; its owned negative lists, every entry a hit; and for a
    // changed key, each group field's costed cells within one cell of its changed cells. It
    // writes the hits into the item's window; the main thread removes them in item order
    // (paths, negatives, then fields), O(1) each, and the flush unlinks their
    // registrations. A link-only key changes no cell, so it evicts no path and no field.
    fn evictScoped(self: *PathfindingSystem, batch: NavBatchResult, thread_system: ?*ThreadSystem, stats: *NavUpdateStats) void {
        const keys = batch.dirty_keys;
        std.debug.assert(keys.len == self.evict_items.items.len and batch.changed_masks.len == batch.changed_keys.len);
        if (keys.len != 0) {
            var job = EvictJob{
                .cache = &self.completed,
                .keys = keys,
                .changed_keys = batch.changed_keys,
                .masks = batch.changed_masks,
                .readers = self.registryReaders(),
                .negative_readers = self.negativeReaders(),
                .fields = self.group_fields.items,
                .chunks = self.chunkGrid(),
                .geometry = RunGeometry.of(&self.graph),
                .chunk_edge = self.graph.chunk_tiles,
                .items = self.evict_items.items,
                .hits = self.evict_hits.items,
                .range_count = self.evict_shape.range_count,
            };
            stats.evict_batch = runShaped(self.navDispatch(thread_system, &self.nav_evict_tuner), self.evict_shape, keys.len, evict_range_alignment_items, &job, evictJob);
            for (self.evict_items.items) |item| {
                stats.evict_entries_visited += item.visited;
                const window = self.evict_hits.items[item.base..];
                for (window[0..item.hits]) |owner| {
                    // Another halo key's run may have hit the owner already.
                    if (!self.completed.core.records.items[owner].live) continue;
                    // A live record's key holds its probe slot.
                    self.completed.removeAt(self.completed.slotIndex(self.completed.core.keyOf(owner)).?);
                    stats.evicted_results += 1;
                }
                for (window[item.bound..][0..item.negative_hits]) |owner| {
                    // Another list of this key or an earlier key may have hit it already.
                    if (!self.negatives.core.records.items[owner].live) continue;
                    self.negatives.removeOwner(owner);
                    stats.evicted_negatives += 1;
                }
                for (window[item.bound + item.negative_bound ..][0..item.field_hits]) |slot| {
                    const field = &self.group_fields.items[slot];
                    if (field.state == .empty) continue;
                    field.state = .empty;
                    stats.dropped_fields += 1;
                }
            }
        }
        stats.evict_flush_batch = self.flushRegistry(self.navDispatch(thread_system, &self.evict_flush_tuner), null);
        stats.off_main_stage_ns += offMainNs(stats.evict_count_batch) + offMainNs(stats.evict_batch) + offMainNs(stats.evict_flush_batch);
    }

    fn countEvictGrowth(self: *PathfindingSystem) void {
        self.evict_reserve_grows += 1;
        if (self.evict_growth_logged) return;
        self.evict_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test) logging.game.info(
            "path eviction scratch grew to {d} keys and {d} hits",
            .{ self.evict_items.capacity, self.evict_hits.capacity },
        );
    }

    // Lookups of every path registry shard, for readers on workers while nothing writes.
    fn registryReaders(self: *const PathfindingSystem) [registry_shard_count]ChunkListMap.Reader {
        var readers: [registry_shard_count]ChunkListMap.Reader = undefined;
        for (&readers, &self.path_index) |*reader, *shard| reader.* = shard.reader();
        return readers;
    }

    // Lookups of every negative registry shard, for readers on workers while nothing writes.
    fn negativeReaders(self: *const PathfindingSystem) [registry_shard_count]ChunkListMap.Reader {
        var readers: [registry_shard_count]ChunkListMap.Reader = undefined;
        for (&readers, &self.negative_index) |*reader, *shard| reader.* = shard.reader();
        return readers;
    }

    // A level add invalidates the negatives of a missing graph or goal level: removes every
    // owner on the world key's list, then flushes. Cold, main thread, O(those negatives).
    fn evictWorldNegatives(self: *PathfindingSystem, stats: *NavUpdateStats) void {
        // Removals log ops only; the list stays as it is until the flush.
        var owners = self.negative_index[registryShard(world_key)].iterator(world_key);
        while (owners.next()) |owner| {
            if (!self.negatives.core.records.items[owner].live) continue;
            self.negatives.removeOwner(owner);
            stats.evicted_negatives += 1;
        }
        _ = self.flushRegistry(null, null);
    }

    fn chunkGrid(self: *const PathfindingSystem) ChunkGrid {
        const geometry = types.ChunkGeometry{ .width = self.graph.width, .height = self.graph.height, .chunk_tiles = self.graph.chunk_tiles };
        return .{ .chunks_x = geometry.chunksX(), .chunks_y = geometry.chunksY() };
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
        self.clearCompleted();
    }

    // Clears request state and negatives but keeps the result cache.
    fn clearRequestStateKeepingCompleted(self: *PathfindingSystem) void {
        self.pending.clear();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.fallback_tier1_slot.clearRetainingCapacity();
        self.solved_paths.clearRetainingCapacity();
        self.group_requests.clearRetainingCapacity();
        self.group_key_map.clear();
        self.clearNegatives();
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
                const first_grid = self.graph.grid(stitched.levels[0]) orelse return .{ .status = .unavailable };
                return .{ .status = .available, .next_waypoint = first_grid.cellCenter(stitched.cells[0]), .path_len = result.stitched_len };
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
        const start = self.startChunk(start_index);
        if (self.negatives.isFreshFor(key, self.step_counter, types.default_cache_ttl_steps, start_level, start.x, start.y)) return .{ .status = .unavailable };
        if (self.pending_keys.contains(key)) return .{ .status = .pending };
        return .{ .status = .missing };
    }

    // The chunk of cell `cell_index`; every level shares one extent.
    fn startChunk(self: *const PathfindingSystem, cell_index: usize) StartChunk {
        const y = cell_index / self.graph.width;
        return self.startChunkAt(.{ .x = @intCast(cell_index - y * self.graph.width), .y = @intCast(y) });
    }

    fn startChunkAt(self: *const PathfindingSystem, cell: GridCell) StartChunk {
        // Chunk edges are powers of two; in-grid cells are non-negative and below 2^32.
        const shift: u5 = @intCast(@ctz(self.graph.chunk_tiles));
        return .{ .x = @as(u32, @intCast(cell.x)) >> shift, .y = @as(u32, @intCast(cell.y)) >> shift };
    }

    const StartChunk = struct {
        x: u32,
        y: u32,
    };

    // Whether a fresh negative answers `key` for a start at `start` on `start_level`, and
    // whether an expired one waits for removal; one probe. Const.
    fn negativeFor(self: *const PathfindingSystem, key: PathQueryKey, start_level: u16, start: GridCell) NegativeAnswer {
        const negative = self.negatives.lookup(key, self.step_counter, types.default_cache_ttl_steps) orelse return .absent;
        if (!negative.fresh) return .expired;
        const chunk = self.startChunkAt(start);
        return if (negative.enclosure.excludes(start_level, chunk.x, chunk.y)) .absent else .hit;
    }

    const NegativeAnswer = enum { absent, hit, expired };

    // Shared accept + group-service + solve-limit prologue for update/updateSerial.
    // Safe-point elastic resize runs here, after last frame's publish and before any
    // accept/solve, so no live worker index or pool offset spans it; a shrink's resize copy
    // threads under `threads`. A returned solve_count of 0 means no solve runs this step
    // (caller publishes the pending counts and returns).
    fn beginUpdate(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, threads: ?StageThreads, stats: *PathfindingStats) !usize {
        self.step_counter +%= 1;
        self.last_resize_copy_batch = .{};
        try self.adjustCapacityForAgentCount(agent_count, threads);
        var accept_timer = PhaseTimer.begin();
        stats.* = self.acceptRequests(requests.mergedItems(), threads);
        stats.resize_copy_batch = self.last_resize_copy_batch;
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
    // publish-reserve OOM nothing is claimed and pending is left intact for retry; the
    // caller's flush still applies the ops logged so far.
    fn finishUpdate(self: *PathfindingSystem, solve_count: usize, threads: ?StageThreads, stats: *PathfindingStats) !void {
        var publish_timer = PhaseTimer.begin();
        try self.reservePublish(stats);
        self.claimPublish(stats);
        stats.publish_copy_batch = self.publishCopy(if (threads) |stage| stage.stage(&self.publish_copy_tuner) else null);
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

    /// One fixed-step update with its stages on `thread_system`. Returns with the path
    /// registry flushed, on success and on error.
    pub fn update(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, thread_system: *ThreadSystem, config: PathfindingConfig) !PathfindingStats {
        const threads = StageThreads{ .thread_system = thread_system, .config = config };
        const flush = threads.stage(&self.registry_flush_tuner);
        var stats = PathfindingStats{};
        errdefer _ = self.flushRegistry(flush, null);
        try self.updateThreaded(requests, agent_count, threads, &stats);
        stats.registry_flush_batch = self.flushRegistry(flush, &stats);
        return stats;
    }

    fn updateThreaded(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, threads: StageThreads, stats: *PathfindingStats) !void {
        const thread_system = threads.thread_system;
        const config = threads.config;
        const solve_count = (try self.beginSolve(requests, agent_count, config, threads, stats)) orelse return;
        var solve_timer = PhaseTimer.begin();
        var system_config = config;
        self.prepareSolvePhase(solve_count, self.effectiveFallbackLimit(system_config), stats);

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
        try self.finishUpdate(solve_count, threads, stats);
    }

    /// One fixed-step update with every stage inline. Returns with the path registry
    /// flushed, on success and on error.
    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) !PathfindingStats {
        var stats = PathfindingStats{};
        errdefer _ = self.flushRegistry(null, null);
        try self.updateInline(requests, agent_count, config, &stats);
        stats.registry_flush_batch = self.flushRegistry(null, &stats);
        return stats;
    }

    fn updateInline(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig, stats: *PathfindingStats) !void {
        const solve_count = (try self.beginSolve(requests, agent_count, config, null, stats)) orelse return;
        var solve_timer = PhaseTimer.begin();
        self.prepareSolvePhase(solve_count, self.effectiveFallbackLimit(config), stats);
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
        try self.finishUpdate(solve_count, null, stats);
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

        // One stage of the update under its own tuner and the caller's controls.
        fn stage(self: StageThreads, tuner: *AdaptiveWorkTuner) Dispatch {
            return .{
                .thread_system = self.thread_system,
                .tuner = tuner,
                .items_per_range = self.config.items_per_range,
                .max_worker_threads = self.config.max_worker_threads,
                .adaptive = self.config.adaptive,
            };
        }
    };

    // One stage of the nav reaction under its own tuner and the nav thread controls.
    fn navDispatch(self: *const PathfindingSystem, thread_system: ?*ThreadSystem, tuner: *AdaptiveWorkTuner) ?Dispatch {
        const threads = thread_system orelse return null;
        return .{
            .thread_system = threads,
            .tuner = tuner,
            .items_per_range = self.nav_thread_items_per_range,
            .max_worker_threads = null,
            .adaptive = self.nav_thread_adaptive,
        };
    }

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
                switch (self.negativeFor(key, request.start_level, cells.start)) {
                    .hit => {
                        stats.duplicate_requests += 1;
                        stats.cache_hits += 1;
                        stats.unavailable_results += 1;
                        continue;
                    },
                    // Removes the expired negative; the request goes on as if none were cached.
                    .expired => _ = self.negatives.removeExpired(key, self.step_counter, types.default_cache_ttl_steps),
                    // A start inside the negative's box goes on to a solve.
                    .absent => {},
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
                const negative = self.negativeFor(key, request.start_level, cells.start);
                var record = IntakeRecord{
                    .entity = request.entity,
                    .key = key,
                    .start_level = request.start_level,
                    .start = cells.start,
                    .goal_index = no_parent,
                    .expired = cached != null,
                    .expired_negative = negative == .expired,
                    .candidate = false,
                    .projected = false,
                    .repeats = 0,
                };
                if (negative == .hit) {
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
                if (!record.candidate and !record.expired and !record.expired_negative) continue;
                // A repeat of a key in this range carries its first record's removals and folds
                // into it; only a candidate's repeats count in the merge. A start inside a
                // fresh negative's box makes a candidate of a key whose first record was not
                // one, which takes a record of its own.
                if (recent_records.find(key)) |entry| {
                    if (record_window[entry].candidate) {
                        if (record.candidate) record_window[entry].repeats += 1;
                        continue;
                    }
                    if (!record.candidate) continue;
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
        // Removes the negative that expired before this step; a repeat finds none.
        if (record.expired_negative) _ = self.negatives.removeExpired(record.key, self.step_counter, types.default_cache_ttl_steps);
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

    // The publish reserve, before any claim: long-block pages for the step's results past
    // an inline stripe, each registry shard's room for this step's registrations of it
    // (path runs and negative keys), and the registration windows. O(solves * shards) on
    // the main thread; on error nothing is claimed.
    fn reservePublish(self: *PathfindingSystem, stats: *PathfindingStats) !void {
        var long_results: usize = 0;
        var registrations: usize = 0;
        var pair_registrations: [flush_pair_count]usize = @splat(0);
        for (self.solve_results.items, 0..) |result, ordinal| {
            const solved = self.solved_paths.items[ordinal];
            const segment: usize = switch (result) {
                .available => available: {
                    if (types.storedPathWords(solved.len, solved.stitched_len) > self.completed.inline_words) long_results += 1;
                    break :available 0;
                },
                .unavailable => negative_pair_base,
                else => continue,
            };
            registrations += solved.run_count;
            for (pair_registrations[segment..][0..registry_shard_count], solved.shard_counts) |*total, shard_count| total.* += shard_count;
        }
        const grows_before = self.registryGrowths();
        for (&self.path_index, pair_registrations[0..registry_shard_count]) |*shard, count| try shard.reserve(count, count, self.completed.logicalCapacity());
        for (&self.negative_index, pair_registrations[negative_pair_base..]) |*shard, count| try shard.reserve(count, count, self.negatives.logicalCapacity());
        var grows = self.registryGrowths() - grows_before;
        // Each range window starts on a cache line.
        const padding = (reg_window_alignment_items - 1) * maxRangeCount(self.solve_results.items.len, 1);
        if (registrations + padding > self.reg_buckets.capacity) {
            try self.reg_buckets.ensureTotalCapacity(self.allocator, registrations + padding);
            grows += 1;
        }
        stats.registry_grows = grows;
        if (grows != 0) self.countRegistryGrowth(grows);
        const pages = try self.completed.reserveLongBlocks(self.allocator, long_results);
        if (pages == 0) return;
        self.long_block_grows += pages;
        if (!self.long_block_growth_logged) {
            self.long_block_growth_logged = true;
            if (comptime logging.enabled(.info) and !builtin.is_test) logging.game.info(
                "path cache long-block pool grew to {d} blocks",
                .{self.completed.long_block_count},
            );
        }
    }

    // Growths of every registry shard's table, entry pool, and owner heads so far.
    fn registryGrowths(self: *const PathfindingSystem) u64 {
        var grows: u64 = 0;
        for (&self.path_index, &self.negative_index) |*shard, *negative_shard| grows += shard.grows + negative_shard.grows;
        return grows;
    }

    fn countRegistryGrowth(self: *PathfindingSystem, grows: u64) void {
        self.registry_grows += grows;
        if (self.registry_growth_logged) return;
        self.registry_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test) logging.game.info(
            "path registry storage grew ({d} growths so far)",
            .{self.registry_grows},
        );
    }

    // Every registry shard holds an owner head per cache owner id below `capacity`.
    fn reserveRegistryOwners(self: *PathfindingSystem, capacity: usize) !void {
        const grows_before = self.registryGrowths();
        for (&self.path_index, &self.negative_index) |*shard, *negative_shard| {
            try shard.reserve(0, 0, capacity);
            try negative_shard.reserve(0, 0, capacity);
        }
        const grows = self.registryGrowths() - grows_before;
        if (grows != 0) self.countRegistryGrowth(grows);
    }

    // Drops every path registration, as when the result cache dropped every entry.
    fn clearRegistry(self: *PathfindingSystem) void {
        for (&self.path_index) |*shard| shard.clear();
        self.publish_ranges = 0;
    }

    // Empties the negative cache, its owner log, and the negative registry. Outside an
    // update, so no publish waits for a flush.
    fn clearNegatives(self: *PathfindingSystem) void {
        std.debug.assert(self.publish_ranges == 0);
        self.negatives.clear();
        for (&self.negative_index) |*shard| shard.clear();
    }

    // Empties the result cache, its owner log, and the registry.
    fn clearCompleted(self: *PathfindingSystem) void {
        self.completed.clear();
        self.clearRegistry();
    }

    // Claims every result of the step in fallback-ordinal order, which is pending order
    // (ordinals increase with the pending index): its cache entry and, past the inline
    // stripe, a long block, logging the retire of a re-put or a victim. O(1) per result
    // on the main thread; the paths are copied by `publish_copy`. Allocates nothing after
    // `reservePublish`.
    fn claimPublish(self: *PathfindingSystem, stats: *PathfindingStats) void {
        std.debug.assert(self.publish_records.capacity >= self.solve_results.items.len);
        self.publish_records.items.len = self.solve_results.items.len;
        self.completed.core.beginPublish();
        self.negatives.core.beginPublish();
        for (self.solve_results.items, self.publish_records.items, 0..) |result, *record, ordinal| {
            record.* = null;
            switch (result) {
                .available => |key| {
                    const solved = self.solved_paths.items[ordinal];
                    if (self.completed.canStore()) {
                        record.* = self.completed.claim(key, solved.len, solved.stitched_len, solved.path_level, self.step_counter, stats);
                    }
                    stats.solved_requests += 1;
                    stats.available_results += 1;
                    if (solved.via_abstract) stats.abstract_solves += 1;
                    if (solved.cross_level) stats.cross_level_solves += 1;
                },
                // A proven negative: its keys are registered by `publish_copy`.
                .unavailable => |key| {
                    const solved = self.solved_paths.items[ordinal];
                    if (self.negatives.canStore()) {
                        const owner = self.negatives.claim(key, solved.enclosure, self.step_counter, stats);
                        record.* = .{ .owner = owner, .long_block = negative_claim_block };
                        stats.negatives_published += 1;
                        if (solved.negative_after_exhaustion) stats.negatives_proven_after_exhaustion += 1;
                    }
                    stats.solved_requests += 1;
                    stats.unavailable_results += 1;
                },
                // Answered for its request only: dropped in compactPendingAfterSolve.
                .start_unreachable => {
                    stats.start_unreachable += 1;
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

    // `publish_copy`: each range copies its claimed results' paths into their stripes or
    // blocks and buckets their registrations (path runs, and claimed negatives' keys) by
    // flush pair into its window, recording each pair's count in its band. The main thread
    // sizes the windows from the selected shape, O(1) per result; inline it is one range.
    // Returns the stage's batch.
    fn publishCopy(self: *PathfindingSystem, dispatch: ?Dispatch) BatchStats {
        const item_count = self.solve_results.items.len;
        self.publish_ranges = 0;
        if (item_count == 0) return .{};
        const shape = stageShape(dispatch, item_count, 1);
        std.debug.assert(self.publish_range_bases.capacity >= shape.range_count);
        std.debug.assert(self.publish_bands.capacity >= shape.range_count);
        self.publish_range_bases.items.len = shape.range_count;
        self.publish_bands.items.len = shape.range_count;
        var total: usize = 0;
        for (self.publish_range_bases.items, 0..) |*base, range_index| {
            total = std.mem.alignForward(usize, total, reg_window_alignment_items);
            base.* = total;
            const first = range_index * shape.items_per_range;
            for (first..@min(first + shape.items_per_range, item_count)) |ordinal| {
                if (self.publish_records.items[ordinal] != null) total += self.solved_paths.items[ordinal].run_count;
            }
        }
        std.debug.assert(total <= self.reg_buckets.capacity);
        self.reg_buckets.items.len = total;
        var job = PublishCopyJob{
            .system = self,
            .geometry = RunGeometry.of(&self.graph),
            .stripe_words = types.resultBlockWords(self.capacity.max_explored_nodes, self.capacity.max_stitched_path_cells),
            .items_per_range = shape.items_per_range,
            .range_count = shape.range_count,
            .buckets = self.reg_buckets.items,
            .bands = self.publish_bands.items,
        };
        const batch = runShaped(dispatch, shape, item_count, 1, &job, publishCopyJob);
        self.publish_ranges = shape.range_count;
        return batch;
    }

    // `registry_flush`: pair by pair (registry index, shard), removes and renames the owners
    // of its index's cache owner log (the result cache's or the negative cache's) in log
    // order, then adds the last publish copy's registrations of the pair in range order, so
    // every list holds its adds in (op, ordinal, run) order for any partition, and installs
    // a shrink's prepared owner heads. Each pair writes only its shard and its tally. Then
    // the logs are emptied, the replaced owner heads are freed, and `stats` (when given)
    // takes the counts. Allocates nothing; every add was reserved by the publish.
    // Items are work units: pair p weighs its index's ops + its adds + 1, and a range runs
    // the pairs whose first unit lies in it, so each pair runs in exactly one range. The
    // main thread sums the weights, O(publish ranges * pairs). A shrink's flush carries ops
    // for most cache entries, a one-off the stage's tuner has no threaded profile for, so
    // with a tuned dispatch it runs at a fixed shape of about one pair per range, outside
    // the tuner. A dispatch wakes at most one worker fewer than the pair count. Returns the
    // stage's batch.
    fn flushRegistry(self: *PathfindingSystem, dispatch: ?Dispatch, stats: ?*PathfindingStats) BatchStats {
        var batch = BatchStats{};
        const truncate = self.registry_truncate_pending;
        const ops = [registry_index_count][]const OwnerOp{ self.completed.core.ownerLog(), self.negatives.core.ownerLog() };
        if (ops[0].len != 0 or ops[1].len != 0 or self.publish_ranges != 0 or truncate) {
            var pair_adds: [flush_pair_count]usize = @splat(0);
            for (self.publish_bands.items[0..self.publish_ranges]) |band| {
                for (&pair_adds, band.counts) |*adds, count| adds.* += count;
            }
            var unit_starts: [flush_pair_count + 1]usize = undefined;
            var units: usize = 0;
            for (unit_starts[0..flush_pair_count], pair_adds, 0..) |*start, adds, pair| {
                start.* = units;
                units += ops[pair / registry_shard_count].len + adds + 1;
            }
            unit_starts[flush_pair_count] = units;
            const flush_dispatch: ?Dispatch = if (dispatch) |stage| pairs: {
                var flush_stage = stage;
                // At most one participant per pair: a worker past that takes only ranges
                // where no pair starts.
                flush_stage.max_worker_threads = @min(stage.max_worker_threads orelse flush_pair_count - 1, flush_pair_count - 1);
                // Only a tuned dispatch's shrink shape is replaced; a configured range size
                // keeps its shape. The explicit range size opts the batch out of the tuner:
                // nothing is recorded.
                if (truncate and stage.adaptive and stage.items_per_range == null) {
                    flush_stage.items_per_range = (units + flush_pair_count - 1) / flush_pair_count;
                }
                break :pairs flush_stage;
            } else null;
            const shape = stageShape(flush_dispatch, units, 1);
            var job = RegistryFlushJob{
                .system = self,
                .ops = ops,
                .publish_ranges = self.publish_ranges,
                .truncate = truncate,
                .range_count = shape.range_count,
                .unit_starts = unit_starts,
            };
            batch = runShaped(flush_dispatch, shape, units, 1, &job, registryFlushJob);
            if (stats) |step| {
                for (self.flush_tallies[0..negative_pair_base]) |tally| {
                    step.registrations_removed += tally.removed;
                    step.registrations_added += tally.added;
                }
                for (self.flush_tallies[negative_pair_base..]) |tally| {
                    step.negative_registrations_removed += tally.removed;
                    step.negative_registrations_added += tally.added;
                }
            }
        }
        self.publish_ranges = 0;
        self.completed.core.finishOwnerLog(self.allocator);
        self.negatives.core.finishOwnerLog(self.allocator);
        if (truncate) {
            for (&self.path_index, &self.negative_index) |*shard, *negative_shard| {
                shard.releaseTruncated();
                negative_shard.releaseTruncated();
            }
            self.registry_truncate_pending = false;
        }
        return batch;
    }

    // The shard map of flush pair `pair`; each registry index needs its own arm.
    fn flushPairMap(self: *PathfindingSystem, pair: usize) *ChunkListMap {
        comptime std.debug.assert(registry_index_count == 2);
        std.debug.assert(pair < flush_pair_count);
        const shard = pair % registry_shard_count;
        return switch (pair / registry_shard_count) {
            0 => &self.path_index[shard],
            1 => &self.negative_index[shard],
            else => unreachable,
        };
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

    // Compacts the solve window [0, solve_count) of pending in O(solve_count). Solved
    // entries (available/unavailable/start_invalid/start_unreachable) are removed; a
    // negative proven after its search exhausted its budget is unavailable and promotes
    // nothing. Deferred entries (not
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
                    // available/unavailable/start_invalid/start_unreachable: removed from
                    // pending. A start_invalid or start_unreachable entry was never
                    // negative-cached, so its next status query is `.missing` and the
                    // caller may re-request.
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

// Each shard's owner heads for a shrink to `capacity`, installed by the flush that applies
// the shrink's ops; allocated before the shrink commits. On error none is prepared.
fn prepareTruncate(shards: *[registry_shard_count]ChunkListMap, capacity: usize) !void {
    errdefer abortTruncate(shards);
    for (shards) |*shard| try shard.prepareTruncate(capacity);
}

fn abortTruncate(shards: *[registry_shard_count]ChunkListMap) void {
    for (shards) |*shard| shard.abortTruncate();
}

// One stage's threading: the thread system, the stage's own tuner, and range controls.
const Dispatch = struct {
    thread_system: *ThreadSystem,
    tuner: *AdaptiveWorkTuner,
    items_per_range: ?usize,
    max_worker_threads: ?usize,
    adaptive: bool,
};

// The shape a stage runs at: a dispatch's pre-selected profile, or one inline range.
const StageShape = struct {
    selection: ?BatchSelection = null,
    items_per_range: usize = 1,
    range_count: usize = 0,
};

// Selects `item_count` items' shape under `dispatch` (its tuner drives an adaptive control
// with no fixed range size), or one inline range without one.
fn stageShape(dispatch: ?Dispatch, item_count: usize, range_alignment_items: usize) StageShape {
    const stage = dispatch orelse return .{ .items_per_range = @max(item_count, 1), .range_count = @intFromBool(item_count != 0) };
    const tuner: ?*AdaptiveWorkTuner = if (stage.adaptive and stage.items_per_range == null) stage.tuner else null;
    const selection = stage.thread_system.selectBatchProfile(tuner, .{
        .item_count = item_count,
        .items_per_range = stage.items_per_range,
        .max_worker_threads = stage.max_worker_threads,
        .range_alignment_items = range_alignment_items,
        .adaptive = stage.adaptive,
    });
    return .{ .selection = selection, .items_per_range = selection.items_per_range, .range_count = selection.range_count };
}

// Runs `job` over `item_count` items at `shape`: dispatched with its selection, or inline
// as one range on the calling thread.
fn runShaped(dispatch: ?Dispatch, shape: StageShape, item_count: usize, range_alignment_items: usize, context: *anyopaque, job: JobFn) BatchStats {
    if (item_count == 0) return .{};
    const stage = dispatch orelse {
        job(context, .{ .start = 0, .end = item_count, .index = 0 }, WorkerId.main);
        return inlineBatch(item_count, range_alignment_items);
    };
    // A shape selected under a dispatch holds its selection.
    const selection = shape.selection.?;
    return stage.thread_system.parallelForWithOptions(item_count, context, job, .{
        .items_per_range = stage.items_per_range,
        .max_worker_threads = stage.max_worker_threads,
        .range_alignment_items = range_alignment_items,
        .adaptive = stage.adaptive,
        .adaptive_tuner = selection.active_tuner,
        .selected_profile = selection.profile,
    });
}

// Dispatch time of a batch that ran on workers; zero when it ran inline.
fn offMainNs(batch: BatchStats) u64 {
    return if (batch.ran_inline) 0 else batch.batch_duration_ns;
}

// One range of `publish_copy`: its ordinals' paths into their claimed stripes or blocks,
// and their registrations, shard by shard in (ordinal, run) order, into its window.
const PublishCopyJob = struct {
    system: *const PathfindingSystem,
    geometry: RunGeometry,
    stripe_words: usize,
    items_per_range: usize,
    range_count: usize,
    buckets: []RegRecord,
    bands: []PublishBand,
};

// SIMD verdict: the path copy is `@memcpy`; bucketing is a scalar counting-sort scatter
// with one division per run start, and at most 64 key hashes per negative.
fn publishCopyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PublishCopyJob = @ptrCast(@alignCast(context));
    const system = job.system;
    std.debug.assert(range.index < job.range_count and range.index < job.bands.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= system.publish_records.items.len and range.end <= system.solve_results.items.len);
    var counts: [flush_pair_count]u32 = @splat(0);
    for (range.start..range.end) |ordinal| {
        const claimed = system.publish_records.items[ordinal] orelse continue;
        const solved = system.solved_paths.items[ordinal];
        const segment: usize = if (system.solve_results.items[ordinal] == .available) path: {
            const words = types.storedPathWords(solved.len, solved.stitched_len);
            // Claims of one publish never share a stripe or a block.
            @memcpy(system.completed.destination(claimed)[0..words], system.worker_path_pool.items[solved.offset..][0..words]);
            break :path 0;
        } else negative_pair_base;
        for (counts[segment..][0..registry_shard_count], solved.shard_counts) |*total, shard_count| total.* += shard_count;
    }
    var cursors: [flush_pair_count]usize = undefined;
    var next = system.publish_range_bases.items[range.index];
    for (&cursors, counts) |*cursor, pair_count| {
        cursor.* = next;
        next += pair_count;
    }
    std.debug.assert(next <= job.buckets.len);
    for (range.start..range.end) |ordinal| {
        const claimed = system.publish_records.items[ordinal] orelse continue;
        const solved = system.solved_paths.items[ordinal];
        if (system.solve_results.items[ordinal] != .available) {
            for (0..solved.run_count) |index| {
                const key = solved.negative.keyAt(@intCast(index));
                const pair = negative_pair_base + registryShard(key);
                job.buckets[cursors[pair]] = .{ .key = key, .owner = claimed.owner, .order = 0 };
                cursors[pair] += 1;
            }
            continue;
        }
        const stripe = system.worker_path_pool.items[solved.offset..][0..job.stripe_words];
        const view = types.stitchedView(stripe, solved.stitched_len);
        for (system.worker_run_starts.items[solved.offset..][0..solved.run_count]) |start| {
            const key = if (solved.stitched_len != 0) job.geometry.key(view.levels[start], view.cells[start]) else job.geometry.key(solved.path_level, stripe[start]);
            const shard = registryShard(key);
            job.buckets[cursors[shard]] = .{ .key = key, .owner = claimed.owner, .order = start };
            cursors[shard] += 1;
        }
    }
    job.bands[range.index] = .{ .counts = counts };
}

// One range of `registry_flush`: the pairs whose first work unit lies in the range, each
// applying the owner log in order and then its segment of every publish range in range
// order.
const RegistryFlushJob = struct {
    system: *PathfindingSystem,
    // Per registry index, its cache's owner log.
    ops: [registry_index_count][]const OwnerOp,
    publish_ranges: usize,
    // Install each pair's prepared owner heads after its ops and adds.
    truncate: bool,
    range_count: usize,
    // Per pair, its first work unit, increasing; the last entry is the unit total.
    unit_starts: [flush_pair_count + 1]usize,
};

fn orderUnit(unit: usize, start: usize) std.math.Order {
    return std.math.order(unit, start);
}

// SIMD verdict: scalar. Hash probes and list links per op and add; one binary search over
// the pair starts per range.
fn registryFlushJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RegistryFlushJob = @ptrCast(@alignCast(context));
    const system = job.system;
    const starts = job.unit_starts[0..flush_pair_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.unit_starts[flush_pair_count]);
    var pair = std.sort.lowerBound(usize, starts, range.start, orderUnit);
    while (pair < flush_pair_count and starts[pair] < range.end) : (pair += 1) {
        std.debug.assert(pair < system.flush_tallies.len);
        const map = system.flushPairMap(pair);
        var removed: usize = 0;
        for (job.ops[pair / registry_shard_count]) |op| {
            // Most owners hold runs in few shards.
            if (!map.holdsOwner(op.old)) continue;
            if (op.new == no_owner) removed += map.removeOwner(op.old) else map.renameOwner(op.old, op.new);
        }
        var added: usize = 0;
        for (system.publish_bands.items[0..job.publish_ranges], system.publish_range_bases.items[0..job.publish_ranges]) |band, base| {
            var start = base;
            for (band.counts[0..pair]) |pair_count| start += pair_count;
            map.addAll(system.reg_buckets.items[start..][0..band.counts[pair]]);
            added += band.counts[pair];
        }
        if (job.truncate) map.installTruncate();
        system.flush_tallies[pair] = .{ .removed = removed, .added = added };
    }
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

// A level's chunk grid size.
const ChunkGrid = struct {
    chunks_x: usize,
    chunks_y: usize,
};

// A chunk key's level, in bits 32-47.
fn keyLevel(key: u64) u16 {
    return @intCast(key >> 32);
}

fn keyChunk(key: u64) u32 {
    return @truncate(key);
}

fn orderKey(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}

// Bit of halo offset (dx, dy) in an `EvictItem.owned` mask.
fn haloBit(dx: isize, dy: isize) u16 {
    // Offsets are -1, 0, or 1: bits 0..8.
    return @as(u16, 1) << @intCast((dy + 1) * 3 + (dx + 1));
}

// A chunk of a level's grid: its key and coordinates.
const ChunkAt = struct {
    key: u64,
    x: usize,
    y: usize,
};

// The chunk at (x + dx, y + dy) on `level`, or null past the level's chunk grid.
fn chunkAround(chunks: ChunkGrid, level: u16, x: usize, y: usize, dx: isize, dy: isize) ?ChunkAt {
    // Chunk coordinates stay below 2^31.
    const nx = @as(isize, @intCast(x)) + dx;
    const ny = @as(isize, @intCast(y)) + dy;
    if (nx < 0 or ny < 0 or nx >= @as(isize, @intCast(chunks.chunks_x)) or ny >= @as(isize, @intCast(chunks.chunks_y))) return null;
    const at_x: usize = @intCast(nx);
    const at_y: usize = @intCast(ny);
    return .{ .key = chunkKey(level, @intCast(at_y * chunks.chunks_x + at_x)), .x = at_x, .y = at_y };
}

// One range of `nav_evict_count`, per dirty key: for a changed key, the registered halo
// keys it owns and their registration count (changed key K owns halo key H iff no changed
// key in H's 3x3 block sorts before it); and the negatives on its chunk list and on the
// superchunk, level, and world lists it owns (the first dirty key in each). Every list is
// walked once whatever the partition.
const EvictCountJob = struct {
    // The batch's dirty and changed keys, sorted.
    keys: []const u64,
    changed_keys: []const u64,
    readers: [registry_shard_count]ChunkListMap.Reader,
    negative_readers: [registry_shard_count]ChunkListMap.Reader,
    chunks: ChunkGrid,
    items: []EvictItem,
    range_count: usize,
};

// SIMD verdict: scalar. Binary searches over sorted u64 keys and hash probes; simd.zig has
// no u64 lanes.
fn evictCountJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *EvictCountJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len and range.end <= job.keys.len);
    for (range.start..range.end) |index| {
        const key = job.keys[index];
        const level = keyLevel(key);
        const x = keyChunk(key) % job.chunks.chunks_x;
        const y = keyChunk(key) / job.chunks.chunks_x;
        var item = EvictItem{};
        if (std.sort.binarySearch(u64, job.changed_keys, key, orderKey)) |changed_index| {
            // Changed keys are fewer than the registries' u32 ids.
            item.changed_index = @intCast(changed_index);
            inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
                if (chunkAround(job.chunks, level, x, y, dx, dy)) |halo| {
                    // A halo key with no registration has nothing to walk.
                    const registrations = job.readers[registryShard(halo.key)].keyCount(halo.key);
                    if (registrations != 0 and ownsHalo(job.changed_keys[0..changed_index], key, job.chunks, level, halo.x, halo.y)) {
                        item.owned |= haloBit(dx, dy);
                        item.bound += registrations;
                    }
                }
            };
        }
        item.negative_bound = negativeListCount(job.negative_readers, key);
        const superchunk = superchunkOf(job.chunks, level, x, y);
        const superchunk_count = negativeListCount(job.negative_readers, superchunk);
        if (superchunk_count != 0 and ownsSuperchunk(job.keys[0..index], job.chunks, level, x, y)) {
            item.owned |= evict_owns_superchunk;
            item.negative_bound += superchunk_count;
        }
        if (index == 0 or keyLevel(job.keys[index - 1]) != level) {
            item.owned |= evict_owns_level;
            item.negative_bound += negativeListCount(job.negative_readers, levelKey(level));
        }
        if (index == 0) {
            item.owned |= evict_owns_world;
            item.negative_bound += negativeListCount(job.negative_readers, world_key);
        }
        job.items[index] = item;
    }
}

fn negativeListCount(readers: [registry_shard_count]ChunkListMap.Reader, key: u64) u32 {
    return readers[registryShard(key)].keyCount(key);
}

// The superchunk key of chunk (x, y) on `level`.
fn superchunkOf(chunks: ChunkGrid, level: u16, x: usize, y: usize) u64 {
    const superchunks_x = (chunks.chunks_x + superchunk_edge - 1) / superchunk_edge;
    // A level's superchunk count stays below its chunk count, below 2^31.
    return superchunkKey(level, @intCast((y / superchunk_edge) * superchunks_x + x / superchunk_edge));
}

// Whether no key of `earlier` (the dirty keys below chunk (x, y)'s, sorted) lies in its
// superchunk: one search per superchunk row.
fn ownsSuperchunk(earlier: []const u64, chunks: ChunkGrid, level: u16, x: usize, y: usize) bool {
    const first_x = x / superchunk_edge * superchunk_edge;
    const end_x = @min(first_x + superchunk_edge, chunks.chunks_x);
    const first_y = y / superchunk_edge * superchunk_edge;
    for (first_y..@min(first_y + superchunk_edge, chunks.chunks_y)) |row| {
        // Chunk indices of a level stay below 2^31.
        const row_first = chunkKey(level, @intCast(row * chunks.chunks_x + first_x));
        const row_end = chunkKey(level, @intCast(row * chunks.chunks_x + end_x));
        const at = std.sort.lowerBound(u64, earlier, row_first, orderKey);
        if (at < earlier.len and earlier[at] < row_end) return false;
    }
    return true;
}

// Whether `key` is the smallest changed key in the 3x3 block around chunk (x, y): no key
// of `earlier` (the changed keys below it, sorted) lies there.
fn ownsHalo(earlier: []const u64, key: u64, chunks: ChunkGrid, level: u16, x: usize, y: usize) bool {
    inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
        if (chunkAround(chunks, level, x, y, dx, dy)) |around| {
            if (around.key < key and std.sort.binarySearch(u64, earlier, around.key, orderKey) != null) return false;
        }
    };
    return true;
}

// One range of `nav_evict`, per dirty key, into its hit window: the owners whose runs in
// its owned halo keys reach a cell within one cell of a changed cell, the negatives on its
// owned lists, and the group fields with a costed cell within one cell of its changed cells.
const EvictJob = struct {
    cache: *const ResultCache,
    // The batch's dirty and changed keys, sorted, and each changed key's flipped cells.
    keys: []const u64,
    changed_keys: []const u64,
    masks: []const ChunkBits,
    readers: [registry_shard_count]ChunkListMap.Reader,
    negative_readers: [registry_shard_count]ChunkListMap.Reader,
    fields: []const GroupField,
    chunks: ChunkGrid,
    geometry: RunGeometry,
    chunk_edge: u16,
    items: []EvictItem,
    hits: []u32,
    range_count: usize,
};

// SIMD verdict: the dilation is word-parallel scalar (`dilateChanged3x3`); the list walks
// are pointer chases and the cell and field tests one bit or word per cell.
fn evictJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *EvictJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len and range.end <= job.keys.len);
    for (job.items[range.start..range.end], job.keys[range.start..range.end]) |*item, key| {
        const field_bound: usize = if (item.changed_index != no_changed_index) job.fields.len else 0;
        std.debug.assert(@as(usize, item.base) + item.bound + item.negative_bound + field_bound <= job.hits.len);
        evictNegatives(job, item, key);
        if (item.changed_index == no_changed_index) continue;
        evictFields(job, item, key);
        const level = keyLevel(key);
        const x = keyChunk(key) % job.chunks.chunks_x;
        const y = keyChunk(key) / job.chunks.chunks_x;
        var hits: u32 = 0;
        var visited: u32 = 0;
        var last_hit: u32 = no_owner;
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (item.owned & haloBit(dx, dy) != 0) {
                // An owned halo key lies in the level's chunk grid.
                const halo = chunkAround(job.chunks, level, x, y, dx, dy).?;
                var around: [9]ChunkBits = undefined;
                inline for (.{ -1, 0, 1 }) |ny| inline for (.{ -1, 0, 1 }) |nx| {
                    around[(ny + 1) * 3 + (nx + 1)] = if (chunkAround(job.chunks, level, halo.x, halo.y, nx, ny)) |neighbour| changedMask(job.changed_keys, job.masks, neighbour.key) else @splat(0);
                };
                const dilated = dilateChanged3x3(job.chunk_edge, &around);
                if (!std.mem.allEqual(u64, &dilated, 0)) {
                    const reader = job.readers[registryShard(halo.key)];
                    var entry = reader.head(halo.key);
                    while (entry != no_entry) : (entry = reader.next_entries[entry]) {
                        visited += 1;
                        const owner = reader.owners[entry];
                        if (owner == last_hit) continue;
                        if (!runHits(job.cache, job.geometry, owner, reader.orders[entry], level, halo.x, halo.y, &dilated)) continue;
                        // Each entry hits once, and the bound counts the owned lists' entries.
                        std.debug.assert(hits < item.bound);
                        job.hits[item.base + hits] = owner;
                        hits += 1;
                        last_hit = owner;
                    }
                }
            }
        };
        item.hits = hits;
        item.visited = visited;
    }
}

// Writes every negative on `key`'s chunk list and on the coarser lists `item` owns into its
// negative hits.
fn evictNegatives(job: *const EvictJob, item: *EvictItem, key: u64) void {
    const window = job.hits[item.base + item.bound ..][0..item.negative_bound];
    var hits: u32 = 0;
    const level = keyLevel(key);
    const x = keyChunk(key) % job.chunks.chunks_x;
    const y = keyChunk(key) / job.chunks.chunks_x;
    const lists = [_]struct { key: u64, owned: bool }{
        .{ .key = key, .owned = true },
        .{ .key = superchunkOf(job.chunks, level, x, y), .owned = item.owned & evict_owns_superchunk != 0 },
        .{ .key = levelKey(level), .owned = item.owned & evict_owns_level != 0 },
        .{ .key = world_key, .owned = item.owned & evict_owns_world != 0 },
    };
    for (lists) |list| {
        if (!list.owned) continue;
        const reader = job.negative_readers[registryShard(list.key)];
        var entry = reader.head(list.key);
        while (entry != no_entry) : (entry = reader.next_entries[entry]) {
            // The bound counts every owned list's entries.
            window[hits] = reader.owners[entry];
            hits += 1;
        }
    }
    std.debug.assert(hits == item.negative_bound);
    item.negative_hits = hits;
}

// Writes the slot of every group field with a costed cell within one cell of `key`'s
// changed cells into `item`'s field hits: the changed cells dilated into each chunk of the
// 3x3 block around `key`, tested against the field's costed bits there.
fn evictFields(job: *const EvictJob, item: *EvictItem, key: u64) void {
    const window = job.hits[item.base + item.bound + item.negative_bound ..][0..job.fields.len];
    const level = keyLevel(key);
    var any_field = false;
    for (job.fields) |field| any_field = any_field or (field.state != .empty and field.key.goal_level == level);
    if (!any_field) return;
    const x = keyChunk(key) % job.chunks.chunks_x;
    const y = keyChunk(key) / job.chunks.chunks_x;
    const mask = job.masks[item.changed_index];
    var near: [9]ChunkBits = undefined;
    var near_chunks: [9]?u32 = @splat(null);
    inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
        const at = (dy + 1) * 3 + (dx + 1);
        if (chunkAround(job.chunks, level, x, y, dx, dy)) |neighbour| {
            // This key's changed cells, seen from the neighbour at offset (-dx, -dy).
            var around: [9]ChunkBits = @splat(@splat(0));
            around[(1 - dy) * 3 + (1 - dx)] = mask;
            near[at] = dilateChanged3x3(job.chunk_edge, &around);
            near_chunks[at] = keyChunk(neighbour.key);
        }
    };
    var hits: u32 = 0;
    for (job.fields, 0..) |*field, slot| {
        if (field.state == .empty or field.key.goal_level != level) continue;
        for (near_chunks, &near) |chunk, *cells| {
            const near_chunk = chunk orelse continue;
            if (!field.costedNear(near_chunk, cells)) continue;
            // Field slots are few.
            window[hits] = @intCast(slot);
            hits += 1;
            break;
        }
    }
    item.field_hits = hits;
}

// The changed mask of `key` in the batch, or none.
fn changedMask(keys: []const u64, masks: []const ChunkBits, key: u64) ChunkBits {
    const index = std.sort.binarySearch(u64, keys, key, orderKey) orelse return @splat(0);
    return masks[index];
}

// Whether `owner`'s stored path, from cell `start` while it stays on `level` in chunk
// (chunk_x, chunk_y), has a cell set in `dilated` (chunk-local bits).
fn runHits(cache: *const ResultCache, geometry: RunGeometry, owner: u32, start: u32, level: u16, chunk_x: usize, chunk_y: usize, dilated: *const ChunkBits) bool {
    const record = cache.core.records.items[owner];
    // The registry lists only live owners between flushes.
    std.debug.assert(record.live);
    const words = cache.storedWords(owner);
    const view = types.stitchedView(words, record.extra.stitched_len);
    const cells = if (record.extra.stitched_len != 0) view.cells else words[0..record.extra.path_len];
    const levels: ?[]const u16 = if (record.extra.stitched_len != 0) view.levels else null;
    std.debug.assert(start < cells.len);
    if (levels == null and record.extra.path_level != level) return false;
    const local_mask: usize = (@as(usize, 1) << geometry.chunk_shift) - 1;
    var cursor = CellCursor.init(geometry.width, cells[start]);
    var index: usize = start;
    while (true) {
        if (levels) |column| {
            if (column[index] != level) return false;
        }
        if (cursor.x >> geometry.chunk_shift != chunk_x or cursor.y >> geometry.chunk_shift != chunk_y) return false;
        const local = ((cursor.y & local_mask) << geometry.chunk_shift) | (cursor.x & local_mask);
        if ((dilated[local / 64] >> @intCast(local % 64)) & 1 != 0) return true;
        index += 1;
        if (index == cells.len) return false;
        cursor.moveTo(cells[index]);
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
    // Start and goal share the level's one chunk, so no chunk box proven around the goal
    // leaves the start out: answered for this request only, never cached.
    try std.testing.expectEqual(@as(usize, 1), stats.start_unreachable);
    try std.testing.expectEqual(@as(usize, 0), stats.negatives_published);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 128, .y = 8 }, .default, null).status);
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
    system.clearCompleted();
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
    const nav_stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The cached path crossed the now-closed gap (5,3), so it was evicted and the
    // re-solve answers unreachable, not a stale cached available. The goal's side holds
    // more portals than the failed search claimed, so its proof stops on that budget and
    // nothing is cached.
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), after.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), after.start_unreachable);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);
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
    const stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expect(stats.remask_batch.item_count > 0);
    try std.testing.expectEqual(stats.dirty_chunks, stats.remask_batch.item_count);

    // The graph keeps its last remask; an update with no batch must not report it again.
    const idle = try system.applyNavUpdates(no_colliders, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), idle.incremental_rebuilds);
    try std.testing.expectEqual(BatchStats{}, idle.remask_batch);

    // A batch whose only mark misses every built level commits without changing the graph.
    const unbuilt = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = 99, .x = 2, .y = 2 }});
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
    const steady_cache = system.completed.core.slots.items.len;
    const steady_pool = system.worker_path_pool.items.len;
    // A constant agent count holds capacity (and every pool's backing) fixed across
    // many steps, so the per-step solve loop never reallocates after warmup.
    for (0..30) |_| {
        _ = try driveAgentCount(&system, &requesters, 16);
        try std.testing.expectEqual(steady_cap, system.effective_agent_capacity);
        try std.testing.expectEqual(steady_pending, system.pending.slotCount());
        try std.testing.expectEqual(steady_cache, system.completed.core.slots.items.len);
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
    const excluded_negative = cellWorld(5, 1);
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
    try publishTestPath(&system, key(&system, IntakeGoals.hit), &path, step, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.expired), &path, step -% 400, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.expired_negative), &path, step -% 400, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.prefilled(0)), &path, step -% 400, &put_stats);
    putTestNegative(&system, key(&system, IntakeGoals.negative), Enclosure.every_start, step);
    putTestNegative(&system, key(&system, IntakeGoals.expired_negative), Enclosure.every_start, step -% 400);
    // Every requester starts in the level's one chunk, inside this negative's box.
    putTestNegative(&system, key(&system, IntakeGoals.excluded_negative), .{ .level = 0, .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 }, step);
    return system;
}

// Claims a negative for `key` leaving out `enclosure` at `step`, in a publish of its own
// and with no registry key, then flushes.
fn putTestNegative(system: *PathfindingSystem, key: PathQueryKey, enclosure: Enclosure, step: u32) void {
    var stats = PathfindingStats{};
    system.negatives.core.beginPublish();
    _ = system.negatives.claim(key, enclosure, step, &stats);
    _ = system.flushRegistry(null, null);
}

// Stores the level-0 plain `path` for `key` at `step` as one publish would, its registry
// runs included, and flushes the registry.
fn publishTestPath(system: *PathfindingSystem, key: PathQueryKey, path: []const u32, step: u32, stats: *PathfindingStats) !void {
    system.completed.core.beginPublish();
    const claimed = system.completed.claim(key, path.len, 0, 0, step, stats);
    @memcpy(system.completed.destination(claimed)[0..path.len], path);
    _ = system.flushRegistry(null, null);
    const starts = try std.testing.allocator.alloc(u16, path.len);
    defer std.testing.allocator.free(starts);
    var counts: [registry_shard_count]u32 = @splat(0);
    const geometry = RunGeometry.of(&system.graph);
    const run_count = solve.splitRuns(geometry, path, null, 0, starts, &counts);
    for (starts[0..run_count]) |start| {
        const run_key = geometry.key(0, path[start]);
        const shard = &system.path_index[registryShard(run_key)];
        try shard.reserve(1, 1, system.completed.logicalCapacity());
        shard.add(claimed.owner, run_key, start);
    }
}

// Forty requests crossing every intake class, with repeats in different ranges.
fn writeIntakeScenarioRequests(stream: *RangeOutputStream(PathRequest), entity: EntityId) !void {
    const Kind = enum { hit, expired, negative, field, out_of_range, blocked, expired_negative, excluded_negative, prefilled, group, distinct };
    const Item = struct { kind: Kind, index: usize = 0 };
    const items = [_]Item{
        .{ .kind = .hit },                   .{ .kind = .expired },               .{ .kind = .negative },              .{ .kind = .field },
        .{ .kind = .out_of_range },          .{ .kind = .blocked },               .{ .kind = .expired_negative },      .{ .kind = .distinct },
        .{ .kind = .prefilled, .index = 1 }, .{ .kind = .group },                 .{ .kind = .prefilled },             .{ .kind = .distinct, .index = 1 },
        .{ .kind = .distinct, .index = 2 },  .{ .kind = .distinct, .index = 3 },  .{ .kind = .prefilled, .index = 2 }, .{ .kind = .excluded_negative },
        .{ .kind = .distinct, .index = 5 },  .{ .kind = .distinct, .index = 6 },  .{ .kind = .field },                 .{ .kind = .distinct, .index = 7 },
        .{ .kind = .distinct, .index = 8 },  .{ .kind = .distinct, .index = 9 },  .{ .kind = .distinct, .index = 10 }, .{ .kind = .distinct, .index = 11 },
        .{ .kind = .hit },                   .{ .kind = .prefilled, .index = 3 }, .{ .kind = .distinct, .index = 12 }, .{ .kind = .distinct, .index = 13 },
        .{ .kind = .group },                 .{ .kind = .distinct, .index = 14 }, .{ .kind = .expired },               .{ .kind = .negative },
        .{ .kind = .distinct, .index = 15 }, .{ .kind = .group },                 .{ .kind = .blocked },               .{ .kind = .distinct, .index = 16 },
        .{ .kind = .distinct, .index = 17 }, .{ .kind = .excluded_negative },     .{ .kind = .distinct },              .{ .kind = .distinct, .index = 19 },
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
            .excluded_negative => IntakeGoals.excluded_negative,
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
    try std.testing.expectEqual(expected.completed.core.slots.items.len, actual.completed.core.slots.items.len);
    for (expected.completed.core.slots.items, actual.completed.core.slots.items) |expected_slot, actual_slot| {
        try std.testing.expectEqualDeep(expected_slot, actual_slot);
    }
    try std.testing.expectEqual(expected.negatives.core.slots.items.len, actual.negatives.core.slots.items.len);
    for (expected.negatives.core.slots.items, actual.negatives.core.slots.items) |expected_slot, actual_slot| {
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
    // The scenario reaches every class: of the negatives, only the fresh one whose box
    // leaves the starts out answers.
    try std.testing.expectEqual(@as(usize, 2), serial_stats.group_field_samples);
    try std.testing.expectEqual(@as(usize, 2), serial_stats.available_results);
    try std.testing.expectEqual(@as(usize, 2), serial_stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), serial_stats.goal_projected);
    try std.testing.expect(serial_stats.dropped_requests > 1);
    try std.testing.expectEqual(intake_test_agents, serial.pending.len);
    try std.testing.expect(serial.completed.slotIndex(serial.graph.keyForWorld(0, IntakeGoals.expired, .default).?) == null);
    try std.testing.expect(serial.completed.slotIndex(serial.graph.keyForWorld(0, IntakeGoals.expired_negative, .default).?) == null);
    try std.testing.expect(serial.completed.slotIndex(serial.graph.keyForWorld(0, IntakeGoals.prefilled(0), .default).?) == null);
    // The expired negative was removed; the excluded one stays and its key went pending.
    try std.testing.expect(serial.negatives.lookup(serial.graph.keyForWorld(0, IntakeGoals.expired_negative, .default).?, serial.step_counter, 0) == null);
    const excluded_key = serial.graph.keyForWorld(0, IntakeGoals.excluded_negative, .default).?;
    try std.testing.expect(serial.negatives.lookup(excluded_key, serial.step_counter, 0) != null);
    try std.testing.expect(serial.pending_keys.contains(excluded_key));

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
    try std.testing.expectEqual(types.max_result_block_words * system.capacity.max_solved_requests_per_step, system.worker_run_starts.items.len);
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
    putTestNegative(&system, system.graph.keyForWorld(0, negative_goal, .default).?, Enclosure.every_start, system.step_counter);
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
    system.clearCompleted();
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

test "pathfinding a publish reserve out of memory claims nothing, leaves pending for retry, and still flushes logged ops (FailingAllocator)" {
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
    // The result is published again and aged past the TTL, so the failing step's intake
    // removes it and logs its retire.
    const aged_goal = cellWorld(1, 2);
    try std.testing.expectEqual(@as(usize, 1), (try solveIndividualGoals(&system, requester, &.{aged_goal}, 8)).available_results);
    system.clearCompleted();
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    try std.testing.expectEqual(@as(usize, 1), (try solveIndividualGoals(&system, requester, &.{aged_goal}, 8)).available_results);
    const aged_owner = system.completed.core.ownerOf(system.graph.keyForWorld(0, aged_goal, .default).?).?;
    system.completed.core.records.items[aged_owner].stamp -%= types.default_cache_ttl_steps + 1;
    var aged_registrations: usize = 0;
    for (&system.path_index) |*shard| aged_registrations += shard.entries.len - shard.entry_free.items.len;
    try std.testing.expect(aged_registrations != 0);

    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4) };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.allocator;
    system.allocator = failing.allocator();
    system.graph.allocator = failing.allocator();
    const failed = solveIndividualGoals(&system, requester, &(goals ++ [_]math.Vec2{aged_goal}), 8);
    system.allocator = original;
    system.graph.allocator = original;
    try std.testing.expectError(error.OutOfMemory, failed);

    try std.testing.expectEqual(@as(usize, 0), system.completed.count());
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    // The expired result's retire was flushed: no owner op waits and no registration remains.
    try std.testing.expectEqual(@as(usize, 0), system.completed.core.ownerLog().len);
    for (&system.path_index) |*shard| try std.testing.expectEqual(shard.entries.len, shard.entry_free.items.len);
    try std.testing.expectEqual(goals.len + 1, system.pending.len);
    for (goals) |goal| {
        try std.testing.expect(system.pending_keys.contains(system.graph.keyForWorld(0, goal, .default).?));
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }

    // With memory back, the next step publishes the same requests without new intake.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const retry = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), retry.accepted_requests);
    try std.testing.expectEqual(goals.len + 1, retry.available_results);
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
        try std.testing.expect(expected.len() > 1);
        try expectSameStitched(expected, cachedStitched(&threaded, 0, goal));
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
        try std.testing.expect(expected.len() > 1);
        try expectSameStitched(expected, cachedStitched(&threaded, 2, goal));
        var jumps_two_levels = false;
        for (expected.levels[0 .. expected.len() - 1], expected.levels[1..]) |from, to| jumps_two_levels = jumps_two_levels or (from == 0 and to == 2);
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
    for (goals) |goal| try expectSameStitched(cachedStitched(&serial, 2, goal), cachedStitched(&threaded, 2, goal));
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

// ---- Path registry, publish split, and scoped eviction ---------------------------

const TileId = @import("../../world_system.zig").TileId;
const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;

// A world `side` tiles a side in 4-tile chunks, open grass, with an obstacle layer to flip.
const RegistryWorld = struct {
    world: WorldSystem,
    obstacle: usize,
    grass: TileId,
    tree: TileId,
};

fn registryWorld(meta: *const WorldTilesetMeta, side: u16) !RegistryWorld {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try test_support.abstractTestWorld(meta, @as(f32, @floatFromInt(side)) * 32, @as(f32, @floatFromInt(side)) * 32);
    errdefer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    return .{ .world = world, .obstacle = obstacle, .grass = grass, .tree = tree };
}

// A system over `world` at the abstract capacity (4-tile chunks, a two-step shrink
// window), grown to `agent_count` agents.
fn registrySystem(data: *const DataSystem, world: *const WorldSystem, agent_count: usize) !PathfindingSystem {
    return registrySystemWith(data, world, agent_count, .{});
}

const RegistrySystemOptions = struct {
    // Inline stripe cells; a path past it is stored in a long block.
    stored_path_cells: ?usize = null,
    participants: usize = 1,
};

fn registrySystemWith(data: *const DataSystem, world: *const WorldSystem, agent_count: usize, options: RegistrySystemOptions) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = abstractCapacity();
    capacity.capacity_shrink_window = 2;
    capacity.worker_participant_count = options.participants;
    if (options.stored_path_cells) |cells| capacity.max_stored_path_cells = cells;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(data, world, null);
    try system.growForAgentCount(agent_count);
    return system;
}

// Route `index` across a registry world `side` tiles a side: distinct goals, each start
// mirrored through the center, so routes cross many chunks.
fn registryRoute(index: usize, side: u16) [2]math.Vec2 {
    const span: usize = side - 4;
    const goal_x: u16 = @intCast(2 + index % span);
    const goal_y: u16 = @intCast(2 + (index / span * 3 + index % 3) % span);
    var start_x = side - 1 - goal_x;
    const start_y = side - 1 - goal_y;
    // The test world's two blocking decorations are no start.
    if ((start_x == side / 4 and start_y == side / 3) or (start_x == side * 3 / 4 and start_y == side * 2 / 3)) start_x += 1;
    return .{ tileCenter(start_x, start_y), tileCenter(goal_x, goal_y) };
}

fn registryRouteKey(system: *const PathfindingSystem, index: usize, side: u16) PathQueryKey {
    return system.graph.keyForWorld(0, registryRoute(index, side)[1], .default).?;
}

// Requests routes [first, first + count) and updates (on `threads` when given) until
// nothing is pending.
fn solveRegistryRoutes(system: *PathfindingSystem, requester: EntityId, side: u16, first: usize, count: usize, agent_count: usize, threads: ?*ThreadSystem, config: PathfindingConfig) !void {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (first..first + count) |index| {
        const route = registryRoute(index, side);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    var requests = &stream;
    for (0..16) |_| {
        if (threads) |thread_system| {
            _ = try system.update(requests, agent_count, thread_system, config);
        } else {
            _ = try system.updateSerial(requests, agent_count, config);
        }
        requests = &empty;
        if (system.pending.len == 0) return;
    }
    return error.TestRoutesStalled;
}

// A cached path's stored cells: its cells, and its levels (null: all on `level`).
const StoredPath = struct {
    cells: []const u32,
    levels: ?[]const u16,
    level: u16,

    fn levelAt(self: StoredPath, index: usize) u16 {
        return if (self.levels) |column| column[index] else self.level;
    }
};

fn storedPath(system: *const PathfindingSystem, owner: u32) StoredPath {
    const payload = system.completed.core.records.items[owner].extra;
    const words = system.completed.storedWords(owner);
    if (payload.stitched_len != 0) {
        const view = types.stitchedView(words, payload.stitched_len);
        return .{ .cells = view.cells, .levels = view.levels, .level = 0 };
    }
    return .{ .cells = words[0..payload.path_len], .levels = null, .level = payload.path_level };
}

const Registration = struct {
    key: u64,
    owner: u32,
    start: u32,

    fn lessThan(_: void, a: Registration, b: Registration) bool {
        if (a.key != b.key) return a.key < b.key;
        if (a.owner != b.owner) return a.owner < b.owner;
        return a.start < b.start;
    }
};

// The registry holds exactly the runs of every live cached path, each in its key's shard,
// with every key's count its list's length and every owner chain naming its own live
// owner; the owner log is empty.
fn expectRegistryMatchesCache(system: *const PathfindingSystem) !void {
    try std.testing.expectEqual(@as(usize, 0), system.completed.core.ownerLog().len);
    const allocator = std.testing.allocator;
    var expected: std.ArrayList(Registration) = .empty;
    defer expected.deinit(allocator);
    var actual: std.ArrayList(Registration) = .empty;
    defer actual.deinit(allocator);
    const geometry = RunGeometry.of(&system.graph);
    for (system.completed.core.records.items, 0..) |record, owner_index| {
        if (!record.live) continue;
        const owner: u32 = @intCast(owner_index);
        const path = storedPath(system, owner);
        const starts = try allocator.alloc(u16, @max(path.cells.len, 1));
        defer allocator.free(starts);
        var counts: [registry_shard_count]u32 = @splat(0);
        const run_count = solve.splitRuns(geometry, path.cells, path.levels, path.level, starts, &counts);
        for (starts[0..run_count]) |start| try expected.append(allocator, .{ .key = geometry.key(path.levelAt(start), path.cells[start]), .owner = owner, .start = start });
    }
    for (&system.path_index, 0..) |*shard, shard_index| {
        for (shard.slot_keys, 0..) |key, slot| {
            if (key == std.math.maxInt(u64)) continue;
            try std.testing.expectEqual(shard_index, registryShard(key));
            var length: u32 = 0;
            var entry = shard.slot_heads[slot];
            while (entry != no_entry) : (entry = shard.entry_next[entry]) {
                length += 1;
                try actual.append(allocator, .{ .key = key, .owner = shard.entry_owner[entry], .start = shard.entry_order[entry] });
            }
            try std.testing.expect(length != 0);
            try std.testing.expectEqual(length, shard.slot_counts[slot]);
        }
        try std.testing.expect(shard.owner_heads.items.len >= system.completed.logicalCapacity());
        for (shard.owner_heads.items, 0..) |owner_head, owner| {
            var entry = owner_head;
            while (entry != no_entry) : (entry = shard.entry_owner_next[entry]) {
                try std.testing.expectEqual(@as(u32, @intCast(owner)), shard.entry_owner[entry]);
                try std.testing.expect(system.completed.core.records.items[owner].live);
            }
        }
    }
    std.mem.sort(Registration, expected.items, {}, Registration.lessThan);
    std.mem.sort(Registration, actual.items, {}, Registration.lessThan);
    try std.testing.expectEqualSlices(Registration, expected.items, actual.items);
}

// Two systems' registries hold the same keys in the same slots and the same lists in the
// same order.
fn expectSameRegistry(a: *const PathfindingSystem, b: *const PathfindingSystem) !void {
    for (&a.path_index, &b.path_index) |*shard_a, *shard_b| {
        try std.testing.expectEqualSlices(u64, shard_a.slot_keys, shard_b.slot_keys);
        for (shard_a.slot_keys, 0..) |key, slot| {
            if (key == std.math.maxInt(u64)) continue;
            var entry_a = shard_a.slot_heads[slot];
            var entry_b = shard_b.slot_heads[slot];
            while (entry_a != no_entry or entry_b != no_entry) {
                try std.testing.expect(entry_a != no_entry and entry_b != no_entry);
                try std.testing.expectEqual(shard_a.entry_owner[entry_a], shard_b.entry_owner[entry_b]);
                try std.testing.expectEqual(shard_a.entry_order[entry_a], shard_b.entry_order[entry_b]);
                entry_a = shard_a.entry_next[entry_a];
                entry_b = shard_b.entry_next[entry_b];
            }
        }
    }
}

// Two systems' caches hold the same entries under the same owner ids and probe slots,
// with the same stored cells.
fn expectSameCache(a: *const PathfindingSystem, b: *const PathfindingSystem) !void {
    try std.testing.expectEqual(a.completed.count(), b.completed.count());
    try std.testing.expectEqual(a.completed.logicalCapacity(), b.completed.logicalCapacity());
    for (a.completed.core.slots.items, b.completed.core.slots.items) |slot_a, slot_b| {
        try std.testing.expectEqual(slot_a.occupied, slot_b.occupied);
        if (slot_a.occupied) try std.testing.expectEqual(slot_a.payload_index, slot_b.payload_index);
    }
    for (a.completed.core.records.items, b.completed.core.records.items, 0..) |record_a, record_b, owner| {
        try std.testing.expectEqual(record_a.live, record_b.live);
        if (!record_a.live) continue;
        try std.testing.expect(keysEqual(a.completed.core.keyOf(@intCast(owner)), b.completed.core.keyOf(@intCast(owner))));
        try std.testing.expectEqual(record_a.stamp, record_b.stamp);
        try std.testing.expectEqualDeep(record_a.extra, record_b.extra);
        const words = types.storedPathWords(record_a.extra.path_len, record_a.extra.stitched_len);
        try std.testing.expectEqualSlices(u32, a.completed.storedWords(owner)[0..words], b.completed.storedWords(owner)[0..words]);
    }
}

// Whether a stored cell of `owner`'s path lies within one cell (8-neighbour) of one of
// `changed` ((level, x, y) cells).
fn pathNearCells(system: *const PathfindingSystem, owner: u32, changed: []const [3]u16) bool {
    const path = storedPath(system, owner);
    const width = system.graph.width;
    for (path.cells, 0..) |cell, index| {
        const x: isize = @intCast(cell % width);
        const y: isize = @intCast(cell / width);
        for (changed) |change| {
            if (change[0] != path.levelAt(index)) continue;
            if (@abs(x - @as(isize, change[1])) <= 1 and @abs(y - @as(isize, change[2])) <= 1) return true;
        }
    }
    return false;
}

// Sets each (x, y) of `cells` on the obstacle layer to `tile` and records it for nav.
fn setRegistryCells(system: *PathfindingSystem, fixture: *RegistryWorld, cells: []const [2]u16, tile: TileId) !void {
    for (cells) |cell| {
        const changed = (try fixture.world.setDenseTile(fixture.obstacle, cell[0], cell[1], tile)) orelse continue;
        try system.markNavDirty(changed.level, changed.x, changed.y);
    }
}

test "the path registry holds every run of every published path, and the incremental registry equals one rebuilt from the live cache after victims, TTL expiry, evictions, re-puts, and a shrink with renames" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 64), system.completed.logicalCapacity());

    // Published paths, then victims: more routes than the 64 entries hold.
    try solveRegistryRoutes(&system, requester, 24, 0, 16, 16, null, .{});
    try expectRegistryMatchesCache(&system);
    for (1..6) |batch| try solveRegistryRoutes(&system, requester, 24, batch * 16, 16, 16, null, .{});
    try std.testing.expect(system.completed.count() == 64);
    try expectRegistryMatchesCache(&system);

    // TTL expiry: an aged entry removed at intake.
    const aged = system.completed.core.ownerOf(registryRouteKey(&system, 90, 24)).?;
    system.completed.core.records.items[aged].stamp -%= types.default_cache_ttl_steps + 1;
    try solveRegistryRoutes(&system, requester, 24, 90, 1, 16, null, .{});
    try expectRegistryMatchesCache(&system);

    // Evictions: a dig across the middle of the map.
    try setRegistryCells(&system, &fixture, &.{ .{ 11, 11 }, .{ 12, 11 }, .{ 12, 12 } }, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(reaction.evicted_results != 0);
    try expectRegistryMatchesCache(&system);

    // A re-put: the same key published with a different path.
    var put_stats = PathfindingStats{};
    var reput_key = emptyKey(system.graph.version);
    for (system.completed.core.records.items, 0..) |record, owner| {
        if (record.live) reput_key = system.completed.core.keyOf(@intCast(owner));
    }
    try publishTestPath(&system, reput_key, &.{ 30, 31, 55, 79 }, system.step_counter, &put_stats);
    try expectRegistryMatchesCache(&system);

    // A shrink with renames: sustained low load drops the capacity to the floor's 32.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..system.capacity.capacity_shrink_window) |_| _ = try system.updateSerial(&empty, 1, .{});
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    try expectRegistryMatchesCache(&system);
}

test "re-putting a key replaces its registrations" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    var stats = PathfindingStats{};
    var key = emptyKey(system.graph.version);
    key.goal = .{ .x = 20, .y = 20 };
    // Row 1 across three chunks, then column 22 across two others.
    try publishTestPath(&system, key, &.{ 25, 26, 27, 28, 29, 30, 31, 32, 33 }, 1, &stats);
    try expectRegistryMatchesCache(&system);
    try publishTestPath(&system, key, &.{ 22 + 24 * 10, 22 + 24 * 11, 22 + 24 * 12 }, 2, &stats);
    try expectRegistryMatchesCache(&system);
    // Only the second path's two runs remain.
    var registrations: usize = 0;
    for (&system.path_index) |*shard| registrations += shard.entries.len - shard.entry_free.items.len;
    try std.testing.expectEqual(@as(usize, 2), registrations);
}

test "eviction equals a brute-force reference: exactly the cached paths with a cell within one cell of a changed cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    const route_count = 60;
    // One cell; a block straddling chunk edges; a chunk corner; a cell keeping its tile.
    const changes = [_][]const [2]u16{
        &.{.{ 9, 13 }},
        &.{ .{ 7, 7 }, .{ 8, 7 }, .{ 7, 8 }, .{ 8, 8 }, .{ 9, 8 } },
        &.{.{ 15, 16 }},
        &.{.{ 3, 20 }},
    };
    for (changes) |cells| {
        try solveRegistryRoutes(&system, requester, 24, 0, route_count, 64, null, .{});
        try std.testing.expectEqual(@as(usize, route_count), system.completed.count());
        var flipped: [8][3]u16 = undefined;
        var flipped_count: usize = 0;
        for (cells) |cell| {
            if (cell[0] == 3 and cell[1] == 20) continue;
            flipped[flipped_count] = .{ 0, cell[0], cell[1] };
            flipped_count += 1;
        }
        var expected: [route_count]bool = undefined;
        for (&expected, 0..) |*evicted, index| evicted.* = pathNearCells(&system, system.completed.core.ownerOf(registryRouteKey(&system, index, 24)).?, flipped[0..flipped_count]);
        if (flipped_count == 0) {
            // The cell keeps its tile: marked, but no cell changed.
            try system.markNavDirty(0, cells[0][0], cells[0][1]);
        } else {
            try setRegistryCells(&system, &fixture, cells, fixture.tree);
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        var evicted_any = false;
        for (expected, 0..) |evicted, index| {
            try std.testing.expectEqual(evicted, system.completed.slotIndex(registryRouteKey(&system, index, 24)) == null);
            evicted_any = evicted_any or evicted;
        }
        try std.testing.expectEqual(flipped_count != 0, evicted_any);
        try expectRegistryMatchesCache(&system);
        if (flipped_count != 0) {
            try setRegistryCells(&system, &fixture, cells, fixture.grass);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        }
    }
}

test "a path that leaves and re-enters a chunk is evicted by a change on its second run" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    var stats = PathfindingStats{};
    var key = emptyKey(system.graph.version);
    key.goal = .{ .x = 3, .y = 2 };
    // (1,1) (2,1) (3,1) in chunk (0,0), (4,1) (5,1) (5,2) (4,2) in chunk (1,0), then (3,2)
    // back in chunk (0,0).
    const cell = struct {
        fn at(x: u32, y: u32) u32 {
            return y * 24 + x;
        }
    }.at;
    try publishTestPath(&system, key, &.{ cell(1, 1), cell(2, 1), cell(3, 1), cell(4, 1), cell(5, 1), cell(5, 2), cell(4, 2), cell(3, 2) }, 1, &stats);
    // (2,3) touches only the second run: two cells from every cell of the first.
    try setRegistryCells(&system, &fixture, &.{.{ 2, 3 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(key) == null);
    try expectRegistryMatchesCache(&system);
}

test "a path whose diagonal step corners on a changed cell in a diagonal-neighbour chunk is evicted" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    var stats = PathfindingStats{};
    var key = emptyKey(system.graph.version);
    key.goal = .{ .x = 5, .y = 5 };
    const cell = struct {
        fn at(x: u32, y: u32) u32 {
            return y * 24 + x;
        }
    }.at;
    // (5,3) in chunk (1,0), then diagonal steps through (4,4) and on to (5,5) in chunk (1,1):
    // only (4,4) neighbours (3,3), in chunk (0,0), the diagonal neighbour of (1,1).
    try publishTestPath(&system, key, &.{ cell(5, 3), cell(4, 4), cell(5, 5) }, 1, &stats);
    try setRegistryCells(&system, &fixture, &.{.{ 3, 3 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(key) == null);
    try expectRegistryMatchesCache(&system);
}

// Publishes `unrelated` one-cell paths in chunks two or more chunks from (1, 1), and three
// paths through chunk (1, 1) of a 64-tile registry world; digs (5, 5) and returns the
// registry entries the eviction visited.
fn visitedWithUnrelated(meta: *const WorldTilesetMeta, unrelated: usize) !usize {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try registryWorld(meta, 64);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 300);
    defer system.deinit();
    var stats = PathfindingStats{};
    var key = emptyKey(system.graph.version);
    for (0..unrelated) |index| {
        key.goal = .{ .x = @intCast(16 + index % 48), .y = @intCast(16 + index / 48) };
        const cell: u32 = @intCast(@as(usize, @intCast(key.goal.y)) * 64 + @as(usize, @intCast(key.goal.x)));
        try publishTestPath(&system, key, &.{cell}, 1, &stats);
    }
    for (0..3) |row| {
        key.goal = .{ .x = 0, .y = @intCast(row) };
        const y: u32 = @intCast(4 + row);
        try publishTestPath(&system, key, &.{ y * 64 + 4, y * 64 + 5, y * 64 + 6 }, 1, &stats);
    }
    try setRegistryCells(&system, &fixture, &.{.{ 5, 5 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 3), reaction.evicted_results);
    try expectRegistryMatchesCache(&system);
    return reaction.evict_entries_visited;
}

test "path eviction visits only results registered in the changed chunks' halo (equal entries visited with 10 and 1000 unrelated results)" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const few = try visitedWithUnrelated(&meta, 10);
    try std.testing.expectEqual(few, try visitedWithUnrelated(&meta, 1000));
    try std.testing.expectEqual(@as(usize, 3), few);
}

test "a new link evicts no cached path" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    _ = try fixture.world.addLevel(-16);
    _ = try fixture.world.addDenseLayer(1, 0, .floor, fixture.grass);
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    try solveRegistryRoutes(&system, requester, 24, 0, 40, 64, null, .{});
    const cached = system.completed.count();
    // A ramp on a cell a cached path crosses, and its far end below.
    const first = storedPath(&system, system.completed.core.ownerOf(registryRouteKey(&system, 0, 24)).?);
    const on_path: u16 = @intCast(first.cells[first.cells.len / 2]);
    const ramp_cell = @import("../../world_system.zig").CellCoord{ .x = @intCast(on_path % 24), .y = @intCast(on_path / 24) };
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 0, .cell_a = ramp_cell, .level_b = 1, .cell_b = ramp_cell, .traversal_cost = 1, .bidirectional = true });
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), reaction.evicted_results);
    try std.testing.expectEqual(cached, system.completed.count());
    try expectRegistryMatchesCache(&system);
}

test "a cached corridor is evicted only by a change on its own level's cells" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    _ = try fixture.world.addLevel(-16);
    _ = try fixture.world.addDenseLayer(1, 0, .floor, fixture.grass);
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    var stats = PathfindingStats{};
    // The same cells on level 0 and on level 1, and a corridor crossing (1, 0) on level 0
    // then dropping to level 1.
    var keys: [3]PathQueryKey = undefined;
    const corridors = [_][3]types.StitchedCell{
        .{ .{ .level = 0, .cell = 0 }, .{ .level = 0, .cell = 1 }, .{ .level = 0, .cell = 2 } },
        .{ .{ .level = 1, .cell = 0 }, .{ .level = 1, .cell = 1 }, .{ .level = 1, .cell = 2 } },
        .{ .{ .level = 0, .cell = 1 }, .{ .level = 1, .cell = 5 }, .{ .level = 1, .cell = 6 } },
    };
    for (&keys, corridors, 0..) |*key, corridor, index| {
        key.* = emptyKey(system.graph.version);
        key.goal = .{ .x = @intCast(10 + index), .y = 10 };
        try publishTestStitched(&system, key.*, &corridor, 1, &stats);
    }
    try expectRegistryMatchesCache(&system);
    // Level 0 cell (1, 1) neighbours level-0 cells 0..2 only.
    try setRegistryCells(&system, &fixture, &.{.{ 1, 1 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 2), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(keys[0]) == null);
    try std.testing.expect(system.completed.slotIndex(keys[1]) != null);
    try std.testing.expect(system.completed.slotIndex(keys[2]) == null);
    try expectRegistryMatchesCache(&system);
}

// Stores the stitched `corridor` for `key` at `step` as one publish would, its registry
// runs included, and flushes the registry.
fn publishTestStitched(system: *PathfindingSystem, key: PathQueryKey, corridor: []const types.StitchedCell, step: u32, stats: *PathfindingStats) !void {
    system.completed.core.beginPublish();
    const claimed = system.completed.claim(key, 0, corridor.len, corridor[0].level, step, stats);
    types.writeStitched(system.completed.destination(claimed), corridor);
    _ = system.flushRegistry(null, null);
    const view = types.stitchedView(system.completed.destination(claimed), corridor.len);
    var starts: [64]u16 = undefined;
    var counts: [registry_shard_count]u32 = @splat(0);
    const geometry = RunGeometry.of(&system.graph);
    const run_count = solve.splitRuns(geometry, view.cells, view.levels, 0, &starts, &counts);
    for (starts[0..run_count]) |start| {
        const run_key = geometry.key(view.levels[start], view.cells[start]);
        const shard = &system.path_index[registryShard(run_key)];
        try shard.reserve(1, 1, system.completed.logicalCapacity());
        shard.add(claimed.owner, run_key, start);
    }
}

// Points every allocator `system` uses (its own, its graph's, and each registry shard's) at
// `allocator`.
fn setSystemAllocators(system: *PathfindingSystem, allocator: std.mem.Allocator) void {
    system.allocator = allocator;
    system.graph.allocator = allocator;
    for (&system.path_index, &system.negative_index) |*shard, *negative_shard| {
        shard.allocator = allocator;
        negative_shard.allocator = allocator;
    }
}

// A fixed-range threaded control: one item per range, so every stage with two or more items
// runs on workers.
const fixed_threads_config = PathfindingConfig{ .adaptive = false, .items_per_range = 1 };

test "threaded publish equals serial across range sizes and worker counts (cache bytes, per-shard lists, stats), and publish_copy and registry_flush run on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    // Eight-cell stripes: most routes are long results.
    var serial = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8 });
    defer serial.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (0..48) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    const serial_stats = try serial.updateSerial(&stream, 64, .{});
    try std.testing.expectEqual(@as(usize, 48), serial_stats.available_results);
    try std.testing.expect(serial_stats.registrations_added > 48);
    try std.testing.expect(serial.completed.long_block_count != 0);
    try expectRegistryMatchesCache(&serial);
    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        if (threads.workerThreadCount() == 0) return error.SkipZigTest;
        for ([_]usize{ 1, 3, 8 }) |items_per_range| {
            var threaded = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8, .participants = threads.participantSlotCount() });
            defer threaded.deinit();
            const stats = try threaded.update(&stream, 64, &threads, .{ .adaptive = false, .items_per_range = items_per_range });
            try expectSameCache(&serial, &threaded);
            try expectSameRegistry(&serial, &threaded);
            try std.testing.expectEqual(serial_stats.available_results, stats.available_results);
            try std.testing.expectEqual(serial_stats.registrations_added, stats.registrations_added);
            try std.testing.expectEqual(serial_stats.registrations_removed, stats.registrations_removed);
            try std.testing.expectEqual(serial_stats.cache_evictions, stats.cache_evictions);
            if (items_per_range == 1) {
                try std.testing.expect(!stats.publish_copy_batch.ran_inline and stats.publish_copy_batch.range_count > 1);
                try std.testing.expect(!stats.registry_flush_batch.ran_inline and stats.registry_flush_batch.range_count > 1);
            }
        }
    }
}

// Work units of a registry flush over `path_ops` and `negative_ops` logged ops and `adds`
// pending registrations: every pair weighs its index's whole log, its adds, and one.
fn flushUnits(path_ops: usize, negative_ops: usize, adds: usize) usize {
    return registry_shard_count * (path_ops + 1) + registry_shard_count * (negative_ops + 1) + adds;
}

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
    try system.resizePreservingLiveState(1, null);
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    var stats = PathfindingStats{};
    system.completed.core.beginPublish();
    const reput = system.completed.core.keyOf(0);
    var fresh = [_]PathQueryKey{ reput, emptyKey(system.graph.version), emptyKey(system.graph.version) };
    fresh[1].goal = .{ .x = 0, .y = 30 };
    fresh[2].goal = .{ .x = 1, .y = 30 };
    for (fresh) |key| {
        const claimed = system.completed.claim(key, 1, 0, 0, system.step_counter, &stats);
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
    const units = flushUnits(ops.len, 0, 0);
    var serial_stats = PathfindingStats{};
    const serial_batch = systems[0].flushRegistry(null, &serial_stats);
    try std.testing.expectEqual(units, serial_batch.item_count);
    var threaded_stats = PathfindingStats{};
    const stage = (PathfindingSystem.StageThreads{ .thread_system = &threads, .config = fixed_threads_config }).stage(&systems[1].registry_flush_tuner);
    const batch = systems[1].flushRegistry(stage, &threaded_stats);
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
    const serial_batch = serial.flushRegistry(null, &serial_stats);
    try std.testing.expect(serial_stats.registrations_removed != 0 and serial_stats.registrations_added != 0);
    const units = flushUnits(ops, 0, serial_stats.registrations_added);
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
            const stage = (PathfindingSystem.StageThreads{ .thread_system = &threads, .config = config }).stage(&threaded.registry_flush_tuner);
            const batch = threaded.flushRegistry(stage, &stats);
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

test "publish after its reserve allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
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
    var system = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8, .participants = threads.participantSlotCount() });
    defer system.deinit();
    // One publish of the routes reserves the registry, its windows, and long pages; cleared,
    // the same publish fits them.
    try solveRegistryRoutes(&system, requester, 24, 0, 48, 64, &threads, fixed_threads_config);
    system.clearRuntimeState();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (0..48) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const stats = system.update(&stream, 64, &threads, fixed_threads_config);
    setSystemAllocators(&system, std.testing.allocator);
    const published = try stats;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 48), published.available_results);
    try std.testing.expect(!published.publish_copy_batch.ran_inline and !published.registry_flush_batch.ran_inline);
    const units = flushUnits(0, 0, published.registrations_added);
    try std.testing.expectEqual(units, published.registry_flush_batch.item_count);
    try std.testing.expectEqual(units, published.registry_flush_batch.range_count);
    try expectRegistryMatchesCache(&system);
}

// Flips one cell in each of 20 chunks (a 5 x 4 chunk block) of a 24-tile registry world.
const dense_change_cells = blk: {
    var cells: [20][2]u16 = undefined;
    for (&cells, 0..) |*cell, index| cell.* = .{ 2 + 4 * (index % 5), 2 + 4 * (index / 5) };
    break :blk cells;
};

test "eviction allocates nothing after its pre-commit reserve on a multi-worker ThreadSystem (FailingAllocator)" {
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
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;
    // A warm cycle sizes the eviction scratch and the nav batch buffers.
    try solveRegistryRoutes(&system, requester, 24, 0, 60, 64, null, .{});
    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try solveRegistryRoutes(&system, requester, 24, 0, 60, 64, null, .{});

    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.tree);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const reaction = system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    setSystemAllocators(&system, std.testing.allocator);
    const stats = try reaction;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(stats.evicted_results != 0);
    try std.testing.expect(!stats.evict_count_batch.ran_inline and !stats.evict_batch.ran_inline);
    try expectRegistryMatchesCache(&system);
}

test "an eviction reserve out of memory leaves graph, cache, registry, and marks intact, and the retry equals an unfailed apply" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var reference = try registrySystem(&data, &fixture.world, 64);
    defer reference.deinit();
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    try solveRegistryRoutes(&reference, requester, 24, 0, 60, 64, null, .{});
    try solveRegistryRoutes(&system, requester, 24, 0, 60, 64, null, .{});
    const cached = system.completed.count();
    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.tree);
    for (dense_change_cells) |cell| try reference.markNavDirty(0, cell[0], cell[1]);
    _ = try reference.applyBufferedNavUpdates(no_colliders, &fixture.world, null);

    // Every allocation of the apply fails in turn; the eviction scratch grows here for the
    // first time, so some attempt fails at the eviction reserve after the graph's.
    const marks = system.nav_marks.items.len;
    var failed_at_eviction: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        const items_before = system.evict_items.capacity;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        system.allocator = failing.allocator();
        system.graph.allocator = failing.allocator();
        const result = system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        system.allocator = std.testing.allocator;
        system.graph.allocator = std.testing.allocator;
        if (result) |_| break else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (system.evict_items.capacity != items_before or system.evict_hits.capacity == 0) failed_at_eviction += 1;
        // Nothing changed: the dug cells read open, every path is cached and registered,
        // and the marks wait for the retry.
        for (dense_change_cells) |cell| try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(.{ .x = cell[0], .y = cell[1] }));
        try std.testing.expectEqual(cached, system.completed.count());
        try std.testing.expectEqual(marks, system.nav_marks.items.len);
        try expectRegistryMatchesCache(&system);
    }
    try std.testing.expect(failed_at_eviction != 0);
    try expectSameCache(&reference, &system);
    try expectSameRegistry(&reference, &system);
}

test "threaded eviction equals serial over a dense region (bounds, flags, hits, cache bytes), and the eviction stages run on workers" {
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
    var serial = try registrySystem(&data, &fixture.world, 64);
    defer serial.deinit();
    var threaded = try registrySystem(&data, &fixture.world, 64);
    defer threaded.deinit();
    threaded.nav_thread_adaptive = false;
    threaded.nav_thread_items_per_range = 1;
    try solveRegistryRoutes(&serial, requester, 24, 0, 60, 64, null, .{});
    try solveRegistryRoutes(&threaded, requester, 24, 0, 60, 64, null, .{});
    try setRegistryCells(&serial, &fixture, &dense_change_cells, fixture.tree);
    for (dense_change_cells) |cell| try threaded.markNavDirty(0, cell[0], cell[1]);
    const serial_stats = try serial.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const stats = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expect(!stats.evict_count_batch.ran_inline and stats.evict_count_batch.range_count > 1);
    try std.testing.expect(!stats.evict_batch.ran_inline and stats.evict_batch.range_count > 1);
    try std.testing.expect(serial_stats.evicted_results != 0);
    try std.testing.expectEqual(serial_stats.evicted_results, stats.evicted_results);
    try std.testing.expectEqual(serial_stats.evict_entries_visited, stats.evict_entries_visited);
    try std.testing.expectEqual(serial.evict_items.items.len, threaded.evict_items.items.len);
    for (serial.evict_items.items, threaded.evict_items.items) |a, b| {
        try std.testing.expectEqual(a.bound, b.bound);
        try std.testing.expectEqual(a.owned, b.owned);
        try std.testing.expectEqual(a.hits, b.hits);
        try std.testing.expectEqual(a.visited, b.visited);
        try std.testing.expectEqualSlices(u32, serial.evict_hits.items[a.base..][0..a.hits], threaded.evict_hits.items[b.base..][0..b.hits]);
    }
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
    try expectHaloOwnedOnce(&threaded);
}

// Every key in a changed key's 3x3 block that held registrations before the eviction is
// owned by exactly one changed key of the last batch.
fn expectHaloOwnedOnce(system: *const PathfindingSystem) !void {
    var owned = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer owned.deinit();
    const chunks = system.chunkGrid();
    const keys = system.graph.changed_keys.items;
    for (system.graph.dirty_keys.items, system.evict_items.items) |key, item| {
        if (item.changed_index == no_changed_index) continue;
        try std.testing.expectEqual(key, keys[item.changed_index]);
        const x = keyChunk(key) % chunks.chunks_x;
        const y = keyChunk(key) / chunks.chunks_x;
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (item.owned & haloBit(dx, dy) != 0) {
                const halo = chunkAround(chunks, keyLevel(key), x, y, dx, dy).?;
                try std.testing.expect(!owned.contains(halo.key));
                try owned.put(halo.key, {});
            }
        };
    }
    // A walk visits at most its owned lists: a key no changed cell neighbours is skipped.
    for (system.evict_items.items) |item| try std.testing.expect(item.visited <= item.bound and item.hits <= item.bound);
    for (keys) |key| {
        const x = keyChunk(key) % chunks.chunks_x;
        const y = keyChunk(key) / chunks.chunks_x;
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (chunkAround(chunks, keyLevel(key), x, y, dx, dy)) |halo| {
                // A key whose runs were all evicted holds none now; it was owned if it held any.
                if (system.path_index[registryShard(halo.key)].keyCount(halo.key) != 0) try std.testing.expect(owned.contains(halo.key));
            }
        };
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

// Two registry systems filled alike with long and inline results, for a shrink to the
// floor's 32 entries.
fn shrinkFixture(data: *const DataSystem, fixture: *const RegistryWorld, requester: EntityId, participants: usize) !PathfindingSystem {
    var system = try registrySystemWith(data, &fixture.world, 16, .{ .stored_path_cells = 8, .participants = participants });
    errdefer system.deinit();
    for (0..4) |batch| try solveRegistryRoutes(&system, requester, 24, batch * 16, 16, 16, null, .{});
    try std.testing.expectEqual(@as(usize, 64), system.completed.count());
    return system;
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
    try serial.resizePreservingLiveState(1, null);
    try threaded.resizePreservingLiveState(1, PathfindingSystem.StageThreads{ .thread_system = &threads, .config = fixed_threads_config });
    try std.testing.expect(serial.last_resize_copy_batch.ran_inline);
    try std.testing.expect(!threaded.last_resize_copy_batch.ran_inline and threaded.last_resize_copy_batch.range_count > 1);
    try std.testing.expectEqual(serial.last_resize_copy_batch.item_count, threaded.last_resize_copy_batch.item_count);
    _ = serial.flushRegistry(null, null);
    _ = threaded.flushRegistry(null, null);
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
    const units = flushUnits(system.completed.core.ownerLog().len, 0, 0);
    // Every allocation and every in-place resize fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const stage = (PathfindingSystem.StageThreads{ .thread_system = &threads, .config = fixed_threads_config });
    const batch = system.runResizeCopy(stage.stage(&system.resize_copy_tuner));
    const flush = system.flushRegistry(stage.stage(&system.registry_flush_tuner), null);
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

const ShrinkFlushes = struct {
    serial: BatchStats = .{},
    threaded: BatchStats = .{},
};

// Two registry systems over one world, filled alike, then shrunk by sustained low load:
// one serial, one on `threads` under `config`. Returns each shrink step's flush batch.
fn shrinkThroughUpdates(serial: *PathfindingSystem, threaded: *PathfindingSystem, threads: *ThreadSystem, config: PathfindingConfig) !ShrinkFlushes {
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    var flushes = ShrinkFlushes{};
    for (0..serial.capacity.capacity_shrink_window) |_| {
        const serial_capacity = serial.completed.logicalCapacity();
        const serial_stats = try serial.updateSerial(&empty, 1, .{});
        if (serial.completed.logicalCapacity() < serial_capacity) flushes.serial = serial_stats.registry_flush_batch;
        const capacity = threaded.completed.logicalCapacity();
        const stats = try threaded.update(&empty, 1, threads, config);
        if (threaded.completed.logicalCapacity() < capacity) flushes.threaded = stats.registry_flush_batch;
    }
    return flushes;
}

test "a shrink's registry flush runs on workers at about one pair per range under the adaptive control, renames included, and equals the serial flush" {
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
    // The shrink's fixed-shape flush leaves the flush tuner untouched.
    const tuner_before = threaded.registry_flush_tuner.report();
    const flushes = try shrinkThroughUpdates(&serial, &threaded, &threads, .{});
    const flush = flushes.threaded;
    const tuner_after = threaded.registry_flush_tuner.report();
    try std.testing.expectEqual(tuner_before.sample_count, tuner_after.sample_count);
    try std.testing.expectEqual(tuner_before.phase, tuner_after.phase);
    try std.testing.expectEqual(tuner_before.current_profile, tuner_after.current_profile);
    try std.testing.expectEqual(@as(usize, 32), threaded.completed.logicalCapacity());
    try std.testing.expect(!flush.ran_inline and flush.active_worker_threads != 0 and flush.worker_thread_ranges != 0);
    // The fixed shape is ceil(units / pairs) units per range; at a pair count's square of
    // units or more that is exactly one range per pair.
    try std.testing.expectEqual(flushes.serial.item_count, flush.item_count);
    try std.testing.expect(flush.item_count >= flush_pair_count * flush_pair_count);
    try std.testing.expectEqual((flush.item_count + flush_pair_count - 1) / flush_pair_count, flush.items_per_range);
    try std.testing.expectEqual(flush_pair_count, flush.range_count);
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
    for (&threaded.path_index) |*shard| try std.testing.expectEqual(@as(usize, 32), shard.owner_heads.items.len);
}

test "a shrink's registry flush keeps a configured range size and equals the serial flush" {
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
    const units_per_range = 4;
    const flushes = try shrinkThroughUpdates(&serial, &threaded, &threads, .{ .items_per_range = units_per_range });
    const flush = flushes.threaded;
    try std.testing.expectEqual(@as(usize, 32), threaded.completed.logicalCapacity());
    try std.testing.expect(!flush.ran_inline);
    try std.testing.expectEqual(flushes.serial.item_count, flush.item_count);
    try std.testing.expect(flush.item_count > flush_pair_count * units_per_range);
    try std.testing.expectEqual(units_per_range, flush.items_per_range);
    try std.testing.expectEqual((flush.item_count + units_per_range - 1) / units_per_range, flush.range_count);
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
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
    // The reserve drops back to the floor's 32 entries, evicting and moving.
    try system.reserve(system.capacity);
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

test "keys of one shard spread over its table (bounded probe length for a dense chunk block)" {
    // A 64 x 64 chunk block of one level: one shard's keys in a registry table.
    var map = ChunkListMap.init(std.testing.allocator, "test registry");
    defer map.deinit();
    const shard = 5;
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(std.testing.allocator);
    for (0..64 * 64) |chunk| {
        const key = chunkKey(3, @intCast(chunk));
        if (registryShard(key) == shard) try keys.append(std.testing.allocator, key);
    }
    try std.testing.expect(keys.items.len > 128);
    try map.reserve(keys.items.len, keys.items.len, keys.items.len);
    for (keys.items, 0..) |key, owner| map.add(@intCast(owner), key, 0);
    const reader = map.reader();
    const mask = reader.keys.len - 1;
    var total: usize = 0;
    var longest: usize = 0;
    for (keys.items) |key| {
        const home = types.fibonacciSlot(key, reader.shift);
        var distance: usize = 0;
        while (reader.keys[(home + distance) & mask] != key) distance += 1;
        total += distance;
        longest = @max(longest, distance);
    }
    // Linear probing at load <= 1/2 averages under one slot past home.
    try std.testing.expect(total <= keys.items.len);
    try std.testing.expect(longest <= 24);
}

// ---------------------------------------------------------------------------------------
// Negatives: goal-side proofs, scoped eviction, and the negative registry.
// ---------------------------------------------------------------------------------------

const pocket_world_side: u16 = 32;
const pocket_cells: u16 = 10;

// A registry world `side` tiles a side with a `pocket`-tile pocket at the origin, closed by
// a wall column x = `pocket` (rows 0 to `pocket`) and a wall row y = `pocket`.
fn pocketWorld(meta: *const WorldTilesetMeta, side: u16, pocket: u16) !RegistryWorld {
    var fixture = try registryWorld(meta, side);
    errdefer fixture.world.deinit();
    for (0..pocket + 1) |y| _ = try fixture.world.setDenseTile(fixture.obstacle, pocket, @intCast(y), fixture.tree);
    for (0..pocket) |x| _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), pocket, fixture.tree);
    return fixture;
}

fn pocketGoal(index: usize) math.Vec2 {
    return tileCenter(@intCast(index % pocket_cells), @intCast(index / pocket_cells));
}

// Starts outside the pocket, clear of the far decoration of a 32-tile world.
fn outsideStart(index: usize) math.Vec2 {
    return tileCenter(@intCast(1 + index % 20), @intCast(pocket_cells + 4 + index / 20));
}

fn pocketKey(system: *const PathfindingSystem, index: usize) PathQueryKey {
    return system.graph.keyForWorld(0, pocketGoal(index), .default).?;
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

fn solveFrom(system: *PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2, config: PathfindingConfig) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    return system.updateSerial(&stream, 16, config);
}

fn chunkCountsOf(system: *const PathfindingSystem) solve.ChunkCounts {
    const chunks = system.chunkGrid();
    return .{ .x = @intCast(chunks.chunks_x), .y = @intCast(chunks.chunks_y) };
}

// The keys a negative proven around its goal registers.
fn enclosureKeys(system: *const PathfindingSystem, enclosure: Enclosure) solve.NegativeKeys {
    return solve.NegativeKeys.cover(enclosure.level, .{ .min_x = enclosure.min_x, .min_y = enclosure.min_y, .max_x = enclosure.max_x, .max_y = enclosure.max_y }, chunkCountsOf(system));
}

// Claims a negative for `key` with `keys` registered, leaving out `enclosure`, at `step`, as
// one publish would, and flushes.
fn publishTestNegative(system: *PathfindingSystem, key: PathQueryKey, keys: solve.NegativeKeys, enclosure: Enclosure, step: u32) !void {
    var stats = PathfindingStats{};
    system.negatives.core.beginPublish();
    const owner = system.negatives.claim(key, enclosure, step, &stats);
    _ = system.flushRegistry(null, null);
    for (0..keys.count()) |index| {
        const registry_key = keys.keyAt(@intCast(index));
        const shard = &system.negative_index[registryShard(registry_key)];
        try shard.reserve(1, 1, system.negatives.logicalCapacity());
        shard.add(owner, registry_key, 0);
    }
}

// The negative registry lists only live negatives, every key in its shard with its count,
// every live negative holds a key, and one proven around its goal holds exactly the keys
// over its box; the owner log is empty.
fn expectNegativeRegistryMatchesCache(system: *const PathfindingSystem) !void {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), system.negatives.core.ownerLog().len);
    var held: std.ArrayList(Registration) = .empty;
    defer held.deinit(allocator);
    for (&system.negative_index, 0..) |*shard, shard_index| {
        for (shard.slot_keys, 0..) |key, slot| {
            if (key == std.math.maxInt(u64)) continue;
            try std.testing.expectEqual(shard_index, registryShard(key));
            var length: u32 = 0;
            var entry = shard.slot_heads[slot];
            while (entry != no_entry) : (entry = shard.entry_next[entry]) {
                length += 1;
                try std.testing.expect(system.negatives.core.records.items[shard.entry_owner[entry]].live);
                try held.append(allocator, .{ .key = key, .owner = shard.entry_owner[entry], .start = 0 });
            }
            try std.testing.expect(length != 0);
            try std.testing.expectEqual(length, shard.slot_counts[slot]);
        }
        try std.testing.expect(shard.owner_heads.items.len >= system.negatives.logicalCapacity());
        for (shard.owner_heads.items, 0..) |owner_head, owner| {
            var entry = owner_head;
            while (entry != no_entry) : (entry = shard.entry_owner_next[entry]) try std.testing.expectEqual(@as(u32, @intCast(owner)), shard.entry_owner[entry]);
        }
    }
    std.mem.sort(Registration, held.items, {}, Registration.lessThan);
    for (system.negatives.core.records.items, 0..) |record, owner_index| {
        if (!record.live) continue;
        const owner: u32 = @intCast(owner_index);
        var keys: std.ArrayList(u64) = .empty;
        defer keys.deinit(allocator);
        for (held.items) |registration| {
            if (registration.owner == owner) try keys.append(allocator, registration.key);
        }
        try std.testing.expect(keys.items.len != 0);
        const enclosure = record.extra;
        if (enclosure.min_x > enclosure.max_x) continue;
        // A goal projected off its key's blocked cell also registers its projection window.
        const key = system.negatives.core.keyOf(owner);
        if (system.graph.grid(key.goal_level).?.isBlockedCell(key.goal)) continue;
        const expected = enclosureKeys(system, enclosure);
        var expected_keys: std.ArrayList(u64) = .empty;
        defer expected_keys.deinit(allocator);
        for (0..expected.count()) |index| try expected_keys.append(allocator, expected.keyAt(@intCast(index)));
        std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));
        std.mem.sort(u64, expected_keys.items, {}, std.sort.asc(u64));
        try std.testing.expectEqualSlices(u64, expected_keys.items, keys.items);
    }
}

test "an agent sealed in a pocket does not make the goal unavailable for an agent outside it" {
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
    // The sealed-in agent's search ends without a corridor, and the goal's open side
    // outgrows its claims: answered for that request only.
    const sealed = try solveFrom(&system, requester, pocketGoal(11), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), sealed.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), sealed.start_unreachable);
    try std.testing.expectEqual(@as(usize, 0), sealed.negatives_published);
    try std.testing.expectEqual(@as(usize, 0), system.negatives.count());
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
    // The outside agent reaches the same goal.
    const outside = try solveFrom(&system, requester, outsideStart(0), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), outside.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, outsideStart(0), 0, goal, .default, null).status);
}

test "a goal sealed in a pocket is unavailable to agents outside it, and an agent inside still gets a path" {
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
    const stats = try solveFrom(&system, requester, outsideStart(3), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.negatives_published);
    try std.testing.expectEqual(@as(usize, 0), stats.start_unreachable);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    // The proof's box is the pocket's chunks, and its keys cover it one chunk wider.
    const found = system.negatives.lookup(system.graph.keyForWorld(0, goal, .default).?, system.step_counter, 0).?;
    try std.testing.expectEqual(Enclosure{ .level = 0, .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, found.enclosure);
    try expectNegativeRegistryMatchesCache(&system);
    // Every outside start reads unavailable and a repeat request is a hit; a start in the box
    // does not.
    for (0..6) |index| try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(index * 7), 0, goal, .default, null).status);
    const repeat = try solveFrom(&system, requester, outsideStart(9), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), repeat.cache_hits);
    try std.testing.expectEqual(@as(usize, 0), repeat.solved_requests);
    const inside_start = pocketGoal(2);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, inside_start, 0, goal, .default, null).status);
    const inside = try solveFrom(&system, requester, inside_start, goal, .{});
    try std.testing.expectEqual(@as(usize, 1), inside.available_results);
    try std.testing.expectEqual(@as(usize, 0), inside.cache_hits);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, inside_start, 0, goal, .default, null).status);
}

test "a goal sealed in a room is cached as unavailable after a budget-exhausted search from outside" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    // The tier-0 cap saturates the forward search from outside but holds the room's flood.
    capacity.tier0_abstract_node_cap = 96;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &fixture.world, null);
    try system.growForAgentCount(16);
    const goal = pocketGoal(44);
    const stats = try solveFrom(&system, requester, outsideStart(5), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.negatives_proven_after_exhaustion);
    try std.testing.expectEqual(@as(usize, 1), stats.negatives_published);
    try std.testing.expectEqual(@as(usize, 0), stats.budget_exhausted);
    // No tier promotion: the request left pending answered.
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expectEqual(@as(usize, 0), stats.escalated_solves);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(5), 0, goal, .default, null).status);
    try expectNegativeRegistryMatchesCache(&system);
}

test "an unproven flood after exhaustion caches nothing and keeps the promote-then-drop ladder" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, pocket_world_side);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.tier0_abstract_node_cap = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &fixture.world, null);
    const start = tileCenter(1, 1);
    const goal = tileCenter(30, 30);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    // Tier 0 exhausts; the goal's open side outgrows the attempt's cap: promoted.
    const first = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 0), first.negatives_published);
    try std.testing.expectEqual(@as(usize, 0), first.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(0).tier);
    // Tier 1, its cap forced below the corridor, exhausts again: dropped, never cached.
    system.capacity.max_abstract_nodes = 8;
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const second = try system.updateSerial(&empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), second.escalated_solves);
    try std.testing.expectEqual(@as(usize, 1), second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), second.escalated_dropped);
    try std.testing.expectEqual(@as(usize, 0), second.negatives_published);
    try std.testing.expectEqual(@as(usize, 0), second.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expectEqual(@as(usize, 0), system.negatives.count());
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);
}

test "one dig leaves unrelated pending requests, negatives, fields, tallies, and paths intact, and a request queued before it is solved after it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    // A negative for a pocket goal, a path along the top right, and a group field inside the
    // pocket from its own agents.
    _ = try requestPocketGoals(&system, requester, 0, 1, 16, null, .{});
    const path_goal = tileCenter(28, 2);
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, tileCenter(16, 2), path_goal, .{})).available_results);
    var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer group.deinit();
    for (0..3) |index| try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = pocketGoal(70 + index), .goal = pocketGoal(33) });
    for (0..4) |_| _ = try system.updateSerial(&group, 16, .{});
    const field_key = system.graph.keyForWorld(0, pocketGoal(33), .default).?;
    const field_state = system.findGroupField(field_key).?.state;
    try std.testing.expect(field_state != .empty);
    // A request left pending.
    const queued_goal = tileCenter(25, 28);
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, tileCenter(16, 20), queued_goal, .{ .max_fallback_requests_per_step = 0 })).deferred_requests);
    const tallies = system.group_requests.items.len;
    try std.testing.expect(tallies != 0);

    // Dig a cell far from all of them.
    try setRegistryCells(&system, &fixture, &.{.{ 28, 26 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), reaction.evicted_negatives + reaction.evicted_results + reaction.dropped_fields);
    try std.testing.expect(system.negatives.lookup(pocketKey(&system, 0), system.step_counter, 0) != null);
    try std.testing.expect(system.completed.slotIndex(system.graph.keyForWorld(0, path_goal, .default).?) != null);
    try std.testing.expectEqual(field_state, system.findGroupField(field_key).?.state);
    try std.testing.expectEqual(tallies, system.group_requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try std.testing.expect(system.pending_keys.contains(system.graph.keyForWorld(0, queued_goal, .default).?));
    try expectNegativeRegistryMatchesCache(&system);
    try expectRegistryMatchesCache(&system);
    // The queued request is solved on the next update.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const after = try system.updateSerial(&empty, 16, .{});
    try std.testing.expectEqual(@as(usize, 1), after.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, tileCenter(16, 20), 0, queued_goal, .default, null).status);
}

test "a negative is evicted by a change next to its proof's box and kept by a change elsewhere" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try requestPocketGoals(&system, requester, 0, 2, 16, null, .{})).negatives_published);
    // Two chunks past the box: kept.
    try setRegistryCells(&system, &fixture, &.{.{ 17, 5 }}, fixture.tree);
    const far = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 0), far.evicted_negatives);
    try std.testing.expectEqual(@as(usize, 2), system.negatives.count());
    // One chunk past it (chunk 3 of the box's row): both evicted, and the goal re-solves.
    try setRegistryCells(&system, &fixture, &.{.{ 13, 5 }}, fixture.tree);
    const near = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 2), near.evicted_negatives);
    try std.testing.expectEqual(@as(usize, 0), system.negatives.count());
    try expectNegativeRegistryMatchesCache(&system);
    for (&system.negative_index) |*shard| try std.testing.expectEqual(shard.entries.len, shard.entry_free.items.len);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, outsideStart(0), 0, pocketGoal(0), .default, null).status);
    try std.testing.expectEqual(@as(usize, 1), (try requestPocketGoals(&system, requester, 0, 1, 16, null, .{})).solved_requests);
}

test "a status query reads a stale negative as missing and leaves it for intake to remove" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    _ = try requestPocketGoals(&system, requester, 0, 1, 16, null, .{});
    const key = pocketKey(&system, 0);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(0), 0, pocketGoal(0), .default, null).status);
    system.step_counter +%= types.default_cache_ttl_steps;
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, outsideStart(0), 0, pocketGoal(0), .default, null).status);
    try std.testing.expect(system.negatives.lookup(key, system.step_counter, 0) != null);
    try std.testing.expectEqual(@as(usize, 0), system.negatives.core.ownerLog().len);
    // The next intake removes it, retiring its keys, and the goal is solved again.
    const again = try requestPocketGoals(&system, requester, 0, 1, 16, null, .{});
    try std.testing.expectEqual(@as(usize, 1), again.solved_requests);
    try std.testing.expectEqual(@as(usize, 1), again.negatives_published);
    try std.testing.expect(again.negative_registrations_removed != 0);
    try expectNegativeRegistryMatchesCache(&system);
}

test "a full negative cache keeps publishing every proven negative, evicting round-robin victims" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 32), system.negatives.logicalCapacity());
    var victims: usize = 0;
    for (0..6) |step| {
        const stats = try requestPocketGoals(&system, requester, step * 8, 8, 8, null, .{});
        try std.testing.expectEqual(@as(usize, 8), stats.negatives_published);
        victims += stats.cache_evictions;
        try expectNegativeRegistryMatchesCache(&system);
    }
    try std.testing.expectEqual(@as(usize, 32), system.negatives.count());
    try std.testing.expectEqual(@as(usize, 48 - 32), victims);
    // The last step's negatives all stand.
    for (40..48) |index| try std.testing.expect(system.negatives.lookup(pocketKey(&system, index), system.step_counter, 0) != null);
}

// A negative for `key` on the chunk-key rect (min_x, min_y)..(max_x, max_y), every start.
fn chunkRectNegative(system: *PathfindingSystem, key: PathQueryKey, min_x: u32, min_y: u32, max_x: u32, max_y: u32) !void {
    const keys = solve.NegativeKeys{ .tier = .chunk, .level = 0, .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y, .row_units = @intCast(system.chunkGrid().chunks_x) };
    try publishTestNegative(system, key, keys, Enclosure.every_start, system.step_counter);
}

fn testGoalKeyAt(system: *const PathfindingSystem, x: i32, y: i32) PathQueryKey {
    var key = emptyKey(system.graph.version);
    key.goal = .{ .x = x, .y = y };
    return key;
}

test "world-key negatives are evicted by any nav batch, and other negatives only by their own keys" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    _ = try requestPocketGoals(&system, requester, 0, 1, 16, null, .{});
    try publishTestNegative(&system, testGoalKeyAt(&system, 30, 30), solve.NegativeKeys.world, Enclosure.every_start, system.step_counter);
    try expectNegativeRegistryMatchesCache(&system);
    try setRegistryCells(&system, &fixture, &.{.{ 28, 26 }}, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.evicted_negatives);
    try std.testing.expect(system.negatives.lookup(testGoalKeyAt(&system, 30, 30), system.step_counter, 0) == null);
    try std.testing.expect(system.negatives.lookup(pocketKey(&system, 0), system.step_counter, 0) != null);
    try std.testing.expectEqual(evict_owns_world | evict_owns_level, system.evict_items.items[0].owned & (evict_owns_world | evict_owns_level));
    try expectNegativeRegistryMatchesCache(&system);
}

test "a level add evicts world-key negatives and keeps the rest" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    _ = try requestPocketGoals(&system, requester, 0, 1, 16, null, .{});
    try publishTestNegative(&system, testGoalKeyAt(&system, 30, 30), solve.NegativeKeys.world, Enclosure.every_start, system.step_counter);
    _ = try fixture.world.addLevel(-16);
    _ = try fixture.world.addDenseLayer(1, 0, .floor, fixture.grass);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expectEqual(@as(usize, 1), stats.evicted_negatives);
    try std.testing.expect(system.negatives.lookup(testGoalKeyAt(&system, 30, 30), system.step_counter, 0) == null);
    try std.testing.expect(system.negatives.lookup(pocketKey(&system, 0), system.step_counter, 0) != null);
    try expectNegativeRegistryMatchesCache(&system);
}

test "a new link evicts the negatives registered on its endpoint chunks and keeps the rest" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    _ = try requestPocketGoals(&system, requester, 0, 1, 16, null, .{});
    // Far from both endpoints.
    try chunkRectNegative(&system, testGoalKeyAt(&system, 27, 1), 6, 0, 7, 1);
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 12, .y = 4 }, .level_b = 0, .cell_b = .{ .x = 20, .y = 28 }, .traversal_cost = 1, .bidirectional = false });
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), system.graph.changed_keys.items.len);
    try std.testing.expectEqual(@as(usize, 1), stats.evicted_negatives);
    try std.testing.expect(system.negatives.lookup(pocketKey(&system, 0), system.step_counter, 0) == null);
    try std.testing.expect(system.negatives.lookup(testGoalKeyAt(&system, 27, 1), system.step_counter, 0) != null);
    try expectNegativeRegistryMatchesCache(&system);
}

test "superchunk keys cover a wide proof's box, and a dense change walks its list once" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // A 33-tile pocket spans nine chunks a side: one chunk wider, a hundred chunk keys.
    var fixture = try pocketWorld(&meta, 80, 33);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    for (0..2) |index| {
        const stats = try solveFrom(&system, requester, tileCenter(@intCast(40 + index), 60), pocketGoal(index), .{});
        try std.testing.expectEqual(@as(usize, 1), stats.negatives_published);
    }
    const enclosure = system.negatives.lookup(pocketKey(&system, 0), system.step_counter, 0).?.enclosure;
    const keys = enclosureKeys(&system, enclosure);
    try std.testing.expectEqual(solve.NegativeKeys.Tier.superchunk, keys.tier);
    try std.testing.expectEqual(@as(u32, 4), keys.count());
    try expectNegativeRegistryMatchesCache(&system);
    // Cells in four chunks of superchunk (1, 1), none of them registered.
    try setRegistryCells(&system, &fixture, &.{ .{ 37, 37 }, .{ 41, 37 }, .{ 37, 41 }, .{ 45, 45 } }, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 2), stats.evicted_negatives);
    var owners: usize = 0;
    var bound: usize = 0;
    for (system.evict_items.items) |item| {
        owners += @intFromBool(item.owned & evict_owns_superchunk != 0);
        bound += item.negative_bound;
    }
    try std.testing.expectEqual(@as(usize, 1), owners);
    try std.testing.expectEqual(@as(usize, 2), bound);
    try expectNegativeRegistryMatchesCache(&system);
}

// Negative entries a one-cell change at (28, 26) walks with `unrelated` negatives
// registered far from it beside two near it.
fn negativeVisitsWithUnrelated(meta: *const WorldTilesetMeta, unrelated: usize) !usize {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try pocketWorld(meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 128);
    defer system.deinit();
    for (0..unrelated) |index| try chunkRectNegative(&system, testGoalKeyAt(&system, @intCast(index % 30), @intCast(100 + index / 30)), 0, 6, 1, 7);
    try chunkRectNegative(&system, testGoalKeyAt(&system, 0, 200), 6, 5, 7, 7);
    try chunkRectNegative(&system, testGoalKeyAt(&system, 1, 200), 7, 6, 7, 6);
    try setRegistryCells(&system, &fixture, &.{.{ 28, 26 }}, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 2), stats.evicted_negatives);
    try std.testing.expectEqual(unrelated, system.negatives.count());
    var visited: usize = 0;
    for (system.evict_items.items) |item| visited += item.negative_hits;
    return visited;
}

test "negative eviction visits only the dirty keys' lists (equal entries walked with 10 and 300 unrelated negatives)" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    try std.testing.expectEqual(@as(usize, 2), try negativeVisitsWithUnrelated(&meta, 10));
    try std.testing.expectEqual(@as(usize, 2), try negativeVisitsWithUnrelated(&meta, 300));
}

// Whether the group field toward (9, 9), covering at most nine cells and given `budget`
// expansions a step, drops on a change at `cell`; checks the brute-force rule (a changed
// cell within one cell of a costed cell) against the field built before the change.
fn fieldDropMatchesReference(meta: *const WorldTilesetMeta, cell: [2]u16, budget: usize) !bool {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try registryWorld(meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 9;
    capacity.group_field_build_budget = budget;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &fixture.world, null);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = tileCenter(12, 12), .goal = tileCenter(9, 9) });
    _ = try system.updateSerial(&stream, 8, .{ .max_fallback_requests_per_step = 0 });
    const key = system.graph.keyForWorld(0, tileCenter(9, 9), .default).?;
    const field = system.findGroupField(key) orelse return error.TestExpectedField;
    try std.testing.expectEqual(@as(GroupFieldState, if (budget == 1) .building else .ready), field.state);
    const grid = system.graph.grid(0).?;
    var near = false;
    for (0..grid.cellCount()) |index| {
        if (field.lookup(grid, index) == null) continue;
        const x: isize = @intCast(index % grid.width);
        const y: isize = @intCast(index / grid.width);
        if (@abs(x - @as(isize, cell[0])) <= 1 and @abs(y - @as(isize, cell[1])) <= 1) near = true;
    }
    try setRegistryCells(&system, &fixture, &.{cell}, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const dropped = system.findGroupField(key) == null;
    try std.testing.expectEqual(near, dropped);
    try std.testing.expectEqual(@as(usize, @intFromBool(near)), stats.dropped_fields);
    return dropped;
}

test "a group field, ready or building, drops exactly when a changed cell lies within one cell of a costed cell, across chunk borders" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // The field costs (8..10, 8..10), all of chunk (2, 2) but its far row and column.
    const cases = [_]struct { cell: [2]u16, drops: bool }{
        .{ .cell = .{ 7, 9 }, .drops = true },
        .{ .cell = .{ 6, 9 }, .drops = false },
        .{ .cell = .{ 7, 7 }, .drops = true },
        .{ .cell = .{ 11, 11 }, .drops = true },
        .{ .cell = .{ 12, 12 }, .drops = false },
        .{ .cell = .{ 9, 12 }, .drops = false },
        .{ .cell = .{ 10, 11 }, .drops = true },
    };
    for ([_]usize{ 8192, 1 }) |budget| {
        for (cases) |case| try std.testing.expectEqual(case.drops, try fieldDropMatchesReference(&meta, case.cell, budget));
    }
}

test "a negative publish reserve out of memory claims nothing and leaves the requests pending (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var system = try registrySystem(&data, &fixture.world, 16);
        defer system.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        setSystemAllocators(&system, failing.allocator());
        const result = requestPocketGoals(&system, requester, 0, 8, 16, null, .{});
        setSystemAllocators(&system, std.testing.allocator);
        if (result) |stats| {
            try std.testing.expectEqual(@as(usize, 8), stats.negatives_published);
            try expectNegativeRegistryMatchesCache(&system);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(@as(usize, 0), system.negatives.count());
        try std.testing.expectEqual(@as(usize, 0), system.negatives.core.ownerLog().len);
        for (&system.negative_index) |*shard| try std.testing.expectEqual(@as(usize, 0), shard.live_keys);
        try std.testing.expectEqual(@as(usize, 8), system.pending.len);
        // The retry publishes them.
        var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer empty.deinit();
        try std.testing.expectEqual(@as(usize, 8), (try system.updateSerial(&empty, 16, .{})).negatives_published);
        try expectNegativeRegistryMatchesCache(&system);
    }
    try std.testing.expect(fail_index >= 1);
}

// Two systems' negative caches hold the same entries under the same owner ids and probe
// slots, and their negative registries the same lists in the same order.
fn expectSameNegatives(a: *const PathfindingSystem, b: *const PathfindingSystem) !void {
    try std.testing.expectEqual(a.negatives.count(), b.negatives.count());
    try std.testing.expectEqual(a.negatives.logicalCapacity(), b.negatives.logicalCapacity());
    for (a.negatives.core.slots.items, b.negatives.core.slots.items) |slot_a, slot_b| {
        try std.testing.expectEqual(slot_a.occupied, slot_b.occupied);
        if (slot_a.occupied) try std.testing.expectEqual(slot_a.payload_index, slot_b.payload_index);
    }
    for (a.negatives.core.records.items, b.negatives.core.records.items, 0..) |record_a, record_b, owner| {
        try std.testing.expectEqual(record_a.live, record_b.live);
        if (!record_a.live) continue;
        try std.testing.expect(keysEqual(a.negatives.core.keyOf(@intCast(owner)), b.negatives.core.keyOf(@intCast(owner))));
        try std.testing.expectEqual(record_a.stamp, record_b.stamp);
        try std.testing.expectEqual(record_a.extra, record_b.extra);
    }
    for (&a.negative_index, &b.negative_index) |*shard_a, *shard_b| {
        try std.testing.expectEqualSlices(u64, shard_a.slot_keys, shard_b.slot_keys);
        for (shard_a.slot_keys, 0..) |key, slot| {
            if (key == std.math.maxInt(u64)) continue;
            var entry_a = shard_a.slot_heads[slot];
            var entry_b = shard_b.slot_heads[slot];
            while (entry_a != no_entry or entry_b != no_entry) {
                try std.testing.expect(entry_a != no_entry and entry_b != no_entry);
                try std.testing.expectEqual(shard_a.entry_owner[entry_a], shard_b.entry_owner[entry_b]);
                entry_a = shard_a.entry_next[entry_a];
                entry_b = shard_b.entry_next[entry_b];
            }
        }
    }
}

// A pocket system at 16 agents (64 cache entries each) holding `routes` routes and a
// negative for each of the pocket goals [0, `negatives`).
fn negativeFixture(data: *const DataSystem, fixture: *const RegistryWorld, requester: EntityId, participants: usize, routes: usize, negatives: usize) !PathfindingSystem {
    var system = try registrySystemWith(data, &fixture.world, 16, .{ .participants = participants });
    errdefer system.deinit();
    var first: usize = 0;
    while (first < negatives) : (first += 16) {
        const stats = try requestPocketGoals(&system, requester, first, @min(16, negatives - first), 16, null, .{});
        try std.testing.expectEqual(@min(16, negatives - first), stats.negatives_published);
    }
    var route: usize = 0;
    while (route < routes) : (route += 16) try solveRegistryRoutes(&system, requester, pocket_world_side, route, @min(16, routes - route), 16, null, .{});
    return system;
}

test "a negative publish after its reserve allocates nothing on a multi-worker ThreadSystem, every shard allocator swapped (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = try registrySystemWith(&data, &fixture.world, 16, .{ .participants = threads.participantSlotCount() });
    defer system.deinit();
    // One publish reserves the negative registry and the windows; cleared, the same publish
    // fits them.
    _ = try requestPocketGoals(&system, requester, 0, 16, 16, &threads, fixed_threads_config);
    system.clearRuntimeState();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const result = requestPocketGoals(&system, requester, 0, 16, 16, &threads, fixed_threads_config);
    setSystemAllocators(&system, std.testing.allocator);
    const stats = try result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 16), stats.negatives_published);
    try std.testing.expect(stats.negative_registrations_added != 0);
    try std.testing.expect(!stats.fallback_batch.ran_inline and !stats.publish_copy_batch.ran_inline and !stats.registry_flush_batch.ran_inline);
    try expectNegativeRegistryMatchesCache(&system);
}

test "threaded negative publish and flush equal serial across range sizes and worker counts, with victims in the log" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    // A full negative cache, then sixteen more negatives and routes: victims in both logs.
    var serial = try negativeFixture(&data, &fixture, requester, 1, 16, 64);
    defer serial.deinit();
    var serial_stats = PathfindingStats{};
    var serial_stream = try pocketStream(requester, 64, 16);
    defer serial_stream.stream.deinit();
    try serial.updateInline(&serial_stream.stream, 16, .{}, &serial_stats);
    try std.testing.expect(serial.negatives.core.ownerLog().len != 0 and serial.publish_ranges != 0);
    const negative_ops = serial.negatives.core.ownerLog().len;
    const path_ops = serial.completed.core.ownerLog().len;
    var serial_flush = PathfindingStats{};
    const serial_batch = serial.flushRegistry(null, &serial_flush);
    try std.testing.expect(serial_flush.negative_registrations_added != 0 and serial_flush.negative_registrations_removed != 0);
    try std.testing.expectEqual(flushUnits(path_ops, negative_ops, serial_flush.registrations_added + serial_flush.negative_registrations_added), serial_batch.item_count);
    try expectNegativeRegistryMatchesCache(&serial);
    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        if (threads.workerThreadCount() == 0) return error.SkipZigTest;
        var worker_ranges: usize = 0;
        for ([_]usize{ 1, 3, 40 }) |items_per_range| {
            var threaded = try negativeFixture(&data, &fixture, requester, threads.participantSlotCount(), 16, 64);
            defer threaded.deinit();
            const config = PathfindingConfig{ .adaptive = false, .items_per_range = items_per_range };
            var stream = try pocketStream(requester, 64, 16);
            defer stream.stream.deinit();
            var stats = PathfindingStats{};
            try threaded.updateThreaded(&stream.stream, 16, .{ .thread_system = &threads, .config = config }, &stats);
            try std.testing.expectEqual(serial_stats.negatives_published, stats.negatives_published);
            try std.testing.expectEqual(serial_stats.cache_evictions, stats.cache_evictions);
            var flush_stats = PathfindingStats{};
            const stage = (PathfindingSystem.StageThreads{ .thread_system = &threads, .config = config }).stage(&threaded.registry_flush_tuner);
            const batch = threaded.flushRegistry(stage, &flush_stats);
            try std.testing.expect(!batch.ran_inline);
            worker_ranges += batch.worker_thread_ranges;
            try std.testing.expectEqual(serial_batch.item_count, batch.item_count);
            try std.testing.expectEqual(serial_flush.negative_registrations_added, flush_stats.negative_registrations_added);
            try std.testing.expectEqual(serial_flush.negative_registrations_removed, flush_stats.negative_registrations_removed);
            try std.testing.expectEqual(serial_flush.registrations_added, flush_stats.registrations_added);
            try expectSameNegatives(&serial, &threaded);
            try expectSameCache(&serial, &threaded);
            try expectSameRegistry(&serial, &threaded);
            try expectNegativeRegistryMatchesCache(&threaded);
        }
        try std.testing.expect(worker_ranges != 0);
    }
}

// Requests for pocket goals [first, first + count) from outside starts.
fn pocketStream(requester: EntityId, first: usize, count: usize) !struct { stream: RangeOutputStream(PathRequest) } {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    errdefer stream.deinit();
    for (first..first + count) |index| try appendPathRequest(&stream, .{ .entity = requester, .start = outsideStart(index - first), .goal = pocketGoal(index) });
    return .{ .stream = stream };
}

// Cells of a dense change, one per chunk: seven on the chunks one past the pocket's box and
// sixteen far from it.
const negative_change_cells = blk: {
    var cells: [23][2]u16 = undefined;
    for (0..4) |row| cells[row] = .{ 13, 2 + 4 * row };
    for (0..3) |column| cells[4 + column] = .{ 2 + 4 * column, 13 };
    for (0..16) |index| cells[7 + index] = .{ 17 + 4 * (index % 4), 17 + 4 * (index / 4) };
    break :blk cells;
};

test "threaded eviction with negatives and fields equals serial over a dense change (bounds, flags, hits), and runs on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var systems: [2]PathfindingSystem = undefined;
    var built: usize = 0;
    defer for (systems[0..built]) |*system| system.deinit();
    for (&systems) |*system| {
        system.* = try negativeFixture(&data, &fixture, requester, threads.participantSlotCount(), 32, 24);
        built += 1;
        try publishTestNegative(system, testGoalKeyAt(system, 31, 31), solve.NegativeKeys.world, Enclosure.every_start, system.step_counter);
        // A group field toward the far corner.
        var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer group.deinit();
        try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = tileCenter(20, 20), .goal = tileCenter(26, 26) });
        _ = try system.updateSerial(&group, 16, .{ .max_fallback_requests_per_step = 0 });
    }
    systems[1].nav_thread_adaptive = false;
    systems[1].nav_thread_items_per_range = 1;
    try setRegistryCells(&systems[0], &fixture, &negative_change_cells, fixture.tree);
    for (negative_change_cells) |cell| try systems[1].markNavDirty(0, cell[0], cell[1]);
    const serial_stats = try systems[0].applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const stats = try systems[1].applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expect(!stats.evict_count_batch.ran_inline and stats.evict_count_batch.range_count > 1);
    try std.testing.expect(!stats.evict_batch.ran_inline and stats.evict_batch.range_count > 1);
    try std.testing.expect(serial_stats.evicted_negatives > 1 and serial_stats.dropped_fields == 1);
    try std.testing.expectEqual(serial_stats.evicted_negatives, stats.evicted_negatives);
    try std.testing.expectEqual(serial_stats.evicted_results, stats.evicted_results);
    try std.testing.expectEqual(serial_stats.dropped_fields, stats.dropped_fields);
    for (systems[0].evict_items.items, systems[1].evict_items.items) |a, b| {
        // Window bases follow each run's range shape.
        var a_unplaced = a;
        a_unplaced.base = b.base;
        try std.testing.expectEqualDeep(a_unplaced, b);
        const field_bound: usize = if (a.changed_index != no_changed_index) systems[0].group_fields.items.len else 0;
        try std.testing.expectEqualSlices(u32, systems[0].evict_hits.items[a.base..][0 .. a.bound + a.negative_bound + field_bound], systems[1].evict_hits.items[b.base..][0 .. b.bound + b.negative_bound + field_bound]);
    }
    try expectSameNegatives(&systems[0], &systems[1]);
    try expectSameCache(&systems[0], &systems[1]);
    try expectSameRegistry(&systems[0], &systems[1]);
    for (&systems) |*system| {
        try expectNegativeRegistryMatchesCache(system);
        try expectRegistryMatchesCache(system);
    }
}

test "eviction with negatives and fields allocates nothing after its pre-commit reserve on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = try negativeFixture(&data, &fixture, requester, threads.participantSlotCount(), 32, 24);
    defer system.deinit();
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;
    var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer group.deinit();
    try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = tileCenter(20, 20), .goal = tileCenter(26, 26) });
    // A warm cycle sizes the eviction scratch and the batch buffers.
    try setRegistryCells(&system, &fixture, &negative_change_cells, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try setRegistryCells(&system, &fixture, &negative_change_cells, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    _ = try requestPocketGoals(&system, requester, 0, 16, 16, null, .{});
    _ = try requestPocketGoals(&system, requester, 16, 8, 16, null, .{});
    _ = try system.updateSerial(&group, 16, .{ .max_fallback_requests_per_step = 0 });

    try setRegistryCells(&system, &fixture, &negative_change_cells, fixture.tree);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const reaction = system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    setSystemAllocators(&system, std.testing.allocator);
    const stats = try reaction;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(stats.evicted_negatives != 0 and stats.dropped_fields == 1);
    try std.testing.expect(!stats.evict_batch.ran_inline and !stats.evict_flush_batch.ran_inline);
    try expectNegativeRegistryMatchesCache(&system);
    try expectRegistryMatchesCache(&system);
}

test "a shrink keeps the youngest negatives, renames the rest below the capacity, and its flush allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = try negativeFixture(&data, &fixture, requester, threads.participantSlotCount(), 0, 64);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 64), system.negatives.count());
    // The youngest 32 (the last two publishes) survive.
    try prepareTruncate(&system.negative_index, 32);
    var resize = try system.negatives.prepareResize(system.allocator, 32);
    system.negatives.commitResize(system.allocator, &resize, system.step_counter);
    system.registry_truncate_pending = true;
    var renames: usize = 0;
    for (system.negatives.core.ownerLog()) |op| renames += @intFromBool(op.new != no_owner);
    try std.testing.expect(renames != 0);
    const units = flushUnits(0, system.negatives.core.ownerLog().len, 0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const stage = (PathfindingSystem.StageThreads{ .thread_system = &threads, .config = fixed_threads_config });
    const flush = system.flushRegistry(stage.stage(&system.registry_flush_tuner), null);
    setSystemAllocators(&system, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(!flush.ran_inline);
    try std.testing.expectEqual(units, flush.item_count);
    for (&system.negative_index) |*shard| try std.testing.expectEqual(@as(usize, 32), shard.owner_heads.items.len);
    try std.testing.expectEqual(@as(usize, 32), system.negatives.count());
    for (32..64) |index| try std.testing.expect(system.negatives.lookup(pocketKey(&system, index), system.step_counter, 0) != null);
    try expectNegativeRegistryMatchesCache(&system);
}

test "an elastic grow and shrink keep negatives and their registrations through the resize seam" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 32), system.negatives.logicalCapacity());
    _ = try requestPocketGoals(&system, requester, 0, 8, 8, null, .{});
    try system.growForAgentCount(40);
    try std.testing.expectEqual(system.completed.logicalCapacity(), system.negatives.logicalCapacity());
    try expectNegativeRegistryMatchesCache(&system);
    for (1..5) |step| _ = try requestPocketGoals(&system, requester, step * 8, 8, 40, null, .{});
    try std.testing.expectEqual(@as(usize, 40), system.negatives.count());
    try expectNegativeRegistryMatchesCache(&system);
    // Sustained low load shrinks back to the floor: the 32 youngest stay.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..system.capacity.capacity_shrink_window) |_| _ = try system.updateSerial(&empty, 1, .{});
    try std.testing.expectEqual(@as(usize, 32), system.negatives.logicalCapacity());
    try std.testing.expectEqual(@as(usize, 32), system.negatives.count());
    for (8..40) |index| try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, outsideStart(0), 0, pocketGoal(index), .default, null).status);
    for (&system.negative_index) |*shard| try std.testing.expect(shard.owner_heads.items.len <= 32);
    try expectNegativeRegistryMatchesCache(&system);
}

// Solves `request` alone at fallback ordinal 0 on the first participant's scratch.
fn solveRequest(system: *PathfindingSystem, request: PendingRequest) PathSolveResult {
    system.pending.clear();
    system.pending.push(request);
    var stats = PathfindingStats{};
    system.prepareSolvePhase(1, 1, &stats);
    system.resetSolvedPaths();
    return solveOne(system, 0, &system.scratch_slots.items[0], 0);
}

fn pocketRequest(system: *const PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2) PendingRequest {
    const grid = system.graph.grid(0).?;
    const key = system.graph.keyForWorld(0, goal, .default).?;
    return .{ .entity = requester, .key = key, .start_level = 0, .start = grid.worldToCellClamped(start), .goal_index = grid.indexForCell(key.goal).? };
}

test "each solve failure maps to its outcome: world, proven region, or proven after exhaustion published; start-side, unproven, and corridor failures not" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    {
        // An unbuilt graph: a world negative.
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        const result = solveRequest(&system, .{ .entity = requester, .key = emptyKey(0), .start_level = 0, .start = .{ .x = 0, .y = 0 }, .goal_index = 0 });
        try std.testing.expect(result == .unavailable);
        try std.testing.expectEqual(solve.NegativeKeys.Tier.world, system.solved_paths.items[0].negative.tier);
        try std.testing.expectEqual(Enclosure.every_start, system.solved_paths.items[0].enclosure);
    }
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    // A goal level the graph lacks: a world negative.
    var missing_level = pocketRequest(&system, requester, outsideStart(0), tileCenter(20, 20));
    missing_level.key.goal_level = 7;
    try std.testing.expect(solveRequest(&system, missing_level) == .unavailable);
    try std.testing.expectEqual(solve.NegativeKeys.Tier.world, system.solved_paths.items[0].negative.tier);
    // No corridor from outside to the pocket: its region proven, keys one chunk wider.
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, outsideStart(0), pocketGoal(12))) == .unavailable);
    const proven = system.solved_paths.items[0];
    try std.testing.expectEqual(Enclosure{ .level = 0, .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, proven.enclosure);
    try std.testing.expectEqual(solve.NegativeKeys.Tier.chunk, proven.negative.tier);
    try std.testing.expectEqual(@as(u32, 16), proven.run_count);
    try std.testing.expect(!proven.negative_after_exhaustion);
    // No corridor out of the pocket: the open side outgrows the search's claims.
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, pocketGoal(12), tileCenter(20, 20))) == .start_unreachable);
    // A blocked start.
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(pocket_cells, 3), tileCenter(20, 20))) == .start_invalid);
    // A corridor found but its stitch past the cap: retried, never a negative.
    system.capacity.tier0_stitched_cell_cap = 2;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(14, 20), tileCenter(28, 28))) == .budget_exhausted);
    system.capacity.tier0_stitched_cell_cap = abstractCapacity().max_stitched_path_cells;
    // A same-component hop past the local budget: retried.
    system.capacity.max_explored_nodes = 2;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(12, 12), tileCenter(15, 15))) == .budget_exhausted);
    system.capacity.max_explored_nodes = abstractCapacity().max_explored_nodes;
    // A saturated search: proven around the pocket, else retried.
    system.capacity.tier0_abstract_node_cap = 96;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, outsideStart(0), pocketGoal(12))) == .unavailable);
    try std.testing.expect(system.solved_paths.items[0].negative_after_exhaustion);
    system.capacity.tier0_abstract_node_cap = 8;
    try std.testing.expect(solveRequest(&system, pocketRequest(&system, requester, tileCenter(12, 12), tileCenter(28, 28))) == .budget_exhausted);
}

test "a goal with no open cell within the projection radius is a negative for every start over its window's keys" {
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
    const stats = try solveFrom(&system, requester, tileCenter(45, 45), goal, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.negatives_published);
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const owner = system.negatives.core.ownerOf(key).?;
    try std.testing.expectEqual(Enclosure.every_start, system.negatives.core.records.items[owner].extra);
    // The window's cells (4..36) span chunks 1..9; one chunk wider is past the chunk-key
    // limit, so its superchunks register.
    const expected = solve.NegativeKeys.cover(0, .{ .min_x = 1, .min_y = 1, .max_x = 9, .max_y = 9 }, chunkCountsOf(&system));
    try std.testing.expectEqual(solve.NegativeKeys.Tier.superchunk, expected.tier);
    var registered: u32 = 0;
    for (0..expected.count()) |index| {
        const registry_key = expected.keyAt(@intCast(index));
        var owners = system.negative_index[registryShard(registry_key)].iterator(registry_key);
        while (owners.next()) |listed| registered += @intFromBool(listed == owner);
    }
    try std.testing.expectEqual(expected.count(), registered);
    try std.testing.expectEqual(@as(usize, expected.count()), stats.negative_registrations_added);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, tileCenter(1, 45), 0, goal, .default, null).status);
    try expectNegativeRegistryMatchesCache(&system);
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

test "a negative proven for a projected goal is evicted by a change in its projection window outside the proof's box" {
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
    const first = try solveFrom(&system, requester, start, goal, .{});
    try std.testing.expectEqual(@as(usize, 1), first.goal_projected);
    try std.testing.expectEqual(@as(usize, 1), first.negatives_published);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, start, 0, goal, .default, null).status);
    // The keys cover the pocket's chunk and the projection window's chunks (x 0..30,
    // y 0..17), one chunk wider: chunks 0..8 by 0..5.
    try std.testing.expectEqual(@as(usize, 54), first.negative_registrations_added);
    try expectNegativeRegistryMatchesCache(&system);
    // A tunnel to the key's cell, outside the pocket's chunk and its neighbours.
    try digProjectionTunnel(&system, &fixture, 13);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.evicted_negatives);
    try std.testing.expect(system.statusForWorld(0, start, 0, goal, .default, null).status != .unavailable);
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, start, goal, .{})).available_results);
    try expectNegativeRegistryMatchesCache(&system);
}

test "a pending request whose projection a change made stale publishes no negative and is answered for itself" {
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
    // Accepted with its projection into the pocket, left pending.
    const accepted = try solveFrom(&system, requester, start, goal, .{ .max_fallback_requests_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 1), accepted.goal_projected);
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    // A tunnel stopping one cell short of the key's still-blocked cell: its projection is
    // now (15, 1), reachable, while the pending one still holds the open pocket cell.
    try digProjectionTunnel(&system, &fixture, 15);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const stale = try system.updateSerial(&empty, 16, .{});
    try std.testing.expectEqual(@as(usize, 0), stale.negatives_published);
    try std.testing.expectEqual(@as(usize, 1), stale.start_unreachable);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);
    // The re-request projects afresh and reaches the goal.
    const again = try solveFrom(&system, requester, start, goal, .{});
    try std.testing.expectEqual(@as(usize, 1), again.goal_projected);
    try std.testing.expectEqual(@as(usize, 1), again.available_results);
}
