// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! World-side mirror of a world's renderer-owned GPU tile store
//! (`Renderer.createTileStore`). Only the render window is resident: the dense
//! layers of its levels, each one directory of `side * side` toroidal chunk words
//! plus a link word chaining it to the next deeper resident layer, and a block per
//! mixed chunk inside the chunk window. Directories and blocks are two allocation
//! classes over one bump high water with a free list each. The mirror keeps each
//! resident layer's directory words as uploaded, the allocator, and the cell edits
//! queued on resident layers since the last sync. A pan across a chunk boundary
//! uploads the entering chunks, a dig one element, and a layer entering the window
//! its directory and the blocks of its mixed window chunks. `plan` sizes and
//! reserves a sync without changing anything a retry depends on; `commit` then
//! applies it and writes the upload batch without allocating.

const std = @import("std");
const ChunkGeometry = @import("world_terrain.zig").ChunkGeometry;
const DenseLayerStore = @import("world_terrain.zig").DenseLayerStore;
const TileDataId = @import("../render/renderer.zig").TileDataId;
const TileStoreSpan = @import("../render/renderer.zig").TileStoreSpan;
const packTileData = @import("../render/renderer.zig").packTileData;
const packTileDataElement = @import("../render/renderer.zig").packTileDataElement;
const tile_data_pad_cell = @import("../render/renderer.zig").tile_data_pad_cell;
const tile_store_max_elements = @import("../render/renderer.zig").tile_store_max_elements;
const tile_store_max_side = @import("../render/renderer.zig").tile_store_max_side;
const tile_store_no_link = @import("../render/renderer.zig").tile_store_no_link;
const tile_store_uniform_bit = @import("../render/renderer.zig").tile_store_uniform_bit;
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const tileStoreUniformWord = @import("../render/renderer.zig").tileStoreUniformWord;

/// `gpu_slot` of a dense layer that is not resident.
pub const no_slot: u32 = std.math.maxInt(u32);
const no_layer: u32 = std.math.maxInt(u32);
// Directory words of toroidal cells no window chunk maps to; never read.
const unused_word: u32 = tileStoreUniformWord(tile_data_pad_cell);

/// A rectangle of chunks, max exclusive. Empty when no chunk is inside.
pub const ChunkWindow = struct {
    min_x: u32 = 0,
    min_y: u32 = 0,
    max_x: u32 = 0,
    max_y: u32 = 0,

    pub fn contains(self: ChunkWindow, chunk_x: u32, chunk_y: u32) bool {
        return chunk_x >= self.min_x and chunk_x < self.max_x and chunk_y >= self.min_y and chunk_y < self.max_y;
    }

    pub fn width(self: ChunkWindow) u32 {
        return self.max_x -| self.min_x;
    }

    pub fn height(self: ChunkWindow) u32 {
        return self.max_y -| self.min_y;
    }

    pub fn count(self: ChunkWindow) usize {
        return @as(usize, self.width()) * self.height();
    }

    pub fn eql(self: ChunkWindow, other: ChunkWindow) bool {
        return std.meta.eql(self, other);
    }

    /// The renderer's per-draw window uniform (`TilemapParams.window`).
    pub fn uniform(self: ChunkWindow) [4]u32 {
        return .{ self.min_x, self.min_y, self.max_x, self.max_y };
    }
};

/// The resident set a sync moves to: `layers` topmost first, each holding the
/// chunks of `window` in a directory of `side * side` words. `side` is a power of
/// two up to `tile_store_max_side`, `window` fits within it on both axes (`fitWindow`),
/// and `layers` within `residentLayerFit`.
pub const Residency = struct {
    layers: []const u32,
    window: ChunkWindow,
    side: u32,
};

/// Words of one directory: the toroidal chunk words plus the link word. `side` is
/// at most `tile_store_max_side`, so this fits `u32`.
pub fn directoryWords(side: u32) u32 {
    std.debug.assert(side <= tile_store_max_side);
    return side * side + 1;
}

/// The side and window a sync can hold for a chunk window: at least `side` and the
/// window's own extent rounded up to a power of two, capped at
/// `tile_store_max_side`, with the window clipped from its min corner to fit. Keeps
/// every resident chunk on its own toroidal word in any build. O(1).
pub fn fitWindow(side: u32, window: ChunkWindow) struct { side: u32, window: ChunkWindow } {
    const extent = @max(1, @max(window.width(), window.height()));
    const needed = @max(side, std.math.ceilPowerOfTwo(u32, extent) catch tile_store_max_side);
    const fitted = @min(needed, tile_store_max_side);
    var clipped = window;
    clipped.max_x = window.min_x + @min(window.width(), fitted);
    clipped.max_y = window.min_y + @min(window.height(), fitted);
    return .{ .side = fitted, .window = clipped };
}

/// Most layers whose directories and a block per window chunk fit the store's `u32`
/// element width at `side`, so every element offset and the store's byte size fit.
/// O(1).
pub fn residentLayerFit(side: u32, block_elements: u32) usize {
    const cells = @as(u64, side) * side;
    const per_layer = cells + 1 + cells * block_elements;
    return @intCast(@as(u64, tile_store_max_elements) / per_layer);
}

/// One queued cell edit on a resident layer: element `element` of `chunk`'s block in
/// the directory of resident slot `slot`.
pub const PendingEdit = struct {
    slot: u32,
    chunk: u32,
    element: u32,
};

/// What one sync changes, sized before anything changes (`GpuTileMirror.plan`).
pub const SyncPlan = struct {
    /// The sync moved the resident set (layers, window, or side).
    residency_changed: bool = false,
    /// The directory side changed or no layout existed: the store is laid out anew
    /// from an empty allocator.
    relayout: bool = false,
    /// A layer entered or left, so the chain or a directory start changed.
    layers_changed: bool = false,
    side: u32 = 0,
    window: ChunkWindow = .{},
    enter_count: usize = 0,
    evict_count: usize = 0,
    span_count: usize = 0,
    value_count: usize = 0,
    /// Store elements the sync needs: the allocator's high water after it.
    required_elements: u32 = 0,
};

const RegionKind = enum { directory, directory_word, link, block, block_element };

// One upload span before its values are written, and where they come from.
const Region = struct {
    dst: u32,
    count: u32,
    kind: RegionKind,
    slot: u32,
    // Toroidal word for `directory_word`; level chunk for `block` and `block_element`.
    index: u32,
    element: u32 = 0,
};

// How one queued chunk's GPU directory word and block must change to match the CPU.
const ChunkChange = enum { none, set_word, free_block, take_block, write_elements };

