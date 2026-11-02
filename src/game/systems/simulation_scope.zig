// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Decides which entities enter each fixed-step stage:
//!   movement: `tier.allowsMovement()`, no chunk filter.
//!   collision: `tier.allowsCollision()`, no chunk filter.
//!   spatial index, perception candidates: the cognition halo, no stagger.
//!   AI, perception observers, memory, affect, decide: the think set, halo ∩
//!     (stagger_phase == step % cognition_stagger_n), in the index's cell-major order
//!     (`compactCognition`). `always_active` entities bypass halo and stagger;
//!     `cognition_region == null` applies neither.
//!
//! The gathers run early and read the chunk columns the prior step's `deriveChunks` wrote;
//! `deriveChunks` runs after every position writer, so the same step's tier policy sees
//! settled positions.
//!
//! Each pass threads: a range writes its window of one item-sized buffer and its padded
//! tally, and the main thread compacts or streams the windows in range order.

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const simd = @import("../../core/simd.zig");
const math = @import("../../core/math.zig");
const pdqSort = @import("../../core/sort.zig").pdq;
const logging = @import("../../core/logging.zig");
const banded_sort = @import("banded_sort.zig");
const BandOffsets = banded_sort.BandOffsets;
const no_component_row = @import("../data_system/types.zig").no_component_row;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const JobFn = @import("../../app/thread_system.zig").JobFn;
const RoundDispatch = @import("../../app/thread_system.zig").RoundDispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;

const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const DataSystem = @import("../data_system.zig").DataSystem;
const PrimitiveVisual = @import("../data_system.zig").PrimitiveVisual;
const EntityId = @import("../data_system.zig").EntityId;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const ConstScopeColumnsSlice = @import("../data_system.zig").ConstScopeColumnsSlice;
const HotI32Slice = @import("../data_system.zig").HotI32Slice;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const ActiveRegion = @import("../simulation_scope.zig").ActiveRegion;
const cognition_stagger_n = @import("../simulation_scope.zig").cognition_stagger_n;
const cognition_halo_chunks = @import("../simulation_scope.zig").cognition_halo_chunks;
const locomotion_halo_chunks = @import("../simulation_scope.zig").locomotion_halo_chunks;
const kinematic_halo_chunks = @import("../simulation_scope.zig").kinematic_halo_chunks;
const level_distance_chunks = @import("../simulation_scope.zig").level_distance_chunks;
const tierForChunkDistance = @import("../simulation_scope.zig").tierForChunkDistance;
const StructuralCommand = @import("../data_system.zig").StructuralCommand;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;
const SpatialIndexView = @import("spatial_index.zig").SpatialIndexView;
const every_cognition_phase = @import("spatial_index.zig").every_cognition_phase;

/// Cache-line range alignment for the scope passes, matching the other hot stages
/// so worker ranges land on aligned SoA boundaries.
pub const scope_range_alignment_items: usize = movement_range_alignment_items;

/// Think place, sort, and pack write 1-byte columns. A range of this many items
/// spans one cache line of those columns. Other scope stages stay on
/// `scope_range_alignment_items`.
const think_column_alignment: usize = 64;

/// Per-step threading knobs for the scope passes. Mirrors the other systems:
/// null `items_per_range` + `adaptive` lets each pass train its own tuner; an
/// explicit `items_per_range` pins the range size and opts out of the tuner.
pub const ScopeConfig = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

/// The batch of a scope gather or compaction, kept only with `runtime_perf_log.enabled`
/// (bench output).
const ScopeBatchPerf = if (runtime_perf_log.enabled) struct { batch: BatchStats = .{} } else struct {};

fn scopeBatchPerf(batch: BatchStats) ScopeBatchPerf {
    return if (comptime runtime_perf_log.enabled) .{ .batch = batch } else .{};
}

/// Threaded gather result for the movement/collision passes: `indices` is null on
/// the full-active fast path (downstream uses the full SoA range), otherwise the
/// merged dense-index list.
pub const ScopeGatherResult = struct {
    indices: ?[]const u32,
    perf: ScopeBatchPerf = .{},
};

/// Threaded gather result for the AI halo: the unstaggered cognition set (spatial index +
/// perception candidates). Unlike movement/collision it never short-circuits to
/// full-active. The think set comes from `compactCognition` over the index built from it.
pub const AiPopulationGatherResult = struct {
    halo: []const u32,
    perf: ScopeBatchPerf = .{},
};

/// The step's think set (`SimulationScopeSystem.compactCognition`), valid until the next
/// compaction.
pub const CognitionResult = struct {
    cognition: []const u32,
    perf: ScopeBatchPerf = .{},
};

