// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-key lists of owner ids: an open-addressed `u64 key -> {head, tail, count}` table over
//! a pool of doubly linked entries, each list ordered by its entries' `order`, plus one
//! chain per owner of the entries it holds. Keys are any u64 whose tier bits (62-63) are not
//! both set; `chunkKey` builds the (level, chunk) keys, `superchunkKey`, `levelKey`, and
//! `world_key` the coarser tiers. Each present key also holds one u32
//! value for its owner (`no_value` until set); a key holding a value is never dropped.
//! Lists change in batches: between `beginBatch` and `commitBatch` the owner unlinks and
//! staged inserts cost O(1) each on the caller's thread, and `commitBatch` places every
//! staged entry in its list's order, the sorted placement threaded per key. Outside a batch,
//! `add` appends at a list's tail and `removeOwner`/`renameOwner` touch one owner's entries.
//! Only the reserves allocate. Reads never mutate, so workers read lists while nothing
//! writes.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../../core/logging.zig");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;

/// End of a list or owner chain, and "no entry" from a lookup.
pub const no_entry: u32 = std.math.maxInt(u32);
/// A key's value when none is set, and the value of an absent key.
pub const no_value: u32 = std.math.maxInt(u32);
// No valid key sets both tier bits (62-63), so all-ones marks an empty table slot.
const empty_key: u64 = std.math.maxInt(u64);
const min_slot_count: usize = 16;
// `slot_touch` value of a slot no batch has touched since the table was built.
const untouched: u32 = std.math.maxInt(u32);

/// The key of `chunk` on `level`: tier 0 (bits 62-63), level in bits 32-47, the
/// level-local chunk index in bits 0-31.
pub fn chunkKey(level: u16, chunk: u32) u64 {
    return (@as(u64, level) << 32) | chunk;
}

/// Chunks along each side of a superchunk.
pub const superchunk_edge: u32 = 8;
const tier_one: u64 = 1 << 62;
const tier_two: u64 = 1 << 63;

/// The key of `superchunk` (a level-local index of `superchunk_edge`-chunk blocks) on
/// `level`: tier 1, level in bits 32-47, the superchunk index in bits 0-31.
pub fn superchunkKey(level: u16, superchunk: u32) u64 {
    return tier_one | (@as(u64, level) << 32) | superchunk;
}

/// The key of all of `level`: tier 2, level in bits 32-47, low bits 0.
pub fn levelKey(level: u16) u64 {
    return tier_two | (@as(u64, level) << 32);
}

/// The key of every level: tier 2, low bits 1.
pub const world_key: u64 = tier_two | 1;

const Entry = struct {
    key: u64,
    owner: u32,
    order: u32,
    prev: u32,
    next: u32,
    owner_next: u32,
};

// One staged insert, chained per key through `next`.
const Claim = struct {
    entry: u32,
    next: u32,
};

// A key with staged inserts this batch: its table slot, its claim chain, and its window
// of `count` splice records at `offset`.
const TouchedKey = struct {
    slot: u32,
    head_claim: u32,
    count: u32,
    offset: u32,
};

/// A staged entry and the entry it links after (`no_entry`: the list head).
const SpliceRecord = struct {
    entry: u32,
    after: u32,
};

/// Splice ranges cover a multiple of this many keys (bounding the range count, and so the
/// window padding), and each range's record window starts on a cache line, so no two
/// ranges write one line.
pub const splice_range_alignment_items: usize = 8;
const thread_shared_record_alignment: usize = 64;
const SpliceRecordList = std.ArrayListAligned(SpliceRecord, .fromByteUnits(thread_shared_record_alignment));

comptime {
    std.debug.assert(@sizeOf(SpliceRecord) * splice_range_alignment_items == thread_shared_record_alignment);
}

/// The splice stage's threading: a thread system and the stage's own tuner and range
/// controls.
pub const SpliceThreads = struct {
    thread_system: *ThreadSystem,
    tuner: *AdaptiveWorkTuner,
    adaptive: bool,
    items_per_range: ?usize,
};

