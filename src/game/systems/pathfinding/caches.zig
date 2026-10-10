// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Goal-keyed query caches: the linear-probe pending/negative KeySet and the
//! completed-path ResultCache (exact path storage, entries kept across resizes), plus
//! the per-agent waypoint derivation that turns a cached plain or stitched path into a
//! forward heading.

const std = @import("std");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavGraph = @import("nav_graph.zig").NavGraph;
const types = @import("types.zig");
const PathQueryKey = types.PathQueryKey;
const StitchedCell = types.StitchedCell;
const PathResult = types.PathResult;
const PathfindingStats = types.PathfindingStats;
const ListResize = types.ListResize;
const hashPathKey = types.hashPathKey;
const keysEqual = types.keysEqual;
const emptyKey = types.emptyKey;
const no_cell = types.no_cell;
const ChangedSpan = types.ChangedSpan;

// Forward window probed around a per-agent waypoint hint before falling back to a full
// path scan. Agents walk a shared goal-keyed path monotonically (~1 cell/step), so the
// next match is almost always within a few cells of last step's index; this turns the
// per-agent waypoint derivation from O(path_len) into O(window) in the common case.
const waypoint_hint_window: usize = 8;

// Generic fixed-capacity, open-addressed (linear-probe) table keyed by PathQueryKey with
// back-shift deletion. Full tables drop new inserts instead of allocating during the
// fixed-step update. Backs both the pending/negative KeySet (Payload = void) and the
// group-key -> requests-index map (Payload = u16). ResultCache below re-implements this
// same probe-walk/back-shift shape rather than composing over this table, because its
// slots also carry per-entry path/stitched cell stripes ProbeTable has no notion of; the
// two copies are kept in sync by hand, not shared code.
//
// The physical slot array is 2x the LOGICAL capacity (inserts stop at logical), so
// occupancy never exceeds 50% and every probe chain — hit or miss — terminates at an
// empty slot instead of degenerating to an O(capacity) scan when the table fills.
fn ProbeTable(comptime Payload: type) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            occupied: bool = false,
            key: PathQueryKey = emptyKey(0),
            payload: Payload = undefined,
        };
        slots: std.ArrayList(Slot) = .empty,
        len: usize = 0,
        // Insert ceiling; slots.items.len is 2x this for probe headroom.
        logical_capacity: usize = 0,

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.* = undefined;
        }

        // Resizes to `capacity` keeping the entries: the slots are rebuilt on the side and
        // every entry rehashed, up to `capacity` of them in slot order. Failure-atomic: the
        // only fallible step allocates the new slots before the old ones are released.
        fn reserve(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            const physical = capacity *| 2;
            if (capacity == self.logical_capacity and self.slots.items.len == physical) return;
            var slots: std.ArrayList(Slot) = .empty;
            try slots.ensureTotalCapacityPrecise(allocator, physical);
            slots.items.len = physical;
            @memset(slots.items, .{});
            var kept: usize = 0;
            for (self.slots.items) |slot| {
                if (!slot.occupied) continue;
                if (kept == capacity) break;
                insertRehashed(Slot, slots.items, slot);
                kept += 1;
            }
            self.slots.deinit(allocator);
            self.slots = slots;
            self.len = kept;
            self.logical_capacity = capacity;
        }

        fn clear(self: *Self) void {
            for (self.slots.items) |*slot| slot.occupied = false;
            self.len = 0;
        }

        fn findIndex(self: *const Self, key: PathQueryKey) ?usize {
            const capacity = self.slots.items.len;
            if (capacity == 0) return null;
            const start = hashPathKey(key) % capacity;
            for (0..capacity) |probe| {
                const index = (start + probe) % capacity;
                const slot = self.slots.items[index];
                if (slot.occupied and keysEqual(slot.key, key)) return index;
                // Chains are contiguous (back-shift deletion) and the table is never
                // more than half full, so the first empty slot ends this key's chain.
                if (!slot.occupied) return null;
            }
            return null;
        }

        fn payloadOf(self: *const Self, key: PathQueryKey) ?Payload {
            const index = self.findIndex(key) orelse return null;
            return self.slots.items[index].payload;
        }

        // Inserts key with payload, or updates the payload if key is already present.
        // Returns false only when the table is logically full and key is absent.
        fn put(self: *Self, key: PathQueryKey, payload: Payload) bool {
            const capacity = self.slots.items.len;
            if (capacity == 0) return false;
            const start = hashPathKey(key) % capacity;
            for (0..capacity) |probe| {
                const index = (start + probe) % capacity;
                const slot = &self.slots.items[index];
                if (slot.occupied and keysEqual(slot.key, key)) {
                    slot.payload = payload;
                    return true;
                }
                if (!slot.occupied) {
                    if (self.len >= self.logical_capacity) return false;
                    slot.* = .{ .occupied = true, .key = key, .payload = payload };
                    self.len += 1;
                    return true;
                }
            }
            return false;
        }

        // Updates the payload of an existing key; no-op if absent.
        fn update(self: *Self, key: PathQueryKey, payload: Payload) void {
            const index = self.findIndex(key) orelse return;
            self.slots.items[index].payload = payload;
        }

        // Removes a key using back-shift deletion so probe chains stay contiguous (an
        // ordinary clear-and-leave-empty would strand later entries behind the gap).
        fn remove(self: *Self, key: PathQueryKey) void {
            const capacity = self.slots.items.len;
            if (capacity == 0) return;
            const start = hashPathKey(key) % capacity;
            var hole: usize = capacity; // sentinel: not found
            for (0..capacity) |probe| {
                const index = (start + probe) % capacity;
                const slot = self.slots.items[index];
                if (!slot.occupied) return; // chain end; key not present
                if (keysEqual(slot.key, key)) {
                    hole = index;
                    break;
                }
            }
            if (hole == capacity) return;
            self.slots.items[hole].occupied = false;
            self.len -= 1;
            // Pull up subsequent entries that can fill the gap without becoming unreachable.
            const initial_hole = hole;
            var probe: usize = initial_hole;
            while (true) {
                probe = (probe + 1) % capacity;
                if (probe == initial_hole) break;
                const slot = self.slots.items[probe];
                if (!slot.occupied) break;
                const home = hashPathKey(slot.key) % capacity;
                if (inCyclicRange(hole, probe, home)) continue;
                self.slots.items[hole] = slot;
                self.slots.items[probe].occupied = false;
                hole = probe;
            }
        }
    };
}

// Fixed-capacity linear-probe set for pending/negative keys. Full sets drop new inserts
// instead of allocating during the fixed-step update.
pub const KeySet = struct {
    table: ProbeTable(void) = .{},

    pub fn deinit(self: *KeySet, allocator: std.mem.Allocator) void {
        self.table.deinit(allocator);
    }

    pub fn reserve(self: *KeySet, allocator: std.mem.Allocator, capacity: usize) !void {
        return self.table.reserve(allocator, capacity);
    }

    pub fn clear(self: *KeySet) void {
        self.table.clear();
    }

    pub fn contains(self: *const KeySet, key: PathQueryKey) bool {
        return self.table.findIndex(key) != null;
    }

    // Returns true if the key is present after the call (already-present or newly inserted);
    // false only when the set is full and the key is absent.
    pub fn insert(self: *KeySet, key: PathQueryKey) bool {
        return self.table.put(key, {});
    }

    pub fn remove(self: *KeySet, key: PathQueryKey) void {
        self.table.remove(key);
    }
};

// Fixed-capacity linear-probe map from goal key to group_requests slot index.
// Enables O(1) lookup in recordGroupRequest instead of an O(N) linear scan. Maps a key to
// the dense ArrayList index in group_requests, stable until a swapRemove touches it (see
// updateIndex).
pub const GroupKeyMap = struct {
    table: ProbeTable(u16) = .{},

    pub fn deinit(self: *GroupKeyMap, allocator: std.mem.Allocator) void {
        self.table.deinit(allocator);
    }

    pub fn reserve(self: *GroupKeyMap, allocator: std.mem.Allocator, capacity: usize) !void {
        return self.table.reserve(allocator, capacity);
    }

    pub fn clear(self: *GroupKeyMap) void {
        self.table.clear();
    }

    // Returns the stored group_requests index for this key, or null if absent.
    pub fn find(self: *const GroupKeyMap, key: PathQueryKey) ?usize {
        const group_index = self.table.payloadOf(key) orelse return null;
        return group_index;
    }

    // Maps key → group_requests index. Returns false when the map is full. group_index
    // fits u16: group_requests is capped at max_solved_requests_per_step, itself clamped
    // to default_max_solves_per_frame (512), far under u16's range.
    pub fn insert(self: *GroupKeyMap, key: PathQueryKey, group_index: usize) bool {
        return self.table.put(key, @intCast(group_index));
    }

    // Updates the stored index for a key that moved due to a swapRemove. See insert for
    // why new_group_index always fits u16.
    pub fn updateIndex(self: *GroupKeyMap, key: PathQueryKey, new_group_index: usize) void {
        self.table.update(key, @intCast(new_group_index));
    }

    pub fn remove(self: *GroupKeyMap, key: PathQueryKey) void {
        self.table.remove(key);
    }
};

