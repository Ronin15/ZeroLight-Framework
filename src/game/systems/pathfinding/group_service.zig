// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The group-field service of `PathfindingSystem`: each step turns the cross-step demand
//! tallies into shared flow fields. Fields building at step start advance
//! (`group_field_expand`, threaded one field per item), the main thread then claims, rekeys,
//! or begins a field per above-threshold goal in tally order (O(max_group_fields) per
//! decision), fields begun this step take their first budgeted expansion, and tallies that
//! decayed to zero retire. Free functions over `*PathfindingSystem`; the system calls them
//! directly.

const std = @import("std");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const RoundDispatch = @import("../../../app/thread_system.zig").RoundDispatch;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const GroupField = @import("group_field.zig").GroupField;
const initialPoolBlocks = @import("group_field.zig").initialPoolBlocks;
const PathfindingConfig = @import("types.zig").PathfindingConfig;
const PathfindingStats = @import("types.zig").PathfindingStats;
const PathQueryKey = @import("types.zig").PathQueryKey;
// Threading for the request-side stages of one update, as `PathfindingSystem` passes it.
const StageThreads = @import("../../../app/thread_system.zig").StageThreads(PathfindingConfig);

/// The fixed per-query group-field threshold (see default_min_group_field_agents), never
/// derived from world size. Clamped to [1, group_field_threshold_ceiling]: the configured
/// max_agent_budget frozen at reserve, NOT live max_pending_requests (a small live crowd
/// never pulls the threshold down) and NOT the live ceiling a seam raise lifts (capacity
/// history never moves the policy). The threshold never demands more sharers than the
/// configured ceiling admits. A pin of 0 clamps to 1.
pub fn groupFieldThreshold(self: *const PathfindingSystem) usize {
    return std.math.clamp(self.capacity.min_group_field_agents, 1, self.group_field_threshold_ceiling);
}

