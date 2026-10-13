// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The generation-stamped open-addressed table the engine's per-step key tables share
//! (nav's abstract and local search tables, the plane stage's landing claims): a slot is
//! live this generation when `stamp >> 1 == generation` (bit 0 is the owner's flag), so a
//! reset is O(1) outside the rare wraparound. Linear probe at load <= 1/2
//! (`hashTableSlots`), so every chain ends at a slot of another generation. Not
//! `std.HashMapUnmanaged`: its clear re-inits every slot's metadata (O(capacity)), and
//! removing a step's keys instead leaves tombstones that, over steps, make a missing
//! key's probe O(capacity).

const std = @import("std");

/// Largest generation of a table stamp `generation << 1 | flag`; the next one wraps to 1
/// after clearing every stamp.
pub const max_stamp_generation: u32 = std.math.maxInt(u32) >> 1;

/// Home slot of `key` in a power-of-two table of `2^(64 - shift)` slots (Fibonacci
/// hashing: the multiply spreads adjacent keys over the table).
pub fn fibonacciSlot(key: u64, shift: u6) usize {
    return @intCast((key *% 0x9E3779B97F4A7C15) >> shift);
}

/// Slot count of an open-addressed table holding at most `max_keys` keys at load <= 1/2:
/// `ceilPow2(max(16, 2 * max_keys))`. Fails as out of memory when the count overflows or
/// a slot id would not fit `u32`.
pub fn hashTableSlots(max_keys: usize) error{OutOfMemory}!usize {
    const slots = std.math.ceilPowerOfTwo(usize, @max(@as(usize, 16), max_keys *| 2)) catch return error.OutOfMemory;
    if (slots > std.math.maxInt(u32)) return error.OutOfMemory;
    return slots;
}

/// The `fibonacciSlot` shift of a power-of-two table of `slot_count` slots.
pub fn hashTableShift(slot_count: usize) u6 {
    std.debug.assert(std.math.isPowerOfTwo(slot_count) and slot_count >= 2);
    return @intCast(@as(usize, 64) - std.math.log2_int(usize, slot_count));
}

/// The table over `Slot` rows keyed by their `key_field`, each row carrying a `stamp: u32`.
/// The owner holds the slots, shift, generation, and claim count.
pub fn StampedTable(comptime Slot: type, comptime key_field: []const u8) type {
    const Key = @FieldType(Slot, key_field);
    return struct {
        pub const Claim = struct {
            slot: u32,
            fresh: bool,
        };

        /// A zeroed table for `limit` keys and its probe shift; allocates before the caller
        /// replaces anything.
        pub fn alloc(allocator: std.mem.Allocator, limit: usize) error{OutOfMemory}!struct { slots: []Slot, shift: u6 } {
            const slot_count = try hashTableSlots(limit);
            const slots = try allocator.alloc(Slot, slot_count);
            @memset(std.mem.sliceAsBytes(slots), 0);
            return .{ .slots = slots, .shift = hashTableShift(slot_count) };
        }

        /// Moves to the next generation, clearing every stamp on the wrap.
        pub fn advance(slots: []Slot, generation: *u32) void {
            if (generation.* == max_stamp_generation) {
                @memset(std.mem.sliceAsBytes(slots), 0);
                generation.* = 1;
            } else {
                generation.* += 1;
            }
        }

        /// The slot of `key` this generation, claiming it (`init(key, stamp)`) on first
        /// touch while `used` is below `budget`; null when a claim would pass the budget. A
        /// touched key always resolves. Scalar probe: about 1.5 slots per hit and 2.5 per
        /// miss at load <= 1/2, and `budget <= slots.len / 2` leaves a free slot on every
        /// chain.
        pub inline fn claim(slots: []Slot, shift: u6, generation: u32, used: *usize, budget: usize, key: Key, comptime init: fn (Key, u32) Slot) ?Claim {
            const slot_mask = slots.len - 1;
            var index = fibonacciSlot(key, shift);
            while (true) : (index = (index + 1) & slot_mask) {
                const slot = &slots[index];
                if (slot.stamp >> 1 == generation) {
                    if (@field(slot, key_field) == key) return .{ .slot = @intCast(index), .fresh = false };
                    continue;
                }
                if (used.* >= budget) return null;
                used.* += 1;
                slot.* = init(key, generation << 1);
                return .{ .slot = @intCast(index), .fresh = true };
            }
        }

        /// Whether `key` holds a slot this generation; claims nothing.
        pub inline fn contains(slots: []const Slot, shift: u6, generation: u32, key: Key) bool {
            const slot_mask = slots.len - 1;
            var index = fibonacciSlot(key, shift);
            while (slots[index].stamp >> 1 == generation) : (index = (index + 1) & slot_mask) {
                if (@field(slots[index], key_field) == key) return true;
            }
            return false;
        }
    };
}

const TestSlot = struct { key: u64, stamp: u32 };
const TestTable = StampedTable(TestSlot, "key");

fn testSlot(key: u64, stamp: u32) TestSlot {
    return .{ .key = key, .stamp = stamp };
}

test "a stamped table claims each key once per generation within its budget, and a new generation starts empty" {
    const allocator = std.testing.allocator;
    const table = try TestTable.alloc(allocator, 40);
    defer allocator.free(table.slots);
    try std.testing.expectEqual(@as(usize, 128), table.slots.len);
    var generation: u32 = 1;
    for (0..2) |_| {
        var used: usize = 0;
        for (0..40) |index| {
            const key = @as(u64, index % 3) << 32 | index * 977;
            try std.testing.expect(!TestTable.contains(table.slots, table.shift, generation, key));
            try std.testing.expect(TestTable.claim(table.slots, table.shift, generation, &used, 40, key, testSlot).?.fresh);
            try std.testing.expect(!TestTable.claim(table.slots, table.shift, generation, &used, 40, key, testSlot).?.fresh);
            try std.testing.expect(TestTable.contains(table.slots, table.shift, generation, key));
        }
        try std.testing.expectEqual(@as(usize, 40), used);
        // Past the budget a new key is refused; a claimed one still resolves.
        try std.testing.expectEqual(@as(?TestTable.Claim, null), TestTable.claim(table.slots, table.shift, generation, &used, 40, 1 << 40, testSlot));
        const claimed: u64 = @as(u64, 1) << 32 | 977;
        try std.testing.expect(TestTable.claim(table.slots, table.shift, generation, &used, 40, claimed, testSlot) != null);
        TestTable.advance(table.slots, &generation);
        try std.testing.expect(!TestTable.contains(table.slots, table.shift, generation, claimed));
    }
}

test "a stamped table's wrapped generation clears every stamp once" {
    const allocator = std.testing.allocator;
    const table = try TestTable.alloc(allocator, 8);
    defer allocator.free(table.slots);
    var generation: u32 = max_stamp_generation;
    var used: usize = 0;
    _ = TestTable.claim(table.slots, table.shift, generation, &used, 8, 5, testSlot);
    TestTable.advance(table.slots, &generation);
    try std.testing.expectEqual(@as(u32, 1), generation);
    for (table.slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.stamp);
    try std.testing.expect(!TestTable.contains(table.slots, table.shift, generation, 5));
}
