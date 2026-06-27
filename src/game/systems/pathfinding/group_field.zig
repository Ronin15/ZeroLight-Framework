// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Demand-driven reverse-Dijkstra shared-goal flow field built with Dial's
//! monotone bucket queue, lazily built and budgeted across frames. Agents sample
//! the per-cell flow direction toward a shared declared goal.

const std = @import("std");
const math = @import("../../../core/math.zig");
const NavGrid = @import("nav_grid.zig").NavGrid;
const types = @import("types.zig");
const diagonal_cost = types.diagonal_cost;
const cardinal_cost = types.cardinal_cost;
const unreachable_cost = types.unreachable_cost;
const no_cell = types.no_cell;
const neighbor_dirs = types.neighbor_dirs;
const oppositeDirIndex = types.oppositeDirIndex;
const setLen = types.setLen;
const GridCell = types.GridCell;
const PathQueryKey = types.PathQueryKey;
const emptyKey = types.emptyKey;

// Reverse-Dijkstra managed shared-goal flow field. Built lazily and budgeted
// across frames; an agent samples the flow direction at its current cell.
pub const GroupFieldState = enum {
    empty,
    building,
    ready,
};

// Bucket count for the integration's monotone bucket queue (Dial's algorithm). Step
// costs are octile {cardinal_cost, diagonal_cost}, so a (current_distance % B) bucket
// holds only cells at exactly current_distance when B > max step cost.
pub const group_field_buckets: u32 = diagonal_cost + 1;