pub const SimulationScopeSystem = struct {
    allocator: std.mem.Allocator,
    /// Step counter incremented at the top of each fixed step. Drives stagger.
    step_count: u32,
    /// Warmed collision dense-index list. null return = full-active (no dormant/kinematic with bounds).
    /// The threaded gather writes per-range windows into it, then compacts them in place.
    collision_indices: IndexList = .empty,
    /// Warmed AI agent dense-index list: cognition-tier agents inside the
    /// fixed-step `sim_view` cognition halo (no stagger). Spatial index and perception candidates consume this.
    /// `always_active` agents are included even outside the halo. The threaded gather
    /// writes per-range windows into it, then compacts them in place.
    ai_halo_indices: IndexList = .empty,
    /// Warmed think set: the indexed halo rows whose stagger phase is this step (plus
    /// `always_active`), in the index's cell-major order. Perception observers, memory,
    /// affect, and AI decide consume this. Steering scopes transitively off the navigation
    /// intents AI emits for these agents, so there is no separate steering gather.
    /// `compactCognition` writes per-range windows into it, then compacts them in place.
    ai_cognition_indices: IndexList = .empty,
    /// Warmed scratch for the per-step auto wake/sleep tier commands this system
    /// produces (per-range windows on the threaded path). Owned here beside the other
    /// scratch, streamed into the frame's structural-command stream.
    scope_tier_commands: CommandList = .empty,
    /// Per-range windows of drawable rows whose chunk changed in `deriveChunks`.
    chunk_changes: ChunkChangeList = .empty,
    /// Per-range tallies (count + diagnostics) for the threaded passes, one padded
    /// record per range. Each worker writes only its own record; the main thread reads
    /// them after the batch. The three passes run sequentially, so they share it.
    range_tallies: SlotList(GatherTally) = .empty,
    /// One adaptive tuner per independently-timed threaded pass.
    chunk_derive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    collision_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    ai_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    cognition_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    tier_policy_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Place and sort are different passes, so they do not share a tuner.
    think_order_place_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    think_order_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    think_pack_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    think_keys: ThinkKeyList = .empty,
    think_staging: ThinkKeyList = .empty,
    think_offsets: SlotList(BandOffsets) = .empty,
    pack_stamp: std.ArrayList(u32) = .empty,
    pack_stamp_id: u32 = 1,
    pack_holes: IndexList = .empty,
    pack_outside: IndexList = .empty,
    // Run bounds from the last `orderThinkPhases`. Empty until that pass.
    aa_begin: u32 = 0,
    aa_halo_end: u32 = 0,
    aa_end: u32 = 0,
    phase_begin: [4]u32 = @splat(0),
    phase_halo_end: [4]u32 = @splat(0),
    phase_end: [4]u32 = @splat(0),
    think_scratch_grow_logged: bool = false,
    /// Think-set scratch grows. Not on `perf`: `advanceStep` and `gatherAiPopulations`
    /// replace that value with `.{}` every step.
    think_scratch_grows: u64 = 0,
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: the last think set's indexed halo entities
    /// whose stagger_phase did not match its step, and the out-of-halo suffixes of the
    /// think-set runs (`publishRunBounds`).
    pub const Perf = if (runtime_perf_log.enabled) struct {
        stagger_skips: usize = 0,
        chunk_filtered_entities: usize = 0,
    } else struct {};

    pub fn init(allocator: std.mem.Allocator) SimulationScopeSystem {
        return .{
            .allocator = allocator,
            .step_count = 0,
            .chunk_derive_tuner = AdaptiveWorkTuner.init(.{}),
            .collision_gather_tuner = AdaptiveWorkTuner.init(.{}),
            .ai_gather_tuner = AdaptiveWorkTuner.init(.{}),
            .cognition_tuner = AdaptiveWorkTuner.init(.{}),
            .tier_policy_tuner = AdaptiveWorkTuner.init(.{}),
            .think_order_place_tuner = AdaptiveWorkTuner.init(.{}),
            .think_order_tuner = AdaptiveWorkTuner.init(.{}),
            .think_pack_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *SimulationScopeSystem) void {
        self.pack_outside.deinit(self.allocator);
        self.pack_holes.deinit(self.allocator);
        self.pack_stamp.deinit(self.allocator);
        self.think_offsets.deinit(self.allocator);
        self.think_staging.deinit(self.allocator);
        self.think_keys.deinit(self.allocator);
        self.range_tallies.deinit(self.allocator);
        self.scope_tier_commands.deinit(self.allocator);
        self.chunk_changes.deinit(self.allocator);
        self.ai_cognition_indices.deinit(self.allocator);
        self.ai_halo_indices.deinit(self.allocator);
        self.collision_indices.deinit(self.allocator);
    }

    /// Pre-sizes the per-step scratch index/command lists to `capacity` movement
    /// bodies and the range tallies to `maxRangeCount(capacity)`, so the serial and
    /// threaded gathers and tier policy are allocation-free after init under every
    /// partition the tuner can pick (the outputs are item-count windows, not per-range
    /// buffers). Grow-only; re-run by the pipeline's population seam.
    pub fn reserve(self: *SimulationScopeSystem, capacity: usize) !void {
        try self.collision_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.ai_halo_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.ai_cognition_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.scope_tier_commands.ensureTotalCapacity(self.allocator, capacity);
        try self.chunk_changes.ensureTotalCapacity(self.allocator, capacity);
        try self.range_tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(capacity, scope_range_alignment_items));
        try self.think_keys.ensureTotalCapacity(self.allocator, capacity);
        try self.think_staging.ensureTotalCapacity(self.allocator, capacity);
        try self.think_offsets.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(capacity, scope_range_alignment_items));
        try self.pack_stamp.ensureTotalCapacity(self.allocator, capacity);
        try self.pack_holes.ensureTotalCapacity(self.allocator, capacity);
        try self.pack_outside.ensureTotalCapacity(self.allocator, capacity);
    }

    /// Increment the step counter. Call once at the top of each fixed step.
    pub fn advanceStep(self: *SimulationScopeSystem) void {
        self.step_count += 1;
        self.perf = .{};
    }

    /// Current stagger slot: entities whose stagger_phase matches this value run AI/steering.
    pub fn staggerStep(self: *const SimulationScopeSystem) u8 {
        return @intCast(self.step_count % cognition_stagger_n);
    }

    /// Current fixed-step counter (already advanced for this step). Feeds
    /// src/core/rng.zig calls so per-entity noise resamples every step instead
    /// of being keyed only by a static seed.
    pub fn currentStep(self: *const SimulationScopeSystem) u32 {
        return self.step_count;
    }

    // ---- Chunk derivation -----------------------------------------------------

    /// Grid scalars for mapping a world position to a chunk coordinate. Mirrors
    /// `WorldSystem.chunkCoordForWorldPos` (clamp to bounds, then cell/chunk
    /// division); scope takes the grid as plain scalars rather than importing world.
    pub const ChunkGrid = struct {
        tile_size: f32,
        chunk_size_tiles: u16,
        width: u16,
        height: u16,
    };

    /// Recompute each movement body's chunk coordinate from its settled position,
    /// once per step, over the full contiguous SoA range. This is the separate pass
    /// that replaces movement's former in-pass chunk write: movement is now a pure
    /// position integrator. Non-moving rows recompute the same chunk from their
    /// frozen position (harmless). Worker ranges own disjoint chunk writes.
    /// `chunk_changes` is reserved before the batch; the main thread retargets
    /// drawable runs from it after the join.
    pub fn deriveChunks(
        self: *SimulationScopeSystem,
        data: *DataSystem,
        thread_system: *ThreadSystem,
        grid: ChunkGrid,
        config: ScopeConfig,
    ) !BatchStats {
        const move = data.movementBodySliceConst();
        const n = move.entities.len;
        if (n == 0) return .{};
        const scope = data.scopeColumnsSlice();
        const derive = Dispatch.init(thread_system, &self.chunk_derive_tuner, .{
            .items_per_range = config.items_per_range,
            .batches_per_participant = config.batches_per_participant,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
        });
        const selection = derive.select(n, scope_range_alignment_items);
        try self.prepareRangeWindows(ChunkChange, &self.chunk_changes, n, selection.range_count);
        var context = DeriveChunksContext{
            .position_x = move.position_x,
            .position_y = move.position_y,
            .has_visual = move.has_primitive_visual,
            .chunk_x = scope.chunk_x,
            .chunk_y = scope.chunk_y,
            .grid = grid,
            .changes = self.chunk_changes.items,
            .items_per_range = selection.items_per_range,
            .tallies = self.range_tallies.items,
        };
        const batch = derive.run(selection, n, scope_range_alignment_items, &context, deriveChunkJob);
        const tallies = self.range_tallies.items;
        const changes = self.chunk_changes.items;
        const items_per_range = selection.items_per_range;
        const range_count = selection.range_count;
        const bodies = &data.movement_bodies;
        // Every destination is reserved before any unlink. A failed reserve rolls back the
        // destinations this pass reserved and writes the old chunks back. Standing neighbor
        // reserves stay. The link pass then allocates nothing.
        // Each change is a hash lookup and an append, not a dense float loop.
        for (tallies[0..range_count], 0..) |*slot, range_index| {
            const src = range_index * items_per_range;
            for (changes[src..][0..slot.value.count], 0..) |change, change_index| {
                const row: usize = change.movement_index;
                bodies.reserveDrawableDestination(data.allocator, scope.level[row], scope.chunk_x[row], scope.chunk_y[row]) catch |err| {
                    rollbackDrawableDestinations(data, changes, tallies, items_per_range, range_index, change_index);
                    restoreChunkColumns(scope.chunk_x, scope.chunk_y, changes, tallies, items_per_range, range_count);
                    return err;
                };
            }
        }
        for (tallies[0..range_count], 0..) |*slot, range_index| {
            const src = range_index * items_per_range;
            for (changes[src..][0..slot.value.count]) |change| {
                const row: usize = change.movement_index;
                bodies.relinkReservedDrawable(row, scope.level[row], scope.chunk_x[row], scope.chunk_y[row]);
            }
        }
        bodies.bumpPoseEpoch();
        return batch;
    }

    // ---- Collision gather (threaded compaction) ------------------------------

    /// Build the collision bounds dense-index list from dynamic bounds rows. Returns
    /// null when no dormant or kinematic body exists (no tier exclusion). Statics are
    /// not in the list. No chunk filter.
    pub fn gatherCollisionBoundsIndices(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !ScopeGatherResult {
        const dynamic_ids = data.collision_bounds.dynamic_ids.items;
        const n = dynamic_ids.len;
        if (n == 0) return .{ .indices = &[_]u32{} };
        // Fast-path: only .dormant/.kinematic entities lack collision. With none
        // present, every dynamic row collides → full-active, no per-entity scan.
        if (data.tierCount(.dormant) + data.tierCount(.kinematic) == 0) return .{ .indices = null };

        const bounds = data.collisionBoundsSliceConst();
        const selection = thread_system.selectBatchProfile(&self.collision_gather_tuner, .{
            .item_count = n,
            .items_per_range = config.items_per_range,
            .batches_per_participant = config.batches_per_participant,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive = config.adaptive,
        });
        try self.prepareRangeWindows(u32, &self.collision_indices, n, selection.range_count);
        var context = CollisionGatherContext{
            .dynamic_ids = dynamic_ids,
            .tier = bounds.tier,
            .out = self.collision_indices.items,
            .items_per_range = selection.items_per_range,
            .tallies = self.range_tallies.items,
        };
        const batch = thread_system.parallelForWithOptions(n, &context, collisionGatherJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        const merged = compactIndexWindows(&self.collision_indices, self.range_tallies.items, selection.items_per_range);
        return .{ .indices = if (merged.any_excluded) self.collision_indices.items else null, .perf = scopeBatchPerf(batch) };
    }

    // ---- Think-set phase order ------------------------------------------------

    /// The spatial-index cell grid the think key's chunk and local cell come from.
    pub const ThinkCellGrid = struct {
        cell_size: f32,
        cells_x: u32,
        cells_y: u32,
        cells_per_chunk: u32,
    };

    /// Orders every AI row into an always-active run and one run per stagger phase, cell-major
    /// within each run, and publishes those bounds. One place dispatch and one sort dispatch.
    /// Grows scratch on this thread before either dispatch; workers do not allocate.
    pub fn orderThinkPhases(
        self: *SimulationScopeSystem,
        data: *DataSystem,
        cognition_region: ?ActiveRegion,
        grid: ThinkCellGrid,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !void {
        const n = data.ai_agents.len();
        if (n == 0) {
            self.clearThinkRuns();
            return;
        }
        const grew = try data.ai_agents.prepareOrderImage(data.allocator, n);
        try self.ensureThinkScratch(n);
        if (grew) self.noteThinkScratchGrow(n);
        const splitters = self.sampleThinkSplitters(data, cognition_region, grid, n);
        self.think_keys.items.len = n;
        self.think_staging.items.len = n;
        const place_items = blk: {
            const selection = thread_system.selectBatchProfile(&self.think_order_place_tuner, .{
                .item_count = n,
                .items_per_range = config.items_per_range,
                .batches_per_participant = config.batches_per_participant,
                .max_worker_threads = config.max_worker_threads,
                .range_alignment_items = think_column_alignment,
                .adaptive = config.adaptive,
            });
            try self.prepareThinkOffsets(selection.range_count);
            var place_job = ThinkPlaceJob{
                .data = data,
                .region = cognition_region,
                .grid = grid,
                .splitters = splitters,
                .keys = self.think_keys.items,
                .staging = self.think_staging.items,
                .items_per_range = selection.items_per_range,
                .offsets = self.think_offsets.items,
            };
            _ = thread_system.parallelForWithOptions(n, &place_job, thinkPlaceJob, .{
                .max_worker_threads = selection.worker_threads,
                .range_alignment_items = think_column_alignment,
                .adaptive_tuner = selection.active_tuner,
                .selected_profile = selection.profile,
            });
            break :blk selection.items_per_range;
        };
        var starts: [banded_sort.band_count + 1]u32 = @splat(0);
        for (self.think_offsets.items) |slot| {
            for (&starts, slot.value.offsets) |*start, offset| start.* += offset;
        }
        {
            const selection = thread_system.selectBatchProfile(&self.think_order_tuner, .{
                .item_count = n,
                .items_per_range = config.items_per_range,
                .batches_per_participant = config.batches_per_participant,
                .max_worker_threads = config.max_worker_threads,
                .range_alignment_items = think_column_alignment,
                .adaptive = config.adaptive,
            });
            var sort_job = ThinkSortJob{
                .source = .{
                    .staging = self.think_staging.items,
                    .band_offsets = self.think_offsets.items,
                    .window_stride = place_items,
                },
                .keys = self.think_keys.items,
                .starts = starts,
                .agents = &data.ai_agents,
                .range_count = selection.range_count,
            };
            _ = thread_system.parallelForWithOptions(n, &sort_job, thinkSortJob, .{
                .max_worker_threads = selection.worker_threads,
                .range_alignment_items = think_column_alignment,
                .adaptive_tuner = selection.active_tuner,
                .selected_profile = selection.profile,
            });
        }
        data.ai_agents.publishOrderImage();
        data.retieAiRows();
        self.publishRunBounds(data, cognition_region);
    }

    /// Packs `ai_cognition_indices` into one span of the same entities, in that order, and
    /// packs the perception, memory, and affect rows those agents name to the same order.
    pub fn packThinkSpan(
        self: *SimulationScopeSystem,
        data: *DataSystem,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !void {
        const n = self.ai_cognition_indices.items.len;
        if (n == 0) return;
        const grew = try data.ai_agents.ensureOrderImage(data.allocator, n);
        const perception_grew = try data.ai_perceptions.ensurePackImage(data.allocator, n);
        const memory_grew = try data.ai_memories.ensurePackImage(data.allocator, n);
        const affect_grew = try data.ai_affects.ensurePackImage(data.allocator, n);
        try self.ensureThinkScratch(data.ai_agents.len());
        if (grew or perception_grew or memory_grew or affect_grew) self.noteThinkScratchGrow(n);
        // The image fill and the prefix copies are rounds of this pack. One sample.
        var rounds = RoundDispatch.beginAligned(Dispatch.init(thread_system, &self.think_pack_tuner, .{
            .items_per_range = config.items_per_range,
            .batches_per_participant = config.batches_per_participant,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
        }), n, think_column_alignment);
        const items_per_range = rounds.selection.?.items_per_range;
        var copy_job = ThinkPackJob{
            .agents = &data.ai_agents,
            .perm = self.ai_cognition_indices.items,
            .items_per_range = items_per_range,
        };
        var copy = ThinkCopy{ .rounds = &rounds, .items_per_range = items_per_range };
        copy.dispatch(n, &copy_job, thinkPackJob);
        try self.installThinkSpan(data, n, &copy);
        _ = rounds.finish(n);
    }

    fn clearThinkRuns(self: *SimulationScopeSystem) void {
        self.aa_begin = 0;
        self.aa_halo_end = 0;
        self.aa_end = 0;
        self.phase_begin = @splat(0);
        self.phase_halo_end = @splat(0);
        self.phase_end = @splat(0);
        if (comptime runtime_perf_log.enabled) self.perf.chunk_filtered_entities = 0;
    }

    fn ensureThinkScratch(self: *SimulationScopeSystem, count: usize) !void {
        const before = self.think_keys.capacity;
        try self.think_keys.ensureTotalCapacity(self.allocator, count);
        try self.think_staging.ensureTotalCapacity(self.allocator, count);
        try self.pack_stamp.ensureTotalCapacity(self.allocator, count);
        try self.pack_holes.ensureTotalCapacity(self.allocator, count);
        try self.pack_outside.ensureTotalCapacity(self.allocator, count);
        if (self.think_keys.capacity > before) self.noteThinkScratchGrow(count);
    }

    fn noteThinkScratchGrow(self: *SimulationScopeSystem, count: usize) void {
        self.think_scratch_grows += 1;
        if (self.think_scratch_grow_logged) return;
        self.think_scratch_grow_logged = true;
        if (comptime logging.enabled(.warn)) logging.game.warn("think-set scratch grew to {d} rows", .{count});
    }

    fn prepareThinkOffsets(self: *SimulationScopeSystem, range_count: usize) !void {
        try self.think_offsets.ensureTotalCapacityPrecise(self.allocator, range_count);
        setSlotCount(BandOffsets, &self.think_offsets, range_count);
    }

    fn sampleThinkSplitters(self: *SimulationScopeSystem, data: *const DataSystem, region: ?ActiveRegion, grid: ThinkCellGrid, n: usize) ThinkSort.Splitters {
        _ = self;
        var samples: [banded_sort.splitter_sample_count]u128 = undefined;
        const count = banded_sort.sampleCount(n);
        const agents = data.aiAgentSliceConst();
        const movement = data.movementBodySliceConst();
        const scope = data.scopeColumnsSliceConst();
        for (samples[0..count], 0..) |*sample, index| {
            const row = banded_sort.sampleSlot(index, n);
            sample.* = thinkKeyAt(agents, movement, scope, region, grid, row);
        }
        return ThinkSort.splittersFromSamples(samples[0..count]);
    }

    fn publishRunBounds(self: *SimulationScopeSystem, data: *const DataSystem, region: ?ActiveRegion) void {
        const ai = data.aiAgentSliceConst();
        const n: u32 = @intCast(ai.entities.len);
        var i: u32 = 0;
        self.aa_begin = 0;
        while (i < n and ai.always_active[i] and rowInHalo(ai.tier[i], true, ai.chunk_x[i], ai.chunk_y[i], region)) : (i += 1) {}
        self.aa_halo_end = i;
        while (i < n and ai.always_active[i]) : (i += 1) {}
        self.aa_end = i;
        for (0..4) |phase| {
            const phase_id: u8 = @intCast(phase);
            self.phase_begin[phase] = i;
            while (i < n and !ai.always_active[i] and ai.stagger_phase[i] == phase_id and rowInHalo(ai.tier[i], false, ai.chunk_x[i], ai.chunk_y[i], region)) : (i += 1) {}
            self.phase_halo_end[phase] = i;
            while (i < n and !ai.always_active[i] and ai.stagger_phase[i] == phase_id) : (i += 1) {}
            self.phase_end[phase] = i;
        }
        if (comptime runtime_perf_log.enabled) {
            // The in-halo prefixes are the gather. The suffixes are the rows the halo drops.
            var out_of_halo: usize = @intCast(self.aa_end - self.aa_halo_end);
            for (0..4) |phase| out_of_halo += @intCast(self.phase_end[phase] - self.phase_halo_end[phase]);
            self.perf.chunk_filtered_entities = out_of_halo;
        }
    }

    fn haloCount(self: *const SimulationScopeSystem) usize {
        var n: usize = self.aa_halo_end - self.aa_begin;
        for (0..4) |phase| n += self.phase_halo_end[phase] - self.phase_begin[phase];
        return n;
    }

    fn installThinkSpan(self: *SimulationScopeSystem, data: *DataSystem, n: usize, copy: *ThinkCopy) !void {
        const sources = self.ai_cognition_indices.items[0..n];
        const ai_len = data.ai_agents.len();
        try self.ensureThinkScratch(ai_len);
        self.growStamp(ai_len);
        const stamp = self.bumpStamp();
        for (sources) |source| self.pack_stamp.items[source] = stamp;
        self.pack_holes.clearRetainingCapacity();
        self.pack_outside.clearRetainingCapacity();
        var hole_i: u32 = 0;
        while (hole_i < n) : (hole_i += 1) {
            if (self.pack_stamp.items[hole_i] != stamp) self.pack_holes.appendAssumeCapacity(hole_i);
        }
        for (sources) |source| {
            if (source >= n) self.pack_outside.appendAssumeCapacity(source);
        }
        std.debug.assert(self.pack_holes.items.len == self.pack_outside.items.len);
        const moved = self.pack_holes.items.len;
        if (moved > 0) {
            var scatter = ThinkScatterJob{
                .agents = &data.ai_agents,
                .dest_index = self.pack_outside.items,
                .src_index = self.pack_holes.items,
                .items_per_range = copy.items_per_range,
            };
            copy.dispatch(moved, &scatter, thinkScatterJob);
        }
        var apply = ThinkApplyJob{
            .agents = &data.ai_agents,
            .items_per_range = copy.items_per_range,
        };
        copy.dispatch(n, &apply, thinkApplyJob);
        data.retieAiRows();
        for (sources, 0..) |_, k| sources[k] = @intCast(k);
        try self.packOptionalColumn(data, n, .perception, copy);
        try self.packOptionalColumn(data, n, .memory, copy);
        try self.packOptionalColumn(data, n, .affect, copy);
    }

    fn growStamp(self: *SimulationScopeSystem, len: usize) void {
        if (self.pack_stamp.items.len >= len) return;
        const old = self.pack_stamp.items.len;
        self.pack_stamp.items.len = len;
        @memset(self.pack_stamp.items[old..], 0);
    }

    fn bumpStamp(self: *SimulationScopeSystem) u32 {
        self.pack_stamp_id +%= 1;
        if (self.pack_stamp_id == 0) {
            @memset(self.pack_stamp.items, 0);
            self.pack_stamp_id = 1;
        }
        return self.pack_stamp_id;
    }

    fn packOptionalColumn(self: *SimulationScopeSystem, data: *DataSystem, n: usize, column: DataSystem.PackedColumn, copy: *ThinkCopy) !void {
        const agents = data.aiAgentSliceConst();
        self.pack_holes.clearRetainingCapacity();
        for (0..n) |k| {
            const row = switch (column) {
                .perception => agents.perception_row[k],
                .memory => agents.memory_row[k],
                .affect => agents.affect_row[k],
            };
            if (row != no_component_row) self.pack_holes.appendAssumeCapacity(row);
        }
        const listed = self.pack_holes.items.len;
        if (listed == 0) return;
        const store_len: usize = switch (column) {
            .perception => data.ai_perceptions.len(),
            .memory => data.ai_memories.len(),
            .affect => data.ai_affects.len(),
        };
        // Size for the store before the slice is captured. `installOptionalRows` ensures
        // the same count; a later grow would free this slice under the stamp walk.
        const outside_before = self.pack_outside.capacity;
        try self.pack_outside.ensureTotalCapacity(self.allocator, @max(store_len, listed));
        if (self.pack_outside.capacity > outside_before) self.noteThinkScratchGrow(store_len);
        self.pack_outside.clearRetainingCapacity();
        self.pack_outside.appendSliceAssumeCapacity(self.pack_holes.items);
        const old_sources = self.pack_outside.items;
        var image = OptionalPackJob{
            .data = data,
            .column = column,
            .mode = .to_image,
            .perm = old_sources,
            .items_per_range = copy.items_per_range,
        };
        copy.dispatch(listed, &image, optionalPackJob);
        try self.installOptionalRows(data, old_sources, column, copy);
    }

    fn installOptionalRows(self: *SimulationScopeSystem, data: *DataSystem, sources: []const u32, column: DataSystem.PackedColumn, copy: *ThinkCopy) !void {
        const n = sources.len;
        const store_len: usize = switch (column) {
            .perception => data.ai_perceptions.len(),
            .memory => data.ai_memories.len(),
            .affect => data.ai_affects.len(),
        };
        try self.ensureThinkScratch(@max(store_len, n));
        self.growStamp(store_len);
        const stamp = self.bumpStamp();
        for (sources) |source| self.pack_stamp.items[source] = stamp;
        self.pack_holes.clearRetainingCapacity();
        var hole_i: u32 = 0;
        while (hole_i < n) : (hole_i += 1) {
            if (self.pack_stamp.items[hole_i] != stamp) self.pack_holes.appendAssumeCapacity(hole_i);
        }
        if (self.think_keys.items.len < n) self.think_keys.items.len = n;
        var outside_count: usize = 0;
        for (sources) |source| {
            if (source >= n) {
                self.think_keys.items[outside_count].source = source;
                outside_count += 1;
            }
        }
        std.debug.assert(outside_count == self.pack_holes.items.len);
        if (outside_count > 0) {
            var scatter = OptionalPackJob{
                .data = data,
                .column = column,
                .mode = .scatter,
                .holes = self.pack_holes.items,
                .slots = self.think_keys.items,
                .items_per_range = copy.items_per_range,
            };
            copy.dispatch(outside_count, &scatter, optionalPackJob);
        }
        var apply = OptionalPackJob{
            .data = data,
            .column = column,
            .mode = .from_image,
            .items_per_range = copy.items_per_range,
        };
        copy.dispatch(n, &apply, optionalPackJob);
        for (0..outside_count) |j| data.retiePackedRow(column, self.think_keys.items[j].source);
        for (0..n) |k| data.retiePackedRow(column, @intCast(k));
    }

    // ---- AI halo gather and think set (threaded compactions) -----------------

    /// Builds this step's AI halo from the phase runs `orderThinkPhases` published:
    /// the always-active in-halo prefix and each phase's in-halo prefix.
    pub fn gatherAiPopulations(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        cognition_region: ?ActiveRegion,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !AiPopulationGatherResult {
        _ = data;
        _ = cognition_region;
        const n = self.haloCount();
        self.perf = .{};
        if (n == 0) {
            self.ai_halo_indices.clearRetainingCapacity();
            return .{ .halo = self.ai_halo_indices.items };
        }

        const selection = thread_system.selectBatchProfile(&self.ai_gather_tuner, .{
            .item_count = n,
            .items_per_range = config.items_per_range,
            .batches_per_participant = config.batches_per_participant,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive = config.adaptive,
        });
        try self.prepareRangeWindows(u32, &self.ai_halo_indices, n, selection.range_count);
        var context = AiGatherContext{
            .aa_begin = self.aa_begin,
            .aa_halo_end = self.aa_halo_end,
            .phase_begin = self.phase_begin,
            .phase_halo_end = self.phase_halo_end,
            .item_count = n,
            .out = self.ai_halo_indices.items,
            .items_per_range = selection.items_per_range,
            .tallies = self.range_tallies.items,
        };
        const batch = thread_system.parallelForWithOptions(n, &context, aiGatherJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        _ = compactIndexWindows(&self.ai_halo_indices, self.range_tallies.items, selection.items_per_range);
        return .{ .halo = self.ai_halo_indices.items, .perf = scopeBatchPerf(batch) };
    }

    /// The step's think set: every row the index holds (`population_row`, dense AI indices)
    /// whose cognition phase (`cognition_phase`, written by the index build) is this step,
    /// all of them when `apply_stagger` is false, in the index's cell-major order. Runs on
    /// workers under `cognition_tuner` over the cell-major positions, so one chunk's entries
    /// split across ranges like any others. `perf.stagger_skips` counts the rest. Allocates only
    /// past `reserve`'s capacity, on the calling thread before dispatch.
    pub fn compactCognition(
        self: *SimulationScopeSystem,
        index: *const SpatialIndexView,
        stagger_step: u8,
        apply_stagger: bool,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !CognitionResult {
        const entry_count = index.entryCount();
        if (comptime runtime_perf_log.enabled) self.perf.stagger_skips = 0;
        if (entry_count == 0) {
            self.ai_cognition_indices.clearRetainingCapacity();
            return .{ .cognition = self.ai_cognition_indices.items };
        }
        const selection = thread_system.selectBatchProfile(&self.cognition_tuner, .{
            .item_count = entry_count,
            .items_per_range = config.items_per_range,
            .batches_per_participant = config.batches_per_participant,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive = config.adaptive,
        });
        try self.prepareRangeWindows(u32, &self.ai_cognition_indices, entry_count, selection.range_count);
        var context = self.cognitionContext(index, stagger_step, apply_stagger, selection.items_per_range);
        const batch = thread_system.parallelForWithOptions(entry_count, &context, cognitionJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        const merged = compactIndexWindows(&self.ai_cognition_indices, self.range_tallies.items, selection.items_per_range);
        if (comptime runtime_perf_log.enabled) self.perf.stagger_skips = merged.perf.stagger_skips;
        return .{ .cognition = self.ai_cognition_indices.items, .perf = scopeBatchPerf(batch) };
    }

    fn cognitionContext(self: *SimulationScopeSystem, index: *const SpatialIndexView, stagger_step: u8, apply_stagger: bool, items_per_range: usize) CognitionContext {
        // A step's phase never reads as every phase.
        std.debug.assert(stagger_step != every_cognition_phase);
        return .{
            .index = index,
            .stagger_step = stagger_step,
            .apply_stagger = apply_stagger,
            .out = self.ai_cognition_indices.items,
            .items_per_range = items_per_range,
            .tallies = self.range_tallies.items,
        };
    }

    // ---- Simulation-LOD tier policy (threaded variable-output producer) -------

    /// Runs the per-step tier policy and writes the resulting set_simulation_tier
    /// commands into the frame's structural-command stream. Threads the dense scan
    /// into per-range windows of `scope_tier_commands`, then streams each window in
    /// range order via the append protocol so it coexists with any other
    /// structural-command producer. No-op (no stream touch) when nothing changes.
    /// Returns the pass batch.
    pub fn queueTierChanges(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        visible_region: ?ActiveRegion,
        stream: *RangeOutputStream(StructuralCommand),
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !BatchStats {
        const region = visible_region orelse return .{};
        const scope = data.scopeColumnsSliceConst();
        const n = scope.entities.len;
        if (n == 0) return .{};

        const selection = thread_system.selectBatchProfile(&self.tier_policy_tuner, .{
            .item_count = n,
            .items_per_range = config.items_per_range,
            .batches_per_participant = config.batches_per_participant,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive = config.adaptive,
        });
        try self.prepareRangeWindows(StructuralCommand, &self.scope_tier_commands, n, selection.range_count);
        var context = TierPolicyContext{
            .scope = scope,
            .region = region,
            .out = self.scope_tier_commands.items,
            .items_per_range = selection.items_per_range,
            .tallies = self.range_tallies.items,
        };
        const batch = thread_system.parallelForWithOptions(n, &context, tierPolicyJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        const tallies = self.range_tallies.items;
        var total: usize = 0;
        for (tallies) |*slot| total += slot.value.count;
        // No tier crossed a band this step → leave the stream untouched so other
        // structural producers' append protocol is unaffected.
        if (total == 0) return batch;

        const windows = self.scope_tier_commands.items;
        const range_base = try stream.appendRangeCounts(tallies.len);
        for (tallies, 0..) |*slot, range_index| {
            stream.addCount(range_base + range_index, slot.value.count);
        }
        try stream.prefixAppendedRanges(range_base);
        for (tallies, 0..) |*slot, range_index| {
            var writer = stream.rangeWriter(range_base + range_index);
            const window_start = range_index * selection.items_per_range;
            for (windows[window_start..][0..slot.value.count]) |command| writer.write(command);
            writer.finish();
        }
        stream.finishWrite();
        return batch;
    }

    // ---- Shared threading helpers --------------------------------------------

    /// Sizes `out` to `item_count` window slots (range r owns `[r * items_per_range,
    /// ...)`) and resets `range_count` tallies. Main thread, before dispatch. The ensures
    /// are grow-only safety nets: after `reserve` at the population seam they never
    /// allocate, whatever partition the tuner picked (`maxRangeCount`).
    fn prepareRangeWindows(
        self: *SimulationScopeSystem,
        comptime T: type,
        out: *std.array_list.Aligned(T, .fromByteUnits(thread_shared_record_alignment)),
        item_count: usize,
        range_count: usize,
    ) !void {
        try out.ensureTotalCapacity(self.allocator, item_count);
        out.items.len = item_count;
        try self.range_tallies.ensureTotalCapacity(self.allocator, range_count);
        setSlotCount(GatherTally, &self.range_tallies, range_count);
    }
};

const IndexMergeResult = struct {
    any_excluded: bool = false,
    perf: GatherPerf = .{},
};

// ---- Per-range windows and tallies ------------------------------------------

/// Cache-line-aligned output lists: with a 16-item range alignment, every range's
/// window starts on a cache-line boundary for u32 rows, so concurrent range writes
/// never share a line.
const IndexList = std.array_list.Aligned(u32, .fromByteUnits(thread_shared_record_alignment));
const CommandList = std.array_list.Aligned(StructuralCommand, .fromByteUnits(thread_shared_record_alignment));

/// One range's output count and perf counts, written once by the range's job.
const GatherTally = struct {
    count: usize = 0,
    // Movement/collision null decision: set when any scanned row was excluded.
    any_excluded: bool = false,
    perf: GatherPerf = .{},
};

// A range's `SimulationScopeSystem.Perf` counts, kept only with `runtime_perf_log.enabled`:
// an AI gather range's rows outside the halo and a think-set range's indexed rows off this
// step's phase, summed on compaction.
const GatherPerf = if (runtime_perf_log.enabled) struct {
    chunk_filtered: usize = 0,
    stagger_skips: usize = 0,
} else struct {};

const GatherTallySlot = PaddedSlot(GatherTally);

/// Compacts the per-range windows of `list` (range r's `count` records at
/// `r * items_per_range`) into one contiguous prefix in range order and sums the
/// tallies. The destination never passes the source (each window starts at or after
/// the running total), so a forward copy is safe, and a step where no range excluded
/// anything copies nothing.
fn compactIndexWindows(list: *IndexList, tallies: []const GatherTallySlot, items_per_range: usize) IndexMergeResult {
    var result: IndexMergeResult = .{};
    var dst: usize = 0;
    for (tallies, 0..) |*slot, range_index| {
        const tally = slot.value;
        if (tally.any_excluded) result.any_excluded = true;
        if (comptime runtime_perf_log.enabled) {
            result.perf.chunk_filtered += tally.perf.chunk_filtered;
            result.perf.stagger_skips += tally.perf.stagger_skips;
        }
        const src = range_index * items_per_range;
        std.debug.assert(dst <= src);
        if (dst != src and tally.count != 0) {
            @memmove(list.items[dst..][0..tally.count], list.items[src..][0..tally.count]);
        }
        dst += tally.count;
    }
    list.items.len = dst;
    return result;
}

// ---- Job contexts and functions ---------------------------------------------

const ChunkChange = struct {
    movement_index: u32,
    old_chunk_x: i32,
    old_chunk_y: i32,
};

const ChunkChangeList = std.array_list.Aligned(ChunkChange, .fromByteUnits(thread_shared_record_alignment));

const DeriveChunksContext = struct {
    position_x: []const f32,
    position_y: []const f32,
    has_visual: []const bool,
    chunk_x: HotI32Slice,
    chunk_y: HotI32Slice,
    grid: SimulationScopeSystem.ChunkGrid,
    changes: []ChunkChange,
    items_per_range: usize,
    tallies: []GatherTallySlot,
};

fn deriveChunkJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *DeriveChunksContext = @ptrCast(@alignCast(context));
    // Worker ranges own disjoint rows; the chunk columns share the movement-body
    // store length, so a range can never write past them.
    std.debug.assert(range.end <= job.chunk_x.len);
    std.debug.assert(range.end <= job.chunk_y.len);
    const grid = job.grid;
    const chunk_size: i32 = @intCast(@max(grid.chunk_size_tiles, 1));
    const chunk_div = simd.splatInt4(chunk_size);

    var i = range.start;
    const count = range.end - range.start;
    const vend = range.start + simd.vectorizedEnd(count);
    while (i < vend) : (i += simd.lane_count) {
        // Dense contiguous SoA: load four positions, worldPosToCell4 (floor +
        // clamp, matching math.worldPosToCell), then truncating cell/chunk divide.
        const px = simd.loadFloat4(job.position_x[i..]);
        const py = simd.loadFloat4(job.position_y[i..]);
        const tx = simd.worldPosToCell4(px, grid.tile_size, grid.width);
        const ty = simd.worldPosToCell4(py, grid.tile_size, grid.height);
        const cx = simd.toIntArray(simd.divInt4(tx, chunk_div));
        const cy = simd.toIntArray(simd.divInt4(ty, chunk_div));
        inline for (0..simd.lane_count) |lane| {
            recordChunkChange(job, range, i + lane, cx[lane], cy[lane]);
        }
    }
    while (i < range.end) : (i += 1) {
        const tx = math.worldPosToCell(job.position_x[i], grid.tile_size, grid.width);
        const ty = math.worldPosToCell(job.position_y[i], grid.tile_size, grid.height);
        const cx: i32 = @intCast(tx / @as(u32, @intCast(chunk_size)));
        const cy: i32 = @intCast(ty / @as(u32, @intCast(chunk_size)));
        recordChunkChange(job, range, i, cx, cy);
    }
}

fn rollbackDrawableDestinations(
    data: *DataSystem,
    changes: []const ChunkChange,
    tallies: []const GatherTallySlot,
    items_per_range: usize,
    failed_range: usize,
    failed_change: usize,
) void {
    const scope = data.scopeColumnsSlice();
    const bodies = &data.movement_bodies;
    for (tallies[0..failed_range], 0..) |*slot, range_index| {
        const src = range_index * items_per_range;
        for (changes[src..][0..slot.value.count]) |change| {
            const row: usize = change.movement_index;
            bodies.unreserveDrawableDestination(scope.level[row], scope.chunk_x[row], scope.chunk_y[row]);
        }
    }
    const src = failed_range * items_per_range;
    for (changes[src..][0..failed_change]) |change| {
        const row: usize = change.movement_index;
        bodies.unreserveDrawableDestination(scope.level[row], scope.chunk_x[row], scope.chunk_y[row]);
    }
}

fn restoreChunkColumns(
    chunk_x: []i32,
    chunk_y: []i32,
    changes: []const ChunkChange,
    tallies: []const GatherTallySlot,
    items_per_range: usize,
    range_count: usize,
) void {
    for (tallies[0..range_count], 0..) |*slot, range_index| {
        const src = range_index * items_per_range;
        for (changes[src..][0..slot.value.count]) |change| {
            chunk_x[change.movement_index] = change.old_chunk_x;
            chunk_y[change.movement_index] = change.old_chunk_y;
        }
    }
}

fn recordChunkChange(job: *DeriveChunksContext, range: ParallelRange, index: usize, chunk_x: i32, chunk_y: i32) void {
    const old_x = job.chunk_x[index];
    const old_y = job.chunk_y[index];
    job.chunk_x[index] = chunk_x;
    job.chunk_y[index] = chunk_y;
    if (!job.has_visual[index] or (old_x == chunk_x and old_y == chunk_y)) return;
    const tally = &job.tallies[range.index].value;
    job.changes[range.index * job.items_per_range + tally.count] = .{
        .movement_index = @intCast(index),
        .old_chunk_x = old_x,
        .old_chunk_y = old_y,
    };
    tally.count += 1;
}

/// Writes a set_simulation_tier command into `out` for each non-pinned entity of
/// `[start, end)` whose cube-LOD tier differs from its current one, in lanes with a scalar
/// tail equal to `lodDistance`/`tierForChunkDistance`; returns the count.
fn scanTierPolicy(
    scope: ConstScopeColumnsSlice,
    region: ActiveRegion,
    start: usize,
    end: usize,
    out: []StructuralCommand,
) usize {
    std.debug.assert(out.len >= end - start);
    var count: usize = 0;
    const min_x = simd.splatInt4(region.min.x);
    const min_y = simd.splatInt4(region.min.y);
    const max_x = simd.splatInt4(region.max_exclusive.x - 1);
    const max_y = simd.splatInt4(region.max_exclusive.y - 1);
    const region_level = simd.splatInt4(@intCast(region.level));
    const penalty_per = simd.splatInt4(@intCast(level_distance_chunks));
    const zero = simd.splatInt4(0);
    const cog = simd.splatInt4(@intCast(cognition_halo_chunks));
    const loco = simd.splatInt4(@intCast(locomotion_halo_chunks));
    const kin = simd.splatInt4(@intCast(kinematic_halo_chunks));

    var i = start;
    const vend = start + simd.vectorizedEnd(end - start);
    while (i < vend) : (i += simd.lane_count) {
        const cx = simd.loadInt4(scope.chunk_x[i..]);
        const cy = simd.loadInt4(scope.chunk_y[i..]);
        const lv = simd.int4(
            @intCast(scope.level[i]),
            @intCast(scope.level[i + 1]),
            @intCast(scope.level[i + 2]),
            @intCast(scope.level[i + 3]),
        );
        // Chebyshev chunk distance: max over each axis of (under-min, over-max, 0).
        const dx = simd.maxInt4(simd.maxInt4(simd.subInt4(min_x, cx), simd.subInt4(cx, max_x)), zero);
        const dy = simd.maxInt4(simd.maxInt4(simd.subInt4(min_y, cy), simd.subInt4(cy, max_y)), zero);
        const chebyshev = simd.maxInt4(dx, dy);
        // Per-level penalty floors the distance so off-level rows read as far.
        const level_delta = simd.subInt4(lv, region_level);
        const level_abs = simd.maxInt4(level_delta, simd.subInt4(zero, level_delta));
        const distance = simd.maxInt4(chebyshev, simd.mulInt4(level_abs, penalty_per));
        const over_cog = simd.subInt4(distance, cog);
        const over_loco = simd.subInt4(distance, loco);
        const over_kin = simd.subInt4(distance, kin);
        inline for (0..simd.lane_count) |lane| {
            const idx = i + lane;
            var correct_tier: SimulationTier = .cognition;
            if (over_cog[lane] > 0) correct_tier = .locomotion;
            if (over_loco[lane] > 0) correct_tier = .kinematic;
            if (over_kin[lane] > 0) correct_tier = .dormant;
            if (!scope.always_active[idx] and scope.tier[idx] != correct_tier) {
                out[count] = .{ .set_simulation_tier = .{ .entity = scope.entities[idx], .tier = correct_tier } };
                count += 1;
            }
        }
    }
    while (i < end) : (i += 1) {
        if (scope.always_active[i]) continue;
        const distance = region.lodDistance(.{ .x = scope.chunk_x[i], .y = scope.chunk_y[i] }, scope.level[i]);
        const correct_tier = tierForChunkDistance(distance);
        if (scope.tier[i] != correct_tier) {
            out[count] = .{ .set_simulation_tier = .{ .entity = scope.entities[i], .tier = correct_tier } };
            count += 1;
        }
    }
    return count;
}

const ThinkKey = struct {
    key: u128,
    source: u32,
};

fn thinkKeyOf(item: ThinkKey) u128 {
    return item.key;
}

const ThinkSort = banded_sort.BandedSort(ThinkKey, thinkKeyOf);
const ThinkKeyList = std.ArrayList(ThinkKey);

fn thinkKeyLess(_: void, lhs: ThinkKey, rhs: ThinkKey) bool {
    return lhs.key < rhs.key;
}

fn rowInHalo(tier: SimulationTier, always_active: bool, chunk_x: i32, chunk_y: i32, region: ?ActiveRegion) bool {
    if (!tier.allowsCognition()) return false;
    if (always_active) return true;
    if (region) |active| return active.containsChunk(.{ .x = chunk_x, .y = chunk_y });
    return true;
}

fn packThinkKey(always_active: bool, phase: u8, in_halo: bool, level: u16, chunk_x: u32, chunk_y: u32, local_x: u32, local_y: u32, faction: u32, entity: u32) u128 {
    const aa_bit: u128 = if (always_active) 0 else 1;
    const phase_bits: u128 = if (always_active) 0 else phase;
    const halo_bit: u128 = if (in_halo) 0 else 1;
    return (aa_bit << 127) | (phase_bits << 125) | (halo_bit << 124) |
        (@as(u128, level) << 108) | (@as(u128, chunk_y & 0x7fff_ffff) << 77) | (@as(u128, chunk_x & 0x7fff_ffff) << 46) |
        (@as(u128, local_y) << 40) | (@as(u128, local_x) << 34) | (@as(u128, faction) << 32) | entity;
}

fn cellParts(grid: SimulationScopeSystem.ThinkCellGrid, x: f32, y: f32) struct { chunk_x: u32, chunk_y: u32, local_x: u32, local_y: u32 } {
    const cx = math.worldPosToCell(x, grid.cell_size, grid.cells_x);
    const cy = math.worldPosToCell(y, grid.cell_size, grid.cells_y);
    const per = if (grid.cells_per_chunk == 0) 1 else grid.cells_per_chunk;
    return .{ .chunk_x = cx / per, .chunk_y = cy / per, .local_x = cx % per, .local_y = cy % per };
}

fn thinkKeyAt(agents: ConstAiAgentSlice, movement: ConstMovementBodySlice, scope: ConstScopeColumnsSlice, region: ?ActiveRegion, grid: SimulationScopeSystem.ThinkCellGrid, row: usize) u128 {
    const linked = agents.movement_row[row];
    const tier = if (linked == no_component_row) agents.tier[row] else scope.tier[linked];
    const always_active = if (linked == no_component_row) agents.always_active[row] else scope.always_active[linked];
    const phase = if (linked == no_component_row) agents.stagger_phase[row] else scope.stagger_phase[linked];
    const level = if (linked == no_component_row) agents.level[row] else scope.level[linked];
    const chunk_x = if (linked == no_component_row) agents.chunk_x[row] else scope.chunk_x[linked];
    const chunk_y = if (linked == no_component_row) agents.chunk_y[row] else scope.chunk_y[linked];
    const previous_x = if (linked == no_component_row) agents.previous_x[row] else movement.previous_x[linked];
    const previous_y = if (linked == no_component_row) agents.previous_y[row] else movement.previous_y[linked];
    const cell = cellParts(grid, previous_x, previous_y);
    return packThinkKey(always_active, phase, rowInHalo(tier, always_active, chunk_x, chunk_y, region), level, cell.chunk_x, cell.chunk_y, cell.local_x, cell.local_y, @intCast(@backingInt(agents.faction[row])), agents.entities[row].index);
}

const ThinkPlaceJob = struct {
    data: *DataSystem,
    region: ?ActiveRegion,
    grid: SimulationScopeSystem.ThinkCellGrid,
    splitters: ThinkSort.Splitters,
    keys: []ThinkKey,
    staging: []ThinkKey,
    items_per_range: usize,
    offsets: []PaddedSlot(BandOffsets),
};

fn thinkPlaceJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ThinkPlaceJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.offsets.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.keys.len and range.end <= job.staging.len);
    const writable = job.data.ai_agents.rows.slice();
    const movement = job.data.movementBodySliceConst();
    const scope = job.data.scopeColumnsSliceConst();
    const movement_row = writable.items(.movement_row);
    const level = writable.items(.level);
    const chunk_x = writable.items(.chunk_x);
    const chunk_y = writable.items(.chunk_y);
    const tier = writable.items(.tier);
    const phase = writable.items(.stagger_phase);
    const always_active = writable.items(.always_active);
    const previous_x = writable.items(.previous_x);
    const previous_y = writable.items(.previous_y);
    const velocity_x = writable.items(.velocity_x);
    const velocity_y = writable.items(.velocity_y);
    for (range.start..range.end) |i| {
        const linked = movement_row[i];
        if (linked == no_component_row) continue;
        level[i] = scope.level[linked];
        chunk_x[i] = scope.chunk_x[linked];
        chunk_y[i] = scope.chunk_y[linked];
        tier[i] = scope.tier[linked];
        phase[i] = scope.stagger_phase[linked];
        always_active[i] = scope.always_active[linked];
        previous_x[i] = movement.previous_x[linked];
        previous_y[i] = movement.previous_y[linked];
        velocity_x[i] = movement.velocity_x[linked];
        velocity_y[i] = movement.velocity_y[linked];
    }
    var i = range.start;
    while (i < range.end) {
        const count = @min(simd.lane_count, range.end - i);
        const cell_x = simd.worldPosToCell4(simd.loadFloat4Lanes(previous_x[i..], count), job.grid.cell_size, job.grid.cells_x);
        const cell_y = simd.worldPosToCell4(simd.loadFloat4Lanes(previous_y[i..], count), job.grid.cell_size, job.grid.cells_y);
        const per: u32 = if (job.grid.cells_per_chunk == 0) 1 else job.grid.cells_per_chunk;
        const factions = writable.items(.faction);
        const entities = writable.items(.entity);
        inline for (0..simd.lane_count) |lane| {
            if (lane < count) {
                const row = i + lane;
                const cx: u32 = @intCast(cell_x[lane]);
                const cy: u32 = @intCast(cell_y[lane]);
                const in_halo = rowInHalo(tier[row], always_active[row], chunk_x[row], chunk_y[row], job.region);
                job.keys[row] = .{
                    .key = packThinkKey(always_active[row], phase[row], in_halo, level[row], cx / per, cy / per, cx % per, cy % per, @intCast(@backingInt(factions[row])), entities[row].index),
                    .source = @intCast(row),
                };
            }
        }
        i += count;
    }
    job.offsets[range.index].value = ThinkSort.placeByBand(&job.splitters, job.keys[range.start..range.end], job.staging[range.start..range.end]);
}

const ThinkSortJob = struct {
    source: ThinkSort.WindowSource,
    keys: []ThinkKey,
    starts: [banded_sort.band_count + 1]u32,
    agents: *@import("../data_system/agents.zig").AiAgentStore,
    range_count: usize,
};

fn thinkSourceAt(keys: []ThinkKey, index: usize) usize {
    // `source` is a row index stored as u32.
    return @intCast(keys[index].source);
}

fn thinkSlotAt(keys: []const ThinkKey, index: usize) usize {
    return @intCast(keys[index].source);
}

fn thinkSortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ThinkSortJob = @ptrCast(@alignCast(context));
    const total = job.starts[banded_sort.band_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.end <= total and total <= job.keys.len);
    var spans: [banded_sort.band_count][2]usize = undefined;
    var span_count: usize = 0;
    var owned = banded_sort.OwnedBands.init(&job.starts, range.start, range.end);
    while (owned.next()) |band| {
        const start: usize = job.starts[band];
        const end: usize = job.starts[band + 1];
        const gathered = ThinkSort.gatherBand(job.keys[start..end], band, .{job.source});
        std.debug.assert(gathered == end - start);
        pdqSort(ThinkKey, job.keys[start..end], {}, thinkKeyLess);
        spans[span_count] = .{ start, end };
        span_count += 1;
    }
    if (span_count == 0) return;
    job.agents.writeOrderSpans(spans[0..span_count], job.keys, thinkSourceAt);
}

const ThinkPackJob = struct {
    agents: *@import("../data_system/agents.zig").AiAgentStore,
    perm: []const u32,
    items_per_range: usize,
};

fn thinkPackJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ThinkPackJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.perm.len);
    job.agents.writeOrderImage(range.start, range.end, job.perm);
}

const ThinkScatterJob = struct {
    agents: *@import("../data_system/agents.zig").AiAgentStore,
    dest_index: []const u32,
    src_index: []const u32,
    items_per_range: usize,
};

fn thinkScatterJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ThinkScatterJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.dest_index.len and range.end <= job.src_index.len);
    job.agents.scatterRows(range.start, range.end, job.dest_index, job.src_index, u32Index, u32Index);
}

const ThinkApplyJob = struct {
    agents: *@import("../data_system/agents.zig").AiAgentStore,
    items_per_range: usize,
};

fn thinkApplyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ThinkApplyJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.end <= job.agents.len());
    job.agents.copyOrderToRows(range.start, range.end);
}

