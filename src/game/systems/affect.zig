// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Emotion-drive appraisal processor: for every cognition-scoped agent that
//! carries `AiAffect`, appraises this step's `AiPerception`/`AiMemory` state
//! (both optional per row — a missing component contributes no signal, it
//! never excludes the row) plus its own `AiAgent.active_behavior` into four
//! independent drives (fear, curiosity, aggression, fatigue), decays each
//! toward its own per-entity baseline, and emits a threshold-crossing event
//! on a rising or falling edge. A true Schmitt trigger (each drive's bit in
//! `AiAffect.above_threshold_mask`, persisted across steps) gates the edges,
//! so a value hovering at threshold cannot refire the same edge twice. Runs
//! after perception and ai_memory (both must have written this step's state
//! first) and before AI reads it — arbitration (`arbitration.zig`)
//! reads the resulting drives one stage later via `AiConfig.affect_slice`;
//! this system only appraises and decays them, it never switches behavior
//! itself.
//!
//! Gather mirrors ai_memory.zig/perception.zig's population-domain shape:
//! walk scope_dense_indices (or every ai_agents row), keeping rows that carry
//! both AiAgent and AiAffect. Unlike ai_memory.zig, AiPerception and AiMemory
//! are each independently optional here, so gather resolves them with
//! `orelse` and packs a "no signal" default rather than skipping the row.
//! This packs a contiguous per-row scratch table (entity, this row's own
//! AiAffectStore index, and the raw signal values needed by the delta
//! formulas below) — the same gather-into-packed-scratch idiom
//! perception.zig's PerceptionGatherRow uses to turn a branchy,
//! optional-component gather into a dense array that a later vectorized pass
//! can read with plain contiguous loads.
//!
//! The compute pass vectorizes across ROWS (four scattered rows per lane
//! group), one drive-column pass at a time — the same shape ai_memory.zig's
//! processDecayRange uses for its own staleness/familiarity columns (gather
//! this row's own baseline/decay_rate/threshold/current value via
//! simd.gatherFloat4, indexed by the row's own AiAffectStore index; never a
//! splatted global constant). Each drive's delta is computed from the packed
//! scratch columns with plain vector ops, added to the current value, decayed
//! toward baseline via simd.lerpFloat4, clamped to [0, 1], and scattered back.
//! The threshold-crossing check runs scalarly per lane afterward (mirrors
//! ai_memory.zig's ageRingForRow: a vectorized combine followed by a small
//! branchy per-lane remainder), reading and updating this row's persisted
//! above_threshold_mask bit for the drive: rising fires when the bit is clear
//! and the new value reaches threshold; falling fires when the bit is set and
//! the new value drops below threshold - ai_affect_threshold_hysteresis. A
//! scalar tail repeats the same math for the remainder.
//!
//! Event emission: workers only mark each row's per-drive
//! "crossed"/"rising" bits in the gather rows' `crossing_bits` column; after
//! the join the main thread popcounts the column, applies this system's own
//! per-step cap, and emits the crossings in (gather row, drive declaration)
//! order as one range (`AffectSystem.emitCrossingEvents`). That order is fixed
//! by construction, so it is partition-independent with no event scratch and
//! no sort. Up to four events can fire per row per step (one per independent
//! drive) rather than perception's two-per-row swap cap.
//!
//! Deliberately deferred: fear and aggression share the same visible-hostile
//! signal but use independent gain constants and are never cross-coupled;
//! there is no cross-drive modulation of any kind within this system --
//! arbitration.zig is the sole consumer that weighs drives against each
//! other (and against behaviors), and it does so downstream, over this
//! system's already-independent output.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const logging = @import("../../core/logging.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BatchSelection = @import("../../app/thread_system.zig").BatchSelection;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const AiBehavior = @import("../data_system.zig").AiBehavior;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const AiAffectSlice = @import("../data_system.zig").AiAffectSlice;
const AiAffectDrive = @import("../data_system.zig").AiAffectDrive;
const ai_affect_threshold_hysteresis = @import("../data_system.zig").ai_affect_threshold_hysteresis;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const SimulationEvent = @import("../simulation.zig").SimulationEvent;
const SimulationEvents = @import("../simulation.zig").SimulationEvents;
const affect_events_per_row_max = @import("../simulation.zig").affect_events_per_row_max;

pub const affect_range_alignment_items: usize = movement_range_alignment_items;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, affect_range_alignment_items);
}

const default_max_events_per_step: usize = 512;

// Small gains: a single step's exposure cannot alone drive a resting-baseline
// drive to 1 -- repeated exposure across several steps, net of the per-step
// decay toward baseline, is what actually pushes a drive past its threshold.
const gain_fear: f32 = 0.15;
const gain_aggression: f32 = 0.1;
const gain_curiosity_hearing: f32 = 0.2;
const gain_curiosity_novelty: f32 = 0.05;
const gain_fatigue: f32 = 0.05;

// "No signal" defaults packed for a row missing the optional component: a
// visible_f of 0 already gates the fear/aggression delta to zero regardless
// of dist/vision_range, so these two only need to avoid a stray div-by-zero.
const no_perception_dist: f32 = std.math.inf(f32);
const no_perception_vision_range: f32 = 1.0;
// A memory-less row is treated as fully familiar (no novelty contribution),
// not maximally curious.
const no_memory_familiarity: f32 = 1.0;

