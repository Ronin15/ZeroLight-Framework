// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Chunk keys and the dense per-level directory of chunk payloads. `chunkKey` builds the
//! (level, chunk) keys: any u64 whose bits 62-63 are not both set. `OrderedIndexSet` is the
//! ordered set chunk-key users (nav's plan merge, the world's batch grouping) drain chunk
//! and level indices through in order. `ChunkDirectory` is a dense per-level slot array into
//! a block pool: an occupied slot's payload is one byte allocation the owner splits into
//! columns, or bytes the owner keeps in its `PayloadSlabs` pool. A directory `with_pending`
//! keeps a `pending` count per slot beside the block ids. `OrdinalClaims` hands out ids by
//! precomputed ordinal, so workers claim blocks and payload slots main reserved once.

const std = @import("std");
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

/// u32 ids handed out by ordinal: a call's claims and releases are counted first, reserved
/// once on the main thread, then read and written on workers at precomputed ordinals, and
/// committed by length. Claim ordinal `o` takes the free list's newest id first
/// (`free[len - 1 - o]`), then fresh ids from `next_id` up. Ids stay below `id_limit`, the
/// count the owner's storage covers, and the free list's capacity covers `id_limit`, so
/// every release of a live id fits without allocating. std has no ordinal-claim stack:
/// `std.heap.MemoryPool` and an `ArrayList` pop hand ids out one call at a time.
pub const OrdinalClaims = struct {
    free: std.ArrayList(u32) = .empty,
    next_id: u32 = 0,
    id_limit: u32 = 0,

    pub fn deinit(self: *OrdinalClaims, allocator: std.mem.Allocator) void {
        self.free.deinit(allocator);
        self.* = .{};
    }

    /// The id count the owner's storage must cover for a call claiming `claims` ids. Ids
    /// stay below `no_entry`; a total reaching it fails as `OutOfMemory`.
    pub fn idsNeeded(self: *const OrdinalClaims, claims: usize) error{OutOfMemory}!u32 {
        const fresh = claims -| self.free.items.len;
        const end = @as(u64, self.next_id) + fresh;
        if (end >= no_entry) return error.OutOfMemory;
        return @intCast(end);
    }

    /// Records that the owner's storage covers ids below `limit` and grows the free list's
    /// capacity to match. An error leaves the limit as it was.
    pub fn cover(self: *OrdinalClaims, allocator: std.mem.Allocator, limit: u32) error{OutOfMemory}!void {
        std.debug.assert(limit < no_entry);
        if (limit <= self.id_limit) return;
        try self.free.ensureTotalCapacity(allocator, limit);
        self.id_limit = limit;
    }

    /// The id claim `ordinal` takes. Pure, so workers read it while the list is unchanged.
    pub fn claimedId(self: *const OrdinalClaims, ordinal: usize) u32 {
        const free_len = self.free.items.len;
        // A fresh ordinal is below the claims `idsNeeded` passed for this call, so
        // `next_id + (ordinal - free_len)` is below that call's `end < no_entry`.
        const id: u32 = if (ordinal < free_len)
            self.free.items[free_len - 1 - ordinal]
        else
            @intCast(@as(u64, self.next_id) + (ordinal - free_len));
        std.debug.assert(id < self.id_limit);
        return id;
    }

    /// Takes the first `claims` ordinals: pops the free ids they read and advances `next_id`
    /// past the fresh ones.
    pub fn commitClaims(self: *OrdinalClaims, claims: usize) void {
        const popped = @min(claims, self.free.items.len);
        self.free.items.len -= popped;
        // `claims` is the count `idsNeeded` passed, so the fresh ones keep `next_id` below
        // its `end < no_entry`.
        self.next_id += @intCast(claims - popped);
        std.debug.assert(self.next_id <= self.id_limit);
    }

    /// Writes released `id` at release `position` past the free list's end. Distinct
    /// positions are disjoint elements, so workers write them concurrently.
    pub fn releaseAt(self: *const OrdinalClaims, position: usize, id: u32) void {
        const at = self.free.items.len + position;
        std.debug.assert(at < self.free.capacity);
        std.debug.assert(id < self.next_id);
        self.free.items.ptr[at] = id;
    }

    /// Adds the `releases` ids written by `releaseAt` to the free list.
    pub fn commitReleases(self: *OrdinalClaims, releases: usize) void {
        std.debug.assert(self.free.items.len + releases <= self.free.capacity);
        self.free.items.len += releases;
    }

    /// Releases every id at once: the next claim takes id 0. Keeps `id_limit` and the free
    /// list's capacity, so the storage the owner covered still covers its ids. O(1). Only
    /// for an owner that keeps no id past it.
    pub fn reset(self: *OrdinalClaims) void {
        self.free.clearRetainingCapacity();
        self.next_id = 0;
    }
};

