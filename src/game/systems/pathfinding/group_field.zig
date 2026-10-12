// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Demand-driven reverse-Dijkstra shared-goal flow field built with Dial's
//! monotone bucket queue, lazily built and budgeted across frames. Agents sample
//! the per-cell flow direction toward a shared declared goal.

const std = @import("std");
const math = @import("../../../core/math.zig");
const NavGrid = @import("nav_grid.zig").NavGrid;
const allowed_moves = @import("nav_grid.zig").allowed_moves;
const testBit = @import("nav_grid.zig").testBit;
const setBit = @import("nav_grid.zig").setBit;
const clearBit = @import("nav_grid.zig").clearBit;
const world_terrain = @import("../../world_terrain.zig");
const ChunkBits = world_terrain.ChunkBits;
const max_chunk_cells = world_terrain.max_chunk_cells;
const types = @import("types.zig");
const diagonal_cost = types.diagonal_cost;
const cardinal_cost = types.cardinal_cost;
const unreachable_cost = types.unreachable_cost;
const no_slot = types.no_slot;
const max_stamp_generation = types.max_stamp_generation;
const neighbor_dirs = types.neighbor_dirs;
const oppositeDirIndex = types.oppositeDirIndex;
const fibonacciSlot = types.fibonacciSlot;
const hashTableSlots = types.hashTableSlots;
const hashTableShift = types.hashTableShift;
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

/// Exclusive upper bound on a field's cell cap: a field holds at most one block per
/// covered cell, and a bucket link packs `block << 8 | local` into a u32 below `no_slot`.
pub const group_field_cell_limit: usize = 1 << 24;

comptime {
    // A slot id's low byte is the chunk-local cell.
    std.debug.assert(max_chunk_cells == 256);
}

/// The costed cells of one nav chunk for the current build: which cells are costed and
/// queued, their integration cost to the goal, flow direction (index into
/// `neighbor_dirs`, or `GroupField.no_flow`), and intrusive bucket links (slot ids).
/// Cell data is valid only where `costed` is set.
pub const FieldBlock = struct {
    chunk: u32,
    origin_x: u32,
    origin_y: u32,
    costed: ChunkBits,
    queued: ChunkBits,
    cost: [max_chunk_cells]u32,
    flow: [max_chunk_cells]u8,
    next: [max_chunk_cells]u32,
    prev: [max_chunk_cells]u32,
};

/// Bytes one pooled `FieldBlock` holds across its columns.
pub const field_block_bytes: usize = blk: {
    var bytes: usize = 0;
    for (@typeInfo(FieldBlock).@"struct".field_types) |T| bytes += @sizeOf(T);
    break :blk bytes;
};

/// One chunk directory row: the chunk's block this build when `stamp` is the field's
/// generation (stamp 0 is untouched).
pub const DirEntry = extern struct {
    chunk: u32,
    stamp: u32,
    block: u32,

    comptime {
        std.debug.assert(@sizeOf(DirEntry) == 12);
    }
};

/// One costed field cell as `GroupField.lookup` reads it.
pub const FieldCell = struct {
    cost: u32,
    flow_dir: u8,
};

/// What ended one `GroupField.expand` call.
pub const Progress = enum {
    /// The call's budget ran out with cells still queued.
    budget_spent,
    /// The field finished: the queue drained or the cell cap stopped the flood.
    ready,
    /// The block pool cannot hold the next pop's new chunks; nothing was popped. The
    /// owner grows the pool (`growForStall`) and expands again with the rest of the budget.
    stalled,
};

// The block pool's column views, refreshed whenever the pool grows.
const Columns = struct {
    chunk: []u32 = &.{},
    origin_x: []u32 = &.{},
    origin_y: []u32 = &.{},
    costed: []ChunkBits = &.{},
    queued: []ChunkBits = &.{},
    cost: [][max_chunk_cells]u32 = &.{},
    flow: [][max_chunk_cells]u8 = &.{},
    next: [][max_chunk_cells]u32 = &.{},
    prev: [][max_chunk_cells]u32 = &.{},
};

// A directory probe: the chunk's row this build, or the free row it would claim.
const DirProbe = struct {
    row: usize,
    found: bool,
};

inline fn slotId(block: u32, local: u32) u32 {
    return block << 8 | local;
}

// Most chunks one pop can newly claim: its 3x3 window crosses at most two chunks per
// axis when the chunk edge is at least 2, so at most three besides its own.
fn perPopBlocks(grid: *const NavGrid) u32 {
    return if (grid.geometry.chunk_tiles >= 2) 3 else 8;
}

// Most blocks a build toward `max_cells` cells on `grid` can claim: one per pushed cell
// and one per level chunk.
fn blockBound(grid: *const NavGrid, max_cells: usize) u32 {
    return @intCast(@min(@max(@as(usize, 1), max_cells), grid.dir.items.len));
}