pub const AffectConfig = struct {
    /// When non-null, only these dense ai-store indices participate this step
    /// (the scope system's think set: halo ∩ stagger). Null = all agents.
    /// Mirrors AiMemoryConfig/PerceptionConfig.scope_dense_indices.
    scope_dense_indices: ?[]const u32 = null,
    /// Deterministic per-step cap on emitted threshold-crossing events,
    /// enforced by this system itself (mirrors PerceptionConfig).
    max_events_per_step: usize = default_max_events_per_step,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const AffectStats = struct {
    processed_count: usize = 0,
    threshold_crossed_count: usize = 0,
    batch: BatchStats = .{},
};

// Packed, contiguous per-row gather scratch (mirrors PerceptionGatherRow):
// resolved once per row during the branchy gather pass, then read by the
// vectorized compute pass with plain contiguous loads. `crossing_bits` is the
// one column the workers write.
const AffectGatherRow = struct {
    entity: EntityId,
    // This row's own index into DataSystem.ai_affects -- scattered, gathered
    // via simd.gatherFloat4/scatterFloat4 in the compute pass.
    affect_dense_index: u32,
    target_visible_f: f32,
    nearest_threat_dist: f32,
    vision_range: f32,
    heard_stimulus_f: f32,
    familiarity: f32,
    behavior_exertion_f: f32,
    // This step's threshold crossings for the row: bits 0..3 "crossed" and
    // bits 4..7 "rising" per drive (`crossedBit`/`risingBit`), zeroed by the
    // gather and set by the row's range job. u32 rather than u8 so a 16-row
    // aligned range spans 64 bytes of the column: neighbouring ranges share
    // at most a boundary line, the same posture as perception's 4-byte
    // `final_nearest_threat_*` columns (a u8 column would put four ranges on
    // one line).
    crossing_bits: u32,
};

// A crossed and a rising bit per drive must fit the row word; widen
// `crossing_bits` before the drive count passes 16.
comptime {
    std.debug.assert(2 * affect_events_per_row_max <= @bitSizeOf(u32));
}

/// Low `affect_events_per_row_max` bits of `crossing_bits`: one "crossed this
/// step" bit per drive.
const crossed_mask: u32 = (@as(u32, 1) << affect_events_per_row_max) - 1;

/// "Crossed this step" bit for `drive` in `crossing_bits`, keyed by
/// declaration order (fear, curiosity, aggression, fatigue).
fn crossedBit(drive: AiAffectDrive) u32 {
    return @as(u32, 1) << @intCast(@backingInt(drive));
}

/// "Rising edge" bit for `drive` in `crossing_bits` (meaningful only with its
/// `crossedBit` set; clear = falling).
fn risingBit(drive: AiAffectDrive) u32 {
    return crossedBit(drive) << affect_events_per_row_max;
}

fn appendAffectGatherRow(
    rows: *std.MultiArrayList(AffectGatherRow),
    row_slice: *std.MultiArrayList(AffectGatherRow).Slice,
    row: AffectGatherRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

fn serialBatch(count: usize) BatchStats {
    return .{ .ran_inline = true, .item_count = count, .range_count = if (count > 0) 1 else 0, .items_per_range = count };
}

pub const AffectSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only; workers read only copies in
    // job context, except their own rows' `crossing_bits`).
    rows: std.MultiArrayList(AffectGatherRow) = .{},
    /// Once-only flag for the emit-cap drop warn. The pipeline's derived share makes a
    /// drop impossible by construction; the cap and `dropped_events` stay as the
    /// shared-frame safety net.
    dropped_events_warned: bool = false,
    compute_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    /// Sizes the gather rows (including the per-row crossing bits) for `pop`
    /// agents; no partition-sized scratch exists, so `update`/`updateSerial`
    /// allocate nothing after this under any `items_per_range`. Grow-only;
    /// re-run by the pipeline's population seam.
    pub fn reserve(self: *AffectSystem, pop: usize) !void {
        if (pop == 0) return;
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(pop));
    }

    pub fn init(allocator: std.mem.Allocator) AffectSystem {
        return .{
            .allocator = allocator,
            .compute_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *AffectSystem) void {
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *AffectSystem,
        ai_agents: ConstAiAgentSlice,
        data: *DataSystem,
        events: *SimulationEvents,
        thread_system: *ThreadSystem,
        config: AffectConfig,
    ) !AffectStats {
        try self.gatherScopedIndices(ai_agents, data, config.scope_dense_indices);
        const count = self.rows.len;
        if (count == 0) return .{};

        const active_tuner: ?*AdaptiveWorkTuner = config.adaptive_tuner orelse
            if (config.adaptive and config.items_per_range == null) &self.compute_tuner else null;
        const selection = selectStageWork(
            thread_system,
            count,
            config.items_per_range,
            config.max_worker_threads,
            config.adaptive,
            active_tuner,
        );
        var job = self.buildJobContext(data, selection.range_count);
        const batch = thread_system.parallelForWithOptions(count, &job, affectRangeJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = affect_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        const merge = try self.emitCrossingEvents(events, config.max_events_per_step);
        return .{
            .processed_count = count,
            .threshold_crossed_count = merge.crossed,
            .batch = batch,
        };
    }

    pub fn updateSerial(
        self: *AffectSystem,
        ai_agents: ConstAiAgentSlice,
        data: *DataSystem,
        events: *SimulationEvents,
        config: AffectConfig,
    ) !AffectStats {
        try self.gatherScopedIndices(ai_agents, data, config.scope_dense_indices);
        const count = self.rows.len;
        if (count == 0) return .{};

        const range_count: usize = 1;
        var job = self.buildJobContext(data, range_count);
        processAffectRange(&job, .{ .index = 0, .start = 0, .end = count });

        const merge = try self.emitCrossingEvents(events, config.max_events_per_step);
        return .{
            .processed_count = count,
            .threshold_crossed_count = merge.crossed,
            .batch = serialBatch(count),
        };
    }

    fn buildJobContext(self: *AffectSystem, data: *DataSystem, range_count: usize) AffectJobContext {
        const rows = self.rows.slice();
        return .{
            .entities = rows.items(.entity),
            .affect_dense_index = rows.items(.affect_dense_index),
            .target_visible_f = rows.items(.target_visible_f),
            .nearest_threat_dist = rows.items(.nearest_threat_dist),
            .vision_range = rows.items(.vision_range),
            .heard_stimulus_f = rows.items(.heard_stimulus_f),
            .familiarity = rows.items(.familiarity),
            .behavior_exertion_f = rows.items(.behavior_exertion_f),
            .crossing_bits = rows.items(.crossing_bits),
            .affect_slice = data.aiAffectSlice(),
            .range_count = range_count,
        };
    }

    // Population-domain contract with ai_memory.zig/perception.zig: walks
    // scope_dense_indices (or every ai agent), keeping only rows that carry
    // both AiAgent and AiAffect. AiPerception/AiMemory are each resolved with
    // `orelse` -- a missing one packs a "no signal" default rather than
    // excluding the row, since fatigue's own input (AiAgent.active_behavior) needs
    // neither.
    fn gatherScopedIndices(
        self: *AffectSystem,
        ai_agents: ConstAiAgentSlice,
        data: *const DataSystem,
        scope_dense_indices: ?[]const u32,
    ) !void {
        self.rows.clearRetainingCapacity();
        const n = if (scope_dense_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return;
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));

        const perception_slice = data.aiPerceptionSliceConst();
        const memory_slice = data.aiMemorySliceConst();

        var row_slice = self.rows.slice();
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (scope_dense_indices) |idx| idx[k] else k;
            const ent = ai_agents.entities[i];
            const affect_index = data.aiAffectDenseIndex(ent) orelse continue;

            var target_visible_f: f32 = 0;
            var nearest_threat_dist: f32 = no_perception_dist;
            var vision_range: f32 = no_perception_vision_range;
            var heard_stimulus_f: f32 = 0;
            if (data.aiPerceptionDenseIndex(ent)) |perception_index| {
                target_visible_f = if (perception_slice.target_visible[perception_index]) 1 else 0;
                nearest_threat_dist = perception_slice.nearest_threat_dist[perception_index];
                vision_range = perception_slice.vision_range[perception_index];
                heard_stimulus_f = if (perception_slice.heard_stimulus[perception_index]) 1 else 0;
            }

            var familiarity: f32 = no_memory_familiarity;
            if (data.aiMemoryDenseIndex(ent)) |memory_index| {
                familiarity = memory_slice.familiarity[memory_index];
            }

            appendAffectGatherRow(&self.rows, &row_slice, .{
                .entity = ent,
                .affect_dense_index = @intCast(affect_index),
                .target_visible_f = target_visible_f,
                .nearest_threat_dist = nearest_threat_dist,
                .vision_range = vision_range,
                .heard_stimulus_f = heard_stimulus_f,
                .familiarity = familiarity,
                .behavior_exertion_f = if (ai_agents.behaviors[i] == .pursue or ai_agents.behaviors[i] == .flee) 1 else 0,
                .crossing_bits = 0,
            });
        }
    }

    /// Main-thread crossing emit after the parallel/serial compute pass:
    /// popcounts the "crossed" bits of every row's
    /// `crossing_bits` for the uncapped total, applies this system's own
    /// deterministic per-step cap (truncating the tail rather than letting
    /// `SimulationEvents`'s own capacity check throw), then writes the first
    /// `max_events_per_step` crossings in (gather row, drive declaration)
    /// order as one range. The order is fixed by construction, independent of
    /// the partition, so there is no event scratch and no sort.
    fn emitCrossingEvents(
        self: *AffectSystem,
        events: *SimulationEvents,
        max_events_per_step: usize,
    ) !AffectEventMergeResult {
        const rows = self.rows.slice();
        const crossing_bits = rows.items(.crossing_bits);
        const entities = rows.items(.entity);

        var total: usize = 0;
        for (crossing_bits) |bits| total += @popCount(bits & crossed_mask);
        const crossed = @min(total, max_events_per_step);
        const dropped = total - crossed;

        const first_range = try events.appendRangeCounts(1);
        events.addCount(first_range, crossed);
        try events.prefixAppendedRanges(first_range);

        var writer = events.rangeWriter(first_range);
        var remaining = crossed;
        if (remaining > 0) {
            emit: for (crossing_bits, entities) |bits, entity| {
                if ((bits & crossed_mask) == 0) continue;
                inline for (comptime std.enums.values(AiAffectDrive)) |drive| {
                    if ((bits & crossedBit(drive)) != 0) {
                        writer.write(.{ .stage = .domain_reaction, .payload = .{ .affect_threshold_crossed = .{
                            .entity = entity,
                            .drive = drive,
                            .rising = (bits & risingBit(drive)) != 0,
                        } } });
                        remaining -= 1;
                        if (remaining == 0) break :emit;
                    }
                }
            }
        }
        // Declared count == written count: the popcount and this pass read
        // the same column (`RangeWriter.finish` asserts it).
        writer.finish();
        events.finishWrite();
        events.stats.dropped += dropped;
        if (dropped > 0 and !self.dropped_events_warned) {
            self.dropped_events_warned = true;
            if (comptime logging.enabled(.warn) and !builtin.is_test) logging.game.warn(
                "affect: {d} threshold crossings dropped past the per-step share of {d}",
                .{ dropped, max_events_per_step },
            );
        }

        return .{ .crossed = crossed, .dropped = dropped };
    }
};

