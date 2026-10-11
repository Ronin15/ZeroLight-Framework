// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! One level's nav cells, stored per chunk: a chunk directory whose entry is OPEN,
//! BLOCKED, or a slot in a pool of cell blocks (blocked bits plus chunk-local component
//! labels). A uniform chunk holds no cells. A chunk's cells are the world's composed
//! blocked bits OR the static colliders listed at that chunk, composed one chunk at a
//! time by its one writer.

const std = @import("std");
const math = @import("../../../core/math.zig");
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const world_terrain = @import("../../world_terrain.zig");
const ChunkBits = world_terrain.ChunkBits;
const ChunkForm = world_terrain.ChunkForm;
const max_chunk_cells = world_terrain.max_chunk_cells;
const ColliderView = @import("../static_colliders.zig").ColliderView;
const types = @import("types.zig");
const default_cell_size = types.default_cell_size;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;
const no_component = types.no_component;
const GridCell = types.GridCell;
const NavSpan = types.NavSpan;
const setLen = types.setLen;
const neighbor_dirs = types.neighbor_dirs;
const rect_edge_epsilon = types.rect_edge_epsilon;

// Directory sentinels; block slots stay below them (at most one slot per chunk, and
// `validateChunkGrid` keeps a level's chunk count below 2^31).
const open_entry: u32 = std.math.maxInt(u32);
const blocked_entry: u32 = std.math.maxInt(u32) - 1;

/// "No cell block" for a remask item that may only end uniform.
pub const no_block: u32 = std.math.maxInt(u32);

comptime {
    // A 16x16 chunk under the corner rule holds at most 128 components, so labels fit u8.
    std.debug.assert(max_chunk_cells / 2 <= std.math.maxInt(u8));
    std.debug.assert(neighbor_dirs.len == 8);
}

const NavCellBlock = struct {
    bits: ChunkBits,
    labels: [max_chunk_cells]u8,
    blocked_count: u16,
    label_count: u8,
};

inline fn testBit(words: *const ChunkBits, local: usize) bool {
    return (words[local >> 6] >> @intCast(local & 63)) & 1 != 0;
}

inline fn clearBit(words: *ChunkBits, local: usize) void {
    words[local >> 6] &= ~(@as(u64, 1) << @intCast(local & 63));
}

// Bit of cell (x + dx, y + dy) in a 3x3 `neighborhood` mask.
fn neighborhoodBit(dx: i32, dy: i32) u4 {
    return @intCast((dy + 1) * 3 + (dx + 1));
}

/// The moves a cell may take given its `neighborhood` mask: bit `d` set when
/// `neighbor_dirs[d]` leads to an open cell, a diagonal only when both orthogonal cells it
/// passes are open too (no squeezing through a corner).
pub const allowed_moves: [512]u8 = blk: {
    @setEvalBranchQuota(512 * neighbor_dirs.len * 8);
    var table: [512]u8 = undefined;
    for (0..512) |mask| {
        const blocked = struct {
            fn at(m: usize, dx: i32, dy: i32) bool {
                return (m >> neighborhoodBit(dx, dy)) & 1 != 0;
            }
        }.at;
        var moves: u8 = 0;
        for (neighbor_dirs, 0..) |dir, index| {
            if (blocked(mask, dir.x, dir.y)) continue;
            if (dir.diagonal and (blocked(mask, dir.x, 0) or blocked(mask, 0, dir.y))) continue;
            moves |= @as(u8, 1) << index;
        }
        table[mask] = moves;
    }
    break :blk table;
};

/// The cells of a chunk within one cell (8-neighbour) of a changed cell: `around[(dy + 1) *
/// 3 + (dx + 1)]` holds the changed bits of the chunk at offset (dx, dy) from it (zero when
/// absent or out of the level), every chunk `edge` cells a side in chunk-local row-major
/// bits. Out-of-level bits of the result may be set.
// SIMD verdict: word-parallel scalar. Each row of at most 16 cells dilates as one padded
// word (shifts and ORs); no per-cell loop is left to vectorize.
pub fn dilateChanged3x3(edge: u16, around: *const [9]ChunkBits) ChunkBits {
    // An edge of at most 16 keeps a padded row within 18 bits and every shift below 64.
    std.debug.assert(edge >= 1 and edge <= world_terrain.max_chunk_edge and std.math.isPowerOfTwo(edge));
    const cells: usize = edge;
    // Padded rows y = -1 .. edge at index y + 1: bit 0 is x = -1, bit edge + 1 is x = edge.
    var padded: [world_terrain.max_chunk_edge + 2]u32 = @splat(0);
    for (padded[0 .. cells + 2], 0..) |*row, index| {
        const band: usize = if (index == 0) 0 else if (index == cells + 1) 2 else 1;
        const source_row = if (index == 0) cells - 1 else if (index == cells + 1) 0 else index - 1;
        const west = chunkRow(&around[band * 3], cells, source_row);
        const center = chunkRow(&around[band * 3 + 1], cells, source_row);
        const east = chunkRow(&around[band * 3 + 2], cells, source_row);
        row.* = (center << 1) | ((west >> @intCast(cells - 1)) & 1) | ((east & 1) << @intCast(cells + 1));
    }
    const row_mask: u32 = (@as(u32, 1) << @intCast(cells)) - 1;
    var dilated: ChunkBits = @splat(0);
    for (0..cells) |y| {
        const vertical = padded[y] | padded[y + 1] | padded[y + 2];
        const both = vertical | (vertical << 1) | (vertical >> 1);
        const local = y * cells;
        dilated[local / 64] |= @as(u64, (both >> 1) & row_mask) << @intCast(local % 64);
    }
    return dilated;
}

// Row `row` of `edge`-cell chunk bits. A row never straddles a word: 64 is a multiple of
// every chunk edge.
fn chunkRow(bits: *const ChunkBits, edge: usize, row: usize) u32 {
    // At most 16 bits; shifts stay below 64.
    const local = row * edge;
    const mask: u64 = (@as(u64, 1) << @intCast(edge)) - 1;
    return @intCast((bits[local / 64] >> @intCast(local % 64)) & mask);
}