/// Blocks a field's first build reserves: room for the goal, one step's budget of cells
/// in dense chunks, and a pop's new chunks; later builds reuse the high-water pool.
pub fn initialPoolBlocks(grid: *const NavGrid, max_cells: usize, build_budget: usize) usize {
    const chunk_cells: usize = @as(usize, grid.geometry.chunk_tiles) * grid.geometry.chunk_tiles;
    const dense = 4 + (@min(max_cells, build_budget) + chunk_cells - 1) / chunk_cells;
    return @max(1 + perPopBlocks(grid), dense);
}

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
    // Set by an expand that stopped for pool room; cleared by the next expand.
    stalled: bool = false,
    // Distinct cells ever pushed (given a cost) during the CURRENT build, persisting
    // across multiple budgeted expand() calls; reset in beginBuild. Bounds the flood
    // to max_cells regardless of world size — see max_cells' doc comment.
    pushed_count: usize = 0,
    // Fixed per-build cap on total distinct cells the flood may cover, set once in
    // beginBuild from the caller's config. Without this, the flood covers the WHOLE
    // reachable component from the goal — for an open world that is the whole grid, so
    // build cost (and therefore group_service_ns) would scale with world size; the cap
    // keeps it a fixed per-query budget, like max_abstract_nodes.
    // A cell past the cap is simply never reached this build: sample() returns null
    // for it, which the caller already treats as "field does not cover this cell" and
    // falls through to an individual solve — never a false unavailable, just a
    // bounded-radius shared-goal hint instead of a whole-map one.
    max_cells: usize = 1,
    // Blocks claimed this build (a bump pointer into the pool), and the most this build
    // can claim: min(max_cells, level chunks).
    used_blocks: u32 = 0,
    block_bound: u32 = 0,
    /// Expansions the owner still grants this step; `expand` consumes it.
    step_budget_left: usize = 0,
    // Dial's bucket queue: per-bucket head slot ids; the blocks' `next`/`prev` links let
    // a decrease-key unlink in O(1). A cell is in at most one bucket; `queued` marks it.
    buckets: [group_field_buckets]u32 = @splat(no_slot),
    // One block per chunk the build covers, from a pool kept at its high-water size
    // across builds and grown only on the owner's thread. Empty until the first build.
    blocks: std.MultiArrayList(FieldBlock) = .{},
    columns: Columns = .{},
    // Chunk id -> block, open-addressed at load <= 1/2 of the pool size; rows of other
    // generations are free.
    directory: []DirEntry = &.{},
    dir_shift: u6 = 0,

    pub const no_flow: u8 = 0xff;

    pub fn deinit(self: *GroupField, allocator: std.mem.Allocator) void {
        allocator.free(self.directory);
        self.blocks.deinit(allocator);
        self.* = undefined;
    }

    /// Bytes the pool and directory hold (allocated capacity).
    pub fn residentBytes(self: *const GroupField) usize {
        return self.blocks.capacity * field_block_bytes + self.directory.len * @sizeOf(DirEntry);
    }

    /// An over-estimate of `residentBytes` for a field capped at `max_cells` cells on a level
    /// of `level_chunks` chunks: the pool never grows past what a build can claim, and its
    /// directory is sized to the pool. A directory too wide to build saturates.
    pub fn storageBytesBound(max_cells: usize, level_chunks: usize) usize {
        const blocks = @min(@max(1, max_cells), level_chunks);
        const rows = hashTableSlots(blocks) catch return std.math.maxInt(usize);
        return blocks *| field_block_bytes +| rows *| @sizeOf(DirEntry);
    }

    /// Grows the pool to at least `min_blocks` blocks (at least doubling, never past what
    /// a build toward `max_cells` on `grid` can claim). Allocation-free when the pool
    /// already holds them. Failure-atomic: the directory and pool are allocated before
    /// anything changes, so an out-of-memory leaves the field as it was.
    pub fn reservePool(self: *GroupField, allocator: std.mem.Allocator, grid: *const NavGrid, max_cells: usize, min_blocks: usize) !void {
        const bound = blockBound(grid, max_cells);
        const wanted = @min(min_blocks, bound);
        if (self.blocks.len >= wanted) return;
        const target = @min(@as(usize, bound), @max(wanted, self.blocks.len * 2));
        const rows = try hashTableSlots(target);
        const directory = try allocator.alloc(DirEntry, rows);
        errdefer allocator.free(directory);
        // Only the claimed blocks move; the rest of the pool holds nothing live.
        const pool_len = self.blocks.len;
        self.blocks.len = self.used_blocks;
        errdefer self.blocks.len = pool_len;
        try self.blocks.setCapacity(allocator, target);
        // Nothing below fails.
        self.blocks.len = target;
        allocator.free(self.directory);
        self.directory = directory;
        self.dir_shift = hashTableShift(rows);
        @memset(std.mem.sliceAsBytes(self.directory), 0);
        self.refreshColumns();
        for (0..self.used_blocks) |block| {
            const chunk = self.columns.chunk[block];
            const probe = self.findChunk(chunk);
            std.debug.assert(!probe.found);
            self.directory[probe.row] = .{ .chunk = chunk, .stamp = self.generation, .block = @intCast(block) };
        }
    }

    /// Grows the pool by what a stalled build needs for its next pop.
    pub fn growForStall(self: *GroupField, allocator: std.mem.Allocator, grid: *const NavGrid) !void {
        std.debug.assert(self.stalled);
        try self.reservePool(allocator, grid, self.max_cells, self.used_blocks + self.blocksNeeded(grid));
    }

    // New blocks the next pop may claim.
    fn blocksNeeded(self: *const GroupField, grid: *const NavGrid) u32 {
        const cells_left = self.max_cells - self.pushed_count;
        return @intCast(@min(@as(usize, perPopBlocks(grid)), @min(cells_left, self.block_bound - self.used_blocks)));
    }

    fn refreshColumns(self: *GroupField) void {
        const slice = self.blocks.slice();
        self.columns = .{
            .chunk = slice.items(.chunk),
            .origin_x = slice.items(.origin_x),
            .origin_y = slice.items(.origin_y),
            .costed = slice.items(.costed),
            .queued = slice.items(.queued),
            .cost = slice.items(.cost),
            .flow = slice.items(.flow),
            .next = slice.items(.next),
            .prev = slice.items(.prev),
        };
    }

    // The directory row of `chunk` this build, or the free row it would claim. The
    // directory is at load <= 1/2, so every chain ends.
    fn findChunk(self: *const GroupField, chunk: u32) DirProbe {
        const directory = self.directory;
        const row_mask = directory.len - 1;
        var row = fibonacciSlot(chunk, self.dir_shift);
        while (true) : (row = (row + 1) & row_mask) {
            const entry = &directory[row];
            if (entry.stamp != self.generation) return .{ .row = row, .found = false };
            if (entry.chunk == chunk) return .{ .row = row, .found = true };
        }
    }

    /// The cost and flow direction of `cell_index` costed by the current build, or null.
    /// Read-only: safe on workers while no stage writes the field.
    pub fn lookup(self: *const GroupField, grid: *const NavGrid, cell_index: usize) ?FieldCell {
        if (self.directory.len == 0) return null;
        const y = cell_index / grid.geometry.width;
        const x = cell_index - y * grid.geometry.width;
        const probe = self.findChunk(grid.geometry.chunkOf(x, y));
        if (!probe.found) return null;
        const block = self.directory[probe.row].block;
        const local = grid.geometry.localOf(x, y);
        if (!testBit(&self.columns.costed[block], local)) return null;
        return .{ .cost = self.columns.cost[block][local], .flow_dir = self.columns.flow[block][local] };
    }

    /// Whether the current build costed a cell of `chunk` set in `cells` (chunk-local
    /// bits); false for an empty field. One directory probe; read-only, so safe on workers
    /// while no stage writes the field.
    pub fn costedNear(self: *const GroupField, chunk: u32, cells: *const ChunkBits) bool {
        if (self.state == .empty or self.directory.len == 0) return false;
        const probe = self.findChunk(chunk);
        if (!probe.found) return false;
        const costed = &self.columns.costed[self.directory[probe.row].block];
        for (costed, cells) |costed_word, cell_word| {
            if (costed_word & cell_word != 0) return true;
        }
        return false;
    }

    fn nextGeneration(self: *GroupField) void {
        if (self.generation == max_stamp_generation) {
            @memset(std.mem.sliceAsBytes(self.directory), 0);
            self.generation = 1;
        } else {
            self.generation += 1;
        }
    }

    /// Begins a build toward `goal_index` covering at most `max_cells` cells (at least the
    /// goal). Returns false, leaving the field empty, when the goal is blocked or the pool
    /// was never reserved (`reservePool`). O(1).
    pub fn beginBuild(self: *GroupField, grid: *const NavGrid, key: PathQueryKey, goal_index: usize, step: u32, max_cells: usize) bool {
        std.debug.assert(max_cells < group_field_cell_limit);
        self.key = key;
        self.goal_index = goal_index;
        self.last_build_step = step;
        self.pushed_count = 0;
        self.stalled = false;
        if (self.blocks.len == 0) {
            self.state = .empty;
            return false;
        }
        self.nextGeneration();
        self.used_blocks = 0;
        self.buckets = @splat(no_slot);
        self.current_distance = 0;
        // At least 1 so the goal cell itself always gets pushed below; a caller passing
        // 0 would otherwise silently produce a field that never covers even its own goal.
        self.max_cells = @max(@as(usize, 1), max_cells);
        self.block_bound = blockBound(grid, self.max_cells);
        if (grid.isBlockedIndex(goal_index)) {
            self.state = .empty;
            return false;
        }
        const y = goal_index / grid.geometry.width;
        const x = goal_index - y * grid.geometry.width;
        const chunk = grid.geometry.chunkOf(x, y);
        const probe = self.findChunk(chunk);
        self.claimBlock(grid, probe.row, chunk, x, y, 0);
        const local = grid.geometry.localOf(x, y);
        setBit(&self.columns.costed[0], local);
        self.columns.cost[0][local] = 0;
        self.columns.flow[0][local] = no_flow;
        bucketPush(self.columns, &self.buckets, slotId(0, local), 0);
        self.used_blocks = 1;
        self.pushed_count = 1;
        self.state = .building;
        return true;
    }

    // Takes pool block `block` for the chunk holding (x, y) and records it at directory
    // row `row`; clears its bitmaps.
    fn claimBlock(self: *GroupField, grid: *const NavGrid, row: usize, chunk: u32, x: usize, y: usize, block: u32) void {
        const mask: usize = grid.geometry.chunk_tiles - 1;
        self.columns.chunk[block] = chunk;
        self.columns.origin_x[block] = @intCast(x & ~mask);
        self.columns.origin_y[block] = @intCast(y & ~mask);
        self.columns.costed[block] = @splat(0);
        self.columns.queued[block] = @splat(0);
        self.directory[row] = .{ .chunk = chunk, .stamp = self.generation, .block = block };
    }

    /// Expands queued cells via Dial's monotone bucket queue until `budget` (decremented
    /// per expansion) runs out, the field finishes, or the pool lacks room for the next
    /// pop's new chunks (`.stalled`, before popping). Never pushes past max_cells distinct
    /// cells for this build, regardless of how much of the grid is still reachable. The
    /// distance cursor advances only forward, so the build resumes correctly across calls.
    /// Writes only this field's header (once) and its own pool and directory.
    pub fn expand(self: *GroupField, grid: *const NavGrid, budget: *usize) Progress {
        std.debug.assert(budget.* != 0); // a zero budget makes no progress and never reaches .ready
        std.debug.assert(self.state == .building);
        // The header state the loop advances lives in locals and is written back once, so
        // workers expanding adjacent fields never write a shared cache line per cell.
        var distance = self.current_distance;
        var pushed = self.pushed_count;
        var used = self.used_blocks;
        var buckets = self.buckets;
        var left = budget.*;
        defer {
            self.current_distance = distance;
            self.pushed_count = pushed;
            self.used_blocks = used;
            self.buckets = buckets;
            budget.* = left;
        }
        self.stalled = false;
        const columns = self.columns;
        const pool_blocks: u32 = @intCast(self.blocks.len);
        const max_cells = self.max_cells;
        const block_bound = self.block_bound;
        const per_pop = perPopBlocks(grid);
        const edge: u32 = grid.geometry.chunk_tiles;
        const mask: u32 = edge - 1;
        const shift = grid.geometry.shift;
        const width = grid.geometry.width;
        var local_steps: [neighbor_dirs.len]u32 = undefined;
        for (neighbor_dirs, &local_steps) |dir, *step| step.* = @bitCast(dir.y * @as(i32, @intCast(edge)) + dir.x);
        while (true) {
            if (left == 0) return .budget_spent;
            const needed: u32 = @intCast(@min(@as(usize, per_pop), @min(max_cells - pushed, block_bound - used)));
            if (pool_blocks - used < needed) {
                self.stalled = true;
                return .stalled;
            }
            const current = popNext(columns, &buckets, &distance) orelse {
                self.state = .ready;
                return .ready;
            };
            left -= 1;
            const block = current >> 8;
            const local = current & 0xff;
            const current_cost = columns.cost[block][local];
            const local_x = local & mask;
            const local_y = local >> shift;
            const x: usize = columns.origin_x[block] + local_x;
            const y: usize = columns.origin_y[block] + local_y;
            const current_chunk = columns.chunk[block];
            // One 3x3 neighborhood read and one table lookup give every allowed move, bounds
            // and the corner rule included.
            const moves = allowed_moves[grid.neighborhood(x, y)];
            // Every neighbour of an interior cell lies in its own block.
            const interior = local_x != 0 and local_y != 0 and local_x != mask and local_y != mask;
            for (neighbor_dirs, 0..) |dir, dir_index| {
                if (moves & (@as(u8, 1) << @intCast(dir_index)) == 0) continue;
                var next_block = block;
                var next_local: u32 = undefined;
                var free_row: ?usize = null;
                var next_chunk: u32 = current_chunk;
                if (interior) {
                    // Wrapping add of the two's-complement block-local step: the neighbour is
                    // inside the block, so the sum is its local index.
                    next_local = local +% local_steps[dir_index];
                } else {
                    // In-grid: the move table admits only in-level neighbours.
                    const next_x: usize = @intCast(@as(i64, @intCast(x)) + dir.x);
                    const next_y: usize = @intCast(@as(i64, @intCast(y)) + dir.y);
                    next_local = grid.geometry.localOf(next_x, next_y);
                    next_chunk = grid.geometry.chunkOf(next_x, next_y);
                    if (next_chunk != current_chunk) {
                        const probe = self.findChunk(next_chunk);
                        if (probe.found) next_block = self.directory[probe.row].block else free_row = probe.row;
                    }
                }
                const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
                const candidate = current_cost + step_cost;
                if (free_row == null and testBit(&columns.costed[next_block], next_local)) {
                    const next_slot = slotId(next_block, next_local);
                    const existing = columns.cost[next_block][next_local];
                    if (candidate < existing) {
                        if (testBit(&columns.queued[next_block], next_local)) bucketUnlink(columns, &buckets, next_slot, existing);
                        columns.cost[next_block][next_local] = candidate;
                        columns.flow[next_block][next_local] = oppositeDirIndex(dir_index);
                        bucketPush(columns, &buckets, next_slot, candidate);
                    } else if (candidate == existing) {
                        // Equal-cost tie: a priority-queue Dijkstra pops predecessors in
                        // (cost, index) order and the FIRST to relax a child sets its flow
                        // direction (strict-improvement rejects later equal relaxations). So
                        // the winning predecessor is the one with the smaller (cost, index).
                        // Replicate that here so the field is identical regardless of the
                        // bucket queue's intra-distance pop order: overwrite only when the
                        // existing recorded predecessor has the SAME cost as `current` but a
                        // strictly higher cell index. A popped predecessor's cost is final,
                        // so the recorded one costs `existing - step(flow)`: it equals
                        // `current_cost` exactly when both steps are diagonal or both
                        // cardinal, with no lookup.
                        const existing_flow = columns.flow[next_block][next_local];
                        if (existing_flow != no_flow and neighbor_dirs[existing_flow].diagonal == dir.diagonal) {
                            const parent = neighbor_dirs[existing_flow];
                            const parent_x: usize = @intCast(@as(i64, @intCast(x)) + dir.x + parent.x);
                            const parent_y: usize = @intCast(@as(i64, @intCast(y)) + dir.y + parent.y);
                            if (parent_y * width + parent_x > y * width + x) {
                                columns.flow[next_block][next_local] = oppositeDirIndex(dir_index);
                            }
                        }
                    }
                    continue;
                }
                // A genuinely NEW cell past the fixed cap is left unreached rather than
                // pushed — bounds total flood extent to max_cells independent of world
                // size. An already-costed cell's cost IMPROVEMENT is never blocked by the
                // cap: it was already counted once and relaxing it again does not grow the
                // flood's footprint.
                if (pushed >= max_cells) continue;
                if (free_row) |row| {
                    // The pre-pop check left room for every chunk this pop claims.
                    std.debug.assert(used < pool_blocks);
                    next_block = used;
                    used += 1;
                    const next_x: usize = @intCast(@as(i64, @intCast(x)) + dir.x);
                    const next_y: usize = @intCast(@as(i64, @intCast(y)) + dir.y);
                    self.claimBlock(grid, row, next_chunk, next_x, next_y, next_block);
                }
                pushed += 1;
                setBit(&columns.costed[next_block], next_local);
                columns.cost[next_block][next_local] = candidate;
                columns.flow[next_block][next_local] = oppositeDirIndex(dir_index);
                bucketPush(columns, &buckets, slotId(next_block, next_local), candidate);
            }
        }
    }

    /// Samples the flow direction at `cell_index`, returning the stepped waypoint. Answers
    /// for a `.building` field too (not just `.ready`): Dial's monotone integration costs
    /// cells in non-decreasing distance order, so an already-costed cell's flow direction
    /// is final the moment it is set, even mid-build — a provisional-but-correct partial
    /// answer, never a stale or cyclic one. Both current production callers happen to gate
    /// on `.ready` first (a conservative choice, not a requirement this function imposes),
    /// so `.building` is reachable only by a future caller choosing to sample early.
    pub fn sample(self: *const GroupField, grid: *const NavGrid, cell_index: usize) ?math.Vec2 {
        if (self.state != .ready and self.state != .building) return null;
        const cell = self.lookup(grid, cell_index) orelse return null;
        const dir = cell.flow_dir;
        if (dir == no_flow) {
            // At the goal cell itself.
            if (cell_index == self.goal_index) return grid.cellCenter(self.goal_index);
            return null;
        }
        const neighbor = neighbor_dirs[dir];
        const cx: i32 = @intCast(cell_index % grid.geometry.width);
        const cy: i32 = @intCast(cell_index / grid.geometry.width);
        const next = GridCell{ .x = cx + neighbor.x, .y = cy + neighbor.y };
        const next_index = grid.indexForCell(next) orelse return grid.cellCenter(cell_index);
        return grid.cellCenter(next_index);
    }
};

