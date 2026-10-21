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

// Leaf helpers are inline: measured to cut the AI query's Debug Ir gap 52%, wall gap 68% at 2,048 entities.
pub inline fn float4(x: f32, y: f32, z: f32, w: f32) Float4 {
    return .{ x, y, z, w };
}

pub inline fn int4(x: i32, y: i32, z: i32, w: i32) Int4 {
    return .{ x, y, z, w };
}

pub inline fn splatFloat4(value: f32) Float4 {
    return @splat(value);
}

pub inline fn splatInt4(value: i32) Int4 {
    return @splat(value);
}

pub inline fn splatUint4(value: u32) Uint4 {
    return @splat(value);
}

/// The first four values; `values.len >= lane_count`.
pub inline fn loadFloat4(values: []const f32) Float4 {
    return values[0..lane_count].*;
}

/// The first four values; `values.len >= lane_count`.
pub inline fn loadInt4(values: []const i32) Int4 {
    return values[0..lane_count].*;
}

/// The first four values; `values.len >= lane_count`.
pub inline fn loadUint4(values: []const u32) Uint4 {
    return values[0..lane_count].*;
}

pub inline fn storeFloat4(values: *[lane_count]f32, vector: Float4) void {
    values.* = toFloatArray(vector);
}

pub inline fn storeFloat4Slice(values: []f32, vector: Float4) void {
    std.debug.assert(values.len >= lane_count);
    const stored = toFloatArray(vector);
    inline for (0..lane_count) |index| {
        values[index] = stored[index];
    }
}

/// Writes the first `count` lanes. `count <= lane_count`. Does not write past
/// `values[0..count]`.
pub fn storeFloat4Prefix(values: []f32, vector: Float4, count: usize) void {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    const stored = toFloatArray(vector);
    for (0..count) |lane| values[lane] = stored[lane];
}

/// Scalar form of `storeFloat4Prefix`.
fn storeFloat4PrefixScalar(values: []f32, lanes: [lane_count]f32, count: usize) void {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    for (0..count) |lane| values[lane] = lanes[lane];
}

/// Writes the first `count` lanes. `count <= lane_count`. Does not write past
/// `values[0..count]`.
pub fn storeUint4Prefix(values: []u32, vector: Uint4, count: usize) void {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    const stored = toUintArray(vector);
    for (0..count) |lane| values[lane] = stored[lane];
}

/// Scalar form of `storeUint4Prefix`.
fn storeUint4PrefixScalar(values: []u32, lanes: [lane_count]u32, count: usize) void {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    for (0..count) |lane| values[lane] = lanes[lane];
}

/// Stores the four lanes of `vector` into the first four values of `values`, in lane order;
/// the rest of `values` is left as it was.
pub inline fn storeUint4Slice(values: []u32, vector: Uint4) void {
    std.debug.assert(values.len >= lane_count);
    inline for (0..lane_count) |index| {
        values[index] = vector[index];
    }
}

pub inline fn storeInt4(values: *[lane_count]i32, vector: Int4) void {
    values.* = toIntArray(vector);
}

pub inline fn toFloatArray(vector: Float4) [lane_count]f32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub inline fn toUintArray(vector: Uint4) [lane_count]u32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub inline fn toIntArray(vector: Int4) [lane_count]i32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub inline fn addFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs + rhs;
}

pub inline fn addInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs + rhs;
}

pub inline fn subFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs - rhs;
}

pub inline fn subInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs - rhs;
}

pub inline fn mulFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs * rhs;
}

pub inline fn mulInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs * rhs;
}

pub inline fn divFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs / rhs;
}

/// Every lane shifted left by `amount`.
pub inline fn shiftLeftUint4(values: Uint4, comptime amount: u5) Uint4 {
    return values << @splat(amount);
}

/// Every lane shifted right by `amount`.
pub inline fn shiftRightUint4(values: Uint4, comptime amount: u5) Uint4 {
    return values >> @splat(amount);
}

/// Per-lane linear interpolation between `start` and `end` by `amount`. SIMD
/// counterpart of `math.lerp`.
pub inline fn lerpFloat4(start: Float4, end: Float4, amount: Float4) Float4 {
    return start + (end - start) * amount;
}

