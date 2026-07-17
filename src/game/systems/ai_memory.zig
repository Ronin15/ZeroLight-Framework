// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI short-term memory processor: decays every gathered agent's `AiMemory`
//! row (staleness climbs, familiarity relaxes toward zero,
//! ring contacts age out), refreshes from this step's perception
//! transitions (`entity_perceived`/`entity_lost` `SimulationEvent`s emitted by
//! `perception.zig` at the `domain_reaction` stage), then continuously tracks
//! still-visible same-identity targets from perception's hot `last_seen_*`.
//!
//! Gather mirrors `AiSystem.gatherAiData`/`PerceptionSystem.gatherPerceptionData`:
//! walk `scope_dense_indices` (or every `ai_agents.entities` row), keeping only
//! entities that carry BOTH `AiPerception` and `AiMemory` — memory is defined
//! as a downstream consumer of perception, never running for a memory-only
//! entity. The gathered set is memory's own `ai_memories` dense-index list
//! (not entities, not ai rows), a scattered subset of that store, so decay
//! uses a SIMD gather/scatter indexed idiom: four scattered rows gather into
//! lanes, decay, and scatter back.
//!
//! Ordering within one `update`/`updateSerial` call:
//! 1. Decay (staleness +1, familiarity decays, ring ages) on the gathered set.
//! 2. Event refresh (`entity_perceived` / `entity_lost`) so a same-step
//!    reacquisition or loss lands at `staleness == 0` rather than `1`.
//! 3. Continuous visibility pass over the gathered set: when perception still
//!    reports `target_visible` for the same identity as `last_known_target`,
//!    refresh `last_known_x/y` from `last_seen_*`, keep `staleness = 0`, and
//!    raise familiarity by `ai_memory_familiarity_gain_rate` (clamped).
//!
//! On `entity_lost`: snapshot perception's frozen `last_seen_*` into
//! `last_known_*` for that observer and reset `staleness` to 0 so it climbs
//! from the moment of loss (not from first sight). An identity-swap emits
//! `entity_lost` then `entity_perceived` in the same pass; the perceived
//! handler retargets `last_known_target` after the loss snapshot.
//!
//! The event refresh pass is unscoped (reads every `domain_reaction` event in
//! `frame.events`, not just this step's gathered subset): since `perception.zig`
//! itself only emits transitions for its own scoped population, an entity
//! excluded from this step's cognition scope never has perception events to
//! react to anyway, so scope-freeze falls out naturally rather than needing a
//! second filter here. Continuous visibility / familiarity only run on the
//! gathered (scoped) set, matching decay.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const ConstPerceptionSlice = @import("../data_system.zig").ConstPerceptionSlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const AiMemorySlice = @import("../data_system.zig").AiMemorySlice;
const ai_memory_ring_capacity = @import("../data_system.zig").ai_memory_ring_capacity;
const max_ai_memory_staleness = @import("../data_system.zig").max_ai_memory_staleness;
const max_ai_memory_familiarity = @import("../data_system.zig").max_ai_memory_familiarity;
const ai_memory_familiarity_decay_rate = @import("../data_system.zig").ai_memory_familiarity_decay_rate;
const ai_memory_familiarity_gain_rate = @import("../data_system.zig").ai_memory_familiarity_gain_rate;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const EntityPerceivedEvent = @import("../simulation.zig").EntityPerceivedEvent;
const EntityLostEvent = @import("../simulation.zig").EntityLostEvent;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;

pub const ai_memory_range_alignment_items: usize = movement_range_alignment_items;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, ai_memory_range_alignment_items);
}

