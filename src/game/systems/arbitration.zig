// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pure, zero-allocation, zero-vtable utility-arbitration + sticky-selection +
//! goal-resolution contract for Slice 32. Deliberately decoupled from
//! `AiPerception`/`AiMemory`/`AiAffect` row types: `Signals` is flat data any
//! future producer (world markers, Slice 41) can populate without depending
//! on today's component layout. `ai.zig` is the only current caller: it
//! gathers `Signals` per row, then chains `scoreBehaviors` -> `selectSticky`
//! -> `resolveGoal`. This module has no dependency on `ai.zig`, the
//! pipeline, or the spatial index — `resolveGoal`'s cohere case takes a
//! pre-gathered neighbor mean as input rather than querying anything itself.

const std = @import("std");
const math = @import("../../core/math.zig");
const data_system = @import("../data_system.zig");
const EntityId = data_system.EntityId;
const AiBehavior = data_system.AiBehavior;
const AiAffectDrive = data_system.AiAffectDrive;
const ai_memory_ring_capacity = data_system.ai_memory_ring_capacity;
const PathRequestKind = @import("../simulation.zig").PathRequestKind;

pub const behavior_count: usize = 5;
pub const Scores = [behavior_count]f32;

const drive_count: usize = @typeInfo(AiAffectDrive).@"enum".fields.len;

/// Flat per-agent signal snapshot: drive values, perception, memory, a
/// caller-gathered cohere neighbor mean, and an explicit opt-in fallback
/// target. Every field defaults to "no signal" (false/invalid/zero), so a
/// caller with no perception/memory/affect component for a row can pass
/// `.{}` and get pure-wander scoring.
pub const Signals = struct {
    // Emotion drives, AiAffectDrive declaration order (fear, curiosity,
    // aggression, fatigue). Absent AiAffect component -> all zero.
    fear: f32 = 0,
    curiosity: f32 = 0,
    aggression: f32 = 0,
    fatigue: f32 = 0,

    // Perception. Absent AiPerception component -> false/invalid defaults.
    target_visible: bool = false,
    nearest_threat: EntityId = EntityId.invalid,
    // Absolute world position where nearest_threat was last actually seen
    // this step (perception's last_seen_x/y), not a relative offset.
    nearest_threat_x: f32 = 0,
    nearest_threat_y: f32 = 0,
    nearest_threat_dist: f32 = std.math.inf(f32),
    heard_stimulus: bool = false,
    heard_stimulus_x: f32 = 0,
    heard_stimulus_y: f32 = 0,

    // World interest marker (Slice 41), gathered read-only from `WorldSystem`.
    interest_present: bool = false,
    interest_x: f32 = 0,
    interest_y: f32 = 0,

    // Memory. Absent AiMemory component -> invalid/zero defaults (staleness
    // 0 and max_staleness 0 keep the "fresh" check `staleness < max_staleness`
    // false by construction whenever the caller leaves both at default).
    memory_last_known_target: EntityId = EntityId.invalid,
    memory_last_known_x: f32 = 0,
    memory_last_known_y: f32 = 0,
    memory_staleness: f32 = 0,
    memory_max_staleness: f32 = 0,
    memory_ring_entity: [ai_memory_ring_capacity]EntityId = [_]EntityId{EntityId.invalid} ** ai_memory_ring_capacity,
    memory_ring_x: [ai_memory_ring_capacity]f32 = [_]f32{0} ** ai_memory_ring_capacity,
    memory_ring_y: [ai_memory_ring_capacity]f32 = [_]f32{0} ** ai_memory_ring_capacity,
    memory_ring_age: [ai_memory_ring_capacity]f32 = [_]f32{0} ** ai_memory_ring_capacity,

    // Cohere neighbor mean, gathered by the caller via the shared spatial
    // index (see ai.zig's separationNeighborVisit-style visitor) — this
    // module never queries anything itself. 0 count = no neighbors found.
    cohere_neighbor_mean_x: f32 = 0,
    cohere_neighbor_mean_y: f32 = 0,
    cohere_neighbor_count: u32 = 0,

    // Explicit opt-in last-resort fallback target (e.g. the demo's player
    // broadcast). The caller is responsible for only populating this when
    // the agent's own gain_pursue > 0 — resolveGoal itself does not
    // re-check the gain, it is a pure signal-in/goal-out function.
    focus_target: ?EntityId = null,
    focus_target_x: f32 = 0,
    focus_target_y: f32 = 0,

    self_x: f32 = 0,
    self_y: f32 = 0,
};

