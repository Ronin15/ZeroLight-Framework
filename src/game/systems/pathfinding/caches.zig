// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Goal-keyed query caches: the linear-probe pending KeySet, the shared `CacheCore` slot
//! table with its owner log, the completed-path ResultCache (exact path storage in pages,
//! entries kept across resizes), plus the per-agent waypoint derivation that turns a
//! cached plain or stitched path into a forward heading.

const std = @import("std");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavGraph = @import("nav_graph.zig").NavGraph;
const types = @import("types.zig");
const PathQueryKey = types.PathQueryKey;
const StitchedCell = types.StitchedCell;
const StitchedView = types.StitchedView;
const PathResult = types.PathResult;
const PathfindingStats = types.PathfindingStats;
const ListResize = types.ListResize;
const OwnerOp = types.OwnerOp;
const no_owner = types.no_owner;
const hashPathKey = types.hashPathKey;
const keysEqual = types.keysEqual;
const emptyKey = types.emptyKey;

// Forward window probed around a per-agent waypoint hint before falling back to a full
// path scan. Agents walk a shared goal-keyed path monotonically (~1 cell/step), so the
// next match is almost always within a few cells of last step's index; this turns the
// per-agent waypoint derivation from O(path_len) into O(window) in the common case.
const waypoint_hint_window: usize = 8;

// Generic fixed-capacity, open-addressed (linear-probe) table keyed by PathQueryKey with
// back-shift deletion. Full tables drop new inserts instead of allocating during the
// fixed-step update. Backs both the pending KeySet (Payload = void) and the
// group-key -> requests-index map (Payload = u16). CacheCore below re-implements this
// same probe-walk/back-shift shape rather than composing over this table, because its
// entries also carry owner ids, claim marks, and owner-log ops ProbeTable has no notion
// of; the two copies are kept in sync by hand, not shared code.
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

// Fixed-capacity linear-probe set for pending keys. Full sets drop new inserts instead of
// allocating during the fixed-step update.
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

// Owner-log ops one entry live at a flush interval's start can take before the next
// flush: a rename (a shrink moves it) and a retire (it is removed). Entries claimed in the
// interval log nothing more until the flush.
const ops_per_entry: usize = 2;

// Page size the result cache's stripes and long blocks are grouped into: a grow appends
// pages and moves no stored path.
const page_target_bytes: usize = 128 * 1024;

// log2 of the blocks of `block_words` words one page holds (at least one); below 64.
fn pageShift(block_words: usize) u6 {
    const block_bytes = @max(@as(usize, 1), block_words *| @sizeOf(u32));
    return @intCast(std.math.log2_int(usize, @max(@as(usize, 1), page_target_bytes / block_bytes)));
}

// Pages of `1 << shift` blocks holding `blocks` blocks.
fn pageCount(blocks: usize, shift: u6) usize {
    const per_page = @as(usize, 1) << shift;
    return (blocks + per_page - 1) / per_page;
}

