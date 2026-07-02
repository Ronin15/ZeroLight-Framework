// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Stateless, seeded, splittable per-entity RNG for AI/gameplay noise (wander
//! jitter, appraisal noise, investigate-target selection). Every function is a
//! pure function of (seed, entity_index, step, salt): identical inputs always
//! produce identical outputs regardless of thread count, worker range
//! partitioning, or call order — there is no generator state to advance,
//! share, or synchronize across workers. `salt` distinguishes independent
//! draws for the same entity/step (e.g. wander direction vs. a future
//! appraisal-noise or investigate-target draw) so multiple streams can be
//! derived without correlating with each other.

const std = @import("std");
const math = @import("math.zig");

/// Core stateless mixer: absorbs all four key components and runs a
/// splitmix64-style avalanche finalizer so varying any single component
/// changes most output bits. Same inputs always produce the same output.
pub fn mix64(seed: u64, entity_index: u32, step: u32, salt: u32) u64 {
    var h: u64 = seed;
    h ^= @as(u64, entity_index) *% 0x9e3779b97f4a7c15;
    h = std.math.rotl(u64, h, 27);
    h ^= @as(u64, step) *% 0xbf58476d1ce4e5b9;
    h = std.math.rotl(u64, h, 27);
    h ^= @as(u64, salt) *% 0x94d049bb133111eb;
    h ^= h >> 30;
    h *%= 0xbf58476d1ce4e5b9;
    h ^= h >> 27;
    h *%= 0x94d049bb133111eb;
    h ^= h >> 31;
    return h;
}

/// Uniform draw in `[0, 1)`. Uses the top 24 bits so the result is exactly
/// representable in f32 and structurally bounded below 1.0 (unlike dividing
/// the low 32 bits by 2^32-1, which can hit exactly 1.0 once in 2^32 draws).
pub fn uniformF32(seed: u64, entity_index: u32, step: u32, salt: u32) f32 {
    const h = mix64(seed, entity_index, step, salt);
    const top24: u32 = @intCast(h >> 40);
    return @as(f32, @floatFromInt(top24)) * (1.0 / 16777216.0);
}

/// Bounded draw in `[0, bound)`. Plain modulo: acceptable for gameplay-scale
/// bounds (picking among a handful of candidates), not intended for
/// cryptographic-grade uniformity — bias is negligible for bound << 2^64.
pub fn boundedU32(seed: u64, entity_index: u32, step: u32, salt: u32, bound: u32) u32 {
    if (bound == 0) return 0;
    return @intCast(mix64(seed, entity_index, step, salt) % bound);
}

/// Deterministic unit vector, uniform in direction. Reuses `math.sinCos`
/// rather than reimplementing trig.
pub fn unitVec2(seed: u64, entity_index: u32, step: u32, salt: u32) math.Vec2 {
    const u = uniformF32(seed, entity_index, step, salt);
    const rotation = math.sinCos(u * 2.0 * std.math.pi);
    return .{ .x = rotation.cos, .y = rotation.sin };
}

test "mix64 is deterministic for identical inputs" {
    const a = mix64(42, 7, 100, 1);
    const b = mix64(42, 7, 100, 1);
    try std.testing.expectEqual(a, b);
}

test "mix64 output changes when entity_index, step, or salt changes independently" {
    const base = mix64(42, 7, 100, 1);
    try std.testing.expect(base != mix64(42, 8, 100, 1));
    try std.testing.expect(base != mix64(42, 7, 101, 1));
    try std.testing.expect(base != mix64(42, 7, 100, 2));
}

test "mix64 decorrelates across salts for the same (seed, entity_index, step)" {
    const s0 = mix64(1, 3, 9, 0);
    const s1 = mix64(1, 3, 9, 1);
    const s2 = mix64(1, 3, 9, 2);
    try std.testing.expect(s0 != s1);
    try std.testing.expect(s1 != s2);
    try std.testing.expect(s0 != s2);
}

test "uniformF32 stays in [0, 1) across a wide sample sweep" {
    var entity_index: u32 = 0;
    while (entity_index < 32) : (entity_index += 1) {
        var step: u32 = 0;
        while (step < 32) : (step += 1) {
            const v = uniformF32(0xabc, entity_index, step, 0);
            try std.testing.expect(v >= 0.0);
            try std.testing.expect(v < 1.0);
        }
    }
}

test "uniformF32 is roughly uniformly distributed" {
    var buckets = [_]u32{0} ** 10;
    var total: u32 = 0;
    var entity_index: u32 = 0;
    while (entity_index < 100) : (entity_index += 1) {
        var step: u32 = 0;
        while (step < 100) : (step += 1) {
            const v = uniformF32(0x1234, entity_index, step, 0);
            const bucket_idx: usize = @intFromFloat(@min(v * 10.0, 9.0));
            buckets[bucket_idx] += 1;
            total += 1;
        }
    }
    const expected_per_bucket: f32 = @as(f32, @floatFromInt(total)) / 10.0;
    for (buckets) |count| {
        const c: f32 = @floatFromInt(count);
        try std.testing.expect(c > expected_per_bucket * 0.5);
        try std.testing.expect(c < expected_per_bucket * 1.5);
    }
}

test "boundedU32 stays in [0, bound) including degenerate bounds" {
    try std.testing.expectEqual(@as(u32, 0), boundedU32(1, 1, 1, 0, 0));
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), boundedU32(1, i, i, 0, 1));
    }
    i = 0;
    while (i < 200) : (i += 1) {
        const v = boundedU32(1, i, i * 3, 2, 7);
        try std.testing.expect(v < 7);
    }
}

test "unitVec2 returns a unit-length vector" {
    const samples = [_][4]u64{
        .{ 1, 0, 0, 0 },
        .{ 42, 7, 100, 1 },
        .{ 0xdeadbeef, 500, 12345, 3 },
    };
    for (samples) |s| {
        const v = unitVec2(s[0], @intCast(s[1]), @intCast(s[2]), @intCast(s[3]));
        const len = math.length(v);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 0.001);
    }
}

test "rng outputs are call-order independent" {
    const a1 = mix64(5, 1, 1, 0);
    const b1 = mix64(5, 2, 1, 0);
    _ = mix64(5, 99, 99, 99);
    const a2 = mix64(5, 1, 1, 0);
    _ = mix64(5, 42, 7, 3);
    const b2 = mix64(5, 2, 1, 0);
    try std.testing.expectEqual(a1, a2);
    try std.testing.expectEqual(b1, b2);
}
