// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Chunk keys and the dense per-level directory of chunk payloads. `chunkKey` builds the
//! (level, chunk) keys: any u64 whose bits 62-63 are not both set. `OrderedIndexSet` is the
//! ordered set chunk-key users (nav's plan merge, the world's batch grouping) drain chunk
//! and level indices through in order. `ChunkDirectory` is a dense per-level slot array into
//! a block pool: an occupied slot's payload is one byte allocation the owner splits into
//! columns. `padded` slots are cache-line records of `{ block, pending }` so workers writing
//! `pending` on adjacent chunks do not share a line.

const std = @import("std");
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;

/// End of an inverse chain, and "no entry" from a lookup.
pub const no_entry: u32 = std.math.maxInt(u32);
/// An empty directory slot, and a block id no live block holds.
pub const empty_block: u32 = std.math.maxInt(u32);

/// Splice and chunk-rewrite ranges cover a multiple of this many items, and each range's
/// record window starts on a cache line, so no two ranges write one line.
pub const splice_range_alignment_items: usize = 8;

comptime {
    std.debug.assert(splice_range_alignment_items * @sizeOf(u64) == thread_shared_record_alignment);
}

/// The key of `chunk` on `level`: bits 62-63 clear, level in bits 32-47, the level-local
/// chunk index in bits 0-31.
pub fn chunkKey(level: u16, chunk: u32) u64 {
    return (@as(u64, level) << 32) | chunk;
}

/// The level of chunk key `key`.
pub fn keyLevel(key: u64) u16 {
    return @intCast(key >> 32);
}

/// The level-local chunk index of chunk key `key`.
pub fn keyChunk(key: u64) u32 {
    return @truncate(key);
}

/// A set of indices below its capacity, popped in ascending order: one std bit set per tier,
/// each bit of a tier set exactly when its word in the tier below is nonzero, and a top tier
/// of one word. Insert and `popMin` cost O(tiers); `isEmpty` reads the top word. std's
/// `PriorityQueue` costs O(log n) per key and keeps repeats, and a std bit set's first-set
/// and iterator scan from word 0, so a drain would cost a local change O(capacity / 64).
pub const OrderedIndexSet = struct {
    pub const Word = std.bit_set.Dynamic.MaskInt;
    const word_bits = @bitSizeOf(Word);
    const word_shift = std.math.log2(word_bits);
    // Each tier divides the index width by `word_bits`, so any usize capacity summarizes to
    // one word within this many tiers.
    const max_tiers = @divCeil(@bitSizeOf(usize), word_shift);

    tiers: [max_tiers]std.bit_set.Dynamic = @splat(.{}),
    tier_count: usize = 0,

    // Mask words of a std bit set of `bits` bits.
    pub fn maskCount(bits: usize) usize {
        return @divCeil(bits, word_bits);
    }

    pub fn deinit(self: *OrderedIndexSet, allocator: std.mem.Allocator) void {
        for (self.tiers[0..self.tier_count]) |*tier| tier.deinit(allocator);
        self.* = .{};
    }

    pub fn capacity(self: *const OrderedIndexSet) usize {
        return self.tiers[0].capacity();
    }

    pub fn isEmpty(self: *const OrderedIndexSet) bool {
        return self.tier_count == 0 or self.tiers[self.tier_count - 1].masks[0] == 0;
    }

    // Grows an empty set to hold indices below `needed`, geometrically; true when it grew.
    // Builds every tier fresh and swaps them in: a tier-by-tier `resize` that failed past
    // the first tier would leave tiers that no longer summarize each other. An error leaves
    // the set as it was.
    pub fn reserve(self: *OrderedIndexSet, allocator: std.mem.Allocator, needed: usize) error{OutOfMemory}!bool {
        if (needed <= self.capacity()) return false;
        std.debug.assert(self.isEmpty());
        var fresh: OrderedIndexSet = .{};
        errdefer fresh.deinit(allocator);
        var tier_bits = @max(needed, 2 * self.capacity());
        while (true) {
            fresh.tiers[fresh.tier_count] = try .initEmpty(allocator, tier_bits);
            fresh.tier_count += 1;
            if (tier_bits <= word_bits) break;
            tier_bits = maskCount(tier_bits);
        }
        self.deinit(allocator);
        self.* = fresh;
        return true;
    }

    pub fn insert(self: *OrderedIndexSet, index: usize) void {
        std.debug.assert(index < self.capacity());
        var position = index;
        for (self.tiers[0..self.tier_count]) |*tier| {
            const word_was_empty = tier.masks[position >> word_shift] == 0;
            tier.set(position);
            // A nonempty word's summary bit is already set in every tier above.
            if (!word_was_empty) return;
            position >>= word_shift;
        }
    }

    // Removes and returns the smallest index, or null when empty.
    pub fn popMin(self: *OrderedIndexSet) ?usize {
        if (self.isEmpty()) return null;
        // Descend from the top word along each tier's lowest set bit.
        var position: usize = 0;
        var tier_index = self.tier_count;
        while (tier_index != 0) {
            tier_index -= 1;
            const word = self.tiers[tier_index].masks[position];
            std.debug.assert(word != 0);
            position = (position << word_shift) | @ctz(word);
        }
        const index = position;
        for (self.tiers[0..self.tier_count]) |*tier| {
            tier.unset(position);
            if (tier.masks[position >> word_shift] != 0) break;
            position >>= word_shift;
        }
        return index;
    }

    pub fn residentBytes(self: *const OrderedIndexSet) usize {
        var bytes: usize = 0;
        for (self.tiers[0..self.tier_count]) |tier| bytes += bitSetBytes(tier);
        return bytes;
    }
};