/// The slot table and entry records of a goal-keyed cache. An entry's record index is its
/// owner id in the path registry: it stays below the logical capacity, so registry owner
/// heads follow the capacity. Every removal logs a retire and every move a rename into the
/// owner log, which the registry flush applies; the log holds at most `ops_per_entry` ops
/// per entry live when it was last emptied. Main thread; readers (`slotIndex`, `ownerOf`,
/// records) are safe on workers while nothing mutates.
fn CacheCore(comptime Extra: type) type {
    return struct {
        const Self = @This();

        pub const Record = struct {
            // step_counter when written, for the TTL and a shrink's age order.
            stamp: u32 = 0,
            // The publish that claimed it: never a victim of that publish.
            claim_epoch: u32 = 0,
            live: bool = false,
            extra: Extra = .{},
        };

        /// A resize's storage, allocated before any entry moves.
        pub const Resize = struct {
            capacity: usize,
            slots: std.ArrayList(ProbeSlot) = .empty,
            records: ListResize(Record) = .{},
            keys: ListResize(PathQueryKey) = .{},
            free: ListResize(u32) = .{},
            log_replacement: ?std.ArrayList(OwnerOp) = null,
        };

        // Probe table, 2x the logical capacity so every chain ends at an empty slot.
        slots: std.ArrayList(ProbeSlot) = .empty,
        // One per entry of logical capacity, indexed by owner id, and each live one's key,
        // kept apart so the records a lookup reads stay small.
        records: std.ArrayList(Record) = .empty,
        keys: std.ArrayList(PathQueryKey) = .empty,
        // Unclaimed record indices; a pop takes the lowest after a resize or clear.
        free: std.ArrayList(u32) = .empty,
        owner_log: std.ArrayList(OwnerOp) = .empty,
        owner_log_limit: usize = 0,
        // A shrink's owner log sized to its new capacity, swapped in after the flush that
        // applies the shrink's ops.
        owner_log_replacement: ?std.ArrayList(OwnerOp) = null,
        logical_capacity: usize = 0,
        len: usize = 0,
        next_evict: usize = 0,
        // The current publish and how many entries it claimed.
        claim_epoch: u32 = 0,
        epoch_claims: usize = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.owner_log_replacement) |*replacement| replacement.deinit(allocator);
            self.owner_log.deinit(allocator);
            self.free.deinit(allocator);
            self.keys.deinit(allocator);
            self.records.deinit(allocator);
            self.slots.deinit(allocator);
            self.* = undefined;
        }

        pub fn slotIndex(self: *const Self, key: PathQueryKey) ?usize {
            const capacity = self.slots.items.len;
            if (capacity == 0) return null;
            const start = hashPathKey(key) % capacity;
            for (0..capacity) |probe| {
                const index = (start + probe) % capacity;
                const slot = self.slots.items[index];
                if (slot.occupied and keysEqual(slot.key, key)) return index;
                // Chains are contiguous (back-shift deletion) and the table is at most half
                // full, so the first empty slot ends this key's chain.
                if (!slot.occupied) return null;
            }
            return null;
        }

        /// The owner id of `key`'s entry, or null.
        pub fn ownerOf(self: *const Self, key: PathQueryKey) ?u32 {
            const index = self.slotIndex(key) orelse return null;
            return self.slots.items[index].payload_index;
        }

        /// The key of live owner `owner`.
        pub fn keyOf(self: *const Self, owner: u32) PathQueryKey {
            std.debug.assert(self.records.items[owner].live);
            return self.keys.items[owner];
        }

        pub fn ownerLog(self: *const Self) []const OwnerOp {
            return self.owner_log.items;
        }

        /// Empties the owner log once a flush applied it, and installs a shrink's smaller log.
        pub fn finishOwnerLog(self: *Self, allocator: std.mem.Allocator) void {
            self.owner_log.clearRetainingCapacity();
            const replacement = self.owner_log_replacement orelse return;
            self.owner_log.deinit(allocator);
            self.owner_log = replacement;
            self.owner_log_replacement = null;
            self.owner_log_limit = ops_per_entry * self.logical_capacity;
            std.debug.assert(self.owner_log.capacity >= self.owner_log_limit);
        }

        fn logOp(self: *Self, op: OwnerOp) void {
            std.debug.assert(self.owner_log.items.len < self.owner_log_limit);
            self.owner_log.appendAssumeCapacity(op);
        }

        /// Opens a publish: its claims are never victims of each other.
        pub fn beginPublish(self: *Self) void {
            self.claim_epoch +%= 1;
            self.epoch_claims = 0;
            if (self.claim_epoch != 0) return;
            // Wrapped: forget every mark so no old claim reads as this publish's.
            for (self.records.items) |*record| record.claim_epoch = 0;
            self.claim_epoch = 1;
        }

        /// Claims `key`'s entry for this publish at `stamp`: its own (a re-put, which
        /// retires its registrations), else the lowest free record, else a round-robin
        /// victim's (retired) when the cache is full. Never picks an entry this publish
        /// claimed. Returns the owner id; its `extra` still holds a re-put's or a victim's.
        /// O(1) expected; allocates nothing. Requires a nonzero capacity.
        pub fn claim(self: *Self, key: PathQueryKey, stamp: u32, stats: *PathfindingStats) u32 {
            std.debug.assert(self.logical_capacity != 0);
            const owner = if (self.slotIndex(key)) |index| reput: {
                const owner = self.slots.items[index].payload_index;
                self.logOp(.{ .old = owner, .new = no_owner });
                break :reput owner;
            } else fresh: {
                if (self.len >= self.logical_capacity) self.evictVictim(stats);
                // Below the capacity, the free list holds a record.
                const owner = self.free.pop().?;
                self.insertSlot(key, owner);
                self.len += 1;
                break :fresh owner;
            };
            const record = &self.records.items[owner];
            self.keys.items[owner] = key;
            record.stamp = stamp;
            record.claim_epoch = self.claim_epoch;
            record.live = true;
            self.epoch_claims += 1;
            return owner;
        }

        // Removes the next round-robin entry this publish did not claim; its record goes
        // back to the free list with its `extra` intact.
        fn evictVictim(self: *Self, stats: *PathfindingStats) void {
            // A capacity of at least four results per solve keeps an unclaimed entry.
            std.debug.assert(self.epoch_claims < self.len);
            const physical = self.slots.items.len;
            while (true) : (self.next_evict = (self.next_evict + 1) % physical) {
                const slot = self.slots.items[self.next_evict];
                if (slot.occupied and self.records.items[slot.payload_index].claim_epoch != self.claim_epoch) break;
            }
            const victim = self.next_evict;
            self.next_evict = (self.next_evict + 1) % physical;
            stats.cache_evictions += 1;
            self.removeAt(victim);
        }

        // Writes `key` at the first empty slot of its chain.
        fn insertSlot(self: *Self, key: PathQueryKey, owner: u32) void {
            insertRehashed(ProbeSlot, self.slots.items, .{ .occupied = true, .key = key, .payload_index = owner });
        }

        /// Removes the entry at probe slot `index`, retiring its owner id. Back-shift
        /// deletion keeps every probe chain contiguous; only probe slots move. The record's
        /// `extra` is left for the owner to release.
        pub fn removeAt(self: *Self, index: usize) void {
            const capacity = self.slots.items.len;
            const owner = self.slots.items[index].payload_index;
            self.records.items[owner].live = false;
            std.debug.assert(self.free.items.len < self.free.capacity);
            self.free.appendAssumeCapacity(owner);
            self.logOp(.{ .old = owner, .new = no_owner });
            self.slots.items[index].occupied = false;
            self.len -= 1;
            var hole = index;
            var probe = index;
            while (true) {
                probe = (probe + 1) % capacity;
                if (probe == index) break;
                const slot = self.slots.items[probe];
                if (!slot.occupied) break;
                const home = hashPathKey(slot.key) % capacity;
                // An entry whose home lies cyclically within (hole, probe] stays.
                if (inCyclicRange(hole, probe, home)) continue;
                self.slots.items[hole] = slot;
                self.slots.items[probe].occupied = false;
                hole = probe;
            }
        }

        /// Empties the cache and its owner log, keeping storage. O(capacity).
        pub fn clear(self: *Self) void {
            for (self.slots.items) |*slot| slot.occupied = false;
            for (self.records.items) |*record| record.live = false;
            self.rebuildFree(self.logical_capacity);
            self.owner_log.clearRetainingCapacity();
            self.len = 0;
            self.next_evict = 0;
        }

        // Pushes every free record below `capacity` highest first, so pops hand out the
        // lowest.
        fn rebuildFree(self: *Self, capacity: usize) void {
            self.free.clearRetainingCapacity();
            var index = capacity;
            while (index > 0) {
                index -= 1;
                if (self.records.items[index].live) continue;
                // Record indices stay below the capacity, a u32 owner width.
                self.free.appendAssumeCapacity(@intCast(index));
            }
        }

        /// Allocates a resize to `capacity` (probe table, records, free list, owner log)
        /// without moving any entry. Undo with `abortResize`.
        pub fn prepareResize(self: *Self, allocator: std.mem.Allocator, capacity: usize) !Resize {
            var resize = Resize{ .capacity = capacity };
            try resize.slots.ensureTotalCapacityPrecise(allocator, capacity *| 2);
            errdefer resize.slots.deinit(allocator);
            try resize.records.prepare(&self.records, allocator, capacity);
            errdefer resize.records.abort(allocator);
            try resize.keys.prepare(&self.keys, allocator, capacity);
            errdefer resize.keys.abort(allocator);
            try resize.free.prepare(&self.free, allocator, capacity);
            errdefer resize.free.abort(allocator);
            // Ops of the entries live now (at most the old capacity) and of the next
            // interval's, until the next flush.
            try self.owner_log.ensureTotalCapacity(allocator, ops_per_entry *| @max(self.logical_capacity, capacity));
            if (capacity < self.logical_capacity) {
                var replacement: std.ArrayList(OwnerOp) = .empty;
                try replacement.ensureTotalCapacityPrecise(allocator, ops_per_entry *| capacity);
                resize.log_replacement = replacement;
            }
            return resize;
        }

        pub fn abortResize(_: *Self, allocator: std.mem.Allocator, resize: *Resize) void {
            if (resize.log_replacement) |*replacement| replacement.deinit(allocator);
            resize.free.abort(allocator);
            resize.keys.abort(allocator);
            resize.records.abort(allocator);
            resize.slots.deinit(allocator);
        }

        /// Commits a prepared resize; infallible. A shrink first evicts the oldest entries
        /// (age `step -% stamp`, then owner id) until the entries fit, retiring each (calling
        /// `context.releaseRecord(owner)`), then moves every live record at or past
        /// `capacity` into the lowest free record below it, renaming the owner (calling
        /// `context.moveRecord(from, to)`). Then the free list and probe table are rebuilt
        /// from the records. O(old capacity + new capacity), no sort.
        pub fn commitResize(self: *Self, allocator: std.mem.Allocator, resize: *Resize, step: u32, context: anytype) void {
            const old_capacity = self.logical_capacity;
            const capacity = resize.capacity;
            if (capacity < old_capacity) {
                if (self.len > capacity) self.evictOldest(step, self.len - capacity, context);
                var target: usize = 0;
                for (capacity..old_capacity) |source| {
                    if (!self.records.items[source].live) continue;
                    while (self.records.items[target].live) target += 1;
                    // The entries fit below the capacity after the evictions.
                    std.debug.assert(target < capacity);
                    self.records.items[target] = self.records.items[source];
                    self.keys.items[target] = self.keys.items[source];
                    self.records.items[source].live = false;
                    // Both indices stay below the old capacity, a u32 owner width.
                    self.logOp(.{ .old = @intCast(source), .new = @intCast(target) });
                    context.moveRecord(@intCast(source), @intCast(target));
                    target += 1;
                }
            }
            resize.records.commitResized(&self.records, allocator, capacity);
            // A key past the old length stays unread until its record is claimed.
            resize.keys.commitResized(&self.keys, allocator, capacity);
            for (old_capacity..@max(old_capacity, capacity)) |index| self.records.items[index] = .{};
            resize.free.commit(&self.free, allocator);
            self.rebuildFree(capacity);
            resize.slots.items.len = capacity * 2;
            @memset(resize.slots.items, .{});
            for (self.records.items, 0..) |record, index| {
                // Record indices stay below the capacity.
                if (record.live) insertRehashed(ProbeSlot, resize.slots.items, .{ .occupied = true, .key = self.keys.items[index], .payload_index = @intCast(index) });
            }
            self.slots.deinit(allocator);
            self.slots = resize.slots;
            resize.slots = .empty;
            self.logical_capacity = capacity;
            self.next_evict = 0;
            self.owner_log_limit = ops_per_entry * @max(old_capacity, capacity);
            std.debug.assert(self.owner_log.capacity >= self.owner_log_limit);
            if (resize.log_replacement) |replacement| {
                if (self.owner_log_replacement) |*pending| pending.deinit(allocator);
                self.owner_log_replacement = replacement;
                resize.log_replacement = null;
            }
            std.debug.assert(self.free.items.len == capacity - self.len);
        }

        // Evicts the `evict_count` oldest entries in age order (greatest `step -% stamp`
        // first, lowest owner id breaking ties) without sorting: four 8-bit histogram
        // passes find the age at which the count is reached, then one pass in owner-id
        // order evicts every older entry and the first entries of that age.
        // SIMD verdict: scalar. Histogram passes scatter into 256 buckets.
        fn evictOldest(self: *Self, step: u32, evict_count: usize, context: anytype) void {
            const threshold = evictionThreshold(self.records.items, step, evict_count);
            var ties = threshold.ties;
            for (self.records.items, 0..) |*record, index| {
                if (!record.live) continue;
                const age = step -% record.stamp;
                if (age < threshold.age) continue;
                if (age == threshold.age) {
                    if (ties == 0) continue;
                    ties -= 1;
                }
                // Record indices stay below the old capacity.
                const owner: u32 = @intCast(index);
                context.releaseRecord(owner);
                record.live = false;
                self.len -= 1;
                self.logOp(.{ .old = owner, .new = no_owner });
            }
            std.debug.assert(ties == 0);
        }

        // The age of the last evicted entry and how many entries of exactly that age are
        // evicted, for evicting `evict_count` live entries oldest first.
        fn evictionThreshold(records: []const Record, step: u32, evict_count: usize) EvictThreshold {
            std.debug.assert(evict_count != 0);
            var age_prefix: u32 = 0;
            var remaining = evict_count;
            inline for (.{ 24, 16, 8, 0 }) |shift| {
                var histogram: [256]usize = @splat(0);
                for (records) |record| {
                    if (!record.live) continue;
                    const age = step -% record.stamp;
                    // Count only entries whose higher bytes match the age found so far.
                    if ((@as(u64, age) >> (shift + 8)) != (@as(u64, age_prefix) >> (shift + 8))) continue;
                    histogram[(age >> shift) & 0xff] += 1;
                }
                var bucket: usize = 256;
                while (bucket > 0) {
                    bucket -= 1;
                    if (histogram[bucket] >= remaining) break;
                    remaining -= histogram[bucket];
                }
                // The live entries outnumber the evictions, so some bucket reached the count.
                std.debug.assert(histogram[bucket] >= remaining);
                age_prefix |= @as(u32, @intCast(bucket)) << shift;
            }
            return .{ .age = age_prefix, .ties = remaining };
        }
    };
}

const EvictThreshold = struct {
    age: u32,
    ties: usize,
};

/// Whether a resize kept the cache's entries or rebuilt it empty (a stripe width change
/// or the first reserve).
pub const ReserveOutcome = enum { kept, rebuilt };

/// One stored path a shrink moves from a record or long block past the new capacity into
/// one below it. Distinct moves touch distinct sources and destinations.
pub const ResizeMove = struct {
    from: u32,
    to: u32,
    words: u32,
    pool: Pool,

    pub const Pool = enum(u8) { inline_stripe, long_block };
};