pub const ChunkListMap = struct {
    /// Bytes one pooled entry takes: its key, owner, order, and three links, and its free
    /// id.
    pub const bytes_per_entry: usize = @sizeOf(u64) + 5 * @sizeOf(u32) + @sizeOf(u32);
    /// Bytes one table slot takes: its key, head, tail, value, count, and batch touch.
    pub const bytes_per_key_slot: usize = @sizeOf(u64) + 5 * @sizeOf(u32);

    allocator: std.mem.Allocator,
    /// What the lists hold, naming this map in its growth log.
    name: []const u8,
    // Table slots, a power of two at load <= 1/2.
    slot_keys: []u64 = &.{},
    slot_heads: []u32 = &.{},
    slot_tails: []u32 = &.{},
    // Per slot, its key's value (`no_value` when unset); moves with the key.
    slot_values: []u32 = &.{},
    // Per slot, the entries in its key's list; moves with the key.
    slot_counts: []u32 = &.{},
    // Per slot, its `touched` index while touched in the current batch; valid only when
    // `touched[slot_touch[slot]].slot == slot`, so it is never cleared.
    slot_touch: []u32 = &.{},
    live_keys: usize = 0,
    entries: std.MultiArrayList(Entry) = .{},
    // Released entry ids; capacity always covers every pooled entry.
    entry_free: std.ArrayList(u32) = .empty,
    // Per owner id, the newest entry it holds or `no_entry`.
    owner_heads: std.ArrayList(u32) = .empty,
    // Fewer owner heads, allocated by `prepareTruncate` and installed by `installTruncate`;
    // the heads they replace wait in `retired_owner_heads` for `releaseTruncated`.
    owner_heads_replacement: ?std.ArrayList(u32) = null,
    retired_owner_heads: std.ArrayList(u32) = .empty,
    // Column views refreshed whenever the entry pool grows.
    entry_key: []u64 = &.{},
    entry_owner: []u32 = &.{},
    entry_order: []u32 = &.{},
    entry_prev: []u32 = &.{},
    entry_next: []u32 = &.{},
    entry_owner_next: []u32 = &.{},
    // Batch scratch, high-water, sized by `reserveBatch`: staged inserts in claim order,
    // touched keys in first-touch order, the splice record windows, and keys whose list
    // emptied (dropped at commit when still empty).
    claims: std.ArrayList(Claim) = .empty,
    touched: std.ArrayList(TouchedKey) = .empty,
    splice_records: SpliceRecordList = .empty,
    emptied_keys: std.ArrayList(u64) = .empty,
    in_batch: bool = false,
    /// Telemetry: table, entry-pool, and batch-scratch growths, logged once.
    grows: u64 = 0,
    growth_logged: bool = false,

    /// `name` outlives the map.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) ChunkListMap {
        return .{ .allocator = allocator, .name = name };
    }

    pub fn deinit(self: *ChunkListMap) void {
        self.emptied_keys.deinit(self.allocator);
        self.splice_records.deinit(self.allocator);
        self.touched.deinit(self.allocator);
        self.claims.deinit(self.allocator);
        self.retired_owner_heads.deinit(self.allocator);
        if (self.owner_heads_replacement) |*replacement| replacement.deinit(self.allocator);
        self.owner_heads.deinit(self.allocator);
        self.entry_free.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.slot_touch);
        self.allocator.free(self.slot_counts);
        self.allocator.free(self.slot_values);
        self.allocator.free(self.slot_tails);
        self.allocator.free(self.slot_heads);
        self.allocator.free(self.slot_keys);
        self.* = undefined;
    }

    fn refreshColumns(self: *ChunkListMap) void {
        const columns = self.entries.slice();
        self.entry_key = columns.items(.key);
        self.entry_owner = columns.items(.owner);
        self.entry_order = columns.items(.order);
        self.entry_prev = columns.items(.prev);
        self.entry_next = columns.items(.next);
        self.entry_owner_next = columns.items(.owner_next);
    }

    fn countGrowth(self: *ChunkListMap) void {
        self.grows += 1;
        if (self.growth_logged) return;
        self.growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test)
            logging.game.info("{s} storage grew ({} growths so far)", .{ self.name, self.grows });
    }

    /// Guarantees `new_keys` more keys, `new_entries` more inserts, and owner ids below
    /// `owner_count` without allocating. Growth is geometric and counted. On error nothing
    /// observable changes. Not during a batch.
    pub fn reserve(self: *ChunkListMap, new_keys: usize, new_entries: usize, owner_count: usize) error{OutOfMemory}!void {
        std.debug.assert(!self.in_batch);
        try self.reserveSlots(self.live_keys + new_keys);
        try self.reserveEntries(new_entries);
        if (self.owner_heads.items.len < owner_count) {
            try self.owner_heads.ensureTotalCapacity(self.allocator, owner_count);
            self.owner_heads.appendNTimesAssumeCapacity(no_entry, owner_count - self.owner_heads.items.len);
        }
    }

    /// Guarantees the next batch's scratch for `inserts` staged inserts and `removals`
    /// unlinked entries without allocating. Geometric and counted. On error nothing
    /// observable changes. Not during a batch.
    pub fn reserveBatch(self: *ChunkListMap, inserts: usize, removals: usize) error{OutOfMemory}!void {
        std.debug.assert(!self.in_batch);
        // Each range's window starts on a cache line: at most `alignment - 1` padding
        // records per range, and a batch over at most `inserts` keys has at most
        // `maxRangeCount(inserts)` ranges.
        const records = inserts + (splice_range_alignment_items - 1) * maxRangeCount(inserts, splice_range_alignment_items);
        if (self.claims.capacity < inserts or self.touched.capacity < inserts or self.splice_records.capacity < records or self.emptied_keys.capacity < removals) {
            try self.claims.ensureTotalCapacity(self.allocator, inserts);
            try self.touched.ensureTotalCapacity(self.allocator, inserts);
            try self.splice_records.ensureTotalCapacity(self.allocator, records);
            // A key empties at most once per batch, and only through a removal.
            try self.emptied_keys.ensureTotalCapacity(self.allocator, removals);
            self.countGrowth();
        }
    }

    // Grows the table so `key_count` keys sit at load <= 1/2, rehashing the live keys into
    // fresh arrays; the old table stays intact until the new one is filled.
    fn reserveSlots(self: *ChunkListMap, key_count: usize) error{OutOfMemory}!void {
        if (key_count * 2 <= self.slot_keys.len) return;
        const slot_count = @max(min_slot_count, std.math.ceilPowerOfTwoAssert(usize, key_count * 2), self.slot_keys.len * 2);
        const keys = try self.allocator.alloc(u64, slot_count);
        errdefer self.allocator.free(keys);
        const heads = try self.allocator.alloc(u32, slot_count);
        errdefer self.allocator.free(heads);
        const tails = try self.allocator.alloc(u32, slot_count);
        errdefer self.allocator.free(tails);
        const values = try self.allocator.alloc(u32, slot_count);
        errdefer self.allocator.free(values);
        const counts = try self.allocator.alloc(u32, slot_count);
        errdefer self.allocator.free(counts);
        const touch = try self.allocator.alloc(u32, slot_count);
        @memset(keys, empty_key);
        @memset(touch, untouched);
        const old_keys = self.slot_keys;
        const old_heads = self.slot_heads;
        const old_tails = self.slot_tails;
        const old_values = self.slot_values;
        const old_counts = self.slot_counts;
        const old_touch = self.slot_touch;
        self.slot_keys = keys;
        self.slot_heads = heads;
        self.slot_tails = tails;
        self.slot_values = values;
        self.slot_counts = counts;
        self.slot_touch = touch;
        for (old_keys, old_heads, old_tails, old_values, old_counts) |key, old_head, old_tail, old_value, old_count| {
            if (key == empty_key) continue;
            const slot = self.emptySlotFor(key);
            self.slot_keys[slot] = key;
            self.slot_heads[slot] = old_head;
            self.slot_tails[slot] = old_tail;
            self.slot_values[slot] = old_value;
            self.slot_counts[slot] = old_count;
        }
        self.allocator.free(old_touch);
        self.allocator.free(old_counts);
        self.allocator.free(old_values);
        self.allocator.free(old_tails);
        self.allocator.free(old_heads);
        self.allocator.free(old_keys);
        self.countGrowth();
    }

    fn reserveEntries(self: *ChunkListMap, needed: usize) error{OutOfMemory}!void {
        if (self.entry_free.items.len >= needed) return;
        const added = needed - self.entry_free.items.len;
        const total = self.entries.len + added;
        // Entry ids stay below `no_entry`: at 28 B per entry, 2^32 entries are 112 GiB, so
        // the allocator fails long before an id could reach it.
        std.debug.assert(total < no_entry);
        if (total > self.entries.capacity) {
            try self.entries.ensureTotalCapacity(self.allocator, @max(total, self.entries.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            self.countGrowth();
        }
        try self.entry_free.ensureTotalCapacity(self.allocator, self.entries.capacity);
        // Pushed in descending id order so pops hand out ascending ids.
        const first: u32 = @intCast(self.entries.len);
        for (0..added) |_| self.entries.appendAssumeCapacity(undefined);
        var id: u32 = @intCast(self.entries.len);
        while (id > first) {
            id -= 1;
            self.entry_free.appendAssumeCapacity(id);
        }
        self.refreshColumns();
    }

    fn mask(self: *const ChunkListMap) usize {
        return self.slot_keys.len - 1;
    }

    fn homeShift(self: *const ChunkListMap) u6 {
        return @intCast(@as(u7, 64) - std.math.log2_int(usize, self.slot_keys.len));
    }

    fn home(self: *const ChunkListMap, key: u64) usize {
        return homeSlot(key, self.homeShift());
    }

    // The slot holding `key`, or null. Never writes.
    fn findSlot(self: *const ChunkListMap, key: u64) ?usize {
        if (self.slot_keys.len == 0) return null;
        return probeSlot(self.slot_keys, self.homeShift(), key);
    }

    // The first empty slot on `key`'s probe path; the table has room by its reserve.
    fn emptySlotFor(self: *const ChunkListMap, key: u64) usize {
        var slot = self.home(key);
        while (self.slot_keys[slot] != empty_key) slot = (slot + 1) & self.mask();
        return slot;
    }

    // `key`'s slot, added with an empty list when absent; the reserve kept room for it.
    fn slotFor(self: *ChunkListMap, key: u64) usize {
        if (self.findSlot(key)) |slot| return slot;
        std.debug.assert((self.live_keys + 1) * 2 <= self.slot_keys.len);
        const slot = self.emptySlotFor(key);
        self.slot_keys[slot] = key;
        self.slot_heads[slot] = no_entry;
        self.slot_tails[slot] = no_entry;
        self.slot_values[slot] = no_value;
        self.slot_counts[slot] = 0;
        self.slot_touch[slot] = untouched;
        self.live_keys += 1;
        return slot;
    }

    /// The first entry of `key`'s list, or `no_entry`. Never mutates.
    pub fn head(self: *const ChunkListMap, key: u64) u32 {
        const slot = self.findSlot(key) orelse return no_entry;
        return self.slot_heads[slot];
    }

    /// `key`'s value, or `no_value` when it has none or is absent. O(1) expected; never
    /// mutates.
    pub fn value(self: *const ChunkListMap, key: u64) u32 {
        const slot = self.findSlot(key) orelse return no_value;
        return self.slot_values[slot];
    }

    /// The entries in `key`'s list; 0 when absent. O(1) expected; never mutates.
    pub fn keyCount(self: *const ChunkListMap, key: u64) u32 {
        const slot = self.findSlot(key) orelse return 0;
        return self.slot_counts[slot];
    }

    /// Sets present `key`'s value; `no_value` clears it. A key whose list a `commitBatch`
    /// leaves empty must hold `no_value` by then. Valid in or out of a batch; O(1)
    /// expected; allocates nothing.
    pub fn setValue(self: *ChunkListMap, key: u64, key_value: u32) void {
        const slot = self.findSlot(key).?;
        self.slot_values[slot] = key_value;
    }

    /// Walks `key`'s owners in list order. Never mutates; valid until the next batch or
    /// append.
    pub fn iterator(self: *const ChunkListMap, key: u64) Iterator {
        return .{ .owners = self.entry_owner, .next_entries = self.entry_next, .entry = self.head(key) };
    }

    /// The table and entry columns for lookups and list walks without the map: O(1) to
    /// take, safe for concurrent reads, valid until the next reserve, batch, or append.
    pub fn reader(self: *const ChunkListMap) Reader {
        if (self.slot_keys.len == 0) return .{};
        return .{
            .keys = self.slot_keys,
            .heads = self.slot_heads,
            .values = self.slot_values,
            .counts = self.slot_counts,
            .owners = self.entry_owner,
            .orders = self.entry_order,
            .next_entries = self.entry_next,
            .shift = self.homeShift(),
        };
    }

    pub const Reader = struct {
        keys: []const u64 = &.{},
        heads: []const u32 = &.{},
        values: []const u32 = &.{},
        counts: []const u32 = &.{},
        /// Per entry, its owner id, its order, and the next entry of its list (`no_entry` at
        /// the end).
        owners: []const u32 = &.{},
        orders: []const u32 = &.{},
        next_entries: []const u32 = &.{},
        shift: u6 = 0,

        /// The first entry of `key`'s list, or `no_entry`.
        pub fn head(self: Reader, key: u64) u32 {
            if (self.keys.len == 0) return no_entry;
            const slot = probeSlot(self.keys, self.shift, key) orelse return no_entry;
            return self.heads[slot];
        }

        /// The entries in `key`'s list; 0 when absent.
        pub fn keyCount(self: Reader, key: u64) u32 {
            if (self.keys.len == 0) return 0;
            const slot = probeSlot(self.keys, self.shift, key) orelse return 0;
            return self.counts[slot];
        }

        /// `key`'s value, or `no_value` when it has none or is absent.
        pub fn value(self: Reader, key: u64) u32 {
            if (self.keys.len == 0) return no_value;
            const slot = probeSlot(self.keys, self.shift, key) orelse return no_value;
            return self.values[slot];
        }
    };

    pub const Iterator = struct {
        owners: []const u32,
        next_entries: []const u32,
        entry: u32,

        pub fn next(self: *Iterator) ?u32 {
            if (self.entry == no_entry) return null;
            const entry = self.entry;
            self.entry = self.next_entries[entry];
            return self.owners[entry];
        }
    };

    // Takes a free entry for `owner` in `key` at `order`, at the head of the owner's chain.
    fn claimEntry(self: *ChunkListMap, owner: u32, key: u64, order: u32) u32 {
        std.debug.assert(key >> 62 != 3);
        std.debug.assert(owner < self.owner_heads.items.len);
        // The reserve grew the free list to cover this insert.
        std.debug.assert(self.entry_free.items.len != 0);
        const entry = self.entry_free.pop().?;
        self.entry_key[entry] = key;
        self.entry_owner[entry] = owner;
        self.entry_order[entry] = order;
        self.entry_owner_next[entry] = self.owner_heads.items[owner];
        self.owner_heads.items[owner] = entry;
        return entry;
    }

    /// Appends `owner` at the tail of `key`'s list; `order` must be at least the tail's.
    /// O(1). Requires a prior `reserve` covering the key, the entry, and the owner id. Not
    /// during a batch.
    pub fn appendTail(self: *ChunkListMap, owner: u32, key: u64, order: u32) void {
        std.debug.assert(!self.in_batch);
        const entry = self.claimEntry(owner, key, order);
        const slot = self.slotFor(key);
        const tail = self.slot_tails[slot];
        std.debug.assert(tail == no_entry or self.entry_order[tail] <= order);
        self.linkAfter(slot, entry, tail);
    }

    /// Appends `owner` at the tail of `key`'s list at `order`, after every entry already
    /// listed whatever their order: lists hold their adds in call order, an owner's repeats
    /// included. O(1). Requires a prior `reserve` covering the key, the entry, and the owner
    /// id. Not during a batch.
    pub fn add(self: *ChunkListMap, owner: u32, key: u64, order: u32) void {
        std.debug.assert(!self.in_batch);
        const entry = self.claimEntry(owner, key, order);
        const slot = self.slotFor(key);
        self.linkAfter(slot, entry, self.slot_tails[slot]);
    }

    /// `add` for each of `records` (any slice of values with `owner`, `key`, and `order`
    /// fields), in order. Records of one key in a row probe the table once: an insert never
    /// moves another key's slot. Requires a prior `reserve` covering the keys, the entries,
    /// and the owner ids. Not during a batch.
    pub fn addAll(self: *ChunkListMap, records: anytype) void {
        std.debug.assert(!self.in_batch);
        std.debug.assert(self.entry_free.items.len >= records.len);
        var slot_key: u64 = empty_key;
        var slot: usize = 0;
        for (records) |record| {
            if (record.key != slot_key) {
                slot = self.slotFor(record.key);
                slot_key = record.key;
            }
            const entry = self.claimEntry(record.owner, record.key, record.order);
            self.linkAfter(slot, entry, self.slot_tails[slot]);
        }
    }

    /// Whether `owner` holds an entry. O(1).
    pub inline fn holdsOwner(self: *const ChunkListMap, owner: u32) bool {
        return owner < self.owner_heads.items.len and self.owner_heads.items[owner] != no_entry;
    }

    /// Unlinks and frees every entry `owner` holds, dropping each key whose list empties
    /// (a key holding a value stays). Returns the entries freed. O(the owner's entries);
    /// allocates nothing. Not during a batch.
    pub fn removeOwner(self: *ChunkListMap, owner: u32) usize {
        std.debug.assert(!self.in_batch);
        if (owner >= self.owner_heads.items.len) return 0;
        var removed: usize = 0;
        var entry = self.owner_heads.items[owner];
        while (entry != no_entry) : (removed += 1) {
            const owner_next = self.entry_owner_next[entry];
            // An entry is always in its key's list, so the key has a slot.
            const slot = self.findSlot(self.entry_key[entry]).?;
            self.unlinkFromSlot(slot, entry);
            if (self.slot_heads[slot] == no_entry and self.slot_values[slot] == no_value) self.removeSlot(slot);
            std.debug.assert(self.entry_free.items.len < self.entry_free.capacity);
            self.entry_free.appendAssumeCapacity(entry);
            entry = owner_next;
        }
        self.owner_heads.items[owner] = no_entry;
        return removed;
    }

    /// Moves every entry of owner `old` to owner `new`, which must hold none; lists keep
    /// their order. O(the owner's entries); allocates nothing. Not during a batch.
    pub fn renameOwner(self: *ChunkListMap, old: u32, new: u32) void {
        std.debug.assert(!self.in_batch);
        std.debug.assert(new < self.owner_heads.items.len);
        std.debug.assert(self.owner_heads.items[new] == no_entry);
        if (old >= self.owner_heads.items.len) return;
        var entry = self.owner_heads.items[old];
        while (entry != no_entry) : (entry = self.entry_owner_next[entry]) self.entry_owner[entry] = new;
        self.owner_heads.items[new] = self.owner_heads.items[old];
        self.owner_heads.items[old] = no_entry;
    }

    /// Allocates the storage of `count` owner heads for a later `installTruncate`, replacing
    /// any earlier unused one. On error nothing changes.
    pub fn prepareTruncate(self: *ChunkListMap, count: usize) error{OutOfMemory}!void {
        var replacement: std.ArrayList(u32) = .empty;
        try replacement.ensureTotalCapacityPrecise(self.allocator, count);
        self.abortTruncate();
        self.owner_heads_replacement = replacement;
    }

    /// Drops a prepared truncation's storage.
    pub fn abortTruncate(self: *ChunkListMap) void {
        if (self.owner_heads_replacement) |*replacement| replacement.deinit(self.allocator);
        self.owner_heads_replacement = null;
    }

    /// Installs the prepared owner heads: the heads below its count move into it, and every
    /// head at or past it must hold no entry. The replaced storage waits for
    /// `releaseTruncated`. Lookups are untouched. O(count) copy; allocates and frees nothing,
    /// so a flush runs it with the shard's other work. Without a prepared truncation it does
    /// nothing. Not during a batch.
    pub fn installTruncate(self: *ChunkListMap) void {
        std.debug.assert(!self.in_batch);
        var replacement = self.owner_heads_replacement orelse return;
        const count = @min(replacement.capacity, self.owner_heads.items.len);
        if (std.debug.runtime_safety) {
            for (self.owner_heads.items[count..]) |owner_head| std.debug.assert(owner_head == no_entry);
        }
        replacement.appendSliceAssumeCapacity(self.owner_heads.items[0..count]);
        std.debug.assert(self.retired_owner_heads.capacity == 0);
        self.retired_owner_heads = self.owner_heads;
        self.owner_heads = replacement;
        self.owner_heads_replacement = null;
    }

    /// Frees the owner heads an `installTruncate` replaced. Main thread.
    pub fn releaseTruncated(self: *ChunkListMap) void {
        self.retired_owner_heads.deinit(self.allocator);
        self.retired_owner_heads = .empty;
    }

    /// Empties every list and drops every key, keeping storage and owner heads (now empty).
    /// O(slots + entries + owners). Not during a batch.
    pub fn clear(self: *ChunkListMap) void {
        std.debug.assert(!self.in_batch);
        @memset(self.slot_keys, empty_key);
        @memset(self.slot_touch, untouched);
        self.live_keys = 0;
        @memset(self.owner_heads.items, no_entry);
        // Every pooled entry is free again, popped in ascending id order; ids stay below
        // `no_entry` by the entry reserve.
        self.entry_free.clearRetainingCapacity();
        var id: u32 = @intCast(self.entries.len);
        while (id > 0) {
            id -= 1;
            self.entry_free.appendAssumeCapacity(id);
        }
    }

    /// Opens a batch; requires `reserveBatch` covering its inserts and removals.
    pub fn beginBatch(self: *ChunkListMap) void {
        std.debug.assert(!self.in_batch);
        self.claims.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        self.splice_records.clearRetainingCapacity();
        self.emptied_keys.clearRetainingCapacity();
        self.in_batch = true;
    }

    /// Unlinks and frees every entry `owner` holds whose key `keep.contains(key)` rejects
    /// (`keep` is any value with `fn contains(self, u64) bool`). A key whose list empties
    /// keeps its slot until `commitBatch`. O(the owner's entries); allocates nothing.
    pub fn unlinkOwnerOutside(self: *ChunkListMap, owner: u32, keep: anytype) void {
        std.debug.assert(self.in_batch);
        if (owner >= self.owner_heads.items.len) return;
        var kept_head: u32 = no_entry;
        var kept_tail: u32 = no_entry;
        var entry = self.owner_heads.items[owner];
        while (entry != no_entry) {
            const owner_next = self.entry_owner_next[entry];
            if (keep.contains(self.entry_key[entry])) {
                // Kept entries keep their chain order.
                self.entry_owner_next[entry] = no_entry;
                if (kept_tail == no_entry) kept_head = entry else self.entry_owner_next[kept_tail] = entry;
                kept_tail = entry;
            } else {
                self.unlink(entry);
                std.debug.assert(self.entry_free.items.len < self.entry_free.capacity);
                self.entry_free.appendAssumeCapacity(entry);
            }
            entry = owner_next;
        }
        self.owner_heads.items[owner] = kept_head;
    }

    /// Stages `owner` into `key`'s list at `order`, linked at `commitBatch` after every
    /// entry of lower or equal order. O(1); allocates nothing. Requires a `reserve`
    /// covering the key, the entry, and the owner id, and a `reserveBatch` covering it.
    pub fn stageInsert(self: *ChunkListMap, owner: u32, key: u64, order: u32) void {
        std.debug.assert(self.in_batch);
        const entry = self.claimEntry(owner, key, order);
        const slot = self.slotFor(key);
        std.debug.assert(self.claims.items.len < self.claims.capacity);
        const claim: u32 = @intCast(self.claims.items.len);
        const touch = self.slot_touch[slot];
        if (touch < self.touched.items.len and self.touched.items[touch].slot == slot) {
            const touched = &self.touched.items[touch];
            self.claims.appendAssumeCapacity(.{ .entry = entry, .next = touched.head_claim });
            touched.head_claim = claim;
            touched.count += 1;
        } else {
            std.debug.assert(self.touched.items.len < self.touched.capacity);
            self.slot_touch[slot] = @intCast(self.touched.items.len);
            self.claims.appendAssumeCapacity(.{ .entry = entry, .next = no_entry });
            self.touched.appendAssumeCapacity(.{ .slot = @intCast(slot), .head_claim = claim, .count = 1, .offset = 0 });
        }
    }

    /// Closes the batch: places every staged entry in its list's order, then drops each
    /// key whose list emptied and stayed empty. Per touched key, the sorted placement (a
    /// sort of its k staged entries, skipped when they were staged in ascending or
    /// descending order, and one walk of its list, or O(k) when they all follow its tail)
    /// runs in the splice stage, threaded under `threads`; the main thread sizes
    /// the record windows and links, O(1) per key and per entry. Lists come out the same
    /// for any partition. Allocates nothing. Returns the splice stage's batch shape.
    pub fn commitBatch(self: *ChunkListMap, threads: ?SpliceThreads) BatchStats {
        std.debug.assert(self.in_batch);
        var batch = BatchStats{};
        const key_count = self.touched.items.len;
        if (key_count != 0) {
            const selection = if (threads) |stage| stage.thread_system.selectBatchProfile(stage.tuner, .{
                .item_count = key_count,
                .items_per_range = stage.items_per_range,
                .range_alignment_items = splice_range_alignment_items,
                .adaptive = stage.adaptive,
            }) else null;
            // Inline is one range over every key.
            const range_size = if (selection) |selected| selected.items_per_range else key_count;
            // Each range's window starts on a cache line.
            var record_count: usize = 0;
            for (self.touched.items, 0..) |*touched, index| {
                if (index % range_size == 0) record_count = std.mem.alignForward(usize, record_count, splice_range_alignment_items);
                touched.offset = @intCast(record_count);
                record_count += touched.count;
            }
            std.debug.assert(record_count <= self.splice_records.capacity);
            self.splice_records.items.len = record_count;
            var job = SpliceJob{
                .map = self,
                .items_per_range = range_size,
                .range_count = (key_count + range_size - 1) / range_size,
                .records = self.splice_records.items,
            };
            if (threads) |stage| {
                const selected = selection.?;
                batch = stage.thread_system.parallelForWithOptions(key_count, &job, spliceJob, .{
                    .items_per_range = stage.items_per_range,
                    .range_alignment_items = splice_range_alignment_items,
                    .adaptive = stage.adaptive,
                    .adaptive_tuner = selected.active_tuner,
                    .selected_profile = selected.profile,
                });
            } else {
                spliceJob(&job, .{ .start = 0, .end = key_count, .index = 0 }, WorkerId.main);
                batch = .{
                    .item_count = key_count,
                    .range_count = 1,
                    .items_per_range = key_count,
                    .range_alignment_items = splice_range_alignment_items,
                    .main_thread_ranges = 1,
                    .ran_inline = true,
                };
            }
            // Link in touched-key order, each key's records in order: each links after a
            // list entry or the record before it, already linked.
            for (self.touched.items) |touched| {
                for (self.splice_records.items[touched.offset..][0..touched.count]) |record| self.linkAfter(touched.slot, record.entry, record.after);
            }
        }
        // Slots stayed put through the links; now drop the keys still empty.
        for (self.emptied_keys.items) |key| {
            const slot = self.findSlot(key).?;
            if (self.slot_heads[slot] != no_entry) continue;
            // A key holding a value is never dropped: its owner clears the value first.
            std.debug.assert(self.slot_values[slot] == no_value);
            self.removeSlot(slot);
        }
        self.in_batch = false;
        return batch;
    }

    // Links `entry` into `slot`'s list after `after`, or at the head for `no_entry`.
    fn linkAfter(self: *ChunkListMap, slot: usize, entry: u32, after: u32) void {
        const next = if (after == no_entry) self.slot_heads[slot] else self.entry_next[after];
        self.entry_prev[entry] = after;
        self.entry_next[entry] = next;
        if (after == no_entry) self.slot_heads[slot] = entry else self.entry_next[after] = entry;
        if (next == no_entry) self.slot_tails[slot] = entry else self.entry_prev[next] = entry;
        self.slot_counts[slot] += 1;
    }

    // Unlinks `entry` from its list; an emptied list's key waits in `emptied_keys`.
    fn unlink(self: *ChunkListMap, entry: u32) void {
        // An entry is always in its key's list, so the key has a slot.
        const slot = self.findSlot(self.entry_key[entry]).?;
        self.unlinkFromSlot(slot, entry);
        if (self.slot_heads[slot] == no_entry) {
            std.debug.assert(self.emptied_keys.items.len < self.emptied_keys.capacity);
            self.emptied_keys.appendAssumeCapacity(self.slot_keys[slot]);
        }
    }

    // Unlinks `entry` from the list of `slot`, its key's slot.
    fn unlinkFromSlot(self: *ChunkListMap, slot: usize, entry: u32) void {
        const prev = self.entry_prev[entry];
        const next = self.entry_next[entry];
        if (prev == no_entry) self.slot_heads[slot] = next else self.entry_next[prev] = next;
        if (next == no_entry) self.slot_tails[slot] = prev else self.entry_prev[next] = prev;
        std.debug.assert(self.slot_counts[slot] != 0);
        self.slot_counts[slot] -= 1;
    }

    // Back-shift deletion: later keys of the probe run move into the hole when their home
    // slot does not lie cyclically after it, so every remaining key stays reachable.
    fn removeSlot(self: *ChunkListMap, removed: usize) void {
        var hole = removed;
        var slot = removed;
        while (true) {
            slot = (slot + 1) & self.mask();
            const key = self.slot_keys[slot];
            if (key == empty_key) break;
            const ideal = self.home(key);
            if (((slot -% ideal) & self.mask()) >= ((slot -% hole) & self.mask())) {
                self.slot_keys[hole] = key;
                self.slot_heads[hole] = self.slot_heads[slot];
                self.slot_tails[hole] = self.slot_tails[slot];
                self.slot_values[hole] = self.slot_values[slot];
                self.slot_counts[hole] = self.slot_counts[slot];
                hole = slot;
            }
        }
        self.slot_keys[hole] = empty_key;
        self.live_keys -= 1;
    }

    // One touched key's records: its staged entries sorted by order, each with the entry
    // it links after. Reads the lists and claims (immutable during the stage); writes only
    // `window`. Claims in ascending or descending order skip the sort: O(k) for k entries.
    fn spliceKey(self: *const ChunkListMap, touched: TouchedKey, window: []SpliceRecord) void {
        // The chain runs newest claim first; filling back to front leaves claim order.
        var claim = touched.head_claim;
        var remaining = window.len;
        while (remaining != 0) {
            remaining -= 1;
            window[remaining].entry = self.claims.items[claim].entry;
            claim = self.claims.items[claim].next;
        }
        std.debug.assert(claim == no_entry);
        // Orders within one key are unique, so a non-increasing window is strictly
        // descending.
        if (!std.sort.isSorted(SpliceRecord, window, self.entry_order, orderLessThan)) {
            if (std.sort.isSorted(SpliceRecord, window, self.entry_order, orderGreaterThan)) {
                std.mem.reverse(SpliceRecord, window);
            } else {
                std.sort.pdq(SpliceRecord, window, self.entry_order, orderLessThan);
            }
        }
        const tail = self.slot_tails[touched.slot];
        if (tail == no_entry or self.entry_order[tail] <= self.entry_order[window[0].entry]) {
            // Every staged entry follows the tail.
            var after = tail;
            for (window) |*record| {
                record.after = after;
                after = record.entry;
            }
            return;
        }
        // One walk: each staged entry links after the last list entry of lower or equal
        // order, or after the staged entry before it when no list entry lies between them.
        var cursor = self.slot_heads[touched.slot];
        var last_listed: u32 = no_entry;
        var previous_listed: u32 = no_entry;
        for (window, 0..) |*record, index| {
            const order = self.entry_order[record.entry];
            while (cursor != no_entry and self.entry_order[cursor] <= order) {
                last_listed = cursor;
                cursor = self.entry_next[cursor];
            }
            record.after = if (index != 0 and last_listed == previous_listed) window[index - 1].entry else last_listed;
            previous_listed = last_listed;
        }
    }
};

// Fibonacci hashing: the multiply spreads chunk-adjacent keys over the table.
fn homeSlot(key: u64, shift: u6) usize {
    return @intCast((key *% 0x9E3779B97F4A7C15) >> shift);
}

// The slot holding `key` in a non-empty power-of-two table hashed at `shift`, or null.
// Linear probing; never writes.
// SIMD verdict: scalar. A probe at load <= 1/2 visits about 2.5 slots per miss, and
// `simd.zig` has no u64 lanes; list walks are pointer chases.
fn probeSlot(keys: []const u64, shift: u6, key: u64) ?usize {
    const slot_mask = keys.len - 1;
    var slot = homeSlot(key, shift);
    while (true) : (slot = (slot + 1) & slot_mask) {
        const stored = keys[slot];
        if (stored == key) return slot;
        if (stored == empty_key) return null;
    }
}

fn orderLessThan(orders: []const u32, a: SpliceRecord, b: SpliceRecord) bool {
    return orders[a.entry] < orders[b.entry];
}

fn orderGreaterThan(orders: []const u32, a: SpliceRecord, b: SpliceRecord) bool {
    return orders[a.entry] > orders[b.entry];
}

// One range of the splice stage: its touched keys' record windows.
const SpliceJob = struct {
    map: *const ChunkListMap,
    items_per_range: usize,
    range_count: usize,
    records: []SpliceRecord,
};

// SIMD verdict: scalar. A per-key sort and a pointer-chasing list walk; irreducible.
fn spliceJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SpliceJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.map.touched.items.len);
    for (job.map.touched.items[range.start..range.end]) |touched| {
        std.debug.assert(touched.offset + touched.count <= job.records.len);
        job.map.spliceKey(touched, job.records[touched.offset..][0..touched.count]);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

// Entries held in lists.
fn liveEntryCount(map: *const ChunkListMap) usize {
    return map.entries.len - map.entry_free.items.len;
}

fn collectOwners(map: *const ChunkListMap, key: u64, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    var owners = map.iterator(key);
    while (owners.next()) |owner| try out.append(std.testing.allocator, owner);
}

// Keeps the entries whose key is in `keys`.
const KeepKeys = struct {
    keys: []const u64,

    pub fn contains(self: KeepKeys, key: u64) bool {
        return std.mem.indexOfScalar(u64, self.keys, key) != null;
    }
};

const keep_nothing = KeepKeys{ .keys = &.{} };

// One batch: `removed` owners leave every list, then each (owner, key) of `inserts` joins
// at order = owner. Reserves first.
fn applyBatch(map: *ChunkListMap, removed: []const u32, inserts: []const [2]u64, owner_count: usize, threads: ?SpliceThreads) !BatchStats {
    try map.reserve(inserts.len, inserts.len, owner_count);
    try map.reserveBatch(inserts.len, liveEntryCount(map));
    map.beginBatch();
    for (removed) |owner| map.unlinkOwnerOutside(owner, keep_nothing);
    for (inserts) |insert| map.stageInsert(@intCast(insert[0]), insert[1], @intCast(insert[0]));
    return map.commitBatch(threads);
}

// Whether every list of `a` equals `b`'s, entry ids included, over `keys`.
fn expectSameLists(a: *const ChunkListMap, b: *const ChunkListMap, keys: []const u64) !void {
    try std.testing.expectEqual(a.live_keys, b.live_keys);
    try std.testing.expectEqual(liveEntryCount(a), liveEntryCount(b));
    for (keys) |key| {
        var entry_a = a.head(key);
        var entry_b = b.head(key);
        while (entry_a != no_entry or entry_b != no_entry) {
            try std.testing.expectEqual(entry_a, entry_b);
            try std.testing.expectEqual(a.entry_owner[entry_a], b.entry_owner[entry_b]);
            entry_a = a.entry_next[entry_a];
            entry_b = b.entry_next[entry_b];
        }
    }
}

test "chunk, superchunk, level, and world keys are distinct and never set both tier bits" {
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(std.testing.allocator);
    for ([_]u16{ 0, 1, std.math.maxInt(u16) }) |level| {
        for ([_]u32{ 0, 1, 7, std.math.maxInt(u31) }) |index| {
            try keys.append(std.testing.allocator, chunkKey(level, index));
            try keys.append(std.testing.allocator, superchunkKey(level, index));
        }
        try keys.append(std.testing.allocator, levelKey(level));
    }
    try keys.append(std.testing.allocator, world_key);
    for (keys.items, 0..) |key, index| {
        try std.testing.expect(key >> 62 != 3);
        try std.testing.expect(key != empty_key);
        for (keys.items[index + 1 ..]) |other| try std.testing.expect(key != other);
    }
    // Every tier lists in one map.
    var map = ChunkListMap.init(std.testing.allocator, "test tiers");
    defer map.deinit();
    try map.reserve(keys.items.len, keys.items.len, keys.items.len);
    for (keys.items, 0..) |key, owner| map.add(@intCast(owner), key, 0);
    for (keys.items, 0..) |key, owner| {
        var owners = map.iterator(key);
        try std.testing.expectEqual(@as(?u32, @intCast(owner)), owners.next());
        try std.testing.expectEqual(@as(?u32, null), owners.next());
    }
}

test "batches keep every list in order and back-shift deletion keeps every key reachable" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    const owner_count = 400;
    var prng = std.Random.DefaultPrng.init(0xc417);
    const random = prng.random();
    // Few distinct keys over a small table so probe runs collide and wrap.
    var keys: [owner_count]u64 = undefined;
    var live: [owner_count]bool = @splat(false);
    var removed: std.ArrayList(u32) = .empty;
    defer removed.deinit(std.testing.allocator);
    var inserts: std.ArrayList([2]u64) = .empty;
    defer inserts.deinit(std.testing.allocator);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (0..6) |_| {
        removed.clearRetainingCapacity();
        inserts.clearRetainingCapacity();
        for (0..owner_count) |owner| {
            if (live[owner] and random.boolean()) {
                try removed.append(std.testing.allocator, @intCast(owner));
                live[owner] = false;
            } else if (!live[owner] and random.boolean()) {
                keys[owner] = chunkKey(random.uintLessThan(u16, 3), random.uintLessThan(u32, 40));
                try inserts.append(std.testing.allocator, .{ owner, keys[owner] });
                live[owner] = true;
            }
        }
        // Inserts arrive out of order.
        random.shuffle([2]u64, inserts.items);
        _ = try applyBatch(&map, removed.items, inserts.items, owner_count, null);
        // Every live key's list holds exactly its live owners, in owner order.
        var expected_keys: usize = 0;
        for (0..3) |level| for (0..40) |chunk| {
            const key = chunkKey(@intCast(level), @intCast(chunk));
            try collectOwners(&map, key, &seen);
            var expected: usize = 0;
            for (0..owner_count) |owner| {
                if (!live[owner] or keys[owner] != key) continue;
                try std.testing.expect(expected < seen.items.len);
                try std.testing.expectEqual(@as(u32, @intCast(owner)), seen.items[expected]);
                expected += 1;
            }
            try std.testing.expectEqual(expected, seen.items.len);
            if (expected != 0) expected_keys += 1;
        };
        try std.testing.expectEqual(expected_keys, map.live_keys);
    }
}

