// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Chunk-owned terrain storage behind `WorldSystem`'s tile accessors.
//! Per dense layer: a chunk directory whose entry is a uniform tile or a block
//! index into a pool of `edge²` tile blocks. Per level: a composed
//! movement-blocked directory whose entry is OPEN, BLOCKED, or a slot in a pool
//! of bit blocks, plus per-chunk heads of the world-link endpoint lists. A
//! uniform chunk stores no cells; a block returns to uniform when a write leaves
//! all its in-level cells holding one tile, whichever tile. Pools grow only at
//! their reserve seam and only OOM fails growth; every release pushes onto a free
//! list whose capacity already covers the pool, so writes after a reserve
//! allocate nothing.

const std = @import("std");

pub const TileId = u16;

/// Largest chunk edge a bit block covers.
pub const max_chunk_edge: u16 = 16;
pub const max_chunk_cells: usize = @as(usize, max_chunk_edge) * max_chunk_edge;
pub const ChunkBits = [max_chunk_cells / 64]u64;

/// Inline band-list bound per level; `WorldSystem.addDenseLayer` refuses a band past it
/// with the same error as its configured per-level cap.
pub const max_level_bands: usize = 32;

/// Head/next sentinel of a level's link-endpoint lists.
pub const no_link_endpoint: u32 = std.math.maxInt(u32);

// A dense directory entry with this bit set holds a uniform tile in its low 16
// bits; otherwise it is a block index. Block indices stay below it: a layer has at
// most one block per chunk, and `validateChunkGrid` keeps a level's chunk count
// below 2^31 (its label space chunks·(edge²+1) is below 2^32).
const uniform_bit: u32 = 1 << 31;

// Composed directory sentinels; slot indices stay below them for the same reason.
const open_entry: u32 = std.math.maxInt(u32);
const blocked_entry: u32 = std.math.maxInt(u32) - 1;

/// One level's chunk grid. `edge` is a power of two in [1, max_chunk_edge].
pub const ChunkGeometry = struct {
    width: u16,
    height: u16,
    edge: u16,
    shift: u4,
    chunks_x: u32,
    chunks_y: u32,

    pub fn init(width: u16, height: u16, edge: u16) ChunkGeometry {
        std.debug.assert(edge >= 1 and edge <= max_chunk_edge and std.math.isPowerOfTwo(edge));
        const edge_wide: u32 = edge;
        return .{
            .width = width,
            .height = height,
            .edge = edge,
            .shift = @intCast(@ctz(edge)),
            .chunks_x = (@as(u32, width) + edge_wide - 1) / edge_wide,
            .chunks_y = (@as(u32, height) + edge_wide - 1) / edge_wide,
        };
    }

    pub fn chunkCount(self: ChunkGeometry) usize {
        return @as(usize, self.chunks_x) * self.chunks_y;
    }

    pub fn blockCells(self: ChunkGeometry) usize {
        return @as(usize, self.edge) * self.edge;
    }

    pub fn chunkOf(self: ChunkGeometry, x: u16, y: u16) u32 {
        return (@as(u32, y) >> self.shift) * self.chunks_x + (@as(u32, x) >> self.shift);
    }

    pub fn localOf(self: ChunkGeometry, x: u16, y: u16) u32 {
        const mask: u32 = self.edge - 1;
        return ((@as(u32, y) & mask) << self.shift) | (@as(u32, x) & mask);
    }

    /// The chunk's in-level cell rectangle: origin plus column/row counts, which are
    /// short of `edge` on the right and bottom border chunks.
    pub fn extent(self: ChunkGeometry, chunk: u32) ChunkExtent {
        std.debug.assert(chunk < self.chunkCount());
        const min_x: u32 = (chunk % self.chunks_x) << self.shift;
        const min_y: u32 = (chunk / self.chunks_x) << self.shift;
        return .{
            .min_x = @intCast(min_x),
            .min_y = @intCast(min_y),
            .cols = @intCast(@min(@as(u32, self.edge), @as(u32, self.width) - min_x)),
            .rows = @intCast(@min(@as(u32, self.edge), @as(u32, self.height) - min_y)),
        };
    }
};

pub const ChunkExtent = struct {
    min_x: u16,
    min_y: u16,
    cols: u16,
    rows: u16,

    pub fn cellCount(self: ChunkExtent) u32 {
        return @as(u32, self.cols) * self.rows;
    }
};

pub const BlockFill = struct {
    /// The tile every in-level cell holds while `unequal_pairs` is zero: the
    /// uniform tile the block was taken from, or the one tile a writer left.
    fill: TileId,
    /// Neighboring pairs of the chunk's in-level cells, chained row-major
    /// (`chainPairDelta`), that hold different tiles. Zero means every in-level
    /// cell holds one tile, which returns the chunk to uniform. A single-cell write
    /// updates it in O(1); a chunk's one writer recounts it once (`chainUnequalPairs`).
    unequal_pairs: u16,
};