const OptionalPackMode = enum { to_image, scatter, from_image };

const OptionalPackJob = struct {
    data: *DataSystem,
    column: DataSystem.PackedColumn,
    mode: OptionalPackMode,
    perm: []const u32 = &.{},
    holes: []const u32 = &.{},
    slots: []const ThinkKey = &.{},
    items_per_range: usize,
};

fn optionalPackJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *OptionalPackJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    switch (job.mode) {
        .to_image => {
            std.debug.assert(range.end <= job.perm.len);
            switch (job.column) {
                .perception => job.data.ai_perceptions.copyToPack(range.start, range.end, job.perm),
                .memory => job.data.ai_memories.copyToPack(range.start, range.end, job.perm),
                .affect => job.data.ai_affects.copyToPack(range.start, range.end, job.perm),
            }
        },
        .scatter => {
            std.debug.assert(range.end <= job.holes.len and range.end <= job.slots.len);
            switch (job.column) {
                .perception => job.data.ai_perceptions.scatterRows(range.start, range.end, job.slots, job.holes, thinkSlotAt, u32Index),
                .memory => job.data.ai_memories.scatterRows(range.start, range.end, job.slots, job.holes, thinkSlotAt, u32Index),
                .affect => job.data.ai_affects.scatterRows(range.start, range.end, job.slots, job.holes, thinkSlotAt, u32Index),
            }
        },
        .from_image => switch (job.column) {
            .perception => job.data.ai_perceptions.copyPackToRows(range.start, range.end),
            .memory => job.data.ai_memories.copyPackToRows(range.start, range.end),
            .affect => job.data.ai_affects.copyPackToRows(range.start, range.end),
        },
    }
}

