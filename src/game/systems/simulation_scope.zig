// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Backbone simulation system that determines which entities enter each
//! fixed-step stage. Runs once per step to recompute chunk coordinates from
//! settled positions, then builds filtered dense-index lists consumed by the
//! downstream movement, collision, AI, and steering systems.
//!
//! Stage participation rules (Slice 24):
//!   movement   — tier.allowsMovement()  — no chunk filter
//!   collision  — tier.allowsCollision() — no chunk filter
//!   ai/steering — tier.allowsCognition() AND chunk inside cognition halo
//!                 AND stagger_phase == step % cognition_stagger_n
//!                 (always_active entities bypass halo and stagger)
//!
//! Index lists are rebuilt each step from the same-step recomputed chunk coords
//! (which reflect positions settled at the end of the prior step — one step lag,
//! identical to the pathfinding frame-delay contract).
//!
//! Each O(N)-per-step pass threads like the other processors: the gathers are
//! stream-compactions (per-range index buffers merged in range order); the tier
//! policy is a variable-output producer (per-range command buffers merged into
//! the frame's structural-command stream). Each pass owns an `AdaptiveWorkTuner`
//! and exposes a `*Serial` variant for the serial bench/test path. Threaded and
//! serial produce identical results (range-ordered merge preserves scan order).

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkProfile = @import("../../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const ConstScopeColumnsSlice = @import("../data_system.zig").ConstScopeColumnsSlice;
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

/// Cache-line range alignment for the scope passes, matching the other hot stages
/// so worker ranges land on aligned SoA boundaries.
pub const scope_range_alignment_items: usize = movement_range_alignment_items;

const thread_shared_record_alignment: usize = 64;

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

/// Threaded gather result for the AI pass. Unlike movement/collision it never
/// short-circuits to full-active, so `indices` is always the merged list.
pub const AiGatherResult = struct {
    indices: []const u32,
    batch: BatchStats = .{},
};

pub const SimulationScopeSystem = struct {
    allocator: std.mem.Allocator,
    /// Step counter incremented at the top of each fixed step. Drives stagger.
    step_count: u32,
    /// Warmed movement dense-index list. null return = full-active (no dormant movers).
    movement_indices: std.ArrayList(u32) = .empty,
    /// Warmed collision dense-index list. null return = full-active (no dormant/kinematic with bounds).
    collision_indices: std.ArrayList(u32) = .empty,
    /// Warmed AI agent dense-index list (cognition halo + stagger filtered).
    /// Steering scopes transitively off the navigation intents AI emits for these
    /// agents, so there is no separate steering gather (a second filter would
    /// double-gate the already-scoped intents).
    ai_indices: std.ArrayList(u32) = .empty,
    /// Warmed scratch for the per-step auto wake/sleep tier commands this system
    /// produces. Owned here beside the other scratch, written into the frame's
    /// structural-command stream by queueTierChangesSerial.
    scope_tier_commands: std.ArrayList(StructuralCommand) = .empty,
    /// Per-range index/command scratch for the threaded passes. Each worker writes
    /// only its assigned slot; the main thread merges serially afterward.
    movement_gather_ranges: IndexRangeSlotList = .empty,
    collision_gather_ranges: IndexRangeSlotList = .empty,
    ai_gather_ranges: IndexRangeSlotList = .empty,
    tier_command_ranges: CommandRangeSlotList = .empty,
    /// One adaptive tuner per independently-timed threaded pass.
    movement_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    collision_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    ai_gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    tier_policy_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    /// Entities inside the halo whose stagger_phase did not match this step.
    stagger_skips: usize,
    /// Entities excluded from cognition because their chunk is outside the halo.
    chunk_filtered_entities: usize,

    pub fn init(allocator: std.mem.Allocator) SimulationScopeSystem {
        return .{
            .allocator = allocator,
            .step_count = 0,
            .movement_gather_tuner = AdaptiveWorkTuner.init(.{}),
            .collision_gather_tuner = AdaptiveWorkTuner.init(.{}),
            .ai_gather_tuner = AdaptiveWorkTuner.init(.{}),
            .tier_policy_tuner = AdaptiveWorkTuner.init(.{}),
            .stagger_skips = 0,
            .chunk_filtered_entities = 0,
        };
    }

    pub fn deinit(self: *SimulationScopeSystem) void {
        for (self.tier_command_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.tier_command_ranges.deinit(self.allocator);
        for (self.ai_gather_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.ai_gather_ranges.deinit(self.allocator);
        for (self.collision_gather_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.collision_gather_ranges.deinit(self.allocator);
        for (self.movement_gather_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.movement_gather_ranges.deinit(self.allocator);
        self.scope_tier_commands.deinit(self.allocator);
        self.ai_indices.deinit(self.allocator);
        self.collision_indices.deinit(self.allocator);
        self.movement_indices.deinit(self.allocator);
    }

    /// Pre-sizes the per-step scratch index/command lists to `capacity` movement
    /// bodies so the serial gathers and tier policy are allocation-free after init.
    /// The threaded per-range slot buffers still warm on their first threaded step.
    pub fn reserve(self: *SimulationScopeSystem, capacity: usize) !void {
        try self.movement_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.collision_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.ai_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.scope_tier_commands.ensureTotalCapacity(self.allocator, capacity);
    }

    /// Increment the step counter. Call once at the top of each fixed step.
    pub fn advanceStep(self: *SimulationScopeSystem) void {
        self.step_count += 1;
        self.stagger_skips = 0;
        self.chunk_filtered_entities = 0;
    }

    /// Current stagger slot: entities whose stagger_phase matches this value run AI/steering.
    pub fn staggerStep(self: *const SimulationScopeSystem) u8 {
        return @intCast(self.step_count % cognition_stagger_n);
    }

    // Chunk maintenance is folded into the movement processor: it derives each
    // integrated body's chunk from its new position in the same pass (see
    // movement.ChunkGridParams), so there is no separate recompute pass here. The
    // gathers below read the chunk columns movement wrote.

    // ---- Movement gather (threaded compaction) -------------------------------

    /// Build the movement dense-index list. Returns null indices when all movement
    /// entities are non-dormant (full-active shortcut — downstream uses the full
    /// SoA range). Movement has NO chunk filter; all non-dormant entities move.
    /// Threads the real scan; the O(1) full-active fast path never dispatches work.
    pub fn gatherMovementBodyIndices(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !ScopeGatherResult {
        const scope = data.scopeColumnsSliceConst();
        const n = scope.tier.len;
        if (n == 0) return .{ .indices = &[_]u32{} };
        // Fast-path: only .dormant entities are excluded from movement. With none
        // present, every entity moves → full-active, no per-entity scan.
        if (data.tierCount(.dormant) == 0) return .{ .indices = null };

        const selection = selectGatherWork(thread_system, n, config, &self.movement_gather_tuner);
        try prepareIndexRangeBuffers(self.allocator, &self.movement_gather_ranges, n, selection.items_per_range, selection.range_count);
        var context = MovementGatherContext{
            .tier = scope.tier,
            .ranges = self.movement_gather_ranges.items[0..selection.range_count],
        };
        const batch = thread_system.parallelForWithOptions(n, &context, movementGatherJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        const merged = try self.mergeIndexRanges(&self.movement_indices, self.movement_gather_ranges.items[0..selection.range_count]);
        return .{ .indices = if (merged.any_excluded) self.movement_indices.items else null, .batch = batch };
    }

    /// Serial movement gather: same predicate, single pass, no thread system.
    /// Drives the serial bench/test path and the threaded==serial parity checks.
    pub fn gatherMovementBodyIndicesSerial(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
    ) !?[]const u32 {
        const scope = data.scopeColumnsSliceConst();
        const n = scope.tier.len;
        if (n == 0) return &[_]u32{};
        if (data.tierCount(.dormant) == 0) return null;

        self.movement_indices.clearRetainingCapacity();
        try self.movement_indices.ensureTotalCapacity(self.allocator, n);
        var any_excluded = false;
        scanTierAboveThreshold(scope.tier, 0, n, @intFromEnum(SimulationTier.dormant), &self.movement_indices, &any_excluded);
        return if (any_excluded) self.movement_indices.items else null;
    }

    // ---- Collision gather (threaded compaction) ------------------------------

    /// Build the collision bounds dense-index list. Returns null indices when all
    /// collision entities are eligible (full-active shortcut). No chunk filter.
    pub fn gatherCollisionBoundsIndices(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !ScopeGatherResult {
        const bounds = data.collisionBoundsSliceConst();
        const n = bounds.entities.len;
        if (n == 0) return .{ .indices = &[_]u32{} };
        // Fast-path: only .dormant/.kinematic entities lack collision. With none
        // present, every entity collides → full-active, no per-entity scan.
        if (data.tierCount(.dormant) + data.tierCount(.kinematic) == 0) return .{ .indices = null };

        const scope = data.scopeColumnsSliceConst();
        const selection = selectGatherWork(thread_system, n, config, &self.collision_gather_tuner);
        try prepareIndexRangeBuffers(self.allocator, &self.collision_gather_ranges, n, selection.items_per_range, selection.range_count);
        var context = CollisionGatherContext{
            .data = data,
            .bounds_entities = bounds.entities,
            .tier = scope.tier,
            .ranges = self.collision_gather_ranges.items[0..selection.range_count],
        };
        const batch = thread_system.parallelForWithOptions(n, &context, collisionGatherJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        const merged = try self.mergeIndexRanges(&self.collision_indices, self.collision_gather_ranges.items[0..selection.range_count]);
        return .{ .indices = if (merged.any_excluded) self.collision_indices.items else null, .batch = batch };
    }

    pub fn gatherCollisionBoundsIndicesSerial(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
    ) !?[]const u32 {
        const bounds = data.collisionBoundsSliceConst();
        const n = bounds.entities.len;
        if (n == 0) return &[_]u32{};
        if (data.tierCount(.dormant) + data.tierCount(.kinematic) == 0) return null;

        self.collision_indices.clearRetainingCapacity();
        try self.collision_indices.ensureTotalCapacity(self.allocator, n);
        const scope = data.scopeColumnsSliceConst();
        var any_excluded = false;
        for (bounds.entities, 0..) |ent, i| {
            const di = data.movementBodyDenseIndex(ent) orelse continue;
            if (scope.tier[di].allowsCollision()) {
                self.collision_indices.appendAssumeCapacity(@intCast(i));
            } else {
                any_excluded = true;
            }
        }
        return if (any_excluded) self.collision_indices.items else null;
    }

    // ---- AI gather (threaded compaction + diagnostics) -----------------------

    /// Build the AI agent dense-index list. Filters by cognition tier, chunk inside
    /// cognition halo, and stagger cadence. always_active entities bypass halo +
    /// stagger. Accumulates stagger_skips and chunk_filtered_entities per range,
    /// summed on merge for diagnostics.
    pub fn gatherAiAgentIndices(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        cognition_region: ?ActiveRegion,
        stagger_step: u8,
        thread_system: *ThreadSystem,
        config: ScopeConfig,
    ) !AiGatherResult {
        const ai = data.aiAgentSliceConst();
        const n = ai.entities.len;
        self.stagger_skips = 0;
        self.chunk_filtered_entities = 0;
        if (n == 0) {
            self.ai_indices.clearRetainingCapacity();
            return .{ .indices = self.ai_indices.items };
        }

        const scope = data.scopeColumnsSliceConst();
        const selection = selectGatherWork(thread_system, n, config, &self.ai_gather_tuner);
        try prepareIndexRangeBuffers(self.allocator, &self.ai_gather_ranges, n, selection.items_per_range, selection.range_count);
        var context = AiGatherContext{
            .data = data,
            .ai_entities = ai.entities,
            .scope = scope,
            .cognition_region = cognition_region,
            .stagger_step = stagger_step,
            .ranges = self.ai_gather_ranges.items[0..selection.range_count],
        };
        const batch = thread_system.parallelForWithOptions(n, &context, aiGatherJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        const merged = try self.mergeIndexRanges(&self.ai_indices, self.ai_gather_ranges.items[0..selection.range_count]);
        self.stagger_skips = merged.stagger_skips;
        self.chunk_filtered_entities = merged.chunk_filtered;
        return .{ .indices = self.ai_indices.items, .batch = batch };
    }

    pub fn gatherAiAgentIndicesSerial(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        cognition_region: ?ActiveRegion,
        stagger_step: u8,
    ) ![]const u32 {
        const ai = data.aiAgentSliceConst();
        self.ai_indices.clearRetainingCapacity();
        self.stagger_skips = 0;
        self.chunk_filtered_entities = 0;
        if (ai.entities.len == 0) return self.ai_indices.items;
        try self.ai_indices.ensureTotalCapacity(self.allocator, ai.entities.len);

        const scope = data.scopeColumnsSliceConst();
        for (ai.entities, 0..) |ent, i| {
            const di = data.movementBodyDenseIndex(ent) orelse continue;
            if (!scope.tier[di].allowsCognition()) continue;
            if (scope.always_active[di]) {
                self.ai_indices.appendAssumeCapacity(@intCast(i));
                continue;
            }
            if (cognition_region) |region| {
                if (!region.containsChunk(.{ .x = scope.chunk_x[di], .y = scope.chunk_y[di] })) {
                    self.chunk_filtered_entities += 1;
                    continue;
                }
                if (scope.stagger_phase[di] != stagger_step) {
                    self.stagger_skips += 1;
                    continue;
                }
            }
            self.ai_indices.appendAssumeCapacity(@intCast(i));
        }
        return self.ai_indices.items;
    }

    // ---- Simulation-LOD tier policy (threaded variable-output producer) -------

    /// Runs the per-step tier policy and writes the resulting set_simulation_tier
    /// commands into the frame's structural-command stream. Threads the dense scan
    /// into per-range command buffers, then merges them into the stream via the
    /// append protocol so it coexists with any other structural-command producer.
    /// No-op (no stream touch) when nothing changes. Returns the pass batch.
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

        const selection = selectGatherWork(thread_system, n, config, &self.tier_policy_tuner);
        try prepareCommandRangeBuffers(self.allocator, &self.tier_command_ranges, n, selection.items_per_range, selection.range_count);
        var context = TierPolicyContext{
            .scope = scope,
            .region = region,
            .ranges = self.tier_command_ranges.items[0..selection.range_count],
        };
        const batch = thread_system.parallelForWithOptions(n, &context, tierPolicyJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = scope_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        var total: usize = 0;
        const slots = self.tier_command_ranges.items[0..selection.range_count];
        for (slots) |*slot| total += slot.buffer.commands.items.len;
        // No tier crossed a band this step → leave the stream untouched so other
        // structural producers' append protocol is unaffected.
        if (total == 0) return batch;

        const range_base = try stream.appendRangeCounts(selection.range_count);
        for (slots, 0..) |*slot, range_index| {
            stream.addCount(range_base + range_index, slot.buffer.commands.items.len);
        }
        try stream.prefixAppendedRanges(range_base);
        for (slots, 0..) |*slot, range_index| {
            var writer = stream.rangeWriter(range_base + range_index);
            for (slot.buffer.commands.items) |command| writer.write(command);
            writer.finish();
        }
        stream.finishWrite();
        return batch;
    }

    /// Serial tier policy: collects the commands in one pass and writes a single
    /// range into the stream. Drives the serial bench/test path.
    pub fn queueTierChangesSerial(
        self: *SimulationScopeSystem,
        data: *const DataSystem,
        visible_region: ?ActiveRegion,
        stream: *RangeOutputStream(StructuralCommand),
    ) !void {
        try collectChunkTierChanges(data, visible_region, &self.scope_tier_commands, self.allocator);
        const commands = self.scope_tier_commands.items;
        if (commands.len == 0) return;

        const range_base = try stream.appendRangeCounts(1);
        stream.addCount(range_base, commands.len);
        try stream.prefixAppendedRanges(range_base);
        var writer = stream.rangeWriter(range_base);
        for (commands) |command| writer.write(command);
        writer.finish();
        stream.finishWrite();
    }

    /// Simulation-LOD tier policy core: assigns each entity the tier for its cube
    /// distance from the visible region — cognition (near) → locomotion → kinematic
    /// → dormant (far), per `tierForChunkDistance`. always_active entities are
    /// pinned (never demoted) and skipped. Emits a set_simulation_tier command only
    /// for entities whose current tier differs, into the caller-cleared buffer.
    /// Shared by the serial path; reserves up front so the per-step path is
    /// allocation-free after warmup even when many entities cross a band.
    pub fn collectChunkTierChanges(
        data: *const DataSystem,
        visible_region: ?ActiveRegion,
        out: *std.ArrayList(StructuralCommand),
        allocator: std.mem.Allocator,
    ) !void {
        out.clearRetainingCapacity();
        const region = visible_region orelse return;
        const scope = data.scopeColumnsSliceConst();
        try out.ensureTotalCapacity(allocator, scope.entities.len);
        scanTierPolicy(scope, region, 0, scope.entities.len, out);
    }

    // ---- Shared threading helpers --------------------------------------------

    fn mergeIndexRanges(
        self: *SimulationScopeSystem,
        out: *std.ArrayList(u32),
        slots: []IndexRangeSlot,
    ) !IndexMergeResult {
        out.clearRetainingCapacity();
        var result = IndexMergeResult{};
        var total: usize = 0;
        for (slots) |*slot| {
            total += slot.buffer.indices.items.len;
            if (slot.buffer.any_excluded) result.any_excluded = true;
            result.stagger_skips += slot.buffer.stagger_skips;
            result.chunk_filtered += slot.buffer.chunk_filtered;
        }
        try out.ensureTotalCapacity(self.allocator, total);
        for (slots) |*slot| {
            const start = out.items.len;
            const len = slot.buffer.indices.items.len;
            out.items.len = start + len;
            @memcpy(out.items[start..][0..len], slot.buffer.indices.items);
        }
        return result;
    }
};

const IndexMergeResult = struct {
    any_excluded: bool = false,
    stagger_skips: usize = 0,
    chunk_filtered: usize = 0,
};

// ---- Per-range scratch buffers ----------------------------------------------

const IndexRangeBuffer = struct {
    indices: std.ArrayList(u32) = .empty,
    // Movement/collision null decision: set when any scanned row was excluded.
    any_excluded: bool = false,
    // AI diagnostics accumulated per range, summed on merge.
    stagger_skips: usize = 0,
    chunk_filtered: usize = 0,

    fn reset(self: *IndexRangeBuffer) void {
        self.indices.clearRetainingCapacity();
        self.any_excluded = false;
        self.stagger_skips = 0;
        self.chunk_filtered = 0;
    }

    fn deinit(self: *IndexRangeBuffer, allocator: std.mem.Allocator) void {
        self.indices.deinit(allocator);
        self.* = undefined;
    }
};

const IndexRangeSlot = struct {
    // Padding keeps hot append state off shared cache lines across concurrently
    // written range records.
    buffer: IndexRangeBuffer = .{},
    padding: [paddingForCacheLine(IndexRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(IndexRangeBuffer),
};

const CommandRangeBuffer = struct {
    commands: std.ArrayList(StructuralCommand) = .empty,

    fn reset(self: *CommandRangeBuffer) void {
        self.commands.clearRetainingCapacity();
    }

    fn deinit(self: *CommandRangeBuffer, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.* = undefined;
    }
};

const CommandRangeSlot = struct {
    buffer: CommandRangeBuffer = .{},
    padding: [paddingForCacheLine(CommandRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(CommandRangeBuffer),
};

const IndexRangeSlotList = std.ArrayListAligned(IndexRangeSlot, .fromByteUnits(thread_shared_record_alignment));
const CommandRangeSlotList = std.ArrayListAligned(CommandRangeSlot, .fromByteUnits(thread_shared_record_alignment));

fn prepareIndexRangeBuffers(
    allocator: std.mem.Allocator,
    ranges: *IndexRangeSlotList,
    item_count: usize,
    items_per_range: usize,
    range_count: usize,
) !void {
    try ranges.ensureTotalCapacity(allocator, range_count);
    while (ranges.items.len < range_count) ranges.appendAssumeCapacity(.{});
    for (ranges.items[0..range_count], 0..) |*slot, range_index| {
        slot.buffer.reset();
        // Max one emitted index per scanned row → reserve the range length exactly,
        // so jobs only append (no overflow, no replay).
        try slot.buffer.indices.ensureTotalCapacity(allocator, rangeLenForIndex(item_count, items_per_range, range_index));
    }
}

fn prepareCommandRangeBuffers(
    allocator: std.mem.Allocator,
    ranges: *CommandRangeSlotList,
    item_count: usize,
    items_per_range: usize,
    range_count: usize,
) !void {
    try ranges.ensureTotalCapacity(allocator, range_count);
    while (ranges.items.len < range_count) ranges.appendAssumeCapacity(.{});
    for (ranges.items[0..range_count], 0..) |*slot, range_index| {
        slot.buffer.reset();
        try slot.buffer.commands.ensureTotalCapacity(allocator, rangeLenForIndex(item_count, items_per_range, range_index));
    }
}

// ---- Job contexts and functions ---------------------------------------------

const MovementGatherContext = struct {
    tier: []const SimulationTier,
    ranges: []IndexRangeSlot,
};

fn movementGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *MovementGatherContext = @ptrCast(@alignCast(context));
    const buffer = &job.ranges[range.index].buffer;
    // Keep all entities whose tier outranks .dormant (the only tier movement drops).
    scanTierAboveThreshold(job.tier, range.start, range.end, @intFromEnum(SimulationTier.dormant), &buffer.indices, &buffer.any_excluded);
}

/// SIMD predicate scan over a contiguous tier column: appends each index whose
/// tier rank exceeds `threshold` to `out`, flags `any_excluded` for the rest.
/// One `greaterThanInt4` compares lane_count tiers per step; a scalar tail covers
/// the remainder. Tier ranks are monotonic, so "rank > threshold" expresses every
/// allows* predicate (movement: > dormant). Reused by the serial and threaded paths.
fn scanTierAboveThreshold(
    tier: []const SimulationTier,
    start: usize,
    end: usize,
    threshold: u2,
    out: *std.ArrayList(u32),
    any_excluded: *bool,
) void {
    const thresh = simd.splatInt4(@intCast(threshold));
    var i = start;
    const vend = start + simd.vectorizedEnd(end - start);
    while (i < vend) : (i += simd.lane_count) {
        const tiers = simd.int4(
            @intFromEnum(tier[i]),
            @intFromEnum(tier[i + 1]),
            @intFromEnum(tier[i + 2]),
            @intFromEnum(tier[i + 3]),
        );
        const keep = simd.greaterThanInt4(tiers, thresh);
        inline for (0..simd.lane_count) |lane| {
            if (keep[lane]) {
                out.appendAssumeCapacity(@intCast(i + lane));
            } else {
                any_excluded.* = true;
            }
        }
    }
    while (i < end) : (i += 1) {
        if (@intFromEnum(tier[i]) > threshold) {
            out.appendAssumeCapacity(@intCast(i));
        } else {
            any_excluded.* = true;
        }
    }
}

/// Vectorized tier-policy scan over a contiguous entity range: computes each
/// entity's cube LOD distance and target tier four lanes at a time (chebyshev
/// chunk distance floored by the per-level penalty, then the `tierForChunkDistance`
/// band ladder via masked selects), then emits a set_simulation_tier command for
/// every non-pinned entity whose current tier differs. Shared by the serial core
/// and the threaded job so both stay SIMD; the scalar tail mirrors the scalar
/// `lodDistance`/`tierForChunkDistance` exactly.
fn scanTierPolicy(
    scope: ConstScopeColumnsSlice,
    region: ActiveRegion,
    start: usize,
    end: usize,
    out: *std.ArrayList(StructuralCommand),
) void {
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
    const tier_cognition = simd.splatInt4(@intCast(@intFromEnum(SimulationTier.cognition)));
    const tier_locomotion = simd.splatInt4(@intCast(@intFromEnum(SimulationTier.locomotion)));
    const tier_kinematic = simd.splatInt4(@intCast(@intFromEnum(SimulationTier.kinematic)));
    const tier_dormant = simd.splatInt4(@intCast(@intFromEnum(SimulationTier.dormant)));

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
        // Band ladder: start nearest, demote one band per crossed threshold. Since
        // the halos are monotonic, the farthest crossed threshold wins per lane.
        var tier = tier_cognition;
        tier = simd.selectInt4(simd.greaterThanInt4(distance, cog), tier_locomotion, tier);
        tier = simd.selectInt4(simd.greaterThanInt4(distance, loco), tier_kinematic, tier);
        tier = simd.selectInt4(simd.greaterThanInt4(distance, kin), tier_dormant, tier);
        inline for (0..simd.lane_count) |lane| {
            const idx = i + lane;
            const correct_tier: SimulationTier = @enumFromInt(tier[lane]);
            if (!scope.always_active[idx] and scope.tier[idx] != correct_tier) {
                out.appendAssumeCapacity(.{ .set_simulation_tier = .{ .entity = scope.entities[idx], .tier = correct_tier } });
            }
        }
    }
    while (i < end) : (i += 1) {
        if (scope.always_active[i]) continue;
        const distance = region.lodDistance(.{ .x = scope.chunk_x[i], .y = scope.chunk_y[i] }, scope.level[i]);
        const correct_tier = tierForChunkDistance(distance);
        if (scope.tier[i] != correct_tier) {
            out.appendAssumeCapacity(.{ .set_simulation_tier = .{ .entity = scope.entities[i], .tier = correct_tier } });
        }
    }
}

const CollisionGatherContext = struct {
    data: *const DataSystem,
    bounds_entities: []const EntityId,
    tier: []const SimulationTier,
    ranges: []IndexRangeSlot,
};

fn collisionGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CollisionGatherContext = @ptrCast(@alignCast(context));
    const buffer = &job.ranges[range.index].buffer;
    for (range.start..range.end) |i| {
        const di = job.data.movementBodyDenseIndex(job.bounds_entities[i]) orelse continue;
        if (job.tier[di].allowsCollision()) {
            buffer.indices.appendAssumeCapacity(@intCast(i));
        } else {
            buffer.any_excluded = true;
        }
    }
}

const AiGatherContext = struct {
    data: *const DataSystem,
    ai_entities: []const EntityId,
    scope: ConstScopeColumnsSlice,
    cognition_region: ?ActiveRegion,
    stagger_step: u8,
    ranges: []IndexRangeSlot,
};

fn aiGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiGatherContext = @ptrCast(@alignCast(context));
    const buffer = &job.ranges[range.index].buffer;
    const scope = job.scope;
    for (range.start..range.end) |i| {
        const ent = job.ai_entities[i];
        const di = job.data.movementBodyDenseIndex(ent) orelse continue;
        if (!scope.tier[di].allowsCognition()) continue;
        if (scope.always_active[di]) {
            buffer.indices.appendAssumeCapacity(@intCast(i));
            continue;
        }
        if (job.cognition_region) |region| {
            if (!region.containsChunk(.{ .x = scope.chunk_x[di], .y = scope.chunk_y[di] })) {
                buffer.chunk_filtered += 1;
                continue;
            }
            if (scope.stagger_phase[di] != job.stagger_step) {
                buffer.stagger_skips += 1;
                continue;
            }
        }
        buffer.indices.appendAssumeCapacity(@intCast(i));
    }
}

const TierPolicyContext = struct {
    scope: ConstScopeColumnsSlice,
    region: ActiveRegion,
    ranges: []CommandRangeSlot,
};

fn tierPolicyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *TierPolicyContext = @ptrCast(@alignCast(context));
    const buffer = &job.ranges[range.index].buffer;
    scanTierPolicy(job.scope, job.region, range.start, range.end, &buffer.commands);
}

// ---- Work selection (matches collision/ai selectStageWork) ------------------

const StageWorkSelection = struct {
    profile: AdaptiveWorkProfile,
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
    active_tuner: ?*AdaptiveWorkTuner = null,
};

/// Resolves the pass's owned tuner (when adaptive and no explicit range size) and
/// selects the work shape for this dispatch.
fn selectGatherWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    config: ScopeConfig,
    owned_tuner: *AdaptiveWorkTuner,
) StageWorkSelection {
    const tuner = if (config.adaptive and config.items_per_range == null) owned_tuner else null;
    return selectStageWork(thread_system, item_count, config.items_per_range, config.max_worker_threads, config.adaptive, tuner);
}

fn selectStageWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    items_per_range_override: ?usize,
    max_worker_threads_override: ?usize,
    adaptive: bool,
    adaptive_tuner: ?*AdaptiveWorkTuner,
) StageWorkSelection {
    const available_workers = thread_system.workerThreadCount();
    const max_worker_threads = @min(max_worker_threads_override orelse available_workers, available_workers);
    const requested_items_per_range = items_per_range_override orelse thread_system.config.items_per_range;
    const active_tuner = if (adaptive and items_per_range_override == null and max_worker_threads > 0)
        adaptive_tuner
    else
        null;
    const profile = if (active_tuner) |tuner|
        tuner.selectProfile(.{
            .item_count = item_count,
            .available_worker_threads = available_workers,
            .max_worker_threads = max_worker_threads,
            .fallback_items_per_range = requested_items_per_range,
            .range_alignment_items = scope_range_alignment_items,
        })
    else
        AdaptiveWorkProfile{
            .worker_threads = max_worker_threads,
            .items_per_range = requested_items_per_range,
        };
    const aligned_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), scope_range_alignment_items);
    const selected_range_count = rangeCount(item_count, aligned_items_per_range);
    const selected_worker_threads = if (selected_range_count <= 1)
        @as(usize, 0)
    else
        @min(profile.worker_threads, @min(max_worker_threads, selected_range_count - 1));
    const items_per_range = if (selected_worker_threads == 0 and active_tuner != null and profile.worker_threads == 0)
        item_count
    else
        aligned_items_per_range;

    return .{
        .profile = .{
            .worker_threads = selected_worker_threads,
            .items_per_range = items_per_range,
        },
        .items_per_range = items_per_range,
        .worker_threads = selected_worker_threads,
        .range_count = rangeCount(item_count, items_per_range),
        .active_tuner = active_tuner,
    };
}

fn paddingForCacheLine(comptime T: type) usize {
    const rem = @sizeOf(T) % thread_shared_record_alignment;
    return if (rem == 0) 0 else thread_shared_record_alignment - rem;
}

fn rangeLenForIndex(item_count: usize, items_per_range: usize, range_index: usize) usize {
    const start = range_index * items_per_range;
    if (start >= item_count) return 0;
    return @min(start + items_per_range, item_count) - start;
}

// ---- Tests ------------------------------------------------------------------

test "SimulationScopeSystem movement gather returns null when all non-dormant" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{});
    const e1 = try data.createEntity();
    try data.setMovementBody(e1, .{});

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const result = try sys.gatherMovementBodyIndicesSerial(&data);
    // All .cognition (default) which allowsMovement → full-active shortcut → null
    try std.testing.expect(result == null);
}

test "SimulationScopeSystem movement gather excludes dormant entities" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const mover = try data.createEntity();
    try data.setMovementBody(mover, .{});

    const dormant_ent = try data.createEntity();
    try data.setMovementBody(dormant_ent, .{});
    try data.setSimulationMetadata(dormant_ent, .{ .tier = .dormant });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();

    const result = try sys.gatherMovementBodyIndicesSerial(&data);
    // dormant entity excluded → non-null filtered list with 1 entry (dense index 0)
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqual(@as(u32, 0), result.?[0]);
}

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
    const indices = try sys.gatherAiAgentIndicesSerial(&data, region, 0);

    try std.testing.expectEqual(@as(usize, 1), indices.len);
    try std.testing.expectEqual(@as(usize, 1), sys.chunk_filtered_entities);
    try std.testing.expectEqual(@as(usize, 0), sys.stagger_skips);
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
    const indices = try sys.gatherAiAgentIndicesSerial(&data, region, 1);
    try std.testing.expectEqual(@as(usize, 0), indices.len);
    try std.testing.expectEqual(@as(usize, 1), sys.stagger_skips);
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
    const indices = try sys.gatherAiAgentIndicesSerial(&data, region, 0);
    try std.testing.expectEqual(@as(usize, 1), indices.len);
    try std.testing.expectEqual(@as(usize, 0), sys.chunk_filtered_entities);
    try std.testing.expectEqual(@as(usize, 0), sys.stagger_skips);
}

test "collectChunkTierChanges assigns all four LOD tiers by distance band" {
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

    var out: std.ArrayList(StructuralCommand) = .empty;
    defer out.deinit(allocator);

    const visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 });
    try SimulationScopeSystem.collectChunkTierChanges(&data, visible, &out, allocator);

    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    const expected = [_]struct { e: @TypeOf(to_cog), t: SimulationTier }{
        .{ .e = to_cog, .t = .cognition },
        .{ .e = to_loco, .t = .locomotion },
        .{ .e = to_kine, .t = .kinematic },
        .{ .e = to_dorm, .t = .dormant },
    };
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp.e, out.items[i].set_simulation_tier.entity);
        try std.testing.expectEqual(exp.t, out.items[i].set_simulation_tier.tier);
    }
}