// Goal-keyed cache of exact paths: a moving agent derives a forward waypoint from its
// current cell against the stored path. Every record owns an inline stripe of
// `inline_words` words, holding a plain path of up to `inline_words` cells or a stitched
// path of up to about two thirds as many cells (its cells, then its levels); a
// longer result is stored whole in one long block of `long_block_words` words. Stripes
// and long blocks live in fixed pages, so a grow appends pages and moves no path. Long
// blocks are claimed from a free list that only the publish reserve grows, released on
// removal, and compacted to the live long entries' pages by a shrink, so a live entry is
// never evicted for long-pool space.
pub const ResultCache = struct {
    const Core = CacheCore(SlotPayload);

    core: Core = .{},
    inline_words: usize = 0,
    long_block_words: usize = 0,
    inline_page_shift: u6 = 0,
    long_page_shift: u6 = 0,
    inline_pages: std.ArrayList([]u32) = .empty,
    // Pages the logical capacity uses; a shrink frees the pages past it after its copy.
    inline_page_count: usize = 0,
    long_pages: std.ArrayList([]u32) = .empty,
    long_page_count: usize = 0,
    // Long blocks in the pages the pool uses.
    long_block_count: usize = 0,
    // Unclaimed long blocks (stack); capacity covers every block, so a release never
    // allocates.
    free_long_blocks: std.ArrayList(u32) = .empty,
    // A shrink's stripe and long-block moves, for its resize copy; freed after it.
    resize_moves: std.ArrayList(ResizeMove) = .empty,

    pub fn deinit(self: *ResultCache, allocator: std.mem.Allocator) void {
        self.resize_moves.deinit(allocator);
        self.free_long_blocks.deinit(allocator);
        for (self.long_pages.items) |page| allocator.free(page);
        self.long_pages.deinit(allocator);
        for (self.inline_pages.items) |page| allocator.free(page);
        self.inline_pages.deinit(allocator);
        self.core.deinit(allocator);
        self.* = undefined;
    }

    /// Bytes one entry of logical capacity holds at `inline_words`-word stripes: two probe
    /// slots, its record and key, free index, and owner-log room, and its stripe.
    pub fn bytesPerEntry(inline_words: usize) usize {
        return 2 * @sizeOf(ProbeSlot) + @sizeOf(Core.Record) + @sizeOf(PathQueryKey) + @sizeOf(u32) + ops_per_entry * @sizeOf(OwnerOp) + inline_words * @sizeOf(u32);
    }

    /// Bytes one long block of `long_block_words` words holds, its free index included.
    pub fn longBlockBytes(long_block_words: usize) usize {
        return long_block_words * @sizeOf(u32) + @sizeOf(u32);
    }

    /// Long blocks one page of `long_block_words`-word blocks holds.
    pub fn longBlocksPerPage(long_block_words: usize) usize {
        return @as(usize, 1) << pageShift(long_block_words);
    }

    pub fn logicalCapacity(self: *const ResultCache) usize {
        return self.core.logical_capacity;
    }

    pub fn count(self: *const ResultCache) usize {
        return self.core.len;
    }

    /// Whether a result can be claimed: a nonzero capacity and stripe.
    pub fn canStore(self: *const ResultCache) bool {
        return self.core.logical_capacity != 0 and self.inline_words != 0;
    }

    // Reconstructs the full PathResult for a probe slot from its key and record.
    pub fn resultAt(self: *const ResultCache, index: usize) PathResult {
        const slot = self.core.slots.items[index];
        const payload = self.core.records.items[slot.payload_index].extra;
        return .{
            .key = slot.key,
            .path_len = payload.path_len,
            .path_level = payload.path_level,
            .stitched_len = payload.stitched_len,
            .end = .{ .level = payload.end_level, .cell = payload.end_cell },
        };
    }

    /// Resizes to `capacity` entries with `inline_words`-word stripes and
    /// `long_block_words`-word long blocks. With unchanged widths the live entries are
    /// kept: a grow appends stripe pages, and a shrink evicts oldest first (age
    /// `step -% stamp`, then owner id) until the entries fit, moves the records past the
    /// new capacity into free low records and the long blocks past the live long entries'
    /// pages into free low blocks, recording each stored path's move in `resize_moves`.
    /// The caller copies them (`copyMove`) and then calls `finishResize`, which frees the
    /// pages left behind. A width change, or the first reserve, rebuilds empty (`.rebuilt`).
    /// Failure-atomic: every allocation precedes any entry move. Main thread, resize seam.
    /// O(old and new capacity) and O(1) per moved entry, no sort, no stored path copied.
    pub fn reserve(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, inline_words: usize, long_block_words: usize, step: u32) !ReserveOutcome {
        std.debug.assert(self.resize_moves.items.len == 0);
        std.debug.assert(long_block_words != 0);
        if (inline_words != self.inline_words or long_block_words != self.long_block_words) {
            try self.reserveEmpty(allocator, capacity, inline_words, long_block_words);
            return .rebuilt;
        }
        if (capacity != self.core.logical_capacity) try self.resizeKeepingEntries(allocator, capacity, step);
        return .kept;
    }

    fn reserveEmpty(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, inline_words: usize, long_block_words: usize) !void {
        // A fresh cache at the new shape replaces this one once fully built.
        var fresh = ResultCache{
            .inline_words = inline_words,
            .long_block_words = long_block_words,
            .inline_page_shift = pageShift(inline_words),
            .long_page_shift = pageShift(long_block_words),
        };
        errdefer fresh.deinit(allocator);
        var resize = try fresh.core.prepareResize(allocator, capacity);
        errdefer fresh.core.abortResize(allocator, &resize);
        try fresh.appendInlinePages(allocator, pageCount(capacity, fresh.inline_page_shift));
        fresh.core.commitResize(allocator, &resize, 0, NoRecordHooks{});
        fresh.inline_page_count = fresh.inline_pages.items.len;
        self.deinit(allocator);
        self.* = fresh;
    }

    // Appends pages until `pages` exist; on error the appended pages are freed.
    fn appendInlinePages(self: *ResultCache, allocator: std.mem.Allocator, pages: usize) !void {
        const before = self.inline_pages.items.len;
        if (pages <= before) return;
        try self.inline_pages.ensureTotalCapacity(allocator, pages);
        errdefer {
            for (self.inline_pages.items[before..]) |page| allocator.free(page);
            self.inline_pages.items.len = before;
        }
        const page_words = (@as(usize, 1) << self.inline_page_shift) * self.inline_words;
        while (self.inline_pages.items.len < pages) self.inline_pages.appendAssumeCapacity(try allocator.alloc(u32, page_words));
    }

    fn resizeKeepingEntries(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, step: u32) !void {
        const old_capacity = self.core.logical_capacity;
        const shrinking = capacity < old_capacity;
        const old_pages = self.inline_pages.items.len;
        var resize = try self.core.prepareResize(allocator, capacity);
        errdefer self.core.abortResize(allocator, &resize);
        try self.appendInlinePages(allocator, pageCount(capacity, self.inline_page_shift));
        errdefer {
            for (self.inline_pages.items[old_pages..]) |page| allocator.free(page);
            self.inline_pages.items.len = old_pages;
        }
        if (shrinking) {
            // Inline moves are at most the records past the new capacity; long moves at
            // most the live long entries.
            const live_long = self.long_block_count - self.free_long_blocks.items.len;
            try self.resize_moves.ensureTotalCapacity(allocator, @min(self.core.len, old_capacity - capacity) + live_long);
        }

        // Commit: nothing below can fail.
        self.core.commitResize(allocator, &resize, step, self);
        if (shrinking) self.compactLongBlocks();
        self.inline_page_count = pageCount(capacity, self.inline_page_shift);
    }

    // Moves every live long block past the pages the live long entries need into a free
    // block below them, recording each move.
    fn compactLongBlocks(self: *ResultCache) void {
        const live_long = self.long_block_count - self.free_long_blocks.items.len;
        const pages = pageCount(live_long, self.long_page_shift);
        const kept_blocks = pages << self.long_page_shift;
        if (kept_blocks >= self.long_block_count) return;
        retainBelow(&self.free_long_blocks, kept_blocks);
        for (self.core.records.items) |*record| {
            if (!record.live or record.extra.long_block == no_block or record.extra.long_block < kept_blocks) continue;
            // The live long entries fit below `kept_blocks`.
            const target = self.free_long_blocks.pop().?;
            const words = types.storedPathWords(record.extra.path_len, record.extra.stitched_len);
            // A stored path fits its u32 length fields.
            self.resize_moves.appendAssumeCapacity(.{ .from = record.extra.long_block, .to = target, .words = @intCast(words), .pool = .long_block });
            record.extra.long_block = target;
        }
        self.long_page_count = pages;
        self.long_block_count = kept_blocks;
    }

    // `CacheCore` hook: a shrink evicted `owner`, releasing its long block.
    fn releaseRecord(self: *ResultCache, owner: u32) void {
        self.releaseLongBlock(&self.core.records.items[owner].extra);
    }

    // `CacheCore` hook: a shrink moved record `from` to `to`; an inline path moves with it.
    fn moveRecord(self: *ResultCache, from: u32, to: u32) void {
        const payload = self.core.records.items[to].extra;
        if (payload.long_block != no_block) return;
        const words = types.storedPathWords(payload.path_len, payload.stitched_len);
        // A stored path fits its u32 length fields.
        self.resize_moves.appendAssumeCapacity(.{ .from = from, .to = to, .words = @intCast(words), .pool = .inline_stripe });
    }

    /// The stored path moves of the last shrink, for its resize copy.
    pub fn pendingMoves(self: *const ResultCache) []const ResizeMove {
        return self.resize_moves.items;
    }

    /// Copies one pending move's stored path. Moves touch distinct words, so they copy on
    /// any thread in any order.
    pub fn copyMove(self: *const ResultCache, move: ResizeMove) void {
        const from, const to = switch (move.pool) {
            .inline_stripe => .{ self.inlineStripe(move.from), self.inlineStripe(move.to) },
            .long_block => .{ self.longBlock(move.from), self.longBlock(move.to) },
        };
        @memcpy(to[0..move.words], from[0..move.words]);
    }

    /// Ends a resize once its moves are copied: frees the pages past the capacity and the
    /// move list. Infallible.
    pub fn finishResize(self: *ResultCache, allocator: std.mem.Allocator) void {
        for (self.inline_pages.items[self.inline_page_count..]) |page| allocator.free(page);
        self.inline_pages.items.len = self.inline_page_count;
        for (self.long_pages.items[self.long_page_count..]) |page| allocator.free(page);
        self.long_pages.items.len = self.long_page_count;
        self.resize_moves.clearAndFree(allocator);
    }

    /// The publish reserve, called with the step's long-result count before any claim
    /// stores one: appends long-block pages so every claim finds a free block, never past
    /// the page holding the `logicalCapacity()`th block. Each entry holds at most one block
    /// and a claim releases (its own, or its victim's) before it takes one, so live blocks
    /// never exceed the entry limit. Copies no stored path. Failure-atomic. Main thread.
    /// Returns the pages it allocated.
    pub fn reserveLongBlocks(self: *ResultCache, allocator: std.mem.Allocator, needed: usize) !usize {
        const live = self.long_block_count - self.free_long_blocks.items.len;
        const required = @min(live +| needed, self.core.logical_capacity);
        if (self.long_block_count >= required) return 0;
        const pages = pageCount(required, self.long_page_shift);
        const new_count = pages << self.long_page_shift;
        try self.long_pages.ensureTotalCapacity(allocator, pages);
        try self.free_long_blocks.ensureTotalCapacity(allocator, new_count);
        const before = self.long_pages.items.len;
        errdefer {
            for (self.long_pages.items[before..]) |page| allocator.free(page);
            self.long_pages.items.len = before;
        }
        const page_words = (@as(usize, 1) << self.long_page_shift) * self.long_block_words;
        while (self.long_pages.items.len < pages) self.long_pages.appendAssumeCapacity(try allocator.alloc(u32, page_words));
        // Pushed high to low so the lowest new block is claimed first.
        var block = new_count;
        while (block > self.long_block_count) {
            block -= 1;
            // Below the page past the logical capacity, a u32 payload width.
            self.free_long_blocks.appendAssumeCapacity(@intCast(block));
        }
        self.long_page_count = pages;
        self.long_block_count = new_count;
        return pages - before;
    }

    pub fn clear(self: *ResultCache) void {
        for (self.core.records.items) |*record| record.extra.long_block = no_block;
        self.core.clear();
        self.free_long_blocks.clearRetainingCapacity();
        var block = self.long_block_count;
        while (block > 0) {
            block -= 1;
            // Below the page past the logical capacity, a u32 payload width.
            self.free_long_blocks.appendAssumeCapacity(@intCast(block));
        }
    }

    /// Removes the entry at probe slot `index`, retiring its owner and releasing its long
    /// block. O(1) expected; allocates nothing.
    pub fn removeAt(self: *ResultCache, index: usize) void {
        self.releaseLongBlock(&self.core.records.items[self.core.slots.items[index].payload_index].extra);
        self.core.removeAt(index);
    }

    fn releaseLongBlock(self: *ResultCache, payload: *SlotPayload) void {
        if (payload.long_block == no_block) return;
        std.debug.assert(self.free_long_blocks.items.len < self.free_long_blocks.capacity);
        self.free_long_blocks.appendAssumeCapacity(payload.long_block);
        payload.long_block = no_block;
    }

    fn inlineStripe(self: *const ResultCache, owner: usize) []u32 {
        const page = self.inline_pages.items[owner >> self.inline_page_shift];
        const offset = (owner & ((@as(usize, 1) << self.inline_page_shift) - 1)) * self.inline_words;
        return page[offset..][0..self.inline_words];
    }

    fn longBlock(self: *const ResultCache, block: usize) []u32 {
        const page = self.long_pages.items[block >> self.long_page_shift];
        const offset = (block & ((@as(usize, 1) << self.long_page_shift) - 1)) * self.long_block_words;
        return page[offset..][0..self.long_block_words];
    }

    /// The words holding `owner`'s stored path: its long block, else its inline stripe.
    pub fn storedWords(self: *const ResultCache, owner: usize) []const u32 {
        const block = self.core.records.items[owner].extra.long_block;
        if (block != no_block) return self.longBlock(block);
        return self.inlineStripe(owner);
    }

    /// The words a claim's copy writes. Distinct claims of one publish never share words.
    pub fn destination(self: *const ResultCache, claimed: Claimed) []u32 {
        if (claimed.long_block != no_block) return self.longBlock(claimed.long_block);
        return self.inlineStripe(claimed.owner);
    }

    // `slot_index` is the PROBE slot index (as returned by slotIndex/freshSlotIndex).
    pub fn pathSlice(self: *const ResultCache, slot_index: usize, path_len: usize) []const u32 {
        return self.storedWords(self.core.slots.items[slot_index].payload_index)[0..path_len];
    }

    pub fn stitchedSlice(self: *const ResultCache, slot_index: usize, stitched_len: usize) StitchedView {
        return types.stitchedView(self.storedWords(self.core.slots.items[slot_index].payload_index), stitched_len);
    }

    pub fn slotIndex(self: *const ResultCache, key: PathQueryKey) ?usize {
        return self.core.slotIndex(key);
    }

    pub fn find(self: *const ResultCache, key: PathQueryKey) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        return self.resultAt(index);
    }

    // Non-mutating freshness gate for the per-frame read path (statusForWorld): returns the
    // slot only when it is within `ttl`. A const reader cannot evict, so a stale entry
    // reads as a miss and the caller re-requests; acceptRequests' findFresh evicts. ttl 0
    // disables expiry.
    pub fn freshSlotIndex(self: *const ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?usize {
        const found = self.lookup(key, step, ttl) orelse return null;
        return if (found.fresh) found.slot else null;
    }

    pub const SlotLookup = struct {
        slot: usize,
        fresh: bool,
        // Where the result ends (`PathResult.end`).
        end: StitchedCell,
    };

    /// The key's slot, whether its result is within `ttl` at `step`, and where it ends, from
    /// one probe and its record; null when absent. ttl 0 disables expiry. Const: never evicts.
    pub fn lookup(self: *const ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?SlotLookup {
        const index = self.slotIndex(key) orelse return null;
        const record = &self.core.records.items[self.core.slots.items[index].payload_index];
        return .{
            .slot = index,
            .fresh = ttl == 0 or (step -% record.stamp) < ttl,
            .end = .{ .level = record.extra.end_level, .cell = record.extra.end_cell },
        };
    }

    // find, but a result older than `ttl` steps is removed (returns null) so the caller
    // re-solves it against current geometry. ttl 0 disables expiry.
    pub fn findFresh(self: *ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        const owner = self.core.slots.items[index].payload_index;
        if (ttl != 0 and (step -% self.core.records.items[owner].stamp) >= ttl) {
            self.removeAt(index);
            return null;
        }
        return self.resultAt(index);
    }

    /// Where a claimed result is stored: its owner's inline stripe, or a long block.
    pub const Claimed = struct {
        owner: u32,
        long_block: u32,
    };

    /// Claims `key`'s entry for a result of `path_len` plain or `stitched_len` stitched
    /// cells ending at `end` at `step` (see `CacheCore.claim`) and records its shape and
    /// end; the caller copies the
    /// path into `destination`. A result past the inline stripe takes a long block, which
    /// `reserveLongBlocks` made free; a re-put or a victim releases its block first. Opens
    /// no publish: call `core.beginPublish` first. Main thread; allocates nothing.
    pub fn claim(self: *ResultCache, key: PathQueryKey, path_len: usize, stitched_len: usize, path_level: u16, end: StitchedCell, step: u32, stats: *PathfindingStats) Claimed {
        std.debug.assert(self.canStore());
        // A solve stores at least its goal cell, as a plain or a stitched path.
        std.debug.assert((path_len == 0) != (stitched_len == 0));
        std.debug.assert(stitched_len != 0 or end.level == path_level);
        const words = types.storedPathWords(path_len, stitched_len);
        const owner = self.core.claim(key, step, stats);
        const payload = &self.core.records.items[owner].extra;
        self.releaseLongBlock(payload);
        var long_block = no_block;
        if (words > self.inline_words) {
            // The solve bounds a result at one long block; the publish reserve freed one.
            std.debug.assert(words <= self.long_block_words);
            long_block = self.free_long_blocks.pop().?;
        }
        payload.* = .{
            .path_len = @intCast(path_len), // bounded by the solve's node budget
            .stitched_len = @intCast(stitched_len), // bounded by max_stitched_path_cells
            .long_block = long_block,
            .end_cell = end.cell,
            .path_level = path_level,
            .end_level = end.level,
        };
        return .{ .owner = owner, .long_block = long_block };
    }
};

// Hooks for a resize that holds no stored paths.
const NoRecordHooks = struct {
    fn releaseRecord(_: NoRecordHooks, _: u32) void {}
    fn moveRecord(_: NoRecordHooks, _: u32, _: u32) void {}
};

const no_block: u32 = std.math.maxInt(u32);

// Probe-hot slot: the fields a linear-probe scan touches (occupancy + key), plus the
// owner id of its record.
const ProbeSlot = struct {
    occupied: bool = false,
    key: PathQueryKey = emptyKey(0),
    payload_index: u32 = 0,
};

// A cached result's shape and end: four u32s, then two u16s: 20 bytes.
const SlotPayload = struct {
    path_len: u32 = 0,
    stitched_len: u32 = 0,
    // The long block holding the path, or no_block when it sits in the inline stripe.
    long_block: u32 = no_block,
    // Where the path ends (`PathResult.end`), so a goal check reads no path page.
    end_cell: u32 = 0,
    path_level: u16 = 0,
    end_level: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(SlotPayload) == 20);
}

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
// agent's forward waypoint is found on the agent's CURRENT level with the same
// cell-by-cell logic as a plain A* path, so the heading is always to a traversable
// neighbor — never a straight-line cut across a blocked cell. Returns null when the
// agent's level has no cell in the path (a cross-level agent has not yet reached a level
// the corridor covers).
pub fn waypointFromStitched(graph: *const NavGraph, stitched: StitchedView, start_level: u16, start_index: usize, hint: ?*u32) ?math.Vec2 {
    const start_grid = graph.grid(start_level) orelse return null;
    // Cell indices are u32.
    const start_cell: u32 = @intCast(start_index);
    // Hinted fast path: probe a forward window for an exact cell match on the agent's
    // level before the full scan. A cell appears at most once per level run, so a hit
    // is unambiguous; a stale hint only misses and falls back to the scan.
    if (hint) |h| {
        const from = @min(@as(usize, h.*), stitched.len() -| 1);
        const to = @min(from + waypoint_hint_window, stitched.len());
        for (from..to) |j| {
            // The cell first: the levels column is read only on a cell match.
            if (stitched.cells[j] == start_cell and stitched.levels[j] == start_level) {
                return stitchedWaypointAt(start_grid, stitched, start_level, j, hint);
            }
        }
    }
    // The agent on a path cell walks to that cell's successor within its run.
    if (stitchedExactIndex(stitched, start_level, start_cell)) |j| return stitchedWaypointAt(start_grid, stitched, start_level, j, hint);
    // Off path: head from the nearest cell on this level. Scalar: the cell -> (x, y) split
    // is an integer division per cell, which simd.zig has no vector form of.
    var nearest_index: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    var found_run = false;
    const start_x: i32 = @intCast(start_index % start_grid.width);
    const start_y: i32 = @intCast(start_index / start_grid.width);
    for (stitched.cells, stitched.levels, 0..) |cell, level, j| {
        if (level != start_level) continue;
        const cx: i32 = @intCast(cell % start_grid.width);
        const cy: i32 = @intCast(cell / start_grid.width);
        const ddx: i64 = cx - start_x;
        const ddy: i64 = cy - start_y;
        const dist = ddx * ddx + ddy * ddy;
        if (dist < best_dist) {
            best_dist = dist;
            nearest_index = j;
            found_run = true;
        }
    }
    if (!found_run) return null;
    // The run is grid-adjacent, so the successor is one traversable step from nearest.
    return stitchedWaypointAt(start_grid, stitched, start_level, nearest_index, hint);
}