test "a batch links staged entries among the listed ones by order, after equal orders" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    const key = chunkKey(2, 7);
    try map.reserve(1, 9, 9);
    for ([_]u32{ 10, 20, 30, 40 }, 0..) |order, owner| map.appendTail(@intCast(owner), key, order);
    try map.reserveBatch(5, 0);
    map.beginBatch();
    for ([_]u32{ 45, 5, 25, 20, 26 }, 4..) |order, owner| map.stageInsert(@intCast(owner), key, order);
    const batch = map.commitBatch(null);
    try std.testing.expectEqual(@as(usize, 1), batch.item_count);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    try collectOwners(&map, key, &seen);
    // Orders 5, 10, 20, 20 (staged after the listed one), 25, 26, 30, 40, 45.
    try std.testing.expectEqualSlices(u32, &.{ 5, 0, 1, 7, 6, 8, 2, 3, 4 }, seen.items);
    // Prev links mirror next links.
    var entry = map.head(key);
    var prev: u32 = no_entry;
    while (entry != no_entry) : (entry = map.entry_next[entry]) {
        try std.testing.expectEqual(prev, map.entry_prev[entry]);
        prev = entry;
    }
    try std.testing.expectEqual(prev, map.slot_tails[map.findSlot(key).?]);
}

test "unlinkOwnerOutside keeps the owner's entries in the keep set and frees the rest" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try map.reserve(4, 6, 3);
    for (0..4) |chunk| map.appendTail(0, chunkKey(0, @intCast(chunk)), 0);
    map.appendTail(1, chunkKey(0, 1), 1);
    map.appendTail(2, chunkKey(0, 2), 2);
    try map.reserveBatch(0, 2);
    map.beginBatch();
    map.unlinkOwnerOutside(0, KeepKeys{ .keys = &.{ chunkKey(0, 1), chunkKey(0, 3) } });
    _ = map.commitBatch(null);
    try std.testing.expectEqual(@as(usize, 4), liveEntryCount(&map));
    // Chunk 0 emptied and dropped; chunk 2 still lists owner 2.
    try std.testing.expectEqual(@as(usize, 3), map.live_keys);
    try std.testing.expectEqual(no_entry, map.head(chunkKey(0, 0)));
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    try collectOwners(&map, chunkKey(0, 1), &seen);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, seen.items);
    try collectOwners(&map, chunkKey(0, 2), &seen);
    try std.testing.expectEqualSlices(u32, &.{2}, seen.items);
    // The owner's chain holds exactly its kept entries.
    var chain: usize = 0;
    var entry = map.owner_heads.items[0];
    while (entry != no_entry) : (entry = map.entry_owner_next[entry]) {
        try std.testing.expect(map.entry_key[entry] == chunkKey(0, 1) or map.entry_key[entry] == chunkKey(0, 3));
        chain += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), chain);
}