/// A payload's place in a `PayloadSlabs` pool: its size class and its id in that class.
/// `none` holds no bytes.
pub const PayloadSlot = struct {
    class: u8 = 0,
    id: u32 = no_entry,

    pub const none: PayloadSlot = .{};

    pub fn isNone(self: PayloadSlot) bool {
        return self.id == no_entry;
    }
};

/// Size classes of `PayloadSlabs`: class `4 * octave + quarter` holds
/// `(4 + quarter) << (octave + 4)` bytes (64, 80, 96, 112, 128, 160, ...), four per octave,
/// so a payload wastes under a quarter of its slot. 132 classes reach past 2^38 bytes; a
/// format width, not a cap.
pub const max_payload_classes: usize = 132;
/// Slot and slab alignment of `PayloadSlabs`: every class size is a multiple of it.
pub const payload_slot_alignment: usize = 16;
// Bytes of a class's first slab (at least one slot); slab `j` holds `base << j` slots.
const payload_first_slab_bytes: usize = 4096;

/// A size-class slab pool of payload bytes, owned by one system and freed with it. Each
/// class's ids come from `OrdinalClaims`: main reserves a call's claims once per class,
/// workers read their claimed ids and write the slots' bytes, and main commits lengths, so
/// no allocator call is made per payload. A slot's bytes are found from its id in O(1), no
/// search. Freed slots are pooled for reuse within the class. Hand-rolled:
/// `std.heap.MemoryPool` is one comptime item size, allocates per item, and keeps a linked
/// free list workers cannot claim by ordinal.
pub const PayloadSlabs = struct {
    const Class = struct {
        slabs: std.ArrayList([]align(payload_slot_alignment) u8) = .empty,
        claims: OrdinalClaims = .{},
    };

    classes: [max_payload_classes]Class = @splat(.{}),
    /// Slabs held across every class; each one counts as one payload growth.
    slab_count: usize = 0,

    pub fn deinit(self: *PayloadSlabs, allocator: std.mem.Allocator) void {
        for (&self.classes) |*held| {
            for (held.slabs.items) |slab| allocator.free(slab);
            held.slabs.deinit(allocator);
            held.claims.deinit(allocator);
        }
        self.* = .{};
    }

    /// The slot bytes of `class`.
    fn classBytes(class: u8) usize {
        std.debug.assert(class < max_payload_classes);
        const octave: std.math.Log2Int(usize) = @intCast(class >> 2);
        const quarter: usize = class & 3;
        return (4 + quarter) << (octave + 4);
    }

    /// The smallest class whose slot holds `bytes`. A request past the last class fails as
    /// `OutOfMemory`.
    pub fn classFor(bytes: usize) error{OutOfMemory}!u8 {
        // In units of 16 bytes: the class holds `(4 + quarter) << octave` units.
        const units = @max(@divCeil(bytes, payload_slot_alignment), 4);
        if (units == 4) return 0;
        // `units - 1 >= 4`, so the log is at least 2; `quarters` is 5 to 8, and 8 is the
        // next octave's quarter 0.
        const octave = std.math.log2_int(usize, units - 1) - 2;
        const quarters = ((units - 1) >> octave) + 1;
        const class = 4 * @as(usize, octave) + quarters - 4;
        if (class >= max_payload_classes) return error.OutOfMemory;
        return @intCast(class);
    }

    fn slabBase(class: u8) usize {
        return @max(1, payload_first_slab_bytes / classBytes(class));
    }

    // Slots in a class's first `slabs` slabs: `base * (2^slabs - 1)`.
    fn slotsIn(base: usize, slabs: usize) u64 {
        // A reserve stops below 2^32 ids, so at most 33 slabs exist.
        std.debug.assert(slabs <= 33);
        return @as(u64, base) * ((@as(u64, 1) << @intCast(slabs)) - 1);
    }

    /// Makes `claims` ordinal claims of `class` fit: adds slabs, each double the last, until
    /// the class's storage covers them, and grows its free list so every release fits.
    /// Counted in `slab_count`. An error keeps the slabs added before it.
    pub fn reserve(self: *PayloadSlabs, allocator: std.mem.Allocator, class: u8, claims: usize) error{OutOfMemory}!void {
        const held = &self.classes[class];
        const needed = try held.claims.idsNeeded(claims);
        const base = slabBase(class);
        const slot_bytes = classBytes(class);
        while (slotsIn(base, held.slabs.items.len) < needed) {
            const slots = @as(u64, base) << @intCast(held.slabs.items.len);
            const bytes = std.math.mul(u64, slots, slot_bytes) catch return error.OutOfMemory;
            try held.slabs.ensureUnusedCapacity(allocator, 1);
            const slab = try allocator.alignedAlloc(u8, .fromByteUnits(payload_slot_alignment), std.math.cast(usize, bytes) orelse return error.OutOfMemory);
            held.slabs.appendAssumeCapacity(slab);
            self.slab_count += 1;
        }
        // Ids stay below `no_entry`, so a last slab past it covers only the ids below.
        const limit = @min(slotsIn(base, held.slabs.items.len), no_entry - 1);
        try held.claims.cover(allocator, @intCast(limit));
    }

    /// The id claim `ordinal` of `class` takes; pure, read on workers.
    pub fn claimedId(self: *const PayloadSlabs, class: u8, ordinal: usize) u32 {
        return self.classes[class].claims.claimedId(ordinal);
    }

    pub fn commitClaims(self: *PayloadSlabs, class: u8, claims: usize) void {
        self.classes[class].claims.commitClaims(claims);
    }

    /// Writes released `slot` at release `position` of its class; disjoint positions are
    /// written concurrently.
    pub fn releaseAt(self: *const PayloadSlabs, slot: PayloadSlot, position: usize) void {
        std.debug.assert(!slot.isNone());
        self.classes[slot.class].claims.releaseAt(position, slot.id);
    }

    pub fn commitReleases(self: *PayloadSlabs, class: u8, releases: usize) void {
        self.classes[class].claims.commitReleases(releases);
    }

    /// Releases every slot of `class` at once and keeps its slabs, so its next claims take
    /// ids from zero inside the storage it already holds. O(1). Only for an owner that keeps
    /// no slot of the class past it.
    pub fn resetClass(self: *PayloadSlabs, class: u8) void {
        self.classes[class].claims.reset();
    }

    /// The bytes of `slot`, `classBytes(slot.class)` long. O(1): slab
    /// `log2(id / base + 1)`, at `id - base * (2^slab - 1)`.
    pub fn bytesOf(self: *const PayloadSlabs, slot: PayloadSlot) []align(payload_slot_alignment) u8 {
        std.debug.assert(!slot.isNone());
        const held = &self.classes[slot.class];
        const base = slabBase(slot.class);
        const id: usize = slot.id;
        const slab = std.math.log2_int(usize, id / base + 1);
        const offset = id - base * ((@as(usize, 1) << slab) - 1);
        const size = classBytes(slot.class);
        // Every class size is a multiple of the slab alignment, so each slot starts aligned.
        return @alignCast(held.slabs.items[slab][offset * size ..][0..size]);
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
/// split of those bytes, stored beside them so freeing the block frees the allocation. An
/// owner that keeps payload bytes in its own pool leaves `bytes` empty and claims and
/// releases blocks by ordinal (`reserveClaims`). Such a pooled owner releases blocks only
/// through `releaseBlockAt`, and its slots through its pool: `release`, `emptyLevel`,
/// `truncateLevels`, and `releaseAll` return no pooled slot, so Debug asserts that each block
/// they release holds none (a `Payload` names its pooled slot `slot: PayloadSlot`).
/// `deinit` releases nothing, so it frees a pooled owner's directory before the pool.
/// Methods take the caller's allocator; the directory does not store one. `with_pending`
/// keeps a dense `pending` column beside each level's slots, one u32 per chunk. Workers
/// writing `pending` on chunks of different shards write disjoint scattered elements: the
/// sparse index maintenance `threading.md` § Writes exempts, so neither column is padded.
pub fn ChunkDirectory(comptime Payload: type, comptime with_pending: bool) type {
    return struct {
        const Self = @This();
        pub const Level = struct {
            slots: []u32 = &.{},
            pending: if (with_pending) []u32 else void = if (with_pending) &.{} else {},
        };
        pub const Block = struct {
            bytes: []align(4) u8 = &.{},
            payload: Payload = .{},
        };

        levels: std.ArrayList(Level) = .empty,
        blocks: std.ArrayList(Block) = .empty,
        block_free: std.ArrayList(u32) = .empty,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.levels.items) |held| {
                if (held.slots.len != 0) allocator.free(held.slots);
                if (comptime with_pending) {
                    if (held.pending.len != 0) allocator.free(held.pending);
                }
            }
            self.levels.deinit(allocator);
            for (self.blocks.items) |block| if (block.bytes.len != 0) allocator.free(block.bytes);
            self.blocks.deinit(allocator);
            self.block_free.deinit(allocator);
            self.* = .{};
        }

        /// Allocates `level`'s slots (and pending column) once. A level already open at
        /// `slot_count` is left alone. A different count is only legal once every slot is
        /// empty: the old columns are freed after the new ones exist.
        pub fn openLevel(self: *Self, allocator: std.mem.Allocator, level: u32, slot_count: usize) error{OutOfMemory}!void {
            const index: usize = level;
            if (self.levels.items.len <= index) {
                try self.levels.ensureTotalCapacity(allocator, index + 1);
                self.levels.appendNTimesAssumeCapacity(.{}, index + 1 - self.levels.items.len);
            }
            const held = &self.levels.items[index];
            if (held.slots.len == slot_count) return;
            if (held.slots.len != 0) {
                for (held.slots) |block| std.debug.assert(block == empty_block);
            }
            const fresh = try allocator.alloc(u32, slot_count);
            errdefer allocator.free(fresh);
            @memset(fresh, empty_block);
            if (comptime with_pending) {
                const pending_column = try allocator.alloc(u32, slot_count);
                @memset(pending_column, 0);
                if (held.pending.len != 0) allocator.free(held.pending);
                held.pending = pending_column;
            }
            if (held.slots.len != 0) allocator.free(held.slots);
            held.slots = fresh;
        }

        /// Closes every level at or past `count`: releases the blocks their slots hold, frees
        /// their columns, and drops their headers, so the directory holds only the levels
        /// below `count`. O(levels closed) plus their slots; the header list's storage is
        /// returned once at most half of it is in use.
        pub fn truncateLevels(self: *Self, allocator: std.mem.Allocator, count: usize) void {
            if (self.levels.items.len <= count) return;
            while (self.levels.items.len > count) {
                const level = self.levels.items.len - 1;
                self.emptyLevel(allocator, @intCast(level));
                const held = self.levels.items[level];
                if (held.slots.len != 0) allocator.free(held.slots);
                if (comptime with_pending) {
                    if (held.pending.len != 0) allocator.free(held.pending);
                }
                self.levels.items.len = level;
            }
            if (count *| 2 <= self.levels.capacity) self.levels.shrinkAndFree(allocator, count);
        }

        /// Releases every block `level`'s slots hold and empties its slots and pending
        /// counts; the columns stay allocated. One pass over the slot column, then a memset
        /// per column.
        // SIMD verdict: scalar filter of the slot column with one release per occupied
        // slot, allocator-bound; the clears are `@memset`.
        pub fn emptyLevel(self: *Self, allocator: std.mem.Allocator, level: u32) void {
            const held = self.levels.items[level];
            for (held.slots) |block| {
                if (block != empty_block) self.release(allocator, block);
            }
            @memset(held.slots, empty_block);
            if (comptime with_pending) @memset(held.pending, 0);
        }

        /// Empties every level's slots and pending counts and releases every block holding
        /// bytes; the level columns and the block pool's storage stay. A block holds bytes
        /// from its `setPayload` until its release, so this runs between those, never with a
        /// claimed block not yet installed. One memset per column and one pass over the block
        /// pool.
        // SIMD verdict: the column clears are `@memset`; the block pass frees one
        // allocation per occupied block, allocator-bound.
        pub fn releaseAll(self: *Self, allocator: std.mem.Allocator) void {
            for (self.levels.items) |held| {
                @memset(held.slots, empty_block);
                if (comptime with_pending) @memset(held.pending, 0);
            }
            for (self.blocks.items, 0..) |*block, id| {
                std.debug.assert(!holdsPooledSlot(&block.payload));
                if (block.bytes.len == 0) continue;
                allocator.free(block.bytes);
                block.* = .{};
                std.debug.assert(self.block_free.items.len < self.block_free.capacity);
                // Block ids stay below `empty_block`.
                self.block_free.appendAssumeCapacity(@intCast(id));
            }
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
            return slots[index];
        }

        pub fn setSlot(self: *Self, level: u32, index: usize, block: u32) void {
            const slots = self.levels.items[level].slots;
            std.debug.assert(index < slots.len);
            slots[index] = block;
        }

        /// Grows the free block list to at least `needed` ids. A block id would pass
        /// `empty_block` only at 2^32 live blocks, which fails as `OutOfMemory` before the
        /// allocator is asked. Geometric, and the free list's capacity covers every block.
        pub fn ensureFree(self: *Self, allocator: std.mem.Allocator, needed: usize) error{OutOfMemory}!void {
            if (self.block_free.items.len >= needed) return;
            const added = needed - self.block_free.items.len;
            const total = self.blocks.items.len + added;
            if (total >= empty_block) return error.OutOfMemory;
            try self.growBlocks(allocator, total);
            const first: u32 = @intCast(self.blocks.items.len);
            self.blocks.appendNTimesAssumeCapacity(.{}, added);
            var id: u32 = @intCast(self.blocks.items.len);
            while (id > first) {
                id -= 1;
                self.block_free.appendAssumeCapacity(id);
            }
        }

        // Grows the block pool's capacity to `total` blocks, geometrically, and the free
        // list's to cover every block.
        fn growBlocks(self: *Self, allocator: std.mem.Allocator, total: usize) error{OutOfMemory}!void {
            if (total > self.blocks.capacity) {
                try self.blocks.ensureTotalCapacity(allocator, @max(total, self.blocks.capacity *| 2));
            }
            try self.block_free.ensureTotalCapacity(allocator, self.blocks.capacity);
        }

        /// Takes a free block. Its bytes are empty until `setPayload`.
        pub fn claim(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!u32 {
            if (self.block_free.items.len == 0) try self.ensureFree(allocator, 1);
            return self.block_free.pop().?;
        }

        /// Returns `block` to the pool and frees its bytes.
        pub fn release(self: *Self, allocator: std.mem.Allocator, block: u32) void {
            std.debug.assert(!holdsPooledSlot(&self.blocks.items[block].payload));
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

        /// The stored column split, read in place.
        pub fn payloadConst(self: *const Self, block: u32) *const Payload {
            return &self.blocks.items[block].payload;
        }

        // Whether `payload` names a slot of its owner's `PayloadSlabs`, which only the owner
        // returns. A `Payload` with no `slot: PayloadSlot` field never does.
        fn holdsPooledSlot(held: *const Payload) bool {
            if (comptime !@hasField(Payload, "slot")) return false;
            if (comptime @FieldType(Payload, "slot") != PayloadSlot) return false;
            return !held.slot.isNone();
        }

        // The block pool as ordinal claims: free ids, then fresh ids from the pool's end.
        // The free list's capacity covers every block, so every release fits.
        fn blockIds(self: *const Self) OrdinalClaims {
            return .{
                .free = self.block_free,
                // Block ids stay below `empty_block`.
                .next_id = @intCast(self.blocks.items.len),
                .id_limit = @intCast(@min(self.blocks.capacity, empty_block - 1)),
            };
        }

        /// Makes `claims` ordinal claims fit: grows the block pool's capacity, geometrically,
        /// and the free list's with it. A claimed fresh block lies past `blocks.items.len`,
        /// undefined, until `commitClaims`; the claimer writes it whole through `writeClaimed`
        /// first. The caller counts growth from `blocks.capacity`. A total reaching
        /// `empty_block` fails as `OutOfMemory` before the allocator is asked. An error leaves
        /// the pool's blocks as they were and keeps the capacity grown before it.
        pub fn reserveClaims(self: *Self, allocator: std.mem.Allocator, claims: usize) error{OutOfMemory}!void {
            try self.growBlocks(allocator, try self.blockIds().idsNeeded(claims));
        }

        /// The block claim `ordinal` takes; pure, read on workers.
        pub fn claimedBlock(self: *const Self, ordinal: usize) u32 {
            return self.blockIds().claimedId(ordinal);
        }

        /// Writes claimed `block` whole, holding no bytes and the column split `columns`, and
        /// returns its payload. Distinct blocks are written concurrently.
        pub fn writeClaimed(self: *const Self, block: u32, columns: Payload) *Payload {
            std.debug.assert(block < self.blocks.capacity);
            const held = &self.blocks.items.ptr[block];
            held.* = .{ .payload = columns };
            return &held.payload;
        }

        /// Takes the first `claims` ordinals: pops the free blocks they read and extends the
        /// pool over the fresh ones, which `writeClaimed` has written.
        pub fn commitClaims(self: *Self, claims: usize) void {
            var ids = self.blockIds();
            ids.commitClaims(claims);
            self.block_free.items.len = ids.free.items.len;
            self.blocks.items.len = ids.next_id;
        }

        /// Empties `block`, which holds no bytes, and writes it at release `position` past
        /// the free list's end. Distinct positions and blocks are written concurrently.
        pub fn releaseBlockAt(self: *const Self, position: usize, block: u32) void {
            const held = &self.blocks.items[block];
            std.debug.assert(held.bytes.len == 0);
            held.* = .{};
            self.blockIds().releaseAt(position, block);
        }

        /// Adds the `releases` blocks written by `releaseBlockAt` to the free list.
        pub fn commitReleases(self: *Self, releases: usize) void {
            std.debug.assert(self.block_free.items.len + releases <= self.block_free.capacity);
            self.block_free.items.len += releases;
        }

        pub fn blockBytes(self: *const Self, block: u32) []align(4) u8 {
            return self.blocks.items[block].bytes;
        }

        /// The stored column split. The caller updates `len` and the columns in place; a
        /// reallocation replaces the split through `setPayload`.
        pub fn payloadMut(self: *Self, block: u32) *Payload {
            return &self.blocks.items[block].payload;
        }

        /// `pending` of `level`'s chunk `index`. Only the registry's count workers write it,
        /// one shard per chunk, and the main thread clears it before apply.
        pub fn pending(self: *Self, level: u32, index: usize) *u32 {
            comptime std.debug.assert(with_pending);
            return &self.levels.items[level].pending[index];
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

test "truncating levels releases the dropped levels' blocks, drops their headers, and returns the header storage" {
    const allocator = std.testing.allocator;
    const Directory = ChunkDirectory(struct { len: u32 = 0 }, true);
    var directory: Directory = .{};
    defer directory.deinit(allocator);
    for (0..4) |level| {
        try directory.openLevel(allocator, @intCast(level), 8);
        const block = try directory.claim(allocator);
        directory.setPayload(block, try allocator.alignedAlloc(u8, .@"4", 16), .{ .len = 1 });
        directory.setSlot(@intCast(level), 3, block);
    }
    const kept = directory.slot(0, 3);
    const free_before = directory.block_free.items.len;

    directory.truncateLevels(allocator, 4);
    try std.testing.expectEqual(@as(usize, 4), directory.levelCount());
    directory.truncateLevels(allocator, 1);
    try std.testing.expectEqual(@as(usize, 1), directory.levelCount());
    try std.testing.expectEqual(@as(usize, 1), directory.levels.capacity);
    try std.testing.expectEqual(free_before + 3, directory.block_free.items.len);
    try std.testing.expectEqual(kept, directory.slot(0, 3));
    try std.testing.expectEqual(@as(usize, 0), directory.slotCount(1));

    try directory.openLevel(allocator, 1, 8);
    try std.testing.expectEqual(empty_block, directory.slot(1, 3));
    directory.truncateLevels(allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), directory.levelCount());
    try std.testing.expectEqual(free_before + 4, directory.block_free.items.len);
}

test "emptying a level releases only that level's blocks and keeps its columns, and releasing every block empties every level and returns every block to the pool" {
    const allocator = std.testing.allocator;
    const Directory = ChunkDirectory(struct { len: u32 = 0 }, true);
    var directory: Directory = .{};
    defer directory.deinit(allocator);
    try directory.openLevel(allocator, 0, 8);
    try directory.openLevel(allocator, 1, 8);
    const held = [_]struct { level: u32, slot: usize }{ .{ .level = 0, .slot = 1 }, .{ .level = 0, .slot = 6 }, .{ .level = 1, .slot = 2 } };
    for (held) |entry| {
        const block = try directory.claim(allocator);
        directory.setPayload(block, try allocator.alignedAlloc(u8, .@"4", 16), .{ .len = 1 });
        directory.setSlot(entry.level, entry.slot, block);
        directory.pending(entry.level, entry.slot).* = 3;
    }
    const blocks = directory.blocks.items.len;
    try std.testing.expectEqual(blocks - held.len, directory.block_free.items.len);

    directory.emptyLevel(allocator, 0);
    try std.testing.expectEqual(@as(usize, 8), directory.slotCount(0));
    for (0..8) |slot| {
        try std.testing.expectEqual(empty_block, directory.slot(0, slot));
        try std.testing.expectEqual(@as(u32, 0), directory.pending(0, slot).*);
    }
    try std.testing.expect(directory.slot(1, 2) != empty_block);
    try std.testing.expectEqual(@as(u32, 3), directory.pending(1, 2).*);
    try std.testing.expectEqual(blocks - 1, directory.block_free.items.len);

    directory.releaseAll(allocator);
    for (0..2) |level| {
        try std.testing.expectEqual(@as(usize, 8), directory.slotCount(@intCast(level)));
        for (0..8) |slot| {
            try std.testing.expectEqual(empty_block, directory.slot(@intCast(level), slot));
            try std.testing.expectEqual(@as(u32, 0), directory.pending(@intCast(level), slot).*);
        }
    }
    try std.testing.expectEqual(blocks, directory.block_free.items.len);
    for (directory.blocks.items) |block| try std.testing.expectEqual(@as(usize, 0), block.bytes.len);
}

test "ordinal claims hand out free ids newest first, then new ids, and releases fit without allocating" {
    const allocator = std.testing.allocator;
    var claims: OrdinalClaims = .{};
    defer claims.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 3), try claims.idsNeeded(3));
    try claims.cover(allocator, 3);
    for (0..3) |ordinal| try std.testing.expectEqual(@as(u32, @intCast(ordinal)), claims.claimedId(ordinal));
    claims.commitClaims(3);
    try std.testing.expectEqual(@as(u32, 3), claims.next_id);
    // Two releases written out of position order, then committed together.
    claims.releaseAt(1, 2);
    claims.releaseAt(0, 0);
    claims.commitReleases(2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, claims.free.items);

    // Three claims: the newest free id, the older one, then a fresh id.
    try std.testing.expectEqual(@as(u32, 4), try claims.idsNeeded(3));
    try claims.cover(allocator, 4);
    try std.testing.expectEqual(@as(u32, 2), claims.claimedId(0));
    try std.testing.expectEqual(@as(u32, 0), claims.claimedId(1));
    try std.testing.expectEqual(@as(u32, 3), claims.claimedId(2));
    claims.commitClaims(3);
    try std.testing.expectEqual(@as(usize, 0), claims.free.items.len);
    try std.testing.expectEqual(@as(u32, 4), claims.next_id);

    // Every live id releases into the reserved free list with the allocator failing.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try claims.cover(failing.allocator(), 4);
    for ([_]u32{ 3, 1, 0, 2 }, 0..) |id, position| claims.releaseAt(position, id);
    claims.commitReleases(4);
    try std.testing.expectEqualSlices(u32, &.{ 3, 1, 0, 2 }, claims.free.items);
    try std.testing.expect(!failing.has_induced_failure);

    // A total reaching `no_entry` fails before any storage is asked for.
    claims.next_id = no_entry - 1;
    try std.testing.expectEqual(no_entry - 1, try claims.idsNeeded(4));
    try std.testing.expectError(error.OutOfMemory, claims.idsNeeded(5));
}

test "payload slabs size each request into its smallest class, and a request past the last class fails as out of memory" {
    try std.testing.expectEqual(@as(usize, 64), PayloadSlabs.classBytes(0));
    try std.testing.expectEqual(@as(usize, 80), PayloadSlabs.classBytes(1));
    try std.testing.expectEqual(@as(usize, 128), PayloadSlabs.classBytes(4));
    try std.testing.expectEqual(@as(usize, 160), PayloadSlabs.classBytes(5));
    var previous: usize = 0;
    for (0..max_payload_classes) |class| {
        const bytes = PayloadSlabs.classBytes(@intCast(class));
        try std.testing.expect(bytes > previous and bytes % payload_slot_alignment == 0);
        previous = bytes;
    }
    try std.testing.expect(PayloadSlabs.classBytes(max_payload_classes - 1) >= @as(usize, 1) << 38);
    for (0..4096) |bytes| {
        const class = try PayloadSlabs.classFor(bytes);
        try std.testing.expect(PayloadSlabs.classBytes(class) >= bytes);
        if (class != 0) try std.testing.expect(PayloadSlabs.classBytes(class - 1) < bytes);
    }
    for (0..max_payload_classes) |class| {
        const bytes = PayloadSlabs.classBytes(@intCast(class));
        try std.testing.expectEqual(@as(u8, @intCast(class)), try PayloadSlabs.classFor(bytes));
        if (class + 1 < max_payload_classes) try std.testing.expectEqual(@as(u8, @intCast(class + 1)), try PayloadSlabs.classFor(bytes + 1));
    }
    try std.testing.expectError(error.OutOfMemory, PayloadSlabs.classFor(PayloadSlabs.classBytes(max_payload_classes - 1) + 1));
}

test "payload slabs map every id to a disjoint slot of its class, and a reserve grows by doubling slabs" {
    const allocator = std.testing.allocator;
    var slabs: PayloadSlabs = .{};
    defer slabs.deinit(allocator);
    // Class 0 slots are 64 bytes: 64 slots in the first slab, then 128, then 256.
    const class: u8 = 0;
    try slabs.reserve(allocator, class, 64);
    try std.testing.expectEqual(@as(usize, 1), slabs.slab_count);
    try slabs.reserve(allocator, class, 65);
    try std.testing.expectEqual(@as(usize, 2), slabs.slab_count);
    try slabs.reserve(allocator, class, 300);
    try std.testing.expectEqual(@as(usize, 3), slabs.slab_count);
    try std.testing.expectEqual(@as(usize, 256 * 64), slabs.classes[class].slabs.items[2].len);
    // Within its storage, a reserve adds nothing.
    try slabs.reserve(allocator, class, 448);
    try std.testing.expectEqual(@as(usize, 3), slabs.slab_count);
    // Each id's bytes are its own slot: stamp every slot, then read every stamp back.
    for (0..448) |id| {
        const bytes = slabs.bytesOf(.{ .class = class, .id = @intCast(id) });
        try std.testing.expectEqual(@as(usize, 64), bytes.len);
        try std.testing.expect(std.mem.isAligned(@intFromPtr(bytes.ptr), payload_slot_alignment));
        std.mem.writeInt(u32, bytes[0..4], @intCast(id), .little);
        std.mem.writeInt(u32, bytes[60..64], @intCast(id), .little);
    }
    for (0..448) |id| {
        const bytes = slabs.bytesOf(.{ .class = class, .id = @intCast(id) });
        try std.testing.expectEqual(@as(u32, @intCast(id)), std.mem.readInt(u32, bytes[0..4], .little));
        try std.testing.expectEqual(@as(u32, @intCast(id)), std.mem.readInt(u32, bytes[60..64], .little));
    }
    // A class past the first slab's bytes holds one slot in its first slab.
    const large: u8 = try PayloadSlabs.classFor(5000);
    try slabs.reserve(allocator, large, 2);
    try std.testing.expectEqual(@as(usize, 5), slabs.slab_count);
    const second = slabs.bytesOf(.{ .class = large, .id = 1 });
    try std.testing.expectEqual(PayloadSlabs.classBytes(large), second.len);
    try std.testing.expect(second.ptr != slabs.bytesOf(.{ .class = large, .id = 0 }).ptr);
}

test "a reserved slab class claims and releases without allocating (FailingAllocator)" {
    const allocator = std.testing.allocator;
    var slabs: PayloadSlabs = .{};
    defer slabs.deinit(allocator);
    const class: u8 = 3;
    try slabs.reserve(allocator, class, 40);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    // The first call claims 40 fresh slots; the next releases 25 and claims 30 from the
    // released and the fresh ones, all inside the reserve.
    for (0..40) |ordinal| try std.testing.expectEqual(@as(u32, @intCast(ordinal)), slabs.claimedId(class, ordinal));
    slabs.commitClaims(class, 40);
    try slabs.reserve(failing.allocator(), class, 30);
    for (0..30) |ordinal| _ = slabs.bytesOf(.{ .class = class, .id = slabs.claimedId(class, ordinal) });
    slabs.commitClaims(class, 30);
    for (0..25) |position| slabs.releaseAt(.{ .class = class, .id = @intCast(position) }, position);
    slabs.commitReleases(class, 25);
    try slabs.reserve(failing.allocator(), class, 25);
    try std.testing.expectEqual(@as(u32, 24), slabs.claimedId(class, 0));
    slabs.commitClaims(class, 25);
    try std.testing.expect(!failing.has_induced_failure);
}

test "a payload class reset hands out ids from zero and keeps its slabs" {
    const allocator = std.testing.allocator;
    var slabs: PayloadSlabs = .{};
    defer slabs.deinit(allocator);
    const class: u8 = 0;
    const other: u8 = 2;
    try slabs.reserve(allocator, class, 100);
    try slabs.reserve(allocator, other, 3);
    slabs.commitClaims(class, 100);
    slabs.commitClaims(other, 3);
    for (0..10) |position| slabs.releaseAt(.{ .class = class, .id = @intCast(position * 7) }, position);
    slabs.commitReleases(class, 10);
    const held = slabs.slab_count;
    const limit = slabs.classes[class].claims.id_limit;

    slabs.resetClass(class);
    try std.testing.expectEqual(held, slabs.slab_count);
    try std.testing.expectEqual(limit, slabs.classes[class].claims.id_limit);
    try std.testing.expectEqual(@as(usize, 0), slabs.classes[class].claims.free.items.len);
    // The same claims fit the kept slabs: no allocation, ids from zero up.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try slabs.reserve(failing.allocator(), class, 100);
    for (0..100) |ordinal| try std.testing.expectEqual(@as(u32, @intCast(ordinal)), slabs.claimedId(class, ordinal));
    slabs.commitClaims(class, 100);
    // Every id releases into the kept free list without allocating.
    for (0..100) |position| slabs.releaseAt(.{ .class = class, .id = @intCast(position) }, position);
    slabs.commitReleases(class, 100);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(held, slabs.slab_count);
    // The other class keeps its claims.
    try std.testing.expectEqual(@as(u32, 3), slabs.classes[other].claims.next_id);
}

test "a directory's ordinal claims extend the block pool once and releases return blocks to it" {
    const allocator = std.testing.allocator;
    const Directory = ChunkDirectory(struct { len: u32 = 0 }, false);
    var directory: Directory = .{};
    defer directory.deinit(allocator);
    try directory.openLevel(allocator, 0, 8);
    try directory.reserveClaims(allocator, 3);
    try std.testing.expect(directory.blocks.capacity >= 3);
    try std.testing.expectEqual(@as(usize, 0), directory.blocks.items.len);
    for (0..3) |ordinal| {
        const block = directory.claimedBlock(ordinal);
        try std.testing.expectEqual(@as(u32, @intCast(ordinal)), block);
        directory.writeClaimed(block, .{ .len = @intCast(ordinal + 1) }).len += 10;
    }
    directory.commitClaims(3);
    try std.testing.expectEqual(@as(usize, 3), directory.blocks.items.len);
    for (0..3) |block| {
        try std.testing.expectEqual(@as(u32, @intCast(block + 11)), directory.payloadConst(@intCast(block)).len);
        directory.setSlot(0, block, @intCast(block));
    }
    // Releasing two blocks out of position order empties them and pools them.
    directory.setSlot(0, 0, empty_block);
    directory.setSlot(0, 2, empty_block);
    directory.releaseBlockAt(1, 0);
    directory.releaseBlockAt(0, 2);
    directory.commitReleases(2);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0 }, directory.block_free.items);
    try std.testing.expectEqual(@as(u32, 0), directory.payloadConst(2).len);
    // The next call claims the pooled blocks, newest first, then one fresh block, without
    // allocating.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try directory.reserveClaims(failing.allocator(), 3);
    try std.testing.expectEqual(@as(u32, 0), directory.claimedBlock(0));
    try std.testing.expectEqual(@as(u32, 2), directory.claimedBlock(1));
    try std.testing.expectEqual(@as(u32, 3), directory.claimedBlock(2));
    for (0..3) |ordinal| _ = directory.writeClaimed(directory.claimedBlock(ordinal), .{ .len = 1 });
    directory.commitClaims(3);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 4), directory.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), directory.block_free.items.len);
    for (0..4) |block| directory.setSlot(0, block, @intCast(block));
}
