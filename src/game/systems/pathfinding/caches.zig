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

pub const KeySet = struct {
    // Fixed-capacity linear-probe set for pending keys. Full sets drop new inserts
    // instead of allocating during the fixed-step update.
    slots: std.ArrayList(KeySetSlot) = .empty,
    len: usize = 0,

    pub fn deinit(self: *KeySet, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *KeySet, allocator: std.mem.Allocator, capacity: usize) !void {
        // Free the backing on a shrink so an elastic down-resize releases memory; the
        // probe positions depend on capacity, so a resized set is always rebuilt.
        if (capacity < self.slots.capacity) self.slots.shrinkAndFree(allocator, 0);
        try setLen(&self.slots, allocator, capacity);
        self.clear();
    }

    pub fn clear(self: *KeySet) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.len = 0;
    }

    pub fn contains(self: *const KeySet, key: PathQueryKey) bool {
        return self.findIndex(key) != null;
    }

    pub fn insert(self: *KeySet, key: PathQueryKey) bool {
        const capacity = self.slots.items.len;
        if (capacity == 0) return false;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return true;
            if (!slot.occupied and self.len < capacity) {
                self.slots.items[index] = .{ .occupied = true, .key = key };
                self.len += 1;
                return true;
            }
        }
        return false;
    }

    pub fn findIndex(self: *const KeySet, key: PathQueryKey) ?usize {
        const capacity = self.slots.items.len;
        if (capacity == 0) return null;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return index;
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }
};

pub const KeySetSlot = struct {
    occupied: bool = false,
    key: PathQueryKey = emptyKey(0),
};

