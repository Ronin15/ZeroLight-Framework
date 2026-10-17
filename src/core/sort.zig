// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Sorts whose element moves are whole-element copies.

const std = @import("std");

/// `std.sort.pdq` with each swap a whole-element copy: measured 433 to 60 Ir per swap in Debug.
pub fn pdq(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (context: @TypeOf(context), lhs: T, rhs: T) bool,
) void {
    const Context = struct {
        items: []T,
        sub_ctx: @TypeOf(context),

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return lessThanFn(ctx.sub_ctx, ctx.items[a], ctx.items[b]);
        }

        pub fn swap(ctx: @This(), a: usize, b: usize) void {
            const held = ctx.items[a];
            ctx.items[a] = ctx.items[b];
            ctx.items[b] = held;
        }
    };
    std.sort.pdqContext(0, items.len, Context{ .items = items, .sub_ctx = context });
}

// A 20-byte element with a total order on its key, then its tag.
const Record = struct {
    key: u64,
    tag: u32,
    weight: f32,
    extra: u32,

    fn lessThan(_: void, lhs: Record, rhs: Record) bool {
        if (lhs.key != rhs.key) return lhs.key < rhs.key;
        return lhs.tag < rhs.tag;
    }
};

const InputOrder = enum { random, sorted, reversed, all_equal };

fn fillKeys(keys: []u128, order: InputOrder, random: std.Random) void {
    for (keys, 0..) |*key, index| key.* = switch (order) {
        .random => random.int(u128) >> @intCast(random.uintLessThan(u8, 120)),
        .sorted => index,
        .reversed => keys.len - index,
        .all_equal => 7,
    };
}

test "pdq sorts like std.sort.pdq for u128 keys and a 20-byte record, over lengths and input orders" {
    var prng = std.Random.DefaultPrng.init(0x50e7_ab1e);
    const random = prng.random();
    var keys: [1000]u128 = undefined;
    var expected_keys: [1000]u128 = undefined;
    var records: [1000]Record = undefined;
    var expected_records: [1000]Record = undefined;
    var lengths: [66]usize = undefined;
    for (lengths[0..65], 0..) |*len, index| len.* = index;
    lengths[65] = 1000;
    for (lengths) |len| {
        for (std.meta.tags(InputOrder)) |order| {
            fillKeys(keys[0..len], order, random);
            @memcpy(expected_keys[0..len], keys[0..len]);
            pdq(u128, keys[0..len], {}, std.sort.asc(u128));
            std.sort.pdq(u128, expected_keys[0..len], {}, std.sort.asc(u128));
            try std.testing.expectEqualSlices(u128, expected_keys[0..len], keys[0..len]);

            for (records[0..len], keys[0..len], 0..) |*record, key, index| {
                record.* = .{ .key = @truncate(key % 13), .tag = @intCast(index), .weight = @floatFromInt(index % 5), .extra = random.int(u32) };
            }
            random.shuffle(Record, records[0..len]);
            @memcpy(expected_records[0..len], records[0..len]);
            pdq(Record, records[0..len], {}, Record.lessThan);
            std.sort.pdq(Record, expected_records[0..len], {}, Record.lessThan);
            // A total order: the same permutation as std's, so the same records in order.
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_records[0..len]), std.mem.sliceAsBytes(records[0..len]));
        }
    }
}