test "collectChunkTierChanges demotes off-level entities by the cube distance" {
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

    var out: std.ArrayList(StructuralCommand) = .empty;
    defer out.deinit(allocator);

    var visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 });
    visible.level = 0;
    try SimulationScopeSystem.collectChunkTierChanges(&data, visible, &out, allocator);

    // Only the off-level entity emits a command, and it leaves cognition.
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(off_level, out.items[0].set_simulation_tier.entity);
    try std.testing.expect(out.items[0].set_simulation_tier.tier != .cognition);
}

test "collectChunkTierChanges is a no-op without a visible region" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();

    const e = try data.createEntity();
    try data.setMovementBody(e, .{});
    try data.setSimulationMetadata(e, .{ .tier = .cognition, .chunk = .{ .x = 99, .y = 99 } });

    var out: std.ArrayList(StructuralCommand) = .empty;
    defer out.deinit(allocator);

    try SimulationScopeSystem.collectChunkTierChanges(&data, null, &out, allocator);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "scoped movement integrates only non-dormant rows and derives chunk in-pass" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const movement = @import("movement.zig");
    const WorldSystem = @import("../world_system.zig").WorldSystem;

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var data = DataSystem.init(allocator);
    defer data.deinit();
    const a = try data.createEntity(); // dense 0
    try data.setMovementBody(a, .{ .position = .{ .x = 300, .y = 100 }, .velocity = .{ .x = 64, .y = 0 } });
    const frozen = try data.createEntity(); // dense 1
    try data.setMovementBody(frozen, .{ .position = .{ .x = 500, .y = 200 }, .velocity = .{ .x = 64, .y = 0 } });
    try data.setSimulationTier(frozen, .dormant);
    const b = try data.createEntity(); // dense 2
    try data.setMovementBody(b, .{ .position = .{ .x = 700, .y = 260 }, .velocity = .{ .x = -32, .y = 16 } });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const indices = try sys.gatherMovementBodyIndicesSerial(&data);
    try std.testing.expect(indices != null); // a dormant entity is present
    try std.testing.expectEqual(@as(usize, 2), indices.?.len);

    const tile_size: f32 = 32;
    const chunk_size: u16 = 8;
    const dims: u16 = 64;
    const scope = data.scopeColumnsSlice();
    var slice = data.movementBodySlice();
    var ms = movement.MovementSystem.init();
    const dt: f32 = 0.5;
    _ = ms.update(&slice, &threads, dt, .{
        .scope_dense_indices = indices,
        .chunk_grid = .{
            .chunk_x = scope.chunk_x,
            .chunk_y = scope.chunk_y,
            .tile_size = tile_size,
            .chunk_size_tiles = chunk_size,
            .width = dims,
            .height = dims,
        },
    });

    // Dormant row never integrated (frozen position preserved exactly).
    try std.testing.expectEqual(@as(f32, 500), data.movementBodyConst(frozen).?.position.x);

    // Running rows integrated pos + vel*dt (exact for these inputs, so this also
    // pins the indexed scalar path to the same arithmetic as the full SIMD path).
    const a_body = data.movementBodyConst(a).?;
    const b_body = data.movementBodyConst(b).?;
    try std.testing.expectEqual(@as(f32, 300 + 64 * 0.5), a_body.position.x);
    try std.testing.expectEqual(@as(f32, 700 - 32 * 0.5), b_body.position.x);

    // Folded chunk for the integrated rows matches the canonical world formula.
    var world = WorldSystem{ .allocator = allocator, .width = dims, .height = dims, .tile_size = tile_size, .chunk_size_tiles = chunk_size };
    defer world.deinit();
    inline for (.{ a, b }) |ent| {
        const body = data.movementBodyConst(ent).?;
        const meta = data.simulationMetadata(ent).?;
        const expect = world.chunkCoordForWorldPos(body.position.x, body.position.y);
        try std.testing.expectEqual(expect.x, meta.chunk.x);
        try std.testing.expectEqual(expect.y, meta.chunk.y);
    }
}