// Goal-keyed cache. Each entry stores its path exactly so a moving agent can derive a
// forward waypoint from its current cell against the stored path.
//
// SoA layout: the probe-hot {occupied, key, payload_index} slots stay dense so a
// linear-probe scan (slotIndex/findOrEvictSlot) never drags the cold payload across
// cache lines. The physical probe table is 2x the logical capacity (occupancy never
// exceeds 50%, so every probe chain ends at an empty slot), while the cold payloads and
// the per-entry inline stripes stay at logical capacity, reached through the slot's
// payload_index. Back-shift deletion and resize rehashing move only the probe slot.
//
// Storage: each payload index owns an inline stripe of `inline_words` words, holding a
// plain path of up to `inline_words` cells or a stitched path of up to
// `inline_words / stitched_cell_words` cells. A longer result is stored whole in one
// long block of `long_block_words` words. Long blocks are claimed from a free list
// that only the publish reserve grows (`reserveLongBlocks`), released on removal, and
// compacted to the live long entries by a shrink, so a live entry is never evicted for
// long-pool space.
pub const ResultCache = struct {
    slots: std.ArrayList(ProbeSlot) = .empty,
    payloads: std.ArrayList(SlotPayload) = .empty,
    inline_cells: std.ArrayList(u32) = .empty,
    inline_words: usize = 0,
    long_cells: std.ArrayList(u32) = .empty,
    long_block_words: usize = 0,
    // Logical long-block count; long_cells holds exactly this many blocks.
    long_block_count: usize = 0,
    // Unclaimed long blocks (stack); capacity covers every block, so a release never
    // allocates.
    free_long_blocks: std.ArrayList(u32) = .empty,
    // Unclaimed payload/stripe indices (stack). Every occupied probe slot owns a
    // distinct payload_index, so this holds exactly logical_capacity - len entries.
    free_payload_indices: std.ArrayList(u32) = .empty,
    // Pre-reserved key scratch for evictCrossing's collect-then-remove sweep.
    evict_scratch: std.ArrayList(PathQueryKey) = .empty,
    // Insert ceiling; slots.items.len is 2x this for probe headroom.
    logical_capacity: usize = 0,
    len: usize = 0,
    next_evict: usize = 0,

    pub fn deinit(self: *ResultCache, allocator: std.mem.Allocator) void {
        self.evict_scratch.deinit(allocator);
        self.free_payload_indices.deinit(allocator);
        self.free_long_blocks.deinit(allocator);
        self.long_cells.deinit(allocator);
        self.inline_cells.deinit(allocator);
        self.payloads.deinit(allocator);
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    // Reconstructs the full PathResult for a probe slot from its hot key and cold payload.
    pub fn resultAt(self: *const ResultCache, index: usize) PathResult {
        const slot = self.slots.items[index];
        const payload = self.payloads.items[slot.payload_index];
        return .{
            .key = slot.key,
            .path_len = payload.path_len,
            .path_level = payload.path_level,
            .stitched_len = payload.stitched_len,
        };
    }

    /// Resizes to `capacity` entries with `inline_words`-word stripes and
    /// `long_block_words`-word long blocks. With unchanged widths the live entries are
    /// kept: a grow rehashes the probe slots, a shrink first evicts oldest first (age
    /// `step -% stamp`, then payload index) until the entries fit, then moves entries at payload index >=
    /// `capacity` into free low indices and compacts long blocks to the live long
    /// entries. A width change (or an empty cache) rebuilds empty. Failure-atomic: every
    /// allocation happens before any entry moves, so an OOM leaves the cache as it was.
    /// Main thread, resize seam. O(live entries + old and new capacity), plus a sort of
    /// the live entries when a shrink evicts.
    pub fn reserve(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, inline_words: usize, long_block_words: usize, step: u32) !void {
        if (self.len == 0 or inline_words != self.inline_words or long_block_words != self.long_block_words) {
            return self.reserveEmpty(allocator, capacity, inline_words, long_block_words);
        }
        if (capacity == self.logical_capacity) return;
        return self.resizeKeepingEntries(allocator, capacity, step);
    }

    fn reserveEmpty(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, inline_words: usize, long_block_words: usize) !void {
        const physical = capacity *| 2;
        // A shrink frees the old backing after its replacement exists, so an elastic
        // down-resize releases memory.
        var slots_resize: ListResize(ProbeSlot) = .{};
        try slots_resize.prepare(&self.slots, allocator, physical);
        errdefer slots_resize.abort(allocator);
        var payloads_resize: ListResize(SlotPayload) = .{};
        try payloads_resize.prepare(&self.payloads, allocator, capacity);
        errdefer payloads_resize.abort(allocator);
        var inline_resize: ListResize(u32) = .{};
        try inline_resize.prepare(&self.inline_cells, allocator, capacity *| inline_words);
        errdefer inline_resize.abort(allocator);
        var long_resize: ListResize(u32) = .{};
        try long_resize.prepare(&self.long_cells, allocator, 0);
        errdefer long_resize.abort(allocator);
        var free_long_resize: ListResize(u32) = .{};
        try free_long_resize.prepare(&self.free_long_blocks, allocator, 0);
        errdefer free_long_resize.abort(allocator);
        var free_indices_resize: ListResize(u32) = .{};
        try free_indices_resize.prepare(&self.free_payload_indices, allocator, capacity);
        errdefer free_indices_resize.abort(allocator);
        var evict_scratch_resize: ListResize(PathQueryKey) = .{};
        try evict_scratch_resize.prepare(&self.evict_scratch, allocator, capacity);

        // Nothing below can fail: commit every list, then rebuild at the new shape.
        slots_resize.commit(&self.slots, allocator);
        payloads_resize.commit(&self.payloads, allocator);
        inline_resize.commit(&self.inline_cells, allocator);
        long_resize.commit(&self.long_cells, allocator);
        free_long_resize.commit(&self.free_long_blocks, allocator);
        free_indices_resize.commit(&self.free_payload_indices, allocator);
        evict_scratch_resize.commit(&self.evict_scratch, allocator);
        self.slots.items.len = physical;
        self.payloads.items.len = capacity;
        // Stripe contents past a stored length are never read, so they stay unwritten.
        self.inline_cells.items.len = capacity * inline_words;
        self.long_cells.clearRetainingCapacity();
        self.free_long_blocks.clearRetainingCapacity();
        self.evict_scratch.clearRetainingCapacity();
        self.long_block_count = 0;
        self.inline_words = inline_words;
        self.long_block_words = long_block_words;
        self.logical_capacity = capacity;
        self.clear();
    }

    fn resizeKeepingEntries(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, step: u32) !void {
        const old_capacity = self.logical_capacity;
        const shrinking = capacity < old_capacity;
        const physical = capacity *| 2;

        // Prepare: every allocation, and the eviction order, before any entry moves.
        var new_slots: std.ArrayList(ProbeSlot) = .empty;
        try new_slots.ensureTotalCapacityPrecise(allocator, physical);
        errdefer new_slots.deinit(allocator);
        var order: std.ArrayList(EntryAge) = .empty;
        defer order.deinit(allocator);
        const evict_count = self.len -| capacity;
        var kept_long = self.long_block_count - self.free_long_blocks.items.len;
        if (evict_count != 0) {
            try order.ensureTotalCapacityPrecise(allocator, self.len);
            for (self.slots.items, 0..) |slot, slot_index| {
                if (!slot.occupied) continue;
                order.appendAssumeCapacity(.{
                    .age = step -% self.payloads.items[slot.payload_index].stamp,
                    .payload_index = slot.payload_index,
                    .slot_index = slot_index,
                });
            }
            std.mem.sortUnstable(EntryAge, order.items, {}, EntryAge.olderThan);
            for (order.items[0..evict_count]) |victim| {
                if (self.payloads.items[victim.payload_index].long_block != no_block) kept_long -= 1;
            }
        }
        const long_count = if (shrinking) kept_long else self.long_block_count;
        var payloads_resize: ListResize(SlotPayload) = .{};
        try payloads_resize.prepare(&self.payloads, allocator, capacity);
        errdefer payloads_resize.abort(allocator);
        var inline_resize: ListResize(u32) = .{};
        try inline_resize.prepare(&self.inline_cells, allocator, capacity *| self.inline_words);
        errdefer inline_resize.abort(allocator);
        var long_resize: ListResize(u32) = .{};
        try long_resize.prepare(&self.long_cells, allocator, long_count *| self.long_block_words);
        errdefer long_resize.abort(allocator);
        var free_long_resize: ListResize(u32) = .{};
        try free_long_resize.prepare(&self.free_long_blocks, allocator, long_count);
        errdefer free_long_resize.abort(allocator);
        var free_indices_resize: ListResize(u32) = .{};
        try free_indices_resize.prepare(&self.free_payload_indices, allocator, capacity);
        errdefer free_indices_resize.abort(allocator);
        var evict_scratch_resize: ListResize(PathQueryKey) = .{};
        try evict_scratch_resize.prepare(&self.evict_scratch, allocator, capacity);

        // Commit: nothing below can fail.
        for (order.items[0..evict_count]) |victim| {
            // The old probe table is rebuilt below, so its chains need not stay contiguous.
            self.slots.items[victim.slot_index].occupied = false;
            self.releasePayload(victim.payload_index);
            self.len -= 1;
        }
        if (shrinking) {
            self.compactPayloads(capacity);
            self.compactLongBlocks(long_count);
        }
        payloads_resize.commitResized(&self.payloads, allocator, capacity);
        inline_resize.commitResized(&self.inline_cells, allocator, capacity * self.inline_words);
        long_resize.commitResized(&self.long_cells, allocator, long_count * self.long_block_words);
        free_long_resize.commitResized(&self.free_long_blocks, allocator, self.free_long_blocks.items.len);
        free_indices_resize.commitResized(&self.free_payload_indices, allocator, self.free_payload_indices.items.len);
        evict_scratch_resize.commit(&self.evict_scratch, allocator);
        self.evict_scratch.clearRetainingCapacity();
        for (old_capacity..@max(old_capacity, capacity)) |payload_index| {
            self.payloads.items[payload_index] = .{};
            self.free_payload_indices.appendAssumeCapacity(@intCast(payload_index));
        }
        self.long_block_count = long_count;

        // Rehash every live slot; payload indices are final.
        new_slots.items.len = physical;
        @memset(new_slots.items, .{});
        for (self.slots.items) |slot| {
            if (slot.occupied) insertRehashed(ProbeSlot, new_slots.items, slot);
        }
        self.slots.deinit(allocator);
        self.slots = new_slots;
        self.logical_capacity = capacity;
        self.next_evict = 0;
        std.debug.assert(self.free_payload_indices.items.len == capacity - self.len);
    }

    // Moves every live payload at index >= `capacity` into a free index below it (stripe
    // and long block reference move with it), leaving only low free indices. Runs after
    // the shrink's evictions, so the live entries fit below `capacity`.
    fn compactPayloads(self: *ResultCache, capacity: usize) void {
        retainBelow(&self.free_payload_indices, capacity);
        for (self.slots.items) |*slot| {
            if (!slot.occupied or slot.payload_index < capacity) continue;
            const target = self.free_payload_indices.pop().?; // live entries fit below capacity
            const payload = self.payloads.items[slot.payload_index];
            if (payload.long_block == no_block) {
                const words = types.storedPathWords(payload.path_len, payload.stitched_len);
                @memcpy(self.inlineStripe(target)[0..words], self.inlineStripe(slot.payload_index)[0..words]);
            }
            self.payloads.items[target] = payload;
            slot.payload_index = target;
        }
    }

    // Moves every live long block at index >= `long_count` (the live long entries) into a
    // free block below it, leaving no free blocks.
    fn compactLongBlocks(self: *ResultCache, long_count: usize) void {
        retainBelow(&self.free_long_blocks, long_count);
        for (self.slots.items) |slot| {
            if (!slot.occupied) continue;
            const payload = &self.payloads.items[slot.payload_index];
            if (payload.long_block == no_block or payload.long_block < long_count) continue;
            const target = self.free_long_blocks.pop().?; // live long entries fit below long_count
            const words = types.storedPathWords(payload.path_len, payload.stitched_len);
            @memcpy(self.longBlock(target)[0..words], self.longBlock(payload.long_block)[0..words]);
            payload.long_block = target;
        }
        std.debug.assert(self.free_long_blocks.items.len == 0);
    }

    /// The publish reserve, called with the step's long-result count before any `put`
    /// stores one: grows the long-block pool so every claim finds a free block, and never
    /// past `logical_capacity` blocks. Each entry holds at most one block and a `put`
    /// releases (its own, or an evicted victim's) before it claims, so live blocks never
    /// exceed the entry limit; min(live + needed, limit) blocks therefore suffice.
    /// Geometric (at least doubles, clamped to the limit); failure-atomic. Main thread.
    pub fn reserveLongBlocks(self: *ResultCache, allocator: std.mem.Allocator, needed: usize) !void {
        const old_count = self.long_block_count;
        const live = old_count - self.free_long_blocks.items.len;
        const required = @min(live +| needed, self.logical_capacity);
        if (old_count >= required) return;
        const new_count = @min(@max(required, old_count *| 2), self.logical_capacity);
        try self.long_cells.ensureTotalCapacity(allocator, new_count *| self.long_block_words);
        try self.free_long_blocks.ensureTotalCapacity(allocator, new_count);
        self.long_cells.items.len = new_count * self.long_block_words;
        // Pushed high to low so the lowest new block is claimed first.
        var block = new_count;
        while (block > old_count) {
            block -= 1;
            self.free_long_blocks.appendAssumeCapacity(@intCast(block)); // <= logical_capacity, a u32 payload width
        }
        self.long_block_count = new_count;
    }

    pub fn clear(self: *ResultCache) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        for (self.payloads.items) |*payload| payload.long_block = no_block;
        self.free_payload_indices.clearRetainingCapacity();
        for (0..self.logical_capacity) |payload_index| {
            self.free_payload_indices.appendAssumeCapacity(@intCast(payload_index));
        }
        self.free_long_blocks.clearRetainingCapacity();
        var block = self.long_block_count;
        while (block > 0) {
            block -= 1;
            self.free_long_blocks.appendAssumeCapacity(@intCast(block));
        }
        self.len = 0;
        self.next_evict = 0;
    }

    // Evicts only cached paths crossing a changed span; paths clear of the edited cells
    // survive and keep serving hits. Matches on the stored corridor (or plain) cells.
    // One read-only pass collects the crossing keys into pre-reserved scratch, then
    // removes them by key: back-shift relocation during removal can therefore never
    // skip or double-visit an entry, without restarting the scan per eviction.
    pub fn evictCrossing(self: *ResultCache, graph: *const NavGraph, spans: []const ChangedSpan) void {
        if (spans.len == 0) return;
        self.evict_scratch.clearRetainingCapacity();
        for (self.slots.items) |slot| {
            if (!slot.occupied) continue;
            if (self.crossesSpans(graph, slot.payload_index, spans)) {
                // At most len (<= logical_capacity) occupied slots exist, matching the
                // scratch reserve.
                self.evict_scratch.appendAssumeCapacity(slot.key);
            }
        }
        for (self.evict_scratch.items) |key| self.remove(key);
    }

    fn remove(self: *ResultCache, key: PathQueryKey) void {
        const index = self.slotIndex(key) orelse return;
        self.removeAt(index);
    }

    // Back-shift deletion for the open-addressed slot table. Clearing a slot in the middle
    // of a probe run would strand later keys behind the gap (lookups early-terminate on the
    // first truly-empty slot), so we pull up any following entry whose home position lets it
    // fill the hole. Only the small probe slot moves — its payload_index travels with it,
    // so the cold payload and cell stripes never move. Keeps every probe chain contiguous,
    // which is what the empty-slot probe early-out relies on.
    fn removeAt(self: *ResultCache, index: usize) void {
        const capacity = self.slots.items.len;
        self.releasePayload(self.slots.items[index].payload_index);
        self.slots.items[index].occupied = false;
        self.len -= 1;
        var hole = index;
        var probe = index;
        while (true) {
            probe = (probe + 1) % capacity;
            if (probe == index) break; // wrapped fully (also guards capacity == 1)
            const slot = self.slots.items[probe];
            if (!slot.occupied) break;
            const home = hashPathKey(slot.key) % capacity;
            // Keep the entry where it is when its home is cyclically within (hole, probe];
            // otherwise it can move up to fill the hole without becoming unreachable.
            if (inCyclicRange(hole, probe, home)) continue;
            self.slots.items[hole] = slot;
            self.slots.items[probe].occupied = false;
            hole = probe;
        }
    }

    // Returns a payload index (and its long block, if any) to the free lists.
    fn releasePayload(self: *ResultCache, payload_index: u32) void {
        self.releaseLongBlock(&self.payloads.items[payload_index]);
        self.free_payload_indices.appendAssumeCapacity(payload_index);
    }

    fn releaseLongBlock(self: *ResultCache, payload: *SlotPayload) void {
        if (payload.long_block == no_block) return;
        self.free_long_blocks.appendAssumeCapacity(payload.long_block);
        payload.long_block = no_block;
    }

    fn crossesSpans(self: *const ResultCache, graph: *const NavGraph, payload_index: usize, spans: []const ChangedSpan) bool {
        const payload = self.payloads.items[payload_index];
        const words = self.storedWords(payload_index);
        if (payload.stitched_len != 0) {
            for (types.stitchedCellsConst(words, payload.stitched_len)) |sc| {
                if (sc.cell != no_cell and cellInSpans(graph, sc.level, sc.cell, spans)) return true;
            }
            return false;
        }
        for (words[0..payload.path_len]) |cell| {
            if (cell != no_cell and cellInSpans(graph, payload.path_level, cell, spans)) return true;
        }
        return false;
    }

    fn inlineStripe(self: *ResultCache, payload_index: usize) []u32 {
        return self.inline_cells.items[payload_index * self.inline_words ..][0..self.inline_words];
    }

    fn longBlock(self: *ResultCache, block: usize) []u32 {
        return self.long_cells.items[block * self.long_block_words ..][0..self.long_block_words];
    }

    // The words holding a payload's stored path: its long block, else its inline stripe.
    fn storedWords(self: *const ResultCache, payload_index: usize) []const u32 {
        const block = self.payloads.items[payload_index].long_block;
        if (block != no_block) return self.long_cells.items[@as(usize, block) * self.long_block_words ..][0..self.long_block_words];
        return self.inline_cells.items[payload_index * self.inline_words ..][0..self.inline_words];
    }

    // `slot_index` is the PROBE slot index (as returned by slotIndex/freshSlotIndex),
    // not a payload index; both slices translate through the slot's payload_index so
    // callers never need to know the indirection exists.
    pub fn pathSlice(self: *const ResultCache, slot_index: usize, path_len: usize) []const u32 {
        return self.storedWords(self.slots.items[slot_index].payload_index)[0..path_len];
    }

    pub fn stitchedSlice(self: *const ResultCache, slot_index: usize, stitched_len: usize) []const StitchedCell {
        return types.stitchedCellsConst(self.storedWords(self.slots.items[slot_index].payload_index), stitched_len);
    }

    pub fn slotIndex(self: *const ResultCache, key: PathQueryKey) ?usize {
        const capacity = self.slots.items.len;
        if (capacity == 0) return null;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return index;
            // Physical capacity is 2x logical_capacity, so len never reaches capacity;
            // chains are contiguous (back-shift deletion), so the first empty slot ends
            // this key's chain whether present or absent.
            if (!slot.occupied) return null;
        }
        return null;
    }

    pub fn find(self: *const ResultCache, key: PathQueryKey) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        return self.resultAt(index);
    }

    // Non-mutating freshness gate for the per-frame read path (statusForWorld): returns the
    // slot only when it is within `ttl`. A const reader cannot evict, so a stale entry simply
    // reads as a miss here and the caller re-requests; acceptRequests' findFresh does the
    // actual eviction. Without this, an agent that only polls statusForWorld (never enqueues)
    // is served a path older than the TTL forever. ttl 0 disables expiry.
    pub fn freshSlotIndex(self: *const ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?usize {
        const found = self.lookup(key, step, ttl) orelse return null;
        return if (found.fresh) found.slot else null;
    }

    pub const SlotLookup = struct {
        slot: usize,
        fresh: bool,
    };

    /// The key's slot and whether its result is within `ttl` at `step`, from one probe;
    /// null when absent. ttl 0 disables expiry. Const: never evicts.
    pub fn lookup(self: *const ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?SlotLookup {
        const index = self.slotIndex(key) orelse return null;
        const payload_index = self.slots.items[index].payload_index;
        return .{ .slot = index, .fresh = ttl == 0 or (step -% self.payloads.items[payload_index].stamp) < ttl };
    }

    // find, but a result older than `ttl` steps is dropped (returns null) so the caller
    // re-solves it against current geometry. ttl 0 disables expiry.
    pub fn findFresh(self: *ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        const payload_index = self.slots.items[index].payload_index;
        if (ttl != 0 and (step -% self.payloads.items[payload_index].stamp) >= ttl) {
            self.removeAt(index);
            return null;
        }
        return self.resultAt(index);
    }

    /// Stores a result exactly: a plain local-solve path (start-to-goal cell order) on
    /// `path_level`, or a full stitched (level,cell) corridor path, never both. A result
    /// past the inline stripe takes a long block, which `reserveLongBlocks` must have made
    /// free; re-putting a key releases its previous block. Allocates nothing.
    pub fn put(self: *ResultCache, key: PathQueryKey, path: []const u32, stitched: []const StitchedCell, path_level: u16, step: u32, stats: *PathfindingStats) void {
        if (self.logical_capacity == 0 or self.inline_words == 0) return;
        std.debug.assert(path.len == 0 or stitched.len == 0);
        const words = types.storedPathWords(path.len, stitched.len);
        const slot_index = self.findOrEvictSlot(key, stats);
        const payload_index = self.slots.items[slot_index].payload_index;
        const payload = &self.payloads.items[payload_index];
        self.releaseLongBlock(payload);
        var long_block = no_block;
        const dst = if (words <= self.inline_words) self.inlineStripe(payload_index) else long: {
            // The solve bounds a result at one long block; the publish reserve freed a block.
            std.debug.assert(words <= self.long_block_words);
            std.debug.assert(self.free_long_blocks.items.len != 0);
            long_block = self.free_long_blocks.pop().?;
            break :long self.longBlock(long_block);
        };
        if (stitched.len != 0) {
            @memcpy(types.stitchedCells(dst, stitched.len), stitched);
        } else {
            @memcpy(dst[0..path.len], path);
        }
        payload.* = .{
            .stamp = step,
            .path_len = @intCast(path.len), // bounded by the solve's node budget
            .stitched_len = @intCast(stitched.len), // bounded by max_stitched_path_cells
            .long_block = long_block,
            .path_level = path_level,
        };
    }

    // Finds key's existing probe slot, or claims/evicts one and assigns it a payload_index
    // (leaving the payload contents for the caller to overwrite). Returns the PROBE slot
    // index, not the payload index.
    fn findOrEvictSlot(self: *ResultCache, key: PathQueryKey, stats: *PathfindingStats) usize {
        const capacity = self.slots.items.len;
        std.debug.assert(capacity != 0); // callers guard this; assert before `% capacity`
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return index;
            if (!slot.occupied) {
                if (self.len < self.logical_capacity) {
                    const payload_index = self.free_payload_indices.pop().?;
                    self.slots.items[index] = .{ .occupied = true, .key = key, .payload_index = payload_index };
                    self.len += 1;
                    return index;
                }
                // Logically full (every payload slot owned): evict a round-robin victim —
                // skipping empty physical slots, since occupancy is sparse — to free a
                // payload_index, then probe again. The victim may sit in this key's chain,
                // where back-shift can leave the hole ahead of `index`, so the key goes in
                // the first empty slot of the re-probed chain, never at the stale `index`.
                while (!self.slots.items[self.next_evict].occupied) {
                    self.next_evict = (self.next_evict + 1) % capacity;
                }
                const victim = self.next_evict;
                self.next_evict = (self.next_evict + 1) % capacity;
                stats.cache_evictions += 1;
                self.removeAt(victim);
                std.debug.assert(self.len < self.logical_capacity);
                return self.findOrEvictSlot(key, stats);
            }
        }
        unreachable; // physical capacity is 2x logical_capacity; an empty slot always exists
    }
};

