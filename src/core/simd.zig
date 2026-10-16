// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const math = @import("math.zig");

// Bytes in one vector register (SSE2, NEON); every lane count derives from it.
const vector_bytes: usize = 16;
/// Lanes of a 32-bit element type.
pub const lane_count: usize = vector_bytes / @sizeOf(u32);
// Lanes of a 16-bit element type.
const u16_lane_count: usize = vector_bytes / @sizeOf(u16);
const Uint16x8 = @Vector(u16_lane_count, u16);
pub const Float4 = @Vector(lane_count, f32);
pub const Int4 = @Vector(lane_count, i32);
pub const Uint4 = @Vector(lane_count, u32);
pub const Mask4 = @Vector(lane_count, bool);

pub fn float4(x: f32, y: f32, z: f32, w: f32) Float4 {
    return .{ x, y, z, w };
}

pub fn int4(x: i32, y: i32, z: i32, w: i32) Int4 {
    return .{ x, y, z, w };
}

pub fn splatFloat4(value: f32) Float4 {
    return @splat(value);
}

pub fn splatInt4(value: i32) Int4 {
    return @splat(value);
}

pub fn splatUint4(value: u32) Uint4 {
    return @splat(value);
}

pub fn loadFloat4(values: []const f32) Float4 {
    std.debug.assert(values.len >= lane_count);
    return .{ values[0], values[1], values[2], values[3] };
}

pub fn loadInt4(values: []const i32) Int4 {
    std.debug.assert(values.len >= lane_count);
    return .{ values[0], values[1], values[2], values[3] };
}

/// Loads four contiguous `u32` values into lane order. Used for direct
/// (non-gathered) loads over dense storage where consecutive indices are
/// already adjacent in memory.
pub fn loadUint4(values: []const u32) Uint4 {
    std.debug.assert(values.len >= lane_count);
    return .{ values[0], values[1], values[2], values[3] };
}

pub fn storeFloat4(values: *[lane_count]f32, vector: Float4) void {
    values.* = toFloatArray(vector);
}

pub fn storeFloat4Slice(values: []f32, vector: Float4) void {
    std.debug.assert(values.len >= lane_count);
    const stored = toFloatArray(vector);
    inline for (0..lane_count) |index| {
        values[index] = stored[index];
    }
}

/// Stores the four lanes of `vector` into the first four values of `values`, in lane order;
/// the rest of `values` is left as it was.
pub fn storeUint4Slice(values: []u32, vector: Uint4) void {
    std.debug.assert(values.len >= lane_count);
    inline for (0..lane_count) |index| {
        values[index] = vector[index];
    }
}

pub fn storeInt4(values: *[lane_count]i32, vector: Int4) void {
    values.* = toIntArray(vector);
}

pub fn toFloatArray(vector: Float4) [lane_count]f32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub fn toIntArray(vector: Int4) [lane_count]i32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub fn addFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs + rhs;
}

pub fn addInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs + rhs;
}

pub fn subFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs - rhs;
}

pub fn subInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs - rhs;
}

pub fn mulFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs * rhs;
}

pub fn mulInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs * rhs;
}

pub fn divFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs / rhs;
}

/// Per-lane linear interpolation between `start` and `end` by `amount`. SIMD
/// counterpart of `math.lerp`.
pub fn lerpFloat4(start: Float4, end: Float4, amount: Float4) Float4 {
    return start + (end - start) * amount;
}

/// Per-lane truncating integer division. Lowered lane-by-lane because Zig's `/`
/// operator rejects signed integer operands (it requires @divTrunc/@divFloor/
/// @divExact), so there is no single signed-vector divide to fold this into.
pub fn divInt4(lhs: Int4, rhs: Int4) Int4 {
    return .{
        @divTrunc(lhs[0], rhs[0]),
        @divTrunc(lhs[1], rhs[1]),
        @divTrunc(lhs[2], rhs[2]),
        @divTrunc(lhs[3], rhs[3]),
    };
}

/// Vectorized counterpart of `math.worldPosToCell`: floor each lane by
/// `tile_size`, then clamp to `[0, max_cells - 1]`. Returns `i32` lanes (grid
/// dimensions fit comfortably; callers that need `u32` cast after). When
/// `max_cells == 0`, every lane is 0 — matching the scalar helper.
pub fn worldPosToCell4(world_pos: Float4, tile_size: f32, max_cells: u32) Int4 {
    if (max_cells == 0) return splatInt4(0);
    const cells = floorToI4(divFloat4(world_pos, splatFloat4(tile_size)));
    return clampInt4(cells, splatInt4(0), splatInt4(@intCast(max_cells - 1)));
}

/// Vectorized counterpart of `math.lastCellOfSpan`, lane for lane: the last cell each
/// half-open span `[min_pos, max_pos)` covers, clamped to `[0, max_cells - 1]`, never
/// before the lane's min cell. Returns `i32` lanes like `worldPosToCell4`.
pub fn lastCellOfSpan4(min_pos: Float4, max_pos: Float4, cell_size: f32, max_cells: u32) Int4 {
    const first = worldPosToCell4(min_pos, cell_size, max_cells);
    const end_cells = @ceil(divFloat4(max_pos, splatFloat4(cell_size)));
    const last = worldPosToCell4(subFloat4(end_cells, splatFloat4(1)), 1, max_cells);
    return selectInt4(greaterThanFloat4(max_pos, min_pos), maxInt4(first, last), first);
}