const PendingGroup = struct {
    slot: u32,
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
    /// The renderer-owned store; `.invalid` until the first sync with uploads creates it.
    store: TileDataId = .invalid,
    /// Directory side `store` was created with; a sync at another side needs a new store.
    store_side: u32 = 0,
    /// Directory side of the current layout; 0 before the first layout.
    side: u32 = 0,
    /// The resident chunk window.
    window: ChunkWindow = .{},
    // Per slot: its layer (`no_layer` when free), directory start, and directory
    // words as uploaded (`directoryWords(side)` per slot, link last).
    slot_layer: std.ArrayList(u32) = .empty,
    slot_dir: std.ArrayList(u32) = .empty,
    slot_words: std.ArrayList(u32) = .empty,
    slot_free: std.ArrayList(u32) = .empty,
    /// Resident slots, topmost layer first: the chain order.
    order: std.ArrayList(u32) = .empty,
    // Bump allocator over store elements; freed regions return to their class's list.
    high_water: u32 = 0,
    block_free: std.ArrayList(u32) = .empty,
    dir_free: std.ArrayList(u32) = .empty,
    // Plan scratch read by the matching commit: slots leaving, layers entering, the
    // new chain order by layer, and per slot whether it stays resident.
    plan_evict: std.ArrayList(u32) = .empty,
    plan_enter: std.ArrayList(u32) = .empty,
    plan_order: std.ArrayList(u32) = .empty,
    plan_stays: std.ArrayList(bool) = .empty,
    pending: std.ArrayList(PendingEdit) = .empty,
    /// Edits reserved by `reserveEdits` and not yet queued.
    pending_reserved: usize = 0,
    regions: std.ArrayList(Region) = .empty,
    /// The last commit's upload batch for `Renderer.queueTileStoreUploads`.
    spans: std.ArrayList(TileStoreSpan) = .empty,
    values: std.ArrayList(u32) = .empty,
    resident_bytes_reported: bool = false,
    width_drop_reported: bool = false,
    window_clip_reported: bool = false,

    pub fn deinit(self: *GpuTileMirror, allocator: std.mem.Allocator) void {
        self.slot_layer.deinit(allocator);
        self.slot_dir.deinit(allocator);
        self.slot_words.deinit(allocator);
        self.slot_free.deinit(allocator);
        self.order.deinit(allocator);
        self.block_free.deinit(allocator);
        self.dir_free.deinit(allocator);
        self.plan_evict.deinit(allocator);
        self.plan_enter.deinit(allocator);
        self.plan_order.deinit(allocator);
        self.plan_stays.deinit(allocator);
        self.pending.deinit(allocator);
        self.regions.deinit(allocator);
        self.spans.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    /// Forgets the store after the renderer retired it: no layer resident (each
    /// resident layer's entry in `layer_slots` back to `no_slot`), no layout, an
    /// empty allocator, and no queued edits; keeps every capacity for the next
    /// store. O(resident layers).
    pub fn reset(self: *GpuTileMirror, layer_slots: []u32) void {
        self.dropLayout(layer_slots);
        self.store = .invalid;
        self.store_side = 0;
        self.side = 0;
        self.window = .{};
        self.pending.clearRetainingCapacity();
        self.regions.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
    }

    /// Whether the layout describes `store`'s contents: false once a store was
    /// created for a sync that never committed, so the next sync lays out anew.
    pub fn layoutMatchesStore(self: *const GpuTileMirror) bool {
        return !self.store.isValid() or self.store_side == self.side;
    }

    pub fn residentLayerCount(self: *const GpuTileMirror) usize {
        return self.order.items.len;
    }

    /// Store bytes in use: the allocator's high water.
    pub fn residentBytes(self: *const GpuTileMirror) u64 {
        return @as(u64, self.high_water) * @sizeOf(u32);
    }

    /// Directory start of resident `slot`.
    pub fn slotDirectory(self: *const GpuTileMirror, slot: u32) u32 {
        return self.slot_dir.items[slot];
    }

    /// Resident `slot`'s directory words as uploaded, link word last.
    pub fn slotWords(self: *const GpuTileMirror, slot: u32) []const u32 {
        const stride = directoryWords(self.side);
        return self.slot_words.items[@as(usize, slot) * stride ..][0..stride];
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
    /// coalesce, and edits outside the window drop, at the next sync.
    pub fn queueEdit(self: *GpuTileMirror, slot: u32, chunk: u32, element: u32) void {
        std.debug.assert(slot < self.slot_layer.items.len and self.slot_layer.items[slot] != no_layer);
        self.pending_reserved -|= 1;
        self.pending.appendAssumeCapacity(.{ .slot = slot, .chunk = chunk, .element = element });
    }

    /// Sizes one sync and reserves every growth it needs. `desired` is the resident
    /// set when the layers, window, or side may have changed, null otherwise.
    /// Changes nothing a retry depends on: it only sorts and coalesces the queue and
    /// fills plan scratch, so an OOM leaves residency, window, and edits intact.
    /// Costs O(resident layers × window chunks) when `desired` is set, plus
    /// O(edits log edits); never depends on chunks outside the window.
    pub fn plan(
        self: *GpuTileMirror,
        allocator: std.mem.Allocator,
        geom: ChunkGeometry,
        stores: []const DenseLayerStore,
        layer_slots: []const u32,
        desired: ?Residency,
    ) error{OutOfMemory}!SyncPlan {
        const block_elements = tileStoreBlockElements(geom.edge);
        var result = SyncPlan{ .side = self.side, .window = self.window };
        var dir_frees: usize = 0;
        var dir_takes: usize = 0;
        var block_frees: usize = 0;
        var block_takes: usize = 0;

        self.plan_evict.clearRetainingCapacity();
        self.plan_enter.clearRetainingCapacity();
        self.plan_order.clearRetainingCapacity();
        try self.plan_stays.resize(allocator, self.slot_layer.items.len);
        const stays = self.plan_stays.items;
        if (desired) |d| {
            std.debug.assert(d.side >= 1 and std.math.isPowerOfTwo(d.side));
            std.debug.assert(d.window.width() <= d.side and d.window.height() <= d.side);
            std.debug.assert(d.layers.len <= residentLayerFit(d.side, block_elements));
            result.residency_changed = true;
            result.relayout = d.side != self.side or !self.layoutMatchesStore();
            result.side = d.side;
            result.window = d.window;
            try self.plan_evict.ensureTotalCapacity(allocator, self.order.items.len);
            try self.plan_enter.ensureTotalCapacity(allocator, d.layers.len);
            try self.plan_order.ensureTotalCapacity(allocator, d.layers.len);
            self.plan_order.appendSliceAssumeCapacity(d.layers);
            @memset(stays, false);
            for (d.layers) |layer| {
                const slot = layer_slots[layer];
                if (!result.relayout and slot != no_slot) {
                    stays[slot] = true;
                } else {
                    self.plan_enter.appendAssumeCapacity(layer);
                }
            }
            for (self.order.items) |slot| {
                if (stays[slot]) continue;
                self.plan_evict.appendAssumeCapacity(slot);
                if (result.relayout) continue;
                dir_frees += 1;
                block_frees += self.countBlocks(geom, slot, self.window, .{});
            }

            const entering_values = directoryWords(d.side);
            for (self.plan_enter.items) |layer| {
                dir_takes += 1;
                result.span_count += 1;
                result.value_count += entering_values;
                const mixed = countMixed(geom, &stores[layer], d.window, .{});
                block_takes += mixed;
                result.span_count += mixed;
                result.value_count += mixed * block_elements;
            }

            if (!result.relayout) {
                for (self.order.items) |slot| {
                    if (!stays[slot]) continue;
                    // Chunks leaving free their blocks; chunks entering upload their word
                    // and, when mixed, take and upload a block.
                    block_frees += self.countBlocks(geom, slot, self.window, d.window);
                    const store = &stores[self.slot_layer.items[slot]];
                    const entering = d.window.count() - overlap(d.window, self.window);
                    const mixed = countMixed(geom, store, d.window, self.window);
                    block_takes += mixed;
                    result.span_count += entering + mixed;
                    result.value_count += entering + mixed * block_elements;
                }
                // A staying layer whose next deeper layer changed rewrites its link.
                for (d.layers, 0..) |layer, index| {
                    const slot = layer_slots[layer];
                    if (slot == no_slot or !stays[slot]) continue;
                    if (self.linkChanges(layer_slots, slot, if (index + 1 < d.layers.len) d.layers[index + 1] else no_layer)) {
                        result.span_count += 1;
                        result.value_count += 1;
                    }
                }
            }
            result.enter_count = self.plan_enter.items.len;
            result.evict_count = self.plan_evict.items.len;
            result.layers_changed = result.relayout or result.enter_count > 0 or result.evict_count > 0;
        } else {
            @memset(stays, false);
            for (self.order.items) |slot| stays[slot] = true;
        }

        self.coalescePending();
        var groups = PendingGroups{ .edits = self.pending.items };
        while (groups.next()) |group| {
            if (!self.editLive(geom, group, result.window)) continue;
            switch (self.chunkChange(geom, stores, group.slot, group.chunk)) {
                .none => {},
                .set_word => {
                    result.span_count += 1;
                    result.value_count += 1;
                },
                .free_block => {
                    block_frees += 1;
                    result.span_count += 1;
                    result.value_count += 1;
                },
                .take_block => {
                    block_takes += 1;
                    result.span_count += 2;
                    result.value_count += 1 + block_elements;
                },
                .write_elements => {
                    result.span_count += group.edits.len;
                    result.value_count += group.edits.len;
                },
            }
        }

        // Slots: a relayout numbers them afresh; otherwise entering layers reuse
        // free and evicted slots before appending.
        const slot_count = if (result.relayout)
            result.enter_count
        else
            self.slot_layer.items.len + (result.enter_count -| (self.slot_free.items.len + result.evict_count));
        try self.slot_layer.ensureTotalCapacity(allocator, slot_count);
        try self.slot_dir.ensureTotalCapacity(allocator, slot_count);
        try self.slot_free.ensureTotalCapacity(allocator, slot_count);
        try self.slot_words.ensureTotalCapacity(allocator, slot_count * @as(usize, directoryWords(result.side)));
        try self.order.ensureTotalCapacity(allocator, self.plan_order.items.len);
        // Frees precede takes, so a free list holds at most its length plus this
        // sync's frees; a relayout starts both lists empty.
        const dir_free_len = if (result.relayout) 0 else self.dir_free.items.len;
        const block_free_len = if (result.relayout) 0 else self.block_free.items.len;
        try self.dir_free.ensureTotalCapacity(allocator, dir_free_len + dir_frees);
        try self.block_free.ensureTotalCapacity(allocator, block_free_len + block_frees);
        try self.regions.ensureTotalCapacity(allocator, result.span_count);
        try self.spans.ensureTotalCapacity(allocator, result.span_count);
        try self.values.ensureTotalCapacity(allocator, result.value_count);

        const base: u64 = if (result.relayout) 0 else self.high_water;
        const new_dirs = dir_takes -| (dir_free_len + dir_frees);
        const new_blocks = block_takes -| (block_free_len + block_frees);
        const required = base + @as(u64, new_dirs) * directoryWords(result.side) + @as(u64, new_blocks) * block_elements;
        // `residentLayerFit` bounds the live directories and blocks, and each class's
        // bumps never exceed its peak live count.
        std.debug.assert(required <= tile_store_max_elements);
        result.required_elements = @intCast(required);
        return result;
    }

    /// Applies `sync_plan` (from `plan` with the same inputs, nothing changed since)
    /// and writes the upload batch into `spans`/`values`, sorted and disjoint, each
    /// span a whole directory, one word, one link, one block, or one block element.
    /// Allocation-free. Frees come first (evictions, chunks leaving, edits), then
    /// takes (edits, chunks entering, layers entering), then links.
    pub fn commit(
        self: *GpuTileMirror,
        sync_plan: *const SyncPlan,
        geom: ChunkGeometry,
        stores: []const DenseLayerStore,
        layer_slots: []u32,
    ) void {
        self.regions.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        const block_elements = tileStoreBlockElements(geom.edge);
        const stays = self.plan_stays.items;
        const old_window = self.window;
        const new_window = sync_plan.window;

        if (sync_plan.relayout) {
            self.dropLayout(layer_slots);
            self.pending.clearRetainingCapacity();
            self.side = sync_plan.side;
        } else if (sync_plan.residency_changed) {
            for (self.plan_evict.items) |slot| {
                self.freeBlocks(geom, slot, old_window, .{});
                self.freeDirectory(self.slot_dir.items[slot]);
                layer_slots[self.slot_layer.items[slot]] = no_slot;
                self.slot_layer.items[slot] = no_layer;
                std.debug.assert(self.slot_free.items.len < self.slot_free.capacity);
                self.slot_free.appendAssumeCapacity(slot);
            }
            for (self.order.items) |slot| {
                if (stays[slot]) self.freeBlocks(geom, slot, old_window, new_window);
            }
        }

        // Only edits on chunks resident before and after stay queued; the rest
        // upload whole when their chunk or layer enters.
        var kept: usize = 0;
        for (self.pending.items) |edit| {
            if (!self.editLive(geom, .{ .slot = edit.slot, .chunk = edit.chunk, .edits = &.{} }, new_window)) continue;
            self.pending.items[kept] = edit;
            kept += 1;
        }
        self.pending.items.len = kept;

        var groups = PendingGroups{ .edits = self.pending.items };
        while (groups.next()) |group| {
            const change = self.chunkChange(geom, stores, group.slot, group.chunk);
            if (change != .set_word and change != .free_block) continue;
            const word = self.toroidalIndex(geom, group.chunk);
            const words = self.slotWordsMut(group.slot);
            if (change == .free_block) self.freeBlock(words[word]);
            words[word] = tileStoreUniformWord(stores[self.slot_layer.items[group.slot]].readUniformTile(group.chunk).?);
            self.appendRegion(.directory_word, group.slot, word, 1);
        }
        groups = .{ .edits = self.pending.items };
        while (groups.next()) |group| {
            switch (self.chunkChange(geom, stores, group.slot, group.chunk)) {
                .take_block => {
                    const word = self.toroidalIndex(geom, group.chunk);
                    self.slotWordsMut(group.slot)[word] = self.takeBlock(block_elements);
                    self.appendRegion(.directory_word, group.slot, word, 1);
                    self.appendBlockRegion(group.slot, group.chunk, word, block_elements);
                },
                .write_elements => {
                    const block = self.slotWords(group.slot)[self.toroidalIndex(geom, group.chunk)];
                    for (group.edits) |edit| {
                        self.regions.appendAssumeCapacity(.{ .dst = block + edit.element, .count = 1, .kind = .block_element, .slot = group.slot, .index = group.chunk, .element = edit.element });
                    }
                },
                .none, .set_word, .free_block => {},
            }
        }
        self.pending.clearRetainingCapacity();

        if (sync_plan.residency_changed) {
            if (!sync_plan.relayout) {
                for (self.order.items) |slot| {
                    if (stays[slot]) self.enterChunks(geom, stores, slot, new_window, old_window, block_elements, true);
                }
            }
            const stride = directoryWords(self.side);
            for (self.plan_enter.items) |layer| {
                const slot = if (self.slot_free.pop()) |free| free else blk: {
                    const appended: u32 = @intCast(self.slot_layer.items.len);
                    self.slot_layer.appendAssumeCapacity(no_layer);
                    self.slot_dir.appendAssumeCapacity(0);
                    _ = self.slot_words.addManyAsSliceAssumeCapacity(stride);
                    break :blk appended;
                };
                self.slot_layer.items[slot] = layer;
                self.slot_dir.items[slot] = self.takeDirectory(stride);
                layer_slots[layer] = slot;
                @memset(self.slotWordsMut(slot), unused_word);
                self.enterChunks(geom, stores, slot, new_window, .{}, block_elements, false);
                self.appendRegion(.directory, slot, 0, stride);
            }

            self.order.clearRetainingCapacity();
            for (self.plan_order.items) |layer| self.order.appendAssumeCapacity(layer_slots[layer]);
            for (self.order.items, 0..) |slot, index| {
                const next_layer = if (index + 1 < self.order.items.len) self.slot_layer.items[self.order.items[index + 1]] else no_layer;
                const staying = slot < stays.len and stays[slot] and !sync_plan.relayout;
                if (staying and !self.linkChanges(layer_slots, slot, next_layer)) continue;
                self.slotWordsMut(slot)[self.side * self.side] = if (next_layer == no_layer) tile_store_no_link else self.slot_dir.items[layer_slots[next_layer]];
                if (staying) self.appendRegion(.link, slot, self.side * self.side, 1);
            }
            self.window = new_window;
        }

        std.mem.sortUnstable(Region, self.regions.items, {}, regionLessThan);
        const block_cells = geom.blockCells();
        for (self.regions.items) |region| {
            self.spans.appendAssumeCapacity(.{ .dst_element = region.dst, .count = region.count });
            switch (region.kind) {
                .directory => self.values.appendSliceAssumeCapacity(self.slotWords(region.slot)),
                .directory_word, .link => self.values.appendAssumeCapacity(self.slotWords(region.slot)[region.index]),
                .block => {
                    const cells = stores[self.slot_layer.items[region.slot]].chunkCells(block_cells, region.index).?;
                    packTileData(cells, self.values.addManyAsSliceAssumeCapacity(block_elements));
                },
                .block_element => {
                    const cells = stores[self.slot_layer.items[region.slot]].chunkCells(block_cells, region.index).?;
                    const low = region.element * 2;
                    const high = if (low + 1 < cells.len) cells[low + 1] else tile_data_pad_cell;
                    self.values.appendAssumeCapacity(packTileDataElement(cells[low], high));
                },
            }
        }
        std.debug.assert(self.spans.items.len == sync_plan.span_count and self.values.items.len == sync_plan.value_count);
    }

    // Drops every slot and the allocator, keeping capacity.
    fn dropLayout(self: *GpuTileMirror, layer_slots: []u32) void {
        for (self.order.items) |slot| layer_slots[self.slot_layer.items[slot]] = no_slot;
        self.slot_layer.clearRetainingCapacity();
        self.slot_dir.clearRetainingCapacity();
        self.slot_words.clearRetainingCapacity();
        self.slot_free.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.block_free.clearRetainingCapacity();
        self.dir_free.clearRetainingCapacity();
        self.high_water = 0;
    }

    // Writes the directory words of `slot`'s chunks in `window` but not in `skip`,
    // taking a block for each mixed one; regions per word only for a staying layer
    // (an entering layer uploads its directory whole).
    fn enterChunks(
        self: *GpuTileMirror,
        geom: ChunkGeometry,
        stores: []const DenseLayerStore,
        slot: u32,
        window: ChunkWindow,
        skip: ChunkWindow,
        block_elements: u32,
        word_regions: bool,
    ) void {
        const store = &stores[self.slot_layer.items[slot]];
        var chunk_y = window.min_y;
        while (chunk_y < window.max_y) : (chunk_y += 1) {
            var chunk_x = window.min_x;
            while (chunk_x < window.max_x) : (chunk_x += 1) {
                if (skip.contains(chunk_x, chunk_y)) continue;
                const chunk = chunk_y * geom.chunks_x + chunk_x;
                const word = self.toroidalWord(chunk_x, chunk_y);
                if (store.readUniformTile(chunk)) |tile| {
                    self.slotWordsMut(slot)[word] = tileStoreUniformWord(tile);
                } else {
                    self.slotWordsMut(slot)[word] = self.takeBlock(block_elements);
                    self.appendBlockRegion(slot, chunk, word, block_elements);
                }
                if (word_regions) self.appendRegion(.directory_word, slot, word, 1);
            }
        }
    }

    // Frees the blocks of `slot`'s chunks in `window` but not in `skip`.
    fn freeBlocks(self: *GpuTileMirror, geom: ChunkGeometry, slot: u32, window: ChunkWindow, skip: ChunkWindow) void {
        _ = geom;
        var chunk_y = window.min_y;
        while (chunk_y < window.max_y) : (chunk_y += 1) {
            var chunk_x = window.min_x;
            while (chunk_x < window.max_x) : (chunk_x += 1) {
                if (skip.contains(chunk_x, chunk_y)) continue;
                const word = self.slotWords(slot)[self.toroidalWord(chunk_x, chunk_y)];
                if (word & tile_store_uniform_bit == 0) self.freeBlock(word);
            }
        }
    }

    // Blocks `slot` holds for its chunks in `window` but not in `skip`.
    fn countBlocks(self: *const GpuTileMirror, geom: ChunkGeometry, slot: u32, window: ChunkWindow, skip: ChunkWindow) usize {
        _ = geom;
        var blocks: usize = 0;
        var chunk_y = window.min_y;
        while (chunk_y < window.max_y) : (chunk_y += 1) {
            var chunk_x = window.min_x;
            while (chunk_x < window.max_x) : (chunk_x += 1) {
                if (skip.contains(chunk_x, chunk_y)) continue;
                blocks += @intFromBool(self.slotWords(slot)[self.toroidalWord(chunk_x, chunk_y)] & tile_store_uniform_bit == 0);
            }
        }
        return blocks;
    }

    // Whether resident `slot`'s link word must change for `next_layer` to follow it
    // (`no_layer` for none). A next layer entering this sync always rewrites, since
    // its directory is assigned at commit.
    fn linkChanges(self: *const GpuTileMirror, layer_slots: []const u32, slot: u32, next_layer: u32) bool {
        const link = self.slotWords(slot)[self.side * self.side];
        if (next_layer == no_layer) return link != tile_store_no_link;
        const next_slot = layer_slots[next_layer];
        if (next_slot == no_slot or next_slot >= self.plan_stays.items.len or !self.plan_stays.items[next_slot]) return true;
        return link != self.slot_dir.items[next_slot];
    }

    // An edit uploads only when its slot stays resident and its chunk is in both
    // the current and the new window.
    fn editLive(self: *const GpuTileMirror, geom: ChunkGeometry, group: PendingGroup, new_window: ChunkWindow) bool {
        if (group.slot >= self.plan_stays.items.len or !self.plan_stays.items[group.slot]) return false;
        const chunk_x = group.chunk % geom.chunks_x;
        const chunk_y = group.chunk / geom.chunks_x;
        return self.window.contains(chunk_x, chunk_y) and new_window.contains(chunk_x, chunk_y);
    }

    fn chunkChange(self: *const GpuTileMirror, geom: ChunkGeometry, stores: []const DenseLayerStore, slot: u32, chunk: u32) ChunkChange {
        const have = self.slotWords(slot)[self.toroidalIndex(geom, chunk)];
        const have_block = have & tile_store_uniform_bit == 0;
        if (stores[self.slot_layer.items[slot]].readUniformTile(chunk)) |tile| {
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

    fn slotWordsMut(self: *GpuTileMirror, slot: u32) []u32 {
        const stride = directoryWords(self.side);
        return self.slot_words.items[@as(usize, slot) * stride ..][0..stride];
    }

    fn toroidalWord(self: *const GpuTileMirror, chunk_x: u32, chunk_y: u32) u32 {
        const mask = self.side - 1;
        return (chunk_y & mask) * self.side + (chunk_x & mask);
    }

    fn toroidalIndex(self: *const GpuTileMirror, geom: ChunkGeometry, chunk: u32) u32 {
        return self.toroidalWord(chunk % geom.chunks_x, chunk / geom.chunks_x);
    }

    fn appendRegion(self: *GpuTileMirror, kind: RegionKind, slot: u32, index: u32, count: u32) void {
        self.regions.appendAssumeCapacity(.{ .dst = self.slot_dir.items[slot] + index, .count = count, .kind = kind, .slot = slot, .index = index });
    }

    fn appendBlockRegion(self: *GpuTileMirror, slot: u32, chunk: u32, word: u32, block_elements: u32) void {
        const block = self.slotWords(slot)[word];
        std.debug.assert(block & tile_store_uniform_bit == 0);
        self.regions.appendAssumeCapacity(.{ .dst = block, .count = block_elements, .kind = .block, .slot = slot, .index = chunk });
    }

    fn takeBlock(self: *GpuTileMirror, block_elements: u32) u32 {
        if (self.block_free.pop()) |block| return block;
        return self.bump(block_elements);
    }

    fn takeDirectory(self: *GpuTileMirror, stride: u32) u32 {
        if (self.dir_free.pop()) |dir| return dir;
        return self.bump(stride);
    }

    fn bump(self: *GpuTileMirror, elements: u32) u32 {
        const start = self.high_water;
        std.debug.assert(@as(u64, start) + elements <= tile_store_max_elements);
        self.high_water = start + elements;
        return start;
    }

    fn freeBlock(self: *GpuTileMirror, block: u32) void {
        std.debug.assert(block < self.high_water);
        std.debug.assert(self.block_free.items.len < self.block_free.capacity);
        self.block_free.appendAssumeCapacity(block);
    }

    fn freeDirectory(self: *GpuTileMirror, dir: u32) void {
        std.debug.assert(dir < self.high_water);
        std.debug.assert(self.dir_free.items.len < self.dir_free.capacity);
        self.dir_free.appendAssumeCapacity(dir);
    }
};

// Mixed chunks of `store` in `window` but not in `skip`.
fn countMixed(geom: ChunkGeometry, store: *const DenseLayerStore, window: ChunkWindow, skip: ChunkWindow) usize {
    var mixed: usize = 0;
    var chunk_y = window.min_y;
    while (chunk_y < window.max_y) : (chunk_y += 1) {
        var chunk_x = window.min_x;
        while (chunk_x < window.max_x) : (chunk_x += 1) {
            if (skip.contains(chunk_x, chunk_y)) continue;
            mixed += @intFromBool(store.readUniformTile(chunk_y * geom.chunks_x + chunk_x) == null);
        }
    }
    return mixed;
}

// Chunks in both windows.
fn overlap(a: ChunkWindow, b: ChunkWindow) usize {
    const min_x = @max(a.min_x, b.min_x);
    const min_y = @max(a.min_y, b.min_y);
    const max_x = @min(a.max_x, b.max_x);
    const max_y = @min(a.max_y, b.max_y);
    return @as(usize, max_x -| min_x) * (max_y -| min_y);
}

fn pendingLessThan(_: void, lhs: PendingEdit, rhs: PendingEdit) bool {
    if (lhs.slot != rhs.slot) return lhs.slot < rhs.slot;
    if (lhs.chunk != rhs.chunk) return lhs.chunk < rhs.chunk;
    return lhs.element < rhs.element;
}

fn regionLessThan(_: void, lhs: Region, rhs: Region) bool {
    return lhs.dst < rhs.dst;
}

const TestGpuStore = @import("world_test_support.zig").TestGpuStore;

// Three layers of 4-cell chunks (16-cell blocks, 8-element blocks) over a
// `width` x `height` cell grid, and a CPU copy of the store the syncs upload to.
const TestLayers = struct {
    geom: ChunkGeometry,
    stores: [3]DenseLayerStore,
    slots: [3]u32 = @splat(no_slot),
    gpu: TestGpuStore = .{},

    const fill: u16 = 1;
    const dug: u16 = 7;
    const empty: u16 = tile_data_pad_cell;
    const block_elements: u32 = 8;

    fn init(width: u16, height: u16) !TestLayers {
        const geom = ChunkGeometry.init(width, height, 4);
        var stores: [3]DenseLayerStore = undefined;
        var initialized: usize = 0;
        errdefer for (stores[0..initialized]) |*store| store.deinit(std.testing.allocator);
        for (&stores) |*store| {
            store.* = try DenseLayerStore.init(std.testing.allocator, geom.chunkCount(), fill);
            initialized += 1;
        }
        return .{ .geom = geom, .stores = stores };
    }

    fn deinit(self: *TestLayers) void {
        for (&self.stores) |*store| store.deinit(std.testing.allocator);
        self.gpu.deinit();
    }

    fn write(self: *TestLayers, layer: usize, x: u16, y: u16, tile: u16) !void {
        const store = &self.stores[layer];
        _ = try store.ensureAvailable(std.testing.allocator, self.geom.blockCells(), 1);
        store.write(self.geom, self.geom.chunkOf(x, y), self.geom.localOf(x, y), tile);
    }

    // Writes a cell and, on a resident layer, queues its edit the way `WorldSystem` does.
    fn dig(self: *TestLayers, mirror: *GpuTileMirror, layer: usize, x: u16, y: u16, tile: u16) !void {
        try self.write(layer, x, y, tile);
        if (self.slots[layer] == no_slot) return;
        try mirror.ensureEdit(std.testing.allocator);
        mirror.queueEdit(self.slots[layer], self.geom.chunkOf(x, y), self.geom.localOf(x, y) / 2);
    }

    // Makes every chunk of `layer` mixed.
    fn mixEveryChunk(self: *TestLayers, layer: usize) !void {
        for (0..self.geom.chunks_y) |chunk_y| for (0..self.geom.chunks_x) |chunk_x| {
            try self.write(layer, @intCast(chunk_x * 4 + 1), @intCast(chunk_y * 4 + 2), dug);
        };
    }

    fn sync(self: *TestLayers, mirror: *GpuTileMirror, desired: ?Residency) !SyncPlan {
        const sync_plan = try mirror.plan(std.testing.allocator, self.geom, &self.stores, &self.slots, desired);
        mirror.commit(&sync_plan, self.geom, &self.stores, &self.slots);
        try self.gpu.apply(mirror.spans.items, mirror.values.items);
        return sync_plan;
    }

    // Every resident layer reads back its tiles inside the window and nothing
    // outside it, and the chain from the topmost layer walks the layers in order.
    fn expectReadsBack(self: *const TestLayers, mirror: *const GpuTileMirror) !void {
        for (self.slots, 0..) |slot, layer| {
            if (slot == no_slot) continue;
            for (0..self.geom.height) |y| for (0..self.geom.width) |x| {
                const cell_x: u16 = @intCast(x);
                const cell_y: u16 = @intCast(y);
                const shown = self.gpu.tileAt(self.geom, mirror.side, mirror.window, mirror.slotDirectory(slot), cell_x, cell_y);
                if (mirror.window.contains(cell_x >> 2, cell_y >> 2)) {
                    try std.testing.expectEqual(@as(?u16, self.stores[layer].tile(self.geom, cell_x, cell_y)), shown);
                } else {
                    try std.testing.expectEqual(@as(?u16, null), shown);
                }
            };
        }
        const order = mirror.order.items;
        for (order, 0..) |slot, index| {
            const link = self.gpu.words.items[mirror.slotDirectory(slot) + mirror.side * mirror.side];
            const expected = if (index + 1 < order.len) mirror.slotDirectory(order[index + 1]) else tile_store_no_link;
            try std.testing.expectEqual(expected, link);
        }
    }
};

fn testWindow(min_x: u32, min_y: u32, max_x: u32, max_y: u32) ChunkWindow {
    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

test "a layer entering uploads its window directory, link, and mixed window blocks; chunks outside the window upload nothing" {
    // 16x8 cells: a 4x2 chunk grid. Mixed chunks (0, 0), (1, 1), and (3, 0); the
    // window covers the left 2x2 chunks.
    var layers = try TestLayers.init(16, 8);
    defer layers.deinit();
    try layers.write(0, 0, 0, TestLayers.dug);
    try layers.write(0, 5, 5, TestLayers.dug);
    try layers.write(0, 13, 1, TestLayers.dug);
    // An early block of only fill reads as uniform.
    _ = try layers.stores[0].ensureAvailable(std.testing.allocator, layers.geom.blockCells(), 1);
    layers.stores[0].materializeChunk(layers.geom.blockCells(), 1);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);

    const entered = try layers.sync(&mirror, .{ .layers = &.{0}, .window = testWindow(0, 0, 2, 2), .side = 2 });
    try std.testing.expect(entered.relayout);
    try std.testing.expectEqual(@as(usize, 1), entered.enter_count);
    // One whole directory (4 words and the link), then the two mixed window blocks.
    try std.testing.expectEqual(@as(usize, 3), mirror.spans.items.len);
    try std.testing.expectEqual(TileStoreSpan{ .dst_element = 0, .count = directoryWords(2) }, mirror.spans.items[0]);
    try std.testing.expectEqual(tile_store_no_link, mirror.values.items[4]);
    try std.testing.expectEqual(directoryWords(2) + 2 * TestLayers.block_elements, entered.required_elements);
    try std.testing.expectEqual(entered.required_elements, mirror.high_water);
    try layers.expectReadsBack(&mirror);
}

test "a one-chunk pan uploads only entering chunks and frees leaving blocks; high water stays flat over a long pan" {
    // 32x8 cells: an 8x2 chunk grid, every chunk mixed on two layers.
    var layers = try TestLayers.init(32, 8);
    defer layers.deinit();
    try layers.mixEveryChunk(0);
    try layers.mixEveryChunk(1);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);

    _ = try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = testWindow(0, 0, 2, 2), .side = 2 });
    const high_water = mirror.high_water;
    for (1..7) |step| {
        const window = testWindow(@intCast(step), 0, @intCast(step + 2), 2);
        const panned = try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = window, .side = 2 });
        // Per layer, the entering column's two chunks: a word and a block each.
        try std.testing.expectEqual(@as(usize, 2 * 2 * 2), panned.span_count);
        try std.testing.expectEqual(@as(usize, 2 * 2 * (1 + TestLayers.block_elements)), panned.value_count);
        try std.testing.expect(!panned.layers_changed);
        try std.testing.expectEqual(high_water, mirror.high_water);
        try layers.expectReadsBack(&mirror);
    }
    // Back across in one jump: the window shares no chunk with the last, so every
    // chunk enters, and still no growth.
    _ = try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = testWindow(0, 0, 2, 2), .side = 2 });
    try std.testing.expectEqual(high_water, mirror.high_water);
    try layers.expectReadsBack(&mirror);
    // The same window again uploads nothing.
    try std.testing.expectEqual(@as(usize, 0), (try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = testWindow(0, 0, 2, 2), .side = 2 })).span_count);
}