const no_block: u32 = std.math.maxInt(u32);

// A live entry's eviction rank for a shrink: greatest age (steps since its stamp, wrapping
// like the TTL check) first, payload index breaking ties.
const EntryAge = struct {
    age: u32,
    payload_index: u32,
    slot_index: usize,

    fn olderThan(_: void, lhs: EntryAge, rhs: EntryAge) bool {
        if (lhs.age != rhs.age) return lhs.age > rhs.age;
        return lhs.payload_index < rhs.payload_index;
    }
};

// Probe-hot slot: the fields a linear-probe scan touches (occupancy + key), plus the
// indirection to this entry's payload/cell-stripe slot in the logical-capacity arrays.
pub const ProbeSlot = struct {
    occupied: bool = false,
    key: PathQueryKey = emptyKey(0),
    payload_index: u32 = 0,
};

// Cold per-slot payload, parallel to ProbeSlot. Read only on a hit / TTL check, so it
// is kept off the probe-scan cache lines. Four u32s, then the u16: 20 bytes.
pub const SlotPayload = struct {
    // step_counter when the entry was written, for TTL refresh.
    stamp: u32 = 0,
    path_len: u32 = 0,
    stitched_len: u32 = 0,
    // The long block holding the path, or no_block when it sits in the inline stripe.
    long_block: u32 = no_block,
    path_level: u16 = 0,
};