// First index holding `cell` on `level`: the four-lane exact scan of the cells column,
// its level checked on each hit.
fn stitchedExactIndex(stitched: StitchedView, level: u16, cell: u32) ?usize {
    var from: usize = 0;
    while (exactCellIndex(stitched.cells[from..], cell)) |offset| {
        const index = from + offset;
        if (stitched.levels[index] == level) return index;
        from = index + 1;
    }
    return null;
}

// Records the matched/nearest stitched index in the hint and returns the heading to its
// successor within the same-level run (or the cell itself at the run's end). The run is
// grid-adjacent, so the successor is always one traversable step.
fn stitchedWaypointAt(grid: *const NavGrid, stitched: StitchedView, level: u16, j: usize, hint: ?*u32) math.Vec2 {
    if (hint) |h| h.* = @intCast(j);
    const next = if (j + 1 < stitched.len() and stitched.levels[j + 1] == level) j + 1 else j;
    return grid.cellCenter(stitched.cells[next]);
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

test "pathfinding fixed-capacity pending key set has explicit fixed capacity" {
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

/// Invariants every settled `ResultCache` state holds: the probe table, records, and pages
/// cover the logical limit, every live record owns a distinct key slot and at most one long
/// block, the free lists hold exactly the rest, and the owner log fits its limit.
fn expectResultCacheConsistent(cache: *const ResultCache) !void {
    const core = &cache.core;
    const logical = core.logical_capacity;
    try std.testing.expectEqual(2 * logical, core.slots.items.len);
    try std.testing.expectEqual(logical, core.records.items.len);
    try std.testing.expectEqual(pageCount(logical, cache.inline_page_shift), cache.inline_pages.items.len);
    try std.testing.expectEqual(cache.long_page_count, cache.long_pages.items.len);
    try std.testing.expectEqual(cache.long_page_count << cache.long_page_shift, cache.long_block_count);
    try std.testing.expect(core.free.capacity >= logical);
    try std.testing.expect(cache.free_long_blocks.capacity >= cache.long_block_count);
    try std.testing.expectEqual(logical - core.len, core.free.items.len);
    try std.testing.expect(core.owner_log.capacity >= core.owner_log_limit);
    try std.testing.expect(core.owner_log.items.len <= core.owner_log_limit);
    try std.testing.expectEqual(@as(usize, 0), cache.resize_moves.items.len);
    var occupied: usize = 0;
    for (core.slots.items) |slot| occupied += @intFromBool(slot.occupied);
    try std.testing.expectEqual(core.len, occupied);
    var live: usize = 0;
    var live_long: usize = 0;
    for (core.records.items, 0..) |record, owner| {
        if (!record.live) continue;
        live += 1;
        try std.testing.expectEqual(@as(?u32, @intCast(owner)), core.ownerOf(core.keyOf(@intCast(owner))));
        const block = record.extra.long_block;
        if (block != no_block) {
            live_long += 1;
            try std.testing.expect(block < cache.long_block_count);
        }
    }
    try std.testing.expectEqual(core.len, live);
    try std.testing.expectEqual(cache.long_block_count - live_long, cache.free_long_blocks.items.len);
}

// Test entries for a cache reserved with 4-word stripes and 16-word long blocks. Entry
// `index` cycles through: a 3-cell plain path (inline), a 10-cell plain path (long), a
// 2-cell stitched path (3 words, inline), and a 5-cell stitched path (8 words, long).
const test_inline_words = 4;
const test_long_block_words = 16;

fn testEntryCell(index: usize, offset: usize) u32 {
    return @intCast(index * 100 + offset);
}

// Claims `key` in a publish of its own and copies its path, as the publish does; the
// owner log is emptied first, as a flush would.
fn testPut(cache: *ResultCache, key: PathQueryKey, path: []const u32, stitched: []const StitchedCell, path_level: u16, step: u32, stats: *PathfindingStats) void {
    cache.core.finishOwnerLog(std.testing.allocator);
    cache.core.beginPublish();
    testClaimAndCopy(cache, key, path, stitched, path_level, step, stats);
}

fn testClaimAndCopy(cache: *ResultCache, key: PathQueryKey, path: []const u32, stitched: []const StitchedCell, path_level: u16, step: u32, stats: *PathfindingStats) void {
    const end: StitchedCell = if (stitched.len != 0) stitched[stitched.len - 1] else .{ .level = path_level, .cell = path[path.len - 1] };
    const claimed = cache.claim(key, path.len, stitched.len, path_level, end, step, stats);
    const words = cache.destination(claimed);
    if (stitched.len != 0) types.writeStitched(words, stitched) else @memcpy(words[0..path.len], path);
}

fn putTestEntry(cache: *ResultCache, index: usize, step: u32, stats: *PathfindingStats) void {
    var plain: [10]u32 = undefined;
    var stitched: [5]StitchedCell = undefined;
    for (&plain, 0..) |*cell, offset| cell.* = testEntryCell(index, offset);
    for (&stitched, 0..) |*cell, offset| cell.* = .{ .level = @intCast(index % 3), .cell = testEntryCell(index, offset) };
    switch (index % 4) {
        0 => testPut(cache, testGoalKey(index), plain[0..3], &.{}, 0, step, stats),
        1 => testPut(cache, testGoalKey(index), plain[0..10], &.{}, 0, step, stats),
        2 => testPut(cache, testGoalKey(index), &.{}, stitched[0..2], 0, step, stats),
        else => testPut(cache, testGoalKey(index), &.{}, stitched[0..5], 0, step, stats),
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
            try std.testing.expectEqual(StitchedCell{ .level = 0, .cell = stored[len - 1] }, result.end);
        },
        else => {
            const len: usize = if (index % 4 == 2) 2 else 5;
            try std.testing.expectEqual(@as(u32, 0), result.path_len);
            const stored = cache.stitchedSlice(slot, result.stitched_len);
            try std.testing.expectEqual(len, stored.len());
            for (0..stored.len()) |offset| {
                try std.testing.expectEqual(@as(u16, @intCast(index % 3)), stored.levels[offset]);
                try std.testing.expectEqual(testEntryCell(index, offset), stored.cells[offset]);
            }
            try std.testing.expectEqual(stored.at(len - 1), result.end);
        },
    }
}

// Resizes and finishes as the system does: the pending moves copied, then the pages past
// the capacity freed and the owner log emptied.
fn testResize(cache: *ResultCache, allocator: std.mem.Allocator, capacity: usize, inline_words: usize, long_block_words: usize, step: u32) !void {
    _ = try cache.reserve(allocator, capacity, inline_words, long_block_words, step);
    for (cache.pendingMoves()) |move| cache.copyMove(move);
    cache.finishResize(allocator);
    cache.core.finishOwnerLog(allocator);
}

// A 16-entry cache holding entries 0..count at steps 0..count, long blocks reserved.
fn filledTestCache(cache: *ResultCache, count: usize, stats: *PathfindingStats) !void {
    try testResize(cache, std.testing.allocator, 16, test_inline_words, test_long_block_words, 0);
    _ = try cache.reserveLongBlocks(std.testing.allocator, count);
    for (0..count) |index| putTestEntry(cache, index, @intCast(index), stats);
}

test "pathfinding result cache stores a long path whole in a long block and never evicts for long-pool space" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try testResize(&cache, std.testing.allocator, 8, test_inline_words, test_long_block_words, 0);
    // No long page exists until a publish needs one.
    try std.testing.expectEqual(@as(usize, 0), cache.long_block_count);

    // One page of blocks: the long entries take blocks; inline entries need none.
    try std.testing.expectEqual(@as(usize, 1), try cache.reserveLongBlocks(std.testing.allocator, 1));
    try std.testing.expectEqual(ResultCache.longBlocksPerPage(test_long_block_words), cache.long_block_count);
    for (0..4) |index| putTestEntry(&cache, index, 0, &stats);
    try std.testing.expectEqual(@as(usize, 0), stats.cache_evictions);
    for (0..4) |index| try expectTestEntry(&cache, index);
    try expectResultCacheConsistent(&cache);
    const free_after_put = cache.free_long_blocks.items.len;

    // Re-putting a long key with an inline path releases its block; a TTL removal of
    // the other long entry releases its block too.
    testPut(&cache, testGoalKey(1), &.{ 7, 8 }, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(free_after_put + 1, cache.free_long_blocks.items.len);
    try std.testing.expect(cache.findFresh(testGoalKey(3), 1000, 10) == null);
    try std.testing.expectEqual(free_after_put + 2, cache.free_long_blocks.items.len);
    try expectResultCacheConsistent(&cache);
}

test "pathfinding result cache long pool never passes the page of the entry limit, and a full cache of long entries still publishes" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    // Two 64 KiB blocks per page.
    const wide_long_words = 16384;
    try std.testing.expectEqual(@as(usize, 2), ResultCache.longBlocksPerPage(wide_long_words));
    try testResize(&cache, std.testing.allocator, 4, test_inline_words, wide_long_words, 0);
    // Four live long entries (odd indices are long) fill the cache and the pool.
    try std.testing.expectEqual(@as(usize, 2), try cache.reserveLongBlocks(std.testing.allocator, 4));
    for ([_]usize{ 1, 3, 5, 7 }) |index| putTestEntry(&cache, index, 0, &stats);
    try std.testing.expectEqual(@as(usize, 4), cache.long_block_count);
    try std.testing.expectEqual(@as(usize, 0), cache.free_long_blocks.items.len);

    // Three more long results: the pool stays at the limit; each claim evicts a long victim
    // before it takes a block, so every claim finds one.
    try std.testing.expectEqual(@as(usize, 0), try cache.reserveLongBlocks(std.testing.allocator, 3));
    for ([_]usize{ 9, 11, 13 }) |index| putTestEntry(&cache, index, 1, &stats);
    try std.testing.expectEqual(@as(usize, 3), stats.cache_evictions);
    for ([_]usize{ 9, 11, 13 }) |index| try expectTestEntry(&cache, index);
    try std.testing.expectEqual(@as(usize, 4), cache.long_block_count);
    try expectResultCacheConsistent(&cache);
}