/// Per-lane truncating integer division. Lowered lane-by-lane because Zig's `/`
/// operator rejects signed integer operands (it requires @divTrunc/@divFloor/
/// @divExact), so there is no single signed-vector divide to fold this into.
pub inline fn divInt4(lhs: Int4, rhs: Int4) Int4 {
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

/// Vectorized counterpart of `math.orderedBits`, lane for lane: each lane's bits as a key
/// whose unsigned order is the float order, `-0` and `+0` one key.
pub inline fn orderedBitsFloat4(values: Float4) Uint4 {
    // Adding +0 turns -0 into +0 and leaves every other value as it is.
    const bits: Uint4 = @bitCast(values + splatFloat4(0));
    const sign_fill: Uint4 = @bitCast(@as(Int4, @bitCast(bits)) >> @splat(31));
    return bits ^ (sign_fill | splatUint4(0x8000_0000));
}

/// Vectorized counterpart of `math.floorToI32`: floors each lane to `i32`,
/// saturating identically to the scalar form (NaN -> 0; at/below `minInt(i32)`
/// -> `minInt(i32)`; at/above the f32 rounding of `maxInt(i32)` -> `maxInt(i32)`).
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

pub inline fn minFloat4(lhs: Float4, rhs: Float4) Float4 {
    return @min(lhs, rhs);
}

pub inline fn minInt4(lhs: Int4, rhs: Int4) Int4 {
    return @min(lhs, rhs);
}

pub inline fn maxFloat4(lhs: Float4, rhs: Float4) Float4 {
    return @max(lhs, rhs);
}

pub inline fn maxInt4(lhs: Int4, rhs: Int4) Int4 {
    return @max(lhs, rhs);
}

pub inline fn lessThanFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs < rhs;
}

pub inline fn lessThanInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs < rhs;
}

pub inline fn greaterThanFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs > rhs;
}

pub inline fn lessEqualFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs <= rhs;
}

pub inline fn greaterEqualFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs >= rhs;
}

pub inline fn greaterThanInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs > rhs;
}

pub inline fn equalFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs == rhs;
}

pub inline fn equalInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs == rhs;
}

pub inline fn equalUint4(lhs: Uint4, rhs: Uint4) Mask4 {
    return lhs == rhs;
}

/// `maskBits(lhs < rhs)`.
pub inline fn lessThanFloat4Bits(lhs: Float4, rhs: Float4) MaskBits {
    return maskBits(lhs < rhs);
}

/// `maskBits(lhs > rhs)`.
pub inline fn greaterThanFloat4Bits(lhs: Float4, rhs: Float4) MaskBits {
    return maskBits(lhs > rhs);
}

/// `maskBits(lhs == rhs)`.
pub inline fn equalUint4Bits(lhs: Uint4, rhs: Uint4) MaskBits {
    return maskBits(lhs == rhs);
}

pub inline fn selectFloat4(mask: Mask4, true_values: Float4, false_values: Float4) Float4 {
    return @select(f32, mask, true_values, false_values);
}

pub inline fn selectInt4(mask: Mask4, true_values: Int4, false_values: Int4) Int4 {
    return @select(i32, mask, true_values, false_values);
}

pub inline fn clampFloat4(values: Float4, minimum: Float4, maximum: Float4) Float4 {
    return minFloat4(maxFloat4(values, minimum), maximum);
}

pub inline fn clampInt4(values: Int4, minimum: Int4, maximum: Int4) Int4 {
    return minInt4(maxInt4(values, minimum), maximum);
}

/// A mask's lanes as bits, lane i at bit i: a lane loop walks the set bits in lane order.
pub inline fn maskBits(mask: Mask4) MaskBits {
    return @bitCast(mask);
}

/// One bit per lane of a `Mask4`.
pub const MaskBits = @Int(.unsigned, lane_count);

/// A lane's number, its bit's index in `MaskBits`.
pub const LaneIndex = std.math.Log2Int(MaskBits);