test "indexed movement path matches scalar reference across the SIMD block and tail" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const movement = @import("movement.zig");

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var data = DataSystem.init(allocator);
    defer data.deinit();

    // Nine bodies with the odd dense rows dormant, so the movement gather yields
    // five non-contiguous indices (0,2,4,6,8): four run through the 4-lane
    // gather/scatter block, the fifth through the scalar tail. Values are f32-exact
    // so the indexed result must equal the hand-computed scalar reference exactly.
    const Spawn = struct { x: f32, y: f32, vx: f32, vy: f32, dormant: bool };
    const spawns = [_]Spawn{
        .{ .x = 10, .y = 20, .vx = 4, .vy = -2, .dormant = false },
        .{ .x = 30, .y = 40, .vx = 8, .vy = 8, .dormant = true },
        .{ .x = 50, .y = 60, .vx = -6, .vy = 2, .dormant = false },
        .{ .x = 70, .y = 80, .vx = 16, .vy = -16, .dormant = true },
        .{ .x = 90, .y = 100, .vx = 2, .vy = 6, .dormant = false },
        .{ .x = 110, .y = 120, .vx = -32, .vy = 4, .dormant = true },
        .{ .x = 130, .y = 140, .vx = 12, .vy = -8, .dormant = false },
        .{ .x = 150, .y = 160, .vx = 24, .vy = 24, .dormant = true },
        .{ .x = 170, .y = 180, .vx = -4, .vy = 10, .dormant = false },
    };
    var ents: [spawns.len]EntityId = undefined;
    for (spawns, 0..) |s, i| {
        ents[i] = try data.createEntity();
        try data.setMovementBody(ents[i], .{ .position = .{ .x = s.x, .y = s.y }, .velocity = .{ .x = s.vx, .y = s.vy } });
        if (s.dormant) try data.setSimulationTier(ents[i], .dormant);
    }

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const indices = try sys.gatherMovementBodyIndicesSerial(&data);
    try std.testing.expect(indices != null);
    try std.testing.expectEqual(@as(usize, 5), indices.?.len); // > 4-lane block → block + tail

    var slice = data.movementBodySlice();
    var ms = movement.MovementSystem.init();
    const dt: f32 = 0.25;
    _ = ms.update(&slice, &threads, dt, .{ .scope_dense_indices = indices });

    const after = data.movementBodySliceConst();
    for (spawns, 0..) |s, i| {
        if (s.dormant) {
            // Excluded from the index set: position left untouched.
            try std.testing.expectEqual(s.x, after.position_x[i]);
            try std.testing.expectEqual(s.y, after.position_y[i]);
        } else {
            // Indexed path scatters next into position and old into previous,
            // per lane and per column — matches the scalar reference exactly.
            try std.testing.expectEqual(s.x + s.vx * dt, after.position_x[i]);
            try std.testing.expectEqual(s.y + s.vy * dt, after.position_y[i]);
            try std.testing.expectEqual(s.x, after.previous_x[i]);
            try std.testing.expectEqual(s.y, after.previous_y[i]);
        }
    }
}