test "a cached result's end is its plain path's last cell on its path level, or its stitched path's last cell, inline and long, from find and lookup" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try testResize(&cache, std.testing.allocator, 8, test_inline_words, test_long_block_words, 0);
    _ = try cache.reserveLongBlocks(std.testing.allocator, 2);
    const plain_short = [_]u32{ 5, 6, 7 };
    const plain_long = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 9 };
    const stitched = [_]StitchedCell{ .{ .level = 0, .cell = 3 }, .{ .level = 0, .cell = 4 }, .{ .level = 2, .cell = 40 }, .{ .level = 2, .cell = 41 } };
    testPut(&cache, testGoalKey(1), &plain_short, &.{}, 3, 0, &stats);
    testPut(&cache, testGoalKey(2), &plain_long, &.{}, 1, 0, &stats);
    testPut(&cache, testGoalKey(3), &.{}, &stitched, 0, 0, &stats);
    const ends = [_]StitchedCell{ .{ .level = 3, .cell = 7 }, .{ .level = 1, .cell = 9 }, .{ .level = 2, .cell = 41 } };
    for (ends, 1..) |end, index| {
        try std.testing.expectEqual(end, cache.find(testGoalKey(index)).?.end);
        try std.testing.expectEqual(end, cache.lookup(testGoalKey(index), 0, 0).?.end);
    }
}