// `lanes_below[n]` holds lanes `[0, n)`.
const lanes_below = blk: {
    var table: [lane_count + 1]MaskBits = undefined;
    for (&table, 0..) |*bits, count| bits.* = @intCast((1 << count) - 1);
    break :blk table;
};

/// Lanes `[0, min(count, lane_count))`.
pub inline fn lanesBelow(count: usize) MaskBits {
    return lanes_below[@min(count, lane_count)];
}

/// The lowest `count` set bits of `bits`. Hand-rolled: `std.bit_set` has no lowest-n.
pub fn keepLowestSetBits(bits: MaskBits, count: usize) MaskBits {
    var beyond = bits;
    var kept: usize = 0;
    while (beyond != 0 and kept < count) : (kept += 1) beyond &= beyond - 1;
    return bits & ~beyond;
}

// `lane_words[bits]` is all ones in each lane set in `bits`, zero elsewhere.
const lane_words = blk: {
    var table: [1 << lane_count]Uint4 = undefined;
    for (&table, 0..) |*words, bits| {
        for (0..lane_count) |lane| words[lane] = if (bits & (1 << lane) != 0) std.math.maxInt(u32) else 0;
    }
    break :blk table;
};

/// The lanes of `values` set in `bits`, bit for bit, and `+0` in the rest.
pub inline fn selectOrZeroFloat4(bits: MaskBits, values: Float4) Float4 {
    // AND with a lane-word mask: no bool vector, which Debug lowers lane by lane.
    return @bitCast(@as(Uint4, @bitCast(values)) & lane_words[bits]);
}

/// `(lanes[0] + lanes[1]) + (lanes[2] + lanes[3])`: one order in every backend and mode,
/// which `@reduce` does not pin.
pub inline fn sumLanesFloat4(lanes: Float4) f32 {
    return (lanes[0] + lanes[1]) + (lanes[2] + lanes[3]);
}

/// Scalar form of `sumLanesFloat4`.
pub fn sumLanesScalar(lanes: [lane_count]f32) f32 {
    return (lanes[0] + lanes[1]) + (lanes[2] + lanes[3]);
}

// Counts the true lanes in a mask via a single vector reduction.
pub inline fn countTrue(mask: Mask4) u32 {
    return @reduce(.Add, @as(@Vector(lane_count, u32), @intFromBool(mask)));
}

pub inline fn vectorCount(item_count: usize) usize {
    return item_count / lane_count;
}