/// Vectorized counterpart of `math.floorToI32`: floors each lane to `i32`,
/// saturating identically to the scalar form (NaN -> 0; at/below `minInt(i32)`
/// -> `minInt(i32)`; at/above the f32 rounding of `maxInt(i32)` -> `maxInt(i32)`).
/// Lanes needing saturation are replaced with a safe dummy value before the
/// vector cast (Zig requires every lane in range for `@intFromFloat`) and then
/// patched with the exact saturated constant, mirroring the scalar function's
/// early-return branches instead of clamping into a castable subrange — the
/// f32 grid spacing near `maxInt(i32)` (256 apart) makes "clamp to max minus
/// one" silently round back to the unrepresentable boundary.
pub fn floorToI4(values: Float4) Int4 {
    const floored = @floor(values);
    const is_nan = floored != floored;
    const min_f = splatFloat4(@as(f32, @floatFromInt(std.math.minInt(i32))));
    const max_f = splatFloat4(@as(f32, @floatFromInt(std.math.maxInt(i32))));
    const at_or_below_min = floored <= min_f;
    const at_or_above_max = floored >= max_f;
    const needs_override = is_nan | at_or_below_min | at_or_above_max;
    const cast_source = selectFloat4(needs_override, splatFloat4(0), floored);
    const cast: Int4 = @intFromFloat(cast_source);
    const with_max = selectInt4(at_or_above_max, splatInt4(std.math.maxInt(i32)), cast);
    const with_min = selectInt4(at_or_below_min, splatInt4(std.math.minInt(i32)), with_max);
    return selectInt4(is_nan, splatInt4(0), with_min);
}

pub fn minFloat4(lhs: Float4, rhs: Float4) Float4 {
    return @min(lhs, rhs);
}

pub fn minInt4(lhs: Int4, rhs: Int4) Int4 {
    return @min(lhs, rhs);
}

pub fn maxFloat4(lhs: Float4, rhs: Float4) Float4 {
    return @max(lhs, rhs);
}

pub fn maxInt4(lhs: Int4, rhs: Int4) Int4 {
    return @max(lhs, rhs);
}

pub fn lessThanFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs < rhs;
}

pub fn lessThanInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs < rhs;
}

pub fn greaterThanFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs > rhs;
}

pub fn greaterThanInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs > rhs;
}

pub fn equalFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs == rhs;
}

pub fn equalInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs == rhs;
}

pub fn equalUint4(lhs: Uint4, rhs: Uint4) Mask4 {
    return lhs == rhs;
}

pub fn selectFloat4(mask: Mask4, true_values: Float4, false_values: Float4) Float4 {
    return @select(f32, mask, true_values, false_values);
}

pub fn selectInt4(mask: Mask4, true_values: Int4, false_values: Int4) Int4 {
    return @select(i32, mask, true_values, false_values);
}

pub fn clampFloat4(values: Float4, minimum: Float4, maximum: Float4) Float4 {
    return minFloat4(maxFloat4(values, minimum), maximum);
}

pub fn clampInt4(values: Int4, minimum: Int4, maximum: Int4) Int4 {
    return minInt4(maxInt4(values, minimum), maximum);
}

// Counts the true lanes in a mask via a single vector reduction.
pub fn countTrue(mask: Mask4) u32 {
    return @reduce(.Add, @as(@Vector(lane_count, u32), @intFromBool(mask)));
}

pub fn vectorCount(item_count: usize) usize {
    return item_count / lane_count;
}

pub fn vectorizedEnd(item_count: usize) usize {
    return vectorCount(item_count) * lane_count;
}

pub fn tailLen(item_count: usize) usize {
    return item_count - vectorizedEnd(item_count);
}

pub fn hasTail(item_count: usize) bool {
    return tailLen(item_count) != 0;
}

/// Counts positions `index` where `lhs[index] != rhs[index]`; the slices have equal
/// length. Whole registers, then a scalar tail.
pub fn countUnequalU16(lhs: []const u16, rhs: []const u16) u32 {
    std.debug.assert(lhs.len == rhs.len);
    const vector_end = lhs.len - lhs.len % u16_lane_count;
    var count: u32 = 0;
    var index: usize = 0;
    while (index < vector_end) : (index += u16_lane_count) {
        const lhs_lanes: Uint16x8 = lhs[index..][0..u16_lane_count].*;
        const rhs_lanes: Uint16x8 = rhs[index..][0..u16_lane_count].*;
        count += @reduce(.Add, @as(@Vector(u16_lane_count, u8), @intFromBool(lhs_lanes != rhs_lanes)));
    }
    return count + countUnequalU16Scalar(lhs[vector_end..], rhs[vector_end..]);
}

/// Scalar form of `countUnequalU16`.
pub fn countUnequalU16Scalar(lhs: []const u16, rhs: []const u16) u32 {
    std.debug.assert(lhs.len == rhs.len);
    var count: u32 = 0;
    for (lhs, rhs) |lhs_value, rhs_value| count += @intFromBool(lhs_value != rhs_value);
    return count;
}

/// Subtracts one from every value, stopping at zero. Whole registers, then a scalar tail.
pub fn decrementSaturatingU16(values: []u16) void {
    const vector_end = values.len - values.len % u16_lane_count;
    const one: Uint16x8 = @splat(1);
    var index: usize = 0;
    while (index < vector_end) : (index += u16_lane_count) {
        const lanes: Uint16x8 = values[index..][0..u16_lane_count].*;
        values[index..][0..u16_lane_count].* = lanes -| one;
    }
    decrementSaturatingU16Scalar(values[vector_end..]);
}

/// Scalar form of `decrementSaturatingU16`.
pub fn decrementSaturatingU16Scalar(values: []u16) void {
    for (values) |*value| value.* -|= 1;
}