test "pathfinding result cache grow and shrink keep entries, evicting oldest first" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try filledTestCache(&cache, 12, &stats);

    // A grow keeps every entry and its stored cells.
    try testResize(&cache, std.testing.allocator, 64, test_inline_words, test_long_block_words, 12);
    try std.testing.expectEqual(@as(usize, 12), cache.count());
    for (0..12) |index| try expectTestEntry(&cache, index);
    try expectResultCacheConsistent(&cache);

    // A shrink to 4 evicts the eight oldest (steps 0..7) and moves the survivors below the
    // new limit; their two long entries keep one page of blocks.
    try testResize(&cache, std.testing.allocator, 4, test_inline_words, test_long_block_words, 12);
    try std.testing.expectEqual(@as(usize, 4), cache.count());
    for (0..8) |index| try std.testing.expect(cache.find(testGoalKey(index)) == null);
    for (8..12) |index| try expectTestEntry(&cache, index);
    try std.testing.expectEqual(@as(usize, 1), cache.long_page_count);
    try expectResultCacheConsistent(&cache);

    // Equal stamps evict in owner-id order.
    var tied = ResultCache{};
    defer tied.deinit(std.testing.allocator);
    try testResize(&tied, std.testing.allocator, 4, test_inline_words, test_long_block_words, 0);
    _ = try tied.reserveLongBlocks(std.testing.allocator, 4);
    for (0..4) |index| putTestEntry(&tied, index * 4, 9, &stats);
    var lowest_index: usize = 0;
    for (0..4) |index| {
        if (tied.core.ownerOf(testGoalKey(index * 4)).? == 0) lowest_index = index * 4;
    }
    try testResize(&tied, std.testing.allocator, 3, test_inline_words, test_long_block_words, 9);
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
    try testResize(&wrapped, std.testing.allocator, 2, test_inline_words, test_long_block_words, 0);
    putTestEntry(&wrapped, 0, std.math.maxInt(u32) - 2, &stats);
    putTestEntry(&wrapped, 4, 3, &stats);
    try testResize(&wrapped, std.testing.allocator, 1, test_inline_words, test_long_block_words, 5);
    try std.testing.expect(wrapped.find(testGoalKey(0)) == null);
    try expectTestEntry(&wrapped, 4);
}

test "pathfinding result cache resize runs out of memory at every allocation and leaves entries and the owner log intact (FailingAllocator)" {
    // Shrink with eviction, shrink without, and grow, at stripe widths that keep one page
    // and at widths whose pages a grow appends and a shrink frees: each allocation the
    // resize makes is failed in turn. A failure leaves the cache whole (limit, widths,
    // every entry and its cells, the logged ops); success keeps the entries that fit.
    const entry_count = 6;
    const Shape = struct { inline_words: usize, targets: [3]usize };
    // 8 stripes of 4096 words per page: 16 entries span 2 pages.
    for ([_]Shape{ .{ .inline_words = test_inline_words, .targets = .{ 2, 8, 64 } }, .{ .inline_words = 4096, .targets = .{ 2, 8, 64 } } }) |shape| {
        for (shape.targets) |target| {
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var stats = PathfindingStats{};
                var cache = ResultCache{};
                defer cache.deinit(std.testing.allocator);
                try testResize(&cache, std.testing.allocator, 16, shape.inline_words, test_long_block_words, 0);
                _ = try cache.reserveLongBlocks(std.testing.allocator, entry_count);
                for (0..entry_count) |index| putTestEntry(&cache, index, @intCast(index), &stats);
                const logged = cache.core.ownerLog().len;

                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
                const outcome = cache.reserve(failing.allocator(), target, shape.inline_words, test_long_block_words, entry_count) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expectEqual(@as(usize, 16), cache.logicalCapacity());
                    try std.testing.expectEqual(shape.inline_words, cache.inline_words);
                    try std.testing.expectEqual(@as(usize, test_long_block_words), cache.long_block_words);
                    try std.testing.expectEqual(logged, cache.core.ownerLog().len);
                    try expectResultCacheConsistent(&cache);
                    for (0..entry_count) |index| try expectTestEntry(&cache, index);
                    // Still fully usable at the old limit.
                    for (0..16) |index| testPut(&cache, testGoalKey(100 + index), &.{1}, &.{}, 0, 0, &stats);
                    try expectResultCacheConsistent(&cache);
                    continue;
                };
                try std.testing.expectEqual(ReserveOutcome.kept, outcome);
                for (cache.pendingMoves()) |move| cache.copyMove(move);
                cache.finishResize(failing.allocator());
                cache.core.finishOwnerLog(failing.allocator());
                try std.testing.expectEqual(target, cache.logicalCapacity());
                try expectResultCacheConsistent(&cache);
                const kept = @min(target, entry_count);
                try std.testing.expectEqual(kept, cache.count());
                for (entry_count - kept..entry_count) |index| try expectTestEntry(&cache, index);
                break;
            }
            try std.testing.expect(fail_index >= 1);
        }
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

// The first stitched index holding `cell` on `level`, by a scalar walk.
fn referenceStitchedIndex(view: StitchedView, level: u16, cell: u32) ?usize {
    for (view.cells, view.levels, 0..) |stored_cell, stored_level, index| {
        if (stored_cell == cell and stored_level == level) return index;
    }
    return null;
}

test "pathfinding stitched exact-match scan in four lanes equals scalar (body, tail, absent, wrong-level match)" {
    // Cells repeat across levels: each cell appears on level 1 before level 0 at a few spots,
    // so a lane hit on the wrong level must keep scanning.
    var stitched: [13]StitchedCell = undefined;
    for (&stitched, 0..) |*cell, index| cell.* = .{ .level = @intCast(index % 2), .cell = @intCast(40 + index / 2) };
    var words: [types.stitchedWords(stitched.len)]u32 = undefined;
    for (0..stitched.len + 1) |len| {
        types.writeStitched(&words, stitched[0..len]);
        const view = types.stitchedView(&words, len);
        for (0..2) |level| {
            for (38..50) |cell| {
                const expected = referenceStitchedIndex(view, @intCast(level), @intCast(cell));
                try std.testing.expectEqual(expected, stitchedExactIndex(view, @intCast(level), @intCast(cell)));
            }
        }
    }
    // Through the waypoint: cell 41 on level 1 sits at index 3, after its level-0 copy at 2.
    var graph = try makeTestGraph(std.testing.allocator, 100, 1);
    defer graph.levels.deinit(std.testing.allocator);
    try graph.levels.append(std.testing.allocator, NavGrid{ .level = 1, .width = 100, .height = 1, .cell_size = 1 });
    types.writeStitched(&words, &stitched);
    var hint: u32 = 99;
    _ = waypointFromStitched(&graph, types.stitchedView(&words, stitched.len), 1, 41, &hint).?;
    try std.testing.expectEqual(@as(u32, 3), hint);
}

test "pathfinding result cache keeps probe chains intact after mid-chain removal" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const capacity = 8;
    try testResize(&cache, std.testing.allocator, capacity, 4, 8, 0);

    // Fill the cache to capacity with distinct goal-keyed entries (no eviction yet).
    for (0..capacity) |i| testPut(&cache, testGoalKey(i), &.{ @intCast(i), @intCast(i + 1) }, &.{}, 0, 0, &stats);
    for (0..capacity) |i| try std.testing.expect(cache.find(testGoalKey(i)) != null);

    // Remove two entries that may sit mid-probe-chain. Without back-shift deletion a later
    // key in a cluster would become unreachable; every surviving key must still be found.
    for ([_]usize{ 2, 5 }) |target| cache.removeAt(cache.slotIndex(testGoalKey(target)).?);
    for (0..capacity) |i| {
        if (i == 2 or i == 5) {
            try std.testing.expect(cache.find(testGoalKey(i)) == null);
        } else {
            try std.testing.expect(cache.find(testGoalKey(i)) != null);
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
    try testResize(&cache, std.testing.allocator, 4, 4, 8, 0);
    // A at its home slot 0, B at its home slot 1, C and D clear of slots 0-2: the round-robin
    // victim is A, and the new key K (home 0) first finds slot 2 empty.
    var taken: [5]usize = undefined;
    taken[0] = testKeyWithHome(8, 0, taken[0..0]);
    taken[1] = testKeyWithHome(8, 1, taken[0..1]);
    taken[2] = testKeyWithHome(8, 4, taken[0..2]);
    taken[3] = testKeyWithHome(8, 5, taken[0..3]);
    taken[4] = testKeyWithHome(8, 0, taken[0..4]);
    for (taken[0..4]) |x| testPut(&cache, testGoalKey(x), &.{1}, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 0), cache.slotIndex(testGoalKey(taken[0])).?);
    try std.testing.expectEqual(@as(usize, 1), cache.slotIndex(testGoalKey(taken[1])).?);

    const new_key = testGoalKey(taken[4]);
    testPut(&cache, new_key, &.{2}, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.slotIndex(new_key) != null);

    // A re-put updates the one slot holding the key, never a duplicate.
    testPut(&cache, new_key, &.{3}, &.{}, 0, 0, &stats);
    var holders: usize = 0;
    for (cache.core.slots.items) |slot| {
        if (slot.occupied and keysEqual(slot.key, new_key)) holders += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), holders);
    try std.testing.expectEqual(@as(usize, 4), cache.count());
    try expectResultCacheConsistent(&cache);
}