pub const AiMemoryConfig = struct {
    /// When non-null, only these dense ai-store indices participate this step
    /// (the scope system's cognition halo + stagger selection). Null = all
    /// agents. Mirrors `AiConfig.scope_dense_indices`/
    /// `PerceptionConfig.scope_dense_indices` exactly.
    scope_dense_indices: ?[]const u32 = null,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const AiMemoryStats = struct {
    processed_count: usize = 0,
    refreshed_count: usize = 0,
    batch: BatchStats = .{},
};

pub const AiMemorySystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only): `ai_memories` dense-store row
    // indices for this step's scoped agents that also carry `AiPerception`.
    // Not entity ids, not ai-store rows — a scattered subset of the memory
    // store's own row order, consumed via indexed SIMD gather/scatter.
    memory_dense_indices: std.ArrayList(u32) = .empty,
    decay_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init(allocator: std.mem.Allocator) AiMemorySystem {
        return .{
            .allocator = allocator,
            .decay_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *AiMemorySystem) void {
        self.memory_dense_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *AiMemorySystem,
        ai_agents: ConstAiAgentSlice,
        data: *DataSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        config: AiMemoryConfig,
    ) !AiMemoryStats {
        try self.gatherScopedIndices(ai_agents, data, config.scope_dense_indices);
        const count = self.memory_dense_indices.items.len;
        if (count == 0) {
            return .{ .refreshed_count = finishMemoryRefresh(data, frame, &.{}) };
        }

        var system_config = config;
        if (system_config.adaptive and system_config.adaptive_tuner == null and system_config.items_per_range == null) {
            system_config.adaptive_tuner = &self.decay_tuner;
        }

        // Pre-select so the job context can dual-assert range.index against
        // the dispatched range count (mirror affect.zig / collision.zig). Mirrors
        // parallelForWithOptions' `adaptive_tuner orelse &self.adaptive_tuner` fallback.
        const selection = thread_system.selectBatchProfile(system_config.adaptive_tuner orelse &thread_system.adaptive_tuner, .{
            .item_count = count,
            .items_per_range = system_config.items_per_range,
            .max_worker_threads = system_config.max_worker_threads,
            .adaptive = system_config.adaptive,
        });
        var context = AiMemoryDecayContext{
            .slice = data.aiMemorySlice(),
            .indices = self.memory_dense_indices.items,
            .range_count = selection.range_count,
        };
        // No range_alignment_items: the indexed gather/scatter path processes
        // each row independently of any contiguous-range shape, mirroring
        // movement.zig's own scoped/indexed dispatch.
        const batch = thread_system.parallelForWithOptions(count, &context, aiMemoryDecayJob, .{
            .items_per_range = system_config.items_per_range,
            .max_worker_threads = system_config.max_worker_threads,
            .adaptive = system_config.adaptive,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        return .{
            .processed_count = count,
            .refreshed_count = finishMemoryRefresh(data, frame, self.memory_dense_indices.items),
            .batch = batch,
        };
    }

    pub fn updateSerial(
        self: *AiMemorySystem,
        ai_agents: ConstAiAgentSlice,
        data: *DataSystem,
        frame: *SimulationFrame,
        config: AiMemoryConfig,
    ) !AiMemoryStats {
        try self.gatherScopedIndices(ai_agents, data, config.scope_dense_indices);
        const count = self.memory_dense_indices.items.len;
        if (count == 0) {
            return .{ .refreshed_count = finishMemoryRefresh(data, frame, &.{}) };
        }

        var memory_slice = data.aiMemorySlice();
        processDecayRange(&memory_slice, self.memory_dense_indices.items, .{ .index = 0, .start = 0, .end = count });

        return .{
            .processed_count = count,
            .refreshed_count = finishMemoryRefresh(data, frame, self.memory_dense_indices.items),
            .batch = serialBatch(count),
        };
    }

    // Population-domain contract with ai.zig/perception.zig: walks
    // `scope_dense_indices` (or every ai agent) resolving each entity's own
    // `ai_memories` dense row, keeping only entities that carry both
    // `AiPerception` and `AiMemory` — memory never runs standalone.
    fn gatherScopedIndices(
        self: *AiMemorySystem,
        ai_agents: ConstAiAgentSlice,
        data: *const DataSystem,
        scope_dense_indices: ?[]const u32,
    ) !void {
        self.memory_dense_indices.clearRetainingCapacity();
        const n = if (scope_dense_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return;
        try self.memory_dense_indices.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));

        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (scope_dense_indices) |idx| idx[k] else k;
            const ent = ai_agents.entities[i];
            _ = data.aiPerceptionDenseIndex(ent) orelse continue;
            const memory_index = data.aiMemoryDenseIndex(ent) orelse continue;
            self.memory_dense_indices.appendAssumeCapacity(@intCast(memory_index));
        }
    }
};