const u32Index = @import("../data_system/types.zig").u32Index;

const ThinkCopy = struct {
    rounds: *RoundDispatch,
    items_per_range: usize,

    fn dispatch(self: *ThinkCopy, item_count: usize, context: *anyopaque, job_fn: JobFn) void {
        if (item_count == 0) return;
        var range_count: usize = 0;
        self.rounds.run(item_count, context, &range_count, job_fn);
    }
};

const CollisionGatherContext = struct {
    dynamic_ids: []const u32,
    tier: []const SimulationTier,
    /// Item-count output; range r writes only its own `[range.start, range.end)` window.
    out: []u32,
    items_per_range: usize,
    tallies: []GatherTallySlot,
};

/// Asserts the reserve-before-dispatch invariant shared by every window job: the
/// range index is within the dispatched tally count, the range is the window the
/// main-thread compaction expects, and it stays inside the output buffer.
fn assertRangeWindow(range: ParallelRange, items_per_range: usize, tally_count: usize, out_len: usize) void {
    std.debug.assert(range.index < tally_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.start == range.index * items_per_range);
    std.debug.assert(range.end <= out_len);
}

fn collisionGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CollisionGatherContext = @ptrCast(@alignCast(context));
    assertRangeWindow(range, job.items_per_range, job.tallies.len, job.out.len);
    const window = job.out[range.start..range.end];
    var tally: GatherTally = .{};
    for (range.start..range.end) |i| {
        const bounds_index = job.dynamic_ids[i];
        if (job.tier[bounds_index].allowsCollision()) {
            window[tally.count] = bounds_index;
            tally.count += 1;
        } else {
            tally.any_excluded = true;
        }
    }
    job.tallies[range.index].value = tally;
}

const AiGatherContext = struct {
    aa_begin: u32,
    aa_halo_end: u32,
    phase_begin: [4]u32,
    phase_halo_end: [4]u32,
    item_count: usize,
    /// Item-count output; range r writes only its own `[range.start, range.end)` window.
    out: []u32,
    items_per_range: usize,
    tallies: []GatherTallySlot,

    fn rowAt(self: *const AiGatherContext, item: usize) u32 {
        const aa: usize = self.aa_halo_end - self.aa_begin;
        if (item < aa) return self.aa_begin + @as(u32, @intCast(item));
        var cursor = aa;
        for (0..4) |phase| {
            const count: usize = self.phase_halo_end[phase] - self.phase_begin[phase];
            if (item < cursor + count) return self.phase_begin[phase] + @as(u32, @intCast(item - cursor));
            cursor += count;
        }
        unreachable;
    }
};

fn aiGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiGatherContext = @ptrCast(@alignCast(context));
    assertRangeWindow(range, job.items_per_range, job.tallies.len, job.out.len);
    std.debug.assert(range.end <= job.item_count);
    const window = job.out[range.start..range.end];
    var tally: GatherTally = .{};
    for (range.start..range.end) |i| {
        window[tally.count] = job.rowAt(i);
        tally.count += 1;
    }
    job.tallies[range.index].value = tally;
}

const CognitionContext = struct {
    index: *const SpatialIndexView,
    stagger_step: u8,
    apply_stagger: bool,
    /// Entry-count output; range r writes only its own `[range.start, range.end)` window.
    out: []u32,
    items_per_range: usize,
    tallies: []GatherTallySlot,
};

// Range r compacts cell-major positions `[range.start, range.end)` into its window, reading
// only the index's entry columns. Scalar: a compaction over runs of `population_row` and
// `cognition_phase`.
fn cognitionJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CognitionContext = @ptrCast(@alignCast(context));
    const index = job.index;
    assertRangeWindow(range, job.items_per_range, job.tallies.len, job.out.len);
    std.debug.assert(job.out.len == index.entryCount());
    const window = job.out[range.start..range.end];
    var tally: GatherTally = .{};
    var span = index.cellMajorSpan(range.start, range.end);
    while (span.next(index)) |run| {
        for (index.population_row[run.start..run.end], index.cognition_phase[run.start..run.end]) |ai_index, phase| {
            if (!job.apply_stagger or phase == job.stagger_step or phase == every_cognition_phase) {
                window[tally.count] = ai_index;
                tally.count += 1;
            } else if (comptime runtime_perf_log.enabled) {
                tally.perf.stagger_skips += 1;
            }
        }
    }
    job.tallies[range.index].value = tally;
}

const TierPolicyContext = struct {
    scope: ConstScopeColumnsSlice,
    region: ActiveRegion,
    /// Item-count output; range r writes only its own `[range.start, range.end)` window.
    out: []StructuralCommand,
    items_per_range: usize,
    tallies: []GatherTallySlot,
};

fn tierPolicyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *TierPolicyContext = @ptrCast(@alignCast(context));
    assertRangeWindow(range, job.items_per_range, job.tallies.len, job.out.len);
    const count = scanTierPolicy(job.scope, job.region, range.start, range.end, job.out[range.start..range.end]);
    job.tallies[range.index].value = .{ .count = count };
}

// ---- Tests ------------------------------------------------------------------

const SpatialIndexSystem = @import("spatial_index.zig").SpatialIndexSystem;
const testHaloIndex = @import("spatial_index_test_support.zig").testHaloIndex;

// A thread system with no workers: every pass runs its production path inline as one
// range and records no tuner sample.
fn inlineThreads() !ThreadSystem {
    return ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
}

fn testThinkGrid() SimulationScopeSystem.ThinkCellGrid {
    return .{ .cell_size = 32, .cells_x = 4096, .cells_y = 4096, .cells_per_chunk = 8 };
}

fn gatherAiInline(sys: *SimulationScopeSystem, data: *DataSystem, region: ?ActiveRegion) !AiPopulationGatherResult {
    var threads = try inlineThreads();
    defer threads.deinit();
    try sys.orderThinkPhases(data, region, testThinkGrid(), &threads, .{});
    return sys.gatherAiPopulations(data, region, &threads, .{});
}

fn gatherCollisionInline(sys: *SimulationScopeSystem, data: *const DataSystem) !?[]const u32 {
    var threads = try inlineThreads();
    defer threads.deinit();
    return (try sys.gatherCollisionBoundsIndices(data, &threads, .{})).indices;
}

fn compactCognitionInline(sys: *SimulationScopeSystem, view: *const SpatialIndexView, stagger_step: u8, apply_stagger: bool) !CognitionResult {
    var threads = try inlineThreads();
    defer threads.deinit();
    return sys.compactCognition(view, stagger_step, apply_stagger, &threads, .{});
}