pub inline fn vectorizedEnd(item_count: usize) usize {
    return vectorCount(item_count) * lane_count;
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

/// In `lanes`, `(x, y) / sqrt(len2)`; `+0` elsewhere. Bit for bit
/// `math.normalizeOrZeroFinite(x, y, epsilon)` in each lane of `lanes` whose `x`, `y`, and
/// `len2 == x * x + y * y` are finite and `len2 > epsilon`, which the caller guarantees.
pub fn normalizeKnownFinite2Float4(x: Float4, y: Float4, len2: Float4, lanes: MaskBits) Vec2x4 {
    const inv = splatFloat4(1) / @sqrt(len2);
    return .{ .x = selectOrZeroFloat4(lanes, x * inv), .y = selectOrZeroFloat4(lanes, y * inv) };
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

/// Four lanes gathered at `indices`: the gather of the packed-SoA-scratch pattern.
pub inline fn gatherFloat4(values: []const f32, indices: [lane_count]usize) Float4 {
    return .{
        values[indices[0]],
        values[indices[1]],
        values[indices[2]],
        values[indices[3]],
    };
}

/// The `table` entries at the four lanes of `indices`: the u32 form of `gatherFloat4`, for
/// a table remap of a u32 id column (each lane's id is its index). Every index is below
/// `table.len`.
pub inline fn gatherUint4(table: []const u32, indices: Uint4) Uint4 {
    return .{
        table[indices[0]],
        table[indices[1]],
        table[indices[2]],
        table[indices[3]],
    };
}

/// Scalar form of `gatherUint4`.
fn gatherUint4Scalar(table: []const u32, indices: [lane_count]u32) [lane_count]u32 {
    var lanes: [lane_count]u32 = undefined;
    for (&lanes, indices) |*lane, index| lane.* = table[index];
    return lanes;
}

/// `gatherUint4` in the lanes set in `lanes`, and zero in the rest: a column's tail. Reads
/// only the set lanes' entries, so an inactive lane's index may be anything.
pub inline fn gatherUint4Masked(table: []const u32, indices: Uint4, lanes: MaskBits) Uint4 {
    var gathered = splatUint4(0);
    inline for (0..lane_count) |lane| {
        if (lanes & (@as(MaskBits, 1) << @intCast(lane)) != 0) gathered[lane] = table[indices[lane]];
    }
    return gathered;
}

/// Scalar form of `gatherUint4Masked`.
fn gatherUint4MaskedScalar(table: []const u32, indices: [lane_count]u32, lanes: MaskBits) [lane_count]u32 {
    var gathered = [_]u32{ 0, 0, 0, 0 };
    for (&gathered, indices, 0..) |*lane_value, index, lane| {
        if (lanes & (@as(MaskBits, 1) << @intCast(lane)) != 0) lane_value.* = table[index];
    }
    return gathered;
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

/// The first `count` values, and `+0` in the other lanes. `count <= lane_count`.
/// Reads only `values[0..count]`. A vector load would read past that prefix.
pub fn loadFloat4Prefix(values: []const f32, count: usize) Float4 {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    var lanes = [_]f32{ 0, 0, 0, 0 };
    for (0..count) |lane| lanes[lane] = values[lane];
    return lanes;
}

/// Scalar form of `loadFloat4Prefix`.
fn loadFloat4PrefixScalar(values: []const f32, count: usize) [lane_count]f32 {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    var lanes = [_]f32{ 0, 0, 0, 0 };
    for (0..count) |lane| lanes[lane] = values[lane];
    return lanes;
}

/// The first `count` values, and zero in the other lanes. `count <= lane_count`.
/// Reads only `values[0..count]`. A vector load would read past that prefix.
pub fn loadUint4Prefix(values: []const u32, count: usize) Uint4 {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    var lanes = [_]u32{ 0, 0, 0, 0 };
    for (0..count) |lane| lanes[lane] = values[lane];
    return lanes;
}

/// Scalar form of `loadUint4Prefix`.
fn loadUint4PrefixScalar(values: []const u32, count: usize) [lane_count]u32 {
    std.debug.assert(count <= lane_count);
    std.debug.assert(values.len >= count);
    var lanes = [_]u32{ 0, 0, 0, 0 };
    for (0..count) |lane| lanes[lane] = values[lane];
    return lanes;
}

/// Writes the lanes set in `lanes`. Distinctness is asserted only for those lanes,
/// so an inactive index may alias a live one.
pub fn scatterFloat4Masked(values: []f32, indices: [lane_count]usize, vector: Float4, lanes: MaskBits) void {
    inline for (0..lane_count) |i| {
        if (lanes & (@as(MaskBits, 1) << @intCast(i)) != 0) {
            inline for (i + 1..lane_count) |j| {
                if (lanes & (@as(MaskBits, 1) << @intCast(j)) != 0) {
                    std.debug.assert(indices[i] != indices[j]);
                }
            }
        }
    }
    inline for (0..lane_count) |lane| {
        if (lanes & (@as(MaskBits, 1) << @intCast(lane)) != 0) {
            values[indices[lane]] = vector[lane];
        }
    }
}

/// Scalar form of `scatterFloat4Masked`.
fn scatterFloat4MaskedScalar(values: []f32, indices: [lane_count]usize, vector: [lane_count]f32, lanes: MaskBits) void {
    inline for (0..lane_count) |i| {
        if (lanes & (@as(MaskBits, 1) << @intCast(i)) != 0) {
            inline for (i + 1..lane_count) |j| {
                if (lanes & (@as(MaskBits, 1) << @intCast(j)) != 0) {
                    std.debug.assert(indices[i] != indices[j]);
                }
            }
        }
    }
    inline for (0..lane_count) |lane| {
        if (lanes & (@as(MaskBits, 1) << @intCast(lane)) != 0) {
            values[indices[lane]] = vector[lane];
        }
    }
}

/// Per-lane reciprocal square root, `1 / sqrt(values)`. Lanes that are zero or
/// negative produce inf/NaN; guard the input when that is possible.
pub inline fn reciprocalSqrtFloat4(values: Float4) Float4 {
    return splatFloat4(1) / @sqrt(values);
}

/// Per-lane squared length of 2D vectors.
pub inline fn lengthSquared2Float4(x: Float4, y: Float4) Float4 {
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
pub inline fn lerpVec2Float4(start: Vec2x4, end: Vec2x4, amount: Float4) Vec2x4 {
    return .{ .x = lerpFloat4(start.x, end.x, amount), .y = lerpFloat4(start.y, end.y, amount) };
}

/// Per-lane 2D dot product: `ax * bx + ay * by`.
pub inline fn dotFloat4(ax: Float4, ay: Float4, bx: Float4, by: Float4) Float4 {
    return addFloat4(mulFloat4(ax, bx), mulFloat4(ay, by));
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

test "maskBits holds each lane at its bit, for every lane pattern" {
    for (0..1 << lane_count) |pattern| {
        var lanes: [lane_count]bool = undefined;
        for (&lanes, 0..) |*lane, index| lane.* = pattern & (@as(usize, 1) << @intCast(index)) != 0;
        const bits = maskBits(lanes);
        for (lanes, 0..) |lane, index| {
            try std.testing.expectEqual(lane, bits & (@as(MaskBits, 1) << @intCast(index)) != 0);
        }
        try std.testing.expectEqual(countTrue(lanes), @popCount(bits));
    }
}

test "vector count and vectorized end cover empty partial exact and multi lane counts" {
    try std.testing.expectEqual(@as(usize, 0), vectorCount(0));
    try std.testing.expectEqual(@as(usize, 0), vectorizedEnd(0));

    try std.testing.expectEqual(@as(usize, 0), vectorCount(3));
    try std.testing.expectEqual(@as(usize, 0), vectorizedEnd(3));

    try std.testing.expectEqual(@as(usize, 1), vectorCount(4));
    try std.testing.expectEqual(@as(usize, 4), vectorizedEnd(4));

    try std.testing.expectEqual(@as(usize, 2), vectorCount(11));
    try std.testing.expectEqual(@as(usize, 8), vectorizedEnd(11));
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

    var dest = [_]f32{ 0, 0, 0, 0, 0, 0 };
    scatterFloat4(&dest, .{ 5, 0, 3, 1 }, float4(15, 10, 13, 11));
    try std.testing.expectEqual([_]f32{ 10, 11, 0, 13, 0, 15 }, dest);
}

test "u32 gathers, masked gathers, and prefix stores match their scalar forms" {
    const table = [_]u32{ 10, 0, std.math.maxInt(u32), 0x8000_0000, 7, 7 };
    const index_sets = [_][lane_count]u32{ .{ 5, 0, 3, 1 }, .{ 2, 2, 2, 2 }, .{ 0, 1, 2, 3 }, .{ 4, 5, 4, 5 } };
    for (index_sets) |indices| {
        const gathered = toUintArray(gatherUint4(&table, indices));
        try std.testing.expectEqual(gatherUint4Scalar(&table, indices), gathered);
        for (0..1 << lane_count) |bits| {
            const lanes: MaskBits = @intCast(bits);
            const masked = toUintArray(gatherUint4Masked(&table, indices, lanes));
            try std.testing.expectEqual(gatherUint4MaskedScalar(&table, indices, lanes), masked);
            for (0..lane_count) |lane| {
                const expected = if (lanes & (@as(MaskBits, 1) << @intCast(lane)) != 0) gathered[lane] else 0;
                try std.testing.expectEqual(expected, masked[lane]);
            }
        }
    }
    // An inactive lane's index is never read: it may lie past the table.
    const past = [_]u32{ 1, std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
    try std.testing.expectEqual([_]u32{ 0, 0, 0, 0 }, toUintArray(gatherUint4Masked(&table, past, lanesBelow(1))));
    try std.testing.expectEqual([_]u32{ 0, 0, 0, 0 }, gatherUint4MaskedScalar(&table, past, lanesBelow(1)));

    const prefix_vector: Uint4 = .{ 0, std.math.maxInt(u32), 0x8000_0001, 5 };
    for (0..lane_count + 1) |count| {
        var prefix_simd = [_]u32{ 9, 9, 9, 9, 8, 7 };
        var prefix_scalar = prefix_simd;
        storeUint4Prefix(prefix_simd[0..], prefix_vector, count);
        storeUint4PrefixScalar(prefix_scalar[0..], toUintArray(prefix_vector), count);
        try std.testing.expectEqual(prefix_scalar, prefix_simd);
        for (prefix_simd[count..lane_count]) |untouched| try std.testing.expectEqual(@as(u32, 9), untouched);
        try std.testing.expectEqual(@as(u32, 8), prefix_simd[4]);
        try std.testing.expectEqual(@as(u32, 7), prefix_simd[5]);
    }
}

test "loadFloat4Prefix and scatterFloat4Masked match their scalar forms bit for bit" {
    const floats = [_]f32{ 1.25, -2.5, -0.0, 3.5 };
    const uints = [_]u32{ 0, 1, 0x8000_0000, 0xffff_ffff };
    for (0..lane_count + 1) |count| {
        const float_prefix = loadFloat4Prefix(floats[0..count], count);
        const float_scalar = loadFloat4PrefixScalar(floats[0..count], count);
        const uint_prefix = loadUint4Prefix(uints[0..count], count);
        const uint_scalar = loadUint4PrefixScalar(uints[0..count], count);
        const float_lanes = toFloatArray(float_prefix);
        const uint_lanes = toUintArray(uint_prefix);
        for (0..lane_count) |lane| {
            try std.testing.expectEqual(@as(u32, @bitCast(float_scalar[lane])), @as(u32, @bitCast(float_lanes[lane])));
            try std.testing.expectEqual(uint_scalar[lane], uint_lanes[lane]);
            if (lane >= count) {
                try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(float_lanes[lane])));
                try std.testing.expectEqual(@as(u32, 0), uint_lanes[lane]);
            }
        }
    }

    // Inactive indices alias the live one. The mask must not store them back.
    const alias = [_]usize{ 1, 1, 1, 1 };
    const alias_vector = float4(-0.0, 9, 9, 9);
    const alias_bits: MaskBits = 0b0001;
    var alias_simd = [_]f32{ 1, 2, 3, 4, 5 };
    var alias_scalar = alias_simd;
    scatterFloat4Masked(&alias_simd, alias, alias_vector, alias_bits);
    scatterFloat4MaskedScalar(&alias_scalar, alias, toFloatArray(alias_vector), alias_bits);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&alias_scalar), std.mem.asBytes(&alias_simd));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, -0.0))), @as(u32, @bitCast(alias_simd[1])));
    try std.testing.expectEqual(@as(f32, 1), alias_simd[0]);
    try std.testing.expectEqual(@as(f32, 3), alias_simd[2]);
    try std.testing.expectEqual(@as(f32, 4), alias_simd[3]);
    try std.testing.expectEqual(@as(f32, 5), alias_simd[4]);

    const prefix_vector = float4(-0.0, 1.5, -2.5, 3.5);
    for (0..lane_count + 1) |count| {
        var prefix_simd = [_]f32{ 7, 7, 7, 7, 8, 9 };
        var prefix_scalar = prefix_simd;
        storeFloat4Prefix(prefix_simd[0..], prefix_vector, count);
        storeFloat4PrefixScalar(prefix_scalar[0..], toFloatArray(prefix_vector), count);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&prefix_scalar), std.mem.asBytes(&prefix_simd));
        try std.testing.expectEqual(@as(f32, 8), prefix_simd[4]);
        try std.testing.expectEqual(@as(f32, 9), prefix_simd[5]);
    }

    const full_indices = [_]usize{ 5, 0, 3, 1 };
    const full_vector = float4(-0.0, 10, 13, 11);
    var full_masked = [_]f32{ 0, 0, 0, 0, 0, 0 };
    var full_scatter = full_masked;
    var full_scalar = full_masked;
    scatterFloat4Masked(&full_masked, full_indices, full_vector, lanesBelow(lane_count));
    scatterFloat4(&full_scatter, full_indices, full_vector);
    scatterFloat4MaskedScalar(&full_scalar, full_indices, toFloatArray(full_vector), lanesBelow(lane_count));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&full_scatter), std.mem.asBytes(&full_masked));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&full_scatter), std.mem.asBytes(&full_scalar));
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