const AiMemoryDecayContext = struct {
    slice: AiMemorySlice,
    indices: []const u32,
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
};

fn aiMemoryDecayJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiMemoryDecayContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig). Bounds on the
    // indices buffer live in processDecayRange (shared with the serial path).
    std.debug.assert(range.index < job.range_count);
    processDecayRange(&job.slice, job.indices, range);
}

/// Decays the rows named by `indices[range.start..range.end]`: staleness
/// climbs by one step clamped to `max_ai_memory_staleness`, familiarity
/// relaxes toward zero by `ai_memory_familiarity_decay_rate`. The indices are
/// scattered (a subset of the memory store's own row order), so four rows at
/// a time gather into lanes, decay as `Float4`, and scatter back — a
/// SIMD-gather/scatter shape over its own scoped subset. A scalar tail covers
/// the remainder. Ring aging
/// (`ageRingForRow`) is a separate per-row step, run once per row regardless
/// of whether that row was reached via the vector or scalar path here; its
/// own age+clamp math is itself vectorized as one `Float4` per row, with only
/// the entity-invalidation check staying scalar.
fn processDecayRange(slice: *AiMemorySlice, indices: []const u32, range: ParallelRange) void {
    // Shared serial/threaded buffer bounds (range.index is asserted at the job entry).
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= indices.len);

    const one = simd.splatFloat4(1.0);
    const zero = simd.splatFloat4(0.0);
    const max_staleness = simd.splatFloat4(max_ai_memory_staleness);
    const decay_rate = simd.splatFloat4(ai_memory_familiarity_decay_rate);

    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{
            indices[k], indices[k + 1], indices[k + 2], indices[k + 3],
        };

        const staleness = simd.gatherFloat4(slice.staleness, lanes);
        const next_staleness = simd.clampFloat4(simd.addFloat4(staleness, one), zero, max_staleness);
        simd.scatterFloat4(slice.staleness, lanes, next_staleness);

        const familiarity = simd.gatherFloat4(slice.familiarity, lanes);
        const next_familiarity = simd.lerpFloat4(familiarity, zero, decay_rate);
        simd.scatterFloat4(slice.familiarity, lanes, next_familiarity);

        inline for (0..simd.lane_count) |lane| {
            ageRingForRow(slice, lanes[lane]);
        }
    }

    while (k < range.end) : (k += 1) {
        const index: usize = indices[k];
        slice.staleness[index] = math.clamp(slice.staleness[index] + 1.0, 0, max_ai_memory_staleness);
        slice.familiarity[index] = math.lerp(slice.familiarity[index], 0.0, ai_memory_familiarity_decay_rate);
        ageRingForRow(slice, index);
    }
}

comptime {
    // The dense age+clamp step below loads/stores the whole ring as one
    // `Float4`, so the ring width must match the SIMD lane count exactly.
    if (ai_memory_ring_capacity != simd.lane_count) @compileError("ai_memory_ring_capacity must equal simd.lane_count for ageRingForRow's vectorized aging");
}

/// Ages one row's ring contacts by one step: age + 1 clamped to
/// `max_ai_memory_staleness` is dense uniform float math over the row's fixed
/// `ai_memory_ring_capacity`-wide array (== `simd.lane_count`), so it runs as
/// one `Float4` op covering all slots, aged or not — harmless for an
/// already-empty slot since `upsertRingContact` always resets a reused slot's
/// age to 0 anyway. The remaining branchy part, clearing a slot's entity to
/// `EntityId.invalid` once its aged value reaches `max_ai_memory_staleness`
/// (an expired contact stays a slot the ring can reuse; expiry is purely
/// columnar, no event is emitted), stays a scalar pass over the resulting ages.
fn ageRingForRow(slice: *AiMemorySlice, index: usize) void {
    const ring_entity = &slice.ring_entity[index];
    const ring_age = &slice.ring_age[index];

    const aged = simd.clampFloat4(
        simd.addFloat4(simd.loadFloat4(ring_age), simd.splatFloat4(1.0)),
        simd.splatFloat4(0.0),
        simd.splatFloat4(max_ai_memory_staleness),
    );
    simd.storeFloat4(ring_age, aged);

    for (0..ai_memory_ring_capacity) |slot| {
        if (!ring_entity[slot].isValid()) continue;
        if (ring_age[slot] >= max_ai_memory_staleness) ring_entity[slot] = EntityId.invalid;
    }
}