/// Per-axis lanes of `math.normalizeOrZeroFinite`, equal to it bit for bit in every lane: zero
/// for a lane whose input, squared length, or ratio is non-finite or whose squared length is
/// at or below `epsilon`.
pub fn normalizeOrZeroFinite2Float4(x: Float4, y: Float4, epsilon: f32) Vec2x4 {
    return lengthDirection2Float4(x, y, epsilon).direction;
}

/// Per-axis lanes of `math.normalizeOrDefaultFinite`, equal to it bit for bit in every lane:
/// the lane of `default` wherever the scalar form returns its default.
pub fn normalizeOrDefaultFinite2Float4(x: Float4, y: Float4, epsilon: f32, default: Vec2x4) Vec2x4 {
    const finite_max = splatFloat4(std.math.floatMax(f32));
    const len2 = lengthSquared2Float4(x, y);
    const inputs_valid = finiteAboveEpsilon(x, y, len2, epsilon);
    const inv = splatFloat4(1) / @sqrt(len2);
    const normal_x = x * inv;
    const normal_y = y * inv;
    const valid = inputs_valid & (@abs(normal_x) <= finite_max) & (@abs(normal_y) <= finite_max);
    return .{ .x = selectFloat4(valid, normal_x, default.x), .y = selectFloat4(valid, normal_y, default.y) };
}

// Lanes where the scalar finite forms normalize: `x`, `y`, and the squared length `len2`
// finite, and `len2` above `epsilon`.
fn finiteAboveEpsilon(x: Float4, y: Float4, len2: Float4, epsilon: f32) Mask4 {
    const finite_max = splatFloat4(std.math.floatMax(f32));
    // `@abs(v) <= floatMax` is false for inf and NaN lanes.
    return (@abs(x) <= finite_max) & (@abs(y) <= finite_max) & (@abs(len2) <= finite_max) & greaterThanFloat4(len2, splatFloat4(epsilon));
}

/// Per-lane pair of 2D components (one `Float4` per axis).
pub const Vec2x4 = struct {
    x: Float4,
    y: Float4,
};

/// Per-lane sine and cosine results.
pub const SinCos4 = struct {
    sin: Float4,
    cos: Float4,
};

/// Gathers four `f32` values from `values` at the given indices into lane order.
///
/// This is the entry point of the **packed-SoA-scratch idiom**, the standard
/// way to vectorize a loop over sparse/filtered SoA indices in this codebase:
///
///  1. Scan the sparse/filtered index sequence (e.g. surviving broadphase
///     candidates, or entities that passed earlier scalar pre-filters) and
///     buffer up to `lane_count` indices at a time.
///  2. Once `lane_count` indices are buffered, `gatherFloat4` each needed SoA
///     column at those indices into contiguous lanes.
///  3. Vectorize the compare/math step over the gathered lanes, using
///     `selectFloat4`/`selectInt4` to mask per-lane outcomes instead of
///     branching.
///  4. Finish each lane scalarly for anything that does not vectorize (list
///     append, branchy asset/asset-ref lookups, building non-uniform output
///     records) — typically an `inline for (0..lane_count)` reading the
///     masked results lane-by-lane.
///  5. Handle the final `< lane_count` remainder (the tail) with the plain
///     scalar version of the same per-item logic; do not pad or mask a
///     partial group into a fake vector call.
///
/// `CollisionSystem` in `src/game/systems/collision.zig` is the canonical
/// example already in this codebase: `buildBroadphaseCandidatesSimd`
/// (`while (candidate_sorted_index + simd.lane_count <= sorted_count)`) packs
/// sorted proxy indices into `candidate_indices`, gathers `min_x`/`min_y`/
/// `max_x`/`max_y` with `gatherFloat4`, vectorizes the AABB overlap test, then
/// finishes each lane scalarly by appending surviving pairs — with a scalar
/// tail loop below it for `candidate_sorted_index < sorted_count`.
/// `writeNarrowphaseContactsSimd` follows the same shape one level further:
/// it gathers both proxies of each candidate pair (`a_indices`/`b_indices`)
/// to compute contacts in lanes, then appends only the lanes whose `valid`
/// mask is true.
pub fn gatherFloat4(values: []const f32, indices: [lane_count]usize) Float4 {
    return .{
        values[indices[0]],
        values[indices[1]],
        values[indices[2]],
        values[indices[3]],
    };
}

/// Gathers four `i32` values from `values` at the given indices into lane order.
pub fn gatherInt4(values: []const i32, indices: [lane_count]usize) Int4 {
    return .{
        values[indices[0]],
        values[indices[1]],
        values[indices[2]],
        values[indices[3]],
    };
}

/// Scatters lane values back to `values` at the given indices. Indices must be
/// distinct; overlapping targets make the result order-dependent.
pub fn scatterFloat4(values: []f32, indices: [lane_count]usize, vector: Float4) void {
    inline for (0..lane_count) |i| {
        inline for (i + 1..lane_count) |j| {
            std.debug.assert(indices[i] != indices[j]);
        }
    }
    inline for (0..lane_count) |lane| {
        values[indices[lane]] = vector[lane];
    }
}

/// Per-lane reciprocal square root, `1 / sqrt(values)`. Lanes that are zero or
/// negative produce inf/NaN; guard the input when that is possible.
pub fn reciprocalSqrtFloat4(values: Float4) Float4 {
    return splatFloat4(1) / @sqrt(values);
}