test "scoped collision excludes kinematic and dormant bodies from contacts" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    const indices = try sys.gatherCollisionBoundsIndicesSerial(&data);
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
    try data.setAiAgent(selected, .{ .behavior = .wander });
    try data.setSimulationMetadata(selected, .{ .tier = .cognition, .chunk = .{ .x = 1, .y = 1 }, .stagger_phase = 0 });

    const out_of_halo = try data.createEntity();
    try data.setMovementBody(out_of_halo, .{ .position = .{ .x = 200, .y = 100 }, .speed = 40 });
    try data.setAiAgent(out_of_halo, .{ .behavior = .wander });
    try data.setSimulationMetadata(out_of_halo, .{ .tier = .cognition, .chunk = .{ .x = 30, .y = 30 }, .stagger_phase = 0 });

    const wrong_phase = try data.createEntity();
    try data.setMovementBody(wrong_phase, .{ .position = .{ .x = 120, .y = 120 }, .speed = 40 });
    try data.setAiAgent(wrong_phase, .{ .behavior = .wander });
    try data.setSimulationMetadata(wrong_phase, .{ .tier = .cognition, .chunk = .{ .x = 1, .y = 1 }, .stagger_phase = 1 });

    var sys = SimulationScopeSystem.init(allocator);
    defer sys.deinit();
    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const indices = try sys.gatherAiAgentIndicesSerial(&data, region, sys.staggerStep());

    // Only the in-halo, phase-0 agent survives the gather at step 0.
    try std.testing.expectEqual(@as(usize, 1), indices.len);
    try std.testing.expectEqual(@as(usize, 1), sys.chunk_filtered_entities);
    try std.testing.expectEqual(@as(usize, 1), sys.stagger_skips);

    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    frame.beginStep();

    var ai_sys = ai.AiSystem.init(allocator);
    defer ai_sys.deinit();
    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();
    _ = try ai_sys.updateSerial(ai_slice, movement_slice, &data, &frame, 0.016, .{ .scope_dense_indices = indices });

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
    try sys.queueTierChangesSerial(&data, region, &stream);

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
    try sys.queueTierChangesSerial(&data, visible, &stream);

    const merged = stream.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqual(sleeper.index, merged[0].set_simulation_tier.entity.index);
    try std.testing.expectEqual(SimulationTier.dormant, merged[0].set_simulation_tier.tier);

    // Idempotent: applying the command then re-running yields no new command.
    try data.setSimulationTier(sleeper, .dormant);
    var stream2 = RangeOutputStream(StructuralCommand).init(allocator);
    defer stream2.deinit();
    try sys.queueTierChangesSerial(&data, visible, &stream2);
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
        try data.setAiAgent(e, .{ .behavior = if (index % 2 == 0) .seek else .wander });
        // Levels 0–4 fan the cube distance across all four tiers (level 4 reaches the
        // dormant band), so the movement/collision gathers leave the full-active fast
        // path and actually scan, and the AI gather/tier policy see real work.
        const level: u16 = @intCast(index % 5);
        const region = ActiveRegion{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 2, .y = 8 }, .level = 0 };
        const tier = tierForChunkDistance(region.lodDistance(.{ .x = chunk_x, .y = 0 }, level));
        try data.setSimulationMetadata(e, .{ .tier = tier, .chunk = .{ .x = chunk_x, .y = 0 }, .level = level, .stagger_phase = @intCast(index % cognition_stagger_n) });
    }
}

