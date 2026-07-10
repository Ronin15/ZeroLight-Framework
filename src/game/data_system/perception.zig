// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI perception component storage: cold vision/FOV tunables plus hot
//! per-step sensed-state columns (target visibility, last-known position,
//! nearest threat, fallback facing), and the perception payload validator.
//! Mirrors agents.zig's AiAgentStore shape.

const std = @import("std");
const types = @import("types.zig");
const math = @import("../../core/math.zig");
const EntityId = types.EntityId;
const AiPerception = types.AiPerception;
const max_ai_perception_vision_range = types.max_ai_perception_vision_range;
const max_ai_perception_hearing_range = types.max_ai_perception_hearing_range;
const ConstPerceptionSlice = types.ConstPerceptionSlice;
const PerceptionSlice = types.PerceptionSlice;
const hotStoreCapacity = types.hotStoreCapacity;

pub fn validateAiPerception(perception: AiPerception) !void {
    if (!std.math.isFinite(perception.vision_range) or perception.vision_range <= 0) return error.InvalidAiPerception;
    if (perception.vision_range > max_ai_perception_vision_range) return error.InvalidAiPerception;
    if (!std.math.isFinite(perception.fov_half_angle_radians)) return error.InvalidAiPerception;
    if (perception.fov_half_angle_radians <= 0 or perception.fov_half_angle_radians > std.math.pi / 2.0) return error.InvalidAiPerception;
    if (!std.math.isFinite(perception.hearing_range) or perception.hearing_range <= 0) return error.InvalidAiPerception;
    if (perception.hearing_range > max_ai_perception_hearing_range) return error.InvalidAiPerception;
}

fn cosHalfFov(fov_half_angle_radians: f32) f32 {
    // The f32 nearest pi/2 rounds slightly high, so @cos(pi/2) evaluates to a
    // tiny negative value rather than exactly 0. Clamp so cos_half_fov never
    // goes negative at the validated (0, pi/2] boundary, matching the "FOV
    // test relies on cos_half_fov >= 0" invariant this slice guarantees.
    return @max(0.0, math.sinCos(fov_half_angle_radians).cos);
}

const PerceptionRow = struct {
    entity: EntityId,
    vision_range: f32,
    fov_half_angle_radians: f32,
    cos_half_fov: f32,
    hearing_range: f32,
    target_visible: bool,
    last_seen_x: f32,
    last_seen_y: f32,
    nearest_threat: EntityId,
    nearest_threat_dist: f32,
    facing_x: f32,
    facing_y: f32,
    heard_stimulus: bool,
    heard_stimulus_x: f32,
    heard_stimulus_y: f32,
};