/// Per-behavior scaling of the shared drive x behavior weight table, sourced
/// from an agent's cold `AiAgent.gain_*` fields.
pub const PersonalityGains = struct {
    wander: f32,
    pursue: f32,
    flee: f32,
    investigate: f32,
    cohere: f32,
};

// Drive x behavior weight table. Row order matches AiAffectDrive's
// declaration order (fear, curiosity, aggression, fatigue); column order
// matches AiBehavior's declaration order (wander, pursue, flee, investigate,
// cohere). Seed values are tunable, not sacred:
//   - fear drives flee hard, slightly discourages pursue/cohere.
//   - aggression drives pursue hard, slightly discourages cohere.
//   - curiosity drives investigate hard, with a small wander/cohere lift.
//   - fatigue drives wander (resting), discourages pursue/flee (exertion).
// cohere's baseline comes from this table (curiosity's small positive
// weight, reachable once drives settle near their per-entity baselines),
// not a special-cased branch elsewhere — see scoreBehaviors.
const drive_behavior_weight: [drive_count][behavior_count]f32 = .{
    // wander, pursue, flee,  investigate, cohere
    .{ 0.0, -0.5, 3.0, 0.0, -0.3 }, // fear
    .{ 0.3, 0.0, 0.0, 2.5, 0.5 }, // curiosity
    .{ 0.0, 3.0, 0.0, 0.0, -0.3 }, // aggression
    .{ 2.0, -1.0, -1.0, 0.0, 0.0 }, // fatigue
};

const pursue_visible_target_bonus: f32 = 1.0;
const flee_visible_threat_bonus: f32 = 1.0;
const investigate_heard_stimulus_bonus: f32 = 0.5;
const investigate_interest_marker_bonus: f32 = 0.35;
const cohere_neighbor_bonus_per_neighbor: f32 = 0.15;
const cohere_neighbor_bonus_cap: f32 = 0.6;
const pursue_fresh_memory_bonus: f32 = 0.5;
const flee_fresh_memory_bonus: f32 = 0.5;
const investigate_fresh_ring_bonus: f32 = 0.2;
// Smaller than the visible/memory bonuses: an opt-in fallback target (see
// Signals.focus_target's doc comment) is the weakest of pursue's three
// signal tiers, but still needs a nonzero score contribution -- otherwise a
// pursue-gained agent with no perception/memory/affect at all would score
// identically to wander (0) and always lose the lowest-index tie-break,
// silently ignoring its configured gain.
const pursue_focus_target_bonus: f32 = 0.3;

fn gainFor(behavior: AiBehavior, gains: PersonalityGains) f32 {
    return switch (behavior) {
        .wander => gains.wander,
        .pursue => gains.pursue,
        .flee => gains.flee,
        .investigate => gains.investigate,
        .cohere => gains.cohere,
    };
}

fn memoryFresh(signals: Signals) bool {
    return signals.memory_last_known_target.isValid() and signals.memory_staleness < signals.memory_max_staleness;
}

/// Fresh memory is only a valid pursue/flee substitute for the *same*
/// opt-in `focus_target` entity when one is configured — memory of some
/// other entity this agent glimpsed earlier (e.g. a different hostile) is
/// not a stand-in for the live fallback goal, even if fresh and valid. When
/// no `focus_target` is configured, there is nothing to mismatch against:
/// the agent's own fresh memory is trusted at face value (this is the
/// faction-generic case — an agent that lost sight of *some* hostile can
/// still act on where it last saw it).
fn memoryMatchesFocus(signals: Signals) bool {
    const wanted = signals.focus_target orelse return true;
    return signals.memory_last_known_target.eql(wanted);
}

fn hasFreshRingContact(signals: Signals) bool {
    for (signals.memory_ring_entity) |entity| {
        if (entity.isValid()) return true;
    }
    return false;
}