const AffectEventMergeResult = struct {
    crossed: usize,
    dropped: usize,
};

const AffectJobContext = struct {
    entities: []const EntityId,
    affect_dense_index: []const u32,
    target_visible_f: []const f32,
    nearest_threat_dist: []const f32,
    vision_range: []const f32,
    heard_stimulus_f: []const f32,
    familiarity: []const f32,
    behavior_exertion_f: []const f32,
    crossing_bits: []u32,
    affect_slice: AiAffectSlice,
    range_count: usize,
};

fn affectRangeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AffectJobContext = @ptrCast(@alignCast(context));
    processAffectRange(job, range);
}

/// Shared serial/threaded per-range compute function: one vectorized pass per
/// drive column (fear, aggression, curiosity, fatigue), each over the same
/// row range. Order across the four passes does not matter: the drives are
/// independent and each pass only ORs its own drive's bits into the range's
/// rows' `crossing_bits` (the passes run sequentially within one range, so the
/// row words are single-writer). Event order is decided later, by row, in
/// `AffectSystem.emitCrossingEvents`.
fn processAffectRange(job: *AffectJobContext, range: ParallelRange) void {
    // Dual worker asserts: range.index vs dispatched range count AND
    // range.end vs the row columns this job writes.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.entities.len);
    std.debug.assert(range.end <= job.crossing_bits.len);
    processFearColumn(job, range);
    processAggressionColumn(job, range);
    processCuriosityColumn(job, range);
    processFatigueColumn(job, range);
}

/// prev + delta, decayed toward baseline, clamped to [0, 1]. Shared by every
/// drive's vectorized combine step.
fn combineDrive(prev: simd.Float4, delta: simd.Float4, baseline: simd.Float4, decay_rate: simd.Float4) simd.Float4 {
    const raw = simd.addFloat4(prev, delta);
    const decayed = simd.lerpFloat4(raw, baseline, decay_rate);
    return simd.clampFloat4(decayed, simd.splatFloat4(0), simd.splatFloat4(1));
}

fn combineDriveScalar(prev: f32, delta: f32, baseline: f32, decay_rate: f32) f32 {
    const raw = prev + delta;
    const decayed = math.lerp(raw, baseline, decay_rate);
    return math.clamp(decayed, 0, 1);
}

/// One bit per AiAffectDrive tag, keyed by its declaration order (fear = bit
/// 0, curiosity = bit 1, aggression = bit 2, fatigue = bit 3).
fn driveBit(drive: AiAffectDrive) u8 {
    return @as(u8, 1) << @intCast(@backingInt(drive));
}

/// True Schmitt trigger over `above_threshold.*`'s persisted per-drive bit
/// (this row's AiAffect.above_threshold_mask), not a stateless comparison
/// against this step's previous value -- a value that crosses threshold
/// upward, dips back down without ever leaving the hysteresis band (falling
/// below threshold - ai_affect_threshold_hysteresis), then crosses threshold
/// upward again, cannot refire: the bit is already set, so the rising
/// branch's "was not above" guard fails. Rising: bit clear and final >=
/// threshold (sets the bit). Falling: bit set and final < threshold -
/// ai_affect_threshold_hysteresis (clears the bit). Any other case leaves the
/// bit and returns null.
fn checkThresholdCrossing(above_threshold: *u8, bit: u8, final: f32, threshold: f32) ?bool {
    const was_above = (above_threshold.* & bit) != 0;
    if (!was_above and final >= threshold) {
        above_threshold.* |= bit;
        return true;
    }
    if (was_above and final < threshold - ai_affect_threshold_hysteresis) {
        above_threshold.* &= ~bit;
        return false;
    }
    return null;
}

/// dist/vision_range gate shared by fear and aggression: closer visible
/// hostile -> larger ratio, clamped so an absent/zero-range row degrades to
/// zero rather than a negative or unbounded value.
fn visibilityRatio(dist: simd.Float4, vision_range: simd.Float4) simd.Float4 {
    const one = simd.splatFloat4(1);
    const zero = simd.splatFloat4(0);
    return simd.clampFloat4(simd.subFloat4(one, simd.divFloat4(dist, vision_range)), zero, one);
}

fn visibilityRatioScalar(dist: f32, vision_range: f32) f32 {
    return math.clamp(1 - dist / vision_range, 0, 1);
}