/// Per-lane squared length of 2D vectors.
pub fn lengthSquared2Float4(x: Float4, y: Float4) Float4 {
    return x * x + y * y;
}

/// Normalizes per-lane 2D vectors, returning zero for lanes whose squared
/// length is at or below `epsilon`. Matches `math.normalizeOrZero` (the
/// unguarded scalar form) exactly, including on non-finite input: the divisor
/// floor + short-lane mask only guarantee no divide-by-zero/short-length
/// inf/NaN — a non-finite INPUT still propagates (e.g. x=inf,y=0 gives
/// inf*rsqrt(inf)=inf*0=NaN, and the positive mask keeps it). Callers whose
/// vectors can be non-finite must pre-mask or use `math.normalizeOrZeroFinite`.
pub fn normalizeOrZero2Float4(x: Float4, y: Float4, epsilon: f32) Vec2x4 {
    const len2 = lengthSquared2Float4(x, y);
    const positive = greaterThanFloat4(len2, splatFloat4(epsilon));
    const safe_len2 = maxFloat4(len2, splatFloat4(std.math.floatMin(f32)));
    const inv_len = reciprocalSqrtFloat4(safe_len2);
    const zero = splatFloat4(0);
    return .{
        .x = selectFloat4(positive, x * inv_len, zero),
        .y = selectFloat4(positive, y * inv_len, zero),
    };
}

/// Per-lane length paired with the unit direction.
pub const LengthDirection4 = struct {
    length: Float4,
    direction: Vec2x4,
};

/// Per-lane length and unit direction of `(x, y)` from one `@sqrt`: SIMD counterpart of
/// `math.lengthDirection`, equal to it bit for bit in every lane, including the zero
/// length and direction of a lane whose input or squared length is non-finite or whose
/// squared length is at or below `epsilon`.
pub fn lengthDirection2Float4(x: Float4, y: Float4, epsilon: f32) LengthDirection4 {
    const len2 = lengthSquared2Float4(x, y);
    const valid = finiteAboveEpsilon(x, y, len2, epsilon);
    const len = @sqrt(len2);
    const inv = splatFloat4(1) / len;
    const zero = splatFloat4(0);
    return .{
        .length = selectFloat4(valid, len, zero),
        .direction = .{ .x = selectFloat4(valid, x * inv, zero), .y = selectFloat4(valid, y * inv, zero) },
    };
}

/// Per-lane linear interpolation of 2D vectors between `start` and `end` by
/// `amount`. SIMD counterpart of `math.lerpVec2`.
pub fn lerpVec2Float4(start: Vec2x4, end: Vec2x4, amount: Float4) Vec2x4 {
    return .{ .x = lerpFloat4(start.x, end.x, amount), .y = lerpFloat4(start.y, end.y, amount) };
}

/// Per-lane 2D dot product: `ax * bx + ay * by`.
pub fn dotFloat4(ax: Float4, ay: Float4, bx: Float4, by: Float4) Float4 {
    return addFloat4(mulFloat4(ax, bx), mulFloat4(ay, by));
}

/// Per-lane sine. Uses the compiler builtin element-wise over the vector; the
/// single call site lets a vectorized polynomial replace this later without
/// touching callers.
pub fn sinFloat4(values: Float4) Float4 {
    return @sin(values);
}

/// Per-lane cosine. See `sinFloat4` for the implementation note.
pub fn cosFloat4(values: Float4) Float4 {
    return @cos(values);
}

/// Per-lane sine and cosine together, for rotation and field-of-view math.
pub fn sinCosFloat4(values: Float4) SinCos4 {
    return .{ .sin = @sin(values), .cos = @cos(values) };
}

fn expectFloatArrayApprox(actual: [lane_count]f32, expected: [lane_count]f32) !void {
    for (actual, expected) |actual_value, expected_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.001);
    }
}

test "float load store and conversion keep stable lane order" {
    const source = [_]f32{ 1, 2, 3, 4 };
    const vector = loadFloat4(&source);

    try expectFloatArrayApprox(toFloatArray(vector), source);

    var stored: [lane_count]f32 = undefined;
    storeFloat4(&stored, vector);
    try expectFloatArrayApprox(stored, source);

    var stored_slice = [_]f32{ 0, 0, 0, 0, 99 };
    storeFloat4Slice(stored_slice[0..], vector);
    try expectFloatArrayApprox(stored_slice[0..lane_count].*, source);
    try std.testing.expectEqual(@as(f32, 99), stored_slice[lane_count]);
}

test "int load store and conversion keep stable lane order" {
    const source = [_]i32{ 1, -2, 3, -4 };
    const vector = loadInt4(&source);

    try std.testing.expectEqual(source, toIntArray(vector));

    var stored: [lane_count]i32 = undefined;
    storeInt4(&stored, vector);
    try std.testing.expectEqual(source, stored);
}

test "uint load and equal match scalar results, including the u32-max lane" {
    const lhs_source = [_]u32{ 5, 0, std.math.maxInt(u32), 7 };
    const rhs_source = [_]u32{ 5, 1, std.math.maxInt(u32), 8 };
    const lhs = loadUint4(&lhs_source);
    const rhs = loadUint4(&rhs_source);

    const mask = equalUint4(lhs, rhs);
    inline for (0..lane_count) |lane| {
        try std.testing.expectEqual(lhs_source[lane] == rhs_source[lane], mask[lane]);
    }
}