test "a key emptied and refilled in one batch keeps one key; a key a batch empties is dropped" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    const refilled = chunkKey(1, 3);
    const emptied = chunkKey(1, 4);
    try map.reserve(2, 2, 3);
    map.appendTail(0, refilled, 0);
    map.appendTail(1, emptied, 1);
    // Owner 0 leaves the refilled key and owner 2 joins it; owner 1 leaves the other.
    _ = try applyBatch(&map, &.{ 0, 1 }, &.{.{ 2, refilled }}, 3, null);
    try std.testing.expectEqual(@as(usize, 1), map.live_keys);
    try std.testing.expectEqual(no_entry, map.head(emptied));
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    try collectOwners(&map, refilled, &seen);
    try std.testing.expectEqualSlices(u32, &.{2}, seen.items);
    // A later insert of the dropped key finds a fresh slot.
    _ = try applyBatch(&map, &.{}, &.{.{ 1, emptied }}, 3, null);
    try collectOwners(&map, emptied, &seen);
    try std.testing.expectEqualSlices(u32, &.{1}, seen.items);
    try std.testing.expectEqual(@as(usize, 2), map.live_keys);
}

// Random batches over 64 keys: owners leave and join several keys each, out of order.
fn randomBatches(map: *ChunkListMap, seed: u64, threads: ?SpliceThreads) !usize {
    const owner_count = 600;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var live: [owner_count]bool = @splat(false);
    var removed: std.ArrayList(u32) = .empty;
    defer removed.deinit(std.testing.allocator);
    var inserts: std.ArrayList([2]u64) = .empty;
    defer inserts.deinit(std.testing.allocator);
    var max_ranges: usize = 0;
    for (0..8) |_| {
        removed.clearRetainingCapacity();
        inserts.clearRetainingCapacity();
        for (0..owner_count) |owner| {
            if (live[owner] and random.uintLessThan(u8, 3) == 0) {
                try removed.append(std.testing.allocator, @intCast(owner));
                live[owner] = false;
            } else if (!live[owner] and random.boolean()) {
                const first = random.uintLessThan(u32, 60);
                for (0..random.uintLessThan(u32, 4) + 1) |offset| try inserts.append(std.testing.allocator, .{ owner, chunkKey(1, first + @as(u32, @intCast(offset))) });
                live[owner] = true;
            }
        }
        random.shuffle([2]u64, inserts.items);
        const batch = try applyBatch(map, removed.items, inserts.items, owner_count, threads);
        max_ranges = @max(max_ranges, batch.range_count);
    }
    return max_ranges;
}