test "orderedBitsFloat4 matches math.orderedBits lane-for-lane" {
    const inf = std.math.inf(f32);
    const subnormal = std.math.floatTrueMin(f32);
    const cases = [_]f32{
        0,                      -0.0,                    subnormal,  -subnormal,
        std.math.floatMin(f32), -std.math.floatMin(f32), inf,        -inf,
        std.math.floatMax(f32), -std.math.floatMax(f32), 1.5,        -1.5,
        std.math.nan(f32),      -std.math.nan(f32),      123_456.75, -0.001,
    };
    comptime std.debug.assert(cases.len % lane_count == 0);
    var start: usize = 0;
    while (start < cases.len) : (start += lane_count) {
        const lanes: [lane_count]u32 = orderedBitsFloat4(loadFloat4(cases[start..]));
        for (0..lane_count) |lane| try std.testing.expectEqual(math.orderedBits(cases[start + lane]), lanes[lane]);
    }
}

// Lane values for the compare and select tests: ordinary, equal, signed zeros, infinities,
// and NaN.
const compare_lane_values = [_]f32{ -2, 0, -0.0, 1.5, 3, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };

test "compare-to-bits matches each lane's scalar compare for every lane pattern, NaN, signed zeros, infinities, and equal lanes" {
    var prng = std.Random.DefaultPrng.init(0xb175_c0de);
    const random = prng.random();
    for (0..512) |_| {
        var lhs: [lane_count]f32 = undefined;
        var rhs: [lane_count]f32 = undefined;
        var lhs_words: [lane_count]u32 = undefined;
        var rhs_words: [lane_count]u32 = undefined;
        for (0..lane_count) |lane| {
            lhs[lane] = compare_lane_values[random.uintLessThan(usize, compare_lane_values.len)];
            rhs[lane] = compare_lane_values[random.uintLessThan(usize, compare_lane_values.len)];
            lhs_words[lane] = random.uintLessThan(u32, 3);
            rhs_words[lane] = if (random.boolean()) lhs_words[lane] else std.math.maxInt(u32) - random.uintLessThan(u32, 2);
        }
        const less = lessThanFloat4Bits(loadFloat4(&lhs), loadFloat4(&rhs));
        const greater = greaterThanFloat4Bits(loadFloat4(&lhs), loadFloat4(&rhs));
        const equal = equalUint4Bits(loadUint4(&lhs_words), loadUint4(&rhs_words));
        for (0..lane_count) |lane| {
            const bit = @as(MaskBits, 1) << @intCast(lane);
            try std.testing.expectEqual(lhs[lane] < rhs[lane], less & bit != 0);
            try std.testing.expectEqual(lhs[lane] > rhs[lane], greater & bit != 0);
            try std.testing.expectEqual(lhs[lane] <= rhs[lane], maskBits(lessEqualFloat4(loadFloat4(&lhs), loadFloat4(&rhs))) & bit != 0);
            try std.testing.expectEqual(lhs[lane] >= rhs[lane], maskBits(greaterEqualFloat4(loadFloat4(&lhs), loadFloat4(&rhs))) & bit != 0);
            try std.testing.expectEqual(lhs_words[lane] == rhs_words[lane], equal & bit != 0);
        }
    }
}