pub const NavGrid = struct {
    // Nav cells for ONE level (Z-floor). All levels of a graph share the dimensions,
    // cell_size, and chunk_tiles, so chunk ids and cell indices agree across levels.
    level: u16 = 0,
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    // Chunk side length in cells, a power of two.
    chunk_tiles: u16 = default_nav_chunk_tiles,
    chunk_shift: u4 = 0,
    chunks_x: usize = 0,
    blocked_count: usize = 0,
    dir: std.ArrayList(u32) = .empty,
    blocks: std.MultiArrayList(NavCellBlock) = .{},
    // Released block slots; capacity always covers every pooled block.
    block_free: std.ArrayList(u32) = .empty,
    // Column views refreshed whenever the block pool grows.
    block_bits: []ChunkBits = &.{},
    block_labels: [][max_chunk_cells]u8 = &.{},
    block_counts: []u16 = &.{},
    block_label_counts: []u8 = &.{},

    pub fn deinit(self: *NavGrid, allocator: std.mem.Allocator) void {
        self.block_free.deinit(allocator);
        self.blocks.deinit(allocator);
        self.dir.deinit(allocator);
        self.* = undefined;
    }

    /// Sets this level's dimensions with every chunk OPEN and no cell block. Dimensions are
    /// assigned by the owning NavGraph so every level stays consistent.
    pub fn prepare(
        self: *NavGrid,
        allocator: std.mem.Allocator,
        level: u16,
        width: usize,
        height: usize,
        cell_size: f32,
        chunk_tiles: u16,
    ) !void {
        std.debug.assert(chunk_tiles != 0 and std.math.isPowerOfTwo(chunk_tiles));
        self.level = level;
        self.cell_size = cell_size;
        self.width = width;
        self.height = height;
        self.chunk_tiles = chunk_tiles;
        self.chunk_shift = @intCast(@ctz(chunk_tiles));
        self.chunks_x = self.chunkGeometry().chunksX();
        try setLen(&self.dir, allocator, self.chunkGeometry().chunkCount());
        @memset(self.dir.items, open_entry);
        self.blocks.clearRetainingCapacity();
        self.block_free.clearRetainingCapacity();
        self.refreshColumns();
        self.blocked_count = 0;
    }

    fn refreshColumns(self: *NavGrid) void {
        const columns = self.blocks.slice();
        self.block_bits = columns.items(.bits);
        self.block_labels = columns.items(.labels);
        self.block_counts = columns.items(.blocked_count);
        self.block_label_counts = columns.items(.label_count);
    }

    /// Grows the free block list to at least `needed` slots, so the next `needed` claims
    /// pop without allocating. Pool growth is geometric and counted.
    pub fn ensureFreeBlocks(self: *NavGrid, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        if (self.block_free.items.len >= needed) return;
        const added = needed - self.block_free.items.len;
        const total = self.blocks.len + added;
        std.debug.assert(total < blocked_entry);
        if (total > self.blocks.capacity) {
            try self.blocks.ensureTotalCapacity(allocator, @max(total, self.blocks.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            pool_grows.* += 1;
        }
        try self.block_free.ensureTotalCapacity(allocator, self.blocks.capacity);
        // Pushed in descending slot order so claims hand out ascending slots.
        const first: u32 = @intCast(self.blocks.len);
        for (0..added) |_| self.blocks.appendAssumeCapacity(undefined);
        var slot: u32 = @intCast(self.blocks.len);
        while (slot > first) {
            slot -= 1;
            self.block_free.appendAssumeCapacity(slot);
        }
        self.refreshColumns();
    }

    /// Takes a free block slot for a chunk's writer; the reserve covered it.
    pub fn claimBlock(self: *NavGrid) u32 {
        return self.block_free.pop().?;
    }

    /// Returns `slot` to the pool. The free list's capacity covers every slot.
    pub fn releaseBlock(self: *NavGrid, slot: u32) void {
        std.debug.assert(self.block_free.items.len < self.block_free.capacity);
        self.block_free.appendAssumeCapacity(slot);
    }

    /// The block slot `chunk` holds, or null for an OPEN or BLOCKED chunk.
    pub fn chunkBlock(self: *const NavGrid, chunk: u32) ?u32 {
        const entry = self.dir.items[chunk];
        return if (entry == open_entry or entry == blocked_entry) null else entry;
    }

    pub fn chunkForm(self: *const NavGrid, chunk: u32) ChunkForm {
        return switch (self.dir.items[chunk]) {
            open_entry => .open,
            blocked_entry => .blocked,
            else => .mixed,
        };
    }

    /// Blocked cells of `chunk`.
    pub fn chunkBlockedCount(self: *const NavGrid, chunk: u32) u32 {
        return switch (self.dir.items[chunk]) {
            open_entry => 0,
            blocked_entry => self.chunkCellCount(chunk),
            else => |slot| self.block_counts[slot],
        };
    }

    fn chunkCellCount(self: *const NavGrid, chunk: u32) u32 {
        const b = self.chunkBounds(chunk);
        return @intCast((b.x1 - b.x0) * (b.y1 - b.y0));
    }

    /// `chunk`'s blocked bits as stored: none for an OPEN chunk, its in-level cells for a
    /// BLOCKED one, its block's bits for a MIXED one. O(1); never writes.
    pub fn chunkBlockedBits(self: *const NavGrid, chunk: u32) ChunkBits {
        return switch (self.dir.items[chunk]) {
            open_entry => @splat(0),
            blocked_entry => blocked: {
                // A chunk's in-level extent is at most its edge of 16 cells.
                const b = self.chunkBounds(chunk);
                break :blocked world_terrain.inLevelMask(self.edgeGeometry(), .{ .min_x = 0, .min_y = 0, .cols = @intCast(b.x1 - b.x0), .rows = @intCast(b.y1 - b.y0) });
            },
            else => |slot| self.block_bits[slot],
        };
    }

    /// Composes `chunk`'s blocked bits: the world's composed bits for this level (null
    /// world: none) OR the cells of every static collider listed at the chunk, clipped to
    /// it. Out-of-level bits stay clear. Reads only the world and the colliders, so chunks
    /// compose in parallel. O(rows listed at the chunk).
    // SIMD verdict: word-parallel scalar. The world's bits copy as four words and each row
    // ORs in as one `rectMask`; no per-cell loop is left to vectorize.
    pub fn composeChunk(self: *const NavGrid, chunk: u32, world: ?*const WorldSystem, colliders: ColliderView) ChunkBits {
        const b = self.chunkBounds(chunk);
        const edge = self.edgeGeometry();
        const in_level = world_terrain.inLevelMask(edge, .{ .min_x = 0, .min_y = 0, .cols = @intCast(b.x1 - b.x0), .rows = @intCast(b.y1 - b.y0) });
        var bits: ChunkBits = @splat(0);
        if (world) |world_system| {
            // A nav build over a world takes its tiles and chunks.
            std.debug.assert(world_system.chunk_size_tiles == self.chunk_tiles);
            if (@as(usize, self.level) < world_system.levelCount()) {
                bits = switch (world_system.levelChunkBlockedForm(self.level, chunk)) {
                    .open => @splat(0),
                    .blocked => in_level,
                    .mixed => world_system.levelChunkBlockedBits(self.level, chunk).?.*,
                };
            } else {
                // A level the world lacks reads as blocked, as `levelBlocksMovement` does.
                bits = in_level;
            }
        }
        var rows = colliders.chunkRows(self.level, chunk);
        while (rows.next()) |row| {
            const cells = colliders.rowCells(row);
            // Listed rows overlap the chunk; clip to its in-level cells.
            const x0 = @max(@as(usize, cells.min_x), b.x0);
            const y0 = @max(@as(usize, cells.min_y), b.y0);
            const x1 = @min(@as(usize, cells.max_x) + 1, b.x1);
            const y1 = @min(@as(usize, cells.max_y) + 1, b.y1);
            if (x0 >= x1 or y0 >= y1) continue;
            const mask = world_terrain.rectMask(edge, @intCast(x0 - b.x0), @intCast(y0 - b.y0), @intCast(x1 - b.x0), @intCast(y1 - b.y0));
            for (&bits, mask) |*word, row_bits| word.* |= row_bits;
        }
        return bits;
    }

    // One chunk square of this grid's edge, for chunk-local bit masks.
    fn edgeGeometry(self: *const NavGrid) world_terrain.ChunkGeometry {
        return world_terrain.ChunkGeometry.init(self.chunk_tiles, self.chunk_tiles, self.chunk_tiles);
    }

    /// Stores `bits` as `chunk`'s cells: OPEN or BLOCKED when every in-level cell agrees,
    /// else in `slot` with labels from a scan-order flood (8-neighbour, corner rule) that
    /// never leaves the chunk. Returns the chunk's blocked count. Writes only `chunk`'s
    /// directory entry and `slot`, so distinct chunks write in parallel. A result that can
    /// be mixed needs a slot (`slot != no_block`); an unused slot stays with the caller.
    pub fn writeChunk(self: *NavGrid, chunk: u32, slot: u32, bits: ChunkBits) u32 {
        var count: u32 = 0;
        for (bits) |word| count += @popCount(word);
        const cell_count = self.chunkCellCount(chunk);
        if (count == 0) {
            self.dir.items[chunk] = open_entry;
            return 0;
        }
        if (count == cell_count) {
            self.dir.items[chunk] = blocked_entry;
            return count;
        }
        std.debug.assert(slot != no_block);
        self.dir.items[chunk] = slot;
        self.block_bits[slot] = bits;
        // A chunk holds at most 256 cells.
        self.block_counts[slot] = @intCast(count);
        self.block_label_counts[slot] = self.floodLabels(chunk, &bits, &self.block_labels[slot]);
        return count;
    }

    // Labels every open in-level cell of `chunk` 1..m by a scan-order flood; 0 elsewhere.
    // A component's seed is its first unlabeled open cell in chunk-local (row-major) order,
    // the first set bit of the unvisited mask, so labels follow scan order whatever order
    // the flood visits cells in.
    // SIMD verdict: scalar. The flood is a BFS frontier (irreducible); seeds and visits are
    // single-bit tests on the chunk's four words.
    fn floodLabels(self: *const NavGrid, chunk: u32, bits: *const ChunkBits, labels: *[max_chunk_cells]u8) u8 {
        const b = self.chunkBounds(chunk);
        const cols = b.x1 - b.x0;
        const rows = b.y1 - b.y0;
        const shift = self.chunk_shift;
        const edge: usize = self.chunk_tiles;
        const mask: usize = edge - 1;
        const in_level = world_terrain.inLevelMask(self.edgeGeometry(), .{ .min_x = 0, .min_y = 0, .cols = @intCast(cols), .rows = @intCast(rows) });
        var open: ChunkBits = undefined;
        for (&open, bits, in_level) |*word, blocked, inside| word.* = ~blocked & inside;
        var unvisited = open;
        labels.* = @splat(0);
        var queue: [max_chunk_cells]u16 = undefined;
        var label: u8 = 0;
        var word_index: usize = 0;
        while (word_index < unvisited.len) {
            if (unvisited[word_index] == 0) {
                word_index += 1;
                continue;
            }
            const seed: usize = word_index * 64 + @ctz(unvisited[word_index]);
            label += 1;
            clearBit(&unvisited, seed);
            labels[seed] = label;
            queue[0] = @intCast(seed);
            var queue_len: usize = 1;
            var read: usize = 0;
            while (read < queue_len) : (read += 1) {
                const current: usize = queue[read];
                const col = current & mask;
                const row = current >> shift;
                const west = col > 0;
                const east = col + 1 < cols;
                const north = row > 0;
                const south = row + 1 < rows;
                // Orthogonal steps, then diagonals through two open orthogonal cells.
                const steps = [8]struct { ok: bool, local: usize }{
                    .{ .ok = east, .local = current +% 1 },
                    .{ .ok = south, .local = current +% edge },
                    .{ .ok = west, .local = current -% 1 },
                    .{ .ok = north, .local = current -% edge },
                    .{ .ok = south and east and testBit(&open, current +% 1) and testBit(&open, current +% edge), .local = current +% edge +% 1 },
                    .{ .ok = south and west and testBit(&open, current -% 1) and testBit(&open, current +% edge), .local = current +% edge -% 1 },
                    .{ .ok = north and west and testBit(&open, current -% 1) and testBit(&open, current -% edge), .local = current -% edge -% 1 },
                    .{ .ok = north and east and testBit(&open, current +% 1) and testBit(&open, current -% edge), .local = current -% edge +% 1 },
                };
                inline for (steps) |step| {
                    if (step.ok and testBit(&unvisited, step.local)) {
                        clearBit(&unvisited, step.local);
                        labels[step.local] = label;
                        queue[queue_len] = @intCast(step.local);
                        queue_len += 1;
                    }
                }
            }
        }
        return label;
    }

    // World-rect -> inclusive nav-cell span, clamped to the grid. Shared by tile-edit span
    // derivation and tests so every rect->cell site uses identical epsilon-adjusted clamping.
    pub fn cellSpanForWorldRect(self: *const NavGrid, min_x: f32, min_y: f32, max_x: f32, max_y: f32) NavSpan {
        const min_cell = self.worldToCellClamped(.{ .x = min_x, .y = min_y });
        const max_cell = self.worldToCellClamped(.{ .x = @max(min_x, max_x - rect_edge_epsilon), .y = @max(min_y, max_y - rect_edge_epsilon) });
        return .{
            .min_x = @intCast(@min(min_cell.x, max_cell.x)),
            .min_y = @intCast(@min(min_cell.y, max_cell.y)),
            .max_x = @intCast(@max(min_cell.x, max_cell.x)),
            .max_y = @intCast(@max(min_cell.y, max_cell.y)),
        };
    }

    pub fn cellCount(self: *const NavGrid) usize {
        return self.width * self.height;
    }

    pub fn valid(self: *const NavGrid) bool {
        // `prepare` sizes the directory to the chunk count.
        return self.width != 0 and self.height != 0 and self.dir.items.len != 0;
    }

    // Precondition: a prepared grid (width/height != 0). Every real caller resolves a
    // NavGrid via NavGraph.grid()/rebuild(), which floors both dimensions to >= 1.
    pub fn worldToCellClamped(self: *const NavGrid, value: math.Vec2) GridCell {
        std.debug.assert(self.width != 0 and self.height != 0);
        const max_x: i32 = @intCast(self.width - 1);
        const max_y: i32 = @intCast(self.height - 1);
        const raw_x: i32 = math.floorToI32(value.x / self.cell_size);
        const raw_y: i32 = math.floorToI32(value.y / self.cell_size);
        return .{
            .x = std.math.clamp(raw_x, 0, max_x),
            .y = std.math.clamp(raw_y, 0, max_y),
        };
    }

    pub fn cellCenter(self: *const NavGrid, index: usize) math.Vec2 {
        const x = index % self.width;
        const y = index / self.width;
        return .{
            .x = (@as(f32, @floatFromInt(x)) + 0.5) * self.cell_size,
            .y = (@as(f32, @floatFromInt(y)) + 0.5) * self.cell_size,
        };
    }

    pub fn indexForCell(self: *const NavGrid, cell: GridCell) ?usize {
        if (cell.x < 0 or cell.y < 0) return null;
        const x: usize = @intCast(cell.x);
        const y: usize = @intCast(cell.y);
        if (x >= self.width or y >= self.height) return null;
        return y * self.width + x;
    }

    inline fn chunkAt(self: *const NavGrid, x: usize, y: usize) u32 {
        // Below the level's chunk count, which `validateChunkGrid` keeps below 2^31.
        return @intCast((y >> self.chunk_shift) * self.chunks_x + (x >> self.chunk_shift));
    }

    inline fn localAt(self: *const NavGrid, x: usize, y: usize) u8 {
        const mask: usize = self.chunk_tiles - 1;
        // A chunk holds at most 256 cells.
        return @intCast(((y & mask) << self.chunk_shift) | (x & mask));
    }

    /// Whether in-grid cell (x, y) blocks movement. O(1): one directory entry plus a bit.
    pub inline fn isBlockedXY(self: *const NavGrid, x: usize, y: usize) bool {
        std.debug.assert(x < self.width and y < self.height);
        return switch (self.dir.items[self.chunkAt(x, y)]) {
            open_entry => false,
            blocked_entry => true,
            else => |slot| testBit(&self.block_bits[slot], self.localAt(x, y)),
        };
    }

    pub fn isBlockedIndex(self: *const NavGrid, index: usize) bool {
        std.debug.assert(index < self.cellCount());
        const y = index / self.width;
        return self.isBlockedXY(index - y * self.width, y);
    }

    pub fn isBlockedCell(self: *const NavGrid, cell: GridCell) bool {
        const index = self.indexForCell(cell) orelse return true;
        return self.isBlockedIndex(index);
    }

    // Blocked state of a cell given signed coordinates; out of the level reads blocked.
    inline fn isBlockedSigned(self: *const NavGrid, x: isize, y: isize) bool {
        if (x < 0 or y < 0) return true;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.width or uy >= self.height) return true;
        return self.isBlockedXY(ux, uy);
    }

    /// The 3x3 blocked mask around in-grid cell (x, y): bit `(dy + 1) * 3 + (dx + 1)` for
    /// cell (x + dx, y + dy), out-of-level cells set. Index `allowed_moves` with it. A cell
    /// inside its chunk reads one directory entry; a chunk-edge cell up to four.
    pub inline fn neighborhood(self: *const NavGrid, x: usize, y: usize) u16 {
        const mask: usize = self.chunk_tiles - 1;
        const local_x = x & mask;
        const local_y = y & mask;
        if (local_x != 0 and local_y != 0 and local_x != mask and local_y != mask and x + 1 < self.width and y + 1 < self.height) {
            switch (self.dir.items[self.chunkAt(x, y)]) {
                open_entry => return 0,
                blocked_entry => return 0x1ff,
                else => |slot| {
                    const bits = &self.block_bits[slot];
                    var result: u16 = 0;
                    // Each row of the chunk sits inside one 64-bit word (64 is a multiple of
                    // every chunk edge), so a 3-bit window never straddles words.
                    inline for (0..3) |row| {
                        const local = ((local_y + row - 1) << self.chunk_shift) + local_x - 1;
                        const window: u16 = @intCast((bits[local / 64] >> @intCast(local % 64)) & 0b111);
                        result |= window << (3 * row);
                    }
                    return result;
                },
            }
        }
        var result: u16 = 0;
        const sx: isize = @intCast(x);
        const sy: isize = @intCast(y);
        inline for (.{ -1, 0, 1 }) |dy| {
            inline for (.{ -1, 0, 1 }) |dx| {
                if (self.isBlockedSigned(sx + dx, sy + dy)) result |= @as(u16, 1) << neighborhoodBit(dx, dy);
            }
        }
        return result;
    }

    /// Nav-cell span covering the inclusive world tile box on this level, clamped to the
    /// world; null when the box misses the world. For a nav build over the world the span
    /// is the box itself.
    pub fn cellSpanForTileBox(self: *const NavGrid, world: *const WorldSystem, min_x: u32, min_y: u32, max_x: u32, max_y: u32) ?NavSpan {
        if (world.width == 0 or world.height == 0) return null;
        if (min_x >= world.width or min_y >= world.height or min_x > max_x or min_y > max_y) return null;
        const last_x: u16 = @intCast(@min(max_x, @as(u32, world.width) - 1));
        const last_y: u16 = @intCast(@min(max_y, @as(u32, world.height) - 1));
        const first = world.cellRect(@intCast(min_x), @intCast(min_y)) orelse return null;
        const last = world.cellRect(last_x, last_y) orelse return null;
        return self.cellSpanForWorldRect(first.x, first.y, last.x + last.w, last.y + last.h);
    }

    // Chunk-tiling geometry for this grid; the shared source of the chunk_id<->cell and
    // label-encoding convention that NavGraph must agree with (see types.ChunkGeometry).
    pub fn chunkGeometry(self: *const NavGrid) types.ChunkGeometry {
        return .{ .width = self.width, .height = self.height, .chunk_tiles = self.chunk_tiles };
    }

    pub fn chunksX(self: *const NavGrid) usize {
        return self.chunkGeometry().chunksX();
    }

    pub fn chunksY(self: *const NavGrid) usize {
        return self.chunkGeometry().chunksY();
    }

    pub fn chunkOfCell(self: *const NavGrid, index: usize) u32 {
        return self.chunkGeometry().chunkOf(index);
    }

    pub const ChunkBounds = types.ChunkGeometry.Bounds;

    // Cell rect [x0,x1) x [y0,y1) of one chunk, clamped to the grid.
    pub fn chunkBounds(self: *const NavGrid, chunk_id: u32) ChunkBounds {
        return self.chunkGeometry().chunkBounds(chunk_id);
    }

    /// The blocked bits of `chunk`'s cells along one side, bit `i` for the side's `i`-th
    /// cell (rows top to bottom for west/east, columns left to right for north/south).
    pub fn sideBits(self: *const NavGrid, chunk: u32, side: ChunkSide) u16 {
        const b = self.chunkBounds(chunk);
        const cols = b.x1 - b.x0;
        const rows = b.y1 - b.y0;
        const run: usize = switch (side) {
            .west, .east => rows,
            .north, .south => cols,
        };
        const all: u16 = @intCast((@as(u32, 1) << @intCast(run)) - 1);
        const slot = switch (self.dir.items[chunk]) {
            open_entry => return 0,
            blocked_entry => return all,
            else => |slot| slot,
        };
        const bits = &self.block_bits[slot];
        const shift = self.chunk_shift;
        switch (side) {
            .north, .south => {
                // A chunk row sits inside one 64-bit word.
                const row: usize = if (side == .north) 0 else rows - 1;
                const start = row << shift;
                return @intCast((bits[start / 64] >> @intCast(start % 64)) & all);
            },
            .west, .east => {
                const col: usize = if (side == .west) 0 else cols - 1;
                var result: u16 = 0;
                for (0..rows) |row| {
                    if (testBit(bits, (row << shift) | col)) result |= @as(u16, 1) << @intCast(row);
                }
                return result;
            },
        }
    }

    pub const ChunkSide = enum { west, east, north, south };

    /// The chunk-local component label (1..m) of `chunk`'s cell `local`, 0 when blocked.
    pub fn labelAtLocal(self: *const NavGrid, chunk: u32, local: u8) u8 {
        return switch (self.dir.items[chunk]) {
            open_entry => 1,
            blocked_entry => 0,
            else => |slot| self.block_labels[slot][local],
        };
    }

    /// The cell's chunk-local component label (1..m in the chunk's flood order), 0 for a
    /// blocked cell. At most 128 labels fit a 16x16 chunk under the corner rule.
    pub fn labelAt(self: *const NavGrid, index: usize) u8 {
        const y = index / self.width;
        const x = index - y * self.width;
        return self.labelAtLocal(self.chunkAt(x, y), self.localAt(x, y));
    }

    /// The cell's level-unique component id: chunk * (chunk_tiles^2 + 1) + label, or
    /// `no_component` for a blocked cell.
    pub fn componentOf(self: *const NavGrid, index: usize) u32 {
        const label = self.labelAt(index);
        if (label == 0) return no_component;
        // Below no_cell for a validated grid (`validateChunkGrid` bounds the label space).
        return @intCast(@as(u64, self.chunkOfCell(index)) * self.chunkGeometry().labelStride() + label);
    }

    // True only when both cells share a chunk-local component, i.e. a local path exists
    // entirely within one chunk. Cross-chunk reachability routes through the abstract
    // graph, never through this predicate.
    pub fn connected(self: *const NavGrid, a: usize, b: usize) bool {
        const component = self.componentOf(a);
        return component != no_component and component == self.componentOf(b);
    }

    /// Bytes held by the directory and the block pool (allocated capacity).
    pub fn residentBytes(self: *const NavGrid) usize {
        return self.dir.capacity * @sizeOf(u32) +
            self.blocks.capacity * (@sizeOf(ChunkBits) + max_chunk_cells + @sizeOf(u16) + @sizeOf(u8)) +
            self.block_free.capacity * @sizeOf(u32);
    }

    /// Mixed chunks holding a cell block.
    pub fn liveBlockCount(self: *const NavGrid) usize {
        return self.blocks.len - self.block_free.items.len;
    }

    // Projects a blocked goal cell to the nearest open cell on this level within a
    // bounded radius, scanning rings outward in (dy, dx) order. Only tests openness, not
    // reachability from any start (that is the search's job); returns the open index, or
    // null if no open cell is found within the radius. A ring's top and bottom rows test
    // a chunk row at a time; its side columns test per cell.
    pub fn projectToNearestOpen(self: *const NavGrid, cell: GridCell, radius: i32) ?usize {
        if (self.indexForCell(cell)) |index| {
            if (!self.isBlockedIndex(index)) return index;
        }
        const width: i64 = @intCast(self.width);
        const height: i64 = @intCast(self.height);
        var ring: i64 = 1;
        while (ring <= radius) : (ring += 1) {
            var dy: i64 = -ring;
            while (dy <= ring) : (dy += 1) {
                const y = @as(i64, cell.y) + dy;
                if (y < 0 or y >= height) continue;
                const uy: usize = @intCast(y);
                if (dy == -ring or dy == ring) {
                    // Widened before subtracting, clamped while wide.
                    const lo = @max(@as(i64, cell.x) - ring, 0);
                    const hi = @min(@as(i64, cell.x) + ring, width - 1);
                    if (lo > hi) continue;
                    if (self.firstOpenInRow(uy, @intCast(lo), @intCast(hi))) |x| return uy * self.width + x;
                    continue;
                }
                inline for (.{ -1, 1 }) |sign| {
                    const x = @as(i64, cell.x) + sign * ring;
                    if (x >= 0 and x < width and !self.isBlockedXY(@intCast(x), uy)) return uy * self.width + @as(usize, @intCast(x));
                }
            }
        }
        return null;
    }

    // The smallest x in [lo, hi] on row y whose cell is open, chunk by chunk: an OPEN chunk
    // answers at once, a BLOCKED one is skipped, a mixed one tests its row's bits as one
    // word (`@ctz` of the open bits keeps the smallest x).
    fn firstOpenInRow(self: *const NavGrid, y: usize, lo: usize, hi: usize) ?usize {
        const shift = self.chunk_shift;
        const mask: usize = self.chunk_tiles - 1;
        var x = lo;
        while (x <= hi) {
            const chunk_x0 = x & ~mask;
            const chunk_end = @min(chunk_x0 + self.chunk_tiles - 1, hi);
            switch (self.dir.items[self.chunkAt(x, y)]) {
                open_entry => return x,
                blocked_entry => {},
                else => |slot| {
                    const start = (y & mask) << shift;
                    const row: u64 = (self.block_bits[slot][start / 64] >> @intCast(start % 64));
                    // Columns [x - chunk_x0, chunk_end - chunk_x0] of this chunk row.
                    const first_col = x - chunk_x0;
                    const span = chunk_end - x + 1;
                    const window: u64 = ((@as(u64, 1) << @intCast(span)) - 1) << @intCast(first_col);
                    const open = ~row & window;
                    if (open != 0) return chunk_x0 + @ctz(open);
                },
            }
            x = chunk_end + 1;
        }
        return null;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const DataSystem = @import("../../data_system.zig").DataSystem;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const test_support = @import("test_support.zig");
const baselineCapacity = test_support.baselineCapacity;
const addNavBody = test_support.addNavBody;

test "a block pool grow that fails after the pool moved keeps the column views on the live pool" {
    var grid = NavGrid{};
    defer grid.deinit(std.testing.allocator);
    try grid.prepare(std.testing.allocator, 0, 32, 32, 1, 4);
    var pool_grows: u64 = 0;
    try grid.ensureFreeBlocks(std.testing.allocator, 2, &pool_grows);
    const slot = grid.claimBlock();
    grid.block_counts[slot] = 7;

    // Growing past the pool moves it (allocation 0); growing the free list (allocation 1,
    // after a refused in-place resize) fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    // Past both the pool's and the free list's capacity, so both must grow.
    const needed = 2 * @max(grid.blocks.capacity, grid.block_free.capacity);
    try std.testing.expectError(error.OutOfMemory, grid.ensureFreeBlocks(failing.allocator(), needed, &pool_grows));
    const columns = grid.blocks.slice();
    try std.testing.expectEqual(columns.items(.bits).ptr, grid.block_bits.ptr);
    try std.testing.expectEqual(columns.items(.blocked_count).ptr, grid.block_counts.ptr);
    try std.testing.expectEqual(columns.items(.labels).ptr, grid.block_labels.ptr);

    // The retry grows the pool; the claimed block kept its count.
    try grid.ensureFreeBlocks(std.testing.allocator, needed, &pool_grows);
    try std.testing.expectEqual(@as(u16, 7), grid.block_counts[slot]);
}

test "pathfinding nav grid blocked set matches per-level composed mask" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const asset_store = @import("../../../assets/assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try @import("../../../assets/world_tileset_meta.zig").load(
        std.testing.allocator,
        asset_store,
        @import("../../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const extra_band = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(extra_band, 5, 6, tree);
    _ = try world.setDenseTile(extra_band, 2, 1, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    var expected_blocked: usize = 0;
    for (0..world.height) |y_usize| {
        const y: u16 = @intCast(y_usize);
        for (0..world.width) |x_usize| {
            const x: u16 = @intCast(x_usize);
            const expect_blocked = world.levelBlocksMovement(0, x, y);
            if (expect_blocked) expected_blocked += 1;
            try std.testing.expectEqual(expect_blocked, system.graph.grid(0).?.isBlockedCell(.{
                .x = @intCast(x),
                .y = @intCast(y),
            }));
        }
    }
    try std.testing.expect(expected_blocked > 0);
    try std.testing.expectEqual(expected_blocked, system.graph.grid(0).?.blocked_count);
}

test "pathfinding nav grid survives degenerate cell size and bounds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    // cell_size 0 and a non-finite bound would feed inf/NaN into @intFromFloat;
    // the guard collapses to at least a 1x1 grid instead of crashing.
    try system.rebuildStaticNavGrid(&data, std.math.inf(f32), 256, 0);
    try std.testing.expect(system.graph.width >= 1);
    try std.testing.expect(system.graph.height >= 1);
}

// The per-cell reference of a chunk's labels: clear, then flood each unlabelled open cell
// in scan order through `isBlockedXY` reads.
fn referenceLabels(grid: *const NavGrid, chunk: u32) [max_chunk_cells]u8 {
    const b = grid.chunkBounds(chunk);
    var labels: [max_chunk_cells]u8 = @splat(0);
    var label: u8 = 0;
    var queue: [max_chunk_cells][2]usize = undefined;
    for (b.y0..b.y1) |sy| for (b.x0..b.x1) |sx| {
        const start = (sy - b.y0) * grid.chunk_tiles + (sx - b.x0);
        if (grid.isBlockedXY(sx, sy) or labels[start] != 0) continue;
        label += 1;
        labels[start] = label;
        queue[0] = .{ sx, sy };
        var len: usize = 1;
        var read: usize = 0;
        while (read < len) : (read += 1) {
            const x = queue[read][0];
            const y = queue[read][1];
            for (neighbor_dirs) |dir| {
                const nx = @as(i64, @intCast(x)) + dir.x;
                const ny = @as(i64, @intCast(y)) + dir.y;
                if (nx < @as(i64, @intCast(b.x0)) or ny < @as(i64, @intCast(b.y0)) or nx >= @as(i64, @intCast(b.x1)) or ny >= @as(i64, @intCast(b.y1))) continue;
                const ux: usize = @intCast(nx);
                const uy: usize = @intCast(ny);
                const local = (uy - b.y0) * grid.chunk_tiles + (ux - b.x0);
                if (grid.isBlockedXY(ux, uy) or labels[local] != 0) continue;
                if (dir.diagonal and (grid.isBlockedXY(ux, y) or grid.isBlockedXY(x, uy))) continue;
                labels[local] = label;
                queue[len] = .{ ux, uy };
                len += 1;
            }
        }
    };
    return labels;
}

test "a remasked chunk equals world bits OR static coverage, labels equal a reference flood" {
    var meta = try test_support.loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    var prng = std.Random.DefaultPrng.init(0x1abe1);
    const random = prng.random();
    for ([_]u16{ 1, 4, 16 }) |edge| {
        // Three chunks and a short border column and row per axis.
        const side_tiles: u16 = edge * 3 + edge / 2;
        const side: f32 = @as(f32, @floatFromInt(side_tiles)) * meta.tileSize();
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try @import("../../world_test_support.zig").demoWorldWithChunkSize(std.testing.allocator, &meta, side, side, edge);
        defer world.deinit();
        const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
        for (0..world.height) |y| for (0..world.width) |x| {
            if (random.uintLessThan(u8, 3) == 0) _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
        };
        // Statics of random size, some across chunk borders and some past the level edge.
        for (0..12) |_| {
            const position = math.Vec2{ .x = (random.float(f32) * 1.2 - 0.1) * side, .y = (random.float(f32) * 1.2 - 0.1) * side };
            _ = try addNavBody(&data, position, .{ .x = 4 + random.float(f32) * meta.tileSize() * 3, .y = 4 + random.float(f32) * meta.tileSize() * 3 }, true);
        }
        var capacity = test_support.abstractCapacity();
        capacity.nav_chunk_tiles = edge;
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const grid = system.graph.grid(0).?;
        for (0..world.height) |y| for (0..world.width) |x| {
            var expected = world.levelBlocksMovement(0, @intCast(x), @intCast(y));
            for (data.movementBodySliceConst().entities) |entity| {
                const rect = data.staticObstacleWorldRect(entity).?;
                const span = grid.cellSpanForWorldRect(rect.min_x, rect.min_y, rect.max_x, rect.max_y);
                if (x >= span.min_x and x <= span.max_x and y >= span.min_y and y <= span.max_y) expected = true;
            }
            try std.testing.expectEqual(expected, grid.isBlockedXY(x, y));
        };
        for (0..grid.dir.items.len) |chunk_index| {
            const chunk: u32 = @intCast(chunk_index);
            const reference = referenceLabels(grid, chunk);
            const b = grid.chunkBounds(chunk);
            for (b.y0..b.y1) |y| for (b.x0..b.x1) |x| {
                try std.testing.expectEqual(reference[(y - b.y0) * edge + (x - b.x0)], grid.labelAt(y * grid.width + x));
            };
        }
    }
}

test "OPEN and BLOCKED chunks hold no cell block after edits elsewhere on their level" {
    var meta = try test_support.loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // 12x12 tiles in 4-tile chunks.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    // Chunk (2,2) fully blocked, chunk (1,1) mixed.
    for (8..12) |y| for (8..12) |x| {
        _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
    };
    _ = try world.setDenseTile(obstacle, 5, 5, tree);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(test_support.abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const grid = system.graph.grid(0).?;
    try std.testing.expectEqual(ChunkForm.blocked, grid.chunkForm(8));
    try std.testing.expectEqual(ChunkForm.mixed, grid.chunkForm(4));
    try expectBlocksOnlyInMixedChunks(grid, &world);

    // Clear the mixed cell and dig into the blocked chunk: chunk (1,1) gives its block back
    // and chunk (2,2) takes one.
    _ = try world.setDenseTile(obstacle, 5, 5, grass);
    _ = try world.setDenseTile(obstacle, 9, 9, grass);
    _ = try system.applyNavUpdates(&test_support.no_colliders, &world, &.{ .{ .level = 0, .x = 5, .y = 5 }, .{ .level = 0, .x = 9, .y = 9 } });
    try std.testing.expectEqual(ChunkForm.mixed, grid.chunkForm(8));
    try std.testing.expect(grid.chunkForm(4) != .mixed);
    try expectBlocksOnlyInMixedChunks(grid, &world);
}

// Every chunk of `grid` is in its world chunk's form (no statics), and only mixed chunks
// hold a cell block.
fn expectBlocksOnlyInMixedChunks(grid: *const NavGrid, world: *const WorldSystem) !void {
    var mixed: usize = 0;
    for (0..grid.dir.items.len) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        const form = world.levelChunkBlockedForm(grid.level, chunk);
        try std.testing.expectEqual(form, grid.chunkForm(chunk));
        try std.testing.expectEqual(form == .mixed, grid.chunkBlock(chunk) != null);
        if (form == .mixed) mixed += 1;
    }
    try std.testing.expectEqual(mixed, grid.liveBlockCount());
}

test "neighborhood equals eight isBlocked reads at chunk corners and level edges" {
    var meta = try test_support.loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    var prng = std.Random.DefaultPrng.init(0x9b);
    const random = prng.random();
    for ([_]u16{ 1, 2, 4, 16 }) |edge| {
        const side_tiles: u16 = edge * 2 + 3;
        const side: f32 = @as(f32, @floatFromInt(side_tiles)) * meta.tileSize();
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try @import("../../world_test_support.zig").demoWorldWithChunkSize(std.testing.allocator, &meta, side, side, edge);
        defer world.deinit();
        const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
        for (0..world.height) |y| for (0..world.width) |x| {
            if (random.boolean()) _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
        };
        var capacity = test_support.abstractCapacity();
        capacity.nav_chunk_tiles = edge;
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const grid = system.graph.grid(0).?;
        for (0..grid.height) |y| for (0..grid.width) |x| {
            var expected: u16 = 0;
            for ([_]i32{ -1, 0, 1 }) |dy| for ([_]i32{ -1, 0, 1 }) |dx| {
                const blocked = grid.isBlockedCell(.{ .x = @as(i32, @intCast(x)) + dx, .y = @as(i32, @intCast(y)) + dy });
                if (blocked) expected |= @as(u16, 1) << neighborhoodBit(dx, dy);
            };
            try std.testing.expectEqual(expected, grid.neighborhood(x, y));
            // The move table admits exactly the steps the per-cell corner rule admits.
            const moves = allowed_moves[expected];
            for (neighbor_dirs, 0..) |dir, index| {
                const nx = @as(i32, @intCast(x)) + dir.x;
                const ny = @as(i32, @intCast(y)) + dir.y;
                var allowed = !grid.isBlockedCell(.{ .x = nx, .y = ny });
                if (allowed and dir.diagonal) allowed = !grid.isBlockedCell(.{ .x = nx, .y = @intCast(y) }) and !grid.isBlockedCell(.{ .x = @intCast(x), .y = ny });
                try std.testing.expectEqual(allowed, moves & (@as(u8, 1) << @intCast(index)) != 0);
            }
        };
    }
}

// The per-cell ring scan `projectToNearestOpen` replaces.
fn projectReference(grid: *const NavGrid, cell: GridCell, radius: i32) ?usize {
    if (grid.indexForCell(cell)) |index| {
        if (!grid.isBlockedIndex(index)) return index;
    }
    var ring: i32 = 1;
    while (ring <= radius) : (ring += 1) {
        var dy: i32 = -ring;
        while (dy <= ring) : (dy += 1) {
            var dx: i32 = -ring;
            while (dx <= ring) : (dx += 1) {
                if (@abs(dx) != ring and @abs(dy) != ring) continue;
                const index = grid.indexForCell(.{ .x = cell.x + dx, .y = cell.y + dy }) orelse continue;
                if (!grid.isBlockedIndex(index)) return index;
            }
        }
    }
    return null;
}

test "word-parallel projection returns the same cell as the per-cell ring scan" {
    var meta = try test_support.loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    var prng = std.Random.DefaultPrng.init(0x7e15);
    const random = prng.random();
    for ([_]u16{ 1, 4, 16 }) |edge| {
        const side_tiles: u16 = edge * 3 + 5;
        const side: f32 = @as(f32, @floatFromInt(side_tiles)) * meta.tileSize();
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try @import("../../world_test_support.zig").demoWorldWithChunkSize(std.testing.allocator, &meta, side, side, edge);
        defer world.deinit();
        const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
        // Mostly blocked, so rings run several cells before an open one.
        for (0..world.height) |y| for (0..world.width) |x| {
            if (random.uintLessThan(u8, 10) != 0) _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
        };
        var capacity = test_support.abstractCapacity();
        capacity.nav_chunk_tiles = edge;
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const grid = system.graph.grid(0).?;
        var y: i32 = -3;
        while (y < @as(i32, @intCast(grid.height)) + 3) : (y += 1) {
            var x: i32 = -3;
            while (x < @as(i32, @intCast(grid.width)) + 3) : (x += 1) {
                for ([_]i32{ 0, 1, 3, 16 }) |radius| {
                    try std.testing.expectEqual(projectReference(grid, .{ .x = x, .y = y }, radius), grid.projectToNearestOpen(.{ .x = x, .y = y }, radius));
                }
            }
        }
    }
}

// Whether cell (x, y) of the 3x3 chunk neighbourhood, in coordinates -edge .. 2 * edge, is
// set in its chunk's bits.
fn aroundBit(around: *const [9]ChunkBits, edge: usize, x: isize, y: isize) bool {
    const span: isize = @intCast(edge);
    if (x < -span or y < -span or x >= 2 * span or y >= 2 * span) return false;
    const chunk_x: usize = @intCast(@divFloor(x, span) + 1);
    const chunk_y: usize = @intCast(@divFloor(y, span) + 1);
    const local: usize = @intCast(@mod(y, span) * span + @mod(x, span));
    return testBit(&around[chunk_y * 3 + chunk_x], local);
}

test "the dilated changed mask equals the per-cell 3x3 reference across chunk edges and corners at chunk edges 4, 8, 16" {
    var prng = std.Random.DefaultPrng.init(0xd11a7e);
    const random = prng.random();
    for ([_]u16{ 4, 8, 16 }) |edge| {
        const cells: usize = edge;
        for (0..40) |round| {
            var around: [9]ChunkBits = undefined;
            for (&around) |*bits| {
                bits.* = @splat(0);
                // Sparse changes, so cells far from every change stay clear.
                for (0..cells * cells) |local| {
                    if (random.uintLessThan(u32, 24) == 0) bits[local / 64] |= @as(u64, 1) << @intCast(local % 64);
                }
            }
            if (round == 0) {
                // Only the diagonal neighbours' corner cells changed.
                for (&around) |*bits| bits.* = @splat(0);
                const last = cells * cells - 1;
                around[0][last / 64] |= @as(u64, 1) << @intCast(last % 64);
                around[8][0] |= 1;
            }
            const dilated = dilateChanged3x3(edge, &around);
            for (0..cells) |y| for (0..cells) |x| {
                var expected = false;
                for ([_]isize{ -1, 0, 1 }) |dy| for ([_]isize{ -1, 0, 1 }) |dx| {
                    if (aroundBit(&around, cells, @as(isize, @intCast(x)) + dx, @as(isize, @intCast(y)) + dy)) expected = true;
                };
                try std.testing.expectEqual(expected, testBit(&dilated, y * cells + x));
            };
            if (round == 0) {
                // The corners reach exactly the center chunk's two corner cells.
                try std.testing.expect(testBit(&dilated, 0) and testBit(&dilated, cells * cells - 1));
            }
        }
    }
}