// Links `slot` (already costed) into its distance bucket at the head.
fn bucketPush(columns: Columns, buckets: *[group_field_buckets]u32, slot: u32, distance: u32) void {
    const bucket = distance % group_field_buckets;
    const head = buckets[bucket];
    const block = slot >> 8;
    const local = slot & 0xff;
    columns.next[block][local] = head;
    columns.prev[block][local] = no_slot;
    if (head != no_slot) columns.prev[head >> 8][head & 0xff] = slot;
    buckets[bucket] = slot;
    setBit(&columns.queued[block], local);
}

// Unlinks queued `slot` from its distance bucket in O(1).
fn bucketUnlink(columns: Columns, buckets: *[group_field_buckets]u32, slot: u32, distance: u32) void {
    const prev = columns.prev[slot >> 8][slot & 0xff];
    const next = columns.next[slot >> 8][slot & 0xff];
    if (prev != no_slot) {
        columns.next[prev >> 8][prev & 0xff] = next;
    } else {
        buckets[distance % group_field_buckets] = next;
    }
    if (next != no_slot) columns.prev[next >> 8][next & 0xff] = prev;
}

// Pops the slot of the next-lowest-distance queued cell, advancing the monotone distance
// cursor over empty buckets. Returns null when the queue is empty.
fn popNext(columns: Columns, buckets: *[group_field_buckets]u32, distance: *u32) ?u32 {
    var scanned: u32 = 0;
    // The live window spans at most group_field_buckets distinct residues (max octile step =
    // diagonal_cost), so one pass over every bucket either finds work or drains the queue.
    while (scanned < group_field_buckets) : (scanned += 1) {
        const bucket = distance.* % group_field_buckets;
        const head = buckets[bucket];
        if (head != no_slot) {
            const next = columns.next[head >> 8][head & 0xff];
            buckets[bucket] = next;
            if (next != no_slot) columns.prev[next >> 8][next & 0xff] = no_slot;
            clearBit(&columns.queued[head >> 8], head & 0xff);
            return head;
        }
        // Empty bucket: advance to the next distance. A full wrap with every bucket
        // empty means the queue is drained.
        distance.* += 1;
    }
    return null;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const OpenNode = types.OpenNode;
const popHeap = types.popHeap;
const siftUp = types.siftUp;
const default_cell_size = types.default_cell_size;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;
const setBlockedCells = @import("test_support.zig").setBlockedCells;

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
        const cx: i32 = @intCast(current.index % grid.geometry.width);
        const cy: i32 = @intCast(current.index / grid.geometry.width);
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

// The flat per-cell-array Dial field the block pool replaced, kept as the reference: the
// same pushes, pop order, cap, and tie-break over level-sized arrays.
const FlatField = struct {
    cost: []u32,
    flow: []u8,
    next: []u32,
    prev: []u32,
    queued: []bool,
    buckets: [group_field_buckets]u32 = @splat(no_slot),
    distance: u32 = 0,
    pushed: usize = 0,
    max_cells: usize,
    ready: bool = false,

    fn init(allocator: std.mem.Allocator, grid: *const NavGrid, goal_index: usize, max_cells: usize) !FlatField {
        const cells = grid.cellCount();
        var field = FlatField{
            .cost = try allocator.alloc(u32, cells),
            .flow = try allocator.alloc(u8, cells),
            .next = try allocator.alloc(u32, cells),
            .prev = try allocator.alloc(u32, cells),
            .queued = try allocator.alloc(bool, cells),
            .max_cells = @max(@as(usize, 1), max_cells),
        };
        @memset(field.cost, unreachable_cost);
        @memset(field.flow, GroupField.no_flow);
        @memset(field.queued, false);
        field.cost[goal_index] = 0;
        field.push(@intCast(goal_index), 0);
        field.pushed = 1;
        return field;
    }

    fn deinit(self: *FlatField, allocator: std.mem.Allocator) void {
        allocator.free(self.queued);
        allocator.free(self.prev);
        allocator.free(self.next);
        allocator.free(self.flow);
        allocator.free(self.cost);
    }

    fn push(self: *FlatField, cell: u32, distance: u32) void {
        const bucket = distance % group_field_buckets;
        const head = self.buckets[bucket];
        self.next[cell] = head;
        self.prev[cell] = no_slot;
        if (head != no_slot) self.prev[head] = cell;
        self.buckets[bucket] = cell;
        self.queued[cell] = true;
    }

    fn unlink(self: *FlatField, cell: u32, distance: u32) void {
        const prev = self.prev[cell];
        const next = self.next[cell];
        if (prev != no_slot) self.next[prev] = next else self.buckets[distance % group_field_buckets] = next;
        if (next != no_slot) self.prev[next] = prev;
    }

    fn pop(self: *FlatField) ?u32 {
        var scanned: u32 = 0;
        while (scanned < group_field_buckets) : (scanned += 1) {
            const bucket = self.distance % group_field_buckets;
            const head = self.buckets[bucket];
            if (head != no_slot) {
                const next = self.next[head];
                self.buckets[bucket] = next;
                if (next != no_slot) self.prev[next] = no_slot;
                self.queued[head] = false;
                return head;
            }
            self.distance += 1;
        }
        return null;
    }

    fn parentIndex(self: *const FlatField, grid: *const NavGrid, cell: usize) usize {
        const dir = self.flow[cell];
        if (dir == GroupField.no_flow) return cell;
        const x: i32 = @intCast(cell % grid.geometry.width);
        const y: i32 = @intCast(cell / grid.geometry.width);
        return grid.indexForCell(.{ .x = x + neighbor_dirs[dir].x, .y = y + neighbor_dirs[dir].y }) orelse cell;
    }

    fn expand(self: *FlatField, grid: *const NavGrid, budget: usize) void {
        var expansions: usize = 0;
        while (expansions < budget) {
            const current = self.pop() orelse {
                self.ready = true;
                return;
            };
            expansions += 1;
            const current_cost = self.cost[current];
            const y = current / grid.geometry.width;
            const x = current - y * grid.geometry.width;
            const moves = allowed_moves[grid.neighborhood(x, y)];
            for (neighbor_dirs, 0..) |dir, dir_index| {
                if (moves & (@as(u8, 1) << @intCast(dir_index)) == 0) continue;
                const next: u32 = @intCast((@as(i64, @intCast(y)) + dir.y) * @as(i64, @intCast(grid.geometry.width)) + @as(i64, @intCast(x)) + dir.x);
                const candidate = current_cost + (if (dir.diagonal) diagonal_cost else cardinal_cost);
                const existing = self.cost[next];
                if (existing == unreachable_cost and self.pushed >= self.max_cells) continue;
                if (candidate < existing) {
                    if (self.queued[next]) self.unlink(next, existing);
                    if (existing == unreachable_cost) self.pushed += 1;
                    self.cost[next] = candidate;
                    self.flow[next] = oppositeDirIndex(dir_index);
                    self.push(next, candidate);
                } else if (candidate == existing) {
                    const parent = self.parentIndex(grid, next);
                    if (self.cost[parent] == current_cost and parent > current) self.flow[next] = oppositeDirIndex(dir_index);
                }
            }
        }
    }
};

// One budgeted step of `field`, growing the pool on every stall like the owner does.
// Returns the expansions spent.
fn stepGrowing(allocator: std.mem.Allocator, field: *GroupField, grid: *const NavGrid, budget: usize) !usize {
    var left = budget;
    while (left != 0 and field.state == .building) {
        if (field.expand(grid, &left) != .stalled) break;
        try field.growForStall(allocator, grid);
    }
    return budget - left;
}

// Reserves the first-build pool and begins a build.
fn beginTestBuild(allocator: std.mem.Allocator, field: *GroupField, grid: *const NavGrid, goal_index: usize, max_cells: usize, budget: usize) !bool {
    try field.reservePool(allocator, grid, max_cells, initialPoolBlocks(grid, max_cells, budget));
    return field.beginBuild(grid, emptyKey(1), goal_index, 1, max_cells);
}

fn buildToReady(allocator: std.mem.Allocator, field: *GroupField, grid: *const NavGrid, budget: usize) !void {
    var guard: usize = 0;
    while (field.state == .building and guard < grid.cellCount() + 8) : (guard += 1) {
        _ = try stepGrowing(allocator, field, grid, budget);
    }
    try std.testing.expectEqual(GroupFieldState.ready, field.state);
}

fn expectFieldEqualsFlat(field: *const GroupField, flat: *const FlatField, grid: *const NavGrid) !void {
    try std.testing.expectEqual(flat.pushed, field.pushed_count);
    try std.testing.expectEqual(flat.distance, field.current_distance);
    try std.testing.expectEqual(flat.ready, field.state == .ready);
    for (0..grid.cellCount()) |cell| {
        const found = field.lookup(grid, cell);
        if (flat.cost[cell] == unreachable_cost) {
            try std.testing.expect(found == null);
        } else {
            try std.testing.expectEqual(flat.cost[cell], found.?.cost);
            try std.testing.expectEqual(flat.flow[cell], found.?.flow_dir);
        }
    }
}

// A width x height grid at chunk edge `edge` with about a quarter of its cells blocked.
fn randomObstacleGrid(allocator: std.mem.Allocator, grid: *NavGrid, width: usize, height: usize, edge: u16, seed: u64) !void {
    try grid.prepare(allocator, 0, width, height, default_cell_size, edge);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var blocked = std.ArrayList([2]usize).empty;
    defer blocked.deinit(allocator);
    for (0..height) |y| {
        for (0..width) |x| {
            if (random.uintLessThan(u8, 4) == 0) try blocked.append(allocator, .{ x, y });
        }
    }
    try setBlockedCells(allocator, grid, blocked.items);
}

fn firstOpenCell(grid: *const NavGrid, from: usize) usize {
    var cell = from;
    while (grid.isBlockedIndex(cell)) cell = (cell + 1) % grid.cellCount();
    return cell;
}

test "a group field equals the flat-array field after every budgeted expand" {
    const allocator = std.testing.allocator;
    for ([_]u16{ 1, 2, 4, 8, 16 }, 0..) |edge, edge_index| {
        var grid = NavGrid{};
        defer grid.deinit(allocator);
        try randomObstacleGrid(allocator, &grid, 40, 40, edge, 0x9e37 + edge_index);
        const goal_index = firstOpenCell(&grid, 20 * 40 + 21);
        for ([_]usize{ 1, 37, 300, grid.cellCount() }) |max_cells| {
            for ([_]usize{ 1, 7, 64 }) |budget| {
                var field = GroupField{};
                defer field.deinit(allocator);
                try std.testing.expect(try beginTestBuild(allocator, &field, &grid, goal_index, max_cells, budget));
                var flat = try FlatField.init(allocator, &grid, goal_index, max_cells);
                defer flat.deinit(allocator);
                try expectFieldEqualsFlat(&field, &flat, &grid);
                var calls: usize = 0;
                while (field.state == .building) : (calls += 1) {
                    _ = try stepGrowing(allocator, &field, &grid, budget);
                    flat.expand(&grid, budget);
                    // Every call is compared except the per-cell sweep at budget 1, which
                    // runs every eighth call and at the end.
                    if (budget != 1 or calls % 8 == 0 or field.state == .ready) {
                        try expectFieldEqualsFlat(&field, &flat, &grid);
                    } else {
                        try std.testing.expectEqual(flat.pushed, field.pushed_count);
                        try std.testing.expectEqual(flat.distance, field.current_distance);
                    }
                }
                try std.testing.expect(flat.ready);
            }
        }
    }
}

test "costedNear is exact against the current build's costed cells, mid-build and ready" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try randomObstacleGrid(allocator, &grid, 24, 24, 4, 0xc057);
    var field = GroupField{};
    defer field.deinit(allocator);
    var single: ChunkBits = @splat(0);
    // An unbuilt field costs nothing.
    single[0] = 1;
    try std.testing.expect(!field.costedNear(0, &single));
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, firstOpenCell(&grid, 12 * 24 + 12), 200, 9));
    for (0..3) |round| {
        if (round != 0) _ = try stepGrowing(allocator, &field, &grid, 9);
        // Each cell alone: set exactly when the build costed it.
        for (0..grid.cellCount()) |cell| {
            const x = cell % grid.geometry.width;
            const y = cell / grid.geometry.width;
            const local = grid.geometry.localOf(x, y);
            single = @splat(0);
            setBit(&single, local);
            try std.testing.expectEqual(field.lookup(&grid, cell) != null, field.costedNear(grid.geometry.chunkOf(x, y), &single));
        }
    }
    try buildToReady(allocator, &field, &grid, 64);
    // A whole chunk's bits answer whether any of its cells is costed.
    var all: ChunkBits = @splat(std.math.maxInt(u64));
    for (0..grid.dir.items.len) |chunk| {
        var any = false;
        for (0..grid.cellCount()) |cell| {
            if (grid.geometry.chunkOf(cell % grid.geometry.width, cell / grid.geometry.width) == chunk and field.lookup(&grid, cell) != null) any = true;
        }
        try std.testing.expectEqual(any, field.costedNear(@intCast(chunk), &all));
    }
    all = @splat(0);
    try std.testing.expect(!field.costedNear(0, &all));
    field.state = .empty;
    single[0] = std.math.maxInt(u64);
    try std.testing.expect(!field.costedNear(grid.geometry.chunkOf(field.goal_index % grid.geometry.width, field.goal_index / grid.geometry.width), &single));
}