test "lanesBelow and keepLowestSetBits match a reference loop for every mask and count 0..5" {
    for (0..lane_count + 2) |count| {
        var below: MaskBits = 0;
        for (0..@min(count, lane_count)) |lane| below |= @as(MaskBits, 1) << @intCast(lane);
        try std.testing.expectEqual(below, lanesBelow(count));
        for (0..1 << lane_count) |pattern| {
            const bits: MaskBits = @intCast(pattern);
            var kept: MaskBits = 0;
            var taken: usize = 0;
            for (0..lane_count) |lane| {
                const bit = @as(MaskBits, 1) << @intCast(lane);
                if (bits & bit != 0 and taken < count) {
                    kept |= bit;
                    taken += 1;
                }
            }
            try std.testing.expectEqual(kept, keepLowestSetBits(bits, count));
        }
    }
}

test "selectOrZeroFloat4 keeps masked lanes bit for bit and zeroes the rest for every mask" {
    const values = float4(std.math.nan(f32), -0.0, std.math.inf(f32), -3.25);
    const value_lanes = toFloatArray(values);
    for (0..1 << lane_count) |pattern| {
        const bits: MaskBits = @intCast(pattern);
        const selected = toFloatArray(selectOrZeroFloat4(bits, values));
        for (0..lane_count) |lane| {
            const want: f32 = if (bits & (@as(MaskBits, 1) << @intCast(lane)) != 0) value_lanes[lane] else 0;
            try std.testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(selected[lane])));
        }
    }
}