// Goal-keyed cache. Each slot owns a fixed path buffer so a moving agent can
// derive a forward waypoint from its current cell against the stored path.
//
// SoA layout: the probe-hot {occupied, key} slots stay dense so a linear-probe scan
// (slotIndex/findOrEvictSlot) never drags the cold TTL/length payload across cache
// lines. The cold payload (stamp + path/stitched lengths + level) is a parallel array
// indexed by the same slot, alongside the per-slot path/stitched cell stripes.
pub const ResultCache = struct {
    slots: std.ArrayList(ProbeSlot) = .empty,
    payloads: std.ArrayList(SlotPayload) = .empty,
    path_cells: std.ArrayList(u32) = .empty,
    path_stride: usize = 0,
    // Per-slot full stitched (level,cell) corridor path: one obstacle-aware, mostly
    // grid-adjacent path per slot (the level changes only across an inter-level
    // link). Walked per-agent on its current level exactly like a plain A* path.
    stitched: std.ArrayList(StitchedCell) = .empty,
    stitched_stride: usize = 0,
    len: usize = 0,
    next_evict: usize = 0,

    pub fn deinit(self: *ResultCache, allocator: std.mem.Allocator) void {
        self.stitched.deinit(allocator);
        self.path_cells.deinit(allocator);
        self.payloads.deinit(allocator);
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    // Reconstructs the full PathResult for a slot from its hot key and cold payload.
    pub fn resultAt(self: *const ResultCache, index: usize) PathResult {
        const payload = self.payloads.items[index];
        return .{
            .key = self.slots.items[index].key,
            .path_len = payload.path_len,
            .path_level = payload.path_level,
            .stitched_len = payload.stitched_len,
        };
    }

    pub fn reserve(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, path_stride: usize, stitched_stride: usize) !void {
        self.path_stride = path_stride;
        self.stitched_stride = stitched_stride;
        // Free the backing on a shrink so an elastic down-resize releases memory; slot
        // probe positions and per-slot strides depend on capacity, so a resized cache
        // is always rebuilt (the goal-keyed entries re-solve on next request).
        const total_cells = capacity * path_stride;
        const total_stitched = capacity * stitched_stride;
        if (capacity < self.slots.capacity) self.slots.shrinkAndFree(allocator, 0);
        if (capacity < self.payloads.capacity) self.payloads.shrinkAndFree(allocator, 0);
        if (total_cells < self.path_cells.capacity) self.path_cells.shrinkAndFree(allocator, 0);
        if (total_stitched < self.stitched.capacity) self.stitched.shrinkAndFree(allocator, 0);
        try setLen(&self.slots, allocator, capacity);
        try setLen(&self.payloads, allocator, capacity);
        try setLen(&self.path_cells, allocator, total_cells);
        @memset(self.path_cells.items, no_cell);
        try setLen(&self.stitched, allocator, total_stitched);
        @memset(self.stitched.items, .{ .level = 0, .cell = no_cell });
        self.clear();
    }

    pub fn clear(self: *ResultCache) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.len = 0;
        self.next_evict = 0;
    }

    // Evicts only cached paths crossing a changed span; paths clear of the edited cells
    // survive and keep serving hits. Matches on the stored corridor (or plain) cells.
    // Removal uses back-shift deletion (removeAt), which can relocate later entries to
    // keep probe chains gap-free, so we restart the scan after each eviction rather than
    // iterate-while-mutating. Evictions are rare/bounded, so the restart cost is fine.
    pub fn evictCrossing(self: *ResultCache, graph: *const NavGraph, spans: []const ChangedSpan) void {
        if (spans.len == 0) return;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.slots.items, 0..) |slot, slot_index| {
                if (!slot.occupied) continue;
                if (self.crossesSpans(graph, slot_index, self.payloads.items[slot_index], spans)) {
                    self.removeAt(slot_index);
                    changed = true;
                    break;
                }
            }
        }
    }

    // Back-shift deletion for the open-addressed slot table. Clearing a slot in the middle
    // of a probe run would strand later keys behind the gap (lookups early-terminate on the
    // first truly-empty slot), so we pull up any following entry whose home position lets it
    // fill the hole, moving its slot struct AND its per-slot path/stitched payload together.
    // Keeps every probe chain contiguous, which is what the `len < capacity` early-out relies on.
    fn removeAt(self: *ResultCache, index: usize) void {
        const capacity = self.slots.items.len;
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
            self.payloads.items[hole] = self.payloads.items[probe];
            self.moveSlotCells(probe, hole);
            self.slots.items[probe].occupied = false;
            hole = probe;
        }
    }

    // Copies a slot's path and stitched cell stripes from one index to another (back-shift
    // move). The {occupied,key} slot and the cold payload are moved by the caller.
    fn moveSlotCells(self: *ResultCache, from: usize, to: usize) void {
        if (self.path_stride != 0) {
            const fb = from * self.path_stride;
            const tb = to * self.path_stride;
            @memcpy(self.path_cells.items[tb .. tb + self.path_stride], self.path_cells.items[fb .. fb + self.path_stride]);
        }
        if (self.stitched_stride != 0) {
            const fb = from * self.stitched_stride;
            const tb = to * self.stitched_stride;
            @memcpy(self.stitched.items[tb .. tb + self.stitched_stride], self.stitched.items[fb .. fb + self.stitched_stride]);
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
        return false;
    }

    pub fn pathSlice(self: *const ResultCache, slot_index: usize, path_len: usize) []const u32 {
        const base = slot_index * self.path_stride;
        return self.path_cells.items[base .. base + @min(path_len, self.path_stride)];
    }

    pub fn stitchedSlice(self: *const ResultCache, slot_index: usize, stitched_len: usize) []const StitchedCell {
        const base = slot_index * self.stitched_stride;
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
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }

    pub fn find(self: *const ResultCache, key: PathQueryKey) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        return self.resultAt(index);
    }

    // find, but a result older than `ttl` steps is dropped (returns null) so the caller
    // re-solves it against current geometry. ttl 0 disables expiry.
    pub fn findFresh(self: *ResultCache, key: PathQueryKey, step: u32, ttl: u32) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        if (ttl != 0 and (step -% self.payloads.items[index].stamp) >= ttl) {
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
        const capacity = self.slots.items.len;
        if (capacity == 0 or self.path_stride == 0) return;
        const slot_index = self.findOrEvictSlot(key, stats);
        const stored_len = self.writePath(slot_index, path);
        const stitched_len = self.writeStitched(slot_index, stitched);
        self.slots.items[slot_index] = .{ .occupied = true, .key = key };
        self.payloads.items[slot_index] = .{
            .stamp = step,
            .path_len = @intCast(stored_len),
            .path_level = path_level,
            .stitched_len = @intCast(stitched_len),
        };
    }

    pub fn writeStitched(self: *ResultCache, slot_index: usize, stitched: []const StitchedCell) usize {
        if (self.stitched_stride == 0) return 0;
        const base = slot_index * self.stitched_stride;
        const copy_len = @min(stitched.len, self.stitched_stride);
        @memcpy(self.stitched.items[base .. base + copy_len], stitched[0..copy_len]);
        return copy_len;
    }

    pub fn findOrEvictSlot(self: *ResultCache, key: PathQueryKey, stats: *PathfindingStats) usize {
        const capacity = self.slots.items.len;
        std.debug.assert(capacity != 0); // callers guard this; assert before `% capacity`
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return index;
            if (!slot.occupied and self.len < capacity) {
                self.len += 1;
                return index;
            }
        }
        // Table full: evict a victim (round-robin) with back-shift, then place the new key
        // at its proper probe position so it stays reachable once the table later drops
        // below capacity (a victim written at next_evict could otherwise sit off its chain).
        const victim = self.next_evict;
        self.next_evict = (self.next_evict + 1) % capacity;
        stats.cache_evictions += 1;
        self.removeAt(victim);
        const start_new = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start_new + probe) % capacity;
            if (!self.slots.items[index].occupied) {
                self.len += 1;
                return index;
            }
        }
        unreachable; // removeAt freed exactly one slot
    }

    pub fn writePath(self: *ResultCache, slot_index: usize, path: []const u32) usize {
        const base = slot_index * self.path_stride;
        const dst = self.path_cells.items[base .. base + self.path_stride];
        // One shared contract with the worker solve buffer: copy when it fits, else
        // stride-downsample so the stored path still spans start->goal.
        return types.downsamplePathInto(dst, path);
    }
};
// Probe-hot slot: only the fields a linear-probe scan touches (occupancy + key).
pub const ProbeSlot = struct {
    occupied: bool = false,
    key: PathQueryKey = emptyKey(0),
};