fn processFearColumn(job: *AffectJobContext, range: ParallelRange) void {
    const s = job.affect_slice;
    const indices = job.affect_dense_index;
    const target_visible_f = job.target_visible_f;
    const dist = job.nearest_threat_dist;
    const vision_range = job.vision_range;
    const crossing_bits = job.crossing_bits;

    const zero = simd.splatFloat4(0);
    const half = simd.splatFloat4(0.5);
    const gain = simd.splatFloat4(gain_fear);

    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{ indices[k], indices[k + 1], indices[k + 2], indices[k + 3] };
        const baseline = simd.gatherFloat4(s.baseline_fear, lanes);
        const decay_rate = simd.gatherFloat4(s.decay_rate_fear, lanes);
        const threshold = simd.gatherFloat4(s.threshold_fear, lanes);
        const prev = simd.gatherFloat4(s.fear, lanes);

        const visible_f = simd.loadFloat4(target_visible_f[k..]);
        const ratio = visibilityRatio(simd.loadFloat4(dist[k..]), simd.loadFloat4(vision_range[k..]));
        const visible_mask = simd.greaterThanFloat4(visible_f, half);
        const delta = simd.selectFloat4(visible_mask, simd.mulFloat4(gain, ratio), zero);

        const final = combineDrive(prev, delta, baseline, decay_rate);
        simd.scatterFloat4(s.fear, lanes, final);
        markCrossings(crossing_bits, indices, s.above_threshold_mask, k, .fear, simd.toFloatArray(final), simd.toFloatArray(threshold));
    }

    while (k < range.end) : (k += 1) {
        const index = indices[k];
        const prev = s.fear[index];
        const visible = target_visible_f[k] > 0.5;
        const delta = if (visible) gain_fear * visibilityRatioScalar(dist[k], vision_range[k]) else 0;
        const final = combineDriveScalar(prev, delta, s.baseline_fear[index], s.decay_rate_fear[index]);
        s.fear[index] = final;
        if (checkThresholdCrossing(&s.above_threshold_mask[index], driveBit(.fear), final, s.threshold_fear[index])) |rising| {
            crossing_bits[k] |= crossingBits(.fear, rising);
        }
    }
}

fn processAggressionColumn(job: *AffectJobContext, range: ParallelRange) void {
    const s = job.affect_slice;
    const indices = job.affect_dense_index;
    const target_visible_f = job.target_visible_f;
    const dist = job.nearest_threat_dist;
    const vision_range = job.vision_range;
    const crossing_bits = job.crossing_bits;

    const zero = simd.splatFloat4(0);
    const half = simd.splatFloat4(0.5);
    const gain = simd.splatFloat4(gain_aggression);

    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{ indices[k], indices[k + 1], indices[k + 2], indices[k + 3] };
        const baseline = simd.gatherFloat4(s.baseline_aggression, lanes);
        const decay_rate = simd.gatherFloat4(s.decay_rate_aggression, lanes);
        const threshold = simd.gatherFloat4(s.threshold_aggression, lanes);
        const prev = simd.gatherFloat4(s.aggression, lanes);

        const visible_f = simd.loadFloat4(target_visible_f[k..]);
        const ratio = visibilityRatio(simd.loadFloat4(dist[k..]), simd.loadFloat4(vision_range[k..]));
        const visible_mask = simd.greaterThanFloat4(visible_f, half);
        const delta = simd.selectFloat4(visible_mask, simd.mulFloat4(gain, ratio), zero);

        const final = combineDrive(prev, delta, baseline, decay_rate);
        simd.scatterFloat4(s.aggression, lanes, final);
        markCrossings(crossing_bits, indices, s.above_threshold_mask, k, .aggression, simd.toFloatArray(final), simd.toFloatArray(threshold));
    }

    while (k < range.end) : (k += 1) {
        const index = indices[k];
        const prev = s.aggression[index];
        const visible = target_visible_f[k] > 0.5;
        const delta = if (visible) gain_aggression * visibilityRatioScalar(dist[k], vision_range[k]) else 0;
        const final = combineDriveScalar(prev, delta, s.baseline_aggression[index], s.decay_rate_aggression[index]);
        s.aggression[index] = final;
        if (checkThresholdCrossing(&s.above_threshold_mask[index], driveBit(.aggression), final, s.threshold_aggression[index])) |rising| {
            crossing_bits[k] |= crossingBits(.aggression, rising);
        }
    }
}

fn processCuriosityColumn(job: *AffectJobContext, range: ParallelRange) void {
    const s = job.affect_slice;
    const indices = job.affect_dense_index;
    const target_visible_f = job.target_visible_f;
    const heard_stimulus_f = job.heard_stimulus_f;
    const familiarity = job.familiarity;
    const crossing_bits = job.crossing_bits;

    const one = simd.splatFloat4(1);
    const zero = simd.splatFloat4(0);
    const half = simd.splatFloat4(0.5);
    const hearing_gain = simd.splatFloat4(gain_curiosity_hearing);
    const novelty_gain = simd.splatFloat4(gain_curiosity_novelty);

    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{ indices[k], indices[k + 1], indices[k + 2], indices[k + 3] };
        const baseline = simd.gatherFloat4(s.baseline_curiosity, lanes);
        const decay_rate = simd.gatherFloat4(s.decay_rate_curiosity, lanes);
        const threshold = simd.gatherFloat4(s.threshold_curiosity, lanes);
        const prev = simd.gatherFloat4(s.curiosity, lanes);

        const visible_f = simd.loadFloat4(target_visible_f[k..]);
        const heard_f = simd.loadFloat4(heard_stimulus_f[k..]);
        const not_visible = simd.subFloat4(one, visible_f);
        const hearing_mask = simd.greaterThanFloat4(simd.mulFloat4(not_visible, heard_f), half);
        const hearing_term = simd.selectFloat4(hearing_mask, hearing_gain, zero);
        const familiarity_v = simd.loadFloat4(familiarity[k..]);
        const novelty_term = simd.mulFloat4(novelty_gain, simd.subFloat4(one, familiarity_v));
        const delta = simd.addFloat4(hearing_term, novelty_term);

        const final = combineDrive(prev, delta, baseline, decay_rate);
        simd.scatterFloat4(s.curiosity, lanes, final);
        markCrossings(crossing_bits, indices, s.above_threshold_mask, k, .curiosity, simd.toFloatArray(final), simd.toFloatArray(threshold));
    }

    while (k < range.end) : (k += 1) {
        const index = indices[k];
        const prev = s.curiosity[index];
        const heard_and_not_visible = target_visible_f[k] <= 0.5 and heard_stimulus_f[k] > 0.5;
        const delta = (if (heard_and_not_visible) gain_curiosity_hearing else @as(f32, 0)) +
            gain_curiosity_novelty * (1 - familiarity[k]);
        const final = combineDriveScalar(prev, delta, s.baseline_curiosity[index], s.decay_rate_curiosity[index]);
        s.curiosity[index] = final;
        if (checkThresholdCrossing(&s.above_threshold_mask[index], driveBit(.curiosity), final, s.threshold_curiosity[index])) |rising| {
            crossing_bits[k] |= crossingBits(.curiosity, rising);
        }
    }
}