/// Small named-constant perception-driven bonuses, added on top of the
/// drive x gain product. Not part of the drive loop: these read
/// perception/memory-derived booleans/counts directly, not the four drives,
/// so a future fifth drive never touches this code.
fn perceptionTerm(behavior: AiBehavior, signals: Signals) f32 {
    return switch (behavior) {
        .pursue => if (signals.target_visible)
            pursue_visible_target_bonus
        else if (signals.focus_target != null)
            pursue_focus_target_bonus
        else
            0,
        .flee => if (signals.target_visible) flee_visible_threat_bonus else 0,
        .investigate => blk: {
            if (signals.heard_stimulus) break :blk investigate_heard_stimulus_bonus;
            if (signals.interest_present) break :blk investigate_interest_marker_bonus;
            break :blk 0;
        },
        .cohere => @min(
            @as(f32, @floatFromInt(signals.cohere_neighbor_count)) * cohere_neighbor_bonus_per_neighbor,
            cohere_neighbor_bonus_cap,
        ),
        .wander => 0,
    };
}

fn memoryTerm(behavior: AiBehavior, signals: Signals) f32 {
    const fresh = memoryFresh(signals) and !signals.target_visible;
    return switch (behavior) {
        .pursue => if (fresh and memoryMatchesFocus(signals)) pursue_fresh_memory_bonus else 0,
        .flee => if (fresh) flee_fresh_memory_bonus else 0,
        .investigate => if (!signals.heard_stimulus and !signals.interest_present and hasFreshRingContact(signals))
            investigate_fresh_ring_bonus
        else
            0,
        .wander, .cohere => 0,
    };
}

/// Table-driven utility score per behavior:
/// `score[b] = gain[b] * sum_d(drive[d] * weight[d][b]) + perceptionTerm(b) + memoryTerm(b)`.
/// The drive loop (`for (0..drive_count)`) is the extensibility contract for
/// a future fifth drive (Slice 42): appending a drive means a new enum tag
/// and a new table row, never a change to this control flow.
pub fn scoreBehaviors(signals: Signals, gains: PersonalityGains) Scores {
    const drive_values = [drive_count]f32{ signals.fear, signals.curiosity, signals.aggression, signals.fatigue };

    var weighted: Scores = @splat(0);
    for (0..drive_count) |d| {
        for (0..behavior_count) |b| {
            weighted[b] += drive_values[d] * drive_behavior_weight[d][b];
        }
    }

    // Gain scales the *whole* per-behavior utility (drive-weighted term plus
    // perception/memory bonuses), not just the drive term: a behavior with
    // zero personality gain must never win purely off a perception/memory
    // bonus (e.g. cohere with gain_cohere == 0 sitting next to friendly
    // neighbors) -- gain is "does this agent have any disposition toward
    // this behavior at all," which the bonus terms don't get to bypass.
    var scores: Scores = undefined;
    for (0..behavior_count) |b| {
        const behavior: AiBehavior = @enumFromInt(b);
        scores[b] = gainFor(behavior, gains) * (weighted[b] + perceptionTerm(behavior, signals) + memoryTerm(behavior, signals));
    }
    return scores;
}

pub const StickySelection = struct { index: usize, new_commitment: u16 };

fn argmax(scores: Scores) usize {
    var best_index: usize = 0;
    var best_score = scores[0];
    for (scores[1..], 1..) |score, i| {
        if (score > best_score) {
            best_score = score;
            best_index = i;
        }
    }
    return best_index;
}

/// Sticky-hysteresis selection over `scoreBehaviors`' output. While
/// `commitment_remaining > 0`, holds `previous` and decrements the
/// countdown UNLESS some other behavior's score exceeds
/// `scores[previous] + sticky_bonus + min_delta`, in which case it switches
/// immediately (does not wait for the countdown to expire). At
/// `commitment_remaining == 0`, picks the argmax (ties broken by lowest enum
/// index — first occurrence wins in an ascending scan) and resets the
/// countdown to `commitment_max_steps`.
pub fn selectSticky(
    scores: Scores,
    previous: AiBehavior,
    commitment_remaining: u16,
    commitment_max_steps: u16,
    sticky_bonus: f32,
    min_delta: f32,
) StickySelection {
    const previous_index = @intFromEnum(previous);
    if (commitment_remaining > 0) {
        const hold_threshold = scores[previous_index] + sticky_bonus + min_delta;
        var challenged = false;
        for (scores, 0..) |score, i| {
            if (i == previous_index) continue;
            if (score > hold_threshold) {
                challenged = true;
                break;
            }
        }
        if (!challenged) {
            return .{ .index = previous_index, .new_commitment = commitment_remaining - 1 };
        }
    }
    const best_index = argmax(scores);
    return .{ .index = best_index, .new_commitment = commitment_max_steps };
}

