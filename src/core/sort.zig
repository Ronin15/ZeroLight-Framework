// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Sorts whose element moves are whole-element copies. std's `pdq` and `insertion`
//! swap through `std.mem.swap`, a per-byte loop.

const std = @import("std");

/// `std.sort.pdq` with each swap a whole-element copy. Unstable.
pub fn pdq(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (context: @TypeOf(context), lhs: T, rhs: T) bool,
) void {
    const Context = SliceContext(T, @TypeOf(context), lessThanFn);
    std.sort.pdqContext(0, items.len, Context{ .items = items, .sub_ctx = context });
}

/// `std.sort.insertion` with each swap a whole-element copy. Stable; O(n²) moves.
pub fn insertion(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (context: @TypeOf(context), lhs: T, rhs: T) bool,
) void {
    const Context = SliceContext(T, @TypeOf(context), lessThanFn);
    std.sort.insertionContext(0, items.len, Context{ .items = items, .sub_ctx = context });
}

fn SliceContext(comptime T: type, comptime Context: type, comptime lessThanFn: fn (context: Context, lhs: T, rhs: T) bool) type {
    return struct {
        items: []T,
        sub_ctx: Context,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return lessThanFn(ctx.sub_ctx, ctx.items[a], ctx.items[b]);
        }

        pub fn swap(ctx: @This(), a: usize, b: usize) void {
            const held = ctx.items[a];
            ctx.items[a] = ctx.items[b];
            ctx.items[b] = held;
        }
    };
}

// A 24-byte element (20 bytes of fields, then padding) with a total order on its key,
// then its tag.
const Record = struct {
    key: u64,
    tag: u32,
    weight: f32,
    extra: u32,

    fn lessThan(_: void, lhs: Record, rhs: Record) bool {
        if (lhs.key != rhs.key) return lhs.key < rhs.key;
        return lhs.tag < rhs.tag;
    }

    // Key only: records sharing a key compare equal, so only a stable sort fixes their order.
    fn keyLessThan(_: void, lhs: Record, rhs: Record) bool {
        return lhs.key < rhs.key;
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

fn fillRecords(records: []Record, keys: []const u128, key_range: u64, random: std.Random) void {
    for (records, keys, 0..) |*record, key, index| {
        record.* = .{ .key = @truncate(key % key_range), .tag = @intCast(index), .weight = @floatFromInt(index % 5), .extra = random.int(u32) };
    }
}

test "pdq sorts like std.sort.pdq for u128 keys and a padded record, over lengths and input orders" {
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

            fillRecords(records[0..len], keys[0..len], 13, random);
            if (order == .random) random.shuffle(Record, records[0..len]);
            @memcpy(expected_records[0..len], records[0..len]);
            pdq(Record, records[0..len], {}, Record.lessThan);
            std.sort.pdq(Record, expected_records[0..len], {}, Record.lessThan);
            // A total order: the same permutation as std's, so the same records in order.
            try std.testing.expectEqualSlices(Record, expected_records[0..len], records[0..len]);
        }
    }
}

test "insertion sorts like std.sort.insertion, keeping equal keys in input order" {
    var prng = std.Random.DefaultPrng.init(0x1a5e_77ed);
    const random = prng.random();
    var keys: [200]u128 = undefined;
    var records: [200]Record = undefined;
    var expected_records: [200]Record = undefined;
    for (0..keys.len + 1) |len| {
        for (std.meta.tags(InputOrder)) |order| {
            fillKeys(keys[0..len], order, random);
            fillRecords(records[0..len], keys[0..len], 7, random);
            if (order == .random) random.shuffle(Record, records[0..len]);
            @memcpy(expected_records[0..len], records[0..len]);
            insertion(Record, records[0..len], {}, Record.keyLessThan);
            std.sort.insertion(Record, expected_records[0..len], {}, Record.keyLessThan);
            try std.testing.expectEqualSlices(Record, expected_records[0..len], records[0..len]);
        }
    }
}