/// Fails the build unless every field of `T` is named exactly once, in `counted` (its
/// `residentBytes` sum reads it) or in `storage_free` (it owns no allocation), and every
/// name is a field: a field added later builds only once its bytes are classified.
pub fn assertFieldsClassified(comptime T: type, comptime counted: []const []const u8, comptime storage_free: []const []const u8) void {
    comptime {
        @setEvalBranchQuota(100_000);
        for (@typeInfo(T).@"struct".field_names) |name| {
            var listed: usize = 0;
            for (counted) |entry| listed += @intFromBool(std.mem.eql(u8, entry, name));
            for (storage_free) |entry| listed += @intFromBool(std.mem.eql(u8, entry, name));
            if (listed != 1) @compileError(@typeName(T) ++ "." ++ name ++ " is not listed exactly once as counted or storage-free");
        }
        for (counted) |entry| if (!@hasField(T, entry)) @compileError(@typeName(T) ++ " has no field " ++ entry);
        for (storage_free) |entry| if (!@hasField(T, entry)) @compileError(@typeName(T) ++ " has no field " ++ entry);
    }
}

/// Bytes of a std bit set: its masks and the length word before them, none when empty.
pub fn bitSetBytes(set: std.bit_set.Dynamic) usize {
    return bitSetBytesFor(set.capacity());
}

/// `bitSetBytes` of a set of `bits` bits.
pub fn bitSetBytesFor(bits: usize) usize {
    if (bits == 0) return 0;
    return (OrderedIndexSet.maskCount(bits) + 1) * @sizeOf(OrderedIndexSet.Word);
}