test "storeUint4Slice round-trips loadUint4 and writes exactly four words" {
    const source = [_]u32{ 1, std.math.maxInt(u32), 0, 0x8000_0001 };
    var stored = [_]u32{ 9, 9, 9, 9, 9, 9 };
    storeUint4Slice(stored[1..], loadUint4(&source));
    try std.testing.expectEqualSlices(u32, &source, stored[1..5]);
    try std.testing.expectEqual(@as(u32, 9), stored[0]);
    try std.testing.expectEqual(@as(u32, 9), stored[5]);
}

test "float operations match scalar results" {
    const lhs = float4(8, -6, 4, 9);
    const rhs = float4(2, 3, -2, 4.5);

    try expectFloatArrayApprox(toFloatArray(addFloat4(lhs, rhs)), .{ 10, -3, 2, 13.5 });
    try expectFloatArrayApprox(toFloatArray(subFloat4(lhs, rhs)), .{ 6, -9, 6, 4.5 });
    try expectFloatArrayApprox(toFloatArray(mulFloat4(lhs, rhs)), .{ 16, -18, -8, 40.5 });
    try expectFloatArrayApprox(toFloatArray(divFloat4(lhs, rhs)), .{ 4, -2, -2, 2 });
    try expectFloatArrayApprox(toFloatArray(minFloat4(lhs, rhs)), .{ 2, -6, -2, 4.5 });
    try expectFloatArrayApprox(toFloatArray(maxFloat4(lhs, rhs)), .{ 8, 3, 4, 9 });
}

test "int operations match scalar results" {
    const lhs = int4(8, -7, 4, -9);
    const rhs = int4(2, 3, -2, 4);

    try std.testing.expectEqual([_]i32{ 10, -4, 2, -5 }, toIntArray(addInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 6, -10, 6, -13 }, toIntArray(subInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 16, -21, -8, -36 }, toIntArray(mulInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 4, -2, -2, -2 }, toIntArray(divInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 2, -7, -2, -9 }, toIntArray(minInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 8, 3, 4, 4 }, toIntArray(maxInt4(lhs, rhs)));
}

test "compare select and clamp helpers match scalar behavior" {
    const values = float4(-4, 2, 6, 12);
    const minimum = splatFloat4(0);
    const maximum = splatFloat4(10);
    const mask = lessThanFloat4(values, maximum);

    try std.testing.expectEqual(Mask4{ true, true, true, false }, mask);
    try expectFloatArrayApprox(
        toFloatArray(selectFloat4(mask, values, maximum)),
        .{ -4, 2, 6, 10 },
    );
    try expectFloatArrayApprox(
        toFloatArray(clampFloat4(values, minimum, maximum)),
        .{ 0, 2, 6, 10 },
    );

    const ints = int4(-4, 2, 6, 12);
    try std.testing.expectEqual(Mask4{ false, true, true, true }, greaterThanInt4(ints, splatInt4(0)));
    try std.testing.expectEqual(
        [_]i32{ 0, 2, 6, 10 },
        toIntArray(clampInt4(ints, splatInt4(0), splatInt4(10))),
    );
}

test "countTrue matches a scalar lane sum" {
    try std.testing.expectEqual(@as(u32, 0), countTrue(Mask4{ false, false, false, false }));
    try std.testing.expectEqual(@as(u32, lane_count), countTrue(@splat(true)));
    try std.testing.expectEqual(@as(u32, 2), countTrue(Mask4{ true, false, true, false }));
    const mask = Mask4{ true, true, false, true };
    var scalar: u32 = 0;
    inline for (0..lane_count) |i| scalar += @intFromBool(mask[i]);
    try std.testing.expectEqual(scalar, countTrue(mask));
}

test "tail helpers cover empty partial exact and multi lane counts" {
    try std.testing.expectEqual(@as(usize, 0), vectorCount(0));
    try std.testing.expectEqual(@as(usize, 0), vectorizedEnd(0));
    try std.testing.expectEqual(@as(usize, 0), tailLen(0));
    try std.testing.expect(!hasTail(0));

    try std.testing.expectEqual(@as(usize, 0), vectorCount(3));
    try std.testing.expectEqual(@as(usize, 0), vectorizedEnd(3));
    try std.testing.expectEqual(@as(usize, 3), tailLen(3));
    try std.testing.expect(hasTail(3));

    try std.testing.expectEqual(@as(usize, 1), vectorCount(4));
    try std.testing.expectEqual(@as(usize, 4), vectorizedEnd(4));
    try std.testing.expectEqual(@as(usize, 0), tailLen(4));
    try std.testing.expect(!hasTail(4));

    try std.testing.expectEqual(@as(usize, 2), vectorCount(11));
    try std.testing.expectEqual(@as(usize, 8), vectorizedEnd(11));
    try std.testing.expectEqual(@as(usize, 3), tailLen(11));
    try std.testing.expect(hasTail(11));
}

test "countUnequalU16 matches its scalar form over every tail length and random, equal, and different data" {
    var prng = std.Random.DefaultPrng.init(0x00c0_0e16);
    const random = prng.random();
    var lhs: [33]u16 = undefined;
    var rhs: [33]u16 = undefined;
    for (0..lhs.len + 1) |len| {
        for (0..8) |_| {
            // A small value range so equal and unequal lanes both occur.
            for (lhs[0..len], rhs[0..len]) |*left, *right| {
                left.* = random.uintLessThan(u16, 3);
                right.* = random.uintLessThan(u16, 3);
            }
            try std.testing.expectEqual(countUnequalU16Scalar(lhs[0..len], rhs[0..len]), countUnequalU16(lhs[0..len], rhs[0..len]));
        }
        @memset(lhs[0..len], 0xBEEF);
        try std.testing.expectEqual(@as(u32, 0), countUnequalU16(lhs[0..len], lhs[0..len]));
        for (rhs[0..len], 0..) |*right, index| right.* = @intCast(index);
        @memset(lhs[0..len], std.math.maxInt(u16));
        try std.testing.expectEqual(@as(u32, @intCast(len)), countUnequalU16(lhs[0..len], rhs[0..len]));
    }
    // Overlapping views, as a chain of adjacent cells is compared.
    for (&lhs) |*value| value.* = random.uintLessThan(u16, 2);
    try std.testing.expectEqual(countUnequalU16Scalar(lhs[0..32], lhs[1..33]), countUnequalU16(lhs[0..32], lhs[1..33]));
}