pub const GoalResolution = struct {
    goal_x: f32 = 0,
    goal_y: f32 = 0,
    goal_entity: ?EntityId = null,
    kind_hint: PathRequestKind = .individual,
    valid: bool = false,
};

const flee_lead_distance: f32 = 96.0;

fn resolvePursueGoal(signals: Signals) GoalResolution {
    if (signals.target_visible and signals.nearest_threat.isValid()) {
        return .{
            .goal_x = signals.nearest_threat_x,
            .goal_y = signals.nearest_threat_y,
            .goal_entity = signals.nearest_threat,
            .kind_hint = .individual,
            .valid = true,
        };
    }
    if (memoryFresh(signals) and memoryMatchesFocus(signals)) {
        return .{
            .goal_x = signals.memory_last_known_x,
            .goal_y = signals.memory_last_known_y,
            .goal_entity = signals.memory_last_known_target,
            .kind_hint = .individual,
            .valid = true,
        };
    }
    if (signals.focus_target) |target| {
        return .{
            .goal_x = signals.focus_target_x,
            .goal_y = signals.focus_target_y,
            .goal_entity = target,
            .kind_hint = .individual,
            .valid = true,
        };
    }
    return .{};
}

fn resolveFleeGoal(signals: Signals) GoalResolution {
    var threat_x: f32 = 0;
    var threat_y: f32 = 0;
    var have_threat = false;
    if (signals.target_visible and signals.nearest_threat.isValid()) {
        threat_x = signals.nearest_threat_x;
        threat_y = signals.nearest_threat_y;
        have_threat = true;
    } else if (memoryFresh(signals)) {
        threat_x = signals.memory_last_known_x;
        threat_y = signals.memory_last_known_y;
        have_threat = true;
    }
    if (!have_threat) return .{};

    const away = math.normalizeOrZeroFinite(signals.self_x - threat_x, signals.self_y - threat_y, 0.0001);
    return .{
        .goal_x = signals.self_x + away.x * flee_lead_distance,
        .goal_y = signals.self_y + away.y * flee_lead_distance,
        .goal_entity = null,
        .kind_hint = .individual,
        .valid = true,
    };
}

fn resolveInvestigateGoal(signals: Signals) GoalResolution {
    if (signals.heard_stimulus) {
        return .{
            .goal_x = signals.heard_stimulus_x,
            .goal_y = signals.heard_stimulus_y,
            .goal_entity = null,
            .kind_hint = .individual,
            .valid = true,
        };
    }

    if (signals.interest_present) {
        return .{
            .goal_x = signals.interest_x,
            .goal_y = signals.interest_y,
            .goal_entity = null,
            .kind_hint = .individual,
            .valid = true,
        };
    }

    var best_age = std.math.inf(f32);
    var best_index: ?usize = null;
    for (0..ai_memory_ring_capacity) |i| {
        if (!signals.memory_ring_entity[i].isValid()) continue;
        if (signals.memory_ring_age[i] < best_age) {
            best_age = signals.memory_ring_age[i];
            best_index = i;
        }
    }
    if (best_index) |i| {
        return .{
            .goal_x = signals.memory_ring_x[i],
            .goal_y = signals.memory_ring_y[i],
            .goal_entity = signals.memory_ring_entity[i],
            .kind_hint = .individual,
            .valid = true,
        };
    }
    return .{};
}

fn resolveCohereGoal(signals: Signals) GoalResolution {
    if (signals.cohere_neighbor_count == 0) return .{};
    return .{
        .goal_x = signals.cohere_neighbor_mean_x,
        .goal_y = signals.cohere_neighbor_mean_y,
        .goal_entity = null,
        // Group-flow upgrade (shared quantized goal cell) is the caller's
        // batching decision, not this pure function's — see ai.zig.
        .kind_hint = .individual,
        .valid = true,
    };
}