/// One level's chunk slots and a free-list pool of payloads. A slot holds a block id, or
/// `empty_block`. The block's bytes are one allocation; `Payload` is the owner's column
/// split of those bytes, stored beside them so freeing the block frees the allocation.
/// Methods take the caller's allocator; the directory does not store one. `padded` stores
/// each slot as a cache-line `PaddedSlot` of `{ block, pending }` so workers writing
/// `pending` on adjacent chunks do not share a line. Unpadded slots are plain block ids
/// and only the main thread writes them.
pub fn ChunkDirectory(comptime Payload: type, comptime padded: bool) type {
    return struct {
        const Self = @This();
        const SlotValue = struct { block: u32 = empty_block, pending: u32 = 0 };
        const Slot = if (padded) PaddedSlot(SlotValue) else u32;
        const Level = struct { slots: []Slot = &.{} };
        const Block = struct {
            bytes: []align(4) u8 = &.{},
            payload: Payload = .{},
        };

        levels: std.ArrayList(Level) = .empty,
        blocks: std.ArrayList(Block) = .empty,
        block_free: std.ArrayList(u32) = .empty,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var index: u32 = 0;
            while (index < self.levels.items.len) : (index += 1) self.closeLevel(allocator, index);
            self.levels.deinit(allocator);
            for (self.blocks.items) |block| if (block.bytes.len != 0) allocator.free(block.bytes);
            self.blocks.deinit(allocator);
            self.block_free.deinit(allocator);
            self.* = .{};
        }

        /// Allocates `level`'s slots once. A level already open at `slot_count` is left
        /// alone. A different count is only legal once every slot is empty: the old slots
        /// are freed after the new ones exist.
        pub fn openLevel(self: *Self, allocator: std.mem.Allocator, level: u32, slot_count: usize) error{OutOfMemory}!void {
            const index: usize = level;
            if (self.levels.items.len <= index) {
                try self.levels.ensureTotalCapacity(allocator, index + 1);
                self.levels.appendNTimesAssumeCapacity(.{}, index + 1 - self.levels.items.len);
            }
            const slots = &self.levels.items[index].slots;
            if (slots.len == slot_count) return;
            if (slots.len != 0) {
                for (slots.*) |held| std.debug.assert(slotBlock(held) == empty_block);
            }
            const fresh = try allocator.alloc(Slot, slot_count);
            if (comptime padded) {
                for (fresh) |*held| held.* = .{};
            } else {
                @memset(fresh, empty_block);
            }
            if (slots.len != 0) allocator.free(slots.*);
            slots.* = fresh;
        }

        /// Frees `level`'s slots and releases every block they hold.
        pub fn closeLevel(self: *Self, allocator: std.mem.Allocator, level: u32) void {
            if (level >= self.levels.items.len) return;
            const slots = self.levels.items[level].slots;
            for (slots) |held| {
                const block = slotBlock(held);
                if (block != empty_block) self.release(allocator, block);
            }
            if (slots.len != 0) allocator.free(slots);
            self.levels.items[level].slots = &.{};
        }

        pub fn levelCount(self: *const Self) usize {
            return self.levels.items.len;
        }

        pub fn slotCount(self: *const Self, level: u32) usize {
            if (level >= self.levels.items.len) return 0;
            return self.levels.items[level].slots.len;
        }

        /// The block id at `level`'s `index`, or `empty_block` when that slot was never opened.
        pub fn slot(self: *const Self, level: u32, index: usize) u32 {
            if (level >= self.levels.items.len) return empty_block;
            const slots = self.levels.items[level].slots;
            if (index >= slots.len) return empty_block;
            return slotBlock(slots[index]);
        }

        pub fn setSlot(self: *Self, level: u32, index: usize, block: u32) void {
            const slots = self.levels.items[level].slots;
            std.debug.assert(index < slots.len);
            setSlotBlock(&slots[index], block);
        }

        /// Grows the free block list to at least `needed` ids. A block id would pass
        /// `empty_block` only at 2^32 live blocks, which fails as `OutOfMemory` before the
        /// allocator is asked. Geometric, and the free list's capacity covers every block.
        pub fn ensureFree(self: *Self, allocator: std.mem.Allocator, needed: usize) error{OutOfMemory}!void {
            if (self.block_free.items.len >= needed) return;
            const added = needed - self.block_free.items.len;
            const total = self.blocks.items.len + added;
            if (total >= empty_block) return error.OutOfMemory;
            if (total > self.blocks.capacity) {
                try self.blocks.ensureTotalCapacity(allocator, @max(total, self.blocks.capacity *| 2));
            }
            try self.block_free.ensureTotalCapacity(allocator, self.blocks.capacity);
            const first: u32 = @intCast(self.blocks.items.len);
            self.blocks.appendNTimesAssumeCapacity(.{}, added);
            var id: u32 = @intCast(self.blocks.items.len);
            while (id > first) {
                id -= 1;
                self.block_free.appendAssumeCapacity(id);
            }
        }

        /// Takes a free block. Its bytes are empty until `setPayload`.
        pub fn claim(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!u32 {
            if (self.block_free.items.len == 0) try self.ensureFree(allocator, 1);
            return self.block_free.pop().?;
        }

        /// Returns `block` to the pool and frees its bytes.
        pub fn release(self: *Self, allocator: std.mem.Allocator, block: u32) void {
            const bytes = self.blocks.items[block].bytes;
            self.blocks.items[block] = .{};
            if (bytes.len != 0) allocator.free(bytes);
            std.debug.assert(self.block_free.items.len < self.block_free.capacity);
            self.block_free.appendAssumeCapacity(block);
        }

        /// Installs `bytes` and the column split `payload`. Does not free a previous
        /// allocation; the caller does, after this returns.
        pub fn setPayload(self: *Self, block: u32, bytes: []align(4) u8, columns: Payload) void {
            self.blocks.items[block].bytes = bytes;
            self.blocks.items[block].payload = columns;
        }

        pub fn payload(self: *const Self, block: u32) Payload {
            return self.blocks.items[block].payload;
        }

        pub fn blockBytes(self: *const Self, block: u32) []align(4) u8 {
            return self.blocks.items[block].bytes;
        }

        /// The stored column split. The caller updates `len` and the columns in place; a
        /// reallocation replaces the split through `setPayload`.
        pub fn payloadMut(self: *Self, block: u32) *Payload {
            return &self.blocks.items[block].payload;
        }

        /// `pending` on a padded slot. Only the registry's count workers write it, one
        /// shard per chunk, and the main thread clears it before apply.
        pub fn pending(self: *Self, level: u32, index: usize) *u32 {
            comptime std.debug.assert(padded);
            return &self.levels.items[level].slots[index].value.pending;
        }

        fn slotBlock(held: Slot) u32 {
            if (comptime padded) return held.value.block;
            return held;
        }

        fn setSlotBlock(held: *Slot, block: u32) void {
            if (comptime padded) held.value.block = block else held.* = block;
        }
    };
}


