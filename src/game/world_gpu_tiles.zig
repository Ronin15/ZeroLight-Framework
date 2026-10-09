// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! World-side mirror of a world's renderer-owned GPU tile store
//! (`Renderer.createTileStore`). Only dense layers on levels in the render window
//! are resident, each in one directory slot. The mirror keeps each slot's directory
//! words as uploaded, the block-region allocator, and the cell edits queued on
//! resident layers since the last sync. A pan uploads nothing, one dig uploads one
//! element, and a layer entering the window uploads its directory and the blocks of
//! its mixed chunks. `plan` sizes and reserves a sync without changing anything a
//! retry depends on; `commit` then applies it and writes the upload batch without
//! allocating.

const std = @import("std");
const ChunkGeometry = @import("world_terrain.zig").ChunkGeometry;
const DenseLayerStore = @import("world_terrain.zig").DenseLayerStore;
const TileDataId = @import("../render/renderer.zig").TileDataId;
const TileStoreSpan = @import("../render/renderer.zig").TileStoreSpan;
const packTileData = @import("../render/renderer.zig").packTileData;
const packTileDataElement = @import("../render/renderer.zig").packTileDataElement;
const tile_data_pad_cell = @import("../render/renderer.zig").tile_data_pad_cell;
const tile_store_directory_slots = @import("../render/renderer.zig").tile_store_directory_slots;
const tile_store_uniform_bit = @import("../render/renderer.zig").tile_store_uniform_bit;
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const tileStoreUniformWord = @import("../render/renderer.zig").tileStoreUniformWord;

pub const slot_count: usize = tile_store_directory_slots;
/// `gpu_slot` of a dense layer that is not resident.
pub const no_slot: u8 = std.math.maxInt(u8);
const no_layer: u32 = std.math.maxInt(u32);

comptime {
    std.debug.assert(slot_count < no_slot);
}

/// Loud index-width check for a world whose levels have `chunk_count` chunks of
/// `chunk_edge` cells: a store holding every directory slot plus one block per
/// slot-chunk keeps every byte offset inside SDL's `u32` buffer size, so element
/// offsets fit `u32` and block indices stay below the uniform bit. O(1).
pub fn validateStoreWidth(chunk_count: u64, chunk_edge: u16) error{GpuTileStoreWidthOverflow}!void {
    const bytes_per_chunk: u64 = @sizeOf(u32) * slot_count * (1 + @as(u64, tileStoreBlockElements(chunk_edge)));
    const bytes = std.math.mul(u64, chunk_count, bytes_per_chunk) catch return error.GpuTileStoreWidthOverflow;
    if (bytes > std.math.maxInt(u32)) return error.GpuTileStoreWidthOverflow;
}

pub fn directoryElements(chunk_count: usize) u32 {
    return @intCast(slot_count * chunk_count);
}

/// One queued cell edit on a resident layer: element `element` of `chunk`'s block in
/// directory slot `slot`.
pub const PendingEdit = struct {
    slot: u8,
    chunk: u32,
    element: u32,
};

/// What one sync changes, sized before anything changes (`GpuTileMirror.plan`).
pub const SyncPlan = struct {
    evict: std.StaticBitSet(slot_count) = .empty,
    enter_slots: [slot_count]u8 = undefined,
    enter_layers: [slot_count]u32 = undefined,
    enter_count: usize = 0,
    span_count: usize = 0,
    value_count: usize = 0,
    /// Store elements the sync needs: the directories plus the block region's high water.
    required_elements: u32 = 0,

    pub fn isEmpty(self: *const SyncPlan) bool {
        return self.span_count == 0 and self.evict.count() == 0;
    }
};

const RegionKind = enum { directory, directory_word, block, block_element };

// One upload span before its values are written, and where they come from.
const Region = struct {
    dst: u32,
    count: u32,
    kind: RegionKind,
    slot: u8,
    chunk: u32,
    element: u32,
};