/// Event refresh + continuous visibility, run AFTER decay. Returns the number
/// of event-driven writes (`entity_perceived` + `entity_lost`). Continuous
/// same-identity tracking is not counted (it is the steady-state path).
fn finishMemoryRefresh(data: *DataSystem, frame: *SimulationFrame, memory_dense_indices: []const u32) usize {
    var memory_slice = data.aiMemorySlice();
    const perception_slice = data.aiPerceptionSliceConst();
    const refreshed = refreshFromEvents(data, &memory_slice, perception_slice, frame);
    refreshVisibleTargets(data, &memory_slice, perception_slice, memory_dense_indices);
    return refreshed;
}

/// Serial scan over this step's `domain_reaction` events for perception
/// acquisitions and losses, run AFTER decay so a same-step reacquisition or
/// loss lands at `staleness == 0` rather than `1`.
fn refreshFromEvents(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    frame: *SimulationFrame,
) usize {
    var refreshed: usize = 0;
    for (frame.events.mergedItems()) |event| {
        if (event.stage != .domain_reaction) continue;
        switch (event.payload) {
            .entity_perceived => |perceived| {
                if (applyPerceivedEvent(data, memory_slice, perception_slice, perceived)) refreshed += 1;
            },
            .entity_lost => |lost| {
                if (applyLostEvent(data, memory_slice, perception_slice, lost)) refreshed += 1;
            },
            else => {},
        }
    }
    return refreshed;
}

fn applyPerceivedEvent(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    perceived: EntityPerceivedEvent,
) bool {
    const memory_index = data.aiMemoryDenseIndex(perceived.observer) orelse return false;
    const perception_index = data.aiPerceptionDenseIndex(perceived.observer) orelse return false;
    const last_seen_x = perception_slice.last_seen_x[perception_index];
    const last_seen_y = perception_slice.last_seen_y[perception_index];

    memory_slice.last_known_target[memory_index] = perceived.target;
    memory_slice.last_known_x[memory_index] = last_seen_x;
    memory_slice.last_known_y[memory_index] = last_seen_y;
    memory_slice.staleness[memory_index] = 0;
    upsertRingContact(memory_slice, memory_index, perceived.target, last_seen_x, last_seen_y);
    return true;
}

/// On loss: snapshot perception's frozen `last_seen_*` into `last_known_*` and
/// reset `staleness` to 0 so it climbs from the loss step (not from first
/// sight). Perception freezes `last_seen_*` when `target_visible` becomes
/// false; identity-swap pairs this with a following `entity_perceived` that
/// retargets `last_known_target` in the same event pass.
fn applyLostEvent(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    lost: EntityLostEvent,
) bool {
    const memory_index = data.aiMemoryDenseIndex(lost.observer) orelse return false;
    const perception_index = data.aiPerceptionDenseIndex(lost.observer) orelse return false;
    // Only snapshot when the lost identity is (or becomes) the remembered one;
    // skip if memory already tracks a different target.
    const remembered = memory_slice.last_known_target[memory_index];
    if (remembered.isValid() and !remembered.matches(lost.target.index, lost.target.generation)) return false;

    const last_seen_x = perception_slice.last_seen_x[perception_index];
    const last_seen_y = perception_slice.last_seen_y[perception_index];
    memory_slice.last_known_target[memory_index] = lost.target;
    memory_slice.last_known_x[memory_index] = last_seen_x;
    memory_slice.last_known_y[memory_index] = last_seen_y;
    memory_slice.staleness[memory_index] = 0;
    return true;
}