test "a threaded batch commit equals the inline commit for any partition" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var inline_map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer inline_map.deinit();
    _ = try randomBatches(&inline_map, 0x5a1ce, null);
    var keys: [64]u64 = undefined;
    for (&keys, 0..) |*key, chunk| key.* = chunkKey(1, @intCast(chunk));
    for ([_]usize{ 8, 16, 40 }) |items_per_range| {
        var tuner = AdaptiveWorkTuner.init(.{});
        var map = ChunkListMap.init(std.testing.allocator, "test lists");
        defer map.deinit();
        const ranges = try randomBatches(&map, 0x5a1ce, .{ .thread_system = &threads, .tuner = &tuner, .adaptive = false, .items_per_range = items_per_range });
        try std.testing.expect(ranges > 1);
        try expectSameLists(&map, &inline_map, &keys);
    }
}

test "reserve and reserveBatch, then a threaded batch, allocate nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var tuner = AdaptiveWorkTuner.init(.{});
    const splice: SpliceThreads = .{ .thread_system = &threads, .tuner = &tuner, .adaptive = false, .items_per_range = 8 };
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    // Owners 0..255 over 32 keys, listed in descending order so each staged insert lands
    // mid-list.
    var inserts: [256][2]u64 = undefined;
    for (&inserts, 0..) |*insert, owner| insert.* = .{ owner, chunkKey(@intCast(owner % 2), @intCast(owner % 32)) };
    _ = try applyBatch(&map, &.{}, &inserts, 256, splice);
    // A third of the owners move to one of 24 other keys.
    var removed: [86]u32 = undefined;
    var moved: [86][2]u64 = undefined;
    for (&removed, &moved, 0..) |*owner, *insert, at| {
        owner.* = @intCast(at * 3);
        insert.* = .{ at * 3, chunkKey(1, @intCast(32 + at % 24)) };
    }
    try map.reserve(moved.len, moved.len, 256);
    try map.reserveBatch(moved.len, liveEntryCount(&map));
    map.allocator = std.testing.failing_allocator;
    defer map.allocator = std.testing.allocator;
    map.beginBatch();
    for (removed) |owner| map.unlinkOwnerOutside(owner, keep_nothing);
    for (moved) |insert| map.stageInsert(@intCast(insert[0]), insert[1], @intCast(insert[0]));
    const batch = map.commitBatch(splice);
    try std.testing.expect(!batch.ran_inline and batch.range_count > 1);
    try std.testing.expectEqual(@as(usize, 256), liveEntryCount(&map));
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    map.allocator = std.testing.allocator;
    for (0..2) |level| for (0..56) |chunk| {
        try collectOwners(&map, chunkKey(@intCast(level), @intCast(chunk)), &seen);
        for (0..seen.items.len -| 1) |at| try std.testing.expect(seen.items[at] < seen.items[at + 1]);
    };
}