test "normalizeKnownFinite2Float4 matches math.normalizeOrZeroFinite bit for bit on finite lanes with len2 above epsilon, and zeroes the masked lanes" {
    for ([_]f32{ 0, 0.0001, 0.25 }) |epsilon| {
        var index: usize = 0;
        while (index < finite_normalize_cases.len) : (index += lane_count) {
            var xs: [lane_count]f32 = undefined;
            var ys: [lane_count]f32 = undefined;
            var lanes: MaskBits = 0;
            for (finite_normalize_cases[index..][0..lane_count], &xs, &ys, 0..) |case, *x, *y, lane| {
                x.* = case[0];
                y.* = case[1];
                const len2 = case[0] * case[0] + case[1] * case[1];
                const meets = std.math.isFinite(case[0]) and std.math.isFinite(case[1]) and std.math.isFinite(len2) and len2 > epsilon;
                if (meets) lanes |= @as(MaskBits, 1) << @intCast(lane);
            }
            const x_lanes = loadFloat4(&xs);
            const y_lanes = loadFloat4(&ys);
            const out = normalizeKnownFinite2Float4(x_lanes, y_lanes, lengthSquared2Float4(x_lanes, y_lanes), lanes);
            const out_x = toFloatArray(out.x);
            const out_y = toFloatArray(out.y);
            for (0..lane_count) |lane| {
                const expected = math.normalizeOrZeroFinite(xs[lane], ys[lane], epsilon);
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(out_x[lane])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(out_y[lane])));
            }
        }
    }
}

