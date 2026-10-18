// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The request intake of `PathfindingSystem`: each step's requests classify against
//! step-start state into their range's windows (`path_intake`, threaded per request range),
//! then the main thread merges the windows in range order into the group tallies,
//! expired-result removals, and pending pushes, O(records + group keys). Free functions over
//! `*PathfindingSystem`; the system calls them directly.

const std = @import("std");
const simd = @import("../../../core/simd.zig");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const stageShape = @import("../../../app/thread_system.zig").stageShape;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const PathRequest = @import("../../simulation.zig").PathRequest;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ResultCache = @import("caches.zig").ResultCache;
const group_service = @import("group_service.zig");
const positionCells = @import("goal_table.zig").positionCells;
const types = @import("types.zig");
const PathfindingConfig = @import("types.zig").PathfindingConfig;
const PathfindingStats = @import("types.zig").PathfindingStats;
const PathQueryKey = @import("types.zig").PathQueryKey;
const GridCell = @import("types.zig").GridCell;
const IntakeRecord = @import("types.zig").IntakeRecord;
const GroupKeyCount = @import("types.zig").GroupKeyCount;
const IntakeTally = @import("types.zig").IntakeTally;
const intake_range_alignment_items = @import("types.zig").intake_range_alignment_items;
const StepGates = PathfindingSystem.StepGates;
// Threading for the request-side stages of one update, as `PathfindingSystem` passes it.
const StageThreads = @import("../../../app/thread_system.zig").StageThreads(PathfindingConfig);

/// `path_intake` record windows, one per range, on thread-shared record alignment.
pub const IntakeRecordList = std.array_list.Aligned(IntakeRecord, .fromByteUnits(thread_shared_record_alignment));
/// `path_intake` group-key windows, one per range, on thread-shared record alignment.
pub const GroupKeyCountList = std.array_list.Aligned(GroupKeyCount, .fromByteUnits(thread_shared_record_alignment));
/// One padded `path_intake` tally per range.
pub const IntakeTallyList = std.array_list.Aligned(IntakeTally, .fromByteUnits(thread_shared_record_alignment));

/// `path_intake`: ranges (one inline range without a thread system or when the tuner keeps
/// the stage inline) classify against step-start state into their windows (a record per
/// new or expired key, repeats folded; a group-key entry per key), then the main thread
/// merges the windows in range order: group tallies, expired-result removal, in-step
/// duplicates, the pending cap, and pending pushes, O(records + group keys). One
/// classifier for every partition, equal to the serial request-order loop. Acceptance is
/// the only stage that mutates the pending-key set; cached hits never enter pending work.
pub fn acceptRequests(self: *PathfindingSystem, requests: []const PathRequest, gates: StepGates, threads: StageThreads) PathfindingStats {
    var stats = PathfindingStats{};
    // Cross-step decaying accumulation: halve every carried tally before this
    // step's requests fold in, so a SUSTAINED shared goal accumulates toward the
    // threshold (~2x per-step intake at equilibrium) while a transient burst
    // decays back to zero. Runs every step (even with no requests) so a crowd
    // that stops requesting decays away. Zero-count tallies are compacted after
    // threshold-service in serviceGroupFields.
    for (self.group_requests.items) |*tally| tally.count /= 2;
    if (comptime runtime_perf_log.enabled) stats.perf.pending_requests = self.pending.len;
    if (requests.len == 0 or !self.graph.valid()) return stats;
    // At most one request per steering agent. The clamp to the staging's logical size is
    // a release-build memory guard only: once the pools cover the gates it never drops.
    std.debug.assert(requests.len <= gates.frame_requests);
    const item_count = @min(requests.len, self.limits.frame_requests);
    if (comptime runtime_perf_log.enabled) stats.perf.dropped_requests += requests.len - item_count;
    if (item_count == 0) return stats;
    const dispatch = threads.stage(&self.tuners.intake);
    const shape = stageShape(dispatch, item_count, intake_range_alignment_items);
    std.debug.assert(self.intake_records.capacity >= item_count);
    std.debug.assert(self.intake_group_counts.capacity >= item_count);
    std.debug.assert(self.intake_tallies.capacity >= shape.range_count);
    self.intake_records.items.len = item_count;
    self.intake_group_counts.items.len = item_count;
    self.intake_tallies.items.len = shape.range_count;
    @memset(self.intake_tallies.items, .{});
    var job = IntakeJob{
        .system = self,
        .requests = requests[0..item_count],
        .items_per_range = shape.items_per_range,
        .records = self.intake_records.items,
        .group_counts = self.intake_group_counts.items,
        .tallies = self.intake_tallies.items,
    };
    stats.intake_batch = runShaped(dispatch, shape, item_count, intake_range_alignment_items, &job, intakeJob);
    mergeIntake(self, shape.items_per_range, gates, &stats);
    if (comptime runtime_perf_log.enabled) stats.perf.pending_requests = self.pending.len;
    return stats;
}