// Staged orders per key in each claim order: ascending, descending, and mixed around the
// listed orders 10, 20, 30, 40, and descending past the tail.
const arrival_listed_orders = [_]u32{ 10, 20, 30, 40 };
const arrival_staged_orders = [_][6]u32{
    .{ 5, 15, 25, 35, 45, 50 },
    .{ 50, 45, 35, 25, 15, 5 },
    .{ 25, 5, 50, 15, 45, 35 },
    .{ 70, 65, 60, 55, 50, 45 },
};
const arrival_keys_per_order: usize = 16;
const arrival_key_count = arrival_staged_orders.len * arrival_keys_per_order;
const arrival_owners_per_key = arrival_listed_orders.len + arrival_staged_orders[0].len;

fn arrivalKey(key_index: usize) u64 {
    return chunkKey(0, @intCast(key_index));
}

// Owner ids are unique per (key, order).
fn arrivalOwner(key_index: usize, order: u32) u32 {
    return @intCast(key_index * 128 + order);
}

// Lists the listed orders in every arrival key, then stages each key's staged orders in its
// claim order, as one batch.
fn stageArrivalOrders(map: *ChunkListMap, threads: ?SpliceThreads) !BatchStats {
    const owner_count = arrival_key_count * 128;
    try map.reserve(arrival_key_count, arrival_key_count * arrival_owners_per_key, owner_count);
    for (0..arrival_key_count) |key_index| {
        for (arrival_listed_orders) |order| map.appendTail(arrivalOwner(key_index, order), arrivalKey(key_index), order);
    }
    try map.reserveBatch(arrival_key_count * arrival_staged_orders[0].len, liveEntryCount(map));
    map.beginBatch();
    for (0..arrival_key_count) |key_index| {
        for (arrival_staged_orders[key_index / arrival_keys_per_order]) |order| map.stageInsert(arrivalOwner(key_index, order), arrivalKey(key_index), order);
    }
    return map.commitBatch(threads);
}