test "threaded movement gather matches serial" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillParityPopulation(&data, scope_range_alignment_items * 6);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    const serial = (try serial_sys.gatherMovementBodyIndicesSerial(&data)).?;
    const threaded = (try threaded_sys.gatherMovementBodyIndices(&data, &threads, .{})).indices.?;
    try std.testing.expectEqualSlices(u32, serial, threaded);
}

test "threaded ai gather matches serial including diagnostics" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    try fillParityPopulation(&data, scope_range_alignment_items * 6);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 });
    const serial = try serial_sys.gatherAiAgentIndicesSerial(&data, region, 0);
    const threaded = (try threaded_sys.gatherAiAgentIndices(&data, region, 0, &threads, .{})).indices;
    try std.testing.expectEqualSlices(u32, serial, threaded);
    try std.testing.expectEqual(serial_sys.stagger_skips, threaded_sys.stagger_skips);
    try std.testing.expectEqual(serial_sys.chunk_filtered_entities, threaded_sys.chunk_filtered_entities);
}

test "threaded tier policy matches serial" {
    if (builtin.single_threaded) return error.SkipZigTest;
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

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    var visible = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    visible.level = 0;

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var serial_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer serial_stream.deinit();
    try serial_sys.queueTierChangesSerial(&data, visible, &serial_stream);

    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();
    var threaded_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer threaded_stream.deinit();
    _ = try threaded_sys.queueTierChanges(&data, visible, &threaded_stream, &threads, .{});

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
    if (builtin.single_threaded) return error.SkipZigTest;
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
        try data.setAiAgent(e, .{ .behavior = if (index % 2 == 0) .seek else .wander });
        try data.setSimulationMetadata(e, .{ .tier = @enumFromInt(index % 4), .chunk = .{ .x = @intCast(index % 20), .y = 0 }, .level = @intCast(index % 5), .stagger_phase = @intCast(index % cognition_stagger_n) });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = scope_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 8 });
    const fixed = ScopeConfig{ .items_per_range = scope_range_alignment_items, .max_worker_threads = 2, .adaptive = false };

    var serial_sys = SimulationScopeSystem.init(allocator);
    defer serial_sys.deinit();
    var threaded_sys = SimulationScopeSystem.init(allocator);
    defer threaded_sys.deinit();

    // Movement gather.
    const move_serial = (try serial_sys.gatherMovementBodyIndicesSerial(&data)).?;
    const move_threaded = (try threaded_sys.gatherMovementBodyIndices(&data, &threads, fixed)).indices.?;
    try std.testing.expectEqualSlices(u32, move_serial, move_threaded);

    // Collision gather.
    const col_serial = (try serial_sys.gatherCollisionBoundsIndicesSerial(&data)).?;
    const col_threaded = (try threaded_sys.gatherCollisionBoundsIndices(&data, &threads, fixed)).indices.?;
    try std.testing.expectEqualSlices(u32, col_serial, col_threaded);

    // AI gather (with diagnostics).
    const ai_serial = try serial_sys.gatherAiAgentIndicesSerial(&data, region, 0);
    const ai_threaded = (try threaded_sys.gatherAiAgentIndices(&data, region, 0, &threads, fixed)).indices;
    try std.testing.expectEqualSlices(u32, ai_serial, ai_threaded);
    try std.testing.expectEqual(serial_sys.stagger_skips, threaded_sys.stagger_skips);
    try std.testing.expectEqual(serial_sys.chunk_filtered_entities, threaded_sys.chunk_filtered_entities);

    // Tier policy (variable-output producer, dense output).
    var visible = region;
    visible.level = 0;
    var serial_stream = RangeOutputStream(StructuralCommand).init(allocator);
    defer serial_stream.deinit();
    try serial_sys.queueTierChangesSerial(&data, visible, &serial_stream);
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

test "thread-written scope range scratch uses cache-line sized slots" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(IndexRangeSlot) % thread_shared_record_alignment);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(CommandRangeSlot) % thread_shared_record_alignment);
}