fn queueTierChangesInline(sys: *SimulationScopeSystem, data: *const DataSystem, visible_region: ?ActiveRegion, stream: *RangeOutputStream(StructuralCommand)) !void {
    var threads = try inlineThreads();
    defer threads.deinit();
    _ = try sys.queueTierChanges(data, visible_region, stream, &threads, .{});
}

// `index`'s think set at `stagger_step`, compacted inline.
fn testThinkSet(sys: *SimulationScopeSystem, index: *const SpatialIndexSystem, stagger_step: u8, apply_stagger: bool) ![]const u32 {
    const view = index.view();
    return (try compactCognitionInline(sys, &view, stagger_step, apply_stagger)).cognition;
}

const data_test_support = @import("../data_system/test_support.zig");

test "SimulationScopeSystem AI gather filters halo and stagger" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    // Inside halo, phase 0
    const inside = try data.createEntity();
    try data.setMovementBody(inside, .{});
    try data.setAiAgent(inside, .{});
    try data.setSimulationMetadata(inside, .{
        .tier = .cognition,
        .chunk = .{ .x = 1, .y = 1 },
        .stagger_phase = 0,
    });

    // Outside halo, phase 0
    const outside_ent = try data.createEntity();
    try data.setMovementBody(outside_ent, .{});
    try data.setAiAgent(outside_ent, .{});
    try data.setSimulationMetadata(outside_ent, .{
        .tier = .cognition,
        .chunk = .{ .x = 20, .y = 20 },
        .stagger_phase = 0,
    });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const pops = try gatherAiInline(&sys, &data, region);
    var index = try testHaloIndex(&data, pops.halo);
    defer index.deinit();
    const cognition = try testThinkSet(&sys, &index, 0, true);

    try std.testing.expectEqual(@as(usize, 1), pops.halo.len);
    try std.testing.expectEqual(@as(usize, 1), cognition.len);
    try std.testing.expectEqual(pops.halo[0], cognition[0]);
    // The halo row is the in-halo agent: the out-of-halo one was filtered.
    try std.testing.expect(data.aiAgentSliceConst().entities[pops.halo[0]].eql(inside));
}

test "SimulationScopeSystem AI stagger skips wrong phase" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const e = try data.createEntity();
    try data.setMovementBody(e, .{});
    try data.setAiAgent(e, .{});
    try data.setSimulationMetadata(e, .{
        .tier = .cognition,
        .chunk = .{ .x = 1, .y = 1 },
        .stagger_phase = 0,
    });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const pops = try gatherAiInline(&sys, &data, region);
    var index = try testHaloIndex(&data, pops.halo);
    defer index.deinit();
    const cognition = try testThinkSet(&sys, &index, 1, true);
    try std.testing.expectEqual(@as(usize, 1), pops.halo.len);
    try std.testing.expectEqual(@as(usize, 0), cognition.len);
}

test "SimulationScopeSystem always_active bypasses halo and stagger" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const boss = try data.createEntity();
    try data.setMovementBody(boss, .{});
    try data.setAiAgent(boss, .{});
    try data.setSimulationMetadata(boss, .{
        .tier = .cognition,
        .chunk = .{ .x = 99, .y = 99 },
        .stagger_phase = 3,
        .always_active = true,
    });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const pops = try gatherAiInline(&sys, &data, region);
    var index = try testHaloIndex(&data, pops.halo);
    defer index.deinit();
    const cognition = try testThinkSet(&sys, &index, 0, true);
    try std.testing.expectEqual(@as(usize, 1), pops.halo.len);
    try std.testing.expectEqual(@as(usize, 1), cognition.len);
}

test "AI halo includes off-phase agents; cognition excludes them" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const phase0 = try data.createEntity();
    try data.setMovementBody(phase0, .{});
    try data.setAiAgent(phase0, .{});
    try data.setSimulationMetadata(phase0, .{
        .tier = .cognition,
        .chunk = .{ .x = 1, .y = 1 },
        .stagger_phase = 0,
    });

    const phase1 = try data.createEntity();
    try data.setMovementBody(phase1, .{});
    try data.setAiAgent(phase1, .{});
    try data.setSimulationMetadata(phase1, .{
        .tier = .cognition,
        .chunk = .{ .x = 1, .y = 1 },
        .stagger_phase = 1,
    });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const pops = try gatherAiInline(&sys, &data, region);
    var index = try testHaloIndex(&data, pops.halo);
    defer index.deinit();
    const cognition = try testThinkSet(&sys, &index, 0, true);
    try std.testing.expectEqual(@as(usize, 2), pops.halo.len);
    try std.testing.expectEqual(@as(usize, 1), cognition.len);
    try std.testing.expectEqual(@as(u32, 0), cognition[0]);
}

test "null cognition region keeps halo identical to cognition with no stagger" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const phase0 = try data.createEntity();
    try data.setMovementBody(phase0, .{});
    try data.setAiAgent(phase0, .{});
    try data.setSimulationMetadata(phase0, .{
        .tier = .cognition,
        .chunk = .{ .x = 1, .y = 1 },
        .stagger_phase = 0,
    });

    const phase1 = try data.createEntity();
    try data.setMovementBody(phase1, .{});
    try data.setAiAgent(phase1, .{});
    try data.setSimulationMetadata(phase1, .{
        .tier = .cognition,
        .chunk = .{ .x = 99, .y = 99 },
        .stagger_phase = 1,
    });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const pops = try gatherAiInline(&sys, &data, null);
    var index = try testHaloIndex(&data, pops.halo);
    defer index.deinit();
    const cognition = try testThinkSet(&sys, &index, 0, false);
    try std.testing.expectEqual(@as(usize, 2), pops.halo.len);
    try std.testing.expectEqualSlices(u32, pops.halo, cognition);
}

test "think budget is one stagger slot of an in-halo four-phase set" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    for (0..4) |phase| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{});
        try data.setAiAgent(e, .{});
        try data.setSimulationMetadata(e, .{
            .tier = .cognition,
            .chunk = .{ .x = 0, .y = 0 },
            .stagger_phase = @intCast(phase),
        });
    }

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 });
    const pops = try gatherAiInline(&sys, &data, region);
    var index = try testHaloIndex(&data, pops.halo);
    defer index.deinit();
    const cognition = try testThinkSet(&sys, &index, 2, true);
    try std.testing.expectEqual(@as(usize, 4), pops.halo.len);
    try std.testing.expectEqual(@as(usize, 1), cognition.len);
    try std.testing.expectEqual(@as(u32, 2), cognition[0]);
}

test "tier policy assigns all four LOD tiers by distance band" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    // Visible region covers chunks [0,4)x[0,4); last in-region cell is 3. Each
    // entity is placed one chunk past a band edge (distance = halo + 1) so it lands
    // squarely in the next band, band-relative so it tracks the live halo constants.
    // Each starts at a tier that differs from its band, so each emits one command;
    // creation order == emit order.
    const loco_x = 4 + @as(i32, cognition_halo_chunks); // dist cognition_halo+1 → locomotion
    const kine_x = 4 + @as(i32, locomotion_halo_chunks); // dist locomotion_halo+1 → kinematic
    const dorm_x = 4 + @as(i32, kinematic_halo_chunks); // dist kinematic_halo+1 → dormant
    const to_cog = try makeScoped(&data, .locomotion, .{ .x = 3, .y = 3 }, false); // dist 0 → cognition
    const to_loco = try makeScoped(&data, .cognition, .{ .x = loco_x, .y = 0 }, false);
    const to_kine = try makeScoped(&data, .cognition, .{ .x = kine_x, .y = 0 }, false);
    const to_dorm = try makeScoped(&data, .cognition, .{ .x = dorm_x, .y = 0 }, false);
    _ = try makeScoped(&data, .cognition, .{ .x = 2, .y = 2 }, false); // dist 0, already cognition → no change
    _ = try makeScoped(&data, .cognition, .{ .x = dorm_x, .y = 0 }, true); // always_active far → pinned, skipped

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();

    const visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 });
    try queueTierChangesInline(&sys, &data, visible, &stream);
    const out = stream.mergedItems();

    try std.testing.expectEqual(@as(usize, 4), out.len);
    const expected = [_]struct { e: @TypeOf(to_cog), t: SimulationTier }{
        .{ .e = to_cog, .t = .cognition },
        .{ .e = to_loco, .t = .locomotion },
        .{ .e = to_kine, .t = .kinematic },
        .{ .e = to_dorm, .t = .dormant },
    };
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp.e, out[i].set_simulation_tier.entity);
        try std.testing.expectEqual(exp.t, out[i].set_simulation_tier.tier);
    }
}

test "tier policy demotes off-level entities by the cube distance" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    // Two entities at the same near chunk (distance 0 in xy). The region is anchored
    // at level 0, so the on-level one stays cognition (no command) and the one a
    // couple of levels away is pushed past the cognition band → demoted.
    const on_level = try data.createEntity();
    try data.setMovementBody(on_level, .{});
    try data.setSimulationMetadata(on_level, .{ .tier = .cognition, .chunk = .{ .x = 1, .y = 1 }, .level = 0 });
    const off_level = try data.createEntity();
    try data.setMovementBody(off_level, .{});
    try data.setSimulationMetadata(off_level, .{ .tier = .cognition, .chunk = .{ .x = 1, .y = 1 }, .level = 2 });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();

    var visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 });
    visible.level = 0;
    try queueTierChangesInline(&sys, &data, visible, &stream);
    const out = stream.mergedItems();

    // Only the off-level entity emits a command, and it leaves cognition.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(off_level, out[0].set_simulation_tier.entity);
    try std.testing.expect(out[0].set_simulation_tier.tier != .cognition);
}

test "tier policy is a no-op without a visible region" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const e = try data.createEntity();
    try data.setMovementBody(e, .{});
    try data.setSimulationMetadata(e, .{ .tier = .cognition, .chunk = .{ .x = 99, .y = 99 } });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();

    try queueTierChangesInline(&sys, &data, null, &stream);
    try std.testing.expectEqual(@as(usize, 0), stream.mergedItems().len);
}

test "deriveChunks recomputes every row's chunk from its settled position" {
    const allocator = std.testing.allocator;
    const WorldSystem = @import("../world/system.zig").WorldSystem;

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var data = DataSystem.init(allocator);
    defer data.deinit();
    const a = try data.createEntity();
    try data.setMovementBody(a, .{ .position = .{ .x = 300, .y = 100 } });
    try data.setPrimitiveVisual(a, testDrawableVisual());
    const dormant = try data.createEntity();
    try data.setMovementBody(dormant, .{ .position = .{ .x = 500, .y = 200 } });
    try data.setPrimitiveVisual(dormant, testDrawableVisual());
    try data.setSimulationTier(dormant, .dormant);
    const b = try data.createEntity();
    try data.setMovementBody(b, .{ .position = .{ .x = 700, .y = 260 } });
    try data.setPrimitiveVisual(b, testDrawableVisual());

    const tile_size: f32 = 32;
    const chunk_size: u16 = 8;
    const dims: u16 = 64;

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    _ = try sys.deriveChunks(&data, &threads, .{
        .tile_size = tile_size,
        .chunk_size_tiles = chunk_size,
        .width = dims,
        .height = dims,
    }, .{});

    // Every row's chunk (dormant included) matches the canonical world formula.
    var world = WorldSystem{ .allocator = allocator, .width = dims, .height = dims, .tile_size = tile_size, .chunk_size_tiles = chunk_size };
    defer world.deinit();
    inline for (.{ a, dormant, b }) |ent| {
        const body = data.movementBodyConst(ent).?;
        const meta = data_test_support.simulationMetadata(&data, ent).?;
        const expect = world.chunkCoordForWorldPos(body.position.x, body.position.y);
        try std.testing.expectEqual(expect.x, meta.chunk.x);
        try std.testing.expectEqual(expect.y, meta.chunk.y);
    }
    const movement = data.movementBodySliceConst();
    for (0..movement.entities.len) |index| try expectDrawableAtSettledChunk(&data, index);
}

test "threaded deriveChunks matches serial across the range block and tail" {
    const allocator = std.testing.allocator;

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = scope_range_alignment_items });
    defer threads.deinit();

    const grid = SimulationScopeSystem.ChunkGrid{ .tile_size = 32, .chunk_size_tiles = 8, .width = 256, .height = 256 };
    const count = scope_range_alignment_items * 8 + 3; // multi-range block + scalar tail

    var threaded_data = DataSystem.init(allocator);
    defer threaded_data.deinit();
    var serial_data = DataSystem.init(allocator);
    defer serial_data.deinit();
    for (0..count) |i| {
        const fi: f32 = @floatFromInt(i);
        const te = try threaded_data.createEntity();
        try threaded_data.setMovementBody(te, .{ .position = .{ .x = fi * 3.5, .y = fi * 1.25 } });
        try threaded_data.setPrimitiveVisual(te, testDrawableVisual());
        const se = try serial_data.createEntity();
        try serial_data.setMovementBody(se, .{ .position = .{ .x = fi * 3.5, .y = fi * 1.25 } });
        try serial_data.setPrimitiveVisual(se, testDrawableVisual());
    }

    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();
    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();

    _ = try threaded_sys.deriveChunks(&threaded_data, &threads, grid, .{
        .items_per_range = scope_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    var inline_threads = try inlineThreads();
    defer inline_threads.deinit();
    _ = try serial_sys.deriveChunks(&serial_data, &inline_threads, grid, .{});

    const ts = threaded_data.scopeColumnsSliceConst();
    const ss = serial_data.scopeColumnsSliceConst();
    for (0..count) |i| {
        try std.testing.expectEqual(ss.chunk_x[i], ts.chunk_x[i]);
        try std.testing.expectEqual(ss.chunk_y[i], ts.chunk_y[i]);
        try expectDrawableAtSettledChunk(&threaded_data, i);
        try expectDrawableAtSettledChunk(&serial_data, i);
    }
}

fn testDrawableVisual() PrimitiveVisual {
    return .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

fn expectDrawableAtSettledChunk(data: *DataSystem, index: usize) !void {
    const movement = data.movementBodySliceConst();
    const scope = data.scopeColumnsSliceConst();
    const run_index = data.movement_bodies.drawableRunIndex(scope.level[index], scope.chunk_x[index], scope.chunk_y[index]);
    try std.testing.expect(run_index != null);
    const run = data.movement_bodies.drawableRunSlice(run_index.?);
    var found = false;
    for (run.entity, run.movement_index) |entity, movement_index| {
        if (movement_index != index) continue;
        try std.testing.expect(entity.eql(movement.entities[index]));
        found = true;
    }
    try std.testing.expect(found);
}

test "deriveChunks restores chunk columns when the second relocate runs out of memory" {
    const allocator = std.testing.allocator;
    const grid = SimulationScopeSystem.ChunkGrid{ .tile_size = 32, .chunk_size_tiles = 8, .width = 64, .height = 64 };

    var counted = try visualChunkMovers(allocator);
    defer counted.data.deinit();
    var count_threads = try inlineThreads();
    defer count_threads.deinit();
    var count_sys = SimulationScopeSystem.init(allocator);
    defer count_sys.deinit();
    try count_sys.reserve(2);
    var counter = std.testing.FailingAllocator.init(allocator, .{});
    counted.data.allocator = counter.allocator();
    _ = try count_sys.deriveChunks(&counted.data, &count_threads, grid, .{});
    counted.data.allocator = allocator;
    const total = counter.allocations;
    try std.testing.expect(total >= 2);

    var data = try visualChunkMovers(allocator);
    defer data.data.deinit();
    var threads = try inlineThreads();
    defer threads.deinit();
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    try sys.reserve(2);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = total - 1 });
    data.data.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, sys.deriveChunks(&data.data, &threads, grid, .{}));
    data.data.allocator = allocator;

    const scope = data.data.scopeColumnsSliceConst();
    try std.testing.expectEqual(@as(i32, 0), scope.chunk_x[0]);
    try std.testing.expectEqual(@as(i32, 0), scope.chunk_y[0]);
    try std.testing.expectEqual(@as(i32, 0), scope.chunk_x[1]);
    try std.testing.expectEqual(@as(i32, 0), scope.chunk_y[1]);
    try expectRunHolds(&data.data, 0, 0, 0, data.a);
    try expectRunHolds(&data.data, 0, 0, 0, data.b);
    try std.testing.expect(data.data.movement_bodies.drawableRunIndex(0, 1, 0) == null);
    try std.testing.expect(data.data.movement_bodies.drawableRunIndex(0, 2, 0) == null);

    _ = try sys.deriveChunks(&data.data, &threads, grid, .{});
    try expectDrawableAtSettledChunk(&data.data, 0);
    try expectDrawableAtSettledChunk(&data.data, 1);
    try std.testing.expect(data.data.movement_bodies.drawableRunIndex(0, 0, 0) == null);
}