test "decrementSaturatingU16 matches its scalar form over every tail length, stopping at zero" {
    var prng = std.Random.DefaultPrng.init(0x0dec_0016);
    const random = prng.random();
    var lanes: [33]u16 = undefined;
    var scalar: [33]u16 = undefined;
    for (0..lanes.len + 1) |len| {
        for (lanes[0..len], 0..) |*value, index| {
            // Zero, one, the maximum, and random values.
            value.* = switch (index % 4) {
                0 => 0,
                1 => 1,
                2 => std.math.maxInt(u16),
                else => random.int(u16),
            };
        }
        @memcpy(scalar[0..len], lanes[0..len]);
        decrementSaturatingU16(lanes[0..len]);
        decrementSaturatingU16Scalar(scalar[0..len]);
        try std.testing.expectEqualSlices(u16, scalar[0..len], lanes[0..len]);
        for (lanes[0..len], 0..) |value, index| {
            const expected: u16 = switch (index % 4) {
                0, 1 => 0,
                2 => std.math.maxInt(u16) - 1,
                else => value,
            };
            try std.testing.expectEqual(expected, value);
        }
    }
}

// Finite, zero, at and just past epsilon, overflowing squares, NaN, and inf lanes; with
// epsilon 0.25, (0.5, 0) sits exactly at epsilon.
const finite_normalize_cases = [_][2]f32{
    .{ 3, 4 },                              .{ -0.75, 12.5 },           .{ 0, 0 },                 .{ -0.0, 0 },
    .{ 0.5, 0 },                            .{ 0.5001, 0 },             .{ 1e-3, 0 },              .{ 1e-20, -1e-20 },
    .{ std.math.floatMax(f32), 0 },         .{ 1e20, 1e20 },            .{ std.math.nan(f32), 1 }, .{ 1, std.math.nan(f32) },
    .{ std.math.inf(f32), 0 },              .{ 0, -std.math.inf(f32) }, .{ 7, -24 },               .{ std.math.floatMin(f32), 0 },
    .{ std.math.floatTrueMin(f32), 1e-30 }, .{ -1e19, 1e19 },           .{ 0.1, -0.2 },            .{ -0.0, -0.0 },
};

test "normalizeOrZeroFinite2Float4 matches math.normalizeOrZeroFinite in every lane" {
    for ([_]f32{ 0, 0.0001, 0.25 }) |epsilon| {
        var index: usize = 0;
        while (index < finite_normalize_cases.len) : (index += lane_count) {
            var xs: [lane_count]f32 = undefined;
            var ys: [lane_count]f32 = undefined;
            for (finite_normalize_cases[index..][0..lane_count], &xs, &ys) |case, *x, *y| {
                x.* = case[0];
                y.* = case[1];
            }
            const lanes = normalizeOrZeroFinite2Float4(loadFloat4(&xs), loadFloat4(&ys), epsilon);
            const out_x = toFloatArray(lanes.x);
            const out_y = toFloatArray(lanes.y);
            for (0..lane_count) |lane| {
                const expected = math.normalizeOrZeroFinite(xs[lane], ys[lane], epsilon);
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(out_x[lane])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(out_y[lane])));
            }
        }
    }
}

test "normalizeOrDefaultFinite2Float4 matches math.normalizeOrDefaultFinite in every lane" {
    // Per-lane defaults, one of them NaN, so a wrong lane pick shows.
    const default_x = float4(0.6, -1, std.math.nan(f32), 0);
    const default_y = float4(0.8, 0, 2, -1);
    for ([_]f32{ 0, 0.0001, 0.25 }) |epsilon| {
        var index: usize = 0;
        while (index < finite_normalize_cases.len) : (index += lane_count) {
            var xs: [lane_count]f32 = undefined;
            var ys: [lane_count]f32 = undefined;
            for (finite_normalize_cases[index..][0..lane_count], &xs, &ys) |case, *x, *y| {
                x.* = case[0];
                y.* = case[1];
            }
            const lanes = normalizeOrDefaultFinite2Float4(loadFloat4(&xs), loadFloat4(&ys), epsilon, .{ .x = default_x, .y = default_y });
            const out_x = toFloatArray(lanes.x);
            const out_y = toFloatArray(lanes.y);
            const defaults_x = toFloatArray(default_x);
            const defaults_y = toFloatArray(default_y);
            for (0..lane_count) |lane| {
                const expected = math.normalizeOrDefaultFinite(xs[lane], ys[lane], epsilon, .{ .x = defaults_x[lane], .y = defaults_y[lane] });
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(out_x[lane])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(out_y[lane])));
            }
        }
    }
}

