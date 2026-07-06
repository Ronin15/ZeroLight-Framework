// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI emotion-drive component storage: per-entity cold tunables (baseline,
//! decay rate, and rising-edge threshold for each of the four drives) plus
//! hot per-step appraisal output, and the affect payload validator. Mirrors
//! perception.zig's PerceptionStore shape: cold tunables are author-set and
//! preserved across a retune, so set() only overwrites the cold columns and
//! leaves the hot fear/curiosity/aggression/fatigue columns untouched.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const AiAffect = types.AiAffect;
const ConstAiAffectSlice = types.ConstAiAffectSlice;
const AiAffectSlice = types.AiAffectSlice;
const hotStoreCapacity = types.hotStoreCapacity;

pub fn validateAiAffect(affect: AiAffect) !void {
    const baselines = [_]f32{ affect.baseline_fear, affect.baseline_curiosity, affect.baseline_aggression, affect.baseline_fatigue };
    for (baselines) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidAiAffect;
    }

    const decay_rates = [_]f32{ affect.decay_rate_fear, affect.decay_rate_curiosity, affect.decay_rate_aggression, affect.decay_rate_fatigue };
    for (decay_rates) |value| {
        if (!std.math.isFinite(value) or value <= 0 or value > 1) return error.InvalidAiAffect;
    }

    const thresholds = [_]f32{ affect.threshold_fear, affect.threshold_curiosity, affect.threshold_aggression, affect.threshold_fatigue };
    for (thresholds) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidAiAffect;
    }

    const hot_values = [_]f32{ affect.fear, affect.curiosity, affect.aggression, affect.fatigue };
    for (hot_values) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidAiAffect;
    }
}

const AffectRow = struct {
    entity: EntityId,
    baseline_fear: f32,
    baseline_curiosity: f32,
    baseline_aggression: f32,
    baseline_fatigue: f32,
    decay_rate_fear: f32,
    decay_rate_curiosity: f32,
    decay_rate_aggression: f32,
    decay_rate_fatigue: f32,
    threshold_fear: f32,
    threshold_curiosity: f32,
    threshold_aggression: f32,
    threshold_fatigue: f32,
    fear: f32,
    curiosity: f32,
    aggression: f32,
    fatigue: f32,
};