/// Resolves the selected behavior into a concrete goal. Pure signal-in/
/// goal-out: does not re-check personality gains (the caller gates
/// `focus_target` population on `gain_pursue > 0` before calling this).
pub fn resolveGoal(behavior: AiBehavior, signals: Signals) GoalResolution {
    return switch (behavior) {
        .wander => .{},
        .pursue => resolvePursueGoal(signals),
        .flee => resolveFleeGoal(signals),
        .investigate => resolveInvestigateGoal(signals),
        .cohere => resolveCohereGoal(signals),
    };
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;

fn zeroGains() PersonalityGains {
    return .{ .wander = 0, .pursue = 0, .flee = 0, .investigate = 0, .cohere = 0 };
}

fn unitGains() PersonalityGains {
    return .{ .wander = 1, .pursue = 1, .flee = 1, .investigate = 1, .cohere = 1 };
}

test "scoreBehaviors is a pure zero-allocation function (provable by signature alone)" {
    // No allocator parameter exists on this function at all -- the type of
    // scoreBehaviors itself is the proof, not a FailingAllocator run.
    const info = @typeInfo(@TypeOf(scoreBehaviors)).@"fn";
    inline for (info.params) |param| {
        try testing.expect(param.type != std.mem.Allocator);
    }
}

test "scoreBehaviors is table-driven: identical perception/memory with only drives differing changes the winner" {
    const base = Signals{
        .self_x = 0,
        .self_y = 0,
    };

    var fearful = base;
    fearful.fear = 1.0;
    const fear_scores = scoreBehaviors(fearful, unitGains());

    var aggressive = base;
    aggressive.aggression = 1.0;
    const aggression_scores = scoreBehaviors(aggressive, unitGains());

    const fear_winner: AiBehavior = @enumFromInt(argmax(fear_scores));
    const aggression_winner: AiBehavior = @enumFromInt(argmax(aggression_scores));

    try testing.expectEqual(AiBehavior.flee, fear_winner);
    try testing.expectEqual(AiBehavior.pursue, aggression_winner);
    try testing.expect(fear_winner != aggression_winner);
}

test "scoreBehaviors with all-zero signals and gains ties every behavior at zero" {
    const scores = scoreBehaviors(.{}, zeroGains());
    for (scores) |score| try testing.expectEqual(@as(f32, 0), score);
}

test "selectSticky ties are broken by lowest enum index" {
    const scores: Scores = .{ 5, 5, 5, 5, 5 };
    const result = selectSticky(scores, .cohere, 0, 30, 0.1, 0.05);
    try testing.expectEqual(@as(usize, 0), result.index);
    try testing.expectEqual(@as(u16, 30), result.new_commitment);
}

test "selectSticky holds the previous behavior within sticky_bonus + min_delta and decrements commitment" {
    // pursue (index 1) leads by 0.1, well inside sticky_bonus(0.2) + min_delta(0.05).
    const scores: Scores = .{ 0, 1.0, 1.1, 0, 0 };
    const result = selectSticky(scores, .pursue, 10, 30, 0.2, 0.05);
    try testing.expectEqual(@as(usize, 1), result.index);
    try testing.expectEqual(@as(u16, 9), result.new_commitment);
}

test "selectSticky switches immediately when a challenger clears the bonus+delta threshold mid-commitment" {
    // flee (index 2) beats pursue's score by more than sticky_bonus(0.1) + min_delta(0.05).
    const scores: Scores = .{ 0, 1.0, 1.2, 0, 0 };
    const result = selectSticky(scores, .pursue, 10, 30, 0.1, 0.05);
    try testing.expectEqual(@as(usize, 2), result.index);
    try testing.expectEqual(@as(u16, 30), result.new_commitment);
}

test "selectSticky resets new_commitment to commitment_max_steps on a fresh (expired-commitment) selection" {
    const scores: Scores = .{ 0, 0, 3.0, 0, 0 };
    const result = selectSticky(scores, .wander, 0, 45, 0.1, 0.05);
    try testing.expectEqual(@as(usize, 2), result.index);
    try testing.expectEqual(@as(u16, 45), result.new_commitment);
}

test "resolveGoal pursue prefers a visible threat over stale memory over focus_target fallback" {
    // Memory intentionally matches focus_target's entity (both index 3):
    // this test proves tier priority (visible > memory > focus), not the
    // separate identity-mismatch rule covered by
    // "resolveGoal pursue rejects fresh memory of a different entity than focus_target".
    const visible = Signals{
        .target_visible = true,
        .nearest_threat = EntityId{ .index = 1, .generation = 1 },
        .nearest_threat_x = 10,
        .nearest_threat_y = 20,
        .memory_last_known_target = EntityId{ .index = 3, .generation = 1 },
        .memory_last_known_x = 30,
        .memory_last_known_y = 40,
        .memory_staleness = 0,
        .memory_max_staleness = 100,
        .focus_target = EntityId{ .index = 3, .generation = 1 },
        .focus_target_x = 50,
        .focus_target_y = 60,
    };
    const visible_goal = resolveGoal(.pursue, visible);
    try testing.expect(visible_goal.valid);
    try testing.expectEqual(@as(f32, 10), visible_goal.goal_x);
    try testing.expectEqual(@as(f32, 20), visible_goal.goal_y);
    try testing.expectEqual(visible.nearest_threat.index, visible_goal.goal_entity.?.index);

    var memory_only = visible;
    memory_only.target_visible = false;
    const memory_goal = resolveGoal(.pursue, memory_only);
    try testing.expect(memory_goal.valid);
    try testing.expectEqual(@as(f32, 30), memory_goal.goal_x);
    try testing.expectEqual(@as(f32, 40), memory_goal.goal_y);
    try testing.expectEqual(memory_only.memory_last_known_target.index, memory_goal.goal_entity.?.index);

    var focus_only = memory_only;
    focus_only.memory_last_known_target = EntityId.invalid;
    const focus_goal = resolveGoal(.pursue, focus_only);
    try testing.expect(focus_goal.valid);
    try testing.expectEqual(@as(f32, 50), focus_goal.goal_x);
    try testing.expectEqual(@as(f32, 60), focus_goal.goal_y);
    try testing.expectEqual(focus_only.focus_target.?.index, focus_goal.goal_entity.?.index);

    var nothing = focus_only;
    nothing.focus_target = null;
    const invalid_goal = resolveGoal(.pursue, nothing);
    try testing.expect(!invalid_goal.valid);
}

test "resolveGoal pursue rejects fresh memory of a different entity than focus_target" {
    // Memory is fresh and valid but belongs to a different entity than the
    // configured focus_target fallback -- it must not be trusted as a
    // substitute for the live focus goal (mirrors the pre-Slice-32 seek_entity
    // identity check).
    const signals = Signals{
        .memory_last_known_target = EntityId{ .index = 9, .generation = 1 },
        .memory_last_known_x = 30,
        .memory_last_known_y = 40,
        .memory_staleness = 0,
        .memory_max_staleness = 100,
        .focus_target = EntityId{ .index = 3, .generation = 1 },
        .focus_target_x = 50,
        .focus_target_y = 60,
    };
    const goal = resolveGoal(.pursue, signals);
    try testing.expect(goal.valid);
    try testing.expectEqual(@as(f32, 50), goal.goal_x);
    try testing.expectEqual(@as(f32, 60), goal.goal_y);
    try testing.expectEqual(signals.focus_target.?.index, goal.goal_entity.?.index);
}

test "resolveGoal pursue trusts fresh memory at face value when no focus_target is configured" {
    // Faction-generic case: an agent with no opt-in fallback configured at
    // all still acts on its own fresh memory, no identity check needed.
    const signals = Signals{
        .memory_last_known_target = EntityId{ .index = 9, .generation = 1 },
        .memory_last_known_x = 30,
        .memory_last_known_y = 40,
        .memory_staleness = 0,
        .memory_max_staleness = 100,
    };
    const goal = resolveGoal(.pursue, signals);
    try testing.expect(goal.valid);
    try testing.expectEqual(@as(f32, 30), goal.goal_x);
    try testing.expectEqual(@as(f32, 40), goal.goal_y);
}

test "resolveGoal flee inverts direction away from the threat position" {
    const signals = Signals{
        .target_visible = true,
        .nearest_threat = EntityId{ .index = 1, .generation = 1 },
        .nearest_threat_x = 100,
        .nearest_threat_y = 0,
        .self_x = 0,
        .self_y = 0,
    };
    const goal = resolveGoal(.flee, signals);
    try testing.expect(goal.valid);
    // Threat is to the east; fleeing should move west (negative x), y unaffected.
    try testing.expect(goal.goal_x < 0);
    try testing.expectApproxEqAbs(@as(f32, 0), goal.goal_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -flee_lead_distance), goal.goal_x, 1e-3);
}