fn processFatigueColumn(job: *AffectJobContext, range: ParallelRange) void {
    const s = job.affect_slice;
    const indices = job.affect_dense_index;
    const behavior_exertion_f = job.behavior_exertion_f;
    const crossing_bits = job.crossing_bits;

    const zero = simd.splatFloat4(0);
    const half = simd.splatFloat4(0.5);
    const gain = simd.splatFloat4(gain_fatigue);

    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{ indices[k], indices[k + 1], indices[k + 2], indices[k + 3] };
        const baseline = simd.gatherFloat4(s.baseline_fatigue, lanes);
        const decay_rate = simd.gatherFloat4(s.decay_rate_fatigue, lanes);
        const threshold = simd.gatherFloat4(s.threshold_fatigue, lanes);
        const prev = simd.gatherFloat4(s.fatigue, lanes);

        // Fatigue's own input is this row's AiAgent.active_behavior, not
        // perception/memory: pursuing or fleeing (both exertive locomotion,
        // matching arbitration.zig's drive_behavior_weight fatigue row, which
        // discourages both equally) raises it; wandering/investigating/
        // cohering add no delta, so the outer decay-toward-baseline alone
        // pulls it back down.
        const exertion_f = simd.loadFloat4(behavior_exertion_f[k..]);
        const exertion_mask = simd.greaterThanFloat4(exertion_f, half);
        const delta = simd.selectFloat4(exertion_mask, gain, zero);

        const final = combineDrive(prev, delta, baseline, decay_rate);
        simd.scatterFloat4(s.fatigue, lanes, final);
        markCrossings(crossing_bits, indices, s.above_threshold_mask, k, .fatigue, simd.toFloatArray(final), simd.toFloatArray(threshold));
    }

    while (k < range.end) : (k += 1) {
        const index = indices[k];
        const prev = s.fatigue[index];
        const delta: f32 = if (behavior_exertion_f[k] > 0.5) gain_fatigue else 0;
        const final = combineDriveScalar(prev, delta, s.baseline_fatigue[index], s.decay_rate_fatigue[index]);
        s.fatigue[index] = final;
        if (checkThresholdCrossing(&s.above_threshold_mask[index], driveBit(.fatigue), final, s.threshold_fatigue[index])) |rising| {
            crossing_bits[k] |= crossingBits(.fatigue, rising);
        }
    }
}

/// `crossing_bits` word for one `drive` crossing: its "crossed" bit plus its
/// "rising" bit on a rising edge.
fn crossingBits(drive: AiAffectDrive, rising: bool) u32 {
    return crossedBit(drive) | (if (rising) risingBit(drive) else 0);
}

/// Per-lane Schmitt-trigger check for one drive over rows `k..k + lane_count`,
/// recording each crossing in the row's own `crossing_bits` word (no events
/// here; `AffectSystem.emitCrossingEvents` emits them after the join).
fn markCrossings(
    crossing_bits: []u32,
    dense_indices: []const u32,
    above_threshold_mask: []u8,
    k: usize,
    drive: AiAffectDrive,
    final: [simd.lane_count]f32,
    threshold: [simd.lane_count]f32,
) void {
    const bit = driveBit(drive);
    inline for (0..simd.lane_count) |lane| {
        const dense_index = dense_indices[k + lane];
        if (checkThresholdCrossing(&above_threshold_mask[dense_index], bit, final[lane], threshold[lane])) |rising| {
            crossing_bits[k + lane] |= crossingBits(drive, rising);
        }
    }
}

const StageWorkSelection = BatchSelection;

// Mirrors ai.zig/perception.zig/collision.zig's selectStageWork verbatim
// (module-local adaptive-profile resolution), keyed by
// affect_range_alignment_items.
fn selectStageWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    items_per_range_override: ?usize,
    max_worker_threads_override: ?usize,
    adaptive: bool,
    adaptive_tuner: ?*AdaptiveWorkTuner,
) StageWorkSelection {
    // Shapes work through the single tuner-owned entry point so pre-sizing and
    // dispatch (parallelForWithOptions) resolve an identical batch shape.
    return thread_system.selectBatchProfile(adaptive_tuner, .{
        .item_count = item_count,
        .items_per_range = items_per_range_override,
        .max_worker_threads = max_worker_threads_override,
        .range_alignment_items = affect_range_alignment_items,
        .adaptive = adaptive,
    });
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;
const AiAgent = @import("../data_system.zig").AiAgent;
const AiAffect = @import("../data_system.zig").AiAffect;
const AiPerception = @import("../data_system.zig").AiPerception;
const AiMemory = @import("../data_system.zig").AiMemory;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;

fn addAgentWithAffect(data: *DataSystem, agent: AiAgent, affect_value: AiAffect) !EntityId {
    const entity = try data.createEntity();
    try data.setAiAgent(entity, agent);
    try data.setAiAffect(entity, affect_value);
    return entity;
}

fn addAgentWithPerceptionMemoryAffect(
    data: *DataSystem,
    agent: AiAgent,
    perception: AiPerception,
    memory: AiMemory,
    affect_value: AiAffect,
) !EntityId {
    const entity = try addAgentWithAffect(data, agent, affect_value);
    try data.setAiPerception(entity, perception);
    try data.setAiMemory(entity, memory);
    return entity;
}

test "decays toward baseline with no perception/memory present, and fatigue responds to behavior" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const wanderer = try addAgentWithAffect(&data, .{ .active_behavior = .wander }, .{
        .baseline_fatigue = 0.1,
        .decay_rate_fatigue = 0.5,
        .fatigue = 0.9,
    });
    const seeker = try addAgentWithAffect(&data, .{ .active_behavior = .pursue }, .{
        .baseline_fatigue = 0.1,
        .decay_rate_fatigue = 0.5,
        .fatigue = 0.1,
    });

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try testing.expectEqual(@as(usize, 2), stats.processed_count);

    // Wandering relaxes toward the low baseline (no delta added).
    try testing.expect(data.aiAffectConst(wanderer).?.fatigue < 0.9);
    // Seeking adds a delta before decaying toward baseline, so it should not
    // have dropped as far, and should sit above the wanderer's fatigue.
    try testing.expect(data.aiAffectConst(seeker).?.fatigue > data.aiAffectConst(wanderer).?.fatigue - 0.5);
}

test "fear and aggression rise together for a close visible hostile, and fall as it recedes" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const entity = try addAgentWithPerceptionMemoryAffect(
        &data,
        .{},
        .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 10 },
        .{},
        .{ .decay_rate_fear = 0.9, .decay_rate_aggression = 0.9 },
    );

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    for (0..10) |_| _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    const settled = data.aiAffectConst(entity).?;
    try testing.expect(settled.fear > 0);
    try testing.expect(settled.aggression > 0);

    // Target no longer visible: flip the hot column directly, since
    // setAiPerception's upsert only retunes cold tunables and preserves hot
    // sensing state (mirrors how PerceptionSystem itself would write this).
    const perception_index = data.aiPerceptionDenseIndex(entity).?;
    data.perceptionSlice().target_visible[perception_index] = false;
    for (0..10) |_| _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    const after = data.aiAffectConst(entity).?;
    try testing.expect(after.fear < settled.fear);
    try testing.expect(after.aggression < settled.aggression);
}