test "pathfinding group flow field (Dial's) equals a reference heap Dijkstra field" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 20, 20, default_cell_size, 4);
    // A diagonal-ish obstacle pattern so the field has equal-cost cells reachable from
    // multiple predecessors (the case where pop order could change flow directions).
    const blocked_cells = [_][2]usize{ .{ 5, 3 }, .{ 5, 4 }, .{ 5, 5 }, .{ 6, 5 }, .{ 7, 5 }, .{ 10, 10 }, .{ 11, 10 }, .{ 12, 10 }, .{ 3, 12 }, .{ 4, 12 }, .{ 14, 6 }, .{ 14, 7 } };
    try setBlockedCells(allocator, &grid, &blocked_cells);

    const cell_count = grid.cellCount();
    const ref_cost = try allocator.alloc(u32, cell_count);
    defer allocator.free(ref_cost);
    const ref_dir = try allocator.alloc(u8, cell_count);
    defer allocator.free(ref_dir);
    const goal_index = 9 * grid.geometry.width + 9;
    try referenceFlowField(allocator, &grid, goal_index, ref_cost, ref_dir);

    var field = GroupField{};
    defer field.deinit(allocator);
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, goal_index, cell_count, 7));
    // Build in tiny budgeted chunks so the cross-frame resume path is exercised too.
    try buildToReady(allocator, &field, &grid, 7);

    // Every cell's integration cost and flow direction matches the reference exactly.
    for (0..cell_count) |i| {
        const found = field.lookup(&grid, i);
        if (ref_cost[i] == unreachable_cost) {
            try std.testing.expect(found == null);
        } else {
            try std.testing.expectEqual(ref_cost[i], found.?.cost);
            try std.testing.expectEqual(ref_dir[i], found.?.flow_dir);
        }
    }
}