// How one queued chunk's GPU directory word and block must change to match the CPU.
const ChunkChange = enum { none, set_word, free_block, take_block, write_elements };

const PendingGroup = struct {
    slot: u8,
    chunk: u32,
    edits: []const PendingEdit,
};

// Runs of sorted pending edits sharing a slot and chunk.
const PendingGroups = struct {
    edits: []const PendingEdit,
    index: usize = 0,

    fn next(self: *PendingGroups) ?PendingGroup {
        if (self.index >= self.edits.len) return null;
        const first = self.edits[self.index];
        var end = self.index + 1;
        while (end < self.edits.len and self.edits[end].slot == first.slot and self.edits[end].chunk == first.chunk) end += 1;
        const group = PendingGroup{ .slot = first.slot, .chunk = first.chunk, .edits = self.edits[self.index..end] };
        self.index = end;
        return group;
    }
};

pub const GpuTileMirror = struct {
    /// The renderer-owned store; `.invalid` until the first sync with work creates it.
    store: TileDataId = .invalid,
    slot_layer: [slot_count]u32 = @splat(no_layer),
    // Each slot's directory words as uploaded; allocated the first time the slot is
    // used and kept for reuse.
    slot_dirs: [slot_count][]u32 = @splat(&.{}),
    // Block-region high water: every block index in use or free is below it.
    block_count: u32 = 0,
    // Released block indices; capacity always covers `block_count`.
    block_free: std.ArrayList(u32) = .empty,
    pending: std.ArrayList(PendingEdit) = .empty,
    /// Edits reserved by `reserveEdits` and not yet queued.
    pending_reserved: usize = 0,
    regions: std.ArrayList(Region) = .empty,
    /// The last commit's upload batch for `Renderer.queueTileStoreUploads`.
    spans: std.ArrayList(TileStoreSpan) = .empty,
    values: std.ArrayList(u32) = .empty,
    resident_bytes_reported: bool = false,

    pub fn deinit(self: *GpuTileMirror, allocator: std.mem.Allocator) void {
        for (self.slot_dirs) |dir| allocator.free(dir);
        self.block_free.deinit(allocator);
        self.pending.deinit(allocator);
        self.regions.deinit(allocator);
        self.spans.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn residentLayerCount(self: *const GpuTileMirror) usize {
        var count: usize = 0;
        for (self.slot_layer) |layer| count += @intFromBool(layer != no_layer);
        return count;
    }

    /// Store bytes in use: every directory slot plus the block region's high water.
    pub fn residentBytes(self: *const GpuTileMirror, geom: ChunkGeometry) u64 {
        const elements = @as(u64, directoryElements(geom.chunkCount())) +
            @as(u64, self.block_count) * tileStoreBlockElements(geom.edge);
        return elements * @sizeOf(u32);
    }

    /// Makes `count` later `ensureEdit` + `queueEdit` calls allocation-free; counted
    /// until used.
    pub fn reserveEdits(self: *GpuTileMirror, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!void {
        try self.pending.ensureTotalCapacity(allocator, self.pending.items.len + self.pending_reserved + count);
        self.pending_reserved += count;
    }

    /// Room for one more edit; allocation-free after `reserveEdits`.
    pub fn ensureEdit(self: *GpuTileMirror, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        try self.pending.ensureTotalCapacity(allocator, self.pending.items.len + 1);
    }

    /// Queues a cell edit on a resident layer; requires `ensureEdit`. Duplicates
    /// coalesce at the next sync.
    pub fn queueEdit(self: *GpuTileMirror, slot: u8, chunk: u32, element: u32) void {
        std.debug.assert(slot < slot_count and self.slot_layer[slot] != no_layer);
        self.pending_reserved -|= 1;
        self.pending.appendAssumeCapacity(.{ .slot = slot, .chunk = chunk, .element = element });
    }

    /// Sizes one sync and reserves every growth it needs. `desired_layers` (at most
    /// `slot_count`) is the resident set when the window or layer set changed, null
    /// otherwise. Changes nothing a retry depends on: it only sorts and coalesces the
    /// queue and grows capacity, so an OOM leaves residency and edits intact. Costs
    /// O(edits log edits), plus O(chunks) per layer entering or leaving the window.
    pub fn plan(
        self: *GpuTileMirror,
        allocator: std.mem.Allocator,
        geom: ChunkGeometry,
        stores: []const DenseLayerStore,
        layer_slots: []const u8,
        desired_layers: ?[]const u32,
    ) error{ OutOfMemory, GpuTileStoreWidthOverflow }!SyncPlan {
        var result = SyncPlan{};
        const chunk_count = geom.chunkCount();
        const block_elements = tileStoreBlockElements(geom.edge);
        var frees: usize = 0;
        var takes: usize = 0;

        if (desired_layers) |desired| {
            std.debug.assert(desired.len <= slot_count);
            for (self.slot_layer, 0..) |layer, slot| {
                if (layer == no_layer or std.mem.indexOfScalar(u32, desired, layer) != null) continue;
                result.evict.set(slot);
                frees += countBlocks(self.slot_dirs[slot]);
            }
            var free_slot: usize = 0;
            for (desired) |layer| {
                if (layer_slots[layer] != no_slot) continue;
                // Every kept slot holds a desired layer, so a free slot remains.
                while (self.slot_layer[free_slot] != no_layer and !result.evict.isSet(free_slot)) free_slot += 1;
                result.enter_slots[result.enter_count] = @intCast(free_slot);
                result.enter_layers[result.enter_count] = layer;
                result.enter_count += 1;
                free_slot += 1;
                var blocks: usize = 0;
                for (0..chunk_count) |chunk| blocks += @intFromBool(stores[layer].readUniformTile(@intCast(chunk)) == null);
                takes += blocks;
                result.span_count += 1 + blocks;
                result.value_count += chunk_count + blocks * block_elements;
            }
        }

        self.coalescePending();
        var groups = PendingGroups{ .edits = self.pending.items };
        while (groups.next()) |group| {
            if (result.evict.isSet(group.slot)) continue;
            switch (self.chunkChange(stores, group.slot, group.chunk)) {
                .none => {},
                .set_word => {
                    result.span_count += 1;
                    result.value_count += 1;
                },
                .free_block => {
                    frees += 1;
                    result.span_count += 1;
                    result.value_count += 1;
                },
                .take_block => {
                    takes += 1;
                    result.span_count += 2;
                    result.value_count += 1 + block_elements;
                },
                .write_elements => {
                    result.span_count += group.edits.len;
                    result.value_count += group.edits.len;
                },
            }
        }

        for (result.enter_slots[0..result.enter_count]) |slot| {
            if (self.slot_dirs[slot].len == 0) self.slot_dirs[slot] = try allocator.alloc(u32, chunk_count);
        }
        try self.block_free.ensureTotalCapacity(allocator, self.block_count + takes);
        try self.regions.ensureTotalCapacity(allocator, result.span_count);
        try self.spans.ensureTotalCapacity(allocator, result.span_count);
        try self.values.ensureTotalCapacity(allocator, result.value_count);
        // `commit` frees before it takes, so this sync's frees serve its takes.
        const new_blocks = takes -| (self.block_free.items.len + frees);
        const elements = @as(u64, directoryElements(chunk_count)) + (@as(u64, self.block_count) + new_blocks) * block_elements;
        result.required_elements = std.math.cast(u32, elements) orelse return error.GpuTileStoreWidthOverflow;
        return result;
    }

    /// Applies `sync_plan` (from `plan` with the same inputs, nothing changed since)
    /// and writes the upload batch into `spans`/`values`, sorted and disjoint.
    /// Allocation-free. Evictions free their blocks first, then queued chunks that
    /// returned to one tile free theirs, then chunks that split take blocks, then
    /// entering layers take theirs.
    pub fn commit(
        self: *GpuTileMirror,
        sync_plan: *const SyncPlan,
        geom: ChunkGeometry,
        stores: []const DenseLayerStore,
        layer_slots: []u8,
    ) void {
        self.regions.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        const chunk_count: u32 = @intCast(geom.chunkCount());
        const block_elements = tileStoreBlockElements(geom.edge);

        if (sync_plan.evict.count() > 0) {
            var evicted = sync_plan.evict.iterator(.{});
            while (evicted.next()) |slot| {
                for (self.slot_dirs[slot]) |word| {
                    if (word & tile_store_uniform_bit == 0) self.freeBlock(word);
                }
                layer_slots[self.slot_layer[slot]] = no_slot;
                self.slot_layer[slot] = no_layer;
            }
            var kept: usize = 0;
            for (self.pending.items) |edit| {
                if (sync_plan.evict.isSet(edit.slot)) continue;
                self.pending.items[kept] = edit;
                kept += 1;
            }
            self.pending.items.len = kept;
        }

        var groups = PendingGroups{ .edits = self.pending.items };
        while (groups.next()) |group| {
            const change = self.chunkChange(stores, group.slot, group.chunk);
            if (change != .set_word and change != .free_block) continue;
            const dir = self.slot_dirs[group.slot];
            if (change == .free_block) self.freeBlock(dir[group.chunk]);
            dir[group.chunk] = tileStoreUniformWord(stores[self.slot_layer[group.slot]].readUniformTile(group.chunk).?);
            self.appendRegion(.directory_word, group.slot, group.chunk, 0, chunk_count, block_elements);
        }
        groups = .{ .edits = self.pending.items };
        while (groups.next()) |group| {
            switch (self.chunkChange(stores, group.slot, group.chunk)) {
                .take_block => {
                    self.slot_dirs[group.slot][group.chunk] = self.takeBlock();
                    self.appendRegion(.directory_word, group.slot, group.chunk, 0, chunk_count, block_elements);
                    self.appendRegion(.block, group.slot, group.chunk, 0, chunk_count, block_elements);
                },
                .write_elements => for (group.edits) |edit| {
                    self.appendRegion(.block_element, group.slot, group.chunk, edit.element, chunk_count, block_elements);
                },
                .none, .set_word, .free_block => {},
            }
        }
        self.pending.clearRetainingCapacity();

        for (sync_plan.enter_slots[0..sync_plan.enter_count], sync_plan.enter_layers[0..sync_plan.enter_count]) |slot, layer| {
            self.slot_layer[slot] = layer;
            layer_slots[layer] = slot;
            const store = &stores[layer];
            for (self.slot_dirs[slot], 0..) |*word, chunk_index| {
                const chunk: u32 = @intCast(chunk_index);
                if (store.readUniformTile(chunk)) |tile| {
                    word.* = tileStoreUniformWord(tile);
                    continue;
                }
                word.* = self.takeBlock();
                self.appendRegion(.block, slot, chunk, 0, chunk_count, block_elements);
            }
            self.appendRegion(.directory, slot, 0, 0, chunk_count, block_elements);
        }

        std.mem.sortUnstable(Region, self.regions.items, {}, regionLessThan);
        const block_cells = geom.blockCells();
        for (self.regions.items) |region| {
            self.spans.appendAssumeCapacity(.{ .dst_element = region.dst, .count = region.count });
            switch (region.kind) {
                .directory => self.values.appendSliceAssumeCapacity(self.slot_dirs[region.slot]),
                .directory_word => self.values.appendAssumeCapacity(self.slot_dirs[region.slot][region.chunk]),
                .block => {
                    const cells = stores[self.slot_layer[region.slot]].chunkCells(block_cells, region.chunk).?;
                    packTileData(cells, self.values.addManyAsSliceAssumeCapacity(block_elements));
                },
                .block_element => {
                    const cells = stores[self.slot_layer[region.slot]].chunkCells(block_cells, region.chunk).?;
                    const low = region.element * 2;
                    const high = if (low + 1 < cells.len) cells[low + 1] else tile_data_pad_cell;
                    self.values.appendAssumeCapacity(packTileDataElement(cells[low], high));
                },
            }
        }
        std.debug.assert(self.spans.items.len == sync_plan.span_count and self.values.items.len == sync_plan.value_count);
    }

    fn chunkChange(self: *const GpuTileMirror, stores: []const DenseLayerStore, slot: u8, chunk: u32) ChunkChange {
        const have = self.slot_dirs[slot][chunk];
        const have_block = have & tile_store_uniform_bit == 0;
        if (stores[self.slot_layer[slot]].readUniformTile(chunk)) |tile| {
            if (have_block) return .free_block;
            return if (have == tileStoreUniformWord(tile)) .none else .set_word;
        }
        return if (have_block) .write_elements else .take_block;
    }

    // Sorts the queue by (slot, chunk, element) and drops repeats. Allocation-free.
    fn coalescePending(self: *GpuTileMirror) void {
        const edits = self.pending.items;
        std.mem.sortUnstable(PendingEdit, edits, {}, pendingLessThan);
        var kept: usize = 0;
        for (edits) |edit| {
            if (kept > 0 and std.meta.eql(edits[kept - 1], edit)) continue;
            edits[kept] = edit;
            kept += 1;
        }
        self.pending.items.len = kept;
    }

    fn appendRegion(self: *GpuTileMirror, kind: RegionKind, slot: u8, chunk: u32, element: u32, chunk_count: u32, block_elements: u32) void {
        const directory_base = @as(u32, slot) * chunk_count;
        const block_base = directoryElements(chunk_count);
        const region: Region = switch (kind) {
            .directory => .{ .dst = directory_base, .count = chunk_count, .kind = kind, .slot = slot, .chunk = 0, .element = 0 },
            .directory_word => .{ .dst = directory_base + chunk, .count = 1, .kind = kind, .slot = slot, .chunk = chunk, .element = 0 },
            .block, .block_element => blk: {
                const block = self.slot_dirs[slot][chunk];
                std.debug.assert(block & tile_store_uniform_bit == 0);
                const block_start = block_base + block * block_elements;
                break :blk if (kind == .block)
                    .{ .dst = block_start, .count = block_elements, .kind = kind, .slot = slot, .chunk = chunk, .element = 0 }
                else
                    .{ .dst = block_start + element, .count = 1, .kind = kind, .slot = slot, .chunk = chunk, .element = element };
            },
        };
        self.regions.appendAssumeCapacity(region);
    }

    fn takeBlock(self: *GpuTileMirror) u32 {
        if (self.block_free.pop()) |block| return block;
        const block = self.block_count;
        self.block_count += 1;
        std.debug.assert(self.block_free.capacity >= self.block_count);
        return block;
    }

    fn freeBlock(self: *GpuTileMirror, block: u32) void {
        std.debug.assert(block < self.block_count);
        std.debug.assert(self.block_free.items.len < self.block_free.capacity);
        self.block_free.appendAssumeCapacity(block);
    }
};

fn countBlocks(dir: []const u32) usize {
    var count: usize = 0;
    for (dir) |word| count += @intFromBool(word & tile_store_uniform_bit == 0);
    return count;
}

fn pendingLessThan(_: void, lhs: PendingEdit, rhs: PendingEdit) bool {
    if (lhs.slot != rhs.slot) return lhs.slot < rhs.slot;
    if (lhs.chunk != rhs.chunk) return lhs.chunk < rhs.chunk;
    return lhs.element < rhs.element;
}

fn regionLessThan(_: void, lhs: Region, rhs: Region) bool {
    return lhs.dst < rhs.dst;
}

// Two 2x2-chunk layers of 4-cell chunks (16-cell blocks, 8-element blocks).
const TestLayers = struct {
    geom: ChunkGeometry,
    stores: [2]DenseLayerStore,
    slots: [2]u8 = @splat(no_slot),

    const fill: u16 = 1;
    const dug: u16 = 7;

    fn init() !TestLayers {
        const geom = ChunkGeometry.init(8, 8, 4);
        var first = try DenseLayerStore.init(std.testing.allocator, geom.chunkCount(), fill);
        errdefer first.deinit(std.testing.allocator);
        const second = try DenseLayerStore.init(std.testing.allocator, geom.chunkCount(), fill);
        return .{ .geom = geom, .stores = .{ first, second } };
    }

    fn deinit(self: *TestLayers) void {
        for (&self.stores) |*store| store.deinit(std.testing.allocator);
    }

    fn write(self: *TestLayers, layer: usize, x: u16, y: u16, tile: u16) !void {
        const store = &self.stores[layer];
        _ = try store.ensureAvailable(std.testing.allocator, self.geom.blockCells(), 1);
        store.write(self.geom, self.geom.chunkOf(x, y), self.geom.localOf(x, y), tile);
    }

    // Writes a cell and queues its edit the way `WorldSystem` does for a resident layer.
    fn dig(self: *TestLayers, mirror: *GpuTileMirror, layer: usize, x: u16, y: u16, tile: u16) !void {
        try self.write(layer, x, y, tile);
        try mirror.ensureEdit(std.testing.allocator);
        mirror.queueEdit(self.slots[layer], self.geom.chunkOf(x, y), self.geom.localOf(x, y) / 2);
    }

    fn sync(self: *TestLayers, mirror: *GpuTileMirror, desired: ?[]const u32) !SyncPlan {
        const sync_plan = try mirror.plan(std.testing.allocator, self.geom, &self.stores, &self.slots, desired);
        mirror.commit(&sync_plan, self.geom, &self.stores, &self.slots);
        return sync_plan;
    }
};

test "a layer entering uploads its directory and mixed blocks; leaving frees its block slots" {
    var layers = try TestLayers.init();
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    // Layer 0: chunks 0 and 3 mixed, chunk 1 holding an early block of only fill.
    try layers.write(0, 0, 0, TestLayers.dug);
    try layers.write(0, 7, 7, TestLayers.dug);
    _ = try layers.stores[0].ensureAvailable(std.testing.allocator, layers.geom.blockCells(), 1);
    layers.stores[0].materializeChunk(layers.geom.blockCells(), 1);

    const entered = try layers.sync(&mirror, &.{0});
    try std.testing.expectEqual(@as(usize, 1), entered.enter_count);
    const slot = layers.slots[0];
    try std.testing.expect(slot != no_slot);
    // One directory span plus a block per mixed chunk; the early block reads as uniform.
    try std.testing.expectEqual(@as(usize, 3), mirror.spans.items.len);
    try std.testing.expectEqual(@as(u32, 2), mirror.block_count);
    const directory_start = @as(u32, slot) * 4;
    try std.testing.expectEqual(TileStoreSpan{ .dst_element = directory_start, .count = 4 }, mirror.spans.items[0]);
    try std.testing.expectEqual(tileStoreUniformWord(TestLayers.fill), mirror.values.items[1]);
    try std.testing.expectEqual(tileStoreUniformWord(TestLayers.fill), mirror.values.items[2]);
    try std.testing.expect(mirror.values.items[0] & tile_store_uniform_bit == 0);
    try std.testing.expect(mirror.values.items[3] & tile_store_uniform_bit == 0);
    try std.testing.expectEqual(directoryElements(4) + 2 * 8, entered.required_elements);

    // Layer 1 replaces it: both block slots return to the free list and a queued edit
    // on the leaving layer is dropped.
    try layers.dig(&mirror, 0, 1, 0, TestLayers.dug);
    const swapped = try layers.sync(&mirror, &.{1});
    try std.testing.expectEqual(@as(usize, 1), swapped.evict.count());
    try std.testing.expectEqual(no_slot, layers.slots[0]);
    try std.testing.expect(layers.slots[1] != no_slot);
    try std.testing.expectEqual(@as(usize, 2), mirror.block_free.items.len);
    try std.testing.expectEqual(@as(usize, 0), mirror.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), mirror.spans.items.len);

    // Nothing queued and no window change: an empty sync.
    try std.testing.expect((try layers.sync(&mirror, null)).isEmpty());
}

test "edits coalesce to one element upload per element, valued from the store" {
    var layers = try TestLayers.init();
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    try layers.write(0, 0, 0, TestLayers.dug);
    _ = try layers.sync(&mirror, &.{0});
    const block = mirror.slot_dirs[layers.slots[0]][0];

    // Cells 0 and 1 share element 0; cell 5 is element 2; repeats coalesce.
    try layers.dig(&mirror, 0, 1, 0, TestLayers.dug);
    try layers.dig(&mirror, 0, 0, 0, TestLayers.fill);
    try layers.dig(&mirror, 0, 1, 0, 9);
    try layers.dig(&mirror, 0, 1, 1, TestLayers.dug);
    try layers.dig(&mirror, 0, 1, 1, TestLayers.dug);
    const sync_plan = try layers.sync(&mirror, null);
    const block_start = directoryElements(4) + block * 8;
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = block_start, .count = 1 },
        .{ .dst_element = block_start + 2, .count = 1 },
    }, mirror.spans.items);
    try std.testing.expectEqualSlices(u32, &.{
        packTileDataElement(TestLayers.fill, 9),
        packTileDataElement(TestLayers.fill, TestLayers.dug),
    }, mirror.values.items);
    try std.testing.expectEqual(@as(usize, 2), sync_plan.span_count);
}