test "curiosity rises from heard_stimulus and separately from low familiarity" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const hearer = try addAgentWithPerceptionMemoryAffect(
        &data,
        .{},
        .{ .target_visible = false, .heard_stimulus = true },
        .{ .familiarity = 1.0 },
        .{ .decay_rate_curiosity = 0.9 },
    );
    const novelty_seeker = try addAgentWithPerceptionMemoryAffect(
        &data,
        .{},
        .{ .target_visible = false, .heard_stimulus = false },
        .{ .familiarity = 0.0 },
        .{ .decay_rate_curiosity = 0.9 },
    );

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try testing.expect(data.aiAffectConst(hearer).?.curiosity > 0);
    try testing.expect(data.aiAffectConst(novelty_seeker).?.curiosity > 0);
}

test "fatigue rises under seek and decays under wander across steps" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const entity = try addAgentWithAffect(&data, .{ .active_behavior = .pursue }, .{ .decay_rate_fatigue = 0.2 });

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    for (0..10) |_| _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    const seeking_fatigue = data.aiAffectConst(entity).?.fatigue;
    try testing.expect(seeking_fatigue > 0);

    // Flip the hot active_behavior column directly: setAiAgent's upsert only
    // retunes cold tunables and preserves hot arbitration state (mirrors how
    // arbitration itself would write this, and how the perception test above
    // flips target_visible via perceptionSlice()).
    const agent_index = data.aiAgentDenseIndex(entity).?;
    data.aiAgentSlice().active_behavior[agent_index] = .wander;
    for (0..10) |_| _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try testing.expect(data.aiAffectConst(entity).?.fatigue < seeking_fatigue);
}

test "fatigue rises under flee just like pursue, matching arbitration's exertion model for both" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const fleer = try addAgentWithAffect(&data, .{ .active_behavior = .flee }, .{ .decay_rate_fatigue = 0.2 });
    const wanderer = try addAgentWithAffect(&data, .{ .active_behavior = .wander }, .{ .decay_rate_fatigue = 0.2 });

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    for (0..10) |_| _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try testing.expect(data.aiAffectConst(fleer).?.fatigue > 0);
    try testing.expect(data.aiAffectConst(fleer).?.fatigue > data.aiAffectConst(wanderer).?.fatigue);
}

test "threshold crossing emits exactly one rising then one falling event, with no chatter at the threshold" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // decay_rate_fear = 1 collapses the value straight to baseline each step
    // once the delta stops, so the value can be driven precisely: visible
    // steps push fear up (delta added, then decayed toward a baseline
    // matched to land it just at/above the threshold band).
    const entity = try addAgentWithPerceptionMemoryAffect(
        &data,
        .{},
        .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 0 },
        .{},
        .{ .baseline_fear = 0.65, .decay_rate_fear = 1.0, .threshold_fear = 0.6 },
    );

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();
    try frameReserve(&events, 16);

    // Step 1: fear rises from 0 to (0 + gain_fear) decayed fully to baseline
    // 0.65, crossing threshold 0.6 upward. Rising event expected.
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    var rising_count: usize = 0;
    for (events.mergedItems()) |event| {
        if (event.payload == .affect_threshold_crossed and event.payload.affect_threshold_crossed.rising) rising_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), rising_count);

    // Hold visible for several more steps: value stays at baseline 0.65,
    // comfortably above the falling edge (0.6 - hysteresis = 0.55), so no
    // further rising or falling events should fire (proves the hysteresis
    // band prevents flapping right at the threshold).
    for (0..5) |_| {
        events.clearRetainingCapacity();
        _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
        try testing.expectEqual(@as(usize, 0), events.mergedItems().len);
    }

    // decay_rate_fear=1 snaps the value straight to baseline every step
    // regardless of visibility, so retuning the baseline itself (a cold
    // tunable) below the falling threshold is what forces the falling edge.
    try data.setAiAffect(entity, .{ .baseline_fear = 0.4, .decay_rate_fear = 1.0, .threshold_fear = 0.6 });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    var falling_count: usize = 0;
    for (events.mergedItems()) |event| {
        if (event.payload == .affect_threshold_crossed and !event.payload.affect_threshold_crossed.rising) falling_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), falling_count);
}

fn frameReserve(events: *SimulationEvents, capacity: usize) !void {
    try events.reserve(4, capacity);
}

fn expectCrossingCounts(items: []const SimulationEvent, expected_rising: usize, expected_falling: usize) !void {
    var rising: usize = 0;
    var falling: usize = 0;
    for (items) |event| {
        if (event.payload != .affect_threshold_crossed) continue;
        if (event.payload.affect_threshold_crossed.rising) rising += 1 else falling += 1;
    }
    try testing.expectEqual(expected_rising, rising);
    try testing.expectEqual(expected_falling, falling);
}

test "Schmitt trigger does not refire a rising edge while oscillating in-band, and fires again only after truly leaving it" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // decay_rate_fear = 1 snaps fear straight to baseline every step
    // regardless of perception/memory inputs (see combineDriveScalar), so
    // retuning baseline_fear (a cold tunable) each step drives fear through
    // an exact, controlled sequence of values.
    const entity = try addAgentWithAffect(&data, .{}, .{
        .baseline_fear = 0.601,
        .decay_rate_fear = 1.0,
        .threshold_fear = 0.6,
    });

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // (a) 0 -> 0.601 crosses threshold (0.6) upward: exactly one rising event.
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 1, 0);

    // (b) dips to 0.599, still above the falling edge (0.6 - 0.05 = 0.55):
    // the hysteresis band was never left, so no event fires.
    try data.setAiAffect(entity, .{ .baseline_fear = 0.599, .decay_rate_fear = 1.0, .threshold_fear = 0.6 });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 0, 0);

    // (c) regression case: crosses threshold upward again without the drive
    // ever having genuinely calmed down. The persisted above-threshold bit is
    // already set, so this must NOT refire rising.
    try data.setAiAffect(entity, .{ .baseline_fear = 0.601, .decay_rate_fear = 1.0, .threshold_fear = 0.6 });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 0, 0);

    // (d) genuinely drops below the falling edge: exactly one falling event.
    try data.setAiAffect(entity, .{ .baseline_fear = 0.4, .decay_rate_fear = 1.0, .threshold_fear = 0.6 });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 0, 1);

    // (e) having truly left and now re-entered, this rising edge is new and
    // must fire.
    try data.setAiAffect(entity, .{ .baseline_fear = 0.601, .decay_rate_fear = 1.0, .threshold_fear = 0.6 });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 1, 0);
}