// Inserts a live slot into a rebuilt probe table at the first empty slot of its chain.
fn insertRehashed(comptime Slot: type, slots: []Slot, slot: Slot) void {
    std.debug.assert(slots.len != 0);
    var index = hashPathKey(slot.key) % slots.len;
    while (slots[index].occupied) index = (index + 1) % slots.len;
    slots[index] = slot;
}

// Keeps, in order, only the free indices below `limit`.
fn retainBelow(free: *std.ArrayList(u32), limit: usize) void {
    var kept: usize = 0;
    for (free.items) |index| {
        if (index >= limit) continue;
        free.items[kept] = index;
        kept += 1;
    }
    free.items.len = kept;
}

// Whether `x` lies in the cyclic half-open-then-closed interval (start, end] on a ring of
// the table's capacity. Used by back-shift deletion to decide if a probed entry must stay.
fn inCyclicRange(start: usize, end: usize, x: usize) bool {
    if (start < end) return x > start and x <= end;
    return x > start or x <= end;
}

// Whether nav cell (level, cell) falls inside any changed span on its level.
fn cellInSpans(graph: *const NavGraph, level: u16, cell: u32, spans: []const ChangedSpan) bool {
    const grid = graph.grid(level) orelse return false;
    const cx: usize = cell % grid.width;
    const cy: usize = cell / grid.width;
    for (spans) |s| {
        if (s.level != level) continue;
        if (cx >= s.span.min_x and cx <= s.span.max_x and cy >= s.span.min_y and cy <= s.span.max_y) return true;
    }
    return false;
}

