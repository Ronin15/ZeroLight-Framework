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
pub const ResultCache = struct {
    slots: std.ArrayList(ResultCacheSlot) = .empty,
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
        self.slots.deinit(allocator);
        self.* = undefined;
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
        if (total_cells < self.path_cells.capacity) self.path_cells.shrinkAndFree(allocator, 0);
        if (total_stitched < self.stitched.capacity) self.stitched.shrinkAndFree(allocator, 0);
        try setLen(&self.slots, allocator, capacity);
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
            if (slot.occupied and keysEqual(slot.result.key, key)) return index;
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }

    pub fn find(self: *const ResultCache, key: PathQueryKey) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        return self.slots.items[index].result;
    }

    // Writes a plain local-solve path (start-to-goal cell order) on `path_level` plus
    // an optional full stitched (level,cell) corridor path. The plain path, when used,
    // is only downsampled when it exceeds the stride; the stitched path is bounded at
    // the solve side and stored whole, so its consecutive cells stay traversable.
    pub fn put(self: *ResultCache, key: PathQueryKey, path: []const u32, stitched: []const StitchedCell, path_level: u16, stats: *PathfindingStats) void {
        const capacity = self.slots.items.len;
        if (capacity == 0 or self.path_stride == 0) return;
        const slot_index = self.findOrEvictSlot(key, stats);
        const stored_len = self.writePath(slot_index, path);
        const stitched_len = self.writeStitched(slot_index, stitched);
        self.slots.items[slot_index] = .{
            .occupied = true,
            .result = .{ .key = key, .path_len = stored_len, .path_level = path_level, .stitched_len = stitched_len },
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
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.result.key, key)) return index;
            if (!slot.occupied and self.len < capacity) {
                self.len += 1;
                return index;
            }
        }
        const index = self.next_evict;
        self.next_evict = (self.next_evict + 1) % capacity;
        stats.cache_evictions += 1;
        return index;
    }

    pub fn writePath(self: *ResultCache, slot_index: usize, path: []const u32) usize {
        const base = slot_index * self.path_stride;
        const dst = self.path_cells.items[base .. base + self.path_stride];
        if (path.len <= self.path_stride) {
            @memcpy(dst[0..path.len], path);
            return path.len;
        }
        // Downsample by stride to preserve forward direction within the budget.
        const stored = self.path_stride;
        for (0..stored) |i| {
            const src_index = (i * (path.len - 1)) / (stored - 1);
            dst[i] = path[src_index];
        }
        return stored;
    }
};
pub const ResultCacheSlot = struct {
    occupied: bool = false,
    result: PathResult = .{ .key = emptyKey(0), .path_len = 0 },
};

// Per-agent waypoint derivation against a cached path. This is the per-step,
// per-entity refinement promised by the goal-keyed cache.
pub fn waypointFromPath(grid: *const NavGrid, path: []const u32, start_index: usize) ?math.Vec2 {
    if (path.len == 0) return null;
    if (path.len == 1) return grid.cellCenter(path[0]);
    // Exact match: step to the next cell on the path.
    for (path[0 .. path.len - 1], 0..) |cell, i| {
        if (cell == start_index) return grid.cellCenter(path[i + 1]);
    }
    if (path[path.len - 1] == start_index) return grid.cellCenter(path[path.len - 1]);
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
    const next = if (best_index + 1 < path.len) best_index + 1 else best_index;
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
pub fn waypointFromStitched(graph: *const NavGraph, stitched: []const StitchedCell, start_level: u16, start_index: usize) ?math.Vec2 {
    const start_grid = graph.grid(start_level) orelse return null;
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
                const next = if (j + 1 < run_end) j + 1 else j;
                return start_grid.cellCenter(stitched[next].cell);
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
    const next = if (nearest + 1 < best_run_end) nearest + 1 else nearest;
    return start_grid.cellCenter(stitched[next].cell);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

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

test "pathfinding result cache evicts deterministically and stores paths" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 1, 4, 8);
    var first_key = emptyKey(1);
    first_key.goal.x = 1;
    var second_key = emptyKey(1);
    second_key.goal.x = 2;

    cache.put(first_key, &.{ 0, 1, 2 }, &.{}, 0, &stats);
    try std.testing.expect(cache.find(first_key) != null);
    cache.put(second_key, &.{ 3, 4 }, &.{}, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.find(first_key) == null);
    const slot = cache.slotIndex(second_key).?;
    const stored = cache.pathSlice(slot, cache.slots.items[slot].result.path_len);
    try std.testing.expectEqual(@as(usize, 2), stored.len);
    try std.testing.expectEqual(@as(u32, 3), stored[0]);
}