test "a threshold just above the hysteresis floor still rises and falls, not permanently latched" {
    // validateAiAffect rejects threshold_* at or below ai_affect_threshold_hysteresis
    // (checkThresholdCrossing's falling bound, threshold - hysteresis, would never be
    // reachable by a [0, 1]-clamped drive otherwise). This proves the smallest value it
    // still accepts is a real, working Schmitt trigger: it rises, falls, and can rise
    // again, rather than latching above_threshold_mask forever after the first rise.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const low_threshold: f32 = ai_affect_threshold_hysteresis + 0.02;
    const entity = try addAgentWithAffect(&data, .{}, .{
        .baseline_fear = low_threshold + 0.01,
        .decay_rate_fear = 1.0,
        .threshold_fear = low_threshold,
    });

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // Rises: baseline sits just above threshold.
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 1, 0);

    // Falls: baseline drops to 0, which is still strictly below threshold - hysteresis
    // even though threshold itself is barely above the floor.
    try data.setAiAffect(entity, .{ .baseline_fear = 0, .decay_rate_fear = 1.0, .threshold_fear = low_threshold });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 0, 1);

    // Rises again: proves the bit was genuinely cleared, not permanently latched.
    try data.setAiAffect(entity, .{ .baseline_fear = low_threshold + 0.01, .decay_rate_fear = 1.0, .threshold_fear = low_threshold });
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try expectCrossingCounts(events.mergedItems(), 1, 0);
}

test "serial and threaded updates are byte-identical" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data_a = DataSystem.init(testing.allocator);
    defer data_a.deinit();
    var data_b = DataSystem.init(testing.allocator);
    defer data_b.deinit();

    for (0..40) |i| {
        const visible = i % 3 == 0;
        const pursue: AiBehavior = if (i % 2 == 0) .pursue else .wander;
        _ = try addAgentWithPerceptionMemoryAffect(
            &data_a,
            .{ .active_behavior = pursue },
            .{ .vision_range = 100, .target_visible = visible, .nearest_threat_dist = 5, .heard_stimulus = !visible },
            .{ .familiarity = 0.3 },
            .{ .baseline_fear = 0.1, .decay_rate_fear = 0.3 },
        );
        _ = try addAgentWithPerceptionMemoryAffect(
            &data_b,
            .{ .active_behavior = pursue },
            .{ .vision_range = 100, .target_visible = visible, .nearest_threat_dist = 5, .heard_stimulus = !visible },
            .{ .familiarity = 0.3 },
            .{ .baseline_fear = 0.1, .decay_rate_fear = 0.3 },
        );
    }

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = affect_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys_a = AffectSystem.init(testing.allocator);
    defer sys_a.deinit();
    var sys_b = AffectSystem.init(testing.allocator);
    defer sys_b.deinit();
    var events_a = SimulationEvents.init(testing.allocator);
    defer events_a.deinit();
    var events_b = SimulationEvents.init(testing.allocator);
    defer events_b.deinit();

    for (0..5) |_| {
        events_a.clearRetainingCapacity();
        _ = try sys_a.updateSerial(data_a.aiAgentSliceConst(), &data_a, &events_a, .{});
        events_b.clearRetainingCapacity();
        _ = try sys_b.update(data_b.aiAgentSliceConst(), &data_b, &events_b, &threads, .{
            .items_per_range = affect_range_alignment_items,
            .max_worker_threads = 2,
            .adaptive = false,
        });
    }

    const slice_a = data_a.aiAffectSliceConst();
    const slice_b = data_b.aiAffectSliceConst();
    try testing.expectEqualSlices(f32, slice_a.fear, slice_b.fear);
    try testing.expectEqualSlices(f32, slice_a.curiosity, slice_b.curiosity);
    try testing.expectEqualSlices(f32, slice_a.aggression, slice_b.aggression);
    try testing.expectEqualSlices(f32, slice_a.fatigue, slice_b.fatigue);
    try testing.expectEqualSlices(u8, slice_a.above_threshold_mask, slice_b.above_threshold_mask);
    try testing.expectEqualSlices(SimulationEvent, events_a.mergedItems(), events_b.mergedItems());
}

test "serial and threaded emit identical order and cap membership when different drives cross across ranges" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // 20 agents span two ranges at items_per_range=16: [0,16) and [16,20).
    // Agent 0 (range 0) crosses aggression only; agent 16 (range 1) crosses
    // fear only. Per-column emission would order these by drive (fear before
    // aggression), making the serial (one range) stream disagree with the
    // threaded (range-ascending) stream. Crossings are emitted after the join
    // from per-row bits, in row order by construction (no sort), so both
    // yield aggression@0 before fear@16 — and the cap then truncates the same
    // tail element in both.
    var data_serial = DataSystem.init(testing.allocator);
    defer data_serial.deinit();
    var data_threaded = DataSystem.init(testing.allocator);
    defer data_threaded.deinit();

    for ([_]*DataSystem{ &data_serial, &data_threaded }) |data| {
        for (0..20) |i| {
            const visible = i == 0 or i == 16;
            var affect: AiAffect = .{};
            if (i == 0) affect.threshold_aggression = 0.06;
            if (i == 16) affect.threshold_fear = 0.1;
            _ = try addAgentWithPerceptionMemoryAffect(
                data,
                .{ .active_behavior = .wander },
                .{ .vision_range = 100, .target_visible = visible, .nearest_threat_dist = 0, .heard_stimulus = false },
                .{ .familiarity = 1 },
                affect,
            );
        }
    }

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = affect_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys_serial = AffectSystem.init(testing.allocator);
    defer sys_serial.deinit();
    var sys_threaded = AffectSystem.init(testing.allocator);
    defer sys_threaded.deinit();
    var events_serial = SimulationEvents.init(testing.allocator);
    defer events_serial.deinit();
    var events_threaded = SimulationEvents.init(testing.allocator);
    defer events_threaded.deinit();

    _ = try sys_serial.updateSerial(data_serial.aiAgentSliceConst(), &data_serial, &events_serial, .{});
    _ = try sys_threaded.update(data_threaded.aiAgentSliceConst(), &data_threaded, &events_threaded, &threads, .{
        .items_per_range = affect_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    const serial_items = events_serial.mergedItems();
    try testing.expectEqualSlices(SimulationEvent, serial_items, events_threaded.mergedItems());
    try testing.expectEqual(@as(usize, 2), serial_items.len);
    // Row order: aggression (row 0) before fear (row 16), independent of partition.
    try testing.expectEqual(AiAffectDrive.aggression, serial_items[0].payload.affect_threshold_crossed.drive);
    try testing.expectEqual(AiAffectDrive.fear, serial_items[1].payload.affect_threshold_crossed.drive);

    // Cap membership must also be partition-independent: cap=1 keeps the row-0
    // aggression crossing (not the column-first fear winner) in both paths.
    events_serial.clearRetainingCapacity();
    events_threaded.clearRetainingCapacity();
    // Reset the above-threshold masks so both drives re-cross this step.
    for ([_]*DataSystem{ &data_serial, &data_threaded }) |data| {
        const slice = data.aiAffectSlice();
        @memset(slice.above_threshold_mask, 0);
    }
    _ = try sys_serial.updateSerial(data_serial.aiAgentSliceConst(), &data_serial, &events_serial, .{ .max_events_per_step = 1 });
    _ = try sys_threaded.update(data_threaded.aiAgentSliceConst(), &data_threaded, &events_threaded, &threads, .{
        .items_per_range = affect_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
        .max_events_per_step = 1,
    });
    const capped_serial = events_serial.mergedItems();
    try testing.expectEqualSlices(SimulationEvent, capped_serial, events_threaded.mergedItems());
    try testing.expectEqual(@as(usize, 1), capped_serial.len);
    try testing.expectEqual(AiAffectDrive.aggression, capped_serial[0].payload.affect_threshold_crossed.drive);
}

test "an entity outside scope_dense_indices is untouched" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    _ = try addAgentWithAffect(&data, .{ .active_behavior = .pursue }, .{ .decay_rate_fatigue = 0.5 });
    _ = try addAgentWithAffect(&data, .{ .active_behavior = .pursue }, .{ .decay_rate_fatigue = 0.5 });

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const only_first = [_]u32{0};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{ .scope_dense_indices = &only_first });

    const entities = data.aiAgentSliceConst().entities;
    try testing.expect(data.aiAffectConst(entities[0]).?.fatigue > 0);
    try testing.expectEqual(@as(f32, 0), data.aiAffectConst(entities[1]).?.fatigue);
}