/// For each gathered memory row still reporting the same visible identity as
/// `last_known_target`: keep `last_known_x/y` in lockstep with perception
/// `last_seen_*`, hold `staleness` at 0, raise familiarity, and refresh the
/// matching ring contact. Runs after event refresh so a same-step acquire
/// already has `last_known_target` set before this pass.
fn refreshVisibleTargets(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    memory_dense_indices: []const u32,
) void {
    for (memory_dense_indices) |memory_index_u32| {
        const memory_index: usize = memory_index_u32;
        const entity = memory_slice.entities[memory_index];
        const perception_index = data.aiPerceptionDenseIndex(entity) orelse continue;
        if (!perception_slice.target_visible[perception_index]) continue;
        const threat = perception_slice.nearest_threat[perception_index];
        if (!threat.isValid()) continue;
        const last = memory_slice.last_known_target[memory_index];
        if (!last.matches(threat.index, threat.generation)) continue;

        const last_seen_x = perception_slice.last_seen_x[perception_index];
        const last_seen_y = perception_slice.last_seen_y[perception_index];
        memory_slice.last_known_x[memory_index] = last_seen_x;
        memory_slice.last_known_y[memory_index] = last_seen_y;
        memory_slice.staleness[memory_index] = 0;
        memory_slice.familiarity[memory_index] = math.clamp(
            memory_slice.familiarity[memory_index] + ai_memory_familiarity_gain_rate,
            0,
            max_ai_memory_familiarity,
        );
        upsertRingContact(memory_slice, memory_index, threat, last_seen_x, last_seen_y);
    }
}

/// Dedup-scans the ring for `target`: an existing contact updates in place
/// (position + `age = 0`, write cursor untouched); otherwise the contact is
/// written at `ring_next_slot` and the cursor advances mod capacity —
/// oldest-first overwrite once the ring is full.
fn upsertRingContact(memory_slice: *AiMemorySlice, index: usize, target: EntityId, x: f32, y: f32) void {
    const ring_entity = &memory_slice.ring_entity[index];
    const ring_x = &memory_slice.ring_x[index];
    const ring_y = &memory_slice.ring_y[index];
    const ring_age = &memory_slice.ring_age[index];

    for (0..ai_memory_ring_capacity) |slot| {
        if (!ring_entity[slot].matches(target.index, target.generation)) continue;
        ring_x[slot] = x;
        ring_y[slot] = y;
        ring_age[slot] = 0;
        return;
    }

    const cursor: usize = memory_slice.ring_next_slot[index];
    ring_entity[cursor] = target;
    ring_x[cursor] = x;
    ring_y[cursor] = y;
    ring_age[cursor] = 0;
    memory_slice.ring_next_slot[index] = @intCast((cursor + 1) % ai_memory_ring_capacity);
}

fn serialBatch(count: usize) BatchStats {
    return .{ .ran_inline = true, .item_count = count, .range_count = if (count > 0) 1 else 0, .items_per_range = count };
}

const testing = std.testing;

fn addAgentWithPerceptionAndMemory(
    data: *DataSystem,
    x: f32,
    y: f32,
    perception: @import("../data_system.zig").AiPerception,
    memory: @import("../data_system.zig").AiMemory,
) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y } });
    try data.setAiAgent(entity, .{});
    try data.setAiPerception(entity, perception);
    try data.setAiMemory(entity, memory);
    return entity;
}

fn appendPerceivedEvent(frame: *SimulationFrame, observer: EntityId, target: EntityId) !void {
    try frame.events.appendRequired(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = target } } });
}

fn appendLostEvent(frame: *SimulationFrame, observer: EntityId, target: EntityId) !void {
    try frame.events.appendRequired(.{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = target } } });
}