/// One dense layer's tiles by chunk.
pub const DenseLayerStore = struct {
    dir: []u32 = &.{},
    /// Block `b` is `cells[b * edge² ..][0..edge²]`, row-major by local cell.
    cells: std.ArrayList(TileId) = .empty,
    fills: std.ArrayList(BlockFill) = .empty,
    /// Released block indices; capacity always covers every block in the pool.
    free: std.ArrayList(u32) = .empty,

    /// Every chunk starts uniform at `fill`. O(chunks).
    pub fn init(allocator: std.mem.Allocator, chunk_count: usize, fill: TileId) error{OutOfMemory}!DenseLayerStore {
        const dir = try allocator.alloc(u32, chunk_count);
        @memset(dir, uniformEntry(fill));
        return .{ .dir = dir };
    }

    pub fn deinit(self: *DenseLayerStore, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        self.cells.deinit(allocator);
        self.fills.deinit(allocator);
        self.free.deinit(allocator);
        self.* = undefined;
    }

    pub fn uniformTile(self: *const DenseLayerStore, chunk: u32) ?TileId {
        const entry = self.dir[chunk];
        return if (entry & uniform_bit != 0) @truncate(entry) else null;
    }

    pub fn tile(self: *const DenseLayerStore, geom: ChunkGeometry, x: u16, y: u16) TileId {
        const entry = self.dir[geom.chunkOf(x, y)];
        if (entry & uniform_bit != 0) return @truncate(entry);
        return self.cells.items[@as(usize, entry) * geom.blockCells() + geom.localOf(x, y)];
    }

    /// The tile every in-level cell of `chunk` reads: its uniform tile, or the one
    /// tile a block's cells all hold (an early block no write used); null when the
    /// chunk's cells differ.
    pub fn readUniformTile(self: *const DenseLayerStore, chunk: u32) ?TileId {
        const entry = self.dir[chunk];
        if (entry & uniform_bit != 0) return @truncate(entry);
        const block_fill = self.fills.items[entry];
        return if (block_fill.unequal_pairs == 0) block_fill.fill else null;
    }

    /// The cells of `chunk`'s block, row-major by local cell, or null when uniform.
    pub fn chunkCells(self: *const DenseLayerStore, block_cells: usize, chunk: u32) ?[]const TileId {
        const entry = self.dir[chunk];
        if (entry & uniform_bit != 0) return null;
        return self.cells.items[@as(usize, entry) * block_cells ..][0..block_cells];
    }

    /// Blocks holding cells now (pool size less released blocks).
    pub fn liveBlockCount(self: *const DenseLayerStore) usize {
        return self.fills.items.len - self.free.items.len;
    }

    /// Whether writing `new_tile` into `chunk` materializes a block.
    pub fn writeNeedsBlock(self: *const DenseLayerStore, chunk: u32, new_tile: TileId) bool {
        const uniform = self.uniformTile(chunk) orelse return false;
        return uniform != new_tile;
    }

    /// Guarantees `count` blocks can be taken without allocating. Returns whether
    /// the pool grew (for the owner's growth count).
    pub fn ensureAvailable(self: *DenseLayerStore, allocator: std.mem.Allocator, block_cells: usize, count: usize) error{OutOfMemory}!bool {
        const released = self.free.items.len;
        if (released >= count) return false;
        const total = self.fills.items.len + (count - released);
        const grows = self.cells.capacity < total * block_cells or self.fills.capacity < total or self.free.capacity < total;
        try self.cells.ensureTotalCapacity(allocator, total * block_cells);
        try self.fills.ensureTotalCapacity(allocator, total);
        try self.free.ensureTotalCapacity(allocator, total);
        return grows;
    }

    /// Gives a uniform chunk a block holding its fill, so later writes to it need no
    /// growth; reads are unchanged. Requires one available block. O(edge²).
    pub fn materializeChunk(self: *DenseLayerStore, block_cells: usize, chunk: u32) void {
        const fill = self.uniformTile(chunk).?;
        self.dir[chunk] = self.takeBlock(block_cells, fill);
    }

    /// Returns the chunk to uniform if its block's in-level cells all hold one tile
    /// (an early block no write used, or a writer's block left uniform). O(1).
    pub fn releaseIfUniform(self: *DenseLayerStore, chunk: u32) void {
        const entry = self.dir[chunk];
        if (entry & uniform_bit != 0) return;
        const block_fill = self.fills.items[entry];
        if (block_fill.unequal_pairs != 0) return;
        self.dir[chunk] = uniformEntry(block_fill.fill);
        std.debug.assert(self.free.items.len < self.free.capacity);
        self.free.appendAssumeCapacity(entry);
    }

    /// Writes one cell; infallible. When `writeNeedsBlock`, a block must be available
    /// (`ensureAvailable`). Materializing costs O(edge²) once; a write that leaves
    /// every in-level cell holding one tile releases the block. O(1) otherwise.
    pub fn write(self: *DenseLayerStore, geom: ChunkGeometry, chunk: u32, local: u32, new_tile: TileId) void {
        const block_cells = geom.blockCells();
        var entry = self.dir[chunk];
        if (entry & uniform_bit != 0) {
            const fill: TileId = @truncate(entry);
            if (fill == new_tile) return;
            entry = self.takeBlock(block_cells, fill);
            self.dir[chunk] = entry;
        }
        const block: usize = entry;
        const cells = self.cells.items[block * block_cells ..][0..block_cells];
        const old_tile = cells[local];
        if (old_tile == new_tile) return;
        const block_fill = &self.fills.items[block];
        const pairs = @as(i32, block_fill.unequal_pairs) + chainPairDelta(cells, geom.shift, geom.extent(chunk), local, old_tile, new_tile);
        block_fill.unequal_pairs = @intCast(pairs); // a chunk has at most edge² - 1 pairs
        cells[local] = new_tile;
        if (block_fill.unequal_pairs == 0) {
            block_fill.fill = new_tile;
            self.dir[chunk] = uniformEntry(new_tile);
            std.debug.assert(self.free.items.len < self.free.capacity);
            self.free.appendAssumeCapacity(@intCast(block));
        }
    }

    /// The tile at `local` in `chunk`, from its uniform entry or its block.
    pub fn chunkTile(self: *const DenseLayerStore, block_cells: usize, chunk: u32, local: u32) TileId {
        const entry = self.dir[chunk];
        if (entry & uniform_bit != 0) return @truncate(entry);
        return self.cells.items[@as(usize, entry) * block_cells + local];
    }

    /// `chunk`'s block for the one writer of that chunk, or null when uniform. The
    /// writer never takes or releases a block, so writers of different chunks run at
    /// once; `releaseIfUniform` afterwards returns a block left uniform.
    pub fn ownBlock(self: *DenseLayerStore, geom: ChunkGeometry, chunk: u32) ?OwnedBlock {
        const entry = self.dir[chunk];
        if (entry & uniform_bit != 0) return null;
        const block: usize = entry;
        const block_cells = geom.blockCells();
        const fill_row = &self.fills.items[block];
        return .{
            .cells = self.cells.items[block * block_cells ..][0..block_cells],
            .fill_row = fill_row,
            .shift = geom.shift,
            .extent = geom.extent(chunk),
        };
    }

    /// Gives a uniform chunk a block whose cells stay undefined until the chunk's one
    /// writer fills them (`OwnedBlock.fillFresh`), so the O(edge²) fill runs with the
    /// writer, not here. Requires one available block. O(1).
    pub fn claimChunk(self: *DenseLayerStore, block_cells: usize, chunk: u32) void {
        const fill = self.uniformTile(chunk).?;
        self.dir[chunk] = self.takeBlockUnfilled(block_cells, fill);
    }

    fn takeBlock(self: *DenseLayerStore, block_cells: usize, fill: TileId) u32 {
        const block = self.takeBlockUnfilled(block_cells, fill);
        @memset(self.cells.items[@as(usize, block) * block_cells ..][0..block_cells], fill);
        return block;
    }

    fn takeBlockUnfilled(self: *DenseLayerStore, block_cells: usize, fill: TileId) u32 {
        const block: u32 = if (self.free.pop()) |released| released else blk: {
            const index: u32 = @intCast(self.fills.items.len);
            std.debug.assert(self.cells.capacity >= self.cells.items.len + block_cells);
            _ = self.cells.addManyAsSliceAssumeCapacity(block_cells);
            _ = self.fills.addOneAssumeCapacity();
            break :blk index;
        };
        self.fills.items[block] = .{ .fill = fill, .unequal_pairs = 0 };
        return block;
    }

    /// Reserves one block per chunk for `materializeEveryChunk`; changes no cell.
    pub fn reserveEveryChunk(self: *DenseLayerStore, allocator: std.mem.Allocator, geom: ChunkGeometry) error{OutOfMemory}!void {
        std.debug.assert(self.fills.items.len == 0);
        const chunk_count = geom.chunkCount();
        try self.cells.ensureTotalCapacity(allocator, chunk_count * geom.blockCells());
        try self.fills.ensureTotalCapacity(allocator, chunk_count);
        try self.free.ensureTotalCapacity(allocator, chunk_count);
    }

    /// Gives every chunk block `chunk` so a threaded writer can fill each chunk's own
    /// block and its `BlockFill`; requires every chunk uniform, an empty pool, and
    /// `reserveEveryChunk`. Block contents are undefined until written. Pair with
    /// `finishChunkFill`.
    pub fn materializeEveryChunk(self: *DenseLayerStore, geom: ChunkGeometry) void {
        std.debug.assert(self.fills.items.len == 0);
        _ = self.cells.addManyAsSliceAssumeCapacity(geom.chunkCount() * geom.blockCells());
        for (self.dir, 0..) |*entry, chunk| {
            std.debug.assert(entry.* & uniform_bit != 0);
            self.fills.appendAssumeCapacity(.{ .fill = @truncate(entry.*), .unequal_pairs = 0 });
            entry.* = @intCast(chunk);
        }
    }

    /// Returns every filled block whose in-level cells hold one tile to uniform.
    /// O(chunks).
    pub fn finishChunkFill(self: *DenseLayerStore) void {
        for (self.dir) |*entry| {
            std.debug.assert(entry.* & uniform_bit == 0);
            const block_fill = self.fills.items[entry.*];
            if (block_fill.unequal_pairs != 0) continue;
            self.free.appendAssumeCapacity(entry.*);
            entry.* = uniformEntry(block_fill.fill);
        }
    }

    fn uniformEntry(fill: TileId) u32 {
        return uniform_bit | fill;
    }
};