test "a stalled expand resumes to the same field as an unstalled one" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try randomObstacleGrid(allocator, &grid, 48, 48, 4, 0x51a1);
    const goal_index = firstOpenCell(&grid, 24 * 48 + 24);
    const budget: usize = 40;

    // Cold: the first-build pool, grown at each stall. Warm: pre-grown to the bound.
    var cold = GroupField{};
    defer cold.deinit(allocator);
    try std.testing.expect(try beginTestBuild(allocator, &cold, &grid, goal_index, grid.cellCount(), budget));
    var warm = GroupField{};
    defer warm.deinit(allocator);
    try warm.reservePool(allocator, &grid, grid.cellCount(), grid.dir.items.len);
    try std.testing.expect(warm.beginBuild(&grid, emptyKey(1), goal_index, 1, grid.cellCount()));

    var stalls: usize = 0;
    while (warm.state == .building) {
        var left = budget;
        while (left != 0 and cold.state == .building) {
            if (cold.expand(&grid, &left) != .stalled) break;
            stalls += 1;
            try cold.growForStall(allocator, &grid);
        }
        const cold_spent = budget - left;
        var warm_left = budget;
        try std.testing.expect(warm.expand(&grid, &warm_left) != .stalled);
        try std.testing.expectEqual(budget - warm_left, cold_spent);
        try std.testing.expectEqual(warm.state, cold.state);
        try std.testing.expectEqual(warm.pushed_count, cold.pushed_count);
        try std.testing.expectEqual(warm.current_distance, cold.current_distance);
    }
    try std.testing.expect(stalls > 0);
    for (0..grid.cellCount()) |cell| try std.testing.expectEqualDeep(warm.lookup(&grid, cell), cold.lookup(&grid, cell));
}