test "gather and scatter move lanes through sparse indices" {
    const source = [_]f32{ 10, 11, 12, 13, 14, 15 };
    const gathered = gatherFloat4(&source, .{ 5, 0, 3, 1 });
    try expectFloatArrayApprox(toFloatArray(gathered), .{ 15, 10, 13, 11 });

    const int_source = [_]i32{ 0, -1, -2, -3, -4 };
    try std.testing.expectEqual(
        [_]i32{ -4, 0, -2, -1 },
        toIntArray(gatherInt4(&int_source, .{ 4, 0, 2, 1 })),
    );

    var dest = [_]f32{ 0, 0, 0, 0, 0, 0 };
    scatterFloat4(&dest, .{ 5, 0, 3, 1 }, float4(15, 10, 13, 11));
    try std.testing.expectEqual([_]f32{ 10, 11, 0, 13, 0, 15 }, dest);
}

test "reciprocal sqrt matches scalar reference" {
    const values = float4(1, 4, 16, 0.25);
    const result = toFloatArray(reciprocalSqrtFloat4(values));
    try expectFloatArrayApprox(result, .{ 1, 0.5, 0.25, 2 });
}

test "normalize or zero matches scalar and zeroes short lanes" {
    const epsilon: f32 = 1.0e-12;
    const xs = float4(3, 0, -5, 0);
    const ys = float4(4, 0, 0, -2);
    const normalized = normalizeOrZero2Float4(xs, ys, epsilon);

    const x_out = toFloatArray(normalized.x);
    const y_out = toFloatArray(normalized.y);
    inline for (0..lane_count) |lane| {
        const len2 = xs[lane] * xs[lane] + ys[lane] * ys[lane];
        if (len2 <= epsilon) {
            try std.testing.expectEqual(@as(f32, 0), x_out[lane]);
            try std.testing.expectEqual(@as(f32, 0), y_out[lane]);
        } else {
            const inv = 1.0 / @sqrt(len2);
            try std.testing.expectApproxEqAbs(xs[lane] * inv, x_out[lane], 0.001);
            try std.testing.expectApproxEqAbs(ys[lane] * inv, y_out[lane], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 1), x_out[lane] * x_out[lane] + y_out[lane] * y_out[lane], 0.001);
        }
    }
}

test "lengthDirection2Float4 matches math.lengthDirection in every lane" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    const max = std.math.floatMax(f32);
    // Finite, zero, at and just past epsilon, overflowing squares, NaN, and inf lanes.
    const cases = [_][2]f32{
        .{ 3, 4 },   .{ -0.75, 12.5 }, .{ 0, 0 },       .{ -0.0, 0 },
        .{ 0.5, 0 }, .{ 0.5001, 0 },   .{ 1e-3, 0 },    .{ 1e-20, -1e-20 },
        .{ max, 0 }, .{ max, max },    .{ 1e20, 1e20 }, .{ nan, 1 },
        .{ 1, nan }, .{ inf, 0 },      .{ 0, -inf },    .{ 7, -24 },
    };
    // 0.25 makes (0.5, 0) a lane exactly at epsilon.
    for ([_]f32{ 0, 0.25 }) |epsilon| {
        var index: usize = 0;
        while (index < cases.len) : (index += lane_count) {
            var xs: [lane_count]f32 = undefined;
            var ys: [lane_count]f32 = undefined;
            for (cases[index..][0..lane_count], &xs, &ys) |case, *x, *y| {
                x.* = case[0];
                y.* = case[1];
            }
            const lanes = lengthDirection2Float4(loadFloat4(&xs), loadFloat4(&ys), epsilon);
            const lengths = toFloatArray(lanes.length);
            const directions_x = toFloatArray(lanes.direction.x);
            const directions_y = toFloatArray(lanes.direction.y);
            for (0..lane_count) |lane| {
                const expected = math.lengthDirection(xs[lane], ys[lane], epsilon);
                try std.testing.expectEqual(@as(u32, @bitCast(expected.length)), @as(u32, @bitCast(lengths[lane])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.direction.x)), @as(u32, @bitCast(directions_x[lane])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.direction.y)), @as(u32, @bitCast(directions_y[lane])));
            }
        }
    }
}

test "lerpVec2Float4 matches scalar math.lerpVec2 lane-for-lane with distinct per-lane amounts" {
    const start = Vec2x4{
        .x = float4(0, 10, -4, 100),
        .y = float4(0, -10, 8, -50),
    };
    const end = Vec2x4{
        .x = float4(10, 0, 6, 200),
        .y = float4(20, 10, -2, 25),
    };
    const amount = float4(0.0, 0.25, 0.5, 0.75);

    const result = lerpVec2Float4(start, end, amount);
    const x_out = toFloatArray(result.x);
    const y_out = toFloatArray(result.y);

    inline for (0..lane_count) |lane| {
        const expected = math.lerpVec2(
            .{ .x = start.x[lane], .y = start.y[lane] },
            .{ .x = end.x[lane], .y = end.y[lane] },
            amount[lane],
        );
        try std.testing.expectEqual(expected.x, x_out[lane]);
        try std.testing.expectEqual(expected.y, y_out[lane]);
    }
}

test "dotFloat4 matches scalar ax*bx + ay*by lane-for-lane" {
    const ax = float4(1, 10, -4, 100);
    const ay = float4(0, -10, 8, -50);
    const bx = float4(2, 0, 6, 0.5);
    const by = float4(3, 4, -2, -0.25);

    const result = toFloatArray(dotFloat4(ax, ay, bx, by));

    inline for (0..lane_count) |lane| {
        const expected = ax[lane] * bx[lane] + ay[lane] * by[lane];
        try std.testing.expectEqual(expected, result[lane]);
    }
}