pub const AiAffectStore = struct {
    rows: std.MultiArrayList(AffectRow) = .{},

    pub fn len(self: *const AiAffectStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *AiAffectStore, allocator: std.mem.Allocator, entity: EntityId, affect: AiAffect) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyAiAffectRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .baseline_fear = affect.baseline_fear,
            .baseline_curiosity = affect.baseline_curiosity,
            .baseline_aggression = affect.baseline_aggression,
            .baseline_fatigue = affect.baseline_fatigue,
            .decay_rate_fear = affect.decay_rate_fear,
            .decay_rate_curiosity = affect.decay_rate_curiosity,
            .decay_rate_aggression = affect.decay_rate_aggression,
            .decay_rate_fatigue = affect.decay_rate_fatigue,
            .threshold_fear = affect.threshold_fear,
            .threshold_curiosity = affect.threshold_curiosity,
            .threshold_aggression = affect.threshold_aggression,
            .threshold_fatigue = affect.threshold_fatigue,
            .fear = affect.fear,
            .curiosity = affect.curiosity,
            .aggression = affect.aggression,
            .fatigue = affect.fatigue,
        });
        return index;
    }

    /// Updates only the cold tunables (baseline_*, decay_rate_*, threshold_*)
    /// on an existing row. A retune must not wipe this step's live appraisal
    /// state, so the hot columns (fear, curiosity, aggression, fatigue) are
    /// left untouched — mirrors PerceptionStore.set.
    pub fn set(self: *AiAffectStore, index: usize, affect: AiAffect) void {
        const s = self.rows.slice();
        s.items(.baseline_fear)[index] = affect.baseline_fear;
        s.items(.baseline_curiosity)[index] = affect.baseline_curiosity;
        s.items(.baseline_aggression)[index] = affect.baseline_aggression;
        s.items(.baseline_fatigue)[index] = affect.baseline_fatigue;
        s.items(.decay_rate_fear)[index] = affect.decay_rate_fear;
        s.items(.decay_rate_curiosity)[index] = affect.decay_rate_curiosity;
        s.items(.decay_rate_aggression)[index] = affect.decay_rate_aggression;
        s.items(.decay_rate_fatigue)[index] = affect.decay_rate_fatigue;
        s.items(.threshold_fear)[index] = affect.threshold_fear;
        s.items(.threshold_curiosity)[index] = affect.threshold_curiosity;
        s.items(.threshold_aggression)[index] = affect.threshold_aggression;
        s.items(.threshold_fatigue)[index] = affect.threshold_fatigue;
    }

    pub fn get(self: *const AiAffectStore, index: usize) AiAffect {
        const s = self.rows.slice();
        return .{
            .baseline_fear = s.items(.baseline_fear)[index],
            .baseline_curiosity = s.items(.baseline_curiosity)[index],
            .baseline_aggression = s.items(.baseline_aggression)[index],
            .baseline_fatigue = s.items(.baseline_fatigue)[index],
            .decay_rate_fear = s.items(.decay_rate_fear)[index],
            .decay_rate_curiosity = s.items(.decay_rate_curiosity)[index],
            .decay_rate_aggression = s.items(.decay_rate_aggression)[index],
            .decay_rate_fatigue = s.items(.decay_rate_fatigue)[index],
            .threshold_fear = s.items(.threshold_fear)[index],
            .threshold_curiosity = s.items(.threshold_curiosity)[index],
            .threshold_aggression = s.items(.threshold_aggression)[index],
            .threshold_fatigue = s.items(.threshold_fatigue)[index],
            .fear = s.items(.fear)[index],
            .curiosity = s.items(.curiosity)[index],
            .aggression = s.items(.aggression)[index],
            .fatigue = s.items(.fatigue)[index],
        };
    }

    pub fn removeAt(self: *AiAffectStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const AiAffectStore) ConstAiAffectSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .baseline_fear = s.items(.baseline_fear),
            .baseline_curiosity = s.items(.baseline_curiosity),
            .baseline_aggression = s.items(.baseline_aggression),
            .baseline_fatigue = s.items(.baseline_fatigue),
            .decay_rate_fear = s.items(.decay_rate_fear),
            .decay_rate_curiosity = s.items(.decay_rate_curiosity),
            .decay_rate_aggression = s.items(.decay_rate_aggression),
            .decay_rate_fatigue = s.items(.decay_rate_fatigue),
            .threshold_fear = s.items(.threshold_fear),
            .threshold_curiosity = s.items(.threshold_curiosity),
            .threshold_aggression = s.items(.threshold_aggression),
            .threshold_fatigue = s.items(.threshold_fatigue),
            .fear = s.items(.fear),
            .curiosity = s.items(.curiosity),
            .aggression = s.items(.aggression),
            .fatigue = s.items(.fatigue),
        };
    }

    /// Mutable view for `AffectSystem`'s per-step appraisal writes. Cold
    /// tunables stay const here — they change only through
    /// DataSystem.setAiAffect, mirroring PerceptionStore.slice.
    pub fn slice(self: *AiAffectStore) AiAffectSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .baseline_fear = s.items(.baseline_fear),
            .baseline_curiosity = s.items(.baseline_curiosity),
            .baseline_aggression = s.items(.baseline_aggression),
            .baseline_fatigue = s.items(.baseline_fatigue),
            .decay_rate_fear = s.items(.decay_rate_fear),
            .decay_rate_curiosity = s.items(.decay_rate_curiosity),
            .decay_rate_aggression = s.items(.decay_rate_aggression),
            .decay_rate_fatigue = s.items(.decay_rate_fatigue),
            .threshold_fear = s.items(.threshold_fear),
            .threshold_curiosity = s.items(.threshold_curiosity),
            .threshold_aggression = s.items(.threshold_aggression),
            .threshold_fatigue = s.items(.threshold_fatigue),
            .fear = s.items(.fear),
            .curiosity = s.items(.curiosity),
            .aggression = s.items(.aggression),
            .fatigue = s.items(.fatigue),
        };
    }

    pub fn clearRetainingCapacity(self: *AiAffectStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *AiAffectStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *AiAffectStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *AiAffectStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

test "validateAiAffect accepts defaults and rejects out-of-range or non-finite fields" {
    try validateAiAffect(.{});
    try validateAiAffect(.{
        .baseline_fear = 1,
        .decay_rate_fear = 1,
        .threshold_fear = 1,
        .fear = 1,
    });

    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .baseline_fear = -0.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .baseline_curiosity = 1.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .baseline_aggression = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .baseline_fatigue = std.math.inf(f32) }));

    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .decay_rate_fear = 0 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .decay_rate_curiosity = -0.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .decay_rate_aggression = 1.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .decay_rate_fatigue = std.math.nan(f32) }));

    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .threshold_fear = -0.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .threshold_curiosity = 1.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .threshold_aggression = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .threshold_fatigue = std.math.inf(f32) }));

    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .fear = -0.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .curiosity = 1.1 }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .aggression = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAffect, validateAiAffect(.{ .fatigue = std.math.inf(f32) }));
}