// Per-agent waypoint derivation against a cached path. This is the per-step,
// per-entity refinement promised by the goal-keyed cache.
pub fn waypointFromPath(grid: *const NavGrid, path: []const u32, start_index: usize, hint: ?*u32) ?math.Vec2 {
    if (path.len == 0) return null;
    if (path.len == 1) return grid.cellCenter(path[0]);
    // Hinted fast path: probe a small forward window from last step's match before the
    // full scan. A cell appears at most once on an A* path, so a window hit is the unique
    // occurrence and a stale hint can only miss (never mis-step), falling back to the scan.
    if (hint) |h| {
        const from = @min(@as(usize, h.*), path.len - 1);
        const to = @min(from + waypoint_hint_window, path.len);
        for (from..to) |i| {
            if (path[i] == start_index) return waypointAt(grid, path, i, hint);
        }
    }
    if (exactCellIndex(path, @intCast(start_index))) |index| return waypointAt(grid, path, index, hint); // cell indices are u32
    // Off path: head from the nearest cell. Scalar: the cell -> (x, y) split is an
    // integer division per cell, which simd.zig has no vector form of.
    const start_x: i32 = @intCast(start_index % grid.width);
    const start_y: i32 = @intCast(start_index / grid.width);
    var best_index: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    for (path, 0..) |cell, i| {
        const cx: i32 = @intCast(cell % grid.width);
        const cy: i32 = @intCast(cell / grid.width);
        const ddx: i64 = cx - start_x;
        const ddy: i64 = cy - start_y;
        const dist = ddx * ddx + ddy * ddy;
        if (dist < best_dist) {
            best_dist = dist;
            best_index = i;
        }
    }
    return waypointAt(grid, path, best_index, hint);
}

// First index of `cell` in `cells`: four lanes per compare, then a scalar tail.
fn exactCellIndex(cells: []const u32, cell: u32) ?usize {
    const needle = simd.splatUint4(cell);
    const vector_end = simd.vectorizedEnd(cells.len);
    var index: usize = 0;
    while (index < vector_end) : (index += simd.lane_count) {
        const matches = simd.equalUint4(simd.loadUint4(cells[index..]), needle);
        if (simd.countTrue(matches) == 0) continue;
        inline for (0..simd.lane_count) |lane| {
            if (matches[lane]) return index + lane;
        }
    }
    for (vector_end..cells.len) |tail| {
        if (cells[tail] == cell) return tail;
    }
    return null;
}

// Records the matched/nearest index in the hint and returns the heading to its successor
// (or the cell itself at the path end), shared by the hinted and full-scan branches.
fn waypointAt(grid: *const NavGrid, path: []const u32, index: usize, hint: ?*u32) math.Vec2 {
    if (hint) |h| h.* = @intCast(index);
    const next = if (index + 1 < path.len) index + 1 else index;
    return grid.cellCenter(path[next]);
}

// Per-agent waypoint derivation against a stitched cross-chunk/cross-level corridor
// path. The stitched path is a single obstacle-aware (level,cell) sequence; within
// each level its cells are grid-adjacent (the level changes only across a link). The
// agent's forward waypoint is found by walking the contiguous run of cells on the
// agent's CURRENT level with the exact same cell-by-cell logic as a plain A* path,
// so the heading is always to a traversable neighbor — never a straight-line cut
// across a blocked cell. Returns null when the agent's level has no run in the path
// (a cross-level agent has not yet reached a level the corridor covers).
pub fn waypointFromStitched(graph: *const NavGraph, stitched: []const StitchedCell, start_level: u16, start_index: usize, hint: ?*u32) ?math.Vec2 {
    const start_grid = graph.grid(start_level) orelse return null;
    // Hinted fast path: probe a forward window for an exact cell match on the agent's
    // level before the full run scan. A cell appears at most once per level run, so a hit
    // is unambiguous; a stale hint only misses and falls back to the scan.
    if (hint) |h| {
        const from = @min(@as(usize, h.*), stitched.len -| 1);
        const to = @min(from + waypoint_hint_window, stitched.len);
        for (from..to) |j| {
            if (stitched[j].level == start_level and stitched[j].cell == start_index) {
                return stitchedWaypointAt(start_grid, stitched, start_level, j, hint);
            }
        }
    }
    // Scan the path's contiguous runs on the agent's level. An exact match (the agent
    // is on a path cell) walks to that cell's successor within the run. Otherwise fall
    // back to the run holding the nearest cell on this level and walk from there.
    // Single pass: an exact cell match returns immediately; otherwise nearest_index is
    // tracked alongside best_dist so the off-path branch needs no second scan.
    var i: usize = 0;
    var nearest_index: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    var found_run = false;
    const start_x: i32 = @intCast(start_index % start_grid.width);
    const start_y: i32 = @intCast(start_index / start_grid.width);
    while (i < stitched.len) {
        if (stitched[i].level != start_level) {
            i += 1;
            continue;
        }
        const run_begin = i;
        while (i < stitched.len and stitched[i].level == start_level) : (i += 1) {}
        const run_end = i; // exclusive
        for (run_begin..run_end) |j| {
            if (stitched[j].cell == start_index) {
                return stitchedWaypointAt(start_grid, stitched, start_level, j, hint);
            }
            const cx: i32 = @intCast(stitched[j].cell % start_grid.width);
            const cy: i32 = @intCast(stitched[j].cell / start_grid.width);
            const ddx: i64 = cx - start_x;
            const ddy: i64 = cy - start_y;
            const dist = ddx * ddx + ddy * ddy;
            if (dist < best_dist) {
                best_dist = dist;
                nearest_index = j;
                found_run = true;
            }
        }
    }
    if (!found_run) return null;
    // Off-path on this level: head toward the nearest run cell's successor tracked above.
    // The run is grid-adjacent, so the successor is one traversable step from nearest.
    return stitchedWaypointAt(start_grid, stitched, start_level, nearest_index, hint);
}

// Records the matched/nearest stitched index in the hint and returns the heading to its
// successor within the same-level run (or the cell itself at the run's end). The run is
// grid-adjacent, so the successor is always one traversable step.
fn stitchedWaypointAt(grid: *const NavGrid, stitched: []const StitchedCell, level: u16, j: usize, hint: ?*u32) math.Vec2 {
    if (hint) |h| h.* = @intCast(j);
    const next = if (j + 1 < stitched.len and stitched[j + 1].level == level) j + 1 else j;
    return grid.cellCenter(stitched[next].cell);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "pathfinding waypoint hint matches full scan and recovers from a stale hint" {
    const grid = NavGrid{ .width = 100, .height = 1, .cell_size = 1 };
    const path = [_]u32{ 10, 11, 12, 13, 14, 15 };

    // Baseline: agent on cell 12 heads to its successor 13.
    const baseline = waypointFromPath(&grid, &path, 12, null).?;
    try std.testing.expectEqual(grid.cellCenter(13).x, baseline.x);

    // A hint pointing near the match takes the windowed fast path and records the index.
    var fresh: u32 = 1;
    const hinted = waypointFromPath(&grid, &path, 12, &fresh).?;
    try std.testing.expectEqual(baseline.x, hinted.x);
    try std.testing.expectEqual(@as(u32, 2), fresh); // index of cell 12

    // An out-of-range/stale hint misses the window, falls back to the full scan, and is
    // repaired to the real index — same waypoint, never a mis-step.
    var stale: u32 = 999;
    const recovered = waypointFromPath(&grid, &path, 12, &stale).?;
    try std.testing.expectEqual(baseline.x, recovered.x);
    try std.testing.expectEqual(@as(u32, 2), stale);
}

test "pathfinding fixed-capacity unavailable key set has explicit fixed capacity" {
    var keys = KeySet{};
    defer keys.deinit(std.testing.allocator);
    try keys.reserve(std.testing.allocator, 1);
    var first_key = emptyKey(1);
    first_key.goal.x = 1;
    var second_key = emptyKey(1);
    second_key.goal.x = 2;

    try std.testing.expect(keys.insert(first_key));
    try std.testing.expect(keys.contains(first_key));
    try std.testing.expect(!keys.insert(second_key));
    try std.testing.expect(keys.contains(first_key));
    try std.testing.expect(!keys.contains(second_key));
}

fn testGoalKey(x: usize) PathQueryKey {
    var key = emptyKey(1);
    key.goal.x = @intCast(x);
    return key;
}

test "pathfinding key set shrink OOM keeps the table and its entries (FailingAllocator)" {
    var keys = KeySet{};
    defer keys.deinit(std.testing.allocator);
    try keys.reserve(std.testing.allocator, 64);
    for (0..8) |i| try std.testing.expect(keys.insert(testGoalKey(i)));

    // A shrink to 4 allocates its replacement first; failing that allocation must leave
    // the old 64-entry table in place (a free-then-reallocate left zero slots behind a
    // logical limit of 64).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, keys.reserve(failing.allocator(), 4));
    try std.testing.expect(failing.has_induced_failure);

    try std.testing.expectEqual(@as(usize, 64), keys.table.logical_capacity);
    try std.testing.expectEqual(@as(usize, 128), keys.table.slots.items.len);
    try std.testing.expect(keys.table.slots.capacity >= 2 * keys.table.logical_capacity);
    for (0..8) |i| try std.testing.expect(keys.contains(testGoalKey(i)));
    try std.testing.expect(keys.insert(testGoalKey(100)));

    // The same shrink succeeds once memory is available, and actually frees.
    try keys.reserve(std.testing.allocator, 4);
    try std.testing.expectEqual(@as(usize, 4), keys.table.logical_capacity);
    try std.testing.expectEqual(@as(usize, 8), keys.table.slots.items.len);
    try std.testing.expect(keys.table.slots.capacity < 128);
}

test "pathfinding key set resize keeps its entries" {
    var keys = KeySet{};
    defer keys.deinit(std.testing.allocator);
    try keys.reserve(std.testing.allocator, 8);
    for (0..6) |i| try std.testing.expect(keys.insert(testGoalKey(i)));

    // A grow rehashes every entry into the larger table.
    try keys.reserve(std.testing.allocator, 64);
    try std.testing.expectEqual(@as(usize, 6), keys.table.len);
    for (0..6) |i| try std.testing.expect(keys.contains(testGoalKey(i)));
    for (6..40) |i| try std.testing.expect(keys.insert(testGoalKey(i)));

    // A shrink keeps as many entries as fit, each still reachable.
    try keys.reserve(std.testing.allocator, 4);
    try std.testing.expectEqual(@as(usize, 4), keys.table.len);
    var kept: usize = 0;
    for (0..40) |i| {
        if (keys.contains(testGoalKey(i))) kept += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), kept);
    try std.testing.expect(!keys.insert(testGoalKey(1000)));
}