test "a side change relayouts from an empty allocator" {
    var layers = try TestLayers.init(32, 8);
    defer layers.deinit();
    try layers.mixEveryChunk(0);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    _ = try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = testWindow(0, 0, 2, 2), .side = 2 });
    const old_directory = mirror.slotDirectory(layers.slots[1]);

    // A wider window at side 4: every layer re-enters into a fresh layout whose
    // size counts nothing of the old one. A new store would hold it.
    layers.gpu.deinit();
    layers.gpu = .{};
    const relayout = try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = testWindow(0, 0, 4, 2), .side = 4 });
    try std.testing.expect(relayout.relayout and relayout.layers_changed);
    try std.testing.expectEqual(@as(usize, 2), relayout.enter_count);
    try std.testing.expectEqual(2 * directoryWords(4) + 8 * TestLayers.block_elements, relayout.required_elements);
    try std.testing.expectEqual(relayout.required_elements, mirror.high_water);
    try std.testing.expect(mirror.slotDirectory(layers.slots[1]) != old_directory or mirror.slotDirectory(layers.slots[0]) == 0);
    try layers.expectReadsBack(&mirror);
}

test "layers chain topmost-first and relink when a layer enters or leaves" {
    var layers = try TestLayers.init(8, 8);
    defer layers.deinit();
    // A hole through layers 0 and 1 at (1, 1): the chain reaches layer 2.
    try layers.write(0, 1, 1, TestLayers.empty);
    try layers.write(1, 1, 1, TestLayers.empty);
    try layers.write(2, 1, 1, TestLayers.dug);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    const window = testWindow(0, 0, 2, 2);

    _ = try layers.sync(&mirror, .{ .layers = &.{ 0, 1 }, .window = window, .side = 2 });
    try layers.expectReadsBack(&mirror);
    const top = mirror.slotDirectory(layers.slots[0]);
    try std.testing.expectEqual(@as(?u16, TestLayers.empty), layers.gpu.composite(layers.geom, 2, window, top, 2, TestLayers.empty, 1, 1));

    // Layer 2 enters at the bottom (its directory and one mixed block); layer 1
    // rewrites only its link word.
    const entered = try layers.sync(&mirror, .{ .layers = &.{ 0, 1, 2 }, .window = window, .side = 2 });
    try std.testing.expectEqual(@as(usize, 3), entered.span_count);
    try std.testing.expect(entered.layers_changed);
    try layers.expectReadsBack(&mirror);
    try std.testing.expectEqual(@as(?u16, TestLayers.dug), layers.gpu.composite(layers.geom, 2, window, top, 3, TestLayers.empty, 1, 1));

    // Layer 1 leaves from the middle: layer 0 relinks to layer 2.
    const left = try layers.sync(&mirror, .{ .layers = &.{ 0, 2 }, .window = window, .side = 2 });
    try std.testing.expectEqual(@as(usize, 1), left.span_count);
    try std.testing.expectEqual(@as(usize, 1), left.evict_count);
    try std.testing.expectEqual(no_slot, layers.slots[1]);
    try layers.expectReadsBack(&mirror);
    try std.testing.expectEqual(@as(?u16, TestLayers.dug), layers.gpu.composite(layers.geom, 2, window, top, 2, TestLayers.empty, 1, 1));
}