test "a tunnel field claims one block per chunk it crosses" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    // A 1-wide corridor along row 1 of a 32x8 grid at chunk edge 4: 8 chunks along it and
    // 8 more below that it never enters.
    try grid.prepare(allocator, 0, 32, 8, default_cell_size, 4);
    var blocked = std.ArrayList([2]usize).empty;
    defer blocked.deinit(allocator);
    for (0..8) |y| {
        for (0..32) |x| {
            if (y != 1) try blocked.append(allocator, .{ x, y });
        }
    }
    try setBlockedCells(allocator, &grid, blocked.items);

    var field = GroupField{};
    defer field.deinit(allocator);
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, 1 * 32 + 0, grid.cellCount(), 3));
    try buildToReady(allocator, &field, &grid, 3);
    try std.testing.expectEqual(@as(usize, 32), field.pushed_count);
    try std.testing.expectEqual(@as(u32, 8), field.used_blocks);
}

test "pool capacity never exceeds min(max_cells, level chunks)" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    // 3 x 4 chunks at edge 16. Budget 1 starts a five-block pool that doubles past 12.
    try grid.prepare(allocator, 0, 48, 64, default_cell_size, 16);
    var field = GroupField{};
    defer field.deinit(allocator);
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, 0, grid.cellCount(), 1));
    try std.testing.expectEqual(@as(usize, 5), field.blocks.len);
    try buildToReady(allocator, &field, &grid, 64);
    try std.testing.expectEqual(@as(u32, 12), field.used_blocks);
    try std.testing.expectEqual(@as(usize, 12), field.blocks.len);
    try std.testing.expectEqual(@as(usize, 12), field.blocks.capacity);

    // A five-cell cap claims at most five blocks whatever the level.
    var capped = GroupField{};
    defer capped.deinit(allocator);
    var wide = NavGrid{};
    defer wide.deinit(allocator);
    try wide.prepare(allocator, 0, 64, 64, default_cell_size, 1);
    try std.testing.expect(try beginTestBuild(allocator, &capped, &wide, 32 * 64 + 32, 5, 64));
    try buildToReady(allocator, &capped, &wide, 64);
    try std.testing.expect(capped.blocks.capacity <= 5);
    try std.testing.expectEqual(@as(usize, 5), capped.pushed_count);
}