pub const ChunkForm = enum { open, blocked, mixed };

/// A level's composed movement-blocked bits by chunk.
pub const ChunkBitsStore = struct {
    dir: []u32 = &.{},
    bits: std.ArrayList(ChunkBits) = .empty,
    /// Blocked in-level cells per slot; reaching zero or the chunk's cell count
    /// returns the chunk to OPEN or BLOCKED.
    counts: std.ArrayList(u16) = .empty,
    /// Released slot indices; capacity always covers every slot in the pool.
    free: std.ArrayList(u32) = .empty,

    /// Every chunk starts OPEN. O(chunks).
    pub fn init(allocator: std.mem.Allocator, chunk_count: usize) error{OutOfMemory}!ChunkBitsStore {
        const dir = try allocator.alloc(u32, chunk_count);
        @memset(dir, open_entry);
        return .{ .dir = dir };
    }

    pub fn deinit(self: *ChunkBitsStore, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        self.bits.deinit(allocator);
        self.counts.deinit(allocator);
        self.free.deinit(allocator);
        self.* = undefined;
    }

    pub fn form(self: *const ChunkBitsStore, chunk: u32) ChunkForm {
        return switch (self.dir[chunk]) {
            open_entry => .open,
            blocked_entry => .blocked,
            else => .mixed,
        };
    }

    pub fn get(self: *const ChunkBitsStore, chunk: u32, local: u32) bool {
        return switch (self.dir[chunk]) {
            open_entry => false,
            blocked_entry => true,
            else => |slot| bitIsSet(&self.bits.items[slot], local),
        };
    }

    /// Blocked cells of a mixed chunk (0 or the cell count for OPEN/BLOCKED).
    pub fn blockedCount(self: *const ChunkBitsStore, geom: ChunkGeometry, chunk: u32) u32 {
        return switch (self.dir[chunk]) {
            open_entry => 0,
            blocked_entry => geom.extent(chunk).cellCount(),
            else => |slot| self.counts.items[slot],
        };
    }

    pub fn liveSlotCount(self: *const ChunkBitsStore) usize {
        return self.bits.items.len - self.free.items.len;
    }

    /// Whether setting `local` to `value` takes a slot.
    pub fn setNeedsSlot(self: *const ChunkBitsStore, chunk: u32, local: u32, value: bool) bool {
        return self.form(chunk) != .mixed and self.get(chunk, local) != value;
    }

    /// Guarantees `count` slots can be taken without allocating. Returns whether
    /// the pool grew (for the owner's growth count).
    pub fn ensureAvailable(self: *ChunkBitsStore, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!bool {
        const released = self.free.items.len;
        if (released >= count) return false;
        const total = self.bits.items.len + (count - released);
        const grows = self.bits.capacity < total or self.counts.capacity < total or self.free.capacity < total;
        try self.bits.ensureTotalCapacity(allocator, total);
        try self.counts.ensureTotalCapacity(allocator, total);
        try self.free.ensureTotalCapacity(allocator, total);
        return grows;
    }

    /// Gives an OPEN or BLOCKED chunk a slot holding the same bits, so later sets in
    /// it need no growth; reads are unchanged. Requires one available slot. O(1).
    pub fn materializeChunk(self: *ChunkBitsStore, geom: ChunkGeometry, chunk: u32) void {
        const uniform = self.dir[chunk];
        std.debug.assert(uniform == open_entry or uniform == blocked_entry);
        const slot = self.takeSlot();
        if (uniform == open_entry) {
            self.bits.items[slot] = @splat(0);
            self.counts.items[slot] = 0;
        } else {
            const extent = geom.extent(chunk);
            self.bits.items[slot] = inLevelMask(geom, extent);
            self.counts.items[slot] = @intCast(extent.cellCount());
        }
        self.dir[chunk] = slot;
    }

    /// Returns the chunk to OPEN or BLOCKED if its slot is all clear or all set (an
    /// early slot no set used). O(1).
    pub fn releaseIfUniform(self: *ChunkBitsStore, geom: ChunkGeometry, chunk: u32) void {
        const slot = self.dir[chunk];
        if (slot == open_entry or slot == blocked_entry) return;
        const count = self.counts.items[slot];
        if (count == 0) {
            self.releaseSlot(chunk, slot, open_entry);
        } else if (count == geom.extent(chunk).cellCount()) {
            self.releaseSlot(chunk, slot, blocked_entry);
        }
    }

    /// Sets one cell's bit; infallible. When `setNeedsSlot`, a slot must be available.
    pub fn set(self: *ChunkBitsStore, geom: ChunkGeometry, chunk: u32, local: u32, value: bool) void {
        const extent = geom.extent(chunk);
        var slot = self.dir[chunk];
        switch (slot) {
            open_entry => {
                if (!value) return;
                slot = self.takeSlot();
                self.bits.items[slot] = @splat(0);
                self.counts.items[slot] = 0;
            },
            blocked_entry => {
                if (value) return;
                slot = self.takeSlot();
                self.bits.items[slot] = inLevelMask(geom, extent);
                self.counts.items[slot] = @intCast(extent.cellCount());
            },
            else => {},
        }
        self.dir[chunk] = slot;
        const words = &self.bits.items[slot];
        if (bitIsSet(words, local) == value) return;
        const word_bit = @as(u64, 1) << @intCast(local % 64);
        if (value) {
            words[local / 64] |= word_bit;
            self.counts.items[slot] += 1;
        } else {
            words[local / 64] &= ~word_bit;
            self.counts.items[slot] -= 1;
        }
        const count = self.counts.items[slot];
        if (count == 0) {
            self.releaseSlot(chunk, slot, open_entry);
        } else if (count == extent.cellCount()) {
            self.releaseSlot(chunk, slot, blocked_entry);
        }
    }

    /// Makes the whole chunk OPEN or BLOCKED, releasing its slot; infallible.
    pub fn setChunk(self: *ChunkBitsStore, chunk: u32, blocked: bool) void {
        const uniform = if (blocked) blocked_entry else open_entry;
        const slot = self.dir[chunk];
        if (slot == open_entry or slot == blocked_entry) {
            self.dir[chunk] = uniform;
            return;
        }
        self.releaseSlot(chunk, slot, uniform);
    }

    /// `chunk`'s slot for the one setter of that chunk; requires a mixed chunk. The
    /// setter never takes or releases a slot, so setters of different chunks run at
    /// once; `releaseIfUniform` afterwards returns a slot left all clear or all set
    /// to OPEN or BLOCKED.
    pub fn ownSlot(self: *ChunkBitsStore, chunk: u32) OwnedBits {
        const slot = self.dir[chunk];
        std.debug.assert(slot != open_entry and slot != blocked_entry);
        return .{
            .slot_bits = &self.bits.items[slot],
            .slot_count = &self.counts.items[slot],
            .bits = self.bits.items[slot],
            .count = self.counts.items[slot],
        };
    }

    /// Gives an OPEN or BLOCKED chunk a slot whose bits stay undefined until the
    /// chunk's one setter fills them from that form (`OwnedBits.fillUniform`).
    /// Requires one available slot. O(1).
    pub fn claimChunk(self: *ChunkBitsStore, chunk: u32) void {
        std.debug.assert(self.form(chunk) != .mixed);
        self.dir[chunk] = self.takeSlot();
    }

    fn takeSlot(self: *ChunkBitsStore) u32 {
        if (self.free.pop()) |released| return released;
        const slot: u32 = @intCast(self.bits.items.len);
        _ = self.bits.addOneAssumeCapacity();
        _ = self.counts.addOneAssumeCapacity();
        return slot;
    }

    fn releaseSlot(self: *ChunkBitsStore, chunk: u32, slot: u32, uniform: u32) void {
        self.dir[chunk] = uniform;
        std.debug.assert(self.free.items.len < self.free.capacity);
        self.free.appendAssumeCapacity(slot);
    }

    /// Reserves one slot per chunk for `materializeEveryChunk`; changes no bit.
    pub fn reserveEveryChunk(self: *ChunkBitsStore, allocator: std.mem.Allocator, geom: ChunkGeometry) error{OutOfMemory}!void {
        std.debug.assert(self.bits.items.len == 0);
        const chunk_count = geom.chunkCount();
        try self.bits.ensureTotalCapacity(allocator, chunk_count);
        try self.counts.ensureTotalCapacity(allocator, chunk_count);
        try self.free.ensureTotalCapacity(allocator, chunk_count);
    }

    /// Gives every chunk slot `chunk` so a threaded writer can compose each chunk's
    /// own bits and count; requires an empty pool and `reserveEveryChunk`. Pair with
    /// `finishChunkFill`.
    pub fn materializeEveryChunk(self: *ChunkBitsStore, geom: ChunkGeometry) void {
        std.debug.assert(self.bits.items.len == 0);
        const chunk_count = geom.chunkCount();
        _ = self.bits.addManyAsSliceAssumeCapacity(chunk_count);
        _ = self.counts.addManyAsSliceAssumeCapacity(chunk_count);
        for (self.dir, 0..) |*entry, chunk| entry.* = @intCast(chunk);
    }

    /// Classifies every composed slot as OPEN, BLOCKED, or mixed. O(chunks).
    pub fn finishChunkFill(self: *ChunkBitsStore, geom: ChunkGeometry) void {
        for (self.dir, 0..) |slot, chunk_index| {
            const chunk: u32 = @intCast(chunk_index);
            const count = self.counts.items[slot];
            if (count == 0) {
                self.releaseSlot(chunk, slot, open_entry);
            } else if (count == geom.extent(chunk).cellCount()) {
                self.releaseSlot(chunk, slot, blocked_entry);
            }
        }
    }
};

/// A chunk's tile block held by its one writer. Cells are written in place and
/// `finish` recounts the unequal pairs once, so a dense write costs no per-cell
/// bookkeeping and writers of neighboring chunks never share a counter.
pub const OwnedBlock = struct {
    cells: []TileId,
    fill_row: *BlockFill,
    shift: u4,
    extent: ChunkExtent,
    written: bool = false,

    pub fn write(self: *OwnedBlock, local: u32, new_tile: TileId) void {
        self.cells[local] = new_tile;
        self.written = true;
    }

    /// Fills a block taken by `DenseLayerStore.claimChunk` with its fill tile.
    pub fn fillFresh(self: *OwnedBlock) void {
        std.debug.assert(self.fill_row.unequal_pairs == 0);
        @memset(self.cells, self.fill_row.fill);
    }

    /// Recounts a written block's unequal pairs, O(edge²); a block left holding one
    /// tile records it as its fill for `DenseLayerStore.releaseIfUniform`.
    pub fn finish(self: *const OwnedBlock) void {
        if (!self.written) return;
        const pairs = chainUnequalPairs(self.cells, self.shift, self.extent);
        if (pairs == 0) self.fill_row.fill = self.cells[0];
        self.fill_row.unequal_pairs = pairs;
    }
};

/// Chain pairs (see `chainPairDelta`) of a block's in-level cells that hold
/// different tiles. One pass over the in-level cells, O(edge²).
pub fn chainUnequalPairs(cells: []const TileId, shift: u4, extent: ChunkExtent) u16 {
    const edge = @as(usize, 1) << shift;
    var pairs: u16 = 0;
    if (extent.cols == edge) {
        // Full-width rows: the chain is the block's first `rows` rows in order.
        const chain = cells[0 .. @as(usize, extent.rows) * edge];
        for (chain[0 .. chain.len - 1], chain[1..]) |cell, next| pairs += @intFromBool(cell != next);
        return pairs;
    }
    var previous = cells[0];
    for (0..extent.rows) |row| {
        for (cells[row << shift ..][0..extent.cols]) |cell| {
            pairs += @intFromBool(cell != previous);
            previous = cell;
        }
    }
    return pairs;
}

/// A chunk's in-level cells chain row-major: (row, col) follows (row, col - 1), and
/// a row's first cell follows the previous row's last in-level cell. Returns the
/// change in chain pairs holding different tiles when `local` goes from `old_tile`
/// to `new_tile`: every in-level cell holds one tile exactly when no pair differs.
/// O(1): a cell has at most two chain neighbors.
pub fn chainPairDelta(cells: []const TileId, shift: u4, extent: ChunkExtent, local: u32, old_tile: TileId, new_tile: TileId) i32 {
    const col = local & ((@as(u32, 1) << shift) - 1);
    const row = local >> shift;
    std.debug.assert(col < extent.cols and row < extent.rows);
    var neighbors: [2]u32 = undefined;
    var neighbor_count: usize = 0;
    if (col > 0) {
        neighbors[neighbor_count] = local - 1;
        neighbor_count += 1;
    } else if (row > 0) {
        neighbors[neighbor_count] = ((row - 1) << shift) | (extent.cols - 1);
        neighbor_count += 1;
    }
    if (col + 1 < extent.cols) {
        neighbors[neighbor_count] = local + 1;
        neighbor_count += 1;
    } else if (row + 1 < extent.rows) {
        neighbors[neighbor_count] = (row + 1) << shift;
        neighbor_count += 1;
    }
    var delta: i32 = 0;
    for (neighbors[0..neighbor_count]) |neighbor| {
        delta += @as(i32, @intFromBool(cells[neighbor] != new_tile)) - @intFromBool(cells[neighbor] != old_tile);
    }
    return delta;
}

/// A chunk's composed-bits slot held by its one setter, updated locally and stored
/// once by `finish` for the same reason as `OwnedBlock`.
pub const OwnedBits = struct {
    slot_bits: *ChunkBits,
    slot_count: *u16,
    bits: ChunkBits,
    count: u16,

    pub fn set(self: *OwnedBits, local: u32, value: bool) void {
        if (bitIsSet(&self.bits, local) == value) return;
        const word_bit = @as(u64, 1) << @intCast(local % 64);
        if (value) {
            self.bits[local / 64] |= word_bit;
            self.count += 1;
        } else {
            self.bits[local / 64] &= ~word_bit;
            self.count -= 1;
        }
    }

    /// Sets a slot taken by `ChunkBitsStore.claimChunk` to the chunk's prior OPEN
    /// (`blocked` false) or BLOCKED form.
    pub fn fillUniform(self: *OwnedBits, geom: ChunkGeometry, chunk: u32, blocked: bool) void {
        const extent = geom.extent(chunk);
        self.bits = if (blocked) inLevelMask(geom, extent) else @splat(0);
        self.count = if (blocked) @intCast(extent.cellCount()) else 0;
    }

    pub fn finish(self: *const OwnedBits) void {
        self.slot_bits.* = self.bits;
        self.slot_count.* = self.count;
    }
};

/// Bits of a chunk's in-level cells; border chunks leave out-of-level cells clear.
pub fn inLevelMask(geom: ChunkGeometry, extent: ChunkExtent) ChunkBits {
    var words: ChunkBits = @splat(0);
    for (0..extent.rows) |row| {
        for (0..extent.cols) |col| {
            const local = (row << geom.shift) | col;
            words[local / 64] |= @as(u64, 1) << @intCast(local % 64);
        }
    }
    return words;
}

pub fn bitIsSet(words: *const ChunkBits, local: u32) bool {
    return words[local / 64] & (@as(u64, 1) << @intCast(local % 64)) != 0;
}

/// One level's chunk-owned terrain: its dense band list, composed blocked bits, and
/// link-endpoint heads.
pub const LevelTerrain = struct {
    bands: [max_level_bands]u32 = undefined,
    band_count: u8 = 0,
    blocked: ChunkBitsStore = .{},
    /// Per chunk, the newest link endpoint (`2 * link + side`) on this level, or
    /// `no_link_endpoint`.
    link_heads: []u32 = &.{},

    /// Every chunk OPEN with no link endpoint. O(chunks).
    pub fn init(allocator: std.mem.Allocator, chunk_count: usize) error{OutOfMemory}!LevelTerrain {
        var blocked = try ChunkBitsStore.init(allocator, chunk_count);
        errdefer blocked.deinit(allocator);
        const link_heads = try allocator.alloc(u32, chunk_count);
        @memset(link_heads, no_link_endpoint);
        return .{ .blocked = blocked, .link_heads = link_heads };
    }

    pub fn deinit(self: *LevelTerrain, allocator: std.mem.Allocator) void {
        self.blocked.deinit(allocator);
        allocator.free(self.link_heads);
        self.* = undefined;
    }

    pub fn bandLayers(self: *const LevelTerrain) []const u32 {
        return self.bands[0..self.band_count];
    }

    /// Position of `layer` in this level's band list.
    pub fn bandOf(self: *const LevelTerrain, layer: u32) u8 {
        for (self.bandLayers(), 0..) |band_layer, band| {
            if (band_layer == layer) return @intCast(band);
        }
        unreachable; // every dense layer is a band of its own level
    }
};

test "chunk geometry maps cells to chunk and local indices with short border chunks" {
    const geom = ChunkGeometry.init(10, 6, 4);
    try std.testing.expectEqual(@as(usize, 6), geom.chunkCount());
    try std.testing.expectEqual(@as(u32, 0), geom.chunkOf(3, 3));
    try std.testing.expectEqual(@as(u32, 2), geom.chunkOf(9, 0));
    try std.testing.expectEqual(@as(u32, 5), geom.chunkOf(9, 5));
    try std.testing.expectEqual(@as(u32, 1 * 4 + 1), geom.localOf(9, 5));
    const border = geom.extent(5);
    try std.testing.expectEqual(@as(u16, 8), border.min_x);
    try std.testing.expectEqual(@as(u16, 4), border.min_y);
    try std.testing.expectEqual(@as(u16, 2), border.cols);
    try std.testing.expectEqual(@as(u16, 2), border.rows);
}

test "chunk bits store returns to OPEN and BLOCKED at the in-level cell count of a border chunk" {
    const allocator = std.testing.allocator;
    const geom = ChunkGeometry.init(5, 5, 4);
    var store = try ChunkBitsStore.init(allocator, geom.chunkCount());
    defer store.deinit(allocator);
    // Chunk 3 is the 1x1 corner chunk: one blocked cell is the whole chunk.
    _ = try store.ensureAvailable(allocator, 1);
    store.set(geom, 3, geom.localOf(4, 4), true);
    try std.testing.expectEqual(ChunkForm.blocked, store.form(3));
    try std.testing.expectEqual(@as(usize, 0), store.liveSlotCount());
    // Chunk 1 (1 col x 4 rows): fill all four cells, then clear one.
    for (0..4) |row| store.set(geom, 1, geom.localOf(4, @intCast(row)), true);
    try std.testing.expectEqual(ChunkForm.blocked, store.form(1));
    store.set(geom, 1, geom.localOf(4, 2), false);
    try std.testing.expectEqual(ChunkForm.mixed, store.form(1));
    try std.testing.expectEqual(@as(u32, 3), store.blockedCount(geom, 1));
    store.setChunk(1, false);
    try std.testing.expectEqual(ChunkForm.open, store.form(1));
    try std.testing.expectEqual(@as(usize, 0), store.liveSlotCount());
}

test "a dense block returns to uniform at whichever one tile its in-level cells all hold" {
    const allocator = std.testing.allocator;
    // 6x6 cells in 4-cell chunks: chunk 0 is full, chunk 1 is 2 cols x 4 rows.
    const geom = ChunkGeometry.init(6, 6, 4);
    var store = try DenseLayerStore.init(allocator, geom.chunkCount(), 1);
    defer store.deinit(allocator);
    _ = try store.ensureAvailable(allocator, geom.blockCells(), 1);

    // Every cell of chunk 0 goes from the fill to 7: uniform at 7 on the last write.
    for (0..4) |y| for (0..4) |x| {
        store.write(geom, 0, geom.localOf(@intCast(x), @intCast(y)), 7);
        if (x != 3 or y != 3) try std.testing.expectEqual(@as(?TileId, null), store.uniformTile(0));
    };
    try std.testing.expectEqual(@as(?TileId, 7), store.uniformTile(0));
    try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());

    // The border chunk's eight in-level cells decide alone; its out-of-level cells
    // keep the old fill.
    for (0..4) |y| for (4..6) |x| store.write(geom, 1, geom.localOf(@intCast(x), @intCast(y)), 9);
    try std.testing.expectEqual(@as(?TileId, 9), store.uniformTile(1));
    try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());

    // A mixed block stays a block; restoring its one differing cell re-uniforms it.
    store.write(geom, 0, geom.localOf(2, 1), 3);
    try std.testing.expectEqual(@as(?TileId, null), store.readUniformTile(0));
    try std.testing.expectEqual(@as(usize, 1), store.liveBlockCount());
    store.write(geom, 0, geom.localOf(2, 1), 7);
    try std.testing.expectEqual(@as(?TileId, 7), store.uniformTile(0));
    // One block was ever taken; each re-uniform released it.
    try std.testing.expectEqual(@as(usize, 1), store.fills.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());
}