test "AiAffectStore append/set/get/removeAt round-trip" {
    var store = AiAffectStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    const third = try EntityId.init(3, 1);

    _ = try store.append(std.testing.allocator, first, .{ .baseline_fear = 0.1, .fear = 0.2 });
    _ = try store.append(std.testing.allocator, second, .{ .baseline_fear = 0.2, .fear = 0.3 });
    _ = try store.append(std.testing.allocator, third, .{ .baseline_fear = 0.3, .fear = 0.4 });
    try std.testing.expectEqual(@as(usize, 3), store.len());
    try std.testing.expectEqual(@as(f32, 0.3), store.get(1).fear);

    store.set(0, .{ .baseline_fear = 0.9, .threshold_fear = 0.8, .fear = 0.99 });
    const updated = store.get(0);
    try std.testing.expectEqual(@as(f32, 0.9), updated.baseline_fear);
    try std.testing.expectEqual(@as(f32, 0.8), updated.threshold_fear);
    // Hot column is untouched by set(): still the append-time value.
    try std.testing.expectEqual(@as(f32, 0.2), updated.fear);

    const moved = store.removeAt(1);
    try std.testing.expectEqual(@as(?EntityId, third), moved);
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqual(@as(f32, 0.3), store.get(1).baseline_fear);
}

test "AiAffectStore set on existing row preserves hot columns and only updates cold columns" {
    var store = AiAffectStore{};
    defer store.deinit(std.testing.allocator);

    const entity = try EntityId.init(1, 1);
    _ = try store.append(std.testing.allocator, entity, .{ .baseline_fear = 0.1, .decay_rate_fear = 0.2, .threshold_fear = 0.3 });

    // Simulate AffectSystem writing this step's live appraisal state.
    var live = store.slice();
    live.fear[0] = 0.77;
    live.curiosity[0] = 0.55;
    live.aggression[0] = 0.33;
    live.fatigue[0] = 0.11;

    // A retune (baseline/decay/threshold) must not clear the hot state above.
    store.set(0, .{ .baseline_fear = 0.9, .decay_rate_fear = 0.4, .threshold_fear = 0.5 });

    const after = store.get(0);
    try std.testing.expectEqual(@as(f32, 0.9), after.baseline_fear);
    try std.testing.expectEqual(@as(f32, 0.4), after.decay_rate_fear);
    try std.testing.expectEqual(@as(f32, 0.5), after.threshold_fear);
    try std.testing.expectEqual(@as(f32, 0.77), after.fear);
    try std.testing.expectEqual(@as(f32, 0.55), after.curiosity);
    try std.testing.expectEqual(@as(f32, 0.33), after.aggression);
    try std.testing.expectEqual(@as(f32, 0.11), after.fatigue);
}

test "AiAffectStore sliceConst and mutable slice expose aligned columns" {
    var store = AiAffectStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    _ = try store.append(std.testing.allocator, first, .{});
    _ = try store.append(std.testing.allocator, second, .{});

    const const_slice = store.sliceConst();
    try std.testing.expectEqual(@as(usize, 2), const_slice.entities.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.baseline_fear.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.decay_rate_curiosity.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.threshold_aggression.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.fatigue.len);

    const mutable_slice = store.slice();
    mutable_slice.fear[1] = 0.42;
    mutable_slice.curiosity[1] = 0.24;
    try std.testing.expectEqual(@as(f32, 0.42), store.get(1).fear);
    try std.testing.expectEqual(@as(f32, 0.24), store.get(1).curiosity);
}