// Cold per-slot payload, parallel to ProbeSlot. Read only on a hit / TTL check, so it
// is kept off the probe-scan cache lines.
pub const SlotPayload = struct {
    // step_counter when the entry was written, for TTL refresh.
    stamp: u32 = 0,
    path_len: u32 = 0,
    path_level: u16 = 0,
    stitched_len: u32 = 0,
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
    // Exact match: step to the next cell on the path.
    for (path[0 .. path.len - 1], 0..) |cell, i| {
        if (cell == start_index) return waypointAt(grid, path, i, hint);
    }
    if (path[path.len - 1] == start_index) return waypointAt(grid, path, path.len - 1, hint);
    // Off-path: head toward the nearest path cell's successor.
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
    var i: usize = 0;
    var best_run_begin: ?usize = null;
    var best_run_end: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
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
                best_run_begin = run_begin;
                best_run_end = run_end;
            }
        }
    }
    const run_begin = best_run_begin orelse return null;
    // Off-path on this level: head toward the nearest run cell's successor. The run is
    // grid-adjacent, so the successor is one traversable step from the nearest cell.
    var nearest = run_begin;
    var nearest_dist: i64 = std.math.maxInt(i64);
    for (run_begin..best_run_end) |j| {
        const cx: i32 = @intCast(stitched[j].cell % start_grid.width);
        const cy: i32 = @intCast(stitched[j].cell / start_grid.width);
        const ddx: i64 = cx - start_x;
        const ddy: i64 = cy - start_y;
        const dist = ddx * ddx + ddy * ddy;
        if (dist < nearest_dist) {
            nearest_dist = dist;
            nearest = j;
        }
    }
    return stitchedWaypointAt(start_grid, stitched, start_level, nearest, hint);
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