test "a key's ascending, descending, and mixed arrivals produce the same list as a tail rebuild, inline and threaded" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var inline_map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer inline_map.deinit();
    _ = try stageArrivalOrders(&inline_map, null);

    // The rebuild: every key's owners appended at the tail in order.
    var rebuilt = ChunkListMap.init(std.testing.allocator, "test lists");
    defer rebuilt.deinit();
    try rebuilt.reserve(arrival_key_count, arrival_key_count * arrival_owners_per_key, arrival_key_count * 128);
    var orders: [arrival_owners_per_key]u32 = undefined;
    var keys: [arrival_key_count]u64 = undefined;
    for (&keys, 0..) |*key, key_index| {
        key.* = arrivalKey(key_index);
        @memcpy(orders[0..arrival_listed_orders.len], &arrival_listed_orders);
        @memcpy(orders[arrival_listed_orders.len..], &arrival_staged_orders[key_index / arrival_keys_per_order]);
        std.sort.pdq(u32, &orders, {}, std.sort.asc(u32));
        for (orders) |order| rebuilt.appendTail(arrivalOwner(key_index, order), key.*, order);
    }
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (keys) |key| {
        try collectOwners(&inline_map, key, &seen);
        try collectOwners(&rebuilt, key, &expected);
        try std.testing.expectEqualSlices(u32, expected.items, seen.items);
    }

    // Threaded over several ranges: the same layout, entry ids included.
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var tuner = AdaptiveWorkTuner.init(.{});
    var threaded_map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer threaded_map.deinit();
    const batch = try stageArrivalOrders(&threaded_map, .{ .thread_system = &threads, .tuner = &tuner, .adaptive = false, .items_per_range = 1 });
    try std.testing.expect(!batch.ran_inline and batch.range_count > 1);
    try expectSameLists(&threaded_map, &inline_map, &keys);
}

test "Reader.head equals head for present and absent keys across a rehash" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try std.testing.expectEqual(no_entry, map.reader().head(chunkKey(0, 0)));
    // Keys across levels and the query-class bits, enough to rehash the table twice.
    var keys: [40]u64 = undefined;
    for (&keys, 0..) |*key, at| key.* = (@as(u64, at % 3) << 48) | chunkKey(@intCast(at % 5), @intCast(at * 7));
    for (keys, 0..) |key, at| {
        const slots_before = map.slot_keys.len;
        try map.reserve(1, 1, keys.len);
        map.appendTail(@intCast(at), key, @intCast(at));
        const view = map.reader();
        for (keys, 0..) |probe, probe_at| {
            try std.testing.expectEqual(map.head(probe), view.head(probe));
            try std.testing.expectEqual(probe_at <= at, view.head(probe) != no_entry);
        }
        // Absent keys on and off the listed levels.
        try std.testing.expectEqual(no_entry, view.head(chunkKey(0, 9999)));
        try std.testing.expectEqual(no_entry, view.head((@as(u64, 7) << 48) | chunkKey(1, 7)));
        if (map.slot_keys.len != slots_before) try std.testing.expect(view.keys.ptr == map.slot_keys.ptr);
    }
    try std.testing.expect(map.slot_keys.len > min_slot_count * 2);
}

test "an entry pool grow that fails after the pool moved keeps the column views on the live pool" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try map.reserve(1, 4, 8);
    for (0..4) |owner| map.appendTail(@intCast(owner), chunkKey(0, 0), @intCast(owner));
    // The pool is full: the next reserve moves it (allocation 0), then growing the free list
    // (allocation 1, after a refused in-place resize) fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    map.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, map.reserve(0, map.entries.capacity + 1, 8));
    map.allocator = std.testing.allocator;
    const columns = map.entries.slice();
    try std.testing.expectEqual(columns.items(.owner).ptr, map.entry_owner.ptr);
    try std.testing.expectEqual(columns.items(.next).ptr, map.entry_next.ptr);
    try std.testing.expectEqual(columns.items(.order).ptr, map.entry_order.ptr);
    // The retry lists the next owner after the kept ones.
    _ = try applyBatch(&map, &.{}, &.{.{ 4, chunkKey(0, 0) }}, 8, null);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(std.testing.allocator);
    try collectOwners(&map, chunkKey(0, 0), &seen);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, seen.items);
}

test "a key's value survives a rehash and the back-shift deletion of its probe neighbours, and Reader.value equals value" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try std.testing.expectEqual(no_value, map.value(chunkKey(0, 0)));
    try std.testing.expectEqual(no_value, map.reader().value(chunkKey(0, 0)));
    // Enough keys to rehash the table twice; every third key holds a value.
    const key_count = 48;
    var keys: [key_count]u64 = undefined;
    for (&keys, 0..) |*key, at| key.* = chunkKey(@intCast(at % 3), @intCast(at * 5));
    for (keys, 0..) |key, at| {
        try map.reserve(1, 1, key_count + 3);
        map.appendTail(@intCast(at), key, @intCast(at));
        // A new key holds no value.
        try std.testing.expectEqual(no_value, map.value(key));
        if (at % 3 == 0) map.setValue(key, @intCast(at * 11));
    }
    try std.testing.expect(map.slot_keys.len > min_slot_count * 2);
    const expectValues = struct {
        fn check(checked: *const ChunkListMap, checked_keys: []const u64) !void {
            const view = checked.reader();
            for (checked_keys, 0..) |key, at| {
                const expected: u32 = if (checked.head(key) == no_entry) no_value else if (at % 3 == 0) @intCast(at * 11) else no_value;
                try std.testing.expectEqual(expected, checked.value(key));
                try std.testing.expectEqual(checked.value(key), view.value(key));
            }
        }
    }.check;
    try expectValues(&map, &keys);
    try std.testing.expectEqual(no_value, map.reader().value(chunkKey(7, 9999)));

    // Three fresh keys sharing one home slot: the second and third hold values and sit
    // after the first on its probe run, so dropping the first back-shifts them.
    var run: [3]u64 = undefined;
    var found: usize = 0;
    const shift = map.homeShift();
    const run_home = homeSlot(chunkKey(5, 0), shift);
    var candidate: u32 = 0;
    while (found < run.len) : (candidate += 1) {
        const key = chunkKey(5, candidate);
        if (homeSlot(key, shift) != run_home) continue;
        run[found] = key;
        found += 1;
    }
    try map.reserve(run.len, run.len, key_count + run.len);
    try std.testing.expectEqual(shift, map.homeShift());
    for (run, 0..) |key, at| map.appendTail(@intCast(key_count + at), key, 0);
    map.setValue(run[1], 101);
    map.setValue(run[2], 202);
    const slot_before = [2]usize{ map.findSlot(run[1]).?, map.findSlot(run[2]).? };
    _ = try applyBatch(&map, &.{key_count}, &.{}, key_count + run.len, null);
    try std.testing.expectEqual(no_entry, map.head(run[0]));
    try std.testing.expect(map.findSlot(run[1]).? != slot_before[0] or map.findSlot(run[2]).? != slot_before[1]);
    try std.testing.expectEqual(@as(u32, 101), map.value(run[1]));
    try std.testing.expectEqual(@as(u32, 202), map.value(run[2]));
    try std.testing.expectEqual(@as(u32, 101), map.reader().value(run[1]));
    try std.testing.expectEqual(@as(u32, 202), map.reader().value(run[2]));
    try std.testing.expectEqual(no_value, map.value(run[0]));
    try expectValues(&map, &keys);

    // Clearing a value lets a batch drop its key.
    map.setValue(run[1], no_value);
    _ = try applyBatch(&map, &.{key_count + 1}, &.{}, key_count + run.len, null);
    try std.testing.expectEqual(no_entry, map.head(run[1]));
    try std.testing.expectEqual(@as(u32, 202), map.value(run[2]));
}

// Owners and orders of `key`'s list, in list order.
fn collectEntries(map: *const ChunkListMap, key: u64, owners: *std.ArrayList(u32), orders: *std.ArrayList(u32)) !void {
    owners.clearRetainingCapacity();
    orders.clearRetainingCapacity();
    var entry = map.head(key);
    while (entry != no_entry) : (entry = map.entry_next[entry]) {
        try owners.append(std.testing.allocator, map.entry_owner[entry]);
        try orders.append(std.testing.allocator, map.entry_order[entry]);
    }
}

// Every live key's count equals its list length, and every pooled entry is listed or free.
fn expectCountsMatchLists(map: *const ChunkListMap) !void {
    var listed: usize = 0;
    for (map.slot_keys, 0..) |key, slot| {
        if (key == empty_key) continue;
        var length: u32 = 0;
        var entry = map.slot_heads[slot];
        while (entry != no_entry) : (entry = map.entry_next[entry]) length += 1;
        try std.testing.expectEqual(length, map.slot_counts[slot]);
        try std.testing.expectEqual(length, map.keyCount(key));
        try std.testing.expectEqual(length, map.reader().keyCount(key));
        listed += length;
    }
    try std.testing.expectEqual(listed, liveEntryCount(map));
}

test "add keeps every run of one owner in insertion order without dedupe" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    const key = chunkKey(3, 5);
    try map.reserve(1, 6, 4);
    // Owner 1 enters the key three times; orders are run starts, not sorted.
    map.add(1, key, 40);
    map.add(2, key, 7);
    map.add(1, key, 3);
    map.add(1, key, 3);
    map.add(0, key, 90);
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(std.testing.allocator);
    var orders: std.ArrayList(u32) = .empty;
    defer orders.deinit(std.testing.allocator);
    try collectEntries(&map, key, &owners, &orders);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 1, 1, 0 }, owners.items);
    try std.testing.expectEqualSlices(u32, &.{ 40, 7, 3, 3, 90 }, orders.items);
    try std.testing.expectEqual(@as(u32, 5), map.keyCount(key));
    try expectCountsMatchLists(&map);
}