test "floorToI4 matches math.floorToI32 lane-for-lane, including NaN/inf/boundary saturation" {
    const cases = [_]f32{
        0,                                             1.5,
        -1.5,                                          3.7,
        -3.2,                                          std.math.nan(f32),
        std.math.inf(f32),                             -std.math.inf(f32),
        1.0e30,                                        -1.0e30,
        @as(f32, @floatFromInt(std.math.minInt(i32))), @as(f32, @floatFromInt(std.math.maxInt(i32))),
        2.9999999,                                     -0.0001,
    };
    var i: usize = 0;
    while (i + lane_count <= cases.len) : (i += lane_count) {
        const vector = loadFloat4(cases[i..]);
        const simd_result = toIntArray(floorToI4(vector));
        for (0..lane_count) |lane| {
            try std.testing.expectEqual(math.floorToI32(cases[i + lane]), simd_result[lane]);
        }
    }
    // Cover the tail values individually too (cases.len is not lane-aligned).
    while (i < cases.len) : (i += 1) {
        const vector = splatFloat4(cases[i]);
        const simd_result = toIntArray(floorToI4(vector));
        try std.testing.expectEqual(math.floorToI32(cases[i]), simd_result[0]);
    }
}

test "worldPosToCell4 matches math.worldPosToCell lane-for-lane" {
    const tile_size: f32 = 32;
    const max_cells: u32 = 10;
    const cases = [_]f32{
        5 * 32 + 7,        3 * 32,             -1.0,              1.0e9,
        std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 100,
    };
    var i: usize = 0;
    while (i + lane_count <= cases.len) : (i += lane_count) {
        const vector = loadFloat4(cases[i..]);
        const simd_result = toIntArray(worldPosToCell4(vector, tile_size, max_cells));
        for (0..lane_count) |lane| {
            try std.testing.expectEqual(
                @as(i32, @intCast(math.worldPosToCell(cases[i + lane], tile_size, max_cells))),
                simd_result[lane],
            );
        }
    }
    try std.testing.expectEqual(
        @as(i32, @intCast(math.worldPosToCell(100, tile_size, 0))),
        toIntArray(worldPosToCell4(splatFloat4(100), tile_size, 0))[0],
    );
    try std.testing.expectEqual(
        @as(i32, @intCast(math.worldPosToCell(100, tile_size, 1))),
        toIntArray(worldPosToCell4(splatFloat4(100), tile_size, 1))[0],
    );
}

test "lastCellOfSpan4 matches math.lastCellOfSpan lane-for-lane" {
    const cells: u32 = 4096;
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    const up = struct {
        fn f(value: f32) f32 {
            return std.math.nextAfter(f32, value, std.math.inf(f32));
        }
    }.f;
    const down = struct {
        fn f(value: f32) f32 {
            return std.math.nextAfter(f32, value, -std.math.inf(f32));
        }
    }.f;
    // (min, max) pairs: boundaries and one ulp either side near 0, 32768, and 65536;
    // empty, inverted, NaN, infinite, and off-grid spans.
    const spans = [_][2]f32{
        .{ 0, 32 },                .{ 0, up(32) },            .{ 0, down(32) },          .{ 0, 0.001 },
        .{ 32_768, 32_800 },       .{ 32_768, up(32_800) },   .{ 32_768, down(32_800) }, .{ 35_296, 35_328 },
        .{ 35_296, up(35_328) },   .{ 35_296, down(35_328) }, .{ 65_536, 65_568 },       .{ 65_536, up(65_568) },
        .{ 65_536, down(65_568) }, .{ 32_768, 33_280 },       .{ 35_296, 35_296 },       .{ 35_328, 35_328 },
        .{ 35_296, 100 },          .{ 35_296, nan },          .{ nan, 35_328 },          .{ 0, inf },
        .{ -inf, 32 },             .{ -100, -40 },            .{ 0, 1.0e9 },             .{ 35_328, 35_328.001 },
    };
    comptime std.debug.assert(spans.len % lane_count == 0);
    var start: usize = 0;
    while (start < spans.len) : (start += lane_count) {
        var mins: [lane_count]f32 = undefined;
        var maxs: [lane_count]f32 = undefined;
        for (0..lane_count) |lane| {
            mins[lane] = spans[start + lane][0];
            maxs[lane] = spans[start + lane][1];
        }
        const simd_result = toIntArray(lastCellOfSpan4(loadFloat4(&mins), loadFloat4(&maxs), 32, cells));
        for (0..lane_count) |lane| {
            try std.testing.expectEqual(
                @as(i32, @intCast(math.lastCellOfSpan(mins[lane], maxs[lane], 32, cells))),
                simd_result[lane],
            );
        }
    }
    try std.testing.expectEqual(
        @as(i32, @intCast(math.lastCellOfSpan(0, 100, 32, 0))),
        toIntArray(lastCellOfSpan4(splatFloat4(0), splatFloat4(100), 32, 0))[0],
    );
}

test "sin and cos match scalar builtins per lane" {
    const angles = float4(0, std.math.pi / 6.0, std.math.pi / 2.0, std.math.pi);
    const sines = toFloatArray(sinFloat4(angles));
    const cosines = toFloatArray(cosFloat4(angles));
    const both = sinCosFloat4(angles);

    inline for (0..lane_count) |lane| {
        try std.testing.expectApproxEqAbs(@sin(angles[lane]), sines[lane], 0.0001);
        try std.testing.expectApproxEqAbs(@cos(angles[lane]), cosines[lane], 0.0001);
        try std.testing.expectApproxEqAbs(sines[lane], both.sin[lane], 0.0001);
        try std.testing.expectApproxEqAbs(cosines[lane], both.cos[lane], 0.0001);
    }
}