const VisualChunkMover = struct {
    data: DataSystem,
    a: EntityId,
    b: EntityId,
};

fn visualChunkMovers(allocator: std.mem.Allocator) !VisualChunkMover {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const a = try data.createEntity();
    const b = try data.createEntity();
    try data.setMovementBody(a, .{ .position = .{ .x = 8, .y = 8 } });
    try data.setMovementBody(b, .{ .position = .{ .x = 8, .y = 8 } });
    try data.setPrimitiveVisual(a, testDrawableVisual());
    try data.setPrimitiveVisual(b, testDrawableVisual());
    data.movementBodyPtr(a).?.position_x.* = 300;
    data.movementBodyPtr(b).?.position_x.* = 600;
    return .{ .data = data, .a = a, .b = b };
}

fn expectRunHolds(data: *DataSystem, level: u16, chunk_x: i32, chunk_y: i32, entity: EntityId) !void {
    const run_index = data.movement_bodies.drawableRunIndex(level, chunk_x, chunk_y);
    try std.testing.expect(run_index != null);
    const run = data.movement_bodies.drawableRunSlice(run_index.?);
    var found = false;
    for (run.entity) |row_entity| if (row_entity.eql(entity)) {
        found = true;
    };
    try std.testing.expect(found);
}

test "threaded deriveChunks records one sample into its own tuner" {
    const allocator = std.testing.allocator;

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var data = DataSystem.init(allocator);
    defer data.deinit();
    const count = scope_range_alignment_items * 8;
    for (0..count) |i| {
        const fi: f32 = @floatFromInt(i);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = fi * 3.5, .y = fi * 1.25 } });
    }

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const stats = try sys.deriveChunks(&data, &threads, .{ .tile_size = 32, .chunk_size_tiles = 8, .width = 256, .height = 256 }, .{});
    try std.testing.expectEqual(count, stats.item_count);
    try std.testing.expectEqual(@as(usize, 1), sys.chunk_derive_tuner.sample_count);
    try std.testing.expect(sys.chunk_derive_tuner.last_request != null);
}

test "scoped collision excludes kinematic and dormant bodies from contacts" {
    const allocator = std.testing.allocator;
    const collision = @import("collision.zig");
    const CollisionContact = @import("../simulation.zig").CollisionContact;

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Three overlapping bodies at the same spot; the kinematic one must not
    // appear in any contact once scoped out.
    const positions = [_]f32{ 100, 104, 108 };
    var ents: [3]EntityId = undefined;
    for (positions, 0..) |px, i| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{ .position = .{ .x = px, .y = 100 } });
        try data.setCollisionBounds(e, .{ .size = .{ .x = 16, .y = 16 } });
        try data.setCollisionResponse(e, .{});
        ents[i] = e;
    }
    const kinematic_ent = ents[1];
    try data.setSimulationTier(kinematic_ent, .kinematic);

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const indices = try gatherCollisionInline(&sys, &data);
    try std.testing.expect(indices != null); // a kinematic entity is present
    try std.testing.expectEqual(@as(usize, 2), indices.?.len);

    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();
    var cs = collision.CollisionSystem.init(allocator);
    defer cs.deinit();
    _ = try cs.update(&data, &contacts, &threads, .{ .scope_dense_indices = indices });

    for (contacts.mergedItems()) |contact| {
        try std.testing.expect(contact.a.index != kinematic_ent.index);
        try std.testing.expect(contact.b.index != kinematic_ent.index);
    }
}

test "collision gather skips a locomotion static and keeps a locomotion dynamic" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const kinematic = try data.createEntity();
    try data.setMovementBody(kinematic, .{ .position = .{ .x = 1, .y = 1 } });
    try data.setCollisionBounds(kinematic, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(kinematic, .{});
    try data.setSimulationTier(kinematic, .kinematic);

    const static_body = try data.createEntity();
    try data.setMovementBody(static_body, .{ .position = .{ .x = 40, .y = 40 } });
    try data.setCollisionBounds(static_body, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(static_body, .{ .mobility = .static });

    const dynamic = try data.createEntity();
    try data.setMovementBody(dynamic, .{ .position = .{ .x = 80, .y = 80 } });
    try data.setCollisionBounds(dynamic, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(dynamic, .{});

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const indices = try gatherCollisionInline(&sys, &data);
    const list = indices orelse return error.ExpectedScopedGather;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    const dynamic_bounds = data.resolveSlotConst(dynamic).?.collision_bounds_index.?;
    try std.testing.expectEqual(dynamic_bounds, list[0]);
    const static_bounds = data.resolveSlotConst(static_body).?.collision_bounds_index.?;
    try std.testing.expect(list[0] != static_bounds);

    var plain = DataSystem.init(allocator);
    defer plain.deinit();
    for (0..2) |_| {
        const body = try plain.createEntity();
        try plain.setMovementBody(body, .{});
        try plain.setCollisionBounds(body, .{ .size = .{ .x = 8, .y = 8 } });
    }
    try std.testing.expect(try gatherCollisionInline(&sys, &plain) == null);
    try std.testing.expectEqual(plain.collision_bounds.len(), plain.collision_bounds.dynamic_ids.items.len);
}

/// Test helper: a live entity with a movement body and the given scope metadata.
fn makeScoped(data: *DataSystem, tier: SimulationTier, chunk: anytype, always_active: bool) !EntityId {
    const e = try data.createEntity();
    try data.setMovementBody(e, .{});
    try data.setSimulationMetadata(e, .{
        .tier = tier,
        .chunk = .{ .x = chunk.x, .y = chunk.y },
        .always_active = always_active,
    });
    return e;
}

test "scoped AI emits navigation intents only for in-halo, on-phase agents" {
    const allocator = std.testing.allocator;
    const ai = @import("ai.zig");
    const SimulationFrame = @import("../simulation.zig").SimulationFrame;

    var data = DataSystem.init(allocator);
    defer data.deinit();

    // Three cognition agents: one selected, two filtered out for different reasons.
    const selected = try data.createEntity();
    try data.setMovementBody(selected, .{ .position = .{ .x = 100, .y = 100 }, .speed = 40 });
    try data.setAiAgent(selected, .{ .active_behavior = .wander });
    try data.setSimulationMetadata(selected, .{ .tier = .cognition, .chunk = .{ .x = 1, .y = 1 }, .stagger_phase = 0 });

    const out_of_halo = try data.createEntity();
    try data.setMovementBody(out_of_halo, .{ .position = .{ .x = 200, .y = 100 }, .speed = 40 });
    try data.setAiAgent(out_of_halo, .{ .active_behavior = .wander });
    try data.setSimulationMetadata(out_of_halo, .{ .tier = .cognition, .chunk = .{ .x = 30, .y = 30 }, .stagger_phase = 0 });

    const wrong_phase = try data.createEntity();
    try data.setMovementBody(wrong_phase, .{ .position = .{ .x = 120, .y = 120 }, .speed = 40 });
    try data.setAiAgent(wrong_phase, .{ .active_behavior = .wander });
    try data.setSimulationMetadata(wrong_phase, .{ .tier = .cognition, .chunk = .{ .x = 1, .y = 1 }, .stagger_phase = 1 });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const pops = try gatherAiInline(&sys, &data, region);
    var spatial_sys = try testHaloIndex(&data, pops.halo);
    defer spatial_sys.deinit();
    const cognition = try testThinkSet(&sys, &spatial_sys, sys.staggerStep(), true);

    // Halo keeps the in-halo off-phase agent; cognition is the on-phase subset.
    try std.testing.expectEqual(@as(usize, 2), pops.halo.len);
    try std.testing.expectEqual(@as(usize, 1), cognition.len);
    const ai_entities = data.aiAgentSliceConst().entities;
    for (pops.halo) |row| try std.testing.expect(!ai_entities[row].eql(out_of_halo));
    try std.testing.expect(ai_entities[cognition[0]].eql(selected));

    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    frame.beginStep();

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();

    var ai_sys = ai.AiSystem.init(allocator);
    defer ai_sys.deinit();
    var threads = try inlineThreads();
    defer threads.deinit();
    _ = try ai_sys.update(ai_slice, movement_slice, spatial_sys.view(), &data, &frame, &threads, 0.016, .{
        .scope_dense_indices = cognition,
    });

    // Exactly one navigation intent, for the selected agent — steering downstream
    // inherits this scoping with no separate gather.
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(selected.index, intents[0].entity.index);
}

test "queueTierChanges appends its range alongside another structural producer" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // One far cognition entity → the policy emits one tier command (sleeps to dormant).
    // Placed past the kinematic halo (band-relative) so it lands in the dormant band.
    const far: i32 = 5 + @as(i32, kinematic_halo_chunks);
    const demoted = try makeScoped(&data, .cognition, .{ .x = far, .y = far }, false);
    // One always_active entity used only as a marker for a prior producer's range.
    const marker = try makeScoped(&data, .cognition, .{ .x = 1, .y = 1 }, true);

    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();

    // Prior producer claims a range first (exclusive prepare path, as the state's
    // own producers use), then the scope system appends its range to coexist.
    try stream.prepareRangeCounts(1);
    stream.addCount(0, 1);
    try stream.prefix();
    var writer = stream.rangeWriter(0);
    writer.write(.{ .destroy_entity = marker });
    writer.finish();
    stream.finishWrite();

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    try queueTierChangesInline(&sys, &data, region, &stream);

    // Both producers' commands survive in the merged stream.
    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(marker.index, merged[0].destroy_entity.index);
    try std.testing.expectEqual(demoted.index, merged[1].set_simulation_tier.entity.index);
    try std.testing.expectEqual(SimulationTier.dormant, merged[1].set_simulation_tier.tier);
}

test "queueTierChanges writes its range as the sole producer on a fresh stream" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Far cognition entity sleeps to dormant; near one stays cognition (no command).
    const far: i32 = 4 + @as(i32, kinematic_halo_chunks);
    const sleeper = try makeScoped(&data, .cognition, .{ .x = far, .y = far }, false);
    _ = try makeScoped(&data, .cognition, .{ .x = 1, .y = 1 }, false);

    // Fresh stream, no prior producer — exercises the prefix_ready=false fallback
    // path that the live pipeline actually hits (queueTierChanges runs first).
    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 });
    try queueTierChangesInline(&sys, &data, visible, &stream);

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqual(sleeper.index, merged[0].set_simulation_tier.entity.index);
    try std.testing.expectEqual(SimulationTier.dormant, merged[0].set_simulation_tier.tier);

    // Idempotent: applying the command then re-running yields no new command.
    try data.setSimulationTier(sleeper, .dormant);
    var stream2 = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream2.deinit();
    try queueTierChangesInline(&sys, &data, visible, &stream2);
    try std.testing.expectEqual(@as(usize, 0), stream2.mergedItems().len);
}

// ---- Threaded == serial parity ----------------------------------------------

/// Builds a mixed-tier population spread over x-chunks and levels for the parity
/// checks: a dormant/kinematic mix so the gathers actually scan, and off-level
/// entities so the cube tier policy produces real demotions.
fn fillParityPopulation(data: *DataSystem, count: usize) !void {
    for (0..count) |index| {
        const e = try data.createEntity();
        const chunk_x: i32 = @intCast(index % 20);
        try data.setMovementBody(e, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setCollisionBounds(e, .{ .size = .{ .x = 8, .y = 8 } });
        try data.setAiAgent(e, .{ .active_behavior = if (index % 2 == 0) .pursue else .wander });
        // Levels 0–4 fan the cube distance across all four tiers (level 4 reaches the
        // dormant band), so the movement/collision gathers leave the full-active fast
        // path and actually scan, and the AI gather/tier policy see real work.
        const level: u16 = @intCast(index % 5);
        const region = ActiveRegion{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 2, .y = 8 }, .level = 0 };
        const tier = tierForChunkDistance(region.lodDistance(.{ .x = chunk_x, .y = 0 }, level));
        try data.setSimulationMetadata(e, .{ .tier = tier, .chunk = .{ .x = chunk_x, .y = 0 }, .level = level, .stagger_phase = @intCast(index % cognition_stagger_n) });
    }
}

test "threaded ai gather and think set match serial" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillParityPopulation(&data, scope_range_alignment_items * 6);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    const fixed = ScopeConfig{ .items_per_range = scope_range_alignment_items, .max_worker_threads = 2, .adaptive = false };

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const serial = try gatherAiInline(&serial_sys, &data, region);
    try threaded_sys.orderThinkPhases(&data, region, testThinkGrid(), &threads, fixed);
    const threaded = try threaded_sys.gatherAiPopulations(&data, region, &threads, fixed);
    try std.testing.expectEqualSlices(u32, serial.halo, threaded.halo);

    var index = try testHaloIndex(&data, serial.halo);
    defer index.deinit();
    const view = index.view();
    const serial_think = try compactCognitionInline(&serial_sys, &view, 0, true);
    const threaded_think = try threaded_sys.compactCognition(&view, 0, true, &threads, fixed);
    try std.testing.expect(serial_think.cognition.len > 0);
    try std.testing.expectEqualSlices(u32, serial_think.cognition, threaded_think.cognition);
}

test "threaded tier policy matches serial" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // All entities start cognition so the cube policy emits a command for every
    // entity that should sit in a farther band — a dense, non-trivial output.
    for (0..scope_range_alignment_items * 6) |index| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{});
        const level: u16 = if (index % 6 == 0) 2 else 0;
        try data.setSimulationMetadata(e, .{ .tier = .cognition, .chunk = .{ .x = @intCast(index % 20), .y = 0 }, .level = level });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    visible.level = 0;

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var serial_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer serial_stream.deinit();
    try queueTierChangesInline(&serial_sys, &data, visible, &serial_stream);

    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();
    var threaded_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer threaded_stream.deinit();
    _ = try threaded_sys.queueTierChanges(&data, visible, &threaded_stream, &threads, .{ .items_per_range = scope_range_alignment_items, .max_worker_threads = 2, .adaptive = false });

    const serial = serial_stream.mergedItems();
    const threaded = threaded_stream.mergedItems();
    try std.testing.expect(serial.len > 0);
    try std.testing.expectEqual(serial.len, threaded.len);
    for (serial, threaded) |s, t| {
        try std.testing.expectEqual(s.set_simulation_tier.entity.index, t.set_simulation_tier.entity.index);
        try std.testing.expectEqual(s.set_simulation_tier.tier, t.set_simulation_tier.tier);
    }
}

test "real worker threads match serial across every scope pass" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Rotate the starting tier across all four values: a dormant/kinematic mix so
    // the movement/collision gathers leave the fast path and fan ranges across
    // workers, while the rotation rarely equals the cube-correct tier so the policy
    // emits a dense command stream too.
    for (0..scope_range_alignment_items * 8) |index| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setCollisionBounds(e, .{ .size = .{ .x = 8, .y = 8 } });
        try data.setAiAgent(e, .{ .active_behavior = if (index % 2 == 0) .pursue else .wander });
        try data.setSimulationMetadata(e, .{ .tier = @fromBackingInt(@intCast(index % 4)), .chunk = .{ .x = @intCast(index % 20), .y = 0 }, .level = @intCast(index % 5), .stagger_phase = @intCast(index % cognition_stagger_n) });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = scope_range_alignment_items });
    defer threads.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    const fixed = ScopeConfig{ .items_per_range = scope_range_alignment_items, .max_worker_threads = 2, .adaptive = false };

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    // Collision gather.
    const col_serial = (try gatherCollisionInline(&serial_sys, &data)).?;
    const col_threaded = (try threaded_sys.gatherCollisionBoundsIndices(&data, &threads, fixed)).indices.?;
    try std.testing.expectEqualSlices(u32, col_serial, col_threaded);

    // AI gather, then the think set over its index.
    const ai_serial = try gatherAiInline(&serial_sys, &data, region);
    try threaded_sys.orderThinkPhases(&data, region, testThinkGrid(), &threads, fixed);
    const ai_threaded = try threaded_sys.gatherAiPopulations(&data, region, &threads, fixed);
    try std.testing.expectEqualSlices(u32, ai_serial.halo, ai_threaded.halo);
    var index = try testHaloIndex(&data, ai_serial.halo);
    defer index.deinit();
    const view = index.view();
    const think_serial = try compactCognitionInline(&serial_sys, &view, 0, true);
    const think_threaded = try threaded_sys.compactCognition(&view, 0, true, &threads, fixed);
    try std.testing.expectEqualSlices(u32, think_serial.cognition, think_threaded.cognition);

    // Tier policy (variable-output producer, dense output).
    var visible = region;
    visible.level = 0;
    var serial_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer serial_stream.deinit();
    try queueTierChangesInline(&serial_sys, &data, visible, &serial_stream);
    var threaded_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer threaded_stream.deinit();
    _ = try threaded_sys.queueTierChanges(&data, visible, &threaded_stream, &threads, fixed);
    const tier_serial = serial_stream.mergedItems();
    const tier_threaded = threaded_stream.mergedItems();
    try std.testing.expect(tier_serial.len > 0);
    try std.testing.expectEqual(tier_serial.len, tier_threaded.len);
    for (tier_serial, tier_threaded) |s, t| {
        try std.testing.expectEqual(s.set_simulation_tier.entity.index, t.set_simulation_tier.entity.index);
        try std.testing.expectEqual(s.set_simulation_tier.tier, t.set_simulation_tier.tier);
    }
}