test "GroupField generation wraparound clears the directory and a rebuild reads the previous build as uncovered" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 16, 16, default_cell_size, 4);

    var field = GroupField{};
    defer field.deinit(allocator);
    const goal_index = 3 * grid.geometry.width + 3;
    // The last generation: this build stamps its directory rows with it.
    field.generation = max_stamp_generation - 1;
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, goal_index, grid.cellCount(), 2));
    try std.testing.expectEqual(max_stamp_generation, field.generation);
    _ = try stepGrowing(allocator, &field, &grid, 2);
    const some_cell = goal_index + 1;
    try std.testing.expect(field.lookup(&grid, some_cell) != null);
    const far_cell = 14 * grid.geometry.width + 14;

    // Rebuilding wraps the generation to 1 and clears every directory row first.
    const other_goal = 12 * grid.geometry.width + 12;
    try std.testing.expect(field.beginBuild(&grid, emptyKey(1), other_goal, 2, grid.cellCount()));
    try std.testing.expectEqual(@as(u32, 1), field.generation);
    var live_rows: usize = 0;
    for (field.directory) |entry| live_rows += @intFromBool(entry.stamp != 0);
    try std.testing.expectEqual(@as(usize, 1), live_rows);
    try std.testing.expect(field.lookup(&grid, some_cell) == null);
    try std.testing.expect(field.lookup(&grid, far_cell) == null);
    try buildToReady(allocator, &field, &grid, 8);
    try std.testing.expectEqual(@as(u32, 0), field.lookup(&grid, other_goal).?.cost);
    try std.testing.expectEqual(grid.cellCount(), field.pushed_count);

    // A plain rebuild (no wrap) reads the previous build as uncovered too.
    try std.testing.expect(field.beginBuild(&grid, emptyKey(1), goal_index, 3, 1));
    try buildToReady(allocator, &field, &grid, 8);
    try std.testing.expect(field.lookup(&grid, other_goal) == null);
    try std.testing.expectEqual(@as(u32, 0), field.lookup(&grid, goal_index).?.cost);
}