test "a chunk that splits takes a block slot and uploads it; one that returns to one tile frees it" {
    var layers = try TestLayers.init();
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    _ = try layers.sync(&mirror, &.{0});
    const slot = layers.slots[0];
    try std.testing.expectEqual(@as(u32, 0), mirror.block_count);

    // Split chunk 2: its directory word and whole block upload; the element edit is
    // inside the block upload.
    try layers.dig(&mirror, 0, 1, 5, TestLayers.dug);
    _ = try layers.sync(&mirror, null);
    try std.testing.expectEqual(@as(u32, 1), mirror.block_count);
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = @as(u32, slot) * 4 + 2, .count = 1 },
        .{ .dst_element = directoryElements(4), .count = 8 },
    }, mirror.spans.items);
    try std.testing.expectEqual(@as(u32, 0), mirror.values.items[0]);
    var expected_block: [8]u32 = undefined;
    packTileData(layers.stores[0].chunkCells(16, 2).?, &expected_block);
    try std.testing.expectEqualSlices(u32, &expected_block, mirror.values.items[1..]);

    // Back to the fill: the directory word turns uniform and the slot is freed for reuse.
    try layers.dig(&mirror, 0, 1, 5, TestLayers.fill);
    _ = try layers.sync(&mirror, null);
    try std.testing.expectEqualSlices(TileStoreSpan, &.{.{ .dst_element = @as(u32, slot) * 4 + 2, .count = 1 }}, mirror.spans.items);
    try std.testing.expectEqualSlices(u32, &.{tileStoreUniformWord(TestLayers.fill)}, mirror.values.items);
    try std.testing.expectEqualSlices(u32, &.{0}, mirror.block_free.items);

    // A split and a return in one sync: the freed slot serves the split, so the block
    // region does not grow.
    try layers.dig(&mirror, 0, 6, 6, TestLayers.dug);
    _ = try layers.sync(&mirror, null);
    try layers.dig(&mirror, 0, 6, 6, TestLayers.fill);
    try layers.dig(&mirror, 0, 0, 0, TestLayers.dug);
    const sync_plan = try layers.sync(&mirror, null);
    try std.testing.expectEqual(@as(u32, 1), mirror.block_count);
    try std.testing.expectEqual(directoryElements(4) + 8, sync_plan.required_elements);
}