test "warmed scope threaded gathers and tier policy do not allocate (FailingAllocator)" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Rotating starting tiers (not cube-correct for the region below) so every
    // gather leaves its full-active fast path and the tier policy actually emits
    // commands, exercising the per-range scratch buffers, the merged index lists,
    // and the structural-command stream. Mirrors the population this file's
    // "real worker threads match serial across every scope pass" test uses.
    const population = scope_range_alignment_items * 2;
    for (0..population) |index| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setCollisionBounds(e, .{ .size = .{ .x = 8, .y = 8 } });
        try data.setAiAgent(e, .{ .active_behavior = if (index % 2 == 0) .pursue else .wander });
        try data.setSimulationMetadata(e, .{
            .tier = @fromBackingInt(@intCast(index % 4)),
            .chunk = .{ .x = @intCast(index % 20), .y = 0 },
            .level = @intCast(index % 5),
            // Fixed at 0 (not `index % cognition_stagger_n`): that modulus shares a
            // factor with the tier rotation above, so every cognition-tier entity
            // would land on the same non-zero stagger phase and the AI gather would
            // always come back empty. A constant phase keeps the halo/tier filtering
            // real while guaranteeing some cognition agents match stagger_step 0.
            .stagger_phase = 0,
        });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();

    const ai_region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    var visible_region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    visible_region.level = 0;

    // Warm-up pass with the real allocator: sizes the per-range gather/command
    // scratch, the merged index lists, and the structural-command stream to this
    // step's shape (data does not change afterward, so re-running is identical).
    const warm_collision = try sys.gatherCollisionBoundsIndices(&data, &threads, .{});
    try std.testing.expect(warm_collision.indices != null);
    try sys.orderThinkPhases(&data, ai_region, testThinkGrid(), &threads, .{});
    const warm_ai = try sys.gatherAiPopulations(&data, ai_region, &threads, .{});
    try std.testing.expect(warm_ai.halo.len > 0);
    var index = try testHaloIndex(&data, warm_ai.halo);
    defer index.deinit();
    const view = index.view();
    var warm_think: std.ArrayList(u32) = .empty;
    defer warm_think.deinit(allocator);
    try warm_think.appendSlice(allocator, (try sys.compactCognition(&view, 0, true, &threads, .{})).cognition);
    try std.testing.expect(warm_think.items.len > 0);
    _ = try sys.queueTierChanges(&data, visible_region, &stream, &threads, .{});
    try std.testing.expect(stream.mergedItems().len > 0);

    // Reset the stream's write state (retains capacity) so the failing-allocator
    // pass re-appends its range the same way queueTierChanges does every step.
    stream.clearRetainingCapacity();

    const original_sys_allocator = sys.allocator;
    const original_thread_allocator = threads.allocator;
    const original_stream_allocator = stream.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    sys.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    stream.allocator = failing_allocator.allocator();
    defer {
        sys.allocator = original_sys_allocator;
        threads.allocator = original_thread_allocator;
        stream.allocator = original_stream_allocator;
    }

    const collision = try sys.gatherCollisionBoundsIndices(&data, &threads, .{});
    try std.testing.expectEqualSlices(u32, warm_collision.indices.?, collision.indices.?);
    const ai_result = try sys.gatherAiPopulations(&data, ai_region, &threads, .{});
    try std.testing.expectEqualSlices(u32, warm_ai.halo, ai_result.halo);
    try std.testing.expectEqualSlices(u32, warm_think.items, (try sys.compactCognition(&view, 0, true, &threads, .{})).cognition);
    _ = try sys.queueTierChanges(&data, visible_region, &stream, &threads, .{});
    try std.testing.expect(stream.mergedItems().len > 0);
}

test "after reserve, threaded gathers and tier policy at 32- then 16-item ranges allocate nothing and match serial" {
    // `reserve` alone (no warm pass) covers every partition the tuner can
    // pick, because each pass writes per-range windows of one item-count buffer and the
    // tallies are reserved to maxRangeCount. A retune to more ranges allocates nothing.
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Rotating starting tiers (as in the real-worker parity test) so every gather leaves
    // its full-active fast path and the tier policy emits a dense command stream. Not a
    // range multiple, so the last range is a short tail.
    const population = scope_range_alignment_items * 8 + 3;
    for (0..population) |index| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setCollisionBounds(e, .{ .size = .{ .x = 8, .y = 8 } });
        try data.setAiAgent(e, .{ .active_behavior = if (index % 2 == 0) .pursue else .wander });
        try data.setSimulationMetadata(e, .{ .tier = @fromBackingInt(@intCast(index % 4)), .chunk = .{ .x = @intCast(index % 20), .y = 0 }, .level = @intCast(index % 5), .stagger_phase = 0 });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    const ai_region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    var visible_region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    visible_region.level = 0;

    // Inline reference.
    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    const col_serial = (try gatherCollisionInline(&serial_sys, &data)).?;
    const ai_serial = try gatherAiInline(&serial_sys, &data, ai_region);
    var index = try testHaloIndex(&data, ai_serial.halo);
    defer index.deinit();
    const view = index.view();
    const think_serial = try compactCognitionInline(&serial_sys, &view, 0, true);
    var serial_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer serial_stream.deinit();
    try queueTierChangesInline(&serial_sys, &data, visible_region, &serial_stream);
    const tier_serial = serial_stream.mergedItems();
    try std.testing.expect(tier_serial.len > 0);

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    try sys.reserve(population);
    try sys.orderThinkPhases(&data, ai_region, testThinkGrid(), &threads, .{});
    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();
    try stream.reserve(maxRangeCount(population, scope_range_alignment_items), population);

    const original_sys_allocator = sys.allocator;
    const original_thread_allocator = threads.allocator;
    const original_stream_allocator = stream.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    sys.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    stream.allocator = failing_allocator.allocator();
    defer {
        sys.allocator = original_sys_allocator;
        threads.allocator = original_thread_allocator;
        stream.allocator = original_stream_allocator;
    }

    for ([_]usize{ 32, 16 }) |items_per_range| {
        const config = ScopeConfig{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false };
        const collision = try sys.gatherCollisionBoundsIndices(&data, &threads, config);
        try std.testing.expectEqualSlices(u32, col_serial, collision.indices.?);

        const ai_result = try sys.gatherAiPopulations(&data, ai_region, &threads, config);
        try std.testing.expectEqualSlices(u32, ai_serial.halo, ai_result.halo);
        try std.testing.expectEqualSlices(u32, think_serial.cognition, (try sys.compactCognition(&view, 0, true, &threads, config)).cognition);

        stream.clearRetainingCapacity();
        _ = try sys.queueTierChanges(&data, visible_region, &stream, &threads, config);
        const tier_threaded = stream.mergedItems();
        try std.testing.expectEqual(tier_serial.len, tier_threaded.len);
        for (tier_serial, tier_threaded) |want, got| {
            try std.testing.expectEqual(want.set_simulation_tier.entity.index, got.set_simulation_tier.entity.index);
            try std.testing.expectEqual(want.set_simulation_tier.tier, got.set_simulation_tier.tier);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "scope reserve makes the first single-range threaded gathers and tier policy allocation-free" {
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Same rotating-tier shape as the warmed proof above, so every pass leaves its
    // full-active fast path, at a population that is not a range multiple.
    const population: usize = 40;
    for (0..population) |index| {
        const e = try data.createEntity();
        try data.setMovementBody(e, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setCollisionBounds(e, .{ .size = .{ .x = 8, .y = 8 } });
        try data.setAiAgent(e, .{ .active_behavior = .wander });
        try data.setSimulationMetadata(e, .{
            .tier = @fromBackingInt(@intCast(index % 4)),
            .chunk = .{ .x = @intCast(index % 20), .y = 0 },
            .level = @intCast(index % 5),
            .stagger_phase = 0,
        });
    }

    // 0 workers: the whole population runs as one inline range (slot 0).
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    try sys.reserve(population);
    var stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream.deinit();
    try stream.reserve(1, population);

    const ai_region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    var visible_region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    visible_region.level = 0;
    // The index of the halo the gather below produces, built before the failing allocator.
    var reference_sys = SimulationScopeSystem.init(allocator);
    defer reference_sys.deinit();
    var index = try testHaloIndex(&data, (try gatherAiInline(&reference_sys, &data, ai_region)).halo);
    try sys.orderThinkPhases(&data, ai_region, testThinkGrid(), &threads, .{});
    defer index.deinit();
    const view = index.view();

    const original_sys_allocator = sys.allocator;
    const original_thread_allocator = threads.allocator;
    const original_stream_allocator = stream.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    sys.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    stream.allocator = failing_allocator.allocator();
    defer {
        sys.allocator = original_sys_allocator;
        threads.allocator = original_thread_allocator;
        stream.allocator = original_stream_allocator;
    }

    const collision = try sys.gatherCollisionBoundsIndices(&data, &threads, .{});
    try std.testing.expect(collision.indices != null);
    const ai_result = try sys.gatherAiPopulations(&data, ai_region, &threads, .{});
    try std.testing.expect(ai_result.halo.len > 0);
    try std.testing.expect((try sys.compactCognition(&view, 0, true, &threads, .{})).cognition.len > 0);
    _ = try sys.queueTierChanges(&data, visible_region, &stream, &threads, .{});
    try std.testing.expect(stream.mergedItems().len > 0);
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

const FactionSet = @import("../faction.zig").FactionSet;

// `count` cognition-tier AI agents over 3 x 2 chunks of the test grid on two levels, of every
// faction, at every stagger phase, some `always_active`.
fn fillCognitionPopulation(data: *DataSystem, count: usize) !void {
    const chunk_world: f32 = 512;
    var prng = std.Random.DefaultPrng.init(0xc0_9417);
    const random = prng.random();
    for (0..count) |index| {
        const e = try data.createEntity();
        const position = math.Vec2{ .x = random.float(f32) * 3 * chunk_world, .y = random.float(f32) * 2 * chunk_world };
        try data.setMovementBody(e, .{ .position = position, .previous_position = position });
        try data.setAiAgent(e, .{ .active_behavior = .wander });
        try data.setFaction(e, @fromBackingInt(@intCast(index % 4)));
        try data.setWorldLevel(e, @intCast(index / 3 % 2));
        try data.setSimulationMetadata(e, .{ .tier = .cognition, .stagger_phase = @intCast(index % cognition_stagger_n), .always_active = index % 13 == 0 });
    }
}

// `count` cognition-tier AI agents in one chunk of the test grid on one level, of every
// faction, at every stagger phase, some `always_active`.
fn fillDenseCognitionPopulation(data: *DataSystem, count: usize) !void {
    const chunk_world: f32 = 512;
    var prng = std.Random.DefaultPrng.init(0xd3_95e1);
    const random = prng.random();
    for (0..count) |index| {
        const e = try data.createEntity();
        const position = math.Vec2{ .x = random.float(f32) * chunk_world, .y = random.float(f32) * chunk_world };
        try data.setMovementBody(e, .{ .position = position, .previous_position = position });
        try data.setAiAgent(e, .{ .active_behavior = .wander });
        try data.setFaction(e, @fromBackingInt(@intCast(index % 4)));
        try data.setSimulationMetadata(e, .{ .tier = .cognition, .stagger_phase = @intCast(index % cognition_stagger_n), .always_active = index % 13 == 0 });
    }
}

// One halo row's place in the index's order, read from `data`: (level, chunk_y, chunk_x,
// local_y, local_x, faction, slot).
const CellMajorRow = struct {
    key: [7]u32,
    ai_index: u32,
    thinks: bool,

    fn lessThan(_: void, lhs: CellMajorRow, rhs: CellMajorRow) bool {
        return std.mem.order(u32, &lhs.key, &rhs.key) == .lt;
    }
};

// `halo`'s think set at `stagger_step` by brute force over `data`, in the index's order.
fn bruteForceThinkSet(data: *const DataSystem, view: SpatialIndexView, halo: []const u32, stagger_step: u8, apply_stagger: bool, out: *std.ArrayList(u32)) !void {
    var rows: std.ArrayList(CellMajorRow) = .empty;
    defer rows.deinit(std.testing.allocator);
    const entities = data.aiAgentSliceConst().entities;
    const movement = data.movementBodySliceConst();
    const scope = data.scopeColumnsSliceConst();
    for (halo, 0..) |ai_index, slot| {
        const entity = entities[ai_index];
        const body = data.movementBodyDenseIndex(entity).?;
        const cell_x = math.worldPosToCell(movement.previous_x[body], view.cell_size, view.cells_x);
        const cell_y = math.worldPosToCell(movement.previous_y[body], view.cell_size, view.cells_y);
        const per_chunk = view.cells_per_chunk;
        const faction: u32 = @intCast(FactionSet.Indexer.indexOf(data.factionConst(entity) orelse .neutral));
        try rows.append(std.testing.allocator, .{
            .key = .{ data.worldLevelConst(entity) orelse 0, cell_y / per_chunk, cell_x / per_chunk, cell_y % per_chunk, cell_x % per_chunk, faction, @intCast(slot) },
            .ai_index = ai_index,
            .thinks = !apply_stagger or scope.always_active[body] or scope.stagger_phase[body] == stagger_step,
        });
    }
    std.sort.pdq(CellMajorRow, rows.items, {}, CellMajorRow.lessThan);
    out.clearRetainingCapacity();
    for (rows.items) |row| if (row.thinks) try out.append(std.testing.allocator, row.ai_index);
}

test "the think set is the halo's phase set in the index's cell-major order, serial and threaded" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillCognitionPopulation(&data, 600);

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    // Every other agent: a halo out of creation order's density.
    const halo_all = (try gatherAiInline(&serial_sys, &data, null)).halo;
    var halo: std.ArrayList(u32) = .empty;
    defer halo.deinit(allocator);
    for (halo_all, 0..) |row, k| if (k % 2 == 0) try halo.append(allocator, row);
    var index = try testHaloIndex(&data, halo.items);
    defer index.deinit();
    const view = index.view();
    try std.testing.expect(view.recordCount() >= 4);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 4 });
    defer threads.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(allocator);
    for ([_]bool{ true, false }) |apply_stagger| {
        for (0..cognition_stagger_n) |step| {
            const stagger_step: u8 = @intCast(step);
            try bruteForceThinkSet(&data, view, halo.items, stagger_step, apply_stagger, &expected);
            try std.testing.expect(expected.items.len > 0);
            const serial = try compactCognitionInline(&serial_sys, &view, stagger_step, apply_stagger);
            try std.testing.expectEqualSlices(u32, expected.items, serial.cognition);
            if (!apply_stagger) try std.testing.expectEqual(halo.items.len, serial.cognition.len);
            for (1..5) |workers| {
                for ([_]usize{ 16, 48, 256 }) |items_per_range| {
                    const threaded = try threaded_sys.compactCognition(&view, stagger_step, apply_stagger, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = workers, .adaptive = false });
                    try std.testing.expectEqualSlices(u32, expected.items, threaded.cognition);
                }
            }
        }
    }
}

test "a one-chunk crowd's think set splits across ranges and workers, equal to the halo's phase set" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillDenseCognitionPopulation(&data, 700);
    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    const halo = (try gatherAiInline(&serial_sys, &data, null)).halo;
    var index = try testHaloIndex(&data, halo);
    defer index.deinit();
    const view = index.view();
    try std.testing.expectEqual(@as(usize, 1), view.recordCount());

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 4 });
    defer threads.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(allocator);
    for ([_]bool{ true, false }) |apply_stagger| {
        for (0..cognition_stagger_n) |step| {
            const stagger_step: u8 = @intCast(step);
            try bruteForceThinkSet(&data, view, halo, stagger_step, apply_stagger, &expected);
            const serial = try compactCognitionInline(&serial_sys, &view, stagger_step, apply_stagger);
            try std.testing.expectEqualSlices(u32, expected.items, serial.cognition);
            for (1..5) |workers| {
                for ([_]usize{ 16, 48, 256 }) |items_per_range| {
                    const threaded = try threaded_sys.compactCognition(&view, stagger_step, apply_stagger, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = workers, .adaptive = false });
                    try std.testing.expectEqualSlices(u32, expected.items, threaded.cognition);
                }
            }
        }
    }
}