test "owned-block writes re-uniform exactly like single-cell writes" {
    // 7x6 cells in 4-cell chunks: border chunks 3 wide and 2 tall. 5x5: border
    // chunks 1 wide, 1 tall, and a 1x1 corner.
    try expectOwnedWritesMatchSingle(ChunkGeometry.init(7, 6, 4), 0x5eed_c4a1);
    try expectOwnedWritesMatchSingle(ChunkGeometry.init(5, 5, 4), 0x5eed_c4a2);
}

// Random write batches applied cell by cell to one store and through the one-writer
// form (claim, fill, write in place, finish, release) to another must leave the
// same tiles, uniform forms, and live block count.
fn expectOwnedWritesMatchSingle(geom: ChunkGeometry, seed: u64) !void {
    const allocator = std.testing.allocator;
    var single = try DenseLayerStore.init(allocator, geom.chunkCount(), 1);
    defer single.deinit(allocator);
    var owned = try DenseLayerStore.init(allocator, geom.chunkCount(), 1);
    defer owned.deinit(allocator);
    const tiles = [_]TileId{ 1, 2, 3 };
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..400) |_| {
        const chunk = random.uintLessThan(u32, @intCast(geom.chunkCount()));
        const extent = geom.extent(chunk);
        var writes: [12]struct { local: u32, tile: TileId } = undefined;
        const count = random.intRangeAtMost(usize, 1, writes.len);
        for (writes[0..count]) |*write| {
            const x = extent.min_x + random.uintLessThan(u16, extent.cols);
            const y = extent.min_y + random.uintLessThan(u16, extent.rows);
            write.* = .{ .local = geom.localOf(x, y), .tile = tiles[random.uintLessThan(usize, tiles.len)] };
        }
        for (writes[0..count]) |write| {
            _ = try single.ensureAvailable(allocator, geom.blockCells(), 1);
            single.write(geom, chunk, write.local, write.tile);
        }
        // The batched form: claim when uniform and a write differs, write in place,
        // store once, then release a block left uniform.
        if (owned.uniformTile(chunk)) |uniform| {
            for (writes[0..count]) |write| {
                if (write.tile == uniform) continue;
                _ = try owned.ensureAvailable(allocator, geom.blockCells(), 1);
                owned.claimChunk(geom.blockCells(), chunk);
                var block = owned.ownBlock(geom, chunk).?;
                block.fillFresh();
                block.finish();
                break;
            }
        }
        if (owned.ownBlock(geom, chunk)) |held| {
            var block = held;
            for (writes[0..count]) |write| block.write(write.local, write.tile);
            block.finish();
            owned.releaseIfUniform(chunk);
        }
        for (0..geom.chunkCount()) |index| {
            const each: u32 = @intCast(index);
            try std.testing.expectEqual(single.uniformTile(each), owned.uniformTile(each));
            const each_extent = geom.extent(each);
            for (0..each_extent.rows) |row| for (0..each_extent.cols) |col| {
                const x: u16 = @intCast(each_extent.min_x + col);
                const y: u16 = @intCast(each_extent.min_y + row);
                try std.testing.expectEqual(single.tile(geom, x, y), owned.tile(geom, x, y));
            };
        }
        try std.testing.expectEqual(single.liveBlockCount(), owned.liveBlockCount());
    }
}