test "freed blocks and directories are reused by class" {
    var layers = try TestLayers.init(8, 8);
    defer layers.deinit();
    try layers.mixEveryChunk(0);
    try layers.write(1, 2, 2, TestLayers.dug);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    const window = testWindow(0, 0, 2, 2);

    _ = try layers.sync(&mirror, .{ .layers = &.{0}, .window = window, .side = 2 });
    const directory = mirror.slotDirectory(layers.slots[0]);
    var blocks: [4]u32 = undefined;
    @memcpy(&blocks, mirror.slotWords(layers.slots[0])[0..4]);
    const high_water = mirror.high_water;

    // Layer 0 leaves and layer 1 enters in one sync: its directory takes layer 0's
    // directory and its one block one of layer 0's blocks, never a block region for
    // a directory or the reverse.
    _ = try layers.sync(&mirror, .{ .layers = &.{1}, .window = window, .side = 2 });
    try std.testing.expectEqual(high_water, mirror.high_water);
    try std.testing.expectEqual(directory, mirror.slotDirectory(layers.slots[1]));
    const block = mirror.slotWords(layers.slots[1])[mirror.toroidalWord(0, 0)];
    try std.testing.expect(std.mem.indexOfScalar(u32, &blocks, block) != null);
    try std.testing.expectEqual(@as(usize, 3), mirror.block_free.items.len);
    try std.testing.expectEqual(@as(usize, 0), mirror.dir_free.items.len);
    try layers.expectReadsBack(&mirror);
}