const no_test_block = std.math.maxInt(u32);

/// Invariants every `ResultCache` state must hold: physical lists cover the logical limit
/// at the committed widths, every live entry owns a distinct payload below the limit and
/// at most one long block, and the free lists hold exactly the rest.
fn expectResultCacheConsistent(cache: *const ResultCache) !void {
    const logical = cache.logical_capacity;
    try std.testing.expectEqual(2 * logical, cache.slots.items.len);
    try std.testing.expectEqual(logical, cache.payloads.items.len);
    try std.testing.expectEqual(logical * cache.inline_words, cache.inline_cells.items.len);
    try std.testing.expectEqual(cache.long_block_count * cache.long_block_words, cache.long_cells.items.len);
    try std.testing.expect(cache.free_payload_indices.capacity >= logical);
    try std.testing.expect(cache.free_long_blocks.capacity >= cache.long_block_count);
    try std.testing.expect(cache.evict_scratch.capacity >= logical);
    try std.testing.expectEqual(logical - cache.len, cache.free_payload_indices.items.len);
    var live: usize = 0;
    var live_long: usize = 0;
    for (cache.slots.items) |slot| {
        if (!slot.occupied) continue;
        live += 1;
        try std.testing.expect(slot.payload_index < logical);
        const block = cache.payloads.items[slot.payload_index].long_block;
        if (block != no_test_block) {
            live_long += 1;
            try std.testing.expect(block < cache.long_block_count);
        }
    }
    try std.testing.expectEqual(cache.len, live);
    try std.testing.expectEqual(cache.long_block_count - live_long, cache.free_long_blocks.items.len);
}

// Test entries for a cache reserved with 4-word stripes and 16-word long blocks. Entry
// `index` cycles through: a 3-cell plain path (inline), a 10-cell plain path (long), a
// 2-cell stitched path (4 words, inline), and a 5-cell stitched path (10 words, long).
const test_inline_words = 4;
const test_long_block_words = 16;

fn testEntryIsLong(index: usize) bool {
    return index % 2 == 1;
}

fn testEntryCell(index: usize, offset: usize) u32 {
    return @intCast(index * 100 + offset);
}

fn putTestEntry(cache: *ResultCache, index: usize, step: u32, stats: *PathfindingStats) void {
    var plain: [10]u32 = undefined;
    var stitched: [5]StitchedCell = undefined;
    for (&plain, 0..) |*cell, offset| cell.* = testEntryCell(index, offset);
    for (&stitched, 0..) |*cell, offset| cell.* = .{ .level = @intCast(index % 3), .cell = testEntryCell(index, offset) };
    switch (index % 4) {
        0 => cache.put(testGoalKey(index), plain[0..3], &.{}, 0, step, stats),
        1 => cache.put(testGoalKey(index), plain[0..10], &.{}, 0, step, stats),
        2 => cache.put(testGoalKey(index), &.{}, stitched[0..2], 0, step, stats),
        else => cache.put(testGoalKey(index), &.{}, stitched[0..5], 0, step, stats),
    }
}

fn expectTestEntry(cache: *const ResultCache, index: usize) !void {
    const slot = cache.slotIndex(testGoalKey(index)) orelse return error.TestExpectedEntry;
    const result = cache.resultAt(slot);
    switch (index % 4) {
        0, 1 => {
            const len: usize = if (index % 4 == 0) 3 else 10;
            try std.testing.expectEqual(@as(u32, 0), result.stitched_len);
            const stored = cache.pathSlice(slot, result.path_len);
            try std.testing.expectEqual(len, stored.len);
            for (stored, 0..) |cell, offset| try std.testing.expectEqual(testEntryCell(index, offset), cell);
        },
        else => {
            const len: usize = if (index % 4 == 2) 2 else 5;
            try std.testing.expectEqual(@as(u32, 0), result.path_len);
            const stored = cache.stitchedSlice(slot, result.stitched_len);
            try std.testing.expectEqual(len, stored.len);
            for (stored, 0..) |cell, offset| {
                try std.testing.expectEqual(@as(u16, @intCast(index % 3)), cell.level);
                try std.testing.expectEqual(testEntryCell(index, offset), cell.cell);
            }
        },
    }
}

// A 16-entry cache holding entries 0..count at steps 0..count, long blocks reserved.
fn filledTestCache(cache: *ResultCache, count: usize, stats: *PathfindingStats) !void {
    try cache.reserve(std.testing.allocator, 16, test_inline_words, test_long_block_words, 0);
    try cache.reserveLongBlocks(std.testing.allocator, count);
    for (0..count) |index| putTestEntry(cache, index, @intCast(index), stats);
}

test "pathfinding result cache stores a long path whole in a long block and never evicts for long-pool space" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 8, test_inline_words, test_long_block_words, 0);

    // One free block: the first long entry takes it; inline entries need none.
    try cache.reserveLongBlocks(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.long_block_count);
    for (0..3) |index| putTestEntry(&cache, index, 0, &stats);
    try std.testing.expectEqual(@as(usize, 0), cache.free_long_blocks.items.len);

    // The pool is exhausted: the publish reserve grows it instead of evicting a live entry.
    try cache.reserveLongBlocks(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(usize, 2), cache.long_block_count);
    putTestEntry(&cache, 3, 0, &stats);
    try std.testing.expectEqual(@as(usize, 0), stats.cache_evictions);
    for (0..4) |index| try expectTestEntry(&cache, index);
    try expectResultCacheConsistent(&cache);

    // Re-putting a long key with an inline path releases its block; a TTL removal of
    // the other long entry releases its block too.
    cache.put(testGoalKey(1), &.{ 7, 8 }, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), cache.free_long_blocks.items.len);
    try std.testing.expect(cache.findFresh(testGoalKey(3), 1000, 10) == null);
    try std.testing.expectEqual(@as(usize, 2), cache.free_long_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), cache.long_block_count);
    try expectResultCacheConsistent(&cache);
}

test "pathfinding result cache long pool never exceeds the entry limit, and a full cache of long entries still publishes" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4, test_inline_words, test_long_block_words, 0);
    // Four live long entries (odd indices are long) fill the cache and the pool.
    try cache.reserveLongBlocks(std.testing.allocator, 4);
    for ([_]usize{ 1, 3, 5, 7 }) |index| putTestEntry(&cache, index, 0, &stats);
    try std.testing.expectEqual(@as(usize, 4), cache.long_block_count);
    try std.testing.expectEqual(@as(usize, 0), cache.free_long_blocks.items.len);

    // Three more long results: the pool stays at the limit; each put evicts a long victim
    // before it claims, so every claim finds a block.
    try cache.reserveLongBlocks(std.testing.allocator, 3);
    try std.testing.expectEqual(@as(usize, 4), cache.long_block_count);
    for ([_]usize{ 9, 11, 13 }) |index| putTestEntry(&cache, index, 1, &stats);
    try std.testing.expectEqual(@as(usize, 3), stats.cache_evictions);
    for ([_]usize{ 9, 11, 13 }) |index| try expectTestEntry(&cache, index);
    try std.testing.expectEqual(@as(usize, 4), cache.long_block_count);
    try expectResultCacheConsistent(&cache);
}

test "pathfinding result cache grow and shrink keep entries, evicting oldest first" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try filledTestCache(&cache, 12, &stats);

    // A grow keeps every entry and its stored cells.
    try cache.reserve(std.testing.allocator, 64, test_inline_words, test_long_block_words, 12);
    try std.testing.expectEqual(@as(usize, 12), cache.len);
    for (0..12) |index| try expectTestEntry(&cache, index);
    try expectResultCacheConsistent(&cache);

    // A shrink to 4 evicts the eight oldest (steps 0..7), moves the survivors below the
    // new limit, and compacts the long pool to their two long entries.
    try cache.reserve(std.testing.allocator, 4, test_inline_words, test_long_block_words, 12);
    try std.testing.expectEqual(@as(usize, 4), cache.len);
    for (0..8) |index| try std.testing.expect(cache.find(testGoalKey(index)) == null);
    for (8..12) |index| try expectTestEntry(&cache, index);
    try std.testing.expectEqual(@as(usize, 2), cache.long_block_count);
    try expectResultCacheConsistent(&cache);

    // Equal stamps evict in payload-index order.
    var tied = ResultCache{};
    defer tied.deinit(std.testing.allocator);
    try tied.reserve(std.testing.allocator, 4, test_inline_words, test_long_block_words, 0);
    for (0..4) |index| putTestEntry(&tied, index * 4, 9, &stats);
    var lowest_index: usize = 0;
    for (0..4) |index| {
        const payload_index = tied.slots.items[tied.slotIndex(testGoalKey(index * 4)).?].payload_index;
        if (payload_index == 0) lowest_index = index * 4;
    }
    try tied.reserve(std.testing.allocator, 3, test_inline_words, test_long_block_words, 9);
    for (0..4) |index| {
        if (index * 4 == lowest_index) {
            try std.testing.expect(tied.find(testGoalKey(index * 4)) == null);
        } else {
            try expectTestEntry(&tied, index * 4);
        }
    }
    try expectResultCacheConsistent(&tied);

    // Age wraps with the step counter: a stamp just below the wrap is older than one after it.
    var wrapped = ResultCache{};
    defer wrapped.deinit(std.testing.allocator);
    try wrapped.reserve(std.testing.allocator, 2, test_inline_words, test_long_block_words, 0);
    putTestEntry(&wrapped, 0, std.math.maxInt(u32) - 2, &stats);
    putTestEntry(&wrapped, 4, 3, &stats);
    try wrapped.reserve(std.testing.allocator, 1, test_inline_words, test_long_block_words, 5);
    try std.testing.expect(wrapped.find(testGoalKey(0)) == null);
    try expectTestEntry(&wrapped, 4);
}