// How intake answers one request past its group field: unavailable when no open goal
// cell lies within the projection radius or an open start cannot reach the live goal;
// a hit when a fresh cached result was solved toward the live goal, unless it is
// partial and the start lies in its end's refresh window; else a candidate (a cached
// result toward an older projection, or a partial asked for its next hop, is replaced by
// the candidate's solve). A blocked start is a candidate, dropped at solve. O(1) with
// the step's goal table. Const.
fn intakeAnswer(self: *const PathfindingSystem, key: PathQueryKey, start_level: u16, start: GridCell, goal_grid: *const NavGrid, cached: ?ResultCache.SlotLookup) IntakeAnswer {
    const live = self.liveGoal(key, goal_grid);
    var answer = IntakeAnswer{};
    if (comptime runtime_perf_log.enabled) answer.perf = .{ .projected = live.perf.blocked, .fallback = live.perf.fallback };
    const goal_index = live.cell orelse {
        answer.kind = .unavailable;
        return answer;
    };
    // The level was checked against the graph's levels, and a clamped start is in-grid.
    const start_index = self.graph.grid(start_level).?.indexForCell(start).?;
    if (self.reaches(key.agent_class, start_level, start_index, key.goal_level, goal_index) == .unreachable_goal) {
        answer.kind = .unavailable;
        return answer;
    }
    if (cached) |found| {
        if (found.fresh and found.goal_cell == goal_index) {
            const refresh = types.isPartialEnd(found.end, key.goal_level, found.goal_cell) and
                types.inPartialRefreshWindow(self.graph.chunkGeometry(), found.end, start_level, start_index);
            if (!refresh) answer.kind = .hit;
        }
    }
    return answer;
}

const IntakeAnswer = struct {
    kind: enum { unavailable, hit, candidate } = .candidate,
    perf: Perf = .{},

    // Kept only with `runtime_perf_log.enabled`: the live goal's blocked and fallback flags
    // (`PathfindingSystem.LiveGoal.perf`), for the merge's projected and fallback counts.
    const Perf = if (runtime_perf_log.enabled) struct {
        projected: bool = false,
        fallback: bool = false,
    } else struct {};
};

// A ready group field answers only members on the goal level whose own cell it
// covers; an off-level member or a sample miss falls through to an individual
// request, mirroring statusForKeyAndStart.
fn groupFieldServes(self: *const PathfindingSystem, key: PathQueryKey, goal_grid: *const NavGrid, start: GridCell) bool {
    const field = group_service.groupFieldOf(self, key) orelse return false;
    if (field.state != .ready) return false;
    const start_index = goal_grid.indexForCell(start) orelse return false;
    return field.sample(goal_grid, start_index) != null;
}