test "edits read back after the next sync and a split takes a freed block" {
    var layers = try TestLayers.init(8, 8);
    defer layers.deinit();
    try layers.write(0, 0, 0, TestLayers.dug);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    const residency = Residency{ .layers = &.{0}, .window = testWindow(0, 0, 2, 2), .side = 2 };
    _ = try layers.sync(&mirror, residency);
    const block = mirror.slotWords(layers.slots[0])[0];

    // Repeated and overwritten edits in one mixed chunk.
    try layers.dig(&mirror, 0, 1, 0, TestLayers.dug);
    try layers.dig(&mirror, 0, 0, 0, TestLayers.fill);
    try layers.dig(&mirror, 0, 1, 0, 9);
    try layers.dig(&mirror, 0, 1, 1, TestLayers.dug);
    try layers.dig(&mirror, 0, 1, 1, TestLayers.dug);
    _ = try layers.sync(&mirror, null);
    try layers.expectReadsBack(&mirror);

    // Back to one tile frees the block; a split elsewhere in the same sync takes it.
    for (0..2) |y| for (0..2) |x| try layers.dig(&mirror, 0, @intCast(x), @intCast(y), TestLayers.fill);
    try layers.dig(&mirror, 0, 6, 6, TestLayers.dug);
    const high_water = mirror.high_water;
    _ = try layers.sync(&mirror, null);
    try std.testing.expectEqual(high_water, mirror.high_water);
    try std.testing.expectEqual(block, mirror.slotWords(layers.slots[0])[mirror.toroidalWord(1, 1)]);
    try layers.expectReadsBack(&mirror);
}