// The tier counts the set reserves at each capacity: one word, past one word, a full and past
// a full second tier, and four tiers.
const ordered_set_capacities = [_]struct { bits: usize, tiers: usize }{
    .{ .bits = 1, .tiers = 1 },
    .{ .bits = 64, .tiers = 1 },
    .{ .bits = 65, .tiers = 2 },
    .{ .bits = 4096, .tiers = 2 },
    .{ .bits = 4097, .tiers = 3 },
    .{ .bits = 300_000, .tiers = 4 },
};

test "the ordered index set pops each inserted index once in ascending order across word and tier boundaries, and is reusable once drained" {
    const allocator = std.testing.allocator;
    for (ordered_set_capacities) |shape| {
        var set: OrderedIndexSet = .{};
        defer set.deinit(allocator);
        try std.testing.expect(set.isEmpty());
        try std.testing.expect(try set.reserve(allocator, shape.bits));
        try std.testing.expectEqual(shape.tiers, set.tier_count);
        try std.testing.expect(!try set.reserve(allocator, shape.bits));
        var reference: std.ArrayList(u64) = .empty;
        defer reference.deinit(allocator);
        var prng = std.Random.DefaultPrng.init(shape.bits);
        const random = prng.random();
        for (0..2) |_| {
            try std.testing.expect(set.isEmpty());
            try std.testing.expectEqual(@as(?usize, null), set.popMin());
            reference.clearRetainingCapacity();
            // Indices at each word and tier edge, then random ones with repeats.
            for ([_]usize{ shape.bits - 1, 0, 63, 64, 4095, 4096, 262_143, 262_144 }) |index| {
                if (index >= shape.bits) continue;
                set.insert(index);
                try reference.append(allocator, index);
            }
            for (0..@min(2 * shape.bits, 4000)) |_| {
                const index = random.uintLessThan(usize, shape.bits);
                set.insert(index);
                try reference.append(allocator, index);
            }
            std.sort.pdq(u64, reference.items, {}, std.sort.asc(u64));
            var unique: usize = 0;
            for (reference.items) |key| {
                if (unique != 0 and reference.items[unique - 1] == key) continue;
                reference.items[unique] = key;
                unique += 1;
            }
            reference.items.len = unique;
            for (reference.items) |expected| try std.testing.expectEqual(@as(?usize, @intCast(expected)), set.popMin());
            try std.testing.expect(set.isEmpty());
        }
    }
}

test "an ordered index set reserve grows geometrically onto valid tiers, and one out of memory leaves the set as it was" {
    const allocator = std.testing.allocator;
    var set: OrderedIndexSet = .{};
    defer set.deinit(allocator);
    try std.testing.expect(try set.reserve(allocator, 64));
    set.insert(5);
    try std.testing.expectEqual(@as(?usize, 5), set.popMin());

    // A tier past the first fails: the earlier tiers free and the set keeps its one word.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, set.reserve(failing.allocator(), 4097));
    try std.testing.expectEqual(@as(usize, 64), set.capacity());
    try std.testing.expectEqual(@as(usize, 1), set.tier_count);
    set.insert(63);
    try std.testing.expectEqual(@as(?usize, 63), set.popMin());

    // Doubling covers the next 64-bit request with room to spare.
    try std.testing.expect(try set.reserve(allocator, 65));
    try std.testing.expectEqual(@as(usize, 128), set.capacity());
    try std.testing.expect(!try set.reserve(allocator, 128));
    for ([_]usize{ 127, 0, 64, 63 }) |index| set.insert(index);
    for ([_]usize{ 0, 63, 64, 127 }) |expected| try std.testing.expectEqual(@as(?usize, expected), set.popMin());
    try std.testing.expect(set.isEmpty());
}