test "pathfinding result cache resize runs out of memory at every allocation and leaves entries intact (FailingAllocator)" {
    // Shrink with eviction (16 -> 2), shrink without (16 -> 8), and grow (16 -> 64): each
    // allocation the resize makes is failed in turn. A failure leaves the cache whole
    // (limit, widths, every entry and its cells); success keeps the entries that fit.
    const entry_count = 6;
    for ([_]usize{ 2, 8, 64 }) |target| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var stats = PathfindingStats{};
            var cache = ResultCache{};
            defer cache.deinit(std.testing.allocator);
            try filledTestCache(&cache, entry_count, &stats);

            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
            cache.reserve(failing.allocator(), target, test_inline_words, test_long_block_words, entry_count) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(@as(usize, 16), cache.logical_capacity);
                try std.testing.expectEqual(@as(usize, test_inline_words), cache.inline_words);
                try std.testing.expectEqual(@as(usize, test_long_block_words), cache.long_block_words);
                try expectResultCacheConsistent(&cache);
                for (0..entry_count) |index| try expectTestEntry(&cache, index);
                // Still fully usable at the old limit.
                for (0..16) |index| cache.put(testGoalKey(100 + index), &.{1}, &.{}, 0, 0, &stats);
                try expectResultCacheConsistent(&cache);
                continue;
            };
            try std.testing.expectEqual(target, cache.logical_capacity);
            try expectResultCacheConsistent(&cache);
            const kept = @min(target, entry_count);
            try std.testing.expectEqual(kept, cache.len);
            for (entry_count - kept..entry_count) |index| try expectTestEntry(&cache, index);
            break;
        }
        try std.testing.expect(fail_index >= 1);
    }
}

test "pathfinding waypoint exact-match scan in four lanes equals the scalar scan (match in body, tail, absent)" {
    var cells: [11]u32 = undefined;
    for (&cells, 0..) |*cell, index| cell.* = @intCast(500 + index * 3);
    // Lengths 0..11 put every match in the vector body or a 0-3 cell tail.
    for (0..cells.len + 1) |len| {
        const path = cells[0..len];
        for (path) |cell| try std.testing.expectEqual(std.mem.indexOfScalar(u32, path, cell), exactCellIndex(path, cell));
        try std.testing.expectEqual(@as(?usize, null), exactCellIndex(path, 7));
    }
    // A repeated cell resolves to its first index, as the scalar scan does.
    const repeated = [_]u32{ 1, 2, 9, 4, 5, 9, 9, 8, 9 };
    try std.testing.expectEqual(@as(?usize, 2), exactCellIndex(&repeated, 9));

    // Through the waypoint derivation: a match in the body and in the tail heads to the
    // successor; an off-path start heads from the nearest cell.
    const grid = NavGrid{ .width = 100, .height = 100, .cell_size = 1 };
    const path = [_]u32{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 };
    try std.testing.expectEqual(grid.cellCenter(14).x, waypointFromPath(&grid, &path, 13, null).?.x);
    try std.testing.expectEqual(grid.cellCenter(19).x, waypointFromPath(&grid, &path, 18, null).?.x);
    var hint: u32 = 0;
    const off_path = waypointFromPath(&grid, &path, 116, &hint).?; // (16, 1): nearest is cell 16
    try std.testing.expectEqual(grid.cellCenter(17).x, off_path.x);
    try std.testing.expectEqual(@as(u32, 6), hint);
}

test "pathfinding result cache keeps probe chains intact after mid-chain removal" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const capacity = 8;
    try cache.reserve(std.testing.allocator, capacity, 4, 8, 0);

    // Fill the cache to capacity with distinct goal-keyed entries (no eviction yet).
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        cache.put(key, &.{ @intCast(i), @intCast(i + 1) }, &.{}, 0, 0, &stats);
    }
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        try std.testing.expect(cache.find(key) != null);
    }

    // Remove two entries that may sit mid-probe-chain. Without back-shift deletion a later
    // key in a cluster would become unreachable; every surviving key must still be found.
    for ([_]usize{ 2, 5 }) |target| {
        var key = emptyKey(1);
        key.goal.x = @intCast(target);
        const index = cache.slotIndex(key).?;
        cache.removeAt(index);
    }
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        if (i == 2 or i == 5) {
            try std.testing.expect(cache.find(key) == null);
        } else {
            try std.testing.expect(cache.find(key) != null);
        }
    }
}

// The first test goal key whose home slot in a `physical`-slot probe table is `home`,
// skipping keys already taken.
fn testKeyWithHome(physical: usize, home: usize, taken: []const usize) usize {
    var x: usize = 0;
    while (true) : (x += 1) {
        if (std.mem.indexOfScalar(usize, taken, x) != null) continue;
        if (hashPathKey(testGoalKey(x)) % physical == home) return x;
    }
}

test "pathfinding result cache full-cache put stays reachable when the evicted victim sits in its probe chain" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4, 4, 8, 0);
    // A at its home slot 0, B at its home slot 1, C and D clear of slots 0-2: the round-robin
    // victim is A, and the new key K (home 0) first finds slot 2 empty.
    var taken: [5]usize = undefined;
    taken[0] = testKeyWithHome(8, 0, taken[0..0]);
    taken[1] = testKeyWithHome(8, 1, taken[0..1]);
    taken[2] = testKeyWithHome(8, 4, taken[0..2]);
    taken[3] = testKeyWithHome(8, 5, taken[0..3]);
    taken[4] = testKeyWithHome(8, 0, taken[0..4]);
    for (taken[0..4]) |x| cache.put(testGoalKey(x), &.{1}, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 0), cache.slotIndex(testGoalKey(taken[0])).?);
    try std.testing.expectEqual(@as(usize, 1), cache.slotIndex(testGoalKey(taken[1])).?);

    const new_key = testGoalKey(taken[4]);
    cache.put(new_key, &.{2}, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.slotIndex(new_key) != null);

    // A re-put updates the one slot holding the key, never a duplicate.
    cache.put(new_key, &.{3}, &.{}, 0, 0, &stats);
    var holders: usize = 0;
    for (cache.slots.items) |slot| {
        if (slot.occupied and keysEqual(slot.key, new_key)) holders += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), holders);
    try std.testing.expectEqual(@as(usize, 4), cache.len);
    try expectResultCacheConsistent(&cache);
}

test "pathfinding result cache read-path TTL gate is non-mutating and expires stale entries" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4, 4, 8, 0);
    var key = emptyKey(1);
    key.goal.x = 3;
    cache.put(key, &.{ 0, 1, 2 }, &.{}, 0, 100, &stats); // stamped at step 100

    const ttl: u32 = 50;
    // Within ttl: the read path serves the slot and never evicts (const reader).
    try std.testing.expect(cache.freshSlotIndex(key, 149, ttl) != null);
    try std.testing.expect(cache.slotIndex(key) != null); // still resident
    // At/after ttl: the read path reports a miss so the caller re-requests, but the entry
    // is left in place for acceptRequests' mutating findFresh to evict.
    try std.testing.expect(cache.freshSlotIndex(key, 150, ttl) == null);
    try std.testing.expect(cache.slotIndex(key) != null);
    // ttl 0 disables expiry.
    try std.testing.expect(cache.freshSlotIndex(key, 100_000, 0) != null);
}

test "pathfinding result cache evicts deterministically and stores paths" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 1, 4, 8, 0);
    var first_key = emptyKey(1);
    first_key.goal.x = 1;
    var second_key = emptyKey(1);
    second_key.goal.x = 2;

    cache.put(first_key, &.{ 0, 1, 2 }, &.{}, 0, 0, &stats);
    try std.testing.expect(cache.find(first_key) != null);
    cache.put(second_key, &.{ 3, 4 }, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.find(first_key) == null);
    const slot = cache.slotIndex(second_key).?;
    const stored = cache.pathSlice(slot, cache.resultAt(slot).path_len);
    try std.testing.expectEqual(@as(usize, 2), stored.len);
    try std.testing.expectEqual(@as(u32, 3), stored[0]);
}