test "an out-of-memory plan leaves residency and window intact (FailingAllocator)" {
    var layers = try TestLayers.init(32, 8);
    defer layers.deinit();
    try layers.mixEveryChunk(0);
    try layers.mixEveryChunk(1);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    _ = try layers.sync(&mirror, .{ .layers = &.{0}, .window = testWindow(0, 0, 2, 2), .side = 2 });
    try layers.dig(&mirror, 0, 2, 2, TestLayers.empty);
    // Chunk (1, 0) stays in the window: its edit must survive every failed plan.
    try layers.dig(&mirror, 0, 5, 1, TestLayers.empty);
    const window = mirror.window;
    const high_water = mirror.high_water;

    // Fail each allocation of a sync that pans, splits nothing new, and enters layer 1.
    const residency = Residency{ .layers = &.{ 0, 1 }, .window = testWindow(1, 0, 3, 2), .side = 2 };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        const result = mirror.plan(failing.allocator(), layers.geom, &layers.stores, &layers.slots, residency);
        if (result) |sync_plan| {
            mirror.commit(&sync_plan, layers.geom, &layers.stores, &layers.slots);
            try layers.gpu.apply(mirror.spans.items, mirror.values.items);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(no_slot, layers.slots[1]);
            try std.testing.expectEqual(@as(usize, 1), mirror.residentLayerCount());
            try std.testing.expect(mirror.window.eql(window));
            try std.testing.expectEqual(high_water, mirror.high_water);
        }
    }
    try std.testing.expect(fail_index > 0);
    try std.testing.expect(layers.slots[1] != no_slot);
    try std.testing.expectEqual(@as(?u16, TestLayers.empty), layers.gpu.tileAt(layers.geom, 2, mirror.window, mirror.slotDirectory(layers.slots[0]), 5, 1));
    try layers.expectReadsBack(&mirror);
}