test "pathfinding a payload claimed this publish is never chosen as the victim" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    // Eight entries over 16 probe slots: A and B both home at slot 0 (B lands in slot 1),
    // the rest at homes 2..7.
    try testResize(&cache, std.testing.allocator, 8, 4, 8, 0);
    var taken: [10]usize = undefined;
    taken[0] = testKeyWithHome(16, 0, taken[0..0]);
    taken[1] = testKeyWithHome(16, 0, taken[0..1]);
    for (2..8) |home| taken[home] = testKeyWithHome(16, home, taken[0..home]);
    for (taken[0..8]) |x| testPut(&cache, testGoalKey(x), &.{1}, &.{}, 0, 0, &stats);
    // K1 homes at slot 1, which the first victim (A, slot 0) frees by back-shifting B into
    // slot 0; K2 homes clear of the entries.
    taken[8] = testKeyWithHome(16, 1, taken[0..8]);
    taken[9] = testKeyWithHome(16, 12, taken[0..9]);

    // One publish claims K1 then K2. Round-robin reaches K1's slot next, so only the
    // same-publish skip keeps K2 from evicting K1.
    cache.core.finishOwnerLog(std.testing.allocator);
    cache.core.beginPublish();
    testClaimAndCopy(&cache, testGoalKey(taken[8]), &.{5}, &.{}, 0, 1, &stats);
    try std.testing.expectEqual(@as(usize, 1), cache.slotIndex(testGoalKey(taken[8])).?);
    testClaimAndCopy(&cache, testGoalKey(taken[9]), &.{6}, &.{}, 0, 1, &stats);
    try std.testing.expectEqual(@as(usize, 2), stats.cache_evictions);
    try std.testing.expect(cache.find(testGoalKey(taken[8])) != null);
    try std.testing.expect(cache.find(testGoalKey(taken[9])) != null);
    try std.testing.expect(cache.find(testGoalKey(taken[0])) == null);
    try std.testing.expectEqual(@as(usize, 8), cache.count());
    try expectResultCacheConsistent(&cache);
}

test "pathfinding claim then copy stores plain, stitched, inline, and long results exactly" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try testResize(&cache, std.testing.allocator, 8, test_inline_words, test_long_block_words, 0);
    _ = try cache.reserveLongBlocks(std.testing.allocator, 4);
    // Every kind in one publish, then a long one re-put inline and an inline one re-put long.
    cache.core.beginPublish();
    var plain: [10]u32 = undefined;
    var stitched: [5]StitchedCell = undefined;
    for (0..4) |index| {
        for (&plain, 0..) |*cell, offset| cell.* = testEntryCell(index, offset);
        for (&stitched, 0..) |*cell, offset| cell.* = .{ .level = @intCast(index % 3), .cell = testEntryCell(index, offset) };
        const path: []const u32 = switch (index) {
            0 => plain[0..3],
            1 => plain[0..10],
            else => &.{},
        };
        const corridor: []const StitchedCell = switch (index) {
            2 => stitched[0..2],
            3 => stitched[0..5],
            else => &.{},
        };
        testClaimAndCopy(&cache, testGoalKey(index), path, corridor, 0, 0, &stats);
    }
    for (0..4) |index| try expectTestEntry(&cache, index);
    // A stitched entry is its cells column, then two levels per word.
    const stitched_slot = cache.slotIndex(testGoalKey(3)).?;
    const words = cache.storedWords(cache.core.slots.items[stitched_slot].payload_index);
    try std.testing.expectEqualSlices(u32, &.{ 300, 301, 302, 303, 304 }, words[0..5]);
    // Long results hold blocks, inline ones none.
    try std.testing.expectEqual(cache.long_block_count - 2, cache.free_long_blocks.items.len);
    putTestEntry(&cache, 5, 1, &stats);
    testPut(&cache, testGoalKey(1), &.{ 1, 2 }, &.{}, 0, 1, &stats);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, cache.pathSlice(cache.slotIndex(testGoalKey(1)).?, 2));
    try std.testing.expectEqual(cache.long_block_count - 2, cache.free_long_blocks.items.len);
    try expectResultCacheConsistent(&cache);
}

// Records each shrink eviction a core reports.
const EvictionRecorder = struct {
    released: std.ArrayList(u32) = .empty,

    fn releaseRecord(self: *EvictionRecorder, owner: u32) void {
        self.released.append(std.testing.allocator, owner) catch @panic("test allocation");
    }

    fn moveRecord(_: *EvictionRecorder, _: u32, _: u32) void {}
};

const OrderedEntry = struct {
    age: u32,
    owner: u32,

    fn olderThan(_: void, lhs: OrderedEntry, rhs: OrderedEntry) bool {
        if (lhs.age != rhs.age) return lhs.age > rhs.age;
        return lhs.owner < rhs.owner;
    }
};

test "pathfinding the shrink's eviction selection equals the age-sorted reference (ties at the threshold, all ages equal, wraparound ages)" {
    const Core = CacheCore(struct {});
    const Stamps = enum { random_ties, all_equal, wraparound };
    var prng = std.Random.DefaultPrng.init(0x5e1ec7);
    const random = prng.random();
    for (std.meta.tags(Stamps)) |stamps| {
        for ([_]usize{ 1, 7, 33, 60 }) |evict_count| {
            var stats = PathfindingStats{};
            var core = Core{};
            defer core.deinit(std.testing.allocator);
            const capacity = 96;
            var resize = try core.prepareResize(std.testing.allocator, capacity);
            core.commitResize(std.testing.allocator, &resize, 0, NoRecordHooks{});
            const live = 64;
            const step: u32 = switch (stamps) {
                .wraparound => 5,
                else => 1_000_000,
            };
            core.beginPublish();
            for (0..live) |index| {
                const stamp: u32 = switch (stamps) {
                    // Few distinct ages, spread across the high and low bytes.
                    .random_ties => step - (random.uintLessThan(u32, 4) << 16) - random.uintLessThan(u32, 3),
                    .all_equal => step - 9,
                    // Half the stamps sit just below the wrap, half just after it.
                    .wraparound => if (index % 2 == 0) std.math.maxInt(u32) - random.uintLessThan(u32, 8) else random.uintLessThan(u32, 5),
                };
                _ = core.claim(testGoalKey(index), stamp, &stats);
            }
            // Free a few low records so survivors also move.
            for ([_]usize{ 3, 10, 40 }) |index| core.removeAt(core.slotIndex(testGoalKey(index)).?);
            core.finishOwnerLog(std.testing.allocator);
            var reference: std.ArrayList(OrderedEntry) = .empty;
            defer reference.deinit(std.testing.allocator);
            for (core.records.items, 0..) |record, owner| {
                if (record.live) try reference.append(std.testing.allocator, .{ .age = step -% record.stamp, .owner = @intCast(owner) });
            }
            std.mem.sort(OrderedEntry, reference.items, {}, OrderedEntry.olderThan);
            var expected: std.ArrayList(u32) = .empty;
            defer expected.deinit(std.testing.allocator);
            for (reference.items[0..evict_count]) |entry| try expected.append(std.testing.allocator, entry.owner);
            std.mem.sort(u32, expected.items, {}, std.sort.asc(u32));

            var recorder = EvictionRecorder{};
            defer recorder.released.deinit(std.testing.allocator);
            var shrink = try core.prepareResize(std.testing.allocator, core.len - evict_count);
            core.commitResize(std.testing.allocator, &shrink, step, &recorder);
            try std.testing.expectEqualSlices(u32, expected.items, recorder.released.items);
            try std.testing.expectEqual(core.logical_capacity, core.len);
        }
    }
}

test "pathfinding every removal logs one retire and every move one rename, within 2x the larger capacity" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try filledTestCache(&cache, 12, &stats);
    cache.core.finishOwnerLog(std.testing.allocator);
    const owner_of = struct {
        fn at(c: *const ResultCache, index: usize) u32 {
            return c.core.ownerOf(testGoalKey(index)).?;
        }
    }.at;
    // A TTL removal and a re-put each retire their owner; a fresh claim of a free record
    // retires nothing.
    const expired = owner_of(&cache, 0);
    try std.testing.expect(cache.findFresh(testGoalKey(0), 1000, 10) == null);
    const reput = owner_of(&cache, 4);
    cache.core.beginPublish();
    testClaimAndCopy(&cache, testGoalKey(4), &.{ 1, 2 }, &.{}, 0, 13, &stats);
    testClaimAndCopy(&cache, testGoalKey(50), &.{3}, &.{}, 0, 13, &stats);
    try std.testing.expectEqualSlices(OwnerOp, &.{ .{ .old = expired, .new = no_owner }, .{ .old = reput, .new = no_owner } }, cache.core.ownerLog());
    // A full cache's claim retires its victim.
    cache.core.finishOwnerLog(std.testing.allocator);
    for (0..4) |index| putTestEntry(&cache, 60 + index, 14, &stats);
    cache.core.finishOwnerLog(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16), cache.count());
    cache.core.beginPublish();
    testClaimAndCopy(&cache, testGoalKey(70), &.{9}, &.{}, 0, 15, &stats);
    try std.testing.expectEqual(@as(usize, 1), cache.core.ownerLog().len);
    try std.testing.expectEqual(no_owner, cache.core.ownerLog()[0].new);
    cache.core.finishOwnerLog(std.testing.allocator);

    // A shrink to 4: one retire per victim, then one rename per survivor it moves, from
    // past the new capacity to below it.
    _ = try cache.reserve(std.testing.allocator, 4, test_inline_words, test_long_block_words, 16);
    const log = cache.core.ownerLog();
    try std.testing.expect(log.len <= cache.core.owner_log_limit);
    try std.testing.expectEqual(@as(usize, 2 * 16), cache.core.owner_log_limit);
    var retires: usize = 0;
    var renames: usize = 0;
    for (log, 0..) |op, at| {
        if (op.new == no_owner) {
            retires += 1;
            // Every retire precedes every rename.
            try std.testing.expectEqual(at, retires - 1);
        } else {
            renames += 1;
            try std.testing.expect(op.old >= 4 and op.new < 4);
        }
    }
    try std.testing.expectEqual(@as(usize, 12), retires);
    try std.testing.expect(renames != 0 and renames <= 4);
    for (cache.pendingMoves()) |move| cache.copyMove(move);
    cache.finishResize(std.testing.allocator);
    cache.core.finishOwnerLog(std.testing.allocator);
    // The flushed shrink's log shrinks to the new capacity.
    try std.testing.expectEqual(@as(usize, 2 * 4), cache.core.owner_log_limit);
    try std.testing.expect(cache.core.owner_log.capacity < 2 * 16);
    try expectResultCacheConsistent(&cache);
}