test "AiMemorySystem refreshes from a perception-acquired event and snapshots on lost" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const observer = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{ .last_seen_x = 42, .last_seen_y = 7 }, .{});
    const target = try data.createEntity();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    const stats = try sys.update(data.aiAgentSliceConst(), &data, &frame, &threads, .{});
    try testing.expectEqual(@as(usize, 1), stats.refreshed_count);

    const memory = data.aiMemoryConst(observer).?;
    try testing.expectEqual(target, memory.last_known_target);
    try testing.expectEqual(@as(f32, 42), memory.last_known_x);
    try testing.expectEqual(@as(f32, 7), memory.last_known_y);
    try testing.expectEqual(@as(f32, 0), memory.staleness);
    try testing.expectEqual(target, memory.ring[0].entity);

    // Lost event snapshots perception last_seen and resets staleness to 0.
    const observer2 = try addAgentWithPerceptionAndMemory(
        &data,
        10,
        10,
        .{ .last_seen_x = 99, .last_seen_y = 11 },
        .{ .last_known_target = target, .last_known_x = 1, .last_known_y = 2, .staleness = 5 },
    );
    frame.beginStep();
    try appendLostEvent(&frame, observer2, target);
    const stats2 = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(usize, 1), stats2.refreshed_count);
    const lost_memory = data.aiMemoryConst(observer2).?;
    try testing.expectEqual(target, lost_memory.last_known_target);
    try testing.expectEqual(@as(f32, 99), lost_memory.last_known_x);
    try testing.expectEqual(@as(f32, 11), lost_memory.last_known_y);
    try testing.expectEqual(@as(f32, 0), lost_memory.staleness);
}

test "AiMemorySystem continuous visibility refreshes last_known to latest last_seen, not first sight" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const target = try data.createEntity();
    const observer = try addAgentWithPerceptionAndMemory(
        &data,
        0,
        0,
        .{ .target_visible = true, .nearest_threat = target, .last_seen_x = 10, .last_seen_y = 0 },
        .{},
    );

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    // Acquire at first-seen position.
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(f32, 10), data.aiMemoryConst(observer).?.last_known_x);
    try testing.expectEqual(@as(f32, 0), data.aiMemoryConst(observer).?.staleness);

    // Moving hostile under continuous LOS: last_seen advances; memory must track it.
    const positions = [_]f32{ 20, 35, 50 };
    for (positions) |x| {
        const pidx = data.aiPerceptionDenseIndex(observer).?;
        var perception = data.perceptionSlice();
        perception.target_visible[pidx] = true;
        perception.nearest_threat[pidx] = target;
        perception.last_seen_x[pidx] = x;
        perception.last_seen_y[pidx] = x * 0.5;
        frame.beginStep();
        // No transition events while still visible with the same identity.
        _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
        const memory = data.aiMemoryConst(observer).?;
        try testing.expectEqual(target, memory.last_known_target);
        try testing.expectEqual(x, memory.last_known_x);
        try testing.expectEqual(x * 0.5, memory.last_known_y);
        try testing.expectEqual(@as(f32, 0), memory.staleness);
    }

    // Drop LOS: snapshot last_seen into last_known, staleness climbs from 0.
    const final_x: f32 = 50;
    const final_y: f32 = 25;
    {
        const pidx = data.aiPerceptionDenseIndex(observer).?;
        var perception = data.perceptionSlice();
        perception.target_visible[pidx] = false;
        perception.nearest_threat[pidx] = EntityId.invalid;
        perception.last_seen_x[pidx] = final_x;
        perception.last_seen_y[pidx] = final_y;
    }
    frame.beginStep();
    try appendLostEvent(&frame, observer, target);
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    var memory = data.aiMemoryConst(observer).?;
    try testing.expectEqual(target, memory.last_known_target);
    try testing.expectEqual(final_x, memory.last_known_x);
    try testing.expectEqual(final_y, memory.last_known_y);
    try testing.expectEqual(@as(f32, 0), memory.staleness);

    frame.beginStep();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    memory = data.aiMemoryConst(observer).?;
    try testing.expectEqual(final_x, memory.last_known_x);
    try testing.expectEqual(final_y, memory.last_known_y);
    try testing.expectEqual(@as(f32, 1), memory.staleness);
}