test "the block region's required size grows with the high water and reuses freed slots" {
    var layers = try TestLayers.init();
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    const directory = directoryElements(4);
    try std.testing.expectEqual(directory, (try layers.sync(&mirror, &.{ 0, 1 })).required_elements);
    // Four splits across two layers in one sync: four new blocks.
    try layers.dig(&mirror, 0, 0, 0, TestLayers.dug);
    try layers.dig(&mirror, 0, 4, 0, TestLayers.dug);
    try layers.dig(&mirror, 1, 0, 4, TestLayers.dug);
    try layers.dig(&mirror, 1, 4, 4, TestLayers.dug);
    try std.testing.expectEqual(directory + 4 * 8, (try layers.sync(&mirror, null)).required_elements);
    // Two return to one tile while two others split: no growth.
    try layers.dig(&mirror, 0, 0, 0, TestLayers.fill);
    try layers.dig(&mirror, 1, 0, 4, TestLayers.fill);
    try layers.dig(&mirror, 0, 0, 4, TestLayers.dug);
    try layers.dig(&mirror, 1, 4, 0, TestLayers.dug);
    try std.testing.expectEqual(directory + 4 * 8, (try layers.sync(&mirror, null)).required_elements);
    try std.testing.expectEqual(@as(u32, 4), mirror.block_count);
    // One more split than slots free: one new block.
    try layers.dig(&mirror, 0, 4, 4, TestLayers.dug);
    try std.testing.expectEqual(directory + 5 * 8, (try layers.sync(&mirror, null)).required_elements);
}