// A plain test path of `len` cells starting at `first`.
fn testLongPath(allocator: std.mem.Allocator, len: usize, first: u32) ![]u32 {
    const path = try allocator.alloc(u32, len);
    for (path, 0..) |*cell, offset| cell.* = first + @as(u32, @intCast(offset));
    return path;
}

test "pathfinding a grow keeps every stored path at its address" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    // Eight 4096-word stripes per page: a grow from 8 to 64 entries appends seven pages.
    try testResize(&cache, std.testing.allocator, 8, 4096, test_long_block_words, 0);
    for (0..8) |index| testPut(&cache, testGoalKey(index), &.{ @intCast(index), 7 }, &.{}, 0, 0, &stats);
    var addresses: [8][*]const u32 = undefined;
    for (&addresses, 0..) |*address, index| address.* = cache.storedWords(cache.core.ownerOf(testGoalKey(index)).?).ptr;
    try std.testing.expectEqual(@as(usize, 1), cache.inline_pages.items.len);
    try testResize(&cache, std.testing.allocator, 64, 4096, test_long_block_words, 0);
    try std.testing.expectEqual(@as(usize, 8), cache.inline_pages.items.len);
    for (addresses, 0..) |address, index| {
        const owner = cache.core.ownerOf(testGoalKey(index)).?;
        try std.testing.expectEqual(address, cache.storedWords(owner).ptr);
        try std.testing.expectEqualSlices(u32, &.{ @intCast(index), 7 }, cache.storedWords(owner)[0..2]);
    }
    try expectResultCacheConsistent(&cache);
}

test "pathfinding a long-pool grow keeps every long path at its address" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    // Two 16384-word blocks per page.
    try testResize(&cache, std.testing.allocator, 16, test_inline_words, 16384, 0);
    try std.testing.expectEqual(@as(usize, 1), try cache.reserveLongBlocks(std.testing.allocator, 2));
    for (0..2) |index| putTestEntry(&cache, index * 4 + 1, 0, &stats);
    const before = [_][*]const u32{
        cache.storedWords(cache.core.ownerOf(testGoalKey(1)).?).ptr,
        cache.storedWords(cache.core.ownerOf(testGoalKey(5)).?).ptr,
    };
    try std.testing.expectEqual(@as(usize, 2), try cache.reserveLongBlocks(std.testing.allocator, 3));
    try std.testing.expectEqual(@as(usize, 6), cache.long_block_count);
    try std.testing.expectEqual(before[0], cache.storedWords(cache.core.ownerOf(testGoalKey(1)).?).ptr);
    try std.testing.expectEqual(before[1], cache.storedWords(cache.core.ownerOf(testGoalKey(5)).?).ptr);
    for ([_]usize{ 1, 5 }) |index| try expectTestEntry(&cache, index);
    try expectResultCacheConsistent(&cache);
}

test "pathfinding a shrink frees pages past the new capacity and keeps every surviving path" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    // Eight 4096-word stripes per page and two 16384-word blocks per page.
    const long_words = 16384;
    try testResize(&cache, std.testing.allocator, 64, 4096, long_words, 0);
    try std.testing.expectEqual(@as(usize, 8), cache.inline_pages.items.len);
    _ = try cache.reserveLongBlocks(std.testing.allocator, 8);
    const long_path = try testLongPath(std.testing.allocator, 4100, 9000);
    defer std.testing.allocator.free(long_path);
    for (0..40) |index| {
        if (index % 5 == 0) {
            testPut(&cache, testGoalKey(index), long_path, &.{}, 0, @intCast(index), &stats);
        } else {
            testPut(&cache, testGoalKey(index), &.{ @intCast(index), 3, 4 }, &.{}, 0, @intCast(index), &stats);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), cache.long_page_count);
    // A shrink to 16 keeps the 16 youngest (24..39), three of them long.
    try testResize(&cache, std.testing.allocator, 16, 4096, long_words, 40);
    try std.testing.expectEqual(@as(usize, 2), cache.inline_pages.items.len);
    try std.testing.expectEqual(@as(usize, 2), cache.long_page_count);
    for (0..40) |index| {
        const slot = cache.slotIndex(testGoalKey(index));
        if (index < 24) {
            try std.testing.expect(slot == null);
            continue;
        }
        const result = cache.resultAt(slot.?);
        if (index % 5 == 0) {
            try std.testing.expectEqualSlices(u32, long_path, cache.pathSlice(slot.?, result.path_len));
        } else {
            try std.testing.expectEqualSlices(u32, &.{ @intCast(index), 3, 4 }, cache.pathSlice(slot.?, result.path_len));
        }
    }
    try expectResultCacheConsistent(&cache);
}

test "pathfinding result cache read-path TTL gate is non-mutating and expires stale entries" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try testResize(&cache, std.testing.allocator, 4, 4, 8, 0);
    testPut(&cache, testGoalKey(3), &.{ 0, 1, 2 }, &.{}, 0, 100, &stats); // stamped at step 100

    const ttl: u32 = 50;
    // Within ttl: the read path serves the slot and never evicts (const reader).
    try std.testing.expect(cache.freshSlotIndex(testGoalKey(3), 149, ttl) != null);
    try std.testing.expect(cache.slotIndex(testGoalKey(3)) != null); // still resident
    // At/after ttl: the read path reports a miss so the caller re-requests, but the entry
    // is left in place for acceptRequests' mutating findFresh to evict.
    try std.testing.expect(cache.freshSlotIndex(testGoalKey(3), 150, ttl) == null);
    try std.testing.expect(cache.slotIndex(testGoalKey(3)) != null);
    // ttl 0 disables expiry.
    try std.testing.expect(cache.freshSlotIndex(testGoalKey(3), 100_000, 0) != null);
}

test "pathfinding result cache evicts deterministically and stores paths" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try testResize(&cache, std.testing.allocator, 1, 4, 8, 0);

    testPut(&cache, testGoalKey(1), &.{ 0, 1, 2 }, &.{}, 0, 0, &stats);
    try std.testing.expect(cache.find(testGoalKey(1)) != null);
    testPut(&cache, testGoalKey(2), &.{ 3, 4 }, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.find(testGoalKey(1)) == null);
    const slot = cache.slotIndex(testGoalKey(2)).?;
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
    try testResize(&cache, std.testing.allocator, capacity, 4, 8, 0);

    for (0..capacity) |i| testPut(&cache, testGoalKey(i), &.{@intCast(i)}, &.{}, 0, 0, &stats);
    for (0..capacity) |i| try std.testing.expect(cache.find(testGoalKey(i)) != null);
    // An absent key (never inserted) must resolve to a miss, not loop or misread a
    // neighboring slot's payload.
    try std.testing.expect(cache.find(testGoalKey(capacity + 100)) == null);

    // One more insert past logical capacity evicts exactly one victim; every other key
    // stays resolvable.
    testPut(&cache, testGoalKey(capacity), &.{99}, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.find(testGoalKey(capacity)) != null);
    var survivors: usize = 0;
    for (0..capacity) |i| {
        if (cache.find(testGoalKey(i)) != null) survivors += 1;
    }
    try std.testing.expectEqual(capacity - 1, survivors);
}

test "pathfinding fixed-capacity key set stays correct at full logical occupancy" {
    var keys = KeySet{};
    defer keys.deinit(std.testing.allocator);
    const capacity = 8;
    try keys.reserve(std.testing.allocator, capacity);

    for (0..capacity) |i| try std.testing.expect(keys.insert(testGoalKey(i)));
    for (0..capacity) |i| try std.testing.expect(keys.contains(testGoalKey(i)));
    // A logically-full set rejects a new key (no eviction: KeySet is fixed-capacity,
    // unlike ResultCache) but every absent-key probe still terminates.
    try std.testing.expect(!keys.insert(testGoalKey(capacity)));
    try std.testing.expect(!keys.contains(testGoalKey(capacity)));
}

// Minimal single-level NavGraph for waypoint tests: only the grid dimensions are read, so
// an empty-backed grid of the requested size suffices. Caller must deinit the returned
// graph's level list.
fn makeTestGraph(allocator: std.mem.Allocator, width: usize, height: usize) !NavGraph {
    var graph = NavGraph{ .allocator = allocator, .width = width, .height = height };
    try graph.levels.append(allocator, NavGrid{ .width = width, .height = height, .cell_size = 1 });
    return graph;
}

test "pathfinding group key map keeps probe chains intact after mid-chain removal" {
    var map = GroupKeyMap{};
    defer map.deinit(std.testing.allocator);
    const capacity = 8;
    try map.reserve(std.testing.allocator, capacity);

    for (0..capacity) |i| try std.testing.expect(map.insert(testGoalKey(i), i));
    // Remove two entries that may sit mid-probe-chain; every survivor must stay findable and
    // keep its group index (back-shift deletion must not strand a later key behind the gap).
    for ([_]usize{ 2, 5 }) |target| map.remove(testGoalKey(target));
    for (0..capacity) |i| {
        if (i == 2 or i == 5) {
            try std.testing.expect(map.find(testGoalKey(i)) == null);
        } else {
            try std.testing.expectEqual(i, map.find(testGoalKey(i)).?);
        }
    }
}

test "pathfinding stitched waypoint matches full scan and recovers from a stale hint" {
    var graph = try makeTestGraph(std.testing.allocator, 100, 1);
    defer graph.levels.deinit(std.testing.allocator);
    const grid = graph.grid(0).?;
    var cells: [6]StitchedCell = undefined;
    for (&cells, 0..) |*cell, index| cell.* = .{ .level = 0, .cell = @intCast(10 + index) };
    var words: [types.stitchedWords(cells.len)]u32 = undefined;
    types.writeStitched(&words, &cells);
    const stitched = types.stitchedView(&words, cells.len);

    const baseline = waypointFromStitched(&graph, stitched, 0, 12, null).?;
    try std.testing.expectEqual(grid.cellCenter(13).x, baseline.x);

    var fresh: u32 = 1;
    const hinted = waypointFromStitched(&graph, stitched, 0, 12, &fresh).?;
    try std.testing.expectEqual(baseline.x, hinted.x);
    try std.testing.expectEqual(@as(u32, 2), fresh);

    var stale: u32 = 999;
    const recovered = waypointFromStitched(&graph, stitched, 0, 12, &stale).?;
    try std.testing.expectEqual(baseline.x, recovered.x);
    try std.testing.expectEqual(@as(u32, 2), stale);
}