test "a warmed pan sync allocates nothing (FailingAllocator)" {
    var layers = try TestLayers.init(32, 8);
    defer layers.deinit();
    try layers.mixEveryChunk(0);
    try layers.mixEveryChunk(1);
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    const left = Residency{ .layers = &.{ 0, 1 }, .window = testWindow(0, 0, 2, 2), .side = 2 };
    const right = Residency{ .layers = &.{ 0, 1 }, .window = testWindow(1, 0, 3, 2), .side = 2 };
    _ = try layers.sync(&mirror, left);
    _ = try layers.sync(&mirror, right);
    _ = try layers.sync(&mirror, left);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    for ([_]Residency{ right, left, right }) |residency| {
        const sync_plan = try mirror.plan(failing.allocator(), layers.geom, &layers.stores, &layers.slots, residency);
        mirror.commit(&sync_plan, layers.geom, &layers.stores, &layers.slots);
        try layers.gpu.apply(mirror.spans.items, mirror.values.items);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try layers.expectReadsBack(&mirror);
}

test "a reserved edit queues without allocating (FailingAllocator)" {
    var layers = try TestLayers.init(8, 8);
    defer layers.deinit();
    var mirror = GpuTileMirror{};
    defer mirror.deinit(std.testing.allocator);
    _ = try layers.sync(&mirror, .{ .layers = &.{0}, .window = testWindow(0, 0, 2, 2), .side = 2 });
    for (0..3) |_| try mirror.reserveEdits(std.testing.allocator, 1);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    for (0..3) |index| {
        try mirror.ensureEdit(failing.allocator());
        mirror.queueEdit(layers.slots[0], @intCast(index), 0);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), mirror.pending_reserved);
}