test "AiMemorySystem familiarity rises under sustained same-identity visibility" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const target = try data.createEntity();
    const observer = try addAgentWithPerceptionAndMemory(
        &data,
        0,
        0,
        .{ .target_visible = true, .nearest_threat = target, .last_seen_x = 5, .last_seen_y = 5 },
        .{ .familiarity = 0 },
    );

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    const after_acquire = data.aiMemoryConst(observer).?.familiarity;
    try testing.expect(after_acquire > 0);

    var prev = after_acquire;
    var step: usize = 0;
    while (step < 8) : (step += 1) {
        frame.beginStep();
        _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
        const familiarity = data.aiMemoryConst(observer).?.familiarity;
        try testing.expect(familiarity > prev);
        prev = familiarity;
    }
    try testing.expect(prev > after_acquire);
    try testing.expect(prev <= max_ai_memory_familiarity);

    // Idle memory (no visibility) must not hold novelty constant: familiarity decays.
    const idle = try addAgentWithPerceptionAndMemory(&data, 20, 20, .{}, .{ .familiarity = 0.5 });
    const idle_before = data.aiMemoryConst(idle).?.familiarity;
    frame.beginStep();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expect(data.aiMemoryConst(idle).?.familiarity < idle_before);
}

test "AiMemorySystem decay is byte-identical between threaded and serial paths" {
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var data_a = DataSystem.init(testing.allocator);
    defer data_a.deinit();
    var data_b = DataSystem.init(testing.allocator);
    defer data_b.deinit();
    _ = try addAgentWithPerceptionAndMemory(&data_a, 0, 0, .{}, .{ .staleness = 10, .familiarity = 0.5 });
    _ = try addAgentWithPerceptionAndMemory(&data_a, 5, 5, .{}, .{ .staleness = 20, .familiarity = 0.9 });
    _ = try addAgentWithPerceptionAndMemory(&data_b, 0, 0, .{}, .{ .staleness = 10, .familiarity = 0.5 });
    _ = try addAgentWithPerceptionAndMemory(&data_b, 5, 5, .{}, .{ .staleness = 20, .familiarity = 0.9 });

    var frame_a = SimulationFrame.init(testing.allocator);
    defer frame_a.deinit();
    try frame_a.reserveStreams(1, 0, 0, 0, 0, 0);
    var frame_b = SimulationFrame.init(testing.allocator);
    defer frame_b.deinit();
    try frame_b.reserveStreams(1, 0, 0, 0, 0, 0);

    var sys_a = AiMemorySystem.init(testing.allocator);
    defer sys_a.deinit();
    var sys_b = AiMemorySystem.init(testing.allocator);
    defer sys_b.deinit();

    for (0..5) |_| {
        frame_a.beginStep();
        _ = try sys_a.updateSerial(data_a.aiAgentSliceConst(), &data_a, &frame_a, .{});
        frame_b.beginStep();
        _ = try sys_b.update(data_b.aiAgentSliceConst(), &data_b, &frame_b, &threads, .{});
    }

    const slice_a = data_a.aiMemorySliceConst();
    const slice_b = data_b.aiMemorySliceConst();
    try testing.expectEqualSlices(f32, slice_a.staleness, slice_b.staleness);
    try testing.expectEqualSlices(f32, slice_a.familiarity, slice_b.familiarity);
    for (slice_a.ring_entity, slice_b.ring_entity) |ring_a, ring_b| {
        try testing.expectEqualSlices(EntityId, &ring_a, &ring_b);
    }
}

test "AiMemorySystem ring eviction overwrites oldest slot and repeated target updates in place" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const observer = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{ .last_seen_x = 1, .last_seen_y = 1 }, .{});
    var targets: [5]EntityId = undefined;
    for (&targets) |*t| t.* = try data.createEntity();

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    for (targets[0..4]) |target| {
        frame.beginStep();
        try appendPerceivedEvent(&frame, observer, target);
        _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    }
    var memory = data.aiMemoryConst(observer).?;
    try testing.expectEqual(@as(u8, 0), memory.ring_next_slot);
    for (targets[0..4], 0..) |target, slot| try testing.expectEqual(target, memory.ring[slot].entity);

    // Repeated target (index 1) updates in place; cursor must not move.
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, targets[1]);
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    memory = data.aiMemoryConst(observer).?;
    try testing.expectEqual(@as(u8, 0), memory.ring_next_slot);
    try testing.expectEqual(targets[1], memory.ring[1].entity);
    try testing.expectEqual(@as(f32, 0), memory.ring[1].age);

    // A 5th distinct target overwrites the oldest slot (0) and advances the cursor.
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, targets[4]);
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    memory = data.aiMemoryConst(observer).?;
    try testing.expectEqual(targets[4], memory.ring[0].entity);
    try testing.expectEqual(@as(u8, 1), memory.ring_next_slot);
}