test "resolveGoal investigate prefers stimulus over interest marker over ring memory" {
    var signals = Signals{
        .heard_stimulus = true,
        .heard_stimulus_x = 5,
        .heard_stimulus_y = 6,
        .interest_present = true,
        .interest_x = 50,
        .interest_y = 60,
    };
    signals.memory_ring_entity[0] = EntityId{ .index = 9, .generation = 1 };
    signals.memory_ring_x[0] = 70;
    signals.memory_ring_y[0] = 80;
    signals.memory_ring_age[0] = 1;

    const stimulus_goal = resolveGoal(.investigate, signals);
    try testing.expect(stimulus_goal.valid);
    try testing.expectEqual(@as(f32, 5), stimulus_goal.goal_x);
    try testing.expectEqual(@as(f32, 6), stimulus_goal.goal_y);

    signals.heard_stimulus = false;
    const marker_goal = resolveGoal(.investigate, signals);
    try testing.expect(marker_goal.valid);
    try testing.expectEqual(@as(f32, 50), marker_goal.goal_x);
    try testing.expectEqual(@as(f32, 60), marker_goal.goal_y);
    try testing.expect(marker_goal.goal_entity == null);

    signals.interest_present = false;
    const ring_goal = resolveGoal(.investigate, signals);
    try testing.expect(ring_goal.valid);
    try testing.expectEqual(@as(f32, 70), ring_goal.goal_x);
    try testing.expectEqual(@as(f32, 80), ring_goal.goal_y);
    try testing.expectEqual(@as(u32, 9), ring_goal.goal_entity.?.index);

    signals.memory_ring_entity[0] = EntityId.invalid;
    const invalid_goal = resolveGoal(.investigate, signals);
    try testing.expect(!invalid_goal.valid);
}