test "pathfinding result cache stays correct at full logical occupancy" {
    // Every absent-key probe on a full table must still terminate (the physical table is
    // never more than 50% occupied), and inserting past logical capacity must still evict
    // exactly one entry via the round-robin victim rather than corrupting the table.
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const capacity = 8;
    try cache.reserve(std.testing.allocator, capacity, 4, 8, 0);

    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        cache.put(key, &.{@intCast(i)}, &.{}, 0, 0, &stats);
    }
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        try std.testing.expect(cache.find(key) != null);
    }
    // An absent key (never inserted) must resolve to a miss, not loop or misread a
    // neighboring slot's payload.
    var absent = emptyKey(1);
    absent.goal.x = capacity + 100;
    try std.testing.expect(cache.find(absent) == null);

    // One more insert past logical capacity evicts exactly one victim; every other key
    // stays resolvable.
    var overflow_key = emptyKey(1);
    overflow_key.goal.x = capacity;
    cache.put(overflow_key, &.{99}, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.find(overflow_key) != null);
    var survivors: usize = 0;
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        if (cache.find(key) != null) survivors += 1;
    }
    try std.testing.expectEqual(capacity - 1, survivors);
}

test "pathfinding fixed-capacity key set stays correct at full logical occupancy" {
    var keys = KeySet{};
    defer keys.deinit(std.testing.allocator);
    const capacity = 8;
    try keys.reserve(std.testing.allocator, capacity);

    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        try std.testing.expect(keys.insert(key));
    }
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        try std.testing.expect(keys.contains(key));
    }
    // A logically-full set rejects a new key (no eviction: KeySet is fixed-capacity,
    // unlike ResultCache) but every absent-key probe still terminates.
    var overflow_key = emptyKey(1);
    overflow_key.goal.x = capacity;
    try std.testing.expect(!keys.insert(overflow_key));
    try std.testing.expect(!keys.contains(overflow_key));
}

// Minimal single-level NavGraph for cache-eviction/waypoint tests: only the grid
// dimensions are read (cellInSpans / waypointFromStitched), so an empty-backed grid
// of the requested size suffices. Caller must deinit the returned graph's level list.
fn makeTestGraph(allocator: std.mem.Allocator, width: usize, height: usize) !NavGraph {
    var graph = NavGraph{ .allocator = allocator, .width = width, .height = height };
    try graph.levels.append(allocator, NavGrid{ .width = width, .height = height, .cell_size = 1 });
    return graph;
}

test "pathfinding result cache evicts only paths crossing an edited span" {
    var stats = PathfindingStats{};
    var graph = try makeTestGraph(std.testing.allocator, 10, 10);
    defer graph.levels.deinit(std.testing.allocator);
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4, 8, 8, 0);

    // Crossing path runs along row 0 through cell (2,0); clear path sits on row 5.
    var crossing = emptyKey(1);
    crossing.goal.x = 1;
    cache.put(crossing, &.{ 0, 1, 2, 3 }, &.{}, 0, 0, &stats);
    var clear = emptyKey(1);
    clear.goal.x = 2;
    cache.put(clear, &.{ 50, 51, 52 }, &.{}, 0, 0, &stats);

    const spans = [_]ChangedSpan{.{ .level = 0, .span = .{ .min_x = 2, .max_x = 2, .min_y = 0, .max_y = 0 } }};
    cache.evictCrossing(&graph, &spans);

    try std.testing.expect(cache.find(crossing) == null); // crossed (2,0) -> evicted
    try std.testing.expect(cache.find(clear) != null); // clear of the edit -> still served
}

test "pathfinding result cache evicts every crossing entry in one bulk edit without a restart per eviction" {
    // A single evictCrossing call with several crossing entries exercises the
    // collect-then-remove sweep under back-shift relocation: every crossing entry must
    // be evicted (none skipped/double-visited because an earlier removal shifted a
    // later entry), and every clear entry must survive.
    var stats = PathfindingStats{};
    var graph = try makeTestGraph(std.testing.allocator, 10, 10);
    defer graph.levels.deinit(std.testing.allocator);
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const capacity = 8;
    try cache.reserve(std.testing.allocator, capacity, 8, 8, 0);

    // Even-indexed entries cross row 0 (the edited span); odd-indexed sit clear on row 5.
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        if (i % 2 == 0) {
            cache.put(key, &.{ 0, 1, @as(u32, @intCast(2 + i)) }, &.{}, 0, 0, &stats);
        } else {
            cache.put(key, &.{ 50, 51, @as(u32, @intCast(52 + i)) }, &.{}, 0, 0, &stats);
        }
    }

    const spans = [_]ChangedSpan{.{ .level = 0, .span = .{ .min_x = 0, .max_x = 1, .min_y = 0, .max_y = 0 } }};
    cache.evictCrossing(&graph, &spans);

    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        if (i % 2 == 0) {
            try std.testing.expect(cache.find(key) == null); // crossing -> evicted
        } else {
            try std.testing.expect(cache.find(key) != null); // clear -> survives
        }
    }
}

test "pathfinding result cache evicts a stitched corridor only when a span matches its cell's own level" {
    // The stitched branch of crossesSpans checks (level, cell) per stored StitchedCell, not
    // cell alone: an edit on level 0 must evict a corridor whose level-0 run touches it, but
    // must NOT evict an otherwise-identical corridor that only touches that cell on level 1.
    var stats = PathfindingStats{};
    var graph = NavGraph{ .allocator = std.testing.allocator, .width = 10, .height = 10 };
    defer graph.levels.deinit(std.testing.allocator);
    try graph.levels.append(std.testing.allocator, NavGrid{ .width = 10, .height = 10, .cell_size = 1 });
    try graph.levels.append(std.testing.allocator, NavGrid{ .level = 1, .width = 10, .height = 10, .cell_size = 1 });

    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4, 8, 8, 0);

    // Same cell sequence, different levels: only the level-0 corridor should be considered
    // crossing an edit scoped to level 0.
    var on_level0 = emptyKey(1);
    on_level0.goal.x = 1;
    cache.put(on_level0, &.{}, &.{
        .{ .level = 0, .cell = 0 },
        .{ .level = 0, .cell = 1 },
        .{ .level = 0, .cell = 2 },
    }, 0, 0, &stats);
    var on_level1 = emptyKey(1);
    on_level1.goal.x = 2;
    cache.put(on_level1, &.{}, &.{
        .{ .level = 1, .cell = 0 },
        .{ .level = 1, .cell = 1 },
        .{ .level = 1, .cell = 2 },
    }, 1, 0, &stats);
    // A cross-level corridor: its level-0 prefix touches the edit, its level-1 tail does not.
    var mixed = emptyKey(1);
    mixed.goal.x = 3;
    cache.put(mixed, &.{}, &.{
        .{ .level = 0, .cell = 1 },
        .{ .level = 1, .cell = 5 },
        .{ .level = 1, .cell = 6 },
    }, 0, 0, &stats);

    const spans = [_]ChangedSpan{.{ .level = 0, .span = .{ .min_x = 1, .max_x = 1, .min_y = 0, .max_y = 0 } }};
    cache.evictCrossing(&graph, &spans);

    try std.testing.expect(cache.find(on_level0) == null); // level-0 cell 1 crossed -> evicted
    try std.testing.expect(cache.find(on_level1) != null); // same cell id, but level 1 -> survives
    try std.testing.expect(cache.find(mixed) == null); // its level-0 prefix crossed -> evicted
}

test "pathfinding group key map keeps probe chains intact after mid-chain removal" {
    var map = GroupKeyMap{};
    defer map.deinit(std.testing.allocator);
    const capacity = 8;
    try map.reserve(std.testing.allocator, capacity);

    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        try std.testing.expect(map.insert(key, i));
    }
    // Remove two entries that may sit mid-probe-chain; every survivor must stay findable and
    // keep its group index (back-shift deletion must not strand a later key behind the gap).
    for ([_]usize{ 2, 5 }) |target| {
        var key = emptyKey(1);
        key.goal.x = @intCast(target);
        map.remove(key);
    }
    for (0..capacity) |i| {
        var key = emptyKey(1);
        key.goal.x = @intCast(i);
        if (i == 2 or i == 5) {
            try std.testing.expect(map.find(key) == null);
        } else {
            try std.testing.expectEqual(i, map.find(key).?);
        }
    }
}

test "pathfinding stitched waypoint matches full scan and recovers from a stale hint" {
    var graph = try makeTestGraph(std.testing.allocator, 100, 1);
    defer graph.levels.deinit(std.testing.allocator);
    const grid = graph.grid(0).?;
    const stitched = [_]StitchedCell{
        .{ .level = 0, .cell = 10 }, .{ .level = 0, .cell = 11 },
        .{ .level = 0, .cell = 12 }, .{ .level = 0, .cell = 13 },
        .{ .level = 0, .cell = 14 }, .{ .level = 0, .cell = 15 },
    };

    const baseline = waypointFromStitched(&graph, &stitched, 0, 12, null).?;
    try std.testing.expectEqual(grid.cellCenter(13).x, baseline.x);

    var fresh: u32 = 1;
    const hinted = waypointFromStitched(&graph, &stitched, 0, 12, &fresh).?;
    try std.testing.expectEqual(baseline.x, hinted.x);
    try std.testing.expectEqual(@as(u32, 2), fresh);

    var stale: u32 = 999;
    const recovered = waypointFromStitched(&graph, &stitched, 0, 12, &stale).?;
    try std.testing.expectEqual(baseline.x, recovered.x);
    try std.testing.expectEqual(@as(u32, 2), stale);
}