test "AiMemorySystem expires a ring contact once its age reaches max staleness" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const observer = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{}, .{});
    const target = try data.createEntity();

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(target, data.aiMemoryConst(observer).?.ring[0].entity);

    var step: usize = 0;
    while (step < @as(usize, @intFromFloat(max_ai_memory_staleness))) : (step += 1) {
        frame.beginStep();
        _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    }

    try testing.expectEqual(EntityId.invalid, data.aiMemoryConst(observer).?.ring[0].entity);
}

test "AiMemorySystem freezes an out-of-scope entity's memory row and resumes without a jump on resync" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    _ = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{}, .{ .staleness = 10 });
    _ = try addAgentWithPerceptionAndMemory(&data, 10, 10, .{}, .{ .staleness = 10 });

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 0, 0, 0);

    frame.beginStep();
    const both = [_]u32{ 0, 1 };
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{ .scope_dense_indices = &both });
    try testing.expectEqual(@as(f32, 11), data.aiMemoryConst(data.aiAgentSliceConst().entities[0]).?.staleness);
    try testing.expectEqual(@as(f32, 11), data.aiMemoryConst(data.aiAgentSliceConst().entities[1]).?.staleness);

    // Only entity 0 in scope: entity 1's row must stay frozen at 11.
    const only_a = [_]u32{0};
    for (0..3) |_| {
        frame.beginStep();
        _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{ .scope_dense_indices = &only_a });
    }
    try testing.expectEqual(@as(f32, 14), data.aiMemoryConst(data.aiAgentSliceConst().entities[0]).?.staleness);
    try testing.expectEqual(@as(f32, 11), data.aiMemoryConst(data.aiAgentSliceConst().entities[1]).?.staleness);

    // Back in scope: resumes from exactly the frozen value, no reset, no catch-up.
    frame.beginStep();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{ .scope_dense_indices = &both });
    try testing.expectEqual(@as(f32, 12), data.aiMemoryConst(data.aiAgentSliceConst().entities[1]).?.staleness);
}

test "AiMemorySystem never gathers an entity with AiMemory but no AiPerception" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    try data.setAiAgent(entity, .{});
    try data.setAiMemory(entity, .{ .staleness = 100 });

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 0, 0, 0);
    frame.beginStep();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(usize, 0), stats.processed_count);
    try testing.expectEqual(@as(usize, 0), sys.memory_dense_indices.items.len);
    try testing.expectEqual(@as(f32, 100), data.aiMemoryConst(entity).?.staleness);
}

test "AiMemorySystem serial has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{}, .{ .staleness = 5 });

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    // Warm-up run sizes memory_dense_indices to steady state.
    frame.beginStep();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_allocator = sys.allocator;
    sys.allocator = failing.allocator();
    defer sys.allocator = original_allocator;

    frame.beginStep();
    const stats = try sys.updateSerial(data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(usize, 1), stats.processed_count);
}

test "AiMemorySystem threaded update has no steady-state allocation after warmup (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..64) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addAgentWithPerceptionAndMemory(&data, fi, 0, .{}, .{ .staleness = 5 });
    }

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = ai_memory_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    const config = AiMemoryConfig{
        .items_per_range = ai_memory_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    };

    // Warm-up: sizes memory_dense_indices to steady state.
    frame.beginStep();
    const warmup_stats = try sys.update(data.aiAgentSliceConst(), &data, &frame, &threads, config);
    try testing.expect(!warmup_stats.batch.ran_inline);
    try testing.expect(warmup_stats.batch.active_worker_threads > 0);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_allocator = sys.allocator;
    sys.allocator = failing.allocator();
    defer sys.allocator = original_allocator;

    frame.beginStep();
    const stats = try sys.update(data.aiAgentSliceConst(), &data, &frame, &threads, config);
    try testing.expectEqual(@as(usize, 64), stats.processed_count);
    try testing.expect(!stats.batch.ran_inline);
    try testing.expect(stats.batch.active_worker_threads > 0);
}