/// Builds/advances managed shared-goal flow fields for declared group goals.
/// Lazy on first request, throttled on goal-cell change, budgeted per frame.
/// The threshold is checked against the cross-step accumulator (acceptRequests),
/// so it reflects SUSTAINED shared-goal demand (~2x per-step intake at
/// equilibrium), not a single-step burst. `group_field_expand` runs the budgeted
/// expansions one field per item: the advance pass over fields building at step
/// start, then the main-thread decisions in tally order (they see the post-advance
/// states), then the begin pass over fields begun this step.
pub fn serviceGroupFields(self: *PathfindingSystem, stats: *PathfindingStats, threads: StageThreads) void {
    if (!self.graph.valid()) return;
    const threshold = groupFieldThreshold(self);
    queueAdvancePass(self);
    const advance_fields = self.group_field_slots.items.len;
    const advance_batch = expandGroupFieldSlots(self, threads, &self.tuners.group_field);
    if (comptime runtime_perf_log.enabled) {
        stats.perf.group_field_batch = advance_batch;
        stats.perf.group_field_step_items = advance_fields;
    }
    var slots_exhausted = false;
    for (self.group_requests.items) |tally| {
        // Only build/maintain a shared flow field once sustained demand for the
        // same goal amortizes its O(cells) build. Smaller groups already took an
        // individual A* solve during acceptance, so a handful of agents never pay
        // the flow-field cost — pathfinding stays cheap at low agent counts and
        // the field engages only at crowd scale.
        if (tally.count < threshold) continue;
        ensureGroupField(self, tally.key, &slots_exhausted, stats);
    }
    self.group_field_slots.clearRetainingCapacity();
    for (self.group_fields.items, 0..) |*field, slot| {
        if (field.fresh_this_step and field.state == .building) {
            field.step_budget_left = self.capacity.group_field_build_budget;
            self.group_field_slots.appendAssumeCapacity(slot);
        }
    }
    const begin_fields = self.group_field_slots.items.len;
    const begin_batch = expandGroupFieldSlots(self, threads, &self.tuners.group_field_begin);
    if (comptime runtime_perf_log.enabled) {
        stats.perf.group_field_begin_batch = begin_batch;
        stats.perf.group_field_begin_step_items = begin_fields;
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

// Queues the step's advance pass in `group_field_slots`: every field building at step start
// whose goal level has a grid, each on a fresh step budget. Clears each field's begun-this-step
// flag.
fn queueAdvancePass(self: *PathfindingSystem) void {
    std.debug.assert(self.group_field_slots.capacity >= self.group_fields.items.len);
    self.group_field_slots.clearRetainingCapacity();
    for (self.group_fields.items, 0..) |*field, slot| {
        field.fresh_this_step = false;
        if (field.state == .building and self.graph.grid(field.key.goal_level) != null) {
            field.step_budget_left = self.capacity.group_field_build_budget;
            self.group_field_slots.appendAssumeCapacity(slot);
        }
    }
}

// Expands every field in `group_field_slots` by the rest of its step budget; each item
// writes only its own field. A field whose pool ran out of room stalls before its pop;
// after the join the main thread grows each stalled field's pool (O(1) per field per
// round, geometric, counted) and expands the stalled fields again, so a step's progress
// never depends on pool capacity. A growth that runs out of memory leaves its field
// stalled for the next step. The pass's rounds run under one selection from its fields and
// record one sample into `tuner` (`RoundDispatch`). Returns the rounds folded into one.
fn expandGroupFieldSlots(self: *PathfindingSystem, threads: StageThreads, tuner: *AdaptiveWorkTuner) BatchStats {
    const fields = self.group_field_slots.items.len;
    if (fields == 0) return .{};
    var rounds = RoundDispatch.begin(threads.stage(tuner), fields);
    while (self.group_field_slots.items.len != 0) {
        const slots = self.group_field_slots.items;
        var job = GroupFieldJob{ .system = self, .slots = slots };
        rounds.run(slots.len, &job, &job.range_count, groupFieldExpandJob);
        var stalled: usize = 0;
        for (slots) |slot| {
            const field = &self.group_fields.items[slot];
            if (!field.stalled) continue;
            if (!growStalledField(self, field)) continue;
            slots[stalled] = slot;
            stalled += 1;
        }
        self.group_field_slots.shrinkRetainingCapacity(stalled);
    }
    return rounds.finish(fields);
}

fn expandGroupField(self: *PathfindingSystem, slot: usize) void {
    const field = &self.group_fields.items[slot];
    _ = field.expand(self.graph.grid(field.key.goal_level).?, &field.step_budget_left);
}

// Grows a stalled field's pool on the main thread; false when it ran out of memory.
fn growStalledField(self: *PathfindingSystem, field: *GroupField) bool {
    field.growForStall(self.allocator, self.graph.grid(field.key.goal_level).?) catch {
        recordGroupFieldPoolFailure(self);
        return false;
    };
    recordGroupFieldPoolGrowth(self, field);
    return true;
}

fn recordGroupFieldPoolGrowth(self: *PathfindingSystem, field: *const GroupField) void {
    self.group_field_pool_growth.record(1, .info, "group field block pool grew to {d} blocks", .{field.blocks.len});
}

fn recordGroupFieldPoolFailure(self: *PathfindingSystem) void {
    self.group_field_pool_failure.record(1, .warn, "group field block pool growth ran out of memory; the field retries next step", .{});
}

// Gives above-threshold goal `key` a field: its own, else a moved goal's field rekeyed
// (throttled), else an empty slot or the field of the least-demanded goal no longer
// requested above the threshold. A field serving an active goal is never taken, so a
// goal past the slots waits on individual solves until a slot frees; `slots_exhausted`
// records that no slot was claimable this step (no later decision of the step can free
// one), so each step scans the slots for claims at most once past its claims.
fn ensureGroupField(self: *PathfindingSystem, key: PathQueryKey, slots_exhausted: *bool, stats: *PathfindingStats) void {
    if (self.group_fields.items.len == 0) return;
    // Exact goal cell already has a field: reuse it (build is still advancing
    // if it has not finished). The goal did not cross into a new cell.
    if (self.group_field_keys.find(key)) |slot| {
        if (comptime runtime_perf_log.enabled) {
            if (!self.group_fields.items[slot].fresh_this_step) stats.perf.group_field_reuses += 1;
        }
        return;
    }
    const goal_grid = self.graph.grid(key.goal_level) orelse return;
    // The step's live goal: the key's cell, or its projection from the goal table.
    const goal_index = self.liveGoal(key, goal_grid).cell orelse return;
    // Same agent class targeting a different (now stale) cell: the declared
    // goal crossed into a new nav cell. Rebuild only if throttle elapsed.
    if (staleGroupSlot(self, key)) |slot| {
        const field = &self.group_fields.items[slot];
        // An in-progress build is never interrupted by a rekey: restarting it discards
        // every cell it has flooded, and a build slower than the throttle window would
        // restart forever without reaching `.ready`. The field keeps advancing every
        // step in serviceGroupFields regardless of this early-out.
        if (field.state == .building) {
            if (comptime runtime_perf_log.enabled) stats.perf.group_field_rebuild_throttled += 1;
            return;
        }
        const elapsed = self.step_counter -% field.last_build_step;
        if (elapsed < self.capacity.group_field_rebuild_min_steps) {
            // Throttled: keep the slightly stale field for general direction.
            if (comptime runtime_perf_log.enabled) stats.perf.group_field_rebuild_throttled += 1;
            return;
        }
        buildGroupSlot(self, slot, key, goal_index, stats);
        return;
    }
    if (slots_exhausted.*) return;
    const slot = claimableGroupSlot(self) orelse {
        slots_exhausted.* = true;
        return;
    };
    if (comptime runtime_perf_log.enabled) {
        if (self.group_fields.items[slot].state != .empty) stats.perf.group_field_evictions += 1;
    }
    buildGroupSlot(self, slot, key, goal_index, stats);
}

// The slot a goal without a field may take: the first empty one, else the field whose
// goal has the least tallied demand among goals below the threshold (lowest slot on a
// tie); null when every field serves an active goal. O(max_group_fields).
fn claimableGroupSlot(self: *const PathfindingSystem) ?usize {
    const threshold = groupFieldThreshold(self);
    var best: ?usize = null;
    var best_demand: usize = threshold;
    for (self.group_fields.items, 0..) |field, slot| {
        if (field.state == .empty) return slot;
        const demand = groupDemand(self, field.key);
        if (demand < best_demand) {
            best = slot;
            best_demand = demand;
        }
    }
    return best;
}

// Begins a build in field `slot` (O(1) on the main thread); the begin pass of
// `group_field_expand` runs its first budgeted expansion. A field's first build reserves
// its pool here; an out-of-memory leaves the field as it was, and a later step's
// decision retries. Keeps the field key map on the slot's key.
fn buildGroupSlot(self: *PathfindingSystem, slot: usize, key: PathQueryKey, goal_index: usize, stats: *PathfindingStats) void {
    const grid = self.graph.grid(key.goal_level) orelse return;
    const field = &self.group_fields.items[slot];
    const max_cells = self.capacity.group_field_max_cells;
    const pool_blocks = field.blocks.len;
    field.reservePool(self.allocator, grid, max_cells, initialPoolBlocks(grid, max_cells, self.capacity.group_field_build_budget)) catch {
        recordGroupFieldPoolFailure(self);
        return;
    };
    if (field.blocks.len != pool_blocks) recordGroupFieldPoolGrowth(self, field);
    if (field.state != .empty) self.group_field_keys.remove(field.key);
    field.fresh_this_step = field.beginBuild(grid, key, goal_index, self.step_counter, max_cells);
    if (!field.fresh_this_step) return;
    if (comptime runtime_perf_log.enabled) stats.perf.group_fields_built += 1;
    // The map holds a key per non-empty field, at most one field per key, and was
    // reserved for every slot.
    const mapped = self.group_field_keys.insert(key, slot);
    std.debug.assert(mapped);
}

/// Empties field `slot` and drops its key from the field key map.
pub fn emptyGroupField(self: *PathfindingSystem, slot: usize) void {
    const field = &self.group_fields.items[slot];
    if (field.state == .empty) return;
    self.group_field_keys.remove(field.key);
    field.state = .empty;
}

// `key`'s tallied requests this step (decayed across steps); 0 when not tallied.
fn groupDemand(self: *const PathfindingSystem, key: PathQueryKey) usize {
    const index = self.group_key_map.find(key) orelse return 0;
    return self.group_requests.items[index].count;
}

// True when `key` is still a live above-threshold group request this step,
// i.e. its own crowd is actively being serviced. Such a slot represents a
// distinct concurrent goal, not a moved-away one, so it must never be rekeyed
// out from under its crowd.
fn isActiveGroupGoal(self: *const PathfindingSystem, key: PathQueryKey) bool {
    return groupDemand(self, key) >= groupFieldThreshold(self);
}

// A stale slot targets the same agent class/version/goal-level but a different
// goal cell whose own crowd is no longer an active above-threshold request —
// the moving-goal case (the declared goal crossed into a new cell, orphaning
// the old field), NOT a second live crowd. Skipping still-active goals is what
// stops two distinct same-class goals from evicting each other's field while
// free slots exist. When several orphaned slots qualify, the one whose stored
// goal is nearest the new goal cell is chosen so rebuild selection is
// deterministic and reuses the most relevant field rather than an arbitrary
// first match. O(max_group_fields).
fn staleGroupSlot(self: *PathfindingSystem, key: PathQueryKey) ?usize {
    var best_index: ?usize = null;
    var best_dist: i64 = std.math.maxInt(i64);
    for (self.group_fields.items, 0..) |field, index| {
        if (field.state == .empty) continue;
        if (std.meta.eql(field.key, key)) continue;
        if (field.key.agent_class != key.agent_class) continue;
        if (field.key.nav_version != key.nav_version) continue;
        if (field.key.goal_level != key.goal_level) continue;
        if (isActiveGroupGoal(self, field.key)) continue;
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

/// The non-empty group field built for `key`, or null. O(1) through the field key map.
pub fn groupFieldOf(self: *const PathfindingSystem, key: PathQueryKey) ?*const GroupField {
    const slot = self.group_field_keys.find(key) orelse return null;
    return &self.group_fields.items[slot];
}

// One range of a `group_field_expand` pass; slot indices are distinct by construction.
const GroupFieldJob = struct {
    system: *PathfindingSystem,
    slots: []const usize,
    range_count: usize = 0,
};

fn groupFieldExpandJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *GroupFieldJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.slots.len);
    for (job.slots[range.start..range.end]) |slot| expandGroupField(job.system, slot);
}

const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathRequest = @import("../../simulation.zig").PathRequest;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const types = @import("types.zig");
const PathStatus = @import("types.zig").PathStatus;
const GroupFieldState = @import("group_field.zig").GroupFieldState;
const test_support = @import("test_support.zig");
const updatePathfindingInline = @import("test_support.zig").updatePathfindingInline;
const addNavBody = test_support.addNavBody;
const appendPathRequest = test_support.appendPathRequest;
const baselineCapacity = test_support.baselineCapacity;
const cellWorld = test_support.cellWorld;
const expectGroupFieldsEqual = test_support.expectGroupFieldsEqual;
const expectRequestStateEqual = test_support.expectRequestStateEqual;
const intake_test_agents = test_support.intake_test_agents;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const registrySystem = test_support.registrySystem;
const registryWorld = test_support.registryWorld;
const stallingFieldCapacity = test_support.stallingFieldCapacity;
const stalling_field_goals = test_support.stalling_field_goals;
const tileCenter = test_support.tileCenter;
const writeGroupGoals = test_support.writeGroupGoals;

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
    // goal dedups to exactly one individual solve while the field is
    // built (and finishes, given the default budget) this same step.
    _ = try updatePathfindingInline(&system, &stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), fieldsBuiltLastStep(&system));
    try std.testing.expectEqual(@as(usize, 1), system.solve_results.items.len);
    var ready_field_count: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready_field_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ready_field_count);

    // Second step: the ready field answers all three; no individual solves, and
    // every agent samples the one shared field.
    _ = try updatePathfindingInline(&system, &stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
    try expectFieldServes(&system, &.{ .{ .x = 8, .y = 8 }, .{ .x = 40, .y = 8 }, .{ .x = 72, .y = 8 } }, goal);
}

