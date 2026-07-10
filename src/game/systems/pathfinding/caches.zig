// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Goal-keyed query caches: the fixed-capacity linear-probe pending/negative KeySet
//! and the completed-path ResultCache, plus the per-agent waypoint derivation that
//! turns a cached plain or stitched path into a forward heading.

const std = @import("std");
const math = @import("../../../core/math.zig");
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavGraph = @import("nav_graph.zig").NavGraph;
const types = @import("types.zig");
const PathQueryKey = types.PathQueryKey;
const StitchedCell = types.StitchedCell;
const PathResult = types.PathResult;
const PathfindingStats = types.PathfindingStats;
const setLen = types.setLen;
const shouldShrinkCapacity = types.shouldShrinkCapacity;
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

        fn reserve(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            const physical = capacity *| 2;
            // Free the backing on a shrink so an elastic down-resize releases memory; the
            // probe positions depend on capacity, so a resized table is always rebuilt.
            if (shouldShrinkCapacity(self.slots.capacity, physical)) self.slots.shrinkAndFree(allocator, 0);
            try setLen(&self.slots, allocator, physical);
            // Zeroed immediately after growing (not deferred to clear() below): setLen
            // leaves new slots' `occupied` uninitialized, and a later fallible step added
            // to this function in the future could otherwise leave that memory exposed to
            // a recoverable-OOM caller. Harmless no-op today since nothing fallible follows.
            for (self.slots.items) |*slot| slot.occupied = false;
            self.logical_capacity = capacity;
            self.clear();
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

// Goal-keyed cache. Each entry owns a fixed path buffer so a moving agent can
// derive a forward waypoint from its current cell against the stored path.
//
// SoA layout: the probe-hot {occupied, key, payload_index} slots stay dense so a
// linear-probe scan (slotIndex/findOrEvictSlot) never drags the cold TTL/length
// payload across cache lines. The physical probe table is 2x the logical capacity
// (occupancy never exceeds 50%, so every probe chain ends at an empty slot), while
// the cold payload and the per-entry path/stitched cell stripes stay at logical
// capacity, reached through the slot's payload_index. The indirection also lets
// back-shift deletion move only the small probe slot — never the cell stripes.
pub const ResultCache = struct {
    slots: std.ArrayList(ProbeSlot) = .empty,
    payloads: std.ArrayList(SlotPayload) = .empty,
    path_cells: std.ArrayList(u32) = .empty,
    path_stride: usize = 0,
    // Per-entry full stitched (level,cell) corridor path: one obstacle-aware, mostly
    // grid-adjacent path per entry (the level changes only across an inter-level
    // link). Walked per-agent on its current level exactly like a plain A* path.
    stitched: std.ArrayList(StitchedCell) = .empty,
    stitched_stride: usize = 0,
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
        self.stitched.deinit(allocator);
        self.path_cells.deinit(allocator);
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

    pub fn reserve(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, path_stride: usize, stitched_stride: usize) !void {
        // Totals computed from locals; strides are committed to self only after all
        // allocations succeed so a mid-reserve OOM never leaves mismatched strides.
        const physical = capacity *| 2;
        const total_cells = capacity *| path_stride;
        const total_stitched = capacity *| stitched_stride;
        // Free the backing on a shrink so an elastic down-resize releases memory; slot
        // probe positions and per-entry strides depend on capacity, so a resized cache
        // is always rebuilt (the goal-keyed entries re-solve on next request).
        if (shouldShrinkCapacity(self.slots.capacity, physical)) self.slots.shrinkAndFree(allocator, 0);
        if (shouldShrinkCapacity(self.payloads.capacity, capacity)) self.payloads.shrinkAndFree(allocator, 0);
        if (shouldShrinkCapacity(self.path_cells.capacity, total_cells)) self.path_cells.shrinkAndFree(allocator, 0);
        if (shouldShrinkCapacity(self.stitched.capacity, total_stitched)) self.stitched.shrinkAndFree(allocator, 0);
        if (shouldShrinkCapacity(self.free_payload_indices.capacity, capacity)) self.free_payload_indices.shrinkAndFree(allocator, 0);
        if (shouldShrinkCapacity(self.evict_scratch.capacity, capacity)) self.evict_scratch.shrinkAndFree(allocator, 0);
        try setLen(&self.slots, allocator, physical);
        // Zeroed immediately (not deferred to clear() below): setLen leaves new slots'
        // `occupied` uninitialized, and any of the further allocations below can still
        // fail — a recoverable-OOM caller must never read stale/undefined occupancy off
        // an abandoned mid-reserve table.
        for (self.slots.items) |*slot| slot.occupied = false;
        try setLen(&self.payloads, allocator, capacity);
        try setLen(&self.path_cells, allocator, total_cells);
        @memset(self.path_cells.items, no_cell);
        try setLen(&self.stitched, allocator, total_stitched);
        @memset(self.stitched.items, .{ .level = 0, .cell = no_cell });
        try self.free_payload_indices.ensureTotalCapacity(allocator, capacity);
        try self.evict_scratch.ensureTotalCapacity(allocator, capacity);
        // All allocations succeeded; safe to commit the new strides and capacity.
        self.path_stride = path_stride;
        self.stitched_stride = stitched_stride;
        self.logical_capacity = capacity;
        self.clear();
    }

    pub fn clear(self: *ResultCache) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.free_payload_indices.clearRetainingCapacity();
        for (0..self.logical_capacity) |payload_index| {
            self.free_payload_indices.appendAssumeCapacity(@intCast(payload_index));
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
        for (self.slots.items, 0..) |slot, slot_index| {
            if (!slot.occupied) continue;
            if (self.crossesSpans(graph, slot_index, self.payloads.items[slot.payload_index], spans)) {
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
        self.free_payload_indices.appendAssumeCapacity(self.slots.items[index].payload_index);
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

    fn crossesSpans(self: *const ResultCache, graph: *const NavGraph, slot_index: usize, payload: SlotPayload, spans: []const ChangedSpan) bool {
        if (payload.stitched_len != 0) {
            for (self.stitchedSlice(slot_index, payload.stitched_len)) |sc| {
                if (sc.cell != no_cell and cellInSpans(graph, sc.level, sc.cell, spans)) return true;
            }
            return false;
        }
        for (self.pathSlice(slot_index, payload.path_len)) |cell| {
            if (cell != no_cell and cellInSpans(graph, payload.path_level, cell, spans)) return true;
        }
        // A plain path that filled the whole stride may be stride-downsampled into non-adjacent
        // samples (downsamplePathInto), so an edit landing between two stored samples is invisible
        // to the per-cell scan above. Conservatively treat such a slot as crossing whenever an
        // edited span touches its level; it simply re-solves. Over-evicts only the boundary case
        // (a path exactly stride-long is adjacent), never under-evicts. Paths shorter than the
        // stride are stored exactly and stay precise.
        if (payload.path_len == self.path_stride and levelInSpans(payload.path_level, spans)) return true;
        return false;
    }

    // `slot_index` is the PROBE slot index (as returned by slotIndex/freshSlotIndex),
    // not a payload index; both slices translate through the slot's payload_index so
    // callers never need to know the indirection exists.
    pub fn pathSlice(self: *const ResultCache, slot_index: usize, path_len: usize) []const u32 {
        const base: usize = @as(usize, self.slots.items[slot_index].payload_index) * self.path_stride;
        return self.path_cells.items[base .. base + @min(path_len, self.path_stride)];
    }

    pub fn stitchedSlice(self: *const ResultCache, slot_index: usize, stitched_len: usize) []const StitchedCell {
        const base: usize = @as(usize, self.slots.items[slot_index].payload_index) * self.stitched_stride;
        return self.stitched.items[base .. base + @min(stitched_len, self.stitched_stride)];
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
        const index = self.slotIndex(key) orelse return null;
        const payload_index = self.slots.items[index].payload_index;
        if (ttl != 0 and (step -% self.payloads.items[payload_index].stamp) >= ttl) return null;
        return index;
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

    // Writes a plain local-solve path (start-to-goal cell order) on `path_level` plus
    // an optional full stitched (level,cell) corridor path. The plain path, when used,
    // is only downsampled when it exceeds the stride; the stitched path is bounded at
    // the solve side and stored whole, so its consecutive cells stay traversable.
    pub fn put(self: *ResultCache, key: PathQueryKey, path: []const u32, stitched: []const StitchedCell, path_level: u16, step: u32, stats: *PathfindingStats) void {
        if (self.logical_capacity == 0 or self.path_stride == 0) return;
        const slot_index = self.findOrEvictSlot(key, stats);
        const payload_index = self.slots.items[slot_index].payload_index;
        const stored_len = self.writePath(payload_index, path);
        const stitched_len = self.writeStitched(payload_index, stitched);
        self.payloads.items[payload_index] = .{
            .stamp = step,
            .path_len = @intCast(stored_len),
            .path_level = path_level,
            .stitched_len = @intCast(stitched_len),
        };
    }

    fn writeStitched(self: *ResultCache, payload_index: u32, stitched: []const StitchedCell) usize {
        if (self.stitched_stride == 0) return 0;
        // Holds by construction, not by convention: stitchCorridor's cap and this stride
        // both trace back to the same capacity.max_stitched_path_cells (via
        // recordStitched's worker-pool stride), so a stitched corridor is genuinely
        // "stored whole" here, never truncated. Assert rather than @min-and-truncate so a
        // future drift between the two fails loud (a silent truncation would dead-end the
        // agent at the cut point and under-evict on a later edit past it).
        std.debug.assert(stitched.len <= self.stitched_stride);
        const base: usize = @as(usize, payload_index) * self.stitched_stride;
        @memcpy(self.stitched.items[base .. base + stitched.len], stitched);
        return stitched.len;
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
                // Logically full (every payload slot owned) but the physical probe table is
                // never more than 50% occupied, so an empty PHYSICAL slot exists (this one)
                // without an available payload. Evict a round-robin victim — skipping empty
                // physical slots, since occupancy is sparse — to free its payload_index, then
                // claim this empty physical slot for the new key.
                while (!self.slots.items[self.next_evict].occupied) {
                    self.next_evict = (self.next_evict + 1) % capacity;
                }
                const victim = self.next_evict;
                self.next_evict = (self.next_evict + 1) % capacity;
                stats.cache_evictions += 1;
                self.removeAt(victim);
                const payload_index = self.free_payload_indices.pop().?;
                self.slots.items[index] = .{ .occupied = true, .key = key, .payload_index = payload_index };
                self.len += 1;
                return index;
            }
        }
        unreachable; // physical capacity is 2x logical_capacity; an empty slot always exists
    }

    fn writePath(self: *ResultCache, payload_index: u32, path: []const u32) usize {
        const base: usize = @as(usize, payload_index) * self.path_stride;
        const dst = self.path_cells.items[base .. base + self.path_stride];
        // One shared contract with the worker solve buffer: copy when it fits, else
        // stride-downsample so the stored path still spans start->goal.
        return types.downsamplePathInto(dst, path);
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
// is kept off the probe-scan cache lines.
// Field order: three u32s first, then the u16, to avoid the 2-byte internal-padding hole
// that placing u16 between two u32s would otherwise create. Total size: 16 bytes.
pub const SlotPayload = struct {
    // step_counter when the entry was written, for TTL refresh.
    stamp: u32 = 0,
    path_len: u32 = 0,
    stitched_len: u32 = 0,
    path_level: u16 = 0,
};

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

// Whether any changed span touches `level`. Used to conservatively evict downsampled plain
// paths whose stored samples can hide an edit that falls between them.
fn levelInSpans(level: u16, spans: []const ChangedSpan) bool {
    for (spans) |s| {
        if (s.level == level) return true;
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
    // Single pass: an exact match returns immediately; otherwise nearest cell is tracked
    // for the off-path fallback, avoiding a second full scan.
    const start_x: i32 = @intCast(start_index % grid.width);
    const start_y: i32 = @intCast(start_index / grid.width);
    var best_index: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    for (path, 0..) |cell, i| {
        if (cell == start_index) return waypointAt(grid, path, i, hint);
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

test "pathfinding result cache keeps probe chains intact after mid-chain removal" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const capacity = 8;
    try cache.reserve(std.testing.allocator, capacity, 4, 8);

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

test "pathfinding result cache read-path TTL gate is non-mutating and expires stale entries" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 4, 4, 8);
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
    try cache.reserve(std.testing.allocator, 1, 4, 8);
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
    try cache.reserve(std.testing.allocator, capacity, 4, 8);

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
    try cache.reserve(std.testing.allocator, 4, 8, 8);

    // Crossing path runs along row 0 through cell (2,0); clear path sits on row 5. Both are
    // stored exactly (length < stride), so the per-cell scan is precise — no conservative branch.
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
    try cache.reserve(std.testing.allocator, capacity, 8, 8);

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
    try cache.reserve(std.testing.allocator, 4, 4, 8);

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

test "pathfinding result cache evicts a downsampled path edited between stored samples" {
    var stats = PathfindingStats{};
    var graph = try makeTestGraph(std.testing.allocator, 10, 10);
    defer graph.levels.deinit(std.testing.allocator);
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const stride = 4;
    try cache.reserve(std.testing.allocator, 2, stride, 8);

    // An 8-cell row-0 path is stride-downsampled to samples {0,2,4,7}; cell 5 lies ON the path
    // but BETWEEN two stored samples. An edit at (5,0) is invisible to the stored-cell scan, so
    // without the conservative downsample rule the slot survives a real obstruction until TTL.
    var key = emptyKey(1);
    key.goal.x = 7;
    cache.put(key, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &.{}, 0, 0, &stats);
    try std.testing.expectEqual(@as(u32, stride), cache.resultAt(cache.slotIndex(key).?).path_len);

    const spans = [_]ChangedSpan{.{ .level = 0, .span = .{ .min_x = 5, .max_x = 5, .min_y = 0, .max_y = 0 } }};
    cache.evictCrossing(&graph, &spans);
    try std.testing.expect(cache.find(key) == null); // conservatively evicted despite the gap
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

test "pathfinding result cache downsamples an over-stride path to span start and goal" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    const stride = 4;
    try cache.reserve(std.testing.allocator, 2, stride, 8);

    // A path longer than the stride is downsampled, not head-truncated: it keeps the
    // stride length and still spans start->goal, so the agent reaches the goal instead
    // of dead-ending at the truncation boundary (which would store the head [10..13]).
    var key = emptyKey(1);
    key.goal.x = 7;
    const long = [_]u32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    cache.put(key, &long, &.{}, 0, 0, &stats);
    const slot = cache.slotIndex(key).?;
    const stored = cache.pathSlice(slot, cache.resultAt(slot).path_len);
    try std.testing.expectEqual(@as(usize, stride), stored.len);
    try std.testing.expectEqual(@as(u32, 10), stored[0]); // start preserved
    try std.testing.expectEqual(@as(u32, 17), stored[stored.len - 1]); // goal preserved
}