test "GroupField build cost is bounded by max_cells independent of world size" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 64, 64, default_cell_size, default_nav_chunk_tiles);

    var field = GroupField{};
    defer field.deinit(allocator);
    const max_cells: usize = 10;
    // Corner goal: every neighbour is a new, reachable cell. A budget far above the cap
    // proves the CAP (not the per-step budget) stops the flood.
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, 0, max_cells, 1000));
    try buildToReady(allocator, &field, &grid, 1000);
    try std.testing.expectEqual(max_cells, field.pushed_count);
    var covered: usize = 0;
    for (0..grid.cellCount()) |cell| covered += @intFromBool(field.lookup(&grid, cell) != null);
    try std.testing.expectEqual(max_cells, covered);
    // A cell far outside the capped radius reads as uncovered, not a default direction.
    try std.testing.expect(field.sample(&grid, grid.cellCount() - 1) == null);
}

test "a field built to its cap, then past it with a wider cap, stays within its storage bound" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 64, 64, default_cell_size, default_nav_chunk_tiles);
    const chunks = grid.dir.items.len;
    var field = GroupField{};
    defer field.deinit(allocator);
    for ([_]usize{ 40, grid.cellCount() }) |max_cells| {
        try std.testing.expect(try beginTestBuild(allocator, &field, &grid, 0, max_cells, 1000));
        try buildToReady(allocator, &field, &grid, 1000);
        try std.testing.expect(field.residentBytes() <= GroupField.storageBytesBound(max_cells, chunks));
    }
    // A cap past the level's cells claims every chunk: the bound is the whole level's.
    try std.testing.expectEqual(GroupField.storageBytesBound(chunks, chunks), GroupField.storageBytesBound(grid.cellCount(), chunks));
    try std.testing.expect(field.residentBytes() > GroupField.storageBytesBound(chunks / 2, chunks));
}

test "an unbuilt field holds no memory and never builds" {
    var grid = NavGrid{};
    defer grid.deinit(std.testing.allocator);
    try grid.prepare(std.testing.allocator, 0, 32, 32, default_cell_size, default_nav_chunk_tiles);
    var field = GroupField{};
    defer field.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), field.residentBytes());
    try std.testing.expect(!field.beginBuild(&grid, emptyKey(1), 0, 1, 10));
    try std.testing.expectEqual(GroupFieldState.empty, field.state);
    try std.testing.expect(field.sample(&grid, 0) == null);
    try std.testing.expect(field.lookup(&grid, 0) == null);
}

test "a pool growth out of memory leaves the field unchanged (FailingAllocator)" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try randomObstacleGrid(allocator, &grid, 40, 40, 4, 0x0f8);
    const goal_index = firstOpenCell(&grid, 20 * 40 + 20);
    const budget: usize = 32;

    var flat = try FlatField.init(allocator, &grid, goal_index, grid.cellCount());
    defer flat.deinit(allocator);
    while (!flat.ready) flat.expand(&grid, budget);

    var failures: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var field = GroupField{};
        defer field.deinit(allocator);
        try std.testing.expect(try beginTestBuild(allocator, &field, &grid, goal_index, grid.cellCount(), budget));
        var left = budget;
        while (field.expand(&grid, &left) != .stalled) left = budget;
        const pool_len = field.blocks.len;
        const cost_column = field.columns.cost.ptr;
        const directory = field.directory.ptr;
        const pushed = field.pushed_count;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        if (field.growForStall(failing.allocator(), &grid)) |_| {
            try std.testing.expect(field.blocks.len > pool_len);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expectEqual(pool_len, field.blocks.len);
            try std.testing.expectEqual(cost_column, field.columns.cost.ptr);
            try std.testing.expectEqual(directory, field.directory.ptr);
            try std.testing.expectEqual(pushed, field.pushed_count);
            try std.testing.expectEqual(GroupFieldState.building, field.state);
            // Still stalled, and the real allocator completes the same field.
            var retry = budget;
            try std.testing.expectEqual(Progress.stalled, field.expand(&grid, &retry));
            try std.testing.expectEqual(budget, retry);
        }
        try buildToReady(allocator, &field, &grid, budget);
        for (0..grid.cellCount()) |cell| {
            const found = field.lookup(&grid, cell);
            if (flat.cost[cell] == unreachable_cost) {
                try std.testing.expect(found == null);
            } else {
                try std.testing.expectEqual(flat.cost[cell], found.?.cost);
                try std.testing.expectEqual(flat.flow[cell], found.?.flow_dir);
            }
        }
    }
    // The directory and the pool allocation each fail once.
    try std.testing.expectEqual(@as(usize, 2), failures);
}

test "a warmed pool rebuilds the same field without allocating (FailingAllocator)" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try randomObstacleGrid(allocator, &grid, 40, 40, 8, 0x3a3);
    const goal_index = firstOpenCell(&grid, 20 * 40 + 20);
    var field = GroupField{};
    defer field.deinit(allocator);
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, goal_index, grid.cellCount(), 16));
    try buildToReady(allocator, &field, &grid, 16);
    const pushed = field.pushed_count;

    // Every growth path runs against the failing allocator: the high-water pool covers it.
    try std.testing.expect(try beginTestBuild(std.testing.failing_allocator, &field, &grid, goal_index, grid.cellCount(), 16));
    try buildToReady(std.testing.failing_allocator, &field, &grid, 16);
    try std.testing.expectEqual(pushed, field.pushed_count);
}

test "sample matches the flat reference on chunk-edge, interior, uncovered, and unpooled cells" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try randomObstacleGrid(allocator, &grid, 48, 48, 8, 0x77);
    const goal_index = firstOpenCell(&grid, 24 * 48 + 24);
    // A 400-cell cap leaves most chunks without a block and cuts others mid-chunk.
    const max_cells: usize = 400;
    var field = GroupField{};
    defer field.deinit(allocator);
    try std.testing.expect(try beginTestBuild(allocator, &field, &grid, goal_index, max_cells, 64));
    try buildToReady(allocator, &field, &grid, 64);
    var flat = try FlatField.init(allocator, &grid, goal_index, max_cells);
    defer flat.deinit(allocator);
    while (!flat.ready) flat.expand(&grid, 64);
    try std.testing.expect(field.used_blocks < grid.dir.items.len);

    var covered: usize = 0;
    for (0..grid.cellCount()) |cell| {
        const got = field.sample(&grid, cell);
        if (flat.cost[cell] == unreachable_cost) {
            try std.testing.expect(got == null);
            continue;
        }
        covered += 1;
        const dir = flat.flow[cell];
        const expected = if (dir == GroupField.no_flow) grid.cellCenter(goal_index) else grid.cellCenter(flat.parentIndex(&grid, cell));
        try std.testing.expectEqual(expected, got.?);
    }
    try std.testing.expectEqual(max_cells, covered);
}