// Group fields this step's service began (a build, a rebuild, or a takeover).
fn fieldsBuiltLastStep(system: *const PathfindingSystem) usize {
    var built: usize = 0;
    for (system.group_fields.items) |field| built += @intFromBool(field.fresh_this_step);
    return built;
}

// Each start on level 0 reads `goal` from its ready group field: a field sample's two-point
// view, never a cached path.
fn expectFieldServes(system: *const PathfindingSystem, starts: []const math.Vec2, goal: math.Vec2) !void {
    for (starts) |start| {
        const view = system.statusForWorld(0, start, 0, goal, .default, null);
        try std.testing.expectEqual(PathStatus.available, view.status);
        try std.testing.expectEqual(@as(usize, 2), view.path_len);
    }
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
    _ = try updatePathfindingInline(&system, &stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), fieldsBuiltLastStep(&system));

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    _ = try updatePathfindingInline(&system, &stream, 8, .{});
    system.allocator = original;

    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try expectFieldServes(&system, &.{ .{ .x = 8, .y = 8 }, .{ .x = 40, .y = 8 }, .{ .x = 72, .y = 8 } }, goal);
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
    _ = try updatePathfindingInline(&system, &below, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
    try std.testing.expectEqual(@as(usize, 1), system.solve_results.items.len);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goal, .default, null).status);

    // Three agents (== threshold): the shared field now builds.
    var at = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer at.deinit();
    try at.reserve(3, 3);
    try appendPathRequest(&at, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&at, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&at, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });
    _ = try updatePathfindingInline(&system, &at, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), fieldsBuiltLastStep(&system));
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

    _ = try updatePathfindingInline(&system, &stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
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
        _ = try updatePathfindingInline(&system, &stream, 8, .{});
        rebuild_count += fieldsBuiltLastStep(&system);
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
        _ = try updatePathfindingInline(&system, &stream, 8, .{});
        built_total += fieldsBuiltLastStep(&system);
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
        _ = try updatePathfindingInline(&system, &stream, 8, .{});
        built += fieldsBuiltLastStep(&system);
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
    _ = try updatePathfindingInline(&system, &burst, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));

    // No further group requests: the carried tally halves to zero and compacts away,
    // and no field is ever built.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..3) |_| {
        _ = try updatePathfindingInline(&system, &empty, 8, .{});
        try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
    }
    try std.testing.expectEqual(@as(usize, 0), system.group_requests.items.len);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
    }
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
    _ = try updatePathfindingInline(&system, &first, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), fieldsBuiltLastStep(&system));
    const key = system.graph.keyForWorld(0, .{ .x = 40, .y = 40 }, .default).?;
    const built_step = groupFieldOf(&system, key).?.last_build_step;

    // A goal that stays inside the same nav cell reuses the field, no rebuild.
    var second = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer second.deinit();
    try appendPathRequest(&second, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 56, .y = 56 } });
    _ = try updatePathfindingInline(&system, &second, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
    try std.testing.expectEqualDeep(key, system.graph.keyForWorld(0, .{ .x = 56, .y = 56 }, .default).?);
    try std.testing.expectEqual(built_step, groupFieldOf(&system, key).?.last_build_step);
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
    _ = try updatePathfindingInline(&system, &stream, 8, .{});

    const key = system.graph.keyForWorld(0, goal, .default).?;
    const field_after_first = groupFieldOf(&system, key).?;
    try std.testing.expectEqual(GroupFieldState.building, field_after_first.state);

    // Advance frames until the field completes; it must finish within the cell
    // count given a positive budget.
    var guard: usize = 0;
    while (groupFieldOf(&system, key).?.state == .building and guard < system.graph.cellCount() + 1) : (guard += 1) {
        var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer empty.deinit();
        try empty.reserve(1, 0);
        try empty.prepareRangeCounts(0);
        try empty.prefix();
        empty.finishWrite();
        _ = try updatePathfindingInline(&system, &empty, 8, .{});
    }
    try std.testing.expect(guard > 0);
    try std.testing.expectEqual(GroupFieldState.ready, groupFieldOf(&system, key).?.state);
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
        _ = try updatePathfindingInline(&system, &stream, 2, .{});
        built += fieldsBuiltLastStep(&system);
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

// Blocks every group field's pool holds.
fn fieldPoolBlocks(system: *const PathfindingSystem) usize {
    var blocks: usize = 0;
    for (system.group_fields.items) |field| blocks += field.blocks.len;
    return blocks;
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

// Four goals build, the fourth moves (a rekey), then a fifth arrives while every field
// serves an active goal (it waits) and the first goal goes quiet (the fifth rekeys its field
// once its demand decays below the threshold).
const group_service_schedule = [_][]const math.Vec2{
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(7, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7) },
    &.{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
    &.{ cellWorld(13, 13), cellWorld(13, 2), cellWorld(8, 7), cellWorld(4, 4) },
};

test "threaded group-field service equals serial for four fields building, finishing, rekeyed, and taken over by a waiting goal" {
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

    var built_total: usize = 0;
    const waiting = serial.graph.keyForWorld(0, cellWorld(4, 4), .default).?;
    var waited_steps: usize = 0;
    for (group_service_schedule) |goals| {
        try writeGroupGoals(&stream, requester, goals);
        _ = try updatePathfindingInline(&serial, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
        _ = try threaded.update(&stream, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 1, .max_solve_admissions_per_step = 0 });
        try expectGroupFieldsEqual(&serial, &threaded);
        try expectRequestStateEqual(&serial, &threaded);
        built_total += fieldsBuiltLastStep(&serial);
        if (goals.len == 5 or (groupDemand(&serial, waiting) != 0 and groupFieldOf(&serial, waiting) == null)) waited_steps += 1;
    }
    // The schedule builds four fields, finishes them, rekeys the moved goal, keeps the fifth
    // goal waiting while every field serves an active goal, then gives it the quiet goal's.
    var ready: usize = 0;
    for (serial.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
    try std.testing.expect(ready > 0);
    try std.testing.expect(built_total > 4);
    try std.testing.expect(waited_steps >= 2);
    try std.testing.expect(groupFieldOf(&serial, waiting) != null);
}

test "group-field service allocates nothing on workers (FailingAllocator, multi-worker)" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = try groupFieldServiceSystem(&data, threads.participantSlotCount());
    defer system.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(16, 16);
    const config = PathfindingConfig{ .adaptive = false, .items_per_range = 1, .max_solve_admissions_per_step = 0 };
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
    _ = try system.update(&stream, intake_test_agents, &threads, config);
    try std.testing.expectEqual(@as(usize, 2), fieldsBuiltLastStep(&system));
}

test "threaded group-field service with stall rounds equals serial and runs on workers" {
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
    for (0..80) |_| _ = try updatePathfindingInline(&warm, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
    warm.clearRuntimeState();
    const warm_blocks = fieldPoolBlocks(&warm);
    const cold_blocks = fieldPoolBlocks(&serial);

    for (0..80) |_| {
        _ = try updatePathfindingInline(&serial, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
        _ = try threaded.update(&stream, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 1, .max_solve_admissions_per_step = 0 });
        _ = try updatePathfindingInline(&warm, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
        try expectGroupFieldsEqual(&serial, &threaded);
        try expectRequestStateEqual(&serial, &threaded);
        // Stalled fields resume in the same step: per-step progress never depends on pools.
        for (serial.group_fields.items, warm.group_fields.items) |cold_field, warm_field| {
            try std.testing.expectEqual(warm_field.state, cold_field.state);
            try std.testing.expectEqual(warm_field.pushed_count, cold_field.pushed_count);
            try std.testing.expectEqual(warm_field.current_distance, cold_field.current_distance);
        }
    }
    // Pools grew past their first-build size on both, alike; never when warm.
    try std.testing.expectEqual(warm_blocks, fieldPoolBlocks(&warm));
    try std.testing.expect(fieldPoolBlocks(&serial) > cold_blocks);
    try std.testing.expectEqual(fieldPoolBlocks(&serial), fieldPoolBlocks(&threaded));
    var ready: usize = 0;
    for (serial.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
    try std.testing.expectEqual(@as(usize, 4), ready);
}

test "a group-field pass whose fields stall records one tuner sample over all its rounds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(stallingFieldCapacity(threads.participantSlotCount()));
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeGroupGoals(&stream, requester, &stalling_field_goals);
    const config = PathfindingConfig{ .max_solve_admissions_per_step = 0 };
    _ = try system.update(&stream, intake_test_agents, &threads, config);
    // Advance passes, each on a fresh tuner, until one stalls: its pools grow, so it ran more
    // than one round.
    var passes: usize = 0;
    while (true) : (passes += 1) {
        try std.testing.expect(passes < 80);
        queueAdvancePass(&system);
        const fields = system.group_field_slots.items.len;
        try std.testing.expect(fields != 0);
        const blocks = fieldPoolBlocks(&system);
        var tuner = AdaptiveWorkTuner.init(.{});
        const pass = expandGroupFieldSlots(&system, .{ .thread_system = &threads, .config = config }, &tuner);
        try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
        if (fieldPoolBlocks(&system) == blocks) continue;
        // Every round folds into the pass's batch and its one sample: the stalled fields ran
        // again past the pass's fields, and the sample is the whole pass's time.
        try std.testing.expect(pass.item_count > fields);
        try std.testing.expectEqual(pass.batch_duration_ns, tuner.sample_durations_ns[0]);
        break;
    }
}

test "a first group-field build that cannot allocate builds nothing and retries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeGroupGoals(&stream, requester, stalling_field_goals[0..1]);
    const config = PathfindingConfig{ .max_solve_admissions_per_step = 0 };

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    try writeGroupGoals(&empty, requester, &.{});

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(stallingFieldCapacity(1));
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    // A request-free step sizes the per-step pools for the agent count first.
    _ = try updatePathfindingInline(&system, &empty, intake_test_agents, config);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    _ = try updatePathfindingInline(&system, &stream, intake_test_agents, config);
    system.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), fieldsBuiltLastStep(&system));
    try std.testing.expect(system.group_field_pool_failure.logged);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
        try std.testing.expectEqual(@as(usize, 0), test_support.groupFieldResidentBytes(&field));
    }

    // The next step builds the same field a fresh system builds on its first step.
    _ = try updatePathfindingInline(&system, &stream, intake_test_agents, config);
    try std.testing.expectEqual(@as(usize, 1), fieldsBuiltLastStep(&system));
    var fresh = PathfindingSystem.init(std.testing.allocator);
    defer fresh.deinit();
    try fresh.reserve(stallingFieldCapacity(1));
    try fresh.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    _ = try updatePathfindingInline(&fresh, &empty, intake_test_agents, config);
    _ = try updatePathfindingInline(&fresh, &stream, intake_test_agents, config);
    const grid = system.graph.grid(0).?;
    const field = &system.group_fields.items[0];
    const expected = &fresh.group_fields.items[0];
    try std.testing.expectEqual(GroupFieldState.building, field.state);
    try std.testing.expectEqual(expected.pushed_count, field.pushed_count);
    try std.testing.expectEqual(expected.used_blocks, field.used_blocks);
    for (0..grid.cellCount()) |cell| try std.testing.expectEqualDeep(expected.lookup(grid, cell), field.lookup(grid, cell));
}