test "sumLanesFloat4 equals its scalar form bit for bit, in its pinned pairwise order" {
    // Sequential `((a + b) + c) + d` gives 1 here; the pinned pairwise order gives 0.
    const order_case = [lane_count]f32{ 1e8, 1, -1e8, 1 };
    try std.testing.expectEqual(@as(f32, 1), ((order_case[0] + order_case[1]) + order_case[2]) + order_case[3]);
    try std.testing.expectEqual(@as(f32, 0), sumLanesFloat4(order_case));
    var prng = std.Random.DefaultPrng.init(0x5e3_1a4e);
    const random = prng.random();
    for (0..256) |_| {
        var lanes: [lane_count]f32 = undefined;
        for (&lanes) |*lane| lane.* = (random.float(f32) - 0.5) * std.math.pow(f32, 10, @floatFromInt(random.uintLessThan(u8, 12)));
        try std.testing.expectEqual(@as(u32, @bitCast(sumLanesScalar(lanes))), @as(u32, @bitCast(sumLanesFloat4(loadFloat4(&lanes)))));
    }
}

test "shiftLeftUint4 and shiftRightUint4 match a per-lane shift" {
    const words = [lane_count]u32{ 1, 0x8000_0001, std.math.maxInt(u32), 0x1234_5678 };
    const lanes = loadUint4(&words);
    inline for ([_]u5{ 0, 1, 14, 31 }) |amount| {
        const left: [lane_count]u32 = shiftLeftUint4(lanes, amount);
        const right: [lane_count]u32 = shiftRightUint4(lanes, amount);
        for (0..lane_count) |lane| {
            try std.testing.expectEqual(words[lane] << amount, left[lane]);
            try std.testing.expectEqual(words[lane] >> amount, right[lane]);
        }
    }
}