// Classifies `requests[start..end]` into the `[start, end)` windows of `records` and
// `group_counts`. Reads only state the intake merge never changes, except expiry and
// pending keys, which the records carry for the merge to resolve in request order.
// SIMD verdict: start and goal cells four-lane (`positionCells`); each request's answer
// is a branchy chain of hash probes (group fields, cache, pending) and reach reads, scalar.
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
        var block_starts: [simd.lane_count]GridCell = undefined;
        var block_goals: [simd.lane_count]GridCell = undefined;
        positionCells(PathRequest, "start", extent_grid, block, block_starts[0..block.len]);
        positionCells(PathRequest, "goal", extent_grid, block, block_goals[0..block.len]);
        for (block, block_starts[0..block.len], block_goals[0..block.len]) |request, start_cell, goal_cell| {
            // Reject (drop, never clamp) an out-of-range level: the query path
            // rejects the same condition as unavailable, so a clamped solve could
            // never be read back by its requester.
            if (request.goal_level >= level_count or request.start_level >= level_count) {
                if (comptime runtime_perf_log.enabled) tally.perf.dropped_requests += 1;
                continue;
            }
            const key = PathQueryKey{
                .nav_version = self.graph.version,
                .agent_class = request.agent_class,
                .goal_level = request.goal_level,
                .goal = goal_cell,
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
                if (request.start_level == request.goal_level and groupFieldServes(self, key, goal_grid, start_cell)) {
                    if (comptime runtime_perf_log.enabled) {
                        tally.perf.group_field_samples += 1;
                        tally.perf.duplicate_requests += 1;
                    }
                    continue;
                }
            }
            const cached = self.completed.lookup(key, self.step_counter, types.default_cache_ttl_steps);
            const answer = intakeAnswer(self, key, request.start_level, start_cell, goal_grid, cached);
            if (comptime runtime_perf_log.enabled) {
                if (answer.perf.fallback) tally.perf.goal_fallbacks += 1;
            }
            var record = IntakeRecord{
                .entity = request.entity,
                .key = key,
                .start_level = request.start_level,
                .start = start_cell,
                // A fresh result toward an older projection is neither served nor
                // expired: the candidate's publish replaces it.
                .expired = cached != null and !cached.?.fresh,
                .candidate = false,
            };
            if (comptime runtime_perf_log.enabled) record.perf.projected = answer.perf.projected;
            switch (answer.kind) {
                .unavailable => if (comptime runtime_perf_log.enabled) {
                    tally.perf.unavailable_results += 1;
                },
                .hit => {
                    if (comptime runtime_perf_log.enabled) {
                        tally.perf.duplicate_requests += 1;
                        tally.perf.cache_hits += 1;
                        tally.perf.available_results += 1;
                    }
                    continue;
                },
                .candidate => if (self.pending_keys.contains(key)) {
                    if (comptime runtime_perf_log.enabled) tally.perf.duplicate_requests += 1;
                } else {
                    record.candidate = true;
                },
            }
            if (!record.candidate and !record.expired) continue;
            // A repeat of a key in this range carries its first record's removal and folds
            // into it; only a candidate's repeats count in the merge. A start that reaches
            // the goal makes a candidate of a key whose first record was not one (its start
            // could not), which takes a record of its own.
            if (recent_records.find(key)) |entry| {
                if (record_window[entry].candidate) {
                    if (comptime runtime_perf_log.enabled) {
                        if (record.candidate) record_window[entry].perf.repeats += 1;
                    }
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
fn mergeIntake(self: *PathfindingSystem, items_per_range: usize, gates: StepGates, stats: *PathfindingStats) void {
    for (self.intake_tallies.items, 0..) |tally, range_index| {
        const window_start = range_index * items_per_range;
        for (self.intake_group_counts.items[window_start..][0..tally.group_key_count]) |entry| {
            recordGroupRequestCount(self, entry.key, entry.count, gates.group_tallies);
        }
        for (self.intake_records.items[window_start..][0..tally.record_count]) |record| {
            mergeIntakeRecord(self, record, gates.pending_requests, stats);
        }
        if (comptime runtime_perf_log.enabled) {
            stats.perf.dropped_requests += tally.perf.dropped_requests;
            stats.perf.duplicate_requests += tally.perf.duplicate_requests;
            stats.perf.cache_hits += tally.perf.cache_hits;
            stats.perf.available_results += tally.perf.available_results;
            stats.perf.unavailable_results += tally.perf.unavailable_results;
            stats.perf.group_field_samples += tally.perf.group_field_samples;
            stats.perf.goal_fallbacks += tally.perf.goal_fallbacks;
        }
    }
}

// A candidate past `pending_gate` drops deterministically in merge order; its key stays
// absent, so its requester reads `.missing` and re-requests.
fn mergeIntakeRecord(self: *PathfindingSystem, record: IntakeRecord, pending_gate: usize, stats: *PathfindingStats) void {
    if (record.expired) {
        // Removes the result that expired before this step; a repeat finds none.
        const fresh = self.completed.findFresh(record.key, self.step_counter, types.default_cache_ttl_steps);
        std.debug.assert(fresh == null);
    }
    if (!record.candidate) return;
    // Repeats follow their first occurrence: pending cannot shrink during intake, so a
    // repeat after an accept or a duplicate is a duplicate and after a drop is a drop.
    if (self.pending_keys.contains(record.key)) {
        if (comptime runtime_perf_log.enabled) stats.perf.duplicate_requests += 1 + record.perf.repeats;
        return;
    }
    if (self.pending.len >= pending_gate) {
        if (comptime runtime_perf_log.enabled) stats.perf.dropped_requests += 1 + record.perf.repeats;
        return;
    }
    // The pool and the key set hold the gate (asserted in `beginUpdate`).
    std.debug.assert(self.pending.len < self.limits.pending_requests);
    if (comptime runtime_perf_log.enabled) stats.perf.duplicate_requests += record.perf.repeats;
    self.pending.pushBackAssumeCapacity(.{
        .entity = record.entity,
        .key = record.key,
        .start_level = record.start_level,
        .start = record.start,
    });
    const registered = self.pending_keys.insert(record.key);
    std.debug.assert(registered);
    if (comptime runtime_perf_log.enabled) {
        stats.perf.accepted_requests += 1;
        if (record.perf.projected) stats.perf.goal_projected += 1;
    }
}

// Adds `count` requests for `key` to the step's group tallies, in first-occurrence
// order across the merge; a new key past `tally_gate` distinct tallies is refused.
fn recordGroupRequestCount(self: *PathfindingSystem, key: PathQueryKey, count: usize, tally_gate: usize) void {
    if (self.group_key_map.find(key)) |group_index| {
        self.group_requests.items[group_index].count += count;
        return;
    }
    // Gate on the step's logical gate, never group_requests' physical .capacity:
    // ensureTotalCapacity rounds up past the logical size group_key_map is reserved to,
    // and appending into that slack would drop the map registration and split one
    // goal's tally across slots. The pools hold the gate (asserted in `beginUpdate`).
    if (self.group_requests.items.len < tally_gate) {
        std.debug.assert(self.group_requests.items.len < self.limits.solves_per_step);
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
    job.tallies[range.index] = classifyIntakeRange(job.system, job.requests, range.start, range.end, job.records, job.group_counts);
}

// The window entry of each recently seen key in one intake range.
const RecentKeys = @import("types.zig").RecentKeys(PathQueryKey, usize);

const builtin = @import("builtin");
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const test_support = @import("test_support.zig");
const updatePathfindingInline = @import("test_support.zig").updatePathfindingInline;
const addNavBody = test_support.addNavBody;
const appendIndividual = test_support.appendIndividual;
const appendPathRequest = test_support.appendPathRequest;
const baselineCapacity = test_support.baselineCapacity;
const cellWorld = test_support.cellWorld;
const expectRequestStateEqual = test_support.expectRequestStateEqual;
const intake_test_agents = test_support.intake_test_agents;
const publishTestPath = test_support.publishTestPath;
const statusOf = test_support.statusOf;
const PathStatus = @import("types.zig").PathStatus;
const goalRef = @import("goal_table.zig").goalRef;
const default_goal_projection_radius = @import("types.zig").default_goal_projection_radius;

test "pathfinding group tally refuses over-cap distinct keys without desyncing the map" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    // The logical per-step cap governs how many distinct group tallies may register:
    // group_requests is reserved to it, but group_key_map refuses inserts past exactly
    // this cap. recordGroupRequestCount must gate the new-group append on the LOGICAL cap, not
    // the ArrayList's physical .capacity — otherwise appends into physical slack outrun the
    // dropped map registrations and split one goal's count across duplicate slots.
    const logical_cap = system.limits.solves_per_step;
    try std.testing.expect(logical_cap >= 2);

    // Force physical slack above the logical cap so the logical/physical divergence is
    // exercised deterministically regardless of the allocator's size-class rounding.
    try system.group_requests.ensureTotalCapacity(system.allocator, logical_cap * 4);
    try std.testing.expect(system.group_requests.capacity > logical_cap);

    // A repeated key must accumulate in ONE slot, never spawn duplicates.
    const repeated = PathQueryKey{ .nav_version = 1, .agent_class = .default, .goal = .{ .x = 0, .y = 0 } };
    recordGroupRequestCount(&system, repeated, 1, logical_cap);
    recordGroupRequestCount(&system, repeated, 2, logical_cap);

    // Drive more distinct goals than the logical cap in a single step.
    var made: usize = 0;
    while (made < logical_cap + 5) : (made += 1) {
        recordGroupRequestCount(&system, .{ .nav_version = 1, .agent_class = .default, .goal = .{ .x = @intCast(made + 1), .y = 0 } }, 1, logical_cap);
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

const IntakeGoals = struct {
    const hit = cellWorld(1, 1);
    const expired = cellWorld(2, 1);
    // Open goals in the sealed pocket (`addIntakeBodies`), the second with an expired path.
    const sealed = cellWorld(14, 7);
    const expired_sealed = cellWorld(15, 6);
    // Blocked, its nearest open cell in the sealed pocket.
    const sealed_blocked = cellWorld(15, 8);
    const field = cellWorld(8, 8);
    const group = cellWorld(12, 5);
    // Inside the static body below: projected to an open cell; its cached path ends
    // elsewhere.
    const blocked = cellWorld(10, 4);

    fn prefilled(index: usize) math.Vec2 {
        return cellWorld(@intCast(index % 16), @intCast(15 - index / 16));
    }

    fn distinct(index: usize) math.Vec2 {
        return cellWorld(@intCast(index % 16), @intCast(10 + index / 16));
    }
};

const intake_prefilled_count: usize = 30;

// The scenario's static bodies: the blocked goal's cell, and a pocket of cells
// (14..15, 6..8) sealed by walls at rows 5 and 9 and column 13, with its corner (15, 8)
// blocked.
fn addIntakeBodies(data: *DataSystem) !void {
    _ = try addNavBody(data, IntakeGoals.blocked, .{ .x = 32, .y = 32 }, true);
    _ = try addNavBody(data, .{ .x = 416, .y = 160 }, .{ .x = 96, .y = 32 }, true);
    _ = try addNavBody(data, .{ .x = 416, .y = 288 }, .{ .x = 96, .y = 32 }, true);
    _ = try addNavBody(data, .{ .x = 416, .y = 192 }, .{ .x = 32, .y = 96 }, true);
    _ = try addNavBody(data, .{ .x = 480, .y = 256 }, .{ .x = 32, .y = 32 }, true);
}

/// A 16x16-cell system at `intake_test_agents` agents holding, before the step under
/// test: 31 pending entries, a ready group field, one fresh cached result, three expired
/// ones (one at a sealed goal, one also pending), and a fresh one at the blocked goal
/// that ends off its projection.
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
    _ = try updatePathfindingInline(&system, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(intake_prefilled_count + 1, system.pending.len);

    const step = system.step_counter;
    var put_stats = PathfindingStats{};
    const path = [_]u32{ 17, 18 };
    const key = struct {
        fn of(s: *const PathfindingSystem, goal: math.Vec2) PathQueryKey {
            return s.graph.keyForWorld(0, goal, .default).?;
        }
    }.of;
    // Ends at the hit goal's cell (1, 1).
    const hit_path = [_]u32{ 18, 17 };
    try publishTestPath(&system, key(&system, IntakeGoals.hit), &hit_path, step, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.expired), &path, step -% 400, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.expired_sealed), &path, step -% 400, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.prefilled(0)), &path, step -% 400, &put_stats);
    try publishTestPath(&system, key(&system, IntakeGoals.blocked), &path, step, &put_stats);
    return system;
}

// Forty requests crossing every intake class, with repeats in different ranges.
fn writeIntakeScenarioRequests(stream: *RangeOutputStream(PathRequest), entity: EntityId) !void {
    const Kind = enum { hit, expired, sealed, field, out_of_range, blocked, expired_sealed, sealed_blocked, prefilled, group, distinct };
    const Item = struct { kind: Kind, index: usize = 0 };
    const items = [_]Item{
        .{ .kind = .hit },                   .{ .kind = .expired },               .{ .kind = .sealed },                .{ .kind = .field },
        .{ .kind = .out_of_range },          .{ .kind = .blocked },               .{ .kind = .expired_sealed },        .{ .kind = .distinct },
        .{ .kind = .prefilled, .index = 1 }, .{ .kind = .group },                 .{ .kind = .prefilled },             .{ .kind = .distinct, .index = 1 },
        .{ .kind = .distinct, .index = 2 },  .{ .kind = .distinct, .index = 3 },  .{ .kind = .prefilled, .index = 2 }, .{ .kind = .sealed_blocked },
        .{ .kind = .distinct, .index = 5 },  .{ .kind = .distinct, .index = 6 },  .{ .kind = .field },                 .{ .kind = .distinct, .index = 7 },
        .{ .kind = .distinct, .index = 8 },  .{ .kind = .distinct, .index = 9 },  .{ .kind = .distinct, .index = 10 }, .{ .kind = .distinct, .index = 11 },
        .{ .kind = .hit },                   .{ .kind = .prefilled, .index = 3 }, .{ .kind = .distinct, .index = 12 }, .{ .kind = .distinct, .index = 13 },
        .{ .kind = .group },                 .{ .kind = .distinct, .index = 14 }, .{ .kind = .expired },               .{ .kind = .sealed },
        .{ .kind = .distinct, .index = 15 }, .{ .kind = .group },                 .{ .kind = .blocked },               .{ .kind = .distinct, .index = 16 },
        .{ .kind = .distinct, .index = 17 }, .{ .kind = .sealed_blocked },        .{ .kind = .distinct },              .{ .kind = .distinct, .index = 19 },
    };
    comptime std.debug.assert(items.len == intake_test_agents);
    for (items, 0..) |item, position| {
        var request = PathRequest{ .entity = entity, .start = cellWorld(@intCast(position % 6), 2), .goal = undefined };
        request.goal = switch (item.kind) {
            .hit => IntakeGoals.hit,
            .expired => IntakeGoals.expired,
            .sealed => IntakeGoals.sealed,
            .field => IntakeGoals.field,
            .out_of_range => IntakeGoals.hit,
            .blocked => IntakeGoals.blocked,
            .expired_sealed => IntakeGoals.expired_sealed,
            .sealed_blocked => IntakeGoals.sealed_blocked,
            .prefilled => IntakeGoals.prefilled(item.index),
            .group => IntakeGoals.group,
            .distinct => IntakeGoals.distinct(item.index),
        };
        if (item.kind == .out_of_range) request.goal_level = 3;
        if (item.kind == .field or item.kind == .group) request.kind = .group;
        try appendPathRequest(stream, request);
    }
}

// The goal table over the scenario's first 15 requests: it holds the blocked goal, and
// the sealed blocked goal stays a fallback.
const intake_table_requests: usize = 15;

test "threaded request intake equals serial intake across range sizes and worker counts" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try addIntakeBodies(&data);
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeIntakeScenarioRequests(&stream, requester);
    const table_requests = stream.mergedItems()[0..intake_table_requests];

    var serial = try intakeScenarioSystem(&data, requester, 1);
    defer serial.deinit();
    _ = try serial.resolveGoals(PathRequest, table_requests, &serial_threads, .{});
    _ = try updatePathfindingInline(&serial, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(intake_test_agents, serial.pending.len);
    const key = struct {
        fn of(s: *const PathfindingSystem, goal: math.Vec2) PathQueryKey {
            return s.graph.keyForWorld(0, goal, .default).?;
        }
    }.of;
    // The scenario reaches every class. The two field requests (from cells (3, 2) and
    // (0, 2)) read the ready field, and the two hits their fresh path without queuing.
    for ([_]math.Vec2{ cellWorld(3, 2), cellWorld(0, 2) }) |start| {
        const view = serial.statusForWorld(0, start, 0, IntakeGoals.field, .default, null);
        try std.testing.expectEqual(PathStatus.available, view.status);
        try std.testing.expectEqual(@as(usize, 2), view.path_len);
    }
    try std.testing.expectEqual(PathStatus.available, statusOf(&serial, cellWorld(0, 2), IntakeGoals.hit));
    try std.testing.expect(!serial.pending_keys.contains(key(&serial, IntakeGoals.hit)));
    // Two sealed requests, the expired sealed one, and two sealed blocked ones read
    // unavailable from reach, never pending.
    for ([_]math.Vec2{ IntakeGoals.sealed, IntakeGoals.expired_sealed, IntakeGoals.sealed_blocked }) |goal| {
        try std.testing.expectEqual(PathStatus.unavailable, statusOf(&serial, cellWorld(0, 2), goal));
        try std.testing.expect(!serial.pending_keys.contains(key(&serial, goal)));
    }
    // The table holds the blocked goal's projection, an open cell off its own; the sealed
    // blocked one's projection, which the table misses, is computed.
    const goal_grid = serial.graph.grid(0).?;
    const blocked_cell = goal_grid.indexForCell(key(&serial, IntakeGoals.blocked).goal).?;
    const blocked_projection = serial.goals.lookup(goalRef(.walk, 0, blocked_cell)) orelse return error.TestExpectedTableProjection;
    try std.testing.expect(blocked_projection != blocked_cell);
    try std.testing.expectEqual(@as(?usize, blocked_projection), serial.liveGoal(key(&serial, IntakeGoals.blocked), goal_grid).cell);
    const sealed_blocked_goal = key(&serial, IntakeGoals.sealed_blocked).goal;
    try std.testing.expectEqual(@as(?u32, null), serial.goals.lookup(goalRef(.walk, 0, goal_grid.indexForCell(sealed_blocked_goal).?)));
    try std.testing.expectEqual(goal_grid.projectToNearestOpen(sealed_blocked_goal, default_goal_projection_radius), serial.liveGoal(key(&serial, IntakeGoals.sealed_blocked), goal_grid).cell);
    // Pending filled to its gate: distinct goals past it were dropped, not queued.
    var dropped_goals: usize = 0;
    for (0..20) |index| {
        if (index == 4 or index == 18) continue;
        if (!serial.pending_keys.contains(key(&serial, IntakeGoals.distinct(index)))) dropped_goals += 1;
    }
    try std.testing.expect(dropped_goals > 1);
    try std.testing.expect(serial.completed.slotIndex(key(&serial, IntakeGoals.expired)) == null);
    try std.testing.expect(serial.completed.slotIndex(key(&serial, IntakeGoals.expired_sealed)) == null);
    try std.testing.expect(serial.completed.slotIndex(key(&serial, IntakeGoals.prefilled(0))) == null);
    // The blocked goal's fresh path ends off its projection: kept, not served, and the key
    // went pending for the solve whose publish replaces it.
    try std.testing.expect(serial.completed.slotIndex(key(&serial, IntakeGoals.blocked)) != null);
    try std.testing.expect(serial.pending_keys.contains(key(&serial, IntakeGoals.blocked)));

    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 8 });
        defer threads.deinit();
        for ([_]usize{ 8, 16, intake_test_agents }) |items_per_range| {
            var threaded = try intakeScenarioSystem(&data, requester, threads.participantSlotCount());
            defer threaded.deinit();
            _ = try threaded.resolveGoals(PathRequest, table_requests, &threads, .{ .adaptive = false, .items_per_range = items_per_range });
            const stats = try threaded.update(&stream, intake_test_agents, &threads, .{
                .adaptive = false,
                .items_per_range = items_per_range,
                .max_solve_admissions_per_step = 0,
            });
            // Several ranges run on workers; one range runs inline on the main thread.
            if (items_per_range < intake_test_agents and threads.workerThreadCount() > 0) {
                try std.testing.expect(!stats.intake_batch.ran_inline);
            } else {
                try std.testing.expect(stats.intake_batch.ran_inline);
            }
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
        _ = try updatePathfindingInline(&system, stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
        try std.testing.expectEqual(intake_test_agents, system.pending.len);
    }
    return system;
}

test "threaded intake folds a new goal's repeats per range and equals serial when accepted and when pending is full" {
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
        _ = try updatePathfindingInline(&serial, &repeated, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
        // Every repeat folds into the goal's one candidate: queued once, or dropped whole
        // when pending is full.
        const repeated_key = serial.graph.keyForWorld(0, cellWorld(9, 9), .default).?;
        if (pending_full) {
            try std.testing.expectEqual(intake_test_agents, serial.pending.len);
            try std.testing.expect(!serial.pending_keys.contains(repeated_key));
        } else {
            try std.testing.expectEqual(@as(usize, 1), serial.pending.len);
            try std.testing.expectEqualDeep(repeated_key, serial.pending.at(0).key);
        }

        var threaded = try repeatsTestSystem(&data, threads.participantSlotCount(), prefill);
        defer threaded.deinit();
        _ = try threaded.update(&repeated, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 8, .max_solve_admissions_per_step = 0 });
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
        var starts: [positions.len]GridCell = undefined;
        var goals: [positions.len]GridCell = undefined;
        positionCells(PathRequest, "start", grid, requests[0..len], starts[0..len]);
        positionCells(PathRequest, "goal", grid, requests[0..len], goals[0..len]);
        for (requests[0..len], starts[0..len], goals[0..len]) |request, start, goal| {
            try std.testing.expectEqualDeep(grid.worldToCellClamped(request.start), start);
            try std.testing.expectEqualDeep(grid.worldToCellClamped(request.goal), goal);
        }
    }
}

test "request intake after reserve allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 8 });
    defer threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try addIntakeBodies(&data);
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try writeIntakeScenarioRequests(&stream, requester);

    var system = try intakeScenarioSystem(&data, requester, threads.participantSlotCount());
    _ = try system.resolveGoals(PathRequest, stream.mergedItems()[0..intake_table_requests], &threads, .{ .adaptive = false, .items_per_range = 8 });
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
        .max_solve_admissions_per_step = 0,
    });
    try std.testing.expect(!stats.intake_batch.ran_inline);
    try std.testing.expect(stats.intake_batch.range_count > 1);
    // Requests were accepted: pending grew past the scenario's prefilled entries.
    try std.testing.expect(system.pending.len > intake_prefilled_count + 1);
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
    _ = try updatePathfindingInline(&serial, &stream, intake_test_agents, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(@as(usize, 12), serial.group_requests.items.len);
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
    _ = try threaded.update(&stream, intake_test_agents, &threads, .{ .adaptive = false, .items_per_range = 8, .max_solve_admissions_per_step = 0 });
    try expectRequestStateEqual(&serial, &threaded);
}