test "a group field for a blocked goal builds at the goal table's live goal" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    for (9..12) |y| {
        for (9..12) |x| _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), @intCast(y), fixture.tree);
    }
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goal = tileCenter(10, 10);
    for (0..3) |index| try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = tileCenter(@intCast(2 + index), 2), .goal = goal });
    _ = try system.resolveGoals(PathRequest, stream.mergedItems(), &serial_threads, .{});
    try std.testing.expectEqual(@as(usize, 1), system.goals.refs.items.len);
    // The decision reads the table's entry: point it at another open cell.
    const grid = system.graph.grid(0).?;
    const table_goal: u32 = 8 * 24 + 12;
    try std.testing.expect(!grid.isBlockedIndex(table_goal) and table_goal != system.goals.live.items[0]);
    system.goals.live.items[0] = table_goal;
    _ = try updatePathfindingInline(&system, &stream, 16, .{ .max_solve_admissions_per_step = 0 });
    const field = groupFieldOf(&system, system.graph.keyForWorld(0, goal, .default).?).?;
    try std.testing.expectEqual(@as(usize, table_goal), field.goal_index);
}

test "group fields past their slots never evict an active goal's field: the slotted goals stay ready and the extra goal takes individual solves" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_group_fields = 2;
    // A 256-cell flood at 32 pops per step: each build spans several steps.
    capacity.group_field_build_budget = 32;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    const goals = [_]math.Vec2{ cellWorld(2, 13), cellWorld(13, 13), cellWorld(13, 2) };
    var keys: [goals.len]PathQueryKey = undefined;
    for (&keys, goals) |*key, goal| key.* = system.graph.keyForWorld(0, goal, .default).?;
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeGroupGoals(&stream, requester, &goals);
    var built: usize = 0;
    var ready_since: [2]?usize = .{ null, null };
    for (0..24) |step| {
        _ = try updatePathfindingInline(&system, &stream, 16, .{});
        built += fieldsBuiltLastStep(&system);
        for (keys[0..2], &ready_since) |key, *since| {
            const field = groupFieldOf(&system, key) orelse return error.TestExpectedField;
            if (field.state == .ready and since.* == null) since.* = step;
            // Once ready, a slotted goal's field stays ready.
            if (since.* != null) try std.testing.expectEqual(GroupFieldState.ready, field.state);
        }
        try std.testing.expect(groupFieldOf(&system, keys[2]) == null);
    }
    try std.testing.expectEqual(@as(usize, 2), built);
    for (ready_since) |since| try std.testing.expect(since != null);
    // The waiting goal's sharers walk an individual cached path.
    const view = system.statusForWorld(0, cellWorld(0, 2), 0, goals[2], .default, null);
    try std.testing.expectEqual(PathStatus.available, view.status);
    try std.testing.expect(view.path_len > 2);
}