test "the think set reads the phases the index was built with" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillDenseCognitionPopulation(&data, 40);
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const halo = (try gatherAiInline(&sys, &data, null)).halo;
    var index = try testHaloIndex(&data, halo);
    defer index.deinit();
    const view = index.view();
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(allocator);
    try bruteForceThinkSet(&data, view, halo, 1, true, &expected);
    // Every agent moves to phase 1 after the build: the think set keeps the built phases.
    for (data.aiAgentSliceConst().entities) |entity| try data.setSimulationMetadata(entity, .{ .tier = .cognition, .stagger_phase = 1 });
    try std.testing.expect(expected.items.len < 40);
    try std.testing.expectEqualSlices(u32, expected.items, (try compactCognitionInline(&sys, &view, 1, true)).cognition);
}

test "after reserve, the threaded think set at 32- then 16-item ranges allocates nothing" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const population: usize = 300;
    try fillCognitionPopulation(&data, population);
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var index = try testHaloIndex(&data, null);
    defer index.deinit();
    const view = index.view();
    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    const serial = try compactCognitionInline(&serial_sys, &view, 1, true);

    try sys.reserve(population);
    const original_sys_allocator = sys.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    sys.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        sys.allocator = original_sys_allocator;
        threads.allocator = original_thread_allocator;
    }
    for ([_]usize{ 32, 16 }) |items_per_range| {
        const threaded = try sys.compactCognition(&view, 1, true, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expectEqualSlices(u32, serial.cognition, threaded.cognition);
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

fn phaseRunIsCellMajor(data: *const DataSystem, region: ?ActiveRegion, begin: u32, end: u32) !void {
    if (end <= begin) return;
    const agents = data.aiAgentSliceConst();
    const movement = data.movementBodySliceConst();
    const scope = data.scopeColumnsSliceConst();
    var previous = thinkKeyAt(agents, movement, scope, region, testThinkGrid(), begin);
    var row = begin + 1;
    while (row < end) : (row += 1) {
        const key = thinkKeyAt(agents, movement, scope, region, testThinkGrid(), row);
        try std.testing.expect(previous <= key);
        previous = key;
    }
}

test "think set phase runs are contiguous and cell-major" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    data.setStaggerCellGrid(32, 8, 8);
    var spawned: [4]EntityId = undefined;
    for (&spawned) |*entity| {
        entity.* = try data.createEntity();
        try data.setMovementBody(entity.*, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 } });
        try data.setAiAgent(entity.*, .{});
        try data.commitStaggerPhase(entity.*);
    }
    var phases = [_]bool{ false, false, false, false };
    for (spawned) |entity| {
        const phase = data.movement_bodies.scopeMetadataAt(data.movementBodyDenseIndex(entity).?).stagger_phase;
        try std.testing.expect(phase < 4);
        phases[phase] = true;
    }
    for (phases) |present| try std.testing.expect(present);

    const outside = try data.createEntity();
    try data.setMovementBody(outside, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 } });
    try data.setAiAgent(outside, .{});
    try data.setSimulationMetadata(outside, .{ .tier = .cognition, .chunk = .{ .x = 30, .y = 30 }, .stagger_phase = 2 });
    const boss = try data.createEntity();
    try data.setMovementBody(boss, .{ .position = .{ .x = 64, .y = 64 }, .previous_position = .{ .x = 64, .y = 64 } });
    try data.setAiAgent(boss, .{});
    try data.setSimulationMetadata(boss, .{ .tier = .cognition, .chunk = .{ .x = 40, .y = 40 }, .stagger_phase = 1, .always_active = true });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var threads = try inlineThreads();
    defer threads.deinit();
    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    try sys.orderThinkPhases(&data, region, testThinkGrid(), &threads, .{});

    const agents = data.aiAgentSliceConst();
    var row: u32 = 0;
    var aa_count: usize = 0;
    while (row < agents.entities.len) : (row += 1) {
        if (!agents.always_active[row]) continue;
        aa_count += 1;
        try std.testing.expect(row >= sys.aa_begin and row < sys.aa_end);
    }
    try std.testing.expectEqual(@as(usize, sys.aa_end - sys.aa_begin), aa_count);
    for (0..4) |phase| {
        const phase_id: u8 = @intCast(phase);
        var phase_count: usize = 0;
        row = 0;
        while (row < agents.entities.len) : (row += 1) {
            if (agents.always_active[row] or agents.stagger_phase[row] != phase_id) continue;
            phase_count += 1;
            try std.testing.expect(row >= sys.phase_begin[phase] and row < sys.phase_end[phase]);
        }
        try std.testing.expectEqual(@as(usize, sys.phase_end[phase] - sys.phase_begin[phase]), phase_count);
        try phaseRunIsCellMajor(&data, region, sys.phase_begin[phase], sys.phase_end[phase]);
    }
    try phaseRunIsCellMajor(&data, region, sys.aa_begin, sys.aa_end);

    const halo = (try sys.gatherAiPopulations(&data, region, &threads, .{})).halo;
    var cursor: usize = 0;
    const aa_len: usize = sys.aa_halo_end - sys.aa_begin;
    for (0..aa_len) |i| try std.testing.expectEqual(sys.aa_begin + @as(u32, @intCast(i)), halo[cursor + i]);
    cursor = aa_len;
    for (0..4) |phase| {
        const count: usize = sys.phase_halo_end[phase] - sys.phase_begin[phase];
        for (0..count) |i| try std.testing.expectEqual(sys.phase_begin[phase] + @as(u32, @intCast(i)), halo[cursor + i]);
        cursor += count;
    }
    try std.testing.expectEqual(cursor, halo.len);
    for (halo) |index| try std.testing.expect(!agents.entities[index].eql(outside));
}

test "think scratch growth warns once" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 8, .y = 8 }, .previous_position = .{ .x = 8, .y = 8 } });
    try data.setAiAgent(entity, .{});
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var threads = try inlineThreads();
    defer threads.deinit();

    try sys.orderThinkPhases(&data, null, testThinkGrid(), &threads, .{});
    const grows = sys.think_scratch_grows;
    try std.testing.expect(grows >= 1);
    try std.testing.expect(sys.think_scratch_grow_logged);
    sys.advanceStep();
    _ = try sys.gatherAiPopulations(&data, null, &threads, .{});
    try std.testing.expectEqual(grows, sys.think_scratch_grows);

    try sys.orderThinkPhases(&data, null, testThinkGrid(), &threads, .{});
    try std.testing.expectEqual(grows, sys.think_scratch_grows);
    try std.testing.expect(sys.think_scratch_grow_logged);
}

test "a packed think span keeps the think set's entity order" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillDenseCognitionPopulation(&data, 12);
    const boss = try data.createEntity();
    try data.setMovementBody(boss, .{ .position = .{ .x = 10, .y = 10 }, .previous_position = .{ .x = 10, .y = 10 } });
    try data.setAiAgent(boss, .{});
    try data.setSimulationMetadata(boss, .{ .tier = .cognition, .always_active = true, .stagger_phase = 2 });
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var threads = try inlineThreads();
    defer threads.deinit();
    try sys.orderThinkPhases(&data, null, testThinkGrid(), &threads, .{});
    const halo = (try sys.gatherAiPopulations(&data, null, &threads, .{})).halo;
    var index = try testHaloIndex(&data, halo);
    defer index.deinit();
    const before = try compactCognitionInline(&sys, &index.view(), 0, false);
    var entities: std.ArrayList(EntityId) = .empty;
    defer entities.deinit(allocator);
    const agents_before = data.aiAgentSliceConst();
    try entities.ensureTotalCapacity(allocator, before.cognition.len);
    for (before.cognition) |ai_row| entities.appendAssumeCapacity(agents_before.entities[ai_row]);
    try sys.packThinkSpan(&data, &threads, .{});
    const span = sys.ai_cognition_indices.items;
    try std.testing.expectEqual(entities.items.len, span.len);
    const agents = data.aiAgentSliceConst();
    for (span, entities.items, 0..) |ai_row, entity, k| {
        try std.testing.expectEqual(@as(u32, @intCast(k)), ai_row);
        try std.testing.expect(agents.entities[ai_row].eql(entity));
    }
}

test "optional pack keeps listed rows when the component store outgrows the ai scratch" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const thinker_count = 2;
    var thinkers: [thinker_count]EntityId = undefined;
    for (&thinkers) |*entity| {
        entity.* = try data.createEntity();
        try data.setMovementBody(entity.*, .{ .position = .{ .x = 8, .y = 8 }, .previous_position = .{ .x = 8, .y = 8 } });
        try data.setAiAgent(entity.*, .{});
        try data.setAiPerception(entity.*, .{});
    }
    // Perception rows with no AI row, past the scratch grown from the AI count.
    for (0..200) |_| {
        const extra = try data.createEntity();
        try data.setAiPerception(extra, .{});
    }
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    var threads = try inlineThreads();
    defer threads.deinit();
    try sys.orderThinkPhases(&data, null, testThinkGrid(), &threads, .{});
    try std.testing.expect(data.ai_perceptions.len() > sys.pack_outside.capacity);
    const halo = (try sys.gatherAiPopulations(&data, null, &threads, .{})).halo;
    var index = try testHaloIndex(&data, halo);
    defer index.deinit();
    const before = try compactCognitionInline(&sys, &index.view(), 0, false);
    var expected: std.ArrayList(EntityId) = .empty;
    defer expected.deinit(allocator);
    const agents_before = data.aiAgentSliceConst();
    const perception_before = data.aiPerceptionSliceConst();
    for (before.cognition) |ai_row| {
        const perception_row = agents_before.perception_row[ai_row];
        if (perception_row == no_component_row) continue;
        try expected.append(allocator, perception_before.entities[perception_row]);
    }
    try std.testing.expectEqual(@as(usize, thinker_count), expected.items.len);
    try sys.packThinkSpan(&data, &threads, .{});
    const packed_rows = data.aiPerceptionSliceConst();
    for (expected.items, 0..) |entity, k| try std.testing.expect(packed_rows.entities[k].eql(entity));
}

test "threaded think order matches serial" {
    const allocator = std.testing.allocator;
    var serial_data = DataSystem.init(allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(allocator);
    defer threaded_data.deinit();
    try fillCognitionPopulation(&serial_data, 24);
    try fillCognitionPopulation(&threaded_data, 24);
    var inline_threads = try inlineThreads();
    defer inline_threads.deinit();
    var workers = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer workers.deinit();
    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();
    const fixed = ScopeConfig{ .items_per_range = scope_range_alignment_items, .max_worker_threads = 2, .adaptive = false };
    try serial_sys.orderThinkPhases(&serial_data, null, testThinkGrid(), &inline_threads, .{});
    try threaded_sys.orderThinkPhases(&threaded_data, null, testThinkGrid(), &workers, fixed);
    try std.testing.expectEqualSlices(EntityId, serial_data.aiAgentSliceConst().entities, threaded_data.aiAgentSliceConst().entities);
    const serial_halo = (try serial_sys.gatherAiPopulations(&serial_data, null, &inline_threads, .{})).halo;
    var serial_index = try testHaloIndex(&serial_data, serial_halo);
    defer serial_index.deinit();
    const threaded_halo = (try threaded_sys.gatherAiPopulations(&threaded_data, null, &workers, fixed)).halo;
    var threaded_index = try testHaloIndex(&threaded_data, threaded_halo);
    defer threaded_index.deinit();
    const serial_think = try compactCognitionInline(&serial_sys, &serial_index.view(), 0, false);
    const threaded_think = try compactCognitionInline(&threaded_sys, &threaded_index.view(), 0, false);
    try std.testing.expectEqual(serial_think.cognition.len, threaded_think.cognition.len);
    const serial_rows = serial_data.aiAgentSliceConst().entities;
    const threaded_rows = threaded_data.aiAgentSliceConst().entities;
    for (serial_think.cognition, threaded_think.cognition) |serial_row, threaded_row| {
        try std.testing.expect(serial_rows[serial_row].eql(threaded_rows[threaded_row]));
    }
    try serial_sys.packThinkSpan(&serial_data, &inline_threads, .{});
    try threaded_sys.packThinkSpan(&threaded_data, &workers, fixed);
    try std.testing.expectEqualSlices(EntityId, serial_data.aiAgentSliceConst().entities[0..serial_think.cognition.len], threaded_data.aiAgentSliceConst().entities[0..threaded_think.cognition.len]);
}

test "threaded think order allocates nothing after reserve" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillDenseCognitionPopulation(&data, 20);
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    try sys.reserve(64);
    var threads = try inlineThreads();
    defer threads.deinit();
    try sys.orderThinkPhases(&data, null, testThinkGrid(), &threads, .{});
    const halo = (try sys.gatherAiPopulations(&data, null, &threads, .{})).halo;
    var index = try testHaloIndex(&data, halo);
    defer index.deinit();
    _ = try compactCognitionInline(&sys, &index.view(), 0, false);
    try sys.packThinkSpan(&data, &threads, .{});

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const failing_allocator = failing.allocator();
    const saved_data = data.allocator;
    const saved_sys = sys.allocator;
    const saved_threads = threads.allocator;
    data.allocator = failing_allocator;
    sys.allocator = failing_allocator;
    threads.allocator = failing_allocator;
    defer {
        data.allocator = saved_data;
        sys.allocator = saved_sys;
        threads.allocator = saved_threads;
    }
    try sys.orderThinkPhases(&data, null, testThinkGrid(), &threads, .{});
    _ = try sys.gatherAiPopulations(&data, null, &threads, .{});
    _ = try compactCognitionInline(&sys, &index.view(), 0, false);
    try sys.packThinkSpan(&data, &threads, .{});
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "collision gather filters on the bounds tier column" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const first = try data.createEntity();
    try data.setMovementBody(first, .{ .position = .{ .x = 1, .y = 1 } });
    try data.setCollisionBounds(first, .{ .size = .{ .x = 4, .y = 4 } });
    try data.setSimulationTier(first, .locomotion);
    const dropped = try data.createEntity();
    try data.setMovementBody(dropped, .{ .position = .{ .x = 8, .y = 8 } });
    try data.setCollisionBounds(dropped, .{ .size = .{ .x = 4, .y = 4 } });
    try data.setSimulationTier(dropped, .kinematic);
    const second = try data.createEntity();
    try data.setMovementBody(second, .{ .position = .{ .x = 16, .y = 16 } });
    try data.setCollisionBounds(second, .{ .size = .{ .x = 4, .y = 4 } });
    try data.setSimulationTier(second, .locomotion);
    const dropped_movement = data.movementBodyDenseIndex(dropped).?;
    var dropped_bounds: usize = 0;
    for (data.collisionBoundsSliceConst().entities, 0..) |bounds_entity, index| {
        if (bounds_entity.eql(dropped)) dropped_bounds = index;
    }
    // Movement-scope tier now allows collision; the bounds column stays kinematic.
    data.movement_bodies.setTier(dropped_movement, .locomotion);
    try std.testing.expect(data.collisionBoundsSliceConst().tier[dropped_bounds] != data.scopeColumnsSliceConst().tier[dropped_movement]);
    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const list = (try gatherCollisionInline(&sys, &data)).?;
    const bounds = data.collisionBoundsSliceConst();
    try std.testing.expect(!bounds.tier[dropped_bounds].allowsCollision());
    var expect_ids: [2]u32 = undefined;
    var count: usize = 0;
    for (data.collision_bounds.dynamic_ids.items) |bounds_index| {
        if (!bounds.tier[bounds_index].allowsCollision()) continue;
        expect_ids[count] = bounds_index;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(u32, expect_ids[0..count], list);
    for (list) |bounds_index| try std.testing.expect(bounds_index != @as(u32, @intCast(dropped_bounds)));
}