test "residentLayerFit is the most layers whose directories and window blocks fit the u32 width" {
    for ([_][2]u32{ .{ 1, 1 }, .{ 8, 128 }, .{ 64, 128 }, .{ 4096, 128 }, .{ tile_store_max_side, 1 } }) |case| {
        const side = case[0];
        const block_elements = case[1];
        const per_layer = @as(u64, side) * side * (1 + block_elements) + 1;
        const fit = residentLayerFit(side, block_elements);
        try std.testing.expect(@as(u64, fit) * per_layer <= tile_store_max_elements);
        try std.testing.expect(@as(u64, fit + 1) * per_layer > tile_store_max_elements);
    }
    // A side whose one layer cannot fit draws nothing rather than overflowing.
    try std.testing.expectEqual(@as(usize, 0), residentLayerFit(tile_store_max_side, 128));
}

test "fitWindow grows the side to the window and clips past the largest side" {
    const small = fitWindow(4, testWindow(2, 3, 5, 6));
    try std.testing.expectEqual(@as(u32, 4), small.side);
    try std.testing.expect(small.window.eql(testWindow(2, 3, 5, 6)));
    // A window wider than the requested side raises the side, never shares words.
    const wide = fitWindow(4, testWindow(0, 0, 9, 2));
    try std.testing.expectEqual(@as(u32, 16), wide.side);
    try std.testing.expect(wide.window.eql(testWindow(0, 0, 9, 2)));
    // Past the largest side the window clips from its min corner.
    const huge = fitWindow(1, testWindow(10, 0, 10 + tile_store_max_side + 5, 1));
    try std.testing.expectEqual(tile_store_max_side, huge.side);
    try std.testing.expect(huge.window.eql(testWindow(10, 0, 10 + tile_store_max_side, 1)));
}