pub const PerceptionStore = struct {
    rows: std.MultiArrayList(PerceptionRow) = .{},

    pub fn len(self: *const PerceptionStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *PerceptionStore, allocator: std.mem.Allocator, entity: EntityId, perception: AiPerception) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyAiPerceptionRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .vision_range = perception.vision_range,
            .fov_half_angle_radians = perception.fov_half_angle_radians,
            .cos_half_fov = cosHalfFov(perception.fov_half_angle_radians),
            .hearing_range = perception.hearing_range,
            .target_visible = perception.target_visible,
            .last_seen_x = perception.last_seen_x,
            .last_seen_y = perception.last_seen_y,
            .nearest_threat = perception.nearest_threat,
            .nearest_threat_dist = perception.nearest_threat_dist,
            .facing_x = perception.facing_x,
            .facing_y = perception.facing_y,
            .heard_stimulus = perception.heard_stimulus,
            .heard_stimulus_x = perception.heard_stimulus_x,
            .heard_stimulus_y = perception.heard_stimulus_y,
        });
        return index;
    }

    /// Updates only the cold tunables (vision_range, fov_half_angle_radians,
    /// the recomputed cos_half_fov, and hearing_range) on an existing row. A
    /// stat retune must not wipe live sensing state, so the hot columns
    /// (target_visible, last_seen_x/y, nearest_threat, nearest_threat_dist,
    /// facing_x/y, heard_stimulus, heard_stimulus_x/y) are left untouched.
    pub fn set(self: *PerceptionStore, index: usize, perception: AiPerception) void {
        const s = self.rows.slice();
        s.items(.vision_range)[index] = perception.vision_range;
        s.items(.fov_half_angle_radians)[index] = perception.fov_half_angle_radians;
        s.items(.cos_half_fov)[index] = cosHalfFov(perception.fov_half_angle_radians);
        s.items(.hearing_range)[index] = perception.hearing_range;
    }

    pub fn get(self: *const PerceptionStore, index: usize) AiPerception {
        const s = self.rows.slice();
        return .{
            .vision_range = s.items(.vision_range)[index],
            .fov_half_angle_radians = s.items(.fov_half_angle_radians)[index],
            .cos_half_fov = s.items(.cos_half_fov)[index],
            .hearing_range = s.items(.hearing_range)[index],
            .target_visible = s.items(.target_visible)[index],
            .last_seen_x = s.items(.last_seen_x)[index],
            .last_seen_y = s.items(.last_seen_y)[index],
            .nearest_threat = s.items(.nearest_threat)[index],
            .nearest_threat_dist = s.items(.nearest_threat_dist)[index],
            .facing_x = s.items(.facing_x)[index],
            .facing_y = s.items(.facing_y)[index],
            .heard_stimulus = s.items(.heard_stimulus)[index],
            .heard_stimulus_x = s.items(.heard_stimulus_x)[index],
            .heard_stimulus_y = s.items(.heard_stimulus_y)[index],
        };
    }

    pub fn removeAt(self: *PerceptionStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const PerceptionStore) ConstPerceptionSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .vision_range = s.items(.vision_range),
            .fov_half_angle_radians = s.items(.fov_half_angle_radians),
            .cos_half_fov = s.items(.cos_half_fov),
            .hearing_range = s.items(.hearing_range),
            .target_visible = s.items(.target_visible),
            .last_seen_x = s.items(.last_seen_x),
            .last_seen_y = s.items(.last_seen_y),
            .nearest_threat = s.items(.nearest_threat),
            .nearest_threat_dist = s.items(.nearest_threat_dist),
            .facing_x = s.items(.facing_x),
            .facing_y = s.items(.facing_y),
            .heard_stimulus = s.items(.heard_stimulus),
            .heard_stimulus_x = s.items(.heard_stimulus_x),
            .heard_stimulus_y = s.items(.heard_stimulus_y),
        };
    }

    /// Mutable view for PerceptionSystem's per-step hot-column writes. Cold
    /// tunables (vision_range, fov_half_angle_radians, cos_half_fov,
    /// hearing_range) stay const here — they change only through
    /// PerceptionStore.set.
    pub fn slice(self: *PerceptionStore) PerceptionSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .vision_range = s.items(.vision_range),
            .fov_half_angle_radians = s.items(.fov_half_angle_radians),
            .cos_half_fov = s.items(.cos_half_fov),
            .hearing_range = s.items(.hearing_range),
            .target_visible = s.items(.target_visible),
            .last_seen_x = s.items(.last_seen_x),
            .last_seen_y = s.items(.last_seen_y),
            .nearest_threat = s.items(.nearest_threat),
            .nearest_threat_dist = s.items(.nearest_threat_dist),
            .facing_x = s.items(.facing_x),
            .facing_y = s.items(.facing_y),
            .heard_stimulus = s.items(.heard_stimulus),
            .heard_stimulus_x = s.items(.heard_stimulus_x),
            .heard_stimulus_y = s.items(.heard_stimulus_y),
        };
    }

    pub fn clearRetainingCapacity(self: *PerceptionStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *PerceptionStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *PerceptionStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *PerceptionStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

test "validateAiPerception accepts defaults and rejects out-of-range or non-finite fields" {
    try validateAiPerception(.{});
    try validateAiPerception(.{ .vision_range = max_ai_perception_vision_range, .fov_half_angle_radians = std.math.pi / 2.0 });

    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .vision_range = 0 }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .vision_range = -1 }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .vision_range = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .vision_range = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .vision_range = max_ai_perception_vision_range + 1 }));

    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .fov_half_angle_radians = 0 }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .fov_half_angle_radians = -0.1 }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .fov_half_angle_radians = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .fov_half_angle_radians = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .fov_half_angle_radians = (std.math.pi / 2.0) + 0.01 }));

    try validateAiPerception(.{ .hearing_range = max_ai_perception_hearing_range });
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .hearing_range = 0 }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .hearing_range = -1 }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .hearing_range = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .hearing_range = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, validateAiPerception(.{ .hearing_range = max_ai_perception_hearing_range + 1 }));
}

test "cosHalfFov never goes negative at the validated pi/2 boundary" {
    // The nearest f32 to pi/2 rounds slightly high, so a naive @cos(pi/2)
    // evaluates to a tiny negative value. The validated cap is inclusive of
    // pi/2, so this boundary must still produce cos_half_fov >= 0 for the
    // (future) PerceptionSystem's FOV dot-product test to hold.
    try std.testing.expect(cosHalfFov(std.math.pi / 2.0) >= 0);
}