pub const GroupField = struct {
    state: GroupFieldState = .empty,
    key: PathQueryKey = emptyKey(0),
    goal_index: usize = 0,
    generation: u32 = 1,
    last_build_step: u32 = 0,
    // Monotone distance cursor for the bucket queue; resumed across budgeted frames.
    current_distance: u32 = 0,
    // Set when (re)built this step so reuse is not double-counted in the same step.
    fresh_this_step: bool = false,
    // Integration cost-to-goal and per-cell flow direction (index into neighbor_dirs,
    // or no_flow). stamps gate costs/flow_dir to the current build without a clear.
    costs: std.ArrayList(u32) = .empty,
    flow_dir: std.ArrayList(u8) = .empty,
    stamps: std.ArrayList(u32) = .empty,
    // Dial's bucket queue: `buckets` holds per-bucket head cell indices; `bucket_next`/
    // `bucket_prev` are intrusive per-cell links so a decrease-key unlinks in O(1). A
    // cell is in at most one bucket; `queued_stamp == generation` marks it queued.
    buckets: std.ArrayList(u32) = .empty,
    bucket_next: std.ArrayList(u32) = .empty,
    bucket_prev: std.ArrayList(u32) = .empty,
    queued_stamp: std.ArrayList(u32) = .empty,

    pub const no_flow: u8 = 0xff;

    pub fn deinit(self: *GroupField, allocator: std.mem.Allocator) void {
        self.queued_stamp.deinit(allocator);
        self.bucket_prev.deinit(allocator);
        self.bucket_next.deinit(allocator);
        self.buckets.deinit(allocator);
        self.stamps.deinit(allocator);
        self.flow_dir.deinit(allocator);
        self.costs.deinit(allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *GroupField, allocator: std.mem.Allocator, cell_count: usize) !void {
        try setLen(&self.costs, allocator, cell_count);
        try setLen(&self.flow_dir, allocator, cell_count);
        try setLen(&self.stamps, allocator, cell_count);
        try setLen(&self.buckets, allocator, group_field_buckets);
        try setLen(&self.bucket_next, allocator, cell_count);
        try setLen(&self.bucket_prev, allocator, cell_count);
        try setLen(&self.queued_stamp, allocator, cell_count);
        @memset(self.costs.items, unreachable_cost);
        @memset(self.flow_dir.items, no_flow);
        @memset(self.stamps.items, 0);
        @memset(self.buckets.items, no_cell);
        @memset(self.queued_stamp.items, 0);
        self.state = .empty;
    }

    pub fn cost(self: *const GroupField, index: usize) u32 {
        return if (self.stamps.items[index] == self.generation) self.costs.items[index] else unreachable_cost;
    }

    pub fn setCost(self: *GroupField, index: usize, value: u32, dir: u8) void {
        self.stamps.items[index] = self.generation;
        self.costs.items[index] = value;
        self.flow_dir.items[index] = dir;
    }

    pub fn nextGeneration(self: *GroupField) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.stamps.items, 0);
            @memset(self.queued_stamp.items, 0);
            self.generation = 1;
        }
    }

    // Links `index` (already costed) into its distance bucket at the head.
    pub fn bucketPush(self: *GroupField, index: usize, distance: u32) void {
        const b = distance % group_field_buckets;
        const head = self.buckets.items[b];
        self.bucket_next.items[index] = head;
        self.bucket_prev.items[index] = no_cell;
        if (head != no_cell) self.bucket_prev.items[head] = @intCast(index);
        self.buckets.items[b] = @intCast(index);
        self.queued_stamp.items[index] = self.generation;
    }

    // Unlinks `index` from its current distance bucket in O(1).
    pub fn bucketUnlink(self: *GroupField, index: usize, distance: u32) void {
        const prev = self.bucket_prev.items[index];
        const next = self.bucket_next.items[index];
        if (prev != no_cell) {
            self.bucket_next.items[prev] = next;
        } else {
            self.buckets.items[distance % group_field_buckets] = next;
        }
        if (next != no_cell) self.bucket_prev.items[next] = prev;
    }

    pub fn beginBuild(self: *GroupField, grid: *const NavGrid, key: PathQueryKey, goal_index: usize, step: u32) bool {
        self.key = key;
        self.goal_index = goal_index;
        self.last_build_step = step;
        self.nextGeneration();
        @memset(self.buckets.items, no_cell);
        self.current_distance = 0;
        if (grid.isBlockedIndex(goal_index)) {
            self.state = .empty;
            return false;
        }
        self.setCost(goal_index, 0, no_flow);
        self.bucketPush(goal_index, 0);
        self.state = .building;
        return true;
    }

    // Expands at most `budget` cells of the integration via Dial's monotone bucket
    // queue. Returns true when the field finished. The distance cursor advances only
    // forward, so the build resumes correctly across budgeted frames.
    pub fn expand(self: *GroupField, grid: *const NavGrid, budget: usize) bool {
        var expansions: usize = 0;
        while (true) {
            if (expansions >= budget) return false;
            const current_index = self.popNext() orelse {
                self.state = .ready;
                return true;
            };
            expansions += 1;
            const current_cost = self.costs.items[current_index];
            const current_x: i32 = @intCast(current_index % grid.width);
            const current_y: i32 = @intCast(current_index / grid.width);
            for (neighbor_dirs, 0..) |dir, dir_index| {
                const nx = current_x + dir.x;
                const ny = current_y + dir.y;
                const next_index = grid.indexForCell(.{ .x = nx, .y = ny }) orelse continue;
                if (grid.isBlockedIndex(next_index)) continue;
                // next_index is in-bounds, so nx/ny and current_x/current_y are too;
                // index the orthogonal diagonal cells directly.
                const width_i: i32 = @intCast(grid.width);
                if (dir.diagonal and (grid.blocked.items[@intCast(current_y * width_i + nx)] or grid.blocked.items[@intCast(ny * width_i + current_x)])) {
                    continue;
                }
                const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
                const candidate = current_cost + step_cost;
                const existing = self.cost(next_index);
                if (candidate < existing) {
                    if (existing != unreachable_cost and self.queued_stamp.items[next_index] == self.generation) {
                        self.bucketUnlink(next_index, existing);
                    }
                    self.setCost(next_index, candidate, oppositeDirIndex(dir_index));
                    self.bucketPush(next_index, candidate);
                } else if (candidate == existing) {
                    // Equal-cost tie: a priority-queue Dijkstra pops predecessors in
                    // (cost, index) order and the FIRST to relax a child sets its flow
                    // direction (strict-improvement rejects later equal relaxations). So
                    // the winning predecessor is the one with the smaller (cost, index).
                    // Replicate that here so the field is byte-identical regardless of
                    // the bucket queue's intra-distance pop order: overwrite only when
                    // the existing recorded predecessor has the SAME cost as `current`
                    // but a strictly higher index (a lower-cost predecessor already won
                    // and a higher-cost one cannot have been processed yet).
                    const existing_parent = self.flowParentIndex(grid, next_index);
                    if (self.cost(existing_parent) == current_cost and existing_parent > @as(usize, current_index)) {
                        self.flow_dir.items[next_index] = oppositeDirIndex(dir_index);
                    }
                }
            }
        }
    }

    // Pops the next-lowest-distance queued cell, advancing the monotone distance cursor
    // over empty buckets. Returns null when the queue is empty.
    pub fn popNext(self: *GroupField) ?usize {
        var scanned: u32 = 0;
        while (scanned <= group_field_buckets) : (scanned += 1) {
            const b = self.current_distance % group_field_buckets;
            const head = self.buckets.items[b];
            if (head != no_cell) {
                const next = self.bucket_next.items[head];
                self.buckets.items[b] = next;
                if (next != no_cell) self.bucket_prev.items[next] = no_cell;
                self.queued_stamp.items[head] = 0;
                return head;
            }
            // Empty bucket: advance to the next distance. A full wrap with every bucket
            // empty means the queue is drained.
            self.current_distance += 1;
        }
        return null;
    }

    // The cell index of next_index's recorded flow parent (the cell its flow_dir points
    // to), used only for the equal-cost predecessor tie-break.
    pub fn flowParentIndex(self: *const GroupField, grid: *const NavGrid, next_index: usize) usize {
        const dir = self.flow_dir.items[next_index];
        if (dir == no_flow) return next_index;
        const neighbor = neighbor_dirs[dir];
        const x: i32 = @intCast(next_index % grid.width);
        const y: i32 = @intCast(next_index / grid.width);
        return grid.indexForCell(.{ .x = x + neighbor.x, .y = y + neighbor.y }) orelse next_index;
    }

    // Samples the flow direction at `cell_index`, returning the stepped waypoint.
    pub fn sample(self: *const GroupField, grid: *const NavGrid, cell_index: usize) ?math.Vec2 {
        if (self.state != .ready and self.state != .building) return null;
        if (self.stamps.items[cell_index] != self.generation) return null;
        const dir = self.flow_dir.items[cell_index];
        if (dir == no_flow) {
            // At the goal cell itself.
            if (cell_index == self.goal_index) return grid.cellCenter(self.goal_index);
            return null;
        }
        const neighbor = neighbor_dirs[dir];
        const cx: i32 = @intCast(cell_index % grid.width);
        const cy: i32 = @intCast(cell_index / grid.width);
        const next = GridCell{ .x = cx + neighbor.x, .y = cy + neighbor.y };
        const next_index = grid.indexForCell(next) orelse return grid.cellCenter(cell_index);
        return grid.cellCenter(next_index);
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const OpenNode = types.OpenNode;
const popHeap = types.popHeap;
const siftUp = types.siftUp;
const default_cell_size = types.default_cell_size;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;

// Reference reverse-Dijkstra integration field over a NavGrid using a binary heap with
// the same octile step costs, strict-improvement relaxation, and (cost, index) tie
// order as a priority-queue Dijkstra. The production GroupField's Dial's bucket queue
// must reproduce this field byte-for-byte (costs AND flow directions).
fn referenceFlowField(allocator: std.mem.Allocator, grid: *const NavGrid, goal_index: usize, out_cost: []u32, out_dir: []u8) !void {
    @memset(out_cost, unreachable_cost);
    @memset(out_dir, GroupField.no_flow);
    var heap = std.ArrayList(OpenNode).empty;
    defer heap.deinit(allocator);
    out_cost[goal_index] = 0;
    try heap.append(allocator, .{ .index = goal_index, .f = 0, .h = 0 });
    while (heap.items.len != 0) {
        const current = popHeap(&heap);
        if (out_cost[current.index] != current.f) continue;
        const cx: i32 = @intCast(current.index % grid.width);
        const cy: i32 = @intCast(current.index / grid.width);
        for (neighbor_dirs, 0..) |dir, dir_index| {
            const next_index = grid.indexForCell(.{ .x = cx + dir.x, .y = cy + dir.y }) orelse continue;
            if (grid.isBlockedIndex(next_index)) continue;
            if (dir.diagonal and (grid.isBlockedCell(.{ .x = cx + dir.x, .y = cy }) or grid.isBlockedCell(.{ .x = cx, .y = cy + dir.y }))) continue;
            const candidate = current.f + (if (dir.diagonal) diagonal_cost else cardinal_cost);
            if (candidate >= out_cost[next_index]) continue;
            out_cost[next_index] = candidate;
            out_dir[next_index] = oppositeDirIndex(dir_index);
            try heap.append(allocator, .{ .index = next_index, .f = candidate, .h = 0 });
            siftUp(heap.items, heap.items.len - 1);
        }
    }
}

test "pathfinding group flow field (Dial's) equals a reference heap Dijkstra field" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 20, 20, default_cell_size, default_nav_chunk_tiles, 1);
    // A diagonal-ish obstacle pattern so the field has equal-cost cells reachable from
    // multiple predecessors (the case where pop order could change flow directions).
    const blocked_cells = [_][2]usize{ .{ 5, 3 }, .{ 5, 4 }, .{ 5, 5 }, .{ 6, 5 }, .{ 7, 5 }, .{ 10, 10 }, .{ 11, 10 }, .{ 12, 10 }, .{ 3, 12 }, .{ 4, 12 }, .{ 14, 6 }, .{ 14, 7 } };
    for (blocked_cells) |bc| grid.markBlockedIndex(bc[1] * grid.width + bc[0]);
    grid.buildComponents();

    const cell_count = grid.cellCount();
    const ref_cost = try allocator.alloc(u32, cell_count);
    defer allocator.free(ref_cost);
    const ref_dir = try allocator.alloc(u8, cell_count);
    defer allocator.free(ref_dir);
    const goal_index = 9 * grid.width + 9;
    try referenceFlowField(allocator, &grid, goal_index, ref_cost, ref_dir);

    var field = GroupField{};
    defer field.deinit(allocator);
    try field.reserve(allocator, cell_count);
    try std.testing.expect(field.beginBuild(&grid, emptyKey(1), goal_index, 1));
    // Build in tiny budgeted chunks so the cross-frame resume path is exercised too.
    var guard: usize = 0;
    while (field.state == .building and guard < cell_count + 8) : (guard += 1) {
        _ = field.expand(&grid, 7);
    }
    try std.testing.expectEqual(GroupFieldState.ready, field.state);

    // Every cell's integration cost and flow direction matches the reference exactly.
    for (0..cell_count) |i| {
        const dial_cost = field.cost(i);
        try std.testing.expectEqual(ref_cost[i], dial_cost);
        if (ref_cost[i] != unreachable_cost) {
            try std.testing.expectEqual(ref_dir[i], field.flow_dir.items[i]);
        }
    }
}