test "serial has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addAgentWithAffect(&data, .{ .active_behavior = .pursue }, .{});

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    try sys.reserve(1);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_allocator = sys.allocator;
    sys.allocator = failing.allocator();
    defer sys.allocator = original_allocator;

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.processed_count);
}

test "after reserve alone, threaded updates at 64- then 16-item ranges allocate nothing (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // The only reserved store is the gather rows (crossing bits
    // included), so `reserve` alone (no warm step) covers the tuner's 64-item
    // initial profile and the 16-item alignment floor on the real multi-worker
    // path. Every row crosses fear on step 1. 96 rows put 32 in the 64-item
    // partition's second range, which the old per-range event slots (reserved
    // for 16 rows past slot 0) grew in-stage.
    const row_total: usize = 96;
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..row_total) |_| {
        _ = try addAgentWithPerceptionMemoryAffect(
            &data,
            .{ .active_behavior = .wander },
            .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 0 },
            .{ .familiarity = 1 },
            .{ .baseline_fear = 0.9, .decay_rate_fear = 1.0, .threshold_fear = 0.1 },
        );
    }

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = affect_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    try sys.reserve(row_total);
    try events.reserve(1, row_total * affect_events_per_row_max);

    // resize_fail_index = 0 also catches in-place growth (a resize/remap that
    // would not count as an allocation).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    const partitions = [_]usize{ (AdaptiveWorkTunerConfig{}).initial_range_items, affect_range_alignment_items };
    for (partitions, 0..) |items, step| {
        // Mirrors `SimulationFrame.beginStep`'s per-step reset of `events`.
        events.clearRetainingCapacity();
        const stats = try sys.update(data.aiAgentSliceConst(), &data, &events, &threads, .{
            .items_per_range = items,
            .max_worker_threads = 2,
            .adaptive = false,
        });
        try testing.expectEqual(row_total, stats.processed_count);
        try testing.expectEqual(rangeCount(row_total, items), stats.batch.range_count);
        try testing.expect(!stats.batch.ran_inline);
        if (step == 0) try testing.expectEqual(row_total, stats.threshold_crossed_count);
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "crossings are emitted in (gather row, drive declaration) order, not entity-index order" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Both entities cross fear and aggression on the first step.
    const poised: AiAffect = .{
        .baseline_fear = 0.9,
        .baseline_aggression = 0.9,
        .decay_rate_fear = 1.0,
        .decay_rate_aggression = 1.0,
        .threshold_fear = 0.1,
        .threshold_aggression = 0.1,
    };
    var entities: [2]EntityId = undefined;
    for (&entities) |*entity| {
        entity.* = try addAgentWithPerceptionMemoryAffect(
            &data,
            .{ .active_behavior = .wander },
            .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 0 },
            .{ .familiarity = 1 },
            poised,
        );
    }

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // The think set lists entity 1's row first, so it is gather row 0.
    const scope = [_]u32{ 1, 0 };
    const expected = [_]struct { entity: EntityId, drive: AiAffectDrive }{
        .{ .entity = entities[1], .drive = .fear },
        .{ .entity = entities[1], .drive = .aggression },
        .{ .entity = entities[0], .drive = .fear },
        .{ .entity = entities[0], .drive = .aggression },
    };

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{ .scope_dense_indices = &scope });
    try testing.expectEqual(@as(usize, 4), stats.threshold_crossed_count);
    const items = events.mergedItems();
    try testing.expectEqual(expected.len, items.len);
    for (expected, items) |want, event| {
        const crossing = event.payload.affect_threshold_crossed;
        try testing.expectEqual(want.entity, crossing.entity);
        try testing.expectEqual(want.drive, crossing.drive);
        try testing.expect(crossing.rising);
    }

    // The cap keeps the first three in that same order and drops the last.
    @memset(data.aiAffectSlice().above_threshold_mask, 0);
    events.clearRetainingCapacity();
    const capped = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{ .scope_dense_indices = &scope, .max_events_per_step = 3 });
    try testing.expectEqual(@as(usize, 3), capped.threshold_crossed_count);
    try testing.expectEqual(@as(usize, 1), events.stats.dropped);
    const capped_items = events.mergedItems();
    try testing.expectEqual(@as(usize, 3), capped_items.len);
    for (expected[0..3], capped_items) |want, event| {
        try testing.expectEqual(want.entity, event.payload.affect_threshold_crossed.entity);
        try testing.expectEqual(want.drive, event.payload.affect_threshold_crossed.drive);
    }
}

test "a tight event capacity forces a graceful drop instead of a throw" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Two entities, each with all four drives poised to cross a rising edge
    // in the same step: up to 8 events produced, capacity capped to 1.
    for (0..2) |_| {
        _ = try addAgentWithPerceptionMemoryAffect(
            &data,
            .{ .active_behavior = .pursue },
            .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 0 },
            .{ .familiarity = 0 },
            .{
                .baseline_fear = 0.9,
                .baseline_aggression = 0.9,
                .baseline_curiosity = 0.9,
                .baseline_fatigue = 0.9,
                .decay_rate_fear = 1.0,
                .decay_rate_aggression = 1.0,
                .decay_rate_curiosity = 1.0,
                .decay_rate_fatigue = 1.0,
                .threshold_fear = 0.1,
                .threshold_aggression = 0.1,
                .threshold_curiosity = 0.1,
                .threshold_fatigue = 0.1,
            },
        );
    }

    var sys = AffectSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{ .max_events_per_step = 1 });
    try testing.expectEqual(@as(usize, 1), stats.threshold_crossed_count);
    const items = events.mergedItems();
    try testing.expectEqual(@as(usize, 1), items.len);
    // Row 0's first drive in declaration order survives the cap.
    try testing.expectEqual(AiAffectDrive.fear, items[0].payload.affect_threshold_crossed.drive);
    // All 4 drives cross for both entities (8 real events); capped to 1.
    try testing.expectEqual(@as(usize, 7), events.stats.dropped);
    try testing.expect(sys.dropped_events_warned);

    // The flag is once-only: a later step never clears it.
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &events, .{ .max_events_per_step = 1 });
    try testing.expect(sys.dropped_events_warned);
}