test "a field capped below a 2048-cell level readies within its build steps, and an uncovered sharer takes an individual solve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.group_field_max_cells = types.default_group_field_max_cells;
    capacity.max_group_fields = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 2048 * 32, 2048 * 32, 32);
    const goal = cellWorld(1024, 1024);
    // The far sharer, first and so the individual solve's representative, lies past the
    // capped flood's ~200-cell reach and inside the tier-0 stitched cap; the near one inside.
    const far = cellWorld(1424, 1024);
    const near = cellWorld(1034, 1024);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = far, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = near, .goal = goal });
    const key = system.graph.keyForWorld(0, goal, .default).?;
    var steps: usize = 0;
    while (steps <= types.default_group_field_max_build_steps) : (steps += 1) {
        _ = try updatePathfindingInline(&system, &stream, 8, .{});
        try std.testing.expect(system.statusForWorld(0, far, 0, goal, .default, null).status != .unavailable);
        if (groupFieldOf(&system, key).?.state == .ready) break;
    }
    const field = groupFieldOf(&system, key).?;
    try std.testing.expectEqual(GroupFieldState.ready, field.state);
    try std.testing.expectEqual(types.default_group_field_max_cells, field.pushed_count);
    const near_view = system.statusForWorld(0, near, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.available, near_view.status);
    try std.testing.expectEqual(@as(usize, 2), near_view.path_len);
    // Further steps sample the field for the near sharer only; the far one keeps its path.
    for (0..3) |_| {
        _ = try updatePathfindingInline(&system, &stream, 8, .{});
        try expectFieldServes(&system, &.{near}, goal);
        const far_step = system.statusForWorld(0, far, 0, goal, .default, null);
        try std.testing.expect(far_step.status != .unavailable);
        try std.testing.expect(far_step.path_len != 2);
    }
    const far_view = system.statusForWorld(0, far, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.available, far_view.status);
    try std.testing.expect(far_view.path_len > 2);
}