test "resolveGoal investigate marker-only produces valid goal without entity" {
    const signals = Signals{
        .interest_present = true,
        .interest_x = 120,
        .interest_y = 130,
    };
    const goal = resolveGoal(.investigate, signals);
    try testing.expect(goal.valid);
    try testing.expectEqual(@as(f32, 120), goal.goal_x);
    try testing.expectEqual(@as(f32, 130), goal.goal_y);
    try testing.expect(goal.goal_entity == null);
}

test "resolveGoal investigate picks the lowest-age valid ring entry" {
    var signals = Signals{};
    signals.memory_ring_entity[0] = EntityId{ .index = 1, .generation = 1 };
    signals.memory_ring_x[0] = 1;
    signals.memory_ring_y[0] = 1;
    signals.memory_ring_age[0] = 50;
    signals.memory_ring_entity[1] = EntityId{ .index = 2, .generation = 1 };
    signals.memory_ring_x[1] = 2;
    signals.memory_ring_y[1] = 2;
    signals.memory_ring_age[1] = 5;

    const goal = resolveGoal(.investigate, signals);
    try testing.expect(goal.valid);
    try testing.expectEqual(@as(f32, 2), goal.goal_x);
    try testing.expectEqual(@as(u32, 2), goal.goal_entity.?.index);
}

test "resolveGoal cohere passes through the caller-gathered neighbor mean, invalid when count is 0" {
    const signals = Signals{
        .cohere_neighbor_mean_x = 42,
        .cohere_neighbor_mean_y = -8,
        .cohere_neighbor_count = 3,
    };
    const goal = resolveGoal(.cohere, signals);
    try testing.expect(goal.valid);
    try testing.expectEqual(@as(f32, 42), goal.goal_x);
    try testing.expectEqual(@as(f32, -8), goal.goal_y);
    try testing.expectEqual(@as(?EntityId, null), goal.goal_entity);

    var empty = signals;
    empty.cohere_neighbor_count = 0;
    const empty_goal = resolveGoal(.cohere, empty);
    try testing.expect(!empty_goal.valid);
}

test "resolveGoal wander is always invalid" {
    const goal = resolveGoal(.wander, .{ .target_visible = true, .heard_stimulus = true, .cohere_neighbor_count = 5 });
    try testing.expect(!goal.valid);
}

test "scoreBehaviors gives a pursue-gained agent with only an opt-in focus_target a nonzero score, beating wander's tie-break default" {
    const signals = Signals{
        .focus_target = EntityId{ .index = 1, .generation = 1 },
        .focus_target_x = 10,
        .focus_target_y = 10,
    };
    const gains = PersonalityGains{ .wander = 1.0, .pursue = 1.0, .flee = 0, .investigate = 0, .cohere = 0 };
    const scores = scoreBehaviors(signals, gains);
    try testing.expectEqual(AiBehavior.pursue, @as(AiBehavior, @enumFromInt(argmax(scores))));
    try testing.expect(scores[@intFromEnum(AiBehavior.pursue)] > scores[@intFromEnum(AiBehavior.wander)]);
}