// Lists, per-key counts, live keys, and owner chains of two maps are equal, entry ids
// included, over `keys` and owners below `owner_count`.
fn expectSameMaps(a: *const ChunkListMap, b: *const ChunkListMap, keys: []const u64, owner_count: usize) !void {
    try expectSameLists(a, b, keys);
    for (keys) |key| {
        try std.testing.expectEqual(a.keyCount(key), b.keyCount(key));
        var entry = a.head(key);
        while (entry != no_entry) : (entry = a.entry_next[entry]) try std.testing.expectEqual(a.entry_order[entry], b.entry_order[entry]);
    }
    for (0..owner_count) |owner| {
        var entry_a = a.owner_heads.items[owner];
        var entry_b = b.owner_heads.items[owner];
        while (entry_a != no_entry or entry_b != no_entry) {
            try std.testing.expectEqual(entry_a, entry_b);
            entry_a = a.entry_owner_next[entry_a];
            entry_b = b.entry_owner_next[entry_b];
        }
    }
}

test "addAll equals one add per record, for runs of one key, a key change back, and a new key" {
    const Record = struct { owner: u32, key: u64, order: u32 };
    const a = chunkKey(0, 1);
    const b = chunkKey(0, 2);
    const c = chunkKey(3, 9);
    // A and B are listed already; C is new. Owners repeat and mix across keys.
    const records = [_]Record{
        .{ .owner = 2, .key = a, .order = 5 },
        .{ .owner = 2, .key = a, .order = 1 },
        .{ .owner = 0, .key = b, .order = 3 },
        .{ .owner = 1, .key = a, .order = 7 },
        .{ .owner = 0, .key = c, .order = 0 },
        .{ .owner = 3, .key = c, .order = 2 },
    };
    var maps: [2]ChunkListMap = .{ ChunkListMap.init(std.testing.allocator, "test lists"), ChunkListMap.init(std.testing.allocator, "test lists") };
    defer for (&maps) |*map| map.deinit();
    for (&maps) |*map| {
        try map.reserve(3, 3 + records.len, 4);
        map.add(1, a, 0);
        map.add(3, b, 0);
        map.add(0, a, 4);
    }
    for (records) |record| maps[0].add(record.owner, record.key, record.order);
    maps[1].addAll(&records);
    try expectSameMaps(&maps[0], &maps[1], &.{ a, b, c }, 4);
    try std.testing.expectEqual(maps[0].live_keys, maps[1].live_keys);
    try std.testing.expectEqual(@as(u32, 5), maps[1].keyCount(a));
    try expectCountsMatchLists(&maps[1]);
}

test "removeOwner unlinks every entry of the owner and drops the keys it empties" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try map.reserve(3, 6, 3);
    // Owner 0 alone in keys A and C; shares key B with owner 1, twice in B.
    const a = chunkKey(0, 1);
    const b = chunkKey(0, 2);
    const c = chunkKey(1, 2);
    map.add(0, a, 0);
    map.add(0, b, 1);
    map.add(1, b, 0);
    map.add(0, b, 4);
    map.add(0, c, 6);
    map.add(2, chunkKey(4, 4), 0);
    try std.testing.expectEqual(@as(usize, 4), map.removeOwner(0));
    try std.testing.expectEqual(no_entry, map.head(a));
    try std.testing.expectEqual(no_entry, map.head(c));
    try std.testing.expect(map.findSlot(a) == null and map.findSlot(c) == null);
    try std.testing.expectEqual(@as(usize, 2), map.live_keys);
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(std.testing.allocator);
    try collectOwners(&map, b, &owners);
    try std.testing.expectEqualSlices(u32, &.{1}, owners.items);
    try std.testing.expectEqual(no_entry, map.owner_heads.items[0]);
    try expectCountsMatchLists(&map);
    // An owner with no entries, or past the heads, removes nothing.
    try std.testing.expectEqual(@as(usize, 0), map.removeOwner(0));
    try std.testing.expectEqual(@as(usize, 0), map.removeOwner(99));
}

test "renameOwner moves every entry and allocates nothing (FailingAllocator)" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try map.reserve(3, 5, 8);
    const keys = [_]u64{ chunkKey(0, 0), chunkKey(0, 1), chunkKey(2, 9) };
    map.add(5, keys[0], 0);
    map.add(1, keys[1], 0);
    map.add(5, keys[1], 3);
    map.add(5, keys[2], 7);
    map.add(1, keys[2], 0);
    map.allocator = std.testing.failing_allocator;
    map.renameOwner(5, 2);
    map.allocator = std.testing.allocator;
    try std.testing.expectEqual(no_entry, map.owner_heads.items[5]);
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(std.testing.allocator);
    var orders: std.ArrayList(u32) = .empty;
    defer orders.deinit(std.testing.allocator);
    try collectEntries(&map, keys[1], &owners, &orders);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, owners.items);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, orders.items);
    try collectEntries(&map, keys[2], &owners, &orders);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, owners.items);
    // The renamed owner's chain holds its three entries; removing it frees them all.
    var chain: usize = 0;
    var entry = map.owner_heads.items[2];
    while (entry != no_entry) : (entry = map.entry_owner_next[entry]) {
        try std.testing.expectEqual(@as(u32, 2), map.entry_owner[entry]);
        chain += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), chain);
    try std.testing.expectEqual(@as(usize, 3), map.removeOwner(2));
    try std.testing.expectEqual(@as(usize, 0), map.removeOwner(5));
    try expectCountsMatchLists(&map);
}

test "key count follows add, a batch commit, removeOwner, renameOwner, a rehash, and back-shift deletion" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    const owner_count = 200;
    var prng = std.Random.DefaultPrng.init(0xc0de);
    const random = prng.random();
    var live: [owner_count]bool = @splat(false);
    // Grows the table from its minimum through several rehashes.
    for (0..owner_count) |owner| {
        const runs = random.uintLessThan(u32, 4) + 1;
        try map.reserve(runs, runs, owner_count);
        for (0..runs) |run| map.add(@intCast(owner), chunkKey(random.uintLessThan(u16, 2), random.uintLessThan(u32, 60)), @intCast(run));
        live[owner] = true;
        try expectCountsMatchLists(&map);
    }
    try std.testing.expect(map.slot_keys.len > min_slot_count * 4);
    // A batch moves some owners: unlinks and staged inserts.
    try map.reserve(64, 64, owner_count);
    try map.reserveBatch(64, liveEntryCount(&map));
    map.beginBatch();
    for (0..32) |at| {
        const owner: u32 = @intCast(at * 5);
        map.unlinkOwnerOutside(owner, keep_nothing);
        map.stageInsert(owner, chunkKey(0, 100 + @as(u32, @intCast(at % 7))), owner);
    }
    _ = map.commitBatch(null);
    try expectCountsMatchLists(&map);
    // Removals drop keys and back-shift their probe neighbours; renames move into freed ids.
    for (0..owner_count) |owner| {
        if (owner % 3 == 0) {
            _ = map.removeOwner(@intCast(owner));
            live[owner] = false;
        }
    }
    try expectCountsMatchLists(&map);
    for (0..owner_count) |owner| {
        if (owner % 3 == 1 and !live[owner - 1]) {
            map.renameOwner(@intCast(owner), @intCast(owner - 1));
            live[owner - 1] = true;
            live[owner] = false;
        }
    }
    try expectCountsMatchLists(&map);
}

test "a prepared owner truncation keeps every lookup, installs without allocating (FailingAllocator), and releases the heads past the count" {
    var map = ChunkListMap.init(std.testing.allocator, "test lists");
    defer map.deinit();
    try map.reserve(4, 4, 64);
    for (0..4) |owner| map.add(@intCast(owner), chunkKey(0, @intCast(owner)), 0);
    // Owners 40 and 60 held entries once; renamed below the count before truncating.
    try map.reserve(2, 2, 64);
    map.add(40, chunkKey(1, 0), 0);
    map.add(60, chunkKey(1, 1), 0);
    try map.prepareTruncate(6);
    map.renameOwner(40, 4);
    map.renameOwner(60, 5);
    map.allocator = std.testing.failing_allocator;
    map.installTruncate();
    map.allocator = std.testing.allocator;
    map.releaseTruncated();
    try std.testing.expectEqual(@as(usize, 6), map.owner_heads.items.len);
    try std.testing.expectEqual(@as(usize, 6), map.owner_heads.capacity);
    for (0..4) |owner| {
        var owners = map.iterator(chunkKey(0, @intCast(owner)));
        try std.testing.expectEqual(@as(?u32, @intCast(owner)), owners.next());
        try std.testing.expectEqual(@as(?u32, null), owners.next());
    }
    var moved = map.iterator(chunkKey(1, 1));
    try std.testing.expectEqual(@as(?u32, 5), moved.next());
    try expectCountsMatchLists(&map);
    // A truncated id grows back through the reserve.
    try map.reserve(1, 1, 64);
    map.add(63, chunkKey(2, 0), 0);
    try std.testing.expectEqual(@as(usize, 1), map.removeOwner(63));
}