test "an out-of-memory plan leaves residency and queued edits intact for a retry (FailingAllocator)" {
    var layers = try TestLayers.init();
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    _ = try layers.sync(&mirror, &.{0});
    try layers.dig(&mirror, 0, 0, 0, TestLayers.dug);
    try layers.dig(&mirror, 0, 0, 0, TestLayers.dug);
    try layers.write(1, 5, 5, TestLayers.dug);

    // Fail each allocation of a sync that splits a chunk and enters layer 1 in turn.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        const result = mirror.plan(failing.allocator(), layers.geom, &layers.stores, &layers.slots, &.{ 0, 1 });
        if (result) |sync_plan| {
            mirror.commit(&sync_plan, layers.geom, &layers.stores, &layers.slots);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(no_slot, layers.slots[1]);
            try std.testing.expectEqual(@as(usize, 1), mirror.residentLayerCount());
            try std.testing.expectEqual(@as(usize, 1), mirror.pending.items.len);
            try std.testing.expectEqual(@as(u32, 0), mirror.block_count);
        }
    }
    try std.testing.expect(fail_index > 0);
    try std.testing.expect(layers.slots[1] != no_slot);
    try std.testing.expectEqual(@as(u32, 2), mirror.block_count);
    try std.testing.expectEqual(@as(usize, 0), mirror.pending.items.len);
}

test "a reserved edit queues without allocating (FailingAllocator)" {
    var layers = try TestLayers.init();
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    _ = try layers.sync(&mirror, &.{0});
    for (0..3) |_| try mirror.reserveEdits(std.testing.allocator, 1);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    for (0..3) |index| {
        try mirror.ensureEdit(failing.allocator());
        mirror.queueEdit(layers.slots[0], @intCast(index), 0);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 3), mirror.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), mirror.pending_reserved);
}

test "the store width check fails at its boundary" {
    // 16-cell chunks: 4 B x 32 slots x (1 + 128) words = 16512 B per chunk.
    try validateStoreWidth(260_111, 16);
    try std.testing.expectError(error.GpuTileStoreWidthOverflow, validateStoreWidth(260_112, 16));
    // 1-cell chunks: one-word blocks, 256 B per chunk.
    try validateStoreWidth(16_777_215, 1);
    try std.testing.expectError(error.GpuTileStoreWidthOverflow, validateStoreWidth(16_777_216, 1));
    try std.testing.expectError(error.GpuTileStoreWidthOverflow, validateStoreWidth(std.math.maxInt(u64), 16));
}