test "PerceptionStore append/set/get/removeAt round-trip" {
    var store = PerceptionStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    const third = try EntityId.init(3, 1);

    _ = try store.append(std.testing.allocator, first, .{ .vision_range = 100, .fov_half_angle_radians = 0.5, .hearing_range = 50 });
    _ = try store.append(std.testing.allocator, second, .{ .vision_range = 200, .fov_half_angle_radians = 0.6, .hearing_range = 60 });
    _ = try store.append(std.testing.allocator, third, .{ .vision_range = 300, .fov_half_angle_radians = 0.7, .hearing_range = 70 });
    try std.testing.expectEqual(@as(usize, 3), store.len());
    try std.testing.expectEqual(@as(f32, 50), store.get(0).hearing_range);

    store.set(0, .{ .vision_range = 150, .fov_half_angle_radians = 0.9, .hearing_range = 125 });
    const updated = store.get(0);
    try std.testing.expectEqual(@as(f32, 150), updated.vision_range);
    try std.testing.expectEqual(@as(f32, 0.9), updated.fov_half_angle_radians);
    try std.testing.expectApproxEqAbs(cosHalfFov(0.9), updated.cos_half_fov, 1e-6);
    try std.testing.expectEqual(@as(f32, 125), updated.hearing_range);

    const moved = store.removeAt(1);
    try std.testing.expectEqual(@as(?EntityId, third), moved);
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqual(@as(f32, 300), store.get(1).vision_range);
}

test "PerceptionStore set on existing row preserves hot columns and only updates cold columns" {
    var store = PerceptionStore{};
    defer store.deinit(std.testing.allocator);

    const entity = try EntityId.init(1, 1);
    _ = try store.append(std.testing.allocator, entity, .{ .vision_range = 100, .fov_half_angle_radians = 0.5 });

    // Simulate the PerceptionSystem writing live sensing state.
    const threat = try EntityId.init(9, 3);
    var live = store.slice();
    live.target_visible[0] = true;
    live.last_seen_x[0] = 12.5;
    live.last_seen_y[0] = -4.5;
    live.nearest_threat[0] = threat;
    live.nearest_threat_dist[0] = 42.0;
    live.facing_x[0] = 0.0;
    live.facing_y[0] = -1.0;
    live.heard_stimulus[0] = true;
    live.heard_stimulus_x[0] = 3.0;
    live.heard_stimulus_y[0] = 4.0;

    // A stat retune (e.g. tuning vision_range/hearing_range) must not clear the
    // hot state above.
    store.set(0, .{ .vision_range = 400, .fov_half_angle_radians = 0.4, .hearing_range = 350 });

    const after = store.get(0);
    try std.testing.expectEqual(@as(f32, 400), after.vision_range);
    try std.testing.expectEqual(@as(f32, 0.4), after.fov_half_angle_radians);
    try std.testing.expectApproxEqAbs(cosHalfFov(0.4), after.cos_half_fov, 1e-6);
    try std.testing.expectEqual(@as(f32, 350), after.hearing_range);
    try std.testing.expect(after.target_visible);
    try std.testing.expectEqual(@as(f32, 12.5), after.last_seen_x);
    try std.testing.expectEqual(@as(f32, -4.5), after.last_seen_y);
    try std.testing.expectEqual(threat, after.nearest_threat);
    try std.testing.expectEqual(@as(f32, 42.0), after.nearest_threat_dist);
    try std.testing.expectEqual(@as(f32, 0.0), after.facing_x);
    try std.testing.expectEqual(@as(f32, -1.0), after.facing_y);
    try std.testing.expect(after.heard_stimulus);
    try std.testing.expectEqual(@as(f32, 3.0), after.heard_stimulus_x);
    try std.testing.expectEqual(@as(f32, 4.0), after.heard_stimulus_y);
}

test "PerceptionStore sliceConst and mutable slice expose aligned columns" {
    var store = PerceptionStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    _ = try store.append(std.testing.allocator, first, .{});
    _ = try store.append(std.testing.allocator, second, .{});

    const const_slice = store.sliceConst();
    try std.testing.expectEqual(@as(usize, 2), const_slice.entities.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.vision_range.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.cos_half_fov.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.nearest_threat.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.hearing_range.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.heard_stimulus.len);

    const mutable_slice = store.slice();
    mutable_slice.target_visible[1] = true;
    mutable_slice.nearest_threat_dist[1] = 7.5;
    mutable_slice.heard_stimulus[1] = true;
    mutable_slice.heard_stimulus_x[1] = 1.5;
    mutable_slice.heard_stimulus_y[1] = 2.5;
    try std.testing.expect(store.get(1).target_visible);
    try std.testing.expectEqual(@as(f32, 7.5), store.get(1).nearest_threat_dist);
    try std.testing.expect(store.get(1).heard_stimulus);
    try std.testing.expectEqual(@as(f32, 1.5), store.get(1).heard_stimulus_x);
    try std.testing.expectEqual(@as(f32, 2.5), store.get(1).heard_stimulus_y);
}
