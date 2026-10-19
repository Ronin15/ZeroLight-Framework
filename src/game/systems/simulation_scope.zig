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
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const paddingForCacheLine = @import("../../app/thread_system.zig").paddingForCacheLine;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
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

/// Per-step threading knobs for the scope passes. Mirrors the other systems:
/// null `items_per_range` + `adaptive` lets each pass train its own tuner; an
/// explicit `items_per_range` pins the range size and opts out of the tuner.
pub const ScopeConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

/// Threaded gather result for the movement/collision passes: `indices` is null on
/// the full-active fast path (downstream uses the full SoA range), otherwise the
/// merged dense-index list. `batch` feeds the perf log / bench.
pub const ScopeGatherResult = struct {
    indices: ?[]const u32,
    batch: BatchStats = .{},
};

/// Threaded gather result for the AI halo: the unstaggered cognition set (spatial index +
/// perception candidates). Unlike movement/collision it never short-circuits to
/// full-active. The think set comes from `compactCognition` over the index built from it.
pub const AiPopulationGatherResult = struct {
    halo: []const u32,
    batch: BatchStats = .{},
};

/// The step's think set (`SimulationScopeSystem.compactCognition`), valid until the next
/// compaction.
pub const CognitionResult = struct {
    cognition: []const u32,
    batch: BatchStats = .{},
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
    /// Per-range tallies (count + diagnostics) for the threaded passes, one padded
    /// record per range. Each worker writes only its own record; the main thread reads
    /// them after the batch. The three passes run sequentially, so they share it.
    range_tallies: GatherTallyList = .empty,
    /// One adaptive tuner per independently-timed threaded pass.
    chunk_derive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    collision_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    ai_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    cognition_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    tier_policy_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: the last think set's indexed halo entities
    /// whose stagger_phase did not match its step, and the last AI gather's cognition
    /// entities excluded because their chunk is outside the halo.
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
        };
    }

    pub fn deinit(self: *SimulationScopeSystem) void {
        self.range_tallies.deinit(self.allocator);
        self.scope_tier_commands.deinit(self.allocator);
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
        try self.range_tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(capacity, scope_range_alignment_items));
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
    /// frozen position (harmless). Worker ranges own disjoint rows, so the chunk
    /// writes are range-disjoint; no pre-sized scratch is needed.
    pub fn deriveChunks(
        self: *SimulationScopeSystem,
        data: *DataSystem,
        thread_system: *ThreadSystem,
        grid: ChunkGrid,
        config: ScopeConfig,
    ) BatchStats {
        const move = data.movementBodySliceConst();
        const n = move.entities.len;
        if (n == 0) return .{};
        const scope = data.scopeColumnsSlice();
        var context = DeriveChunksContext{
            .position_x = move.position_x,
            .position_y = move.position_y,
            .chunk_x = scope.chunk_x,
            .chunk_y = scope.chunk_y,
            .grid = grid,
        };
        const derive = Dispatch.init(thread_system, &self.chunk_derive_tuner, .{
            .items_per_range = config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
        });
        const selection = derive.select(n, scope_range_alignment_items);
        return derive.run(selection, n, scope_range_alignment_items, &context, deriveChunkJob);
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
        const scope = data.scopeColumnsSliceConst();
        const selection = thread_system.selectBatchProfile(&self.collision_gather_tuner, .{
            .item_count = n,
            .items_per_range = config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive = config.adaptive,
        });
        try self.prepareRangeWindows(u32, &self.collision_indices, n, selection.range_count);
        var context = CollisionGatherContext{
            .data = data,
            .dynamic_ids = dynamic_ids,
            .bounds_entities = bounds.entities,
            .tier = scope.tier,
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
        return .{ .indices = if (merged.any_excluded) self.collision_indices.items else null, .batch = batch };
    }

    // ---- AI halo gather and think set (threaded compactions) -----------------

    /// Builds this step's AI halo: cognition tier inside `cognition_region` (every
    /// cognition-tier row when null), `always_active` included.
    pub fn gatherAiPopulations(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        cognition_region: ?ActiveRegion,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !AiPopulationGatherResult {
        const ai = data.aiAgentSliceConst();
        const n = ai.entities.len;
        self.perf = .{};
        if (n == 0) {
            self.ai_halo_indices.clearRetainingCapacity();
            return .{ .halo = self.ai_halo_indices.items };
        }

        const scope = data.scopeColumnsSliceConst();
        const selection = thread_system.selectBatchProfile(&self.ai_gather_tuner, .{
            .item_count = n,
            .items_per_range = config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive = config.adaptive,
        });
        try self.prepareRangeWindows(u32, &self.ai_halo_indices, n, selection.range_count);
        var context = AiGatherContext{
            .data = data,
            .ai_entities = ai.entities,
            .scope = scope,
            .cognition_region = cognition_region,
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
        const merged = compactIndexWindows(&self.ai_halo_indices, self.range_tallies.items, selection.items_per_range);
        if (comptime runtime_perf_log.enabled) self.perf.chunk_filtered_entities = merged.perf.chunk_filtered;
        return .{ .halo = self.ai_halo_indices.items, .batch = batch };
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
        return .{ .cognition = self.ai_cognition_indices.items, .batch = batch };
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
        for (tallies) |*slot| total += slot.tally.count;
        // No tier crossed a band this step → leave the stream untouched so other
        // structural producers' append protocol is unaffected.
        if (total == 0) return batch;

        const windows = self.scope_tier_commands.items;
        const range_base = try stream.appendRangeCounts(tallies.len);
        for (tallies, 0..) |*slot, range_index| {
            stream.addCount(range_base + range_index, slot.tally.count);
        }
        try stream.prefixAppendedRanges(range_base);
        for (tallies, 0..) |*slot, range_index| {
            var writer = stream.rangeWriter(range_base + range_index);
            const window_start = range_index * selection.items_per_range;
            for (windows[window_start..][0..slot.tally.count]) |command| writer.write(command);
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
        self.range_tallies.items.len = range_count;
        for (self.range_tallies.items) |*slot| slot.tally = .{};
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

const GatherTallySlot = struct {
    // Padding keeps concurrently written tallies off shared cache lines.
    tally: GatherTally = .{},
    padding: [paddingForCacheLine(GatherTally)]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(GatherTallySlot) % thread_shared_record_alignment == 0);
}

const GatherTallyList = std.array_list.Aligned(GatherTallySlot, .fromByteUnits(thread_shared_record_alignment));

/// Compacts the per-range windows of `list` (range r's `count` records at
/// `r * items_per_range`) into one contiguous prefix in range order and sums the
/// tallies. The destination never passes the source (each window starts at or after
/// the running total), so a forward copy is safe, and a step where no range excluded
/// anything copies nothing.
fn compactIndexWindows(list: *IndexList, tallies: []const GatherTallySlot, items_per_range: usize) IndexMergeResult {
    var result: IndexMergeResult = .{};
    var dst: usize = 0;
    for (tallies, 0..) |*slot, range_index| {
        const tally = slot.tally;
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

const DeriveChunksContext = struct {
    position_x: []const f32,
    position_y: []const f32,
    chunk_x: HotI32Slice,
    chunk_y: HotI32Slice,
    grid: SimulationScopeSystem.ChunkGrid,
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
            job.chunk_x[i + lane] = cx[lane];
            job.chunk_y[i + lane] = cy[lane];
        }
    }
    while (i < range.end) : (i += 1) {
        const tx = math.worldPosToCell(job.position_x[i], grid.tile_size, grid.width);
        const ty = math.worldPosToCell(job.position_y[i], grid.tile_size, grid.height);
        job.chunk_x[i] = @intCast(tx / @as(u32, @intCast(chunk_size)));
        job.chunk_y[i] = @intCast(ty / @as(u32, @intCast(chunk_size)));
    }
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

const CollisionGatherContext = struct {
    data: *const DataSystem,
    dynamic_ids: []const u32,
    bounds_entities: []const EntityId,
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
        const di = job.data.movementBodyDenseIndex(job.bounds_entities[bounds_index]) orelse continue;
        if (job.tier[di].allowsCollision()) {
            window[tally.count] = bounds_index;
            tally.count += 1;
        } else {
            tally.any_excluded = true;
        }
    }
    job.tallies[range.index].tally = tally;
}

const AiGatherContext = struct {
    data: *const DataSystem,
    ai_entities: []const EntityId,
    scope: ConstScopeColumnsSlice,
    cognition_region: ?ActiveRegion,
    item_count: usize,
    /// Item-count output; range r writes only its own `[range.start, range.end)` window.
    out: []u32,
    items_per_range: usize,
    tallies: []GatherTallySlot,
};

fn aiGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiGatherContext = @ptrCast(@alignCast(context));
    // Window asserts plus range.end vs the candidate count this job walks.
    assertRangeWindow(range, job.items_per_range, job.tallies.len, job.out.len);
    std.debug.assert(range.end <= job.item_count);
    const window = job.out[range.start..range.end];
    var tally: GatherTally = .{};
    const scope = job.scope;
    for (range.start..range.end) |i| {
        const ent = job.ai_entities[i];
        const di = job.data.movementBodyDenseIndex(ent) orelse continue;
        if (!scope.tier[di].allowsCognition()) continue;
        if (scope.always_active[di]) {
            window[tally.count] = @intCast(i);
            tally.count += 1;
            continue;
        }
        if (job.cognition_region) |region| {
            if (!region.containsChunk(.{ .x = scope.chunk_x[di], .y = scope.chunk_y[di] })) {
                if (comptime runtime_perf_log.enabled) tally.perf.chunk_filtered += 1;
                continue;
            }
        }
        window[tally.count] = @intCast(i);
        tally.count += 1;
    }
    job.tallies[range.index].tally = tally;
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
    job.tallies[range.index].tally = tally;
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
    job.tallies[range.index].tally = .{ .count = count };
}

// ---- Tests ------------------------------------------------------------------

const SpatialIndexSystem = @import("spatial_index.zig").SpatialIndexSystem;
const testHaloIndex = @import("spatial_index_test_support.zig").testHaloIndex;

// A thread system with no workers: every pass runs its production path inline as one
// range and records no tuner sample.
fn inlineThreads() !ThreadSystem {
    return ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
}

fn gatherAiInline(sys: *SimulationScopeSystem, data: *const DataSystem, region: ?ActiveRegion) !AiPopulationGatherResult {
    var threads = try inlineThreads();
    defer threads.deinit();
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
    const dormant = try data.createEntity();
    try data.setMovementBody(dormant, .{ .position = .{ .x = 500, .y = 200 } });
    try data.setSimulationTier(dormant, .dormant);
    const b = try data.createEntity();
    try data.setMovementBody(b, .{ .position = .{ .x = 700, .y = 260 } });

    const tile_size: f32 = 32;
    const chunk_size: u16 = 8;
    const dims: u16 = 64;

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    _ = sys.deriveChunks(&data, &threads, .{
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
        const se = try serial_data.createEntity();
        try serial_data.setMovementBody(se, .{ .position = .{ .x = fi * 3.5, .y = fi * 1.25 } });
    }

    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();
    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();

    const stats = threaded_sys.deriveChunks(&threaded_data, &threads, grid, .{
        .items_per_range = scope_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    try std.testing.expect(!stats.ran_inline); // real workers partitioned the range
    var inline_threads = try inlineThreads();
    defer inline_threads.deinit();
    const inline_stats = serial_sys.deriveChunks(&serial_data, &inline_threads, grid, .{});
    try std.testing.expect(inline_stats.ran_inline);

    const ts = threaded_data.scopeColumnsSliceConst();
    const ss = serial_data.scopeColumnsSliceConst();
    for (0..count) |i| {
        try std.testing.expectEqual(ss.chunk_x[i], ts.chunk_x[i]);
        try std.testing.expectEqual(ss.chunk_y[i], ts.chunk_y[i]);
    }
}

test "threaded deriveChunks records one sample into its own tuner and none into the shared tuner" {
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
    const stats = sys.deriveChunks(&data, &threads, .{ .tile_size = 32, .chunk_size_tiles = 8, .width = 256, .height = 256 }, .{});
    try std.testing.expectEqual(count, stats.item_count);
    try std.testing.expectEqual(@as(usize, 1), sys.chunk_derive_tuner.sample_count);
    try std.testing.expect(sys.chunk_derive_tuner.last_request != null);
    try std.testing.expectEqual(@as(usize, 0), threads.adaptive_tuner.sample_count);
    try std.testing.expect(threads.adaptive_tuner.last_request == null);
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
    const threaded = try threaded_sys.gatherAiPopulations(&data, region, &threads, fixed);
    try std.testing.expect(!threaded.batch.ran_inline);
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
    const batch = try threaded_sys.queueTierChanges(&data, visible, &threaded_stream, &threads, .{ .items_per_range = scope_range_alignment_items, .max_worker_threads = 2, .adaptive = false });
    try std.testing.expect(!batch.ran_inline);

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

test "thread-written scope range tallies use cache-line sized slots" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(GatherTallySlot) % thread_shared_record_alignment);
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
        try std.testing.expect(!collision.batch.ran_inline);
        try std.testing.expectEqual(@divCeil(population, items_per_range), collision.batch.range_count);
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
                    try std.testing.expect(!threaded.batch.ran_inline);
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
                    try std.testing.expect(!threaded.batch.ran_inline);
                    try std.testing.expectEqual(@divCeil(halo.len, items_per_range), threaded.batch.range_count);
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
    var index = try testHaloIndex(&data, null);
    defer index.deinit();
    const view = index.view();
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(allocator);
    try bruteForceThinkSet(&data, view, (try gatherAiInline(&sys, &data, null)).halo, 1, true, &expected);
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
        try std.testing.expect(!threaded.batch.ran_inline);
        try std.testing.expectEqual(@divCeil(population, items_per_range), threaded.batch.range_count);
        try std.testing.expectEqualSlices(u32, serial.cognition, threaded.cognition);
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}
