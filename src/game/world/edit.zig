// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `WorldSystem`'s terrain content edits: single-cell dense writes and their reserve
//! scope, batched dense writes over the thread system, and sparse tile adds and
//! blocking clears. Free functions over `*WorldSystem`, which exposes the public ones
//! as its methods.

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const StageControls = @import("../../app/thread_system.zig").StageControls;
const runStage = @import("../../app/thread_system.zig").runStage;
const WorldObstacleChangedEvent = @import("../simulation.zig").WorldObstacleChangedEvent;
const WorldTileChangedEvent = @import("../simulation.zig").WorldTileChangedEvent;
const WorldDepth = @import("../render_depth.zig").WorldDepth;
const world_render = @import("render.zig");
const log = @import("../../core/logging.zig").game;
const logging = @import("../../core/logging.zig");
const world_terrain = @import("terrain.zig");
const ChunkBits = @import("terrain.zig").ChunkBits;
const ChunkBitsStore = @import("terrain.zig").ChunkBitsStore;
const ChunkForm = @import("terrain.zig").ChunkForm;
const ChunkGeometry = @import("terrain.zig").ChunkGeometry;
const DenseLayerStore = @import("terrain.zig").DenseLayerStore;
const max_chunk_cells = @import("terrain.zig").max_chunk_cells;
const LevelTerrain = @import("terrain.zig").LevelTerrain;
const OwnedBlock = @import("terrain.zig").OwnedBlock;
const no_sparse_tile = @import("terrain.zig").no_sparse_tile;
const no_edit_write = @import("terrain.zig").no_edit_write;
const WorldSystem = @import("system.zig").WorldSystem;
const TileId = @import("system.zig").TileId;
const TileFlags = @import("system.zig").TileFlags;
const CellCoord = @import("system.zig").CellCoord;
const WorldEditError = @import("system.zig").WorldEditError;
const invalid_tile_id = @import("system.zig").invalid_tile_id;
const catalogValid = @import("system.zig").catalogValid;
const catalogFlags = @import("system.zig").catalogFlags;

pub const ReservedChunk = struct {
    kind: enum { dense_block, blocked_slot },
    /// Dense layer index for `dense_block`, level index for `blocked_slot`.
    owner: u32,
    chunk: u32,
};

/// One cell write of a batched dense edit (`WorldSystem.applyDenseCellWrites`);
/// `invalid_tile_id` clears the cell to empty.
pub const DenseCellWrite = struct {
    layer: u32,
    x: u16,
    y: u16,
    tile: TileId,
};

/// One chunk's part of a batched dense edit: writes to cells of chunk
/// (`chunk_x`, `chunk_y`) on `level`'s dense layers, applied in order (last wins).
pub const DenseChunkWrites = struct {
    level: u16,
    chunk_x: u16,
    chunk_y: u16,
    writes: []const DenseCellWrite,
};

/// Threading for a batched dense edit, with one tuner per stage. `controls` pin a fixed
/// partition or a worker cap for benchmark controls.
pub const TerrainEditThreads = struct {
    thread_system: *ThreadSystem,
    plan_tuner: *AdaptiveWorkTuner,
    write_tuner: *AdaptiveWorkTuner,
    controls: StageControls = .{},

    fn plan(self: TerrainEditThreads) Dispatch {
        return Dispatch.init(self.thread_system, self.plan_tuner, self.controls);
    }

    fn write(self: TerrainEditThreads) Dispatch {
        return Dispatch.init(self.thread_system, self.write_tuner, self.controls);
    }
};

const DenseEditStatus = enum { ok, invalid_layer, invalid_cell, invalid_tile };

// One bit per band of a level over a caller-owned window of words: a group's
// written or claimed bands in `DenseEditScratch.masks`. Not `std.bit_set`: std's bit
// sets own their words, and these are windows of one shared, reserved scratch buffer.
const BandBits = struct {
    words: []u64,

    fn set(self: BandBits, band: u32) void {
        self.words[band / 64] |= @as(u64, 1) << @intCast(band % 64);
    }

    fn isSet(self: BandBits, band: u32) bool {
        return self.words[band / 64] & (@as(u64, 1) << @intCast(band % 64)) != 0;
    }

    // The first set band at or after `cursor`, or null. O(words from `cursor`).
    fn next(self: BandBits, cursor: u32) ?u32 {
        var word_index: usize = cursor / 64;
        if (word_index >= self.words.len) return null;
        var word = self.words[word_index] & (~@as(u64, 0) << @intCast(cursor % 64));
        while (true) {
            if (word != 0) return @intCast(word_index * 64 + @ctz(word));
            word_index += 1;
            if (word_index >= self.words.len) return null;
            word = self.words[word_index];
        }
    }
};

// What the plan stage derives from one group's writes, before any mutation. The
// group's band bits live in `DenseEditScratch.masks` (`groupBandBits`).
const DenseEditPlan = struct {
    status: DenseEditStatus = .ok,
    // The chunk's composed form; when not mixed the main thread claims a slot and
    // the write stage fills it from this form.
    slot_form: ChunkForm = .mixed,
};

// One (level, chunk) of a batched dense edit. The plan stage writes `plan` and the
// write stage `change_count`, each once, by the one participant running the group;
// `start` is its window in the batch's event buffer.
const DenseEditGroup = struct {
    level: u16,
    chunk: u32,
    writes: []const DenseCellWrite,
    plan: DenseEditPlan = .{},
    start: usize = 0,
    change_count: usize = 0,
};

// Per-participant scratch strides are whole cache lines: no shared writable line.
const EditFinalsList = std.array_list.Aligned(TileId, .fromByteUnits(thread_shared_record_alignment));
const EditTouchedList = std.array_list.Aligned(ChunkBits, .fromByteUnits(thread_shared_record_alignment));
const EditOwnedList = std.array_list.Aligned(?OwnedBlock, .fromByteUnits(thread_shared_record_alignment));
const EditBandList = std.array_list.Aligned(u32, .fromByteUnits(thread_shared_record_alignment));

// Scratch of `applyDenseCellWrites`, kept at its high water.
pub const DenseEditScratch = struct {
    groups: std.ArrayList(DenseEditGroup) = .empty,
    // Per group, `mask_words` words of written bands then `mask_words` of bands
    // whose uniform chunk a write splits (claimed by the main thread).
    masks: std.ArrayList(u64) = .empty,
    finals: EditFinalsList = .empty,
    touched: EditTouchedList = .empty,
    owned: EditOwnedList = .empty,
    // Per participant, the running group's written bands in band order.
    written_bands: EditBandList = .empty,
    // Per band of the level being reserved: blocks its claims take.
    band_counts: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *DenseEditScratch, allocator: std.mem.Allocator) void {
        self.groups.deinit(allocator);
        self.masks.deinit(allocator);
        self.finals.deinit(allocator);
        self.touched.deinit(allocator);
        self.owned.deinit(allocator);
        self.written_bands.deinit(allocator);
        self.band_counts.deinit(allocator);
    }
};

// The batched edit's per-group and per-participant scratch strides for a level of
// `bands` bands: whole cache lines per participant, so no two share a writable line.
const DenseEditStrides = struct {
    bands: usize,
    mask_words: usize,
    finals: usize,
    touched: usize,
    owned: usize,
    written_bands: usize,

    fn of(bands: usize) DenseEditStrides {
        comptime std.debug.assert(max_chunk_cells * @sizeOf(TileId) % thread_shared_record_alignment == 0);
        return .{
            .bands = bands,
            .mask_words = @max(1, @divCeil(bands, 64)),
            .finals = bands * max_chunk_cells,
            .touched = std.mem.alignForward(usize, bands * @sizeOf(ChunkBits), thread_shared_record_alignment) / @sizeOf(ChunkBits),
            .owned = std.mem.alignForward(usize, bands, thread_shared_record_alignment / std.math.gcd(@sizeOf(?OwnedBlock), thread_shared_record_alignment)),
            .written_bands = std.mem.alignForward(usize, bands, thread_shared_record_alignment / @sizeOf(u32)),
        };
    }
};

// Group `group_index`'s written bands (`claims` false) or claimed bands in `masks`.
fn groupBandBits(masks: []u64, mask_words: usize, group_index: usize, claims: bool) BandBits {
    return .{ .words = masks[(2 * group_index + @intFromBool(claims)) * mask_words ..][0..mask_words] };
}

// Job context of the plan stage: read-only over the world; group `g` writes only
// its own `plan` and its window of `masks`.
const DenseEditPlanJob = struct {
    geom: ChunkGeometry,
    groups: []DenseEditGroup,
    masks: []u64,
    mask_words: usize,
    stores: []const DenseLayerStore,
    layer_levels: []const u16,
    layer_bands: []const u32,
    levels: []const LevelTerrain,
    catalog_valid: []const bool,
    range_count: usize,
};

// Job context of the write stage. Group `g` writes only its chunk's blocks and their
// fill rows on its level's bands, that chunk's composed-bits slot, its window of
// `events`, and its own `change_count`; a participant uses only its scratch slots.
const DenseEditWriteJob = struct {
    geom: ChunkGeometry,
    width: u16,
    groups: []DenseEditGroup,
    masks: []u64,
    mask_words: usize,
    events: []WorldTileChangedEvent,
    finals: []TileId,
    finals_stride: usize,
    touched: []ChunkBits,
    touched_stride: usize,
    owned: []?OwnedBlock,
    owned_stride: usize,
    written_bands: []u32,
    written_bands_stride: usize,
    participant_count: usize,
    stores: []DenseLayerStore,
    layer_bands: []const u32,
    levels: []LevelTerrain,
    catalog_flags: []const TileFlags,
    range_count: usize,
};

/// Writes one dense cell. Reserves its growth first, so an OOM changes nothing;
/// after `reserveDenseCellWrite` for this cell it allocates nothing. O(1) plus a
/// one-time O(edge²) block materialize, plus O(bands + sparse tiles in the chunk)
/// to recompose the cell's movement-blocked bit.
pub fn setDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) WorldEditError!?WorldTileChangedEvent {
    try self.validateTileId(tile_id);
    return writeDenseTileCell(self, layer_index, x, y, tile_id);
}

/// Clears a dense floor cell to the empty/see-through state (`invalid_tile_id`):
/// the tilemap shader discards it, revealing the layer drawn below, and
/// `flagsFor` treats it as non-blocking. This is how a dig punches a hole
/// through one plane to expose the level beneath. Same costs as `setDenseTile`.
pub fn clearDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16) WorldEditError!?WorldTileChangedEvent {
    return writeDenseTileCell(self, layer_index, x, y, invalid_tile_id);
}

/// Starts a reserve scope: later `reserveDenseCellWrite` calls accumulate until
/// the next begin. Returns to uniform every chunk the previous scope gave an early
/// block or slot that no write used. O(chunks reserved in the previous scope).
pub fn beginDenseCellWriteReserve(self: *WorldSystem) void {
    const stores = self.dense_layers.items(.store);
    for (self.dense_reserved_chunks.items) |reserved| switch (reserved.kind) {
        .dense_block => stores[reserved.owner].releaseIfUniform(reserved.chunk),
        .blocked_slot => self.level_terrain.items[reserved.owner].blocked.releaseIfUniform(self.chunkGeometry(), reserved.chunk),
    };
    self.dense_reserved_chunks.clearRetainingCapacity();
}

/// The dense growth seam: makes writing `tile_id` into one cell allocation-free.
/// A uniform chunk the write would split gets its tile block (and a composed chunk
/// the write would split its bits slot) now, once per chunk, so N reserves in one
/// scope (`beginDenseCellWriteReserve`) cover N writes however they share chunks.
/// A resident in-window chunk reserves one GPU list slot per distinct chunk, not
/// per cell. Reads are unchanged. O(bands + sparse tiles in the chunk), plus a one-time
/// O(edge²) block and pool growth.
pub fn reserveDenseCellWrite(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) WorldEditError!void {
    if (layer_index >= self.dense_layers.len) return error.InvalidWorldLayer;
    if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
    const geom = self.chunkGeometry();
    const chunk = geom.chunkOf(x, y);
    const local = geom.localOf(x, y);
    const store = &self.dense_layers.items(.store)[layer_index];
    if (store.tile(geom, x, y) == tile_id) return;
    const gpu_slot = self.dense_layers.items(.gpu_slot)[layer_index];
    try self.gpu_tiles.reserveChangedChunk(self.allocator, gpu_slot, chunk % geom.chunks_x, chunk / geom.chunks_x);
    const level = self.denseLayerLevel(layer_index);
    const blocked = &self.level_terrain.items[level].blocked;
    const needs_block = store.writeNeedsBlock(chunk, tile_id);
    const needs_slot = blocked.setNeedsSlot(chunk, local, composedBlockedWith(self, level, x, y, layer_index, tile_id));

    // Fallible growth first; the commits below only take what it guaranteed.
    try self.dense_reserved_chunks.ensureUnusedCapacity(self.allocator, @as(usize, @intFromBool(needs_block)) + @intFromBool(needs_slot));
    if (needs_block) try ensureDenseBlocks(self, store, geom.blockCells(), 1);
    if (needs_slot) try ensureBlockedSlots(self, blocked, 1);
    if (needs_block) {
        store.materializeChunk(geom.blockCells(), chunk);
        self.dense_reserved_chunks.appendAssumeCapacity(.{ .kind = .dense_block, .owner = @intCast(layer_index), .chunk = chunk });
    }
    if (needs_slot) {
        blocked.materializeChunk(geom, chunk);
        self.dense_reserved_chunks.appendAssumeCapacity(.{ .kind = .blocked_slot, .owner = level, .chunk = chunk });
    }
}

/// Shared dense-cell write: bounds-checks, updates the chunk store (the source of
/// truth, which marks its block changed) and the level's composed blocked bit,
/// flags the layer for the next GPU sync when it is resident, and returns the
/// compact change event. Tile-id validity is the caller's concern, so an empty
/// (`invalid_tile_id`) write is allowed here. Every growth (changed-chunk slot,
/// tile block, bits slot) is ensured before the first mutation, so an OOM leaves
/// the world unchanged and retryable.
fn writeDenseTileCell(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) WorldEditError!?WorldTileChangedEvent {
    if (layer_index >= self.dense_layers.len) return error.InvalidWorldLayer;
    if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
    const geom = self.chunkGeometry();
    const chunk = geom.chunkOf(x, y);
    const local = geom.localOf(x, y);
    const store = &self.dense_layers.items(.store)[layer_index];
    const old_tile_id = store.tile(geom, x, y);
    if (old_tile_id == tile_id) return null;
    const level = self.denseLayerLevel(layer_index);
    const blocked = &self.level_terrain.items[level].blocked;
    const new_composed = composedBlockedWith(self, level, x, y, layer_index, tile_id);
    const gpu_slot = self.dense_layers.items(.gpu_slot)[layer_index];
    if (self.gpu_tiles.changedChunkIsNew(gpu_slot, chunk % geom.chunks_x, chunk / geom.chunks_x)) {
        try self.gpu_tiles.reserveChangedChunks(self.allocator, 1);
    }
    if (store.writeNeedsBlock(chunk, tile_id)) try ensureDenseBlocks(self, store, geom.blockCells(), 1);
    if (blocked.setNeedsSlot(chunk, local, new_composed)) try ensureBlockedSlots(self, blocked, 1);

    store.write(geom, chunk, local, tile_id);
    blocked.set(geom, chunk, local, new_composed);
    // A layer outside the render window flags nothing: it uploads whole when it
    // enters.
    world_render.markRenderChanged(self, self.dense_layers.items(.gpu_slot), self.dense_layers.items(.render_changed), layer_index, chunk);
    return .{
        .level = level,
        .x = x,
        .y = y,
        .old_tile_id = old_tile_id,
        .new_tile_id = tile_id,
        .old_blocks_movement = self.flagsFor(old_tile_id).blocks_movement,
        .new_blocks_movement = self.flagsFor(tile_id).blocks_movement,
    };
}

/// Applies a dense one-step change (cave-in, explosion) all-or-nothing: every
/// write is validated and every growth reserved before the first mutation, so
/// an error leaves the world untouched for a retry.
///
/// `chunks` holds one entry per (level, chunk), strictly increasing in (level,
/// chunk_y, chunk_x), else `error.UnorderedDenseChunkWrites`; an entry's writes
/// lie in its chunk on its level's layers and apply in order. Chunks are planned
/// and written one participant each over `threads` (inline for one chunk or no
/// threads). Appends one event per changed cell to `events`, which must have
/// spare capacity for every write, in (level, chunk, local cell, layer) order,
/// identical for any partition; flags each resident written layer for the next
/// GPU sync.
///
/// c writes over k chunks with d changed cells, B bands on the widest touched
/// level, b bands written per chunk, and s sparse tiles in each chunk: O(c +
/// k·(edge² + ⌈B/64⌉ + s) + d·bands) stage work; the main thread does O(k·b) reserves,
/// claims, flags, and releases and an O(k + d) event merge.
pub fn applyDenseCellWrites(
    self: *WorldSystem,
    chunks: []const DenseChunkWrites,
    threads: ?TerrainEditThreads,
    events: *std.ArrayList(WorldTileChangedEvent),
) (WorldEditError || error{UnorderedDenseChunkWrites})!void {
    if (comptime runtime_perf_log.enabled) {
        self.perf.last_terrain_edit_plan_batch = .{};
        self.perf.last_terrain_edit_write_batch = .{};
    }
    if (chunks.len == 0) return;
    // A world with no level has no chunk grid; every entry's level is invalid.
    if (self.level_terrain.items.len == 0) return error.InvalidWorldLevel;
    const geom = self.chunkGeometry();
    const block_cells = geom.blockCells();
    const rows = self.dense_layers.slice();
    const stores = rows.items(.store);
    const levels = self.level_terrain.items;
    const scratch = &self.dense_edit;

    // Groups in input order, which must be (level, chunk) order. O(k).
    try ensureDenseEditCapacity(self, &scratch.groups, chunks.len);
    scratch.groups.clearRetainingCapacity();
    var write_count: usize = 0;
    var band_stride: usize = 0;
    for (chunks, 0..) |entry, index| {
        if (entry.level >= levels.len) return error.InvalidWorldLevel;
        if (entry.chunk_x >= geom.chunks_x or entry.chunk_y >= geom.chunks_y) return error.InvalidWorldCell;
        const chunk = @as(u32, entry.chunk_y) * geom.chunks_x + entry.chunk_x;
        if (index > 0) {
            const previous = scratch.groups.items[index - 1];
            if (entry.level < previous.level or (entry.level == previous.level and chunk <= previous.chunk)) {
                return error.UnorderedDenseChunkWrites;
            }
        }
        scratch.groups.appendAssumeCapacity(.{ .level = entry.level, .chunk = chunk, .writes = entry.writes });
        write_count += entry.writes.len;
        band_stride = @max(band_stride, levels[entry.level].bandLayers().len);
    }
    std.debug.assert(events.capacity - events.items.len >= write_count);
    const groups = scratch.groups.items;
    // One chunk runs inline: there is nothing to fan out.
    const stage_threads: ?TerrainEditThreads = if (groups.len > 1) threads else null;

    // Reserve every growth both stages and the merge use, sized from the groups'
    // widest level, before either dispatch; nothing changes yet.
    const participant_count = if (stage_threads) |stage| stage.thread_system.participantSlotCount() else 1;
    const strides = DenseEditStrides.of(band_stride);
    try reserveDenseEditScratch(self, groups.len, strides, participant_count);
    const mask_words = strides.mask_words;
    const finals_stride = strides.finals;
    const touched_stride = strides.touched;
    const owned_stride = strides.owned;
    const written_bands_stride = strides.written_bands;
    scratch.masks.items.len = groups.len * 2 * mask_words;
    const masks = scratch.masks.items;

    // Plan stage: validation and band bits per group, read-only over the world.
    var plan_job = DenseEditPlanJob{
        .geom = geom,
        .groups = groups,
        .masks = masks,
        .mask_words = mask_words,
        .stores = stores,
        .layer_levels = rows.items(.level_index),
        .layer_bands = rows.items(.band),
        .levels = levels,
        .catalog_valid = self.catalog_valid.items,
        .range_count = 1,
    };
    const plan_batch = runStage(if (stage_threads) |stage| stage.plan() else null, groups.len, 1, &plan_job, &plan_job.range_count, denseEditPlanJob);
    if (comptime runtime_perf_log.enabled) self.perf.last_terrain_edit_plan_batch = plan_batch;

    // The first invalid write in group order fails the batch before any growth.
    for (groups) |group| switch (group.plan.status) {
        .ok => {},
        .invalid_layer => return error.InvalidWorldLayer,
        .invalid_cell => return error.InvalidWorldCell,
        .invalid_tile => return error.InvalidWorldTile,
    };

    // One list slot per resident written layer not already recorded. Before any
    // mutation, so an OOM leaves the world unchanged; a group that then changes
    // no cell keeps the spare slot.
    const gpu_slots = rows.items(.gpu_slot);
    var render_marks: usize = 0;
    for (groups, 0..) |group, group_index| {
        const written = groupBandBits(masks, mask_words, group_index, false);
        var cursor: u32 = 0;
        while (written.next(cursor)) |band| : (cursor = band + 1) {
            const layer = levels[group.level].bands.items[band];
            const chunk_y = group.chunk / geom.chunks_x;
            const chunk_x = group.chunk - chunk_y * geom.chunks_x;
            render_marks += @intFromBool(self.gpu_tiles.changedChunkIsNew(gpu_slots[layer], chunk_x, chunk_y));
        }
    }
    try self.gpu_tiles.reserveChangedChunks(self.allocator, render_marks);

    // Groups are in level order, so each level's pools reserve once: one block per
    // (band, chunk) a write splits and one slot per chunk not already mixed. The
    // counts are zeroed, summed, and read through the claimed bits alone.
    scratch.band_counts.items.len = band_stride;
    const band_counts = scratch.band_counts.items;
    var run_start: usize = 0;
    while (run_start < groups.len) {
        const level = groups[run_start].level;
        const terrain = &levels[level];
        var slot_count: usize = 0;
        var run_end = run_start;
        while (run_end < groups.len and groups[run_end].level == level) : (run_end += 1) {
            const claims = groupBandBits(masks, mask_words, run_end, true);
            var cursor: u32 = 0;
            while (claims.next(cursor)) |band| : (cursor = band + 1) band_counts[band] = 0;
        }
        for (run_start..run_end) |group_index| {
            const claims = groupBandBits(masks, mask_words, group_index, true);
            var cursor: u32 = 0;
            while (claims.next(cursor)) |band| : (cursor = band + 1) band_counts[band] += 1;
            slot_count += @intFromBool(groups[group_index].plan.slot_form != .mixed);
        }
        for (run_start..run_end) |group_index| {
            const claims = groupBandBits(masks, mask_words, group_index, true);
            var cursor: u32 = 0;
            while (claims.next(cursor)) |band| : (cursor = band + 1) {
                if (band_counts[band] == 0) continue;
                try ensureDenseBlocks(self, &stores[terrain.bands.items[band]], block_cells, band_counts[band]);
                band_counts[band] = 0;
            }
        }
        try ensureBlockedSlots(self, &terrain.blocked, slot_count);
        run_start = run_end;
    }

    // Commit. Every chunk a write may split takes its block and slot here, so the
    // write stage never takes or releases pool entries; each group's event window
    // starts at its writes' prefix offset.
    var offset: usize = 0;
    for (groups, 0..) |*group, group_index| {
        const terrain = &levels[group.level];
        const claims = groupBandBits(masks, mask_words, group_index, true);
        var cursor: u32 = 0;
        while (claims.next(cursor)) |band| : (cursor = band + 1) stores[terrain.bands.items[band]].claimChunk(block_cells, group.chunk);
        if (group.plan.slot_form != .mixed) terrain.blocked.claimChunk(group.chunk);
        group.start = offset;
        group.change_count = 0;
        offset += group.writes.len;
    }
    scratch.finals.items.len = participant_count * finals_stride;
    scratch.touched.items.len = participant_count * touched_stride;
    scratch.owned.items.len = participant_count * owned_stride;
    scratch.written_bands.items.len = participant_count * written_bands_stride;
    const event_windows = events.unusedCapacitySlice()[0..write_count];
    var write_job = DenseEditWriteJob{
        .geom = geom,
        .width = self.width,
        .groups = groups,
        .masks = masks,
        .mask_words = mask_words,
        .events = event_windows,
        .finals = scratch.finals.items,
        .finals_stride = finals_stride,
        .touched = scratch.touched.items,
        .touched_stride = touched_stride,
        .owned = scratch.owned.items,
        .owned_stride = owned_stride,
        .written_bands = scratch.written_bands.items,
        .written_bands_stride = written_bands_stride,
        .participant_count = participant_count,
        .stores = stores,
        .layer_bands = rows.items(.band),
        .levels = levels,
        .catalog_flags = self.catalog_flags.items,
        .range_count = 1,
    };
    const write_batch = runStage(if (stage_threads) |stage| stage.write() else null, groups.len, 1, &write_job, &write_job.range_count, denseEditWriteJob);
    if (comptime runtime_perf_log.enabled) self.perf.last_terrain_edit_write_batch = write_batch;

    // Ordered merge: compact the event windows in group order (each window starts
    // at or after the merged length), flag the resident written layers of each
    // group that changed a cell, then return chunks left uniform to the pools.
    const render_changed = rows.items(.render_changed);
    var merged: usize = 0;
    for (groups, 0..) |group, group_index| {
        const window = event_windows[group.start..][0..group.change_count];
        if (merged != group.start) @memmove(event_windows[merged..][0..window.len], window);
        merged += window.len;
        if (group.change_count == 0) continue;
        const written = groupBandBits(masks, mask_words, group_index, false);
        var cursor: u32 = 0;
        while (written.next(cursor)) |band| : (cursor = band + 1) world_render.markRenderChanged(self, gpu_slots, render_changed, levels[group.level].bands.items[band], group.chunk);
    }
    events.items.len += merged;
    for (groups, 0..) |group, group_index| {
        const terrain = &levels[group.level];
        const written = groupBandBits(masks, mask_words, group_index, false);
        var cursor: u32 = 0;
        while (written.next(cursor)) |band| : (cursor = band + 1) stores[terrain.bands.items[band]].releaseIfUniform(group.chunk);
        terrain.blocked.releaseIfUniform(geom, group.chunk);
    }
}

/// Groups dense cell writes given in any order into `applyDenseCellWrites` entries:
/// one per (level, chunk) touched, strictly increasing in (level, chunk), each holding
/// its chunk's writes in input order. `out_writes` receives the regrouped writes and
/// backs the entries; `next` is per-write chain scratch; each holds `writes.len`, and
/// `out_chunks` as many entries. Every write's layer and cell must be valid
/// (asserted). O(1) per write (a link into its level's chain, then into its chunk's,
/// and ordered-set marks) and per touched chunk and level (ordered pops), never a
/// level's chunk count; allocation-free, and leaves the grouping scratch empty.
// SIMD verdict: scalar. Per-write chain links and ordered-set inserts and pops.
pub fn groupDenseCellWrites(
    self: *WorldSystem,
    writes: []const DenseCellWrite,
    next: []u32,
    out_writes: []DenseCellWrite,
    out_chunks: []DenseChunkWrites,
) []DenseChunkWrites {
    std.debug.assert(next.len >= writes.len and out_writes.len >= writes.len and out_chunks.len >= writes.len);
    if (writes.len == 0) return out_chunks[0..0];
    const geom = self.chunkGeometry();
    const layer_levels = self.dense_layers.items(.level_index);
    const levels = self.level_terrain.items;
    const level_heads = self.edit_level_heads.items;
    const level_tails = self.edit_level_tails.items;
    const chunk_heads = self.edit_chunk_heads;
    const chunk_tails = self.edit_chunk_tails;
    // Each level's writes, chained in input order.
    for (writes, 0..) |write, index| {
        std.debug.assert(write.layer < layer_levels.len and write.x < geom.width and write.y < geom.height);
        const level = layer_levels[write.layer];
        // Write indices stay below the batch length, which the caller's u32 chains bound.
        const item: u32 = @intCast(index);
        next[index] = no_edit_write;
        if (level_heads[level] == no_edit_write) {
            self.edit_levels.insert(level);
            level_heads[level] = item;
        } else {
            next[level_tails[level]] = item;
        }
        level_tails[level] = item;
    }
    var chunk_count: usize = 0;
    var written: usize = 0;
    while (self.edit_levels.popMin()) |level_index| {
        const terrain = &levels[level_index];
        // Relink the level's chain into per-chunk chains through the shared chunk ends;
        // each write's next is read before it is relinked.
        var item = level_heads[level_index];
        level_heads[level_index] = no_edit_write;
        while (item != no_edit_write) {
            const following = next[item];
            const write = writes[item];
            const chunk = geom.chunkOf(write.x, write.y);
            next[item] = no_edit_write;
            if (chunk_heads[chunk] == no_edit_write) {
                terrain.edit_chunks.insert(chunk);
                chunk_heads[chunk] = item;
            } else {
                next[chunk_tails[chunk]] = item;
            }
            chunk_tails[chunk] = item;
            item = following;
        }
        while (terrain.edit_chunks.popMin()) |chunk_index| {
            // Below the level's chunk count, which fits u32.
            const chunk: u32 = @intCast(chunk_index);
            const start = written;
            var chained = chunk_heads[chunk];
            while (chained != no_edit_write) : (chained = next[chained]) {
                out_writes[written] = writes[chained];
                written += 1;
            }
            chunk_heads[chunk] = no_edit_write;
            out_chunks[chunk_count] = .{
                // Below the level count and the u16-wide chunk grid.
                .level = @intCast(level_index),
                .chunk_x = @intCast(chunk % geom.chunks_x),
                .chunk_y = @intCast(chunk / geom.chunks_x),
                .writes = out_writes[start..written],
            };
            chunk_count += 1;
        }
    }
    std.debug.assert(written == writes.len);
    return out_chunks[0..chunk_count];
}

/// Reserves the scratch `applyDenseCellWrites(chunks, threads, _)` uses (its groups,
/// band masks, and per-participant write buffers), so a caller can take the batch's
/// scratch growth at its own reserve seam; the batch's pool growth stays at its own
/// reserve. Counted; changes no terrain. O(chunks).
pub fn reserveDenseCellWrites(self: *WorldSystem, chunks: []const DenseChunkWrites, threads: ?TerrainEditThreads) error{ InvalidWorldLevel, OutOfMemory }!void {
    if (chunks.len == 0) return;
    const levels = self.level_terrain.items;
    var band_stride: usize = 0;
    for (chunks) |entry| {
        if (entry.level >= levels.len) return error.InvalidWorldLevel;
        band_stride = @max(band_stride, levels[entry.level].bandLayers().len);
    }
    try ensureDenseEditCapacity(self, &self.dense_edit.groups, chunks.len);
    const stage_threads: ?TerrainEditThreads = if (chunks.len > 1) threads else null;
    const participant_count = if (stage_threads) |stage| stage.thread_system.participantSlotCount() else 1;
    try reserveDenseEditScratch(self, chunks.len, DenseEditStrides.of(band_stride), participant_count);
}

// The batched edit's scratch for `group_count` groups whose widest level has the
// strides' bands, over `participant_count` participants.
fn reserveDenseEditScratch(self: *WorldSystem, group_count: usize, strides: DenseEditStrides, participant_count: usize) error{OutOfMemory}!void {
    const scratch = &self.dense_edit;
    try ensureDenseEditCapacity(self, &scratch.masks, group_count * 2 * strides.mask_words);
    try ensureDenseEditCapacity(self, &scratch.finals, participant_count * strides.finals);
    try ensureDenseEditCapacity(self, &scratch.touched, participant_count * strides.touched);
    try ensureDenseEditCapacity(self, &scratch.owned, participant_count * strides.owned);
    try ensureDenseEditCapacity(self, &scratch.written_bands, participant_count * strides.written_bands);
    try ensureDenseEditCapacity(self, &scratch.band_counts, strides.bands);
}

// One batched-edit scratch list's growth seam: geometric, its first growth logged once.
fn ensureDenseEditCapacity(self: *WorldSystem, list: anytype, needed: usize) error{OutOfMemory}!void {
    if (list.capacity >= needed) return;
    try list.ensureTotalCapacity(self.allocator, needed);
    if (self.dense_edit_scratch_growth_logged) return;
    self.dense_edit_scratch_growth_logged = true;
    if (comptime logging.enabled(.info)) log.info("batched terrain edit scratch grew to {d}", .{list.capacity});
}

// The terrain pools' reserve seams: each counts a reserve that grew its pool.
fn ensureDenseBlocks(self: *WorldSystem, store: *DenseLayerStore, block_cells: usize, count: usize) error{OutOfMemory}!void {
    if (try store.ensureAvailable(self.allocator, block_cells, count)) countTerrainPoolGrowth(self);
}

fn ensureBlockedSlots(self: *WorldSystem, blocked: *ChunkBitsStore, count: usize) error{OutOfMemory}!void {
    if (try blocked.ensureAvailable(self.allocator, count)) countTerrainPoolGrowth(self);
}

fn countTerrainPoolGrowth(self: *WorldSystem) void {
    @branchHint(.cold);
    if (comptime runtime_perf_log.enabled) self.perf.terrain_pool_grows += 1;
    if (self.terrain_pool_growth_logged) return;
    self.terrain_pool_growth_logged = true;
    if (comptime logging.enabled(.info)) log.info(
        "terrain pools grew at their reserve seam ({d} dense layers, {d} levels)",
        .{ self.dense_layers.len, self.level_terrain.items.len },
    );
}

// The cell's composed movement-blocked bit with `layer_index` holding `tile_id`:
// OR over the level's bands, then the chunk's sparse tiles at this cell.
// O(bands + sparse tiles in the chunk).
fn composedBlockedWith(self: *const WorldSystem, level: u16, x: u16, y: u16, layer_index: usize, tile_id: TileId) bool {
    const geom = self.chunkGeometry();
    const stores = self.dense_layers.items(.store);
    for (self.level_terrain.items[level].bandLayers()) |band_layer| {
        const tile = if (band_layer == layer_index) tile_id else stores[band_layer].tile(geom, x, y);
        if (self.flagsFor(tile).blocks_movement) return true;
    }
    return sparseBlocksCell(self, level, geom.chunkOf(x, y), self.cellIndex(x, y));
}

fn sparseBlocksCell(self: *const WorldSystem, level: u16, chunk: u32, cell: u32) bool {
    const run = self.level_terrain.items[level].sparse_runs[chunk];
    if (run.rows.len == 0) return false;
    const sparse = run.rows.slice();
    const sparse_cells = sparse.items(.cell_index);
    const sparse_flags = sparse.items(.flags);
    for (sparse_cells, sparse_flags) |row_cell, row_flags| {
        if (row_cell == cell and row_flags.blocks_movement) return true;
    }
    return false;
}

// This chunk's capacity doubled, or null when the double does not fit in `usize`.
// Exact: `MultiArrayList.growCapacity` adds a cache-line floor, so a one-row chunk
// would keep more slots than the double.
fn doubledSparseCapacity(capacity: usize) ?usize {
    if (capacity == 0) return 1;
    if (capacity > std.math.maxInt(usize) / 2) return null;
    return capacity * 2;
}

fn reserveSparseBlockedSlot(self: *WorldSystem, blocked: *ChunkBitsStore, chunk: u32, local: u8, blocks: bool) error{OutOfMemory}!void {
    if (blocks and blocked.setNeedsSlot(chunk, local, true)) try ensureBlockedSlots(self, blocked, 1);
}

// Writes the new row into the run's spare slot. The slot and, when the tile
// blocks, the composed-bits slot are already reserved. The window dirties only
// when the new tile is in it.
fn commitSparseRow(
    self: *WorldSystem,
    level: u16,
    chunk: u32,
    cell: u32,
    tile_id: TileId,
    world_z: i32,
    flags: TileFlags,
    x: u16,
    y: u16,
    geom: ChunkGeometry,
    local_cell: u8,
) void {
    const run = &self.level_terrain.items[level].sparse_runs[chunk];
    std.debug.assert(run.rows.len < run.rows.capacity);
    run.rows.appendAssumeCapacity(.{
        .level_index = level,
        .cell_index = cell,
        .tile_id = tile_id,
        .depth_value = world_z,
        .flags = flags,
    });
    self.sparse_live += 1;
    if (flags.blocks_movement) self.level_terrain.items[level].blocked.set(geom, chunk, local_cell, true);
    if (world_render.sparseTileInWindow(self, level, x, y)) self.sparse_window.dirty = true;
}

pub fn addSparseTile(
    self: *WorldSystem,
    level_index: u16,
    x: u16,
    y: u16,
    tile_id: TileId,
    base_z: i32,
    depth: WorldDepth,
) WorldEditError!?WorldObstacleChangedEvent {
    try self.validateLevelIndex(level_index);
    try self.validateTileId(tile_id);
    if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
    const cell = self.cellIndex(x, y);
    const flags = self.flagsFor(tile_id);
    const world_z = self.worldZForLevel(level_index, base_z, depth);

    // Reserve the row and the level's composed bits before committing either: an
    // OOM leaves the tile in no structure, so every lookup (nav rebuild,
    // levelBlocksMovement and the LOS that reads it) agrees.
    const geom = self.chunkGeometry();
    const chunk = geom.chunkOf(x, y);
    const local_cell = geom.localOf(x, y);
    const blocked = &self.level_terrain.items[level_index].blocked;
    // The population stays below the u32 cap. At the cap the add fails before any
    // reserve, the same as exhausting it.
    if (self.sparse_live == no_sparse_tile) return error.OutOfMemory;

    const run = &self.level_terrain.items[level_index].sparse_runs[chunk];
    if (run.rows.len < run.rows.capacity) {
        try reserveSparseBlockedSlot(self, blocked, chunk, local_cell, flags.blocks_movement);
        commitSparseRow(self, level_index, chunk, cell, tile_id, world_z, flags, x, y, geom, local_cell);
    } else {
        const new_capacity = doubledSparseCapacity(run.rows.capacity) orelse return error.OutOfMemory;
        const was_empty = run.rows.len == 0;
        try run.rows.setCapacity(self.allocator, new_capacity);
        // A failed composed-bits reserve must not leave an empty chunk holding the
        // new buffer. A chunk that already had rows keeps the grown capacity.
        errdefer if (was_empty) run.rows.clearAndFree(self.allocator);
        try reserveSparseBlockedSlot(self, blocked, chunk, local_cell, flags.blocks_movement);
        commitSparseRow(self, level_index, chunk, cell, tile_id, world_z, flags, x, y, geom, local_cell);
    }
    if (!flags.blocks_movement) return null;
    return .{
        .level = level_index,
        .min_x = x,
        .min_y = y,
        .max_x_exclusive = @min(self.width, x +| 1),
        .max_y_exclusive = @min(self.height, y +| 1),
    };
}

/// Reserves what `clearCellBlocking(level_index, x, y, floor_tile)` writes, in the
/// current reserve scope (`beginDenseCellWriteReserve`): a tile block for each
/// band whose blocking tile sits in a uniform chunk, and the composed-bits slot
/// when the cell is blocked in a uniform chunk. Reads are unchanged; an OOM
/// leaves the world's contents as they were. O(bands + sparse tiles in the chunk),
/// plus a one-time O(edge²) block per band and pool growth.
pub fn reserveClearCellBlocking(self: *WorldSystem, level_index: u16, x: u16, y: u16, floor_tile: TileId) WorldEditError!void {
    try self.validateLevelIndex(level_index);
    if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
    try self.validateTileId(floor_tile);
    // A blocking floor tile would leave the cell blocked.
    if (self.flagsFor(floor_tile).blocks_movement) return error.InvalidWorldTile;
    if (!cellComposedBlocked(self, level_index, x, y)) return;

    const geom = self.chunkGeometry();
    const chunk = geom.chunkOf(x, y);
    const stores = self.dense_layers.items(.store);
    const floor_layer = self.denseFloorLayerForLevel(level_index);
    const terrain = &self.level_terrain.items[level_index];
    var block_count: usize = 0;
    var render_marks: usize = 0;
    const gpu_slots = self.dense_layers.items(.gpu_slot);
    const chunk_x = chunk % geom.chunks_x;
    const chunk_y = chunk / geom.chunks_x;
    for (terrain.bandLayers()) |layer| {
        if (!self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) continue;
        block_count += @intFromBool(stores[layer].writeNeedsBlock(chunk, clearedBandTile(layer, floor_layer, floor_tile)));
        render_marks += @intFromBool(self.gpu_tiles.changedChunkIsNew(gpu_slots[layer], chunk_x, chunk_y));
    }
    const needs_slot = terrain.blocked.setNeedsSlot(chunk, geom.localOf(x, y), false);

    // Fallible growth first; each materialized chunk is recorded for the scope.
    try self.dense_reserved_chunks.ensureUnusedCapacity(self.allocator, block_count + @intFromBool(needs_slot));
    try self.gpu_tiles.reserveChangedChunks(self.allocator, render_marks);
    for (terrain.bandLayers()) |layer| {
        if (!self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) continue;
        if (!stores[layer].writeNeedsBlock(chunk, clearedBandTile(layer, floor_layer, floor_tile))) continue;
        try ensureDenseBlocks(self, &stores[layer], geom.blockCells(), 1);
        stores[layer].materializeChunk(geom.blockCells(), chunk);
        self.dense_reserved_chunks.appendAssumeCapacity(.{ .kind = .dense_block, .owner = layer, .chunk = chunk });
    }
    if (needs_slot) {
        try ensureBlockedSlots(self, &terrain.blocked, 1);
        terrain.blocked.materializeChunk(geom, chunk);
        self.dense_reserved_chunks.appendAssumeCapacity(.{ .kind = .blocked_slot, .owner = level_index, .chunk = chunk });
    }
}

/// Makes one cell walkable: each band whose tile blocks movement is cleared (the
/// level's floor band to the non-blocking `floor_tile`, any other band to empty)
/// and each blocking sparse tile in the cell is removed; non-blocking content, an
/// empty floor included, stays. Returns a 1x1 obstacle event when anything
/// changed, else null. Reserves first, so an OOM changes nothing; allocation-free
/// after `reserveClearCellBlocking` for this cell. O(bands + sparse tiles in the
/// chunk).
pub fn clearCellBlocking(self: *WorldSystem, level_index: u16, x: u16, y: u16, floor_tile: TileId) WorldEditError!?WorldObstacleChangedEvent {
    try reserveClearCellBlocking(self, level_index, x, y, floor_tile);
    const geom = self.chunkGeometry();
    const chunk = geom.chunkOf(x, y);
    const rows = self.dense_layers.slice();
    const stores = rows.items(.store);
    const gpu_slots = rows.items(.gpu_slot);
    const render_changed = rows.items(.render_changed);
    const floor_layer = self.denseFloorLayerForLevel(level_index);
    var changed = false;
    for (self.level_terrain.items[level_index].bandLayers()) |layer| {
        if (!self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) continue;
        stores[layer].write(geom, chunk, geom.localOf(x, y), clearedBandTile(layer, floor_layer, floor_tile));
        world_render.markRenderChanged(self, gpu_slots, render_changed, layer, chunk);
        changed = true;
    }

    // A removal copies the run's last live row onto this offset, so the walk
    // reads that offset again and does not skip the row just swapped in.
    // The slice ends before the free: at len 0 the run releases its buffer.
    const cell = self.cellIndex(x, y);
    const run = &self.level_terrain.items[level_index].sparse_runs[chunk];
    if (run.rows.len != 0) {
        const sparse = run.rows.slice();
        const sparse_cells = sparse.items(.cell_index);
        const sparse_flags = sparse.items(.flags);
        var offset: usize = 0;
        while (offset < run.rows.len) {
            if (sparse_cells[offset] != cell or !sparse_flags[offset].blocks_movement) {
                offset += 1;
                continue;
            }
            removeSparseTile(self, level_index, chunk, offset);
            changed = true;
        }
    }
    if (run.rows.len == 0) run.rows.clearAndFree(self.allocator);
    if (!changed) return null;

    const composed = cellComposedBlocked(self, level_index, x, y);
    std.debug.assert(!composed);
    self.level_terrain.items[level_index].blocked.set(geom, chunk, geom.localOf(x, y), composed);
    return .{
        .level = level_index,
        .min_x = x,
        .min_y = y,
        .max_x_exclusive = x + 1,
        .max_y_exclusive = y + 1,
    };
}

// The tile a cleared blocking band takes: the floor tile on the floor band,
// empty on any other band.
fn clearedBandTile(layer: u32, floor_layer: ?usize, floor_tile: TileId) TileId {
    const floor = floor_layer orelse return invalid_tile_id;
    return if (floor == layer) floor_tile else invalid_tile_id;
}

// Drops the live row at `offset`. The last live row moves onto it. Capacity
// stays; the caller frees the run at len 0. The window dirties only when the
// removed tile is in it: a swapped survivor does not change draw order.
// O(1), allocation-free.
fn removeSparseTile(self: *WorldSystem, level: u16, chunk: u32, offset: usize) void {
    const run = &self.level_terrain.items[level].sparse_runs[chunk];
    std.debug.assert(offset < run.rows.len);
    std.debug.assert(self.sparse_live > 0);
    const rows = run.rows.slice();
    const removed_coord = cellCoordOf(self, rows.items(.cell_index)[offset]);
    if (world_render.sparseTileInWindow(self, level, removed_coord.x, removed_coord.y)) self.sparse_window.dirty = true;
    run.rows.swapRemove(offset);
    self.sparse_live -= 1;
}

// The cell's composed movement-blocked bit from its bands and sparse tiles as
// they stand. O(bands + sparse tiles in the chunk).
fn cellComposedBlocked(self: *const WorldSystem, level: u16, x: u16, y: u16) bool {
    const geom = self.chunkGeometry();
    const stores = self.dense_layers.items(.store);
    for (self.level_terrain.items[level].bandLayers()) |layer| {
        if (self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) return true;
    }
    return sparseBlocksCell(self, level, geom.chunkOf(x, y), self.cellIndex(x, y));
}

// Tile-cell coordinate of a cell index (below width * height, so both fit u16).
pub fn cellCoordOf(self: *const WorldSystem, cell: u32) CellCoord {
    return .{ .x = @intCast(cell % self.width), .y = @intCast(cell / self.width) };
}

fn denseEditPlanJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *DenseEditPlanJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.groups.len);
    std.debug.assert(job.masks.len == job.groups.len * 2 * job.mask_words);
    for (range.start..range.end) |group_index| planDenseEditGroup(job, group_index);
}

// Validates one group's writes and derives its plan and band bits; read-only over
// the world. O(writes + mask words).
// SIMD verdict: scalar. Branchy per-write validation with an early break and per-run
// directory lookups.
fn planDenseEditGroup(job: *const DenseEditPlanJob, group_index: usize) void {
    const geom = job.geom;
    const group = &job.groups[group_index];
    const terrain = &job.levels[group.level];
    const written = groupBandBits(job.masks, job.mask_words, group_index, false);
    const claims = groupBandBits(job.masks, job.mask_words, group_index, true);
    @memset(written.words, 0);
    @memset(claims.words, 0);
    var plan = DenseEditPlan{ .slot_form = terrain.blocked.form(group.chunk) };
    var run_layer: u32 = std.math.maxInt(u32);
    var run_band: u32 = 0;
    var run_uniform: ?TileId = null;
    var run_claimed = false;
    for (group.writes) |write| {
        if (write.layer >= job.layer_levels.len or job.layer_levels[write.layer] != group.level) {
            plan.status = .invalid_layer;
            break;
        }
        if (write.x >= geom.width or write.y >= geom.height or geom.chunkOf(write.x, write.y) != group.chunk) {
            plan.status = .invalid_cell;
            break;
        }
        if (write.tile != invalid_tile_id and !catalogValid(job.catalog_valid, write.tile)) {
            plan.status = .invalid_tile;
            break;
        }
        // Runs of writes on one layer look its band and uniform tile up once.
        if (write.layer != run_layer) {
            run_layer = write.layer;
            run_band = job.layer_bands[write.layer];
            // The plan stage mutates nothing, so this is the chunk's form before the batch.
            run_uniform = job.stores[write.layer].uniformTile(group.chunk);
            run_claimed = false;
            written.set(run_band);
        }
        if (run_claimed) continue;
        if (run_uniform) |tile| {
            if (tile != write.tile) {
                claims.set(run_band);
                run_claimed = true;
            }
        }
    }
    group.plan = plan;
}

fn denseEditWriteJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *DenseEditWriteJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.groups.len);
    // Scratch was reserved for every participant before dispatch.
    std.debug.assert(worker_id.index < job.participant_count);
    for (range.start..range.end) |group_index| writeDenseEditGroup(job, group_index, worker_id.index);
}

// Applies one group's writes: fills its claimed blocks and slot, then writes each
// touched cell's last write per band, recomposing its blocked bit and recording
// events at the head of the group's window in local-cell then band order.
fn writeDenseEditGroup(job: *const DenseEditWriteJob, group_index: usize, participant: usize) void {
    const geom = job.geom;
    const block_cells = geom.blockCells();
    const group = &job.groups[group_index];
    const terrain = &job.levels[group.level];
    const bands = terrain.bandLayers();
    const chunk = group.chunk;
    const plan = group.plan;
    const extent = geom.extent(chunk);
    const sparse_blocked = sparseBlockedBits(job, geom, group.level, chunk);
    const written = groupBandBits(job.masks, job.mask_words, group_index, false);
    const claims = groupBandBits(job.masks, job.mask_words, group_index, true);
    std.debug.assert(bands.len * max_chunk_cells <= job.finals_stride);
    std.debug.assert(bands.len <= job.touched_stride);
    std.debug.assert(bands.len <= job.owned_stride);
    std.debug.assert(group.start + group.writes.len <= job.events.len);
    std.debug.assert(bands.len <= job.written_bands_stride);
    std.debug.assert((participant + 1) * job.owned_stride <= job.owned.len);
    std.debug.assert((participant + 1) * job.written_bands_stride <= job.written_bands.len);
    const finals = job.finals[participant * job.finals_stride ..][0..job.finals_stride];
    const touched = job.touched[participant * job.touched_stride ..][0..job.touched_stride];
    // Every written band's block, or null for a uniform band no write changes.
    const blocks = job.owned[participant * job.owned_stride ..][0..job.owned_stride];
    // The written bands, listed once so the per-cell loop walks only them.
    const band_slots = job.written_bands[participant * job.written_bands_stride ..][0..job.written_bands_stride];
    var written_count: usize = 0;
    var cursor: u32 = 0;
    while (written.next(cursor)) |band| : (cursor = band + 1) {
        band_slots[written_count] = band;
        written_count += 1;
    }
    const written_list = band_slots[0..written_count];

    for (written_list) |band| {
        touched[band] = @splat(0);
        blocks[band] = job.stores[bands[band]].ownBlock(geom, chunk);
        if (claims.isSet(band)) blocks[band].?.fillFresh();
    }
    var blocked = terrain.blocked.ownSlot(chunk);
    if (plan.slot_form != .mixed) blocked.fillUniform(geom, chunk, plan.slot_form == .blocked);

    // SIMD verdict: scalar. Scattered per-write stores into the band's finals and bits.
    for (group.writes) |write| {
        const band = job.layer_bands[write.layer];
        const local = geom.localOf(write.x, write.y);
        finals[@as(usize, band) * max_chunk_cells + local] = write.tile;
        world_terrain.setBit(&touched[band], local);
    }
    var any_touched: ChunkBits = @splat(0);
    for (written_list) |band| {
        for (&any_touched, touched[band]) |*word, band_word| word.* |= band_word;
    }

    const events = job.events[group.start..][0..group.writes.len];
    var change_count: usize = 0;
    const edge_mask: u32 = geom.chunk_tiles - 1;
    // SIMD verdict: scalar. Set-bit iteration over touched cells with a branchy
    // per-band compare and event write per changed cell.
    for (any_touched, 0..) |touched_word, word_index| {
        var word = touched_word;
        while (word != 0) : (word &= word - 1) {
            const local: u32 = @intCast(word_index * 64 + @ctz(word));
            const x: u16 = extent.min_x + @as(u16, @intCast(local & edge_mask));
            const y: u16 = extent.min_y + @as(u16, @intCast(local >> geom.shift));
            var cell_changed = false;
            for (written_list) |band| {
                if (!world_terrain.bitIsSet(&touched[band], local)) continue;
                const layer = bands[band];
                const old_tile = job.stores[layer].chunkTile(block_cells, chunk, local);
                const new_tile = finals[@as(usize, band) * max_chunk_cells + local];
                if (old_tile == new_tile) continue;
                // A write that changes a cell of a uniform chunk had its block claimed.
                blocks[band].?.write(local, new_tile);
                events[change_count] = .{
                    .level = group.level,
                    .x = x,
                    .y = y,
                    .old_tile_id = old_tile,
                    .new_tile_id = new_tile,
                    .old_blocks_movement = catalogFlags(job.catalog_flags, old_tile).blocks_movement,
                    .new_blocks_movement = catalogFlags(job.catalog_flags, new_tile).blocks_movement,
                };
                change_count += 1;
                cell_changed = true;
            }
            if (cell_changed) blocked.set(local, composedBlockedCell(job, bands, chunk, local, &sparse_blocked));
        }
    }
    for (written_list) |band| {
        if (blocks[band]) |owned| owned.finish();
    }
    blocked.finish();
    group.change_count = change_count;
}

// A cell's composed movement-blocked bit after the write stage's writes: OR over
// the level's `bands`, then the cell's bit in the chunk's `sparse_blocked`; the same
// rule as `composedBlockedWith`, kept separate for the per-changed-cell cost. O(bands).
fn composedBlockedCell(job: *const DenseEditWriteJob, bands: []const u32, chunk: u32, local: u32, sparse_blocked: *const ChunkBits) bool {
    const block_cells = job.geom.blockCells();
    for (bands) |layer| {
        if (catalogFlags(job.catalog_flags, job.stores[layer].chunkTile(block_cells, chunk, local)).blocks_movement) return true;
    }
    return world_terrain.bitIsSet(sparse_blocked, local);
}

// The chunk-local cells of `level`'s `chunk` that hold a movement-blocking sparse
// tile, built once per group so each changed cell tests one bit. O(sparse tiles in
// the chunk).
// SIMD verdict: scalar. A bit scatter with a skip of non-blocking rows, not uniform float math.
fn sparseBlockedBits(job: *const DenseEditWriteJob, geom: ChunkGeometry, level: u16, chunk: u32) ChunkBits {
    var bits: ChunkBits = @splat(0);
    const run = job.levels[level].sparse_runs[chunk];
    if (run.rows.len == 0) return bits;
    const rows = run.rows.slice();
    const sparse_flags = rows.items(.flags);
    const sparse_cells = rows.items(.cell_index);
    for (sparse_flags, sparse_cells) |row_flags, cell| {
        if (!row_flags.blocks_movement) continue;
        // A cell index is below width * height, so both coordinates fit u16.
        const x: u16 = @intCast(cell % job.width);
        const y: u16 = @intCast(cell / job.width);
        std.debug.assert(geom.chunkOf(x, y) == chunk);
        world_terrain.setBit(&bits, geom.localOf(x, y));
    }
    return bits;
}

const TileStoreSpan = @import("../../render/renderer.zig").TileStoreSpan;
const TestGpuStore = @import("test_support.zig").TestGpuStore;
const testSyncGpuTiles = @import("test_support.zig").testSyncGpuTiles;
const testApplySync = @import("test_support.zig").testApplySync;
const testGpuTile = @import("test_support.zig").testGpuTile;
const expectGpuStoreMatches = @import("test_support.zig").expectGpuStoreMatches;
const expectSparseIndexConsistent = @import("test_support.zig").expectSparseIndexConsistent;
const sparseTileCellCoord = @import("test_support.zig").sparseTileCellCoord;
const WorldTilesetMeta = @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const testWorldMeta = @import("test_support.zig").testWorldMeta;
const testMinimalSurfaceWorld = @import("test_support.zig").testMinimalSurfaceWorld;
const bruteForceLevelBlocked = @import("test_support.zig").bruteForceLevelBlocked;
const TerrainTestTiles = @import("test_support.zig").TerrainTestTiles;
const level_z_step = @import("system.zig").level_z_step;
const world_gpu_tiles = @import("gpu_tiles.zig");

fn cellCount(world: *const WorldSystem) usize {
    return @as(usize, world.width) * @as(usize, world.height);
}

const liveBlockCount = @import("test_support.zig").liveBlockCount;
const liveSlotCount = @import("test_support.zig").liveSlotCount;
const chunkBlockedCount = @import("test_support.zig").chunkBlockedCount;

test "reserveDenseCellWrite covers N writes across uniform chunks on a resident layer (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 28x4 tiles, 4-tile chunks: seven chunks in a row, all resident. Fifteen cells
    // of the first chunk (one left, so it stays mixed) plus one cell in each of the
    // next five: six distinct chunks. The changed-chunk list's first growth is 5,
    // so three chunks still fit without a stacked reserve and the sixth does not.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 28,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(level, 0, .floor, grass);
    // Resident in the GPU tile store, so every write also reaches the GPU.
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);

    var writes: [20][2]u16 = undefined;
    var write_count: usize = 0;
    for (0..4) |y| for (0..4) |x| {
        if (x == 3 and y == 3) continue;
        writes[write_count] = .{ @intCast(x), @intCast(y) };
        write_count += 1;
    };
    for (1..6) |chunk_x| {
        writes[write_count] = .{ @intCast(chunk_x * 4), 0 };
        write_count += 1;
    }
    std.debug.assert(write_count == writes.len);
    world.beginDenseCellWriteReserve();
    for (writes) |cell| try world.reserveDenseCellWrite(layer, cell[0], cell[1], water);
    // Reads are unchanged by the reserve.
    for (writes) |cell| {
        try std.testing.expectEqual(grass, world.denseTile(layer, cell[0], cell[1]));
        try std.testing.expect(!world.levelBlocksMovement(level, cell[0], cell[1]));
    }
    // One block, one slot, and one GPU list slot per distinct chunk, not per cell.
    // The list length has not moved; the slots are only reserved.
    try std.testing.expectEqual(@as(usize, 6), liveBlockCount(world.dense_layers.items(.store)[layer]));
    try std.testing.expectEqual(@as(usize, 6), liveSlotCount(world.level_terrain.items[level].blocked));
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.changed_chunks.items.len);
    try std.testing.expectEqual(@as(usize, 6), world.gpu_tiles.changed_held);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        for (writes) |cell| _ = try world.setDenseTile(layer, cell[0], cell[1], water);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    for (writes) |cell| try std.testing.expect(world.levelBlocksMovement(level, cell[0], cell[1]));
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);

    // A reserve whose write never comes leaves only an early block, which the next
    // scope returns to uniform.
    world.beginDenseCellWriteReserve();
    try world.reserveDenseCellWrite(layer, 24, 0, water);
    try std.testing.expectEqual(@as(?TileId, null), world.dense_layers.items(.store)[layer].uniformTile(6));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(level, 6));
    world.beginDenseCellWriteReserve();
    try std.testing.expectEqual(@as(?TileId, grass), world.dense_layers.items(.store)[layer].uniformTile(6));
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 6));
    try std.testing.expectEqual(@as(usize, 6), liveBlockCount(world.dense_layers.items(.store)[layer]));

    // Reserving a write that changes nothing reserves nothing.
    try world.reserveDenseCellWrite(layer, 0, 0, water);
    try std.testing.expectEqual(@as(usize, 0), world.dense_reserved_chunks.items.len);
}

test "writeDenseTileCell reserves its growth before mutating CPU tiles (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(level, 0, .floor, grass);

    // Resident in the GPU tile store, so a change also flags the layer.
    _ = try testSyncGpuTiles(&world, level);

    const old_tile = world.denseTile(layer, 1, 1);
    try std.testing.expectEqual(grass, old_tile);
    try std.testing.expectEqual(@as(?TileId, grass), world.dense_layers.items(.store)[layer].uniformTile(0));
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));

    // The changed-chunk list is empty, so its reserve fails before any tile write.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, world.setDenseTile(layer, 1, 1, water));
        try std.testing.expectEqual(old_tile, world.denseTile(layer, 1, 1));
        try std.testing.expectEqual(@as(?TileId, grass), world.dense_layers.items(.store)[layer].uniformTile(0));
        try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));
        try std.testing.expect(!world.levelBlocksMovement(level, 1, 1));
        try std.testing.expect(!world.dense_layers.items(.render_changed)[layer]);
        try std.testing.expect(!world.resident_layers_changed);
    }

    // One changed-chunk slot, so the next failures are the block pool and then,
    // warmed, the composed-bits slot. Each OOM leaves the tile and the render flag.
    try world.gpu_tiles.reserveChangedChunks(std.testing.allocator, 1);
    for (0..2) |warmed| {
        if (warmed == 1) _ = try world.dense_layers.items(.store)[layer].ensureAvailable(std.testing.allocator, world.chunkGeometry().blockCells(), 1);
        // Block remap (resize_fail_index) as well as fresh alloc: ArrayList growth
        // may succeed via remap without bumping fail_index's allocation count.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, world.setDenseTile(layer, 1, 1, water));
        try std.testing.expectEqual(old_tile, world.denseTile(layer, 1, 1));
        try std.testing.expectEqual(@as(?TileId, grass), world.dense_layers.items(.store)[layer].uniformTile(0));
        try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));
        try std.testing.expect(!world.levelBlocksMovement(level, 1, 1));
        try std.testing.expect(!world.dense_layers.items(.render_changed)[layer]);
        try std.testing.expect(!world.resident_layers_changed);
    }

    // Retry with a working allocator succeeds and is consistent.
    const changed = (try world.setDenseTile(layer, 1, 1, water)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(water, changed.new_tile_id);
    try std.testing.expectEqual(water, world.denseTile(layer, 1, 1));
    try std.testing.expectEqual(@as(?TileId, null), world.dense_layers.items(.store)[layer].uniformTile(0));
    try std.testing.expect(world.levelBlocksMovement(level, 1, 1));
    try std.testing.expect(world.dense_layers.items(.render_changed)[layer] and world.resident_layers_changed);
}

test "world dense tile mutation returns compact change event" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();

    const water = try world.requireTileByName(&meta, "water_1");
    const changed = (try world.setDenseTile(0, 1, 1, water)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), changed.level);
    try std.testing.expectEqual(@as(u16, 1), changed.x);
    try std.testing.expectEqual(@as(u16, 1), changed.y);
    try std.testing.expectEqual(water, changed.new_tile_id);
    try std.testing.expect(changed.old_blocks_movement != changed.new_blocks_movement);

    try std.testing.expect((try world.setDenseTile(0, 1, 1, water)) == null);
}

test "world sparse obstacle mutation returns obstacle event for blockers" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();

    const tree = try world.requireTileByName(&meta, "tree_0");
    const changed = (try world.addSparseTile(0, 2, 1, tree, 0, .obstacle)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), changed.level);
    try std.testing.expectEqual(@as(u16, 2), changed.min_x);
    try std.testing.expectEqual(@as(u16, 1), changed.min_y);
    try std.testing.expectEqual(@as(u16, 3), changed.max_x_exclusive);
    try std.testing.expectEqual(@as(u16, 2), changed.max_y_exclusive);
}

// Compares two index lists as sets: same members, order irrelevant. Copies
// into scratch so the caller's slices are never mutated by the sort.
fn expectSparseIndexSetEqual(expected: []const u32, actual: []const u32) !void {
    const expected_sorted = try std.testing.allocator.dupe(u32, expected);
    defer std.testing.allocator.free(expected_sorted);
    const actual_sorted = try std.testing.allocator.dupe(u32, actual);
    defer std.testing.allocator.free(actual_sorted);
    std.mem.sort(u32, expected_sorted, {}, std.sort.asc(u32));
    std.mem.sort(u32, actual_sorted, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, expected_sorted, actual_sorted);
}

// Chunk-local offsets of `level`'s live sparse rows, in chunk-run order, into `out`.
// Offsets restart at 0 in each chunk.
fn testLevelSparseRows(world: *const WorldSystem, level: u16, out: []u32) []u32 {
    if (@as(usize, level) >= world.level_terrain.items.len) return out[0..0];
    var count: usize = 0;
    for (world.level_terrain.items[level].sparse_runs) |run| {
        for (0..run.rows.len) |offset| {
            out[count] = @intCast(offset);
            count += 1;
        }
    }
    return out[0..count];
}

// Chunk-local offsets of (`level`, `chunk`)'s live rows, `[0, len)`, into `out`.
fn testChunkSparseRows(world: *const WorldSystem, level: u16, chunk: u32, out: []u32) []u32 {
    if (@as(usize, level) >= world.level_terrain.items.len) return out[0..0];
    const runs = world.level_terrain.items[level].sparse_runs;
    if (chunk >= runs.len) return out[0..0];
    const len = runs[chunk].rows.len;
    for (0..len) |offset| out[offset] = @intCast(offset);
    return out[0..len];
}

test "each chunk's sparse list holds exactly the level's tiles in that chunk" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const deco = try world.requireTileByName(&meta, "deco_0");

    // 4x4 tiles, chunk_size_tiles=2 -> 2x2 chunk grid; level-local chunk
    // offset = chunkY*2+chunkX, so (0,0)->0 (1,0)->1 (0,1)->2 (1,1)->3.
    _ = try world.addSparseTile(level0, 0, 0, deco, 0, .obstacle); // level0 chunk0
    _ = try world.addSparseTile(level0, 1, 1, deco, 0, .obstacle); // level0 chunk0
    _ = try world.addSparseTile(level0, 3, 0, deco, 0, .obstacle); // level0 chunk1
    _ = try world.addSparseTile(level0, 1, 3, deco, 0, .obstacle); // level0 chunk2
    // Level 1 reuses level-local chunk indices; its tiles stay in its own buckets.
    _ = try world.addSparseTile(level1, 2, 2, deco, 0, .obstacle); // level1 chunk3
    _ = try world.addSparseTile(level1, 0, 1, deco, 0, .obstacle); // level1 chunk0

    const chunks_x: u32 = 2;
    var level_buffer: [8]u32 = undefined;
    var level_cells: [8]u32 = undefined;
    var chunk_buffer: [8]u32 = undefined;
    var actual_cells: [8]u32 = undefined;
    for ([_]u16{ level0, level1 }) |level| {
        var level_count: usize = 0;
        var chunk: u32 = 0;
        while (chunk < 4) : (chunk += 1) {
            for (testChunkSparseRows(&world, level, chunk, &chunk_buffer)) |offset| {
                const cell = sparseTileCellCoord(&world, level, chunk, offset);
                level_cells[level_count] = world.cellIndex(cell.x, cell.y);
                level_count += 1;
            }
        }
        try std.testing.expectEqual(level_count, testLevelSparseRows(&world, level, &level_buffer).len);

        chunk = 0;
        while (chunk < 4) : (chunk += 1) {
            var expected: std.ArrayList(u32) = .empty;
            defer expected.deinit(std.testing.allocator);
            for (level_cells[0..level_count]) |cell| {
                const x: u32 = cell % world.width;
                const y: u32 = cell / world.width;
                const cell_chunk = (y / 2) * chunks_x + (x / 2);
                if (cell_chunk == chunk) try expected.append(std.testing.allocator, cell);
            }
            const offsets = testChunkSparseRows(&world, level, chunk, &chunk_buffer);
            for (offsets, 0..) |offset, index| {
                const cell = sparseTileCellCoord(&world, level, chunk, offset);
                actual_cells[index] = world.cellIndex(cell.x, cell.y);
            }
            try expectSparseIndexSetEqual(expected.items, actual_cells[0..offsets.len]);
        }
    }

    // Out-of-range level and out-of-range chunk both yield nothing.
    try expectSparseIndexSetEqual(&.{}, testChunkSparseRows(&world, 99, 0, &chunk_buffer));
    try expectSparseIndexSetEqual(&.{}, testChunkSparseRows(&world, level0, 99, &chunk_buffer));
}

test "addSparseTile reserves its row before publishing it, and a fresh chunk's first row allocates (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const level0 = try world.addLevel(0);
    const deco = try world.requireTileByName(&meta, "deco_0");
    const marker = try world.requireTileByName(&meta, "grass_patchy");

    // The first add fails its row allocation: nothing published, and the run holds no bytes.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level0, 0, 0, deco, 0, .obstacle));
        const run = world.level_terrain.items[level0].sparse_runs[0];
        try std.testing.expectEqual(@as(usize, 0), run.rows.len);
        try std.testing.expectEqual(@as(usize, 0), run.rows.capacity);
        try std.testing.expectEqual(@as(u32, 0), world.sparse_live);
    }
    // The row buffer allocated, then the composed-bits reserve failed: the empty
    // chunk releases that buffer and still publishes nothing.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level0, 0, 0, deco, 0, .obstacle));
        try std.testing.expect(failing.has_induced_failure);
        const run = world.level_terrain.items[level0].sparse_runs[0];
        try std.testing.expectEqual(@as(usize, 0), run.rows.len);
        try std.testing.expectEqual(@as(usize, 0), run.rows.capacity);
        try std.testing.expectEqual(@as(u32, 0), world.sparse_live);
    }

    // A fresh chunk's first row allocates. Three doubles then leave capacity 4, so
    // the fourth row in that chunk allocates nothing.
    _ = try world.addSparseTile(level0, 0, 0, deco, 0, .obstacle);
    try std.testing.expectEqual(@as(usize, 1), world.level_terrain.items[level0].sparse_runs[0].rows.capacity);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level0, 3, 3, marker, 0, .marker));
        try std.testing.expect(failing.has_induced_failure);
        const fresh = world.level_terrain.items[level0].sparse_runs[3];
        try std.testing.expectEqual(@as(usize, 0), fresh.rows.len);
        try std.testing.expectEqual(@as(usize, 0), fresh.rows.capacity);
    }
    _ = try world.addSparseTile(level0, 0, 1, deco, 0, .obstacle);
    try std.testing.expectEqual(@as(usize, 2), world.level_terrain.items[level0].sparse_runs[0].rows.capacity);
    _ = try world.addSparseTile(level0, 1, 0, deco, 0, .obstacle);
    try std.testing.expectEqual(@as(usize, 4), world.level_terrain.items[level0].sparse_runs[0].rows.capacity);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        try std.testing.expect((try world.addSparseTile(level0, 1, 1, marker, 0, .marker)) == null);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
    const grown = world.level_terrain.items[level0].sparse_runs[0];
    try std.testing.expectEqual(@as(usize, 4), grown.rows.len);
    try std.testing.expectEqual(@as(usize, 4), grown.rows.capacity);
    try expectSparseIndexConsistent(&world);
}

// The sparse rows as sorted (level, cell, tile id) keys, into `out`.
const TestSparseRowKey = struct { level: u16, cell: u32, tile_id: TileId };

fn testSparseRowKeys(world: *const WorldSystem, out: []TestSparseRowKey) []TestSparseRowKey {
    var count: usize = 0;
    for (world.level_terrain.items) |terrain| {
        for (terrain.sparse_runs) |run| {
            if (run.rows.len == 0) continue;
            const rows = run.rows.slice();
            const levels = rows.items(.level_index);
            const cells = rows.items(.cell_index);
            const tiles = rows.items(.tile_id);
            for (levels, cells, tiles) |level, cell, tile| {
                out[count] = .{ .level = level, .cell = cell, .tile_id = tile };
                count += 1;
            }
        }
    }
    const keys = out[0..count];
    std.mem.sort(TestSparseRowKey, keys, {}, testSparseRowKeyLessThan);
    return keys;
}

fn testSparseRowKeyLessThan(_: void, lhs: TestSparseRowKey, rhs: TestSparseRowKey) bool {
    if (lhs.level != rhs.level) return lhs.level < rhs.level;
    if (lhs.cell != rhs.cell) return lhs.cell < rhs.cell;
    return lhs.tile_id < rhs.tile_id;
}

// An 8x8 world in 4-tile chunks with `level_count` levels that have no bands.
fn testSparseRemovalWorld(meta: *const WorldTilesetMeta, level_count: u16) !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    for (0..level_count) |level_index| _ = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
    return world;
}

test "clearing a cell removes a blocking row swapped onto the cursor and leaves another chunk's rows in place" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseRemovalWorld(&meta, 1);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    // Chunk 0: a blocking row, a later blocker on another cell, then a second blocker
    // of the cleared cell. Chunk 3 holds two rows that the clear must not move.
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 2, 2, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 6, 6, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 6, 5, deco, 0, .obstacle);
    const other = world.level_terrain.items[0].sparse_runs[3];
    const other_capacity = other.rows.capacity;
    var other_cells: [2]u32 = undefined;
    const row_cells = other.rows.items(.cell_index);
    for (row_cells, 0..) |cell, offset| other_cells[offset] = cell;

    try std.testing.expect((try world.clearCellBlocking(0, 1, 1, tunnel)) != null);
    try std.testing.expect(!world.levelBlocksMovement(0, 1, 1));
    try std.testing.expect(world.levelBlocksMovement(0, 2, 2));
    try std.testing.expectEqual(@as(u32, 3), world.sparse_live);
    const kept = world.level_terrain.items[0].sparse_runs[3];
    try std.testing.expectEqual(other_capacity, kept.rows.capacity);
    const kept_cells = kept.rows.items(.cell_index);
    try std.testing.expectEqualSlices(u32, &other_cells, kept_cells);
    try expectSparseIndexConsistent(&world);
}

test "clearing a chunk's last sparse row releases its storage and leaves another chunk's rows" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseRemovalWorld(&meta, 1);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    // Chunk 0 holds one row. Chunk 3 holds two; clearing chunk 0 must not move them.
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 6, 6, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 6, 5, deco, 0, .obstacle);
    try expectSparseIndexConsistent(&world);
    const other = world.level_terrain.items[0].sparse_runs[3];
    const other_capacity = other.rows.capacity;
    var other_cells: [2]u32 = undefined;
    for (other.rows.items(.cell_index), 0..) |cell, offset| other_cells[offset] = cell;

    try std.testing.expect((try world.clearCellBlocking(0, 1, 1, tunnel)) != null);
    const cleared = world.level_terrain.items[0].sparse_runs[0];
    try std.testing.expectEqual(@as(usize, 0), cleared.rows.len);
    try std.testing.expectEqual(@as(usize, 0), cleared.rows.capacity);
    const kept = world.level_terrain.items[0].sparse_runs[3];
    try std.testing.expectEqual(other_capacity, kept.rows.capacity);
    try std.testing.expectEqualSlices(u32, &other_cells, kept.rows.items(.cell_index));
    try std.testing.expectEqual(@as(u32, @intCast(kept.rows.len)), world.sparse_live);
    try expectSparseIndexConsistent(&world);

    try std.testing.expect((try world.clearCellBlocking(0, 6, 6, tunnel)) != null);
    try std.testing.expect((try world.clearCellBlocking(0, 6, 5, tunnel)) != null);
    try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[0].sparse_runs[0].rows.capacity);
    try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[0].sparse_runs[3].rows.len);
    try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[0].sparse_runs[3].rows.capacity);
    try std.testing.expectEqual(@as(u32, 0), world.sparse_live);
    try expectSparseIndexConsistent(&world);
}

test "removing sparse tiles at the first, middle, last, and sole list positions keeps every index consistent" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseRemovalWorld(&meta, 2);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    const tunnel = try world.requireTileByName(&meta, "cave_0");

    // Level 0 chunk 0 holds five tiles, chunk 1 one; level 1 holds two in chunk 0 and
    // one in chunk 3. One blocking tile per cell, so clearing a cell removes one row.
    const placements = [_]struct { level: u16, x: u16, y: u16 }{
        .{ .level = 0, .x = 0, .y = 0 }, .{ .level = 1, .x = 0, .y = 1 }, .{ .level = 0, .x = 1, .y = 0 },
        .{ .level = 0, .x = 2, .y = 0 }, .{ .level = 0, .x = 5, .y = 0 }, .{ .level = 1, .x = 1, .y = 1 },
        .{ .level = 0, .x = 3, .y = 0 }, .{ .level = 1, .x = 5, .y = 5 }, .{ .level = 0, .x = 3, .y = 3 },
    };
    for (placements) |placement| _ = try world.addSparseTile(placement.level, placement.x, placement.y, deco, 0, .obstacle);
    try expectSparseIndexConsistent(&world);

    // (level, chunk, which position of the chunk list): first, middle, last, then a
    // sole tile, then level 0 chunk 0 down to empty.
    const Removal = struct { level: u16, chunk: u32, at: enum { first, middle, last } };
    const removals = [_]Removal{
        .{ .level = 0, .chunk = 0, .at = .first },
        .{ .level = 0, .chunk = 0, .at = .middle },
        .{ .level = 0, .chunk = 0, .at = .last },
        .{ .level = 0, .chunk = 1, .at = .first },
        .{ .level = 1, .chunk = 0, .at = .last },
        .{ .level = 0, .chunk = 0, .at = .first },
        .{ .level = 0, .chunk = 0, .at = .first },
        .{ .level = 1, .chunk = 3, .at = .first },
        .{ .level = 1, .chunk = 0, .at = .first },
    };
    var before_buf: [placements.len]TestSparseRowKey = undefined;
    var after_buf: [placements.len]TestSparseRowKey = undefined;
    var list_buf: [placements.len]u32 = undefined;
    for (removals, 0..) |removal, step| {
        const list = testChunkSparseRows(&world, removal.level, removal.chunk, &list_buf);
        if (removal.at == .middle) try std.testing.expect(list.len >= 3);
        const position = switch (removal.at) {
            .first => 0,
            .middle => list.len / 2,
            .last => list.len - 1,
        };
        const removed = list[position];
        const coord = sparseTileCellCoord(&world, removal.level, removal.chunk, removed);
        const before = testSparseRowKeys(&world, &before_buf);
        try std.testing.expect(world.levelBlocksMovement(removal.level, coord.x, coord.y));

        const event = (try world.clearCellBlocking(removal.level, coord.x, coord.y, tunnel)).?;
        try std.testing.expectEqual(WorldObstacleChangedEvent{ .level = removal.level, .min_x = coord.x, .min_y = coord.y, .max_x_exclusive = coord.x + 1, .max_y_exclusive = coord.y + 1 }, event);
        try std.testing.expect(!world.levelBlocksMovement(removal.level, coord.x, coord.y));
        try expectSparseIndexConsistent(&world);

        // Exactly the removed tile is gone.
        const after = testSparseRowKeys(&world, &after_buf);
        try std.testing.expectEqual(placements.len - step - 1, after.len);
        const removed_key = TestSparseRowKey{ .level = removal.level, .cell = world.cellIndex(coord.x, coord.y), .tile_id = deco };
        var skipped = false;
        var after_index: usize = 0;
        for (before) |key| {
            if (!skipped and std.meta.eql(key, removed_key)) {
                skipped = true;
                continue;
            }
            try std.testing.expectEqual(key, after[after_index]);
            after_index += 1;
        }
        try std.testing.expect(skipped);
        // Every remaining live tile still blocks its cell.
        var row_buf: [placements.len]u32 = undefined;
        for (world.level_terrain.items, 0..) |_, level_index| {
            const level: u16 = @intCast(level_index);
            for (world.level_terrain.items[level_index].sparse_runs, 0..) |_, chunk_index| {
                const chunk: u32 = @intCast(chunk_index);
                for (testChunkSparseRows(&world, level, chunk, &row_buf)) |offset| {
                    const remaining = sparseTileCellCoord(&world, level, chunk, offset);
                    try std.testing.expect(world.levelBlocksMovement(level, remaining.x, remaining.y));
                }
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 0), world.sparse_live);
}

test "repeated sparse add and clear cycles keep rows, lists, and composed bits at the live count" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseRemovalWorld(&meta, 1);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    const stone = try world.requireTileByName(&meta, "stone_floor");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    // One live walkable decal stays throughout.
    _ = try world.addSparseTile(0, 2, 2, stone, 0, .floor);

    var row_capacity: usize = 0;
    for (0..16) |cycle| {
        for (0..3) |_| _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
        _ = try world.addSparseTile(0, 6, 6, deco, 0, .obstacle);
        try std.testing.expectEqual(@as(u32, 5), world.sparse_live);
        try std.testing.expect((try world.clearCellBlocking(0, 1, 1, tunnel)) != null);
        try std.testing.expect((try world.clearCellBlocking(0, 6, 6, tunnel)) != null);

        try std.testing.expectEqual(@as(u32, 1), world.sparse_live);
        try expectSparseIndexConsistent(&world);
        // No blocked cell remains, so the level holds no composed-bits slot.
        try std.testing.expectEqual(@as(usize, 0), liveSlotCount(world.level_terrain.items[0].blocked));
        const runs = world.level_terrain.items[0].sparse_runs;
        if (cycle == 0) row_capacity = runs[0].rows.capacity;
        try std.testing.expectEqual(row_capacity, runs[0].rows.capacity);
        try std.testing.expectEqual(@as(usize, 0), runs[3].rows.capacity);
    }
}

test "clearCellBlocking leaves non-blocking content and returns no event when nothing blocks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseRemovalWorld(&meta, 1);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const dirt = try world.requireTileByName(&meta, "dirt");
    const stone = try world.requireTileByName(&meta, "stone_floor");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    const floor = try world.addDenseLayer(0, 0, .floor, grass);
    const overlay = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.addSparseTile(0, 2, 2, stone, 0, .floor);
    _ = try world.clearDenseTile(floor, 3, 3);
    const slots_before = liveSlotCount(world.level_terrain.items[0].blocked);

    // Walkable floor and overlay with a walkable decal, and a hole: nothing to clear.
    try std.testing.expectEqual(@as(?WorldObstacleChangedEvent, null), try world.clearCellBlocking(0, 2, 2, tunnel));
    try std.testing.expectEqual(@as(?WorldObstacleChangedEvent, null), try world.clearCellBlocking(0, 3, 3, tunnel));
    try std.testing.expectEqual(grass, world.denseTile(floor, 2, 2));
    try std.testing.expectEqual(grass, world.denseTile(overlay, 2, 2));
    try std.testing.expectEqual(invalid_tile_id, world.denseTile(floor, 3, 3));
    try std.testing.expectEqual(@as(u32, 1), world.sparse_live);
    try std.testing.expectEqual(slots_before, liveSlotCount(world.level_terrain.items[0].blocked));

    // A blocking floor clears to the floor tile; the walkable overlay and decal stay.
    _ = try world.setDenseTile(floor, 2, 2, dirt);
    try std.testing.expect(world.levelBlocksMovement(0, 2, 2));
    try std.testing.expect((try world.clearCellBlocking(0, 2, 2, tunnel)) != null);
    try std.testing.expectEqual(tunnel, world.denseTile(floor, 2, 2));
    try std.testing.expectEqual(grass, world.denseTile(overlay, 2, 2));
    try std.testing.expectEqual(@as(u32, 1), world.sparse_live);
    try std.testing.expect(!world.levelBlocksMovement(0, 2, 2));

    // A blocking floor tile could not make the cell walkable.
    try std.testing.expectError(error.InvalidWorldTile, world.clearCellBlocking(0, 2, 2, dirt));
    try std.testing.expectError(error.InvalidWorldCell, world.clearCellBlocking(0, 8, 0, tunnel));
    try std.testing.expectError(error.InvalidWorldLevel, world.clearCellBlocking(1, 0, 0, tunnel));
}

test "clearCellBlocking after its reserve allocates nothing and opens a solid chunk's cell (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseRemovalWorld(&meta, 1);
    defer world.deinit();
    const dirt = try world.requireTileByName(&meta, "dirt");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const deco = try world.requireTileByName(&meta, "deco_0");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    // Every chunk uniform and blocked on both bands and in the composed bits, so the
    // clear takes two tile blocks and a bits slot, all at the reserve.
    const floor = try world.addDenseLayer(0, 0, .floor, dirt);
    const overlay = try world.addDenseLayer(0, 0, .obstacle, tree);
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(0, 0));

    world.beginDenseCellWriteReserve();
    try world.reserveClearCellBlocking(0, 1, 1, tunnel);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    world.allocator = failing.allocator();
    defer world.allocator = std.testing.allocator;
    const event = try world.clearCellBlocking(0, 1, 1, tunnel);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(tunnel, world.denseTile(floor, 1, 1));
    try std.testing.expectEqual(invalid_tile_id, world.denseTile(overlay, 1, 1));
    try std.testing.expectEqual(@as(u32, 0), world.sparse_live);
    try std.testing.expect(!world.levelBlocksMovement(0, 1, 1));
    try std.testing.expect(world.levelBlocksMovement(0, 0, 1));
    try expectSparseIndexConsistent(&world);
}

// Checks every chunk-storage invariant against a flat reference (`reference[layer]`
// row-major cells): tiles, composed bits against a brute-force scan, each block's
// unequal-pair count, live block and slot counts, and the forms they imply: a chunk
// is uniform exactly when its in-level cells hold one tile.
fn expectTerrainMatchesReference(world: *const WorldSystem, reference: []const []const TileId) !void {
    const geom = world.chunkGeometry();
    const stores = world.dense_layers.items(.store);
    for (reference, 0..) |layer_cells, layer| {
        const store = stores[layer];
        var mixed_chunks: usize = 0;
        for (0..geom.chunkCount()) |chunk_index| {
            const chunk: u32 = @intCast(chunk_index);
            const extent = geom.extent(chunk);
            // Unequal neighbors along the in-level row-major chain.
            var unequal_pairs: u16 = 0;
            var previous: ?TileId = null;
            const uniform = store.uniformTile(chunk);
            for (0..extent.rows) |row| {
                for (0..extent.cols) |col| {
                    const x: u16 = @intCast(extent.min_x + col);
                    const y: u16 = @intCast(extent.min_y + row);
                    const expected = layer_cells[@as(usize, y) * world.width + x];
                    try std.testing.expectEqual(expected, world.denseTile(layer, x, y));
                    if (previous) |previous_tile| unequal_pairs += @intFromBool(expected != previous_tile);
                    previous = expected;
                }
            }
            if (uniform == null) {
                mixed_chunks += 1;
                try std.testing.expectEqual(unequal_pairs, store.fills.items[store.dir[chunk]].unequal_pairs);
                try std.testing.expect(unequal_pairs > 0);
            } else {
                try std.testing.expectEqual(@as(u16, 0), unequal_pairs);
            }
        }
        try std.testing.expectEqual(mixed_chunks, liveBlockCount(store));
    }
    for (world.level_terrain.items, 0..) |terrain, level_index| {
        const level: u16 = @intCast(level_index);
        var mixed_chunks: usize = 0;
        for (0..geom.chunkCount()) |chunk_index| {
            const chunk: u32 = @intCast(chunk_index);
            const extent = geom.extent(chunk);
            var blocked_cells: u32 = 0;
            for (0..extent.rows) |row| {
                for (0..extent.cols) |col| {
                    const x: u16 = @intCast(extent.min_x + col);
                    const y: u16 = @intCast(extent.min_y + row);
                    const expected = bruteForceLevelBlocked(world, level, x, y);
                    try std.testing.expectEqual(expected, world.levelBlocksMovement(level, x, y));
                    blocked_cells += @intFromBool(expected);
                }
            }
            const expected_form: ChunkForm = if (blocked_cells == 0)
                .open
            else if (blocked_cells == extent.cellCount())
                .blocked
            else
                .mixed;
            try std.testing.expectEqual(expected_form, terrain.blocked.form(chunk));
            try std.testing.expectEqual(blocked_cells, chunkBlockedCount(terrain.blocked, geom, chunk));
            mixed_chunks += @intFromBool(expected_form == .mixed);
        }
        try std.testing.expectEqual(mixed_chunks, liveSlotCount(terrain.blocked));
    }
}

test "chunk terrain accessors match a flat reference model under random writes" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 10x7 tiles, 4x4 chunks: a 3x2 grid whose right and bottom chunks are short.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 10,
        .height = 7,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const cell_count = cellCount(&world);

    // Three levels: grass floor + grass obstacle band, a dirt floor, and a grass
    // floor under a dirt obstacle band.
    const layer_specs = [_]struct { level: u16, depth: WorldDepth, fill: TileId }{
        .{ .level = 0, .depth = .floor, .fill = tiles.grass },
        .{ .level = 0, .depth = .obstacle, .fill = tiles.grass },
        .{ .level = 1, .depth = .floor, .fill = tiles.dirt },
        .{ .level = 2, .depth = .floor, .fill = tiles.grass },
        .{ .level = 2, .depth = .obstacle, .fill = tiles.dirt },
    };
    for (0..3) |level| _ = try world.addLevel(-@as(i32, @intCast(level)) * level_z_step);
    var reference_storage: [layer_specs.len][70]TileId = undefined;
    var reference: [layer_specs.len][]TileId = undefined;
    for (layer_specs, 0..) |spec, layer| {
        _ = try world.addDenseLayer(spec.level, 0, spec.depth, spec.fill);
        reference[layer] = reference_storage[layer][0..cell_count];
        @memset(reference[layer], spec.fill);
    }
    try expectTerrainMatchesReference(&world, &reference);

    const write_tiles = [_]TileId{ tiles.grass, tiles.dirt, tiles.water, tiles.cave, tiles.tree, invalid_tile_id };
    var prng = std.Random.DefaultPrng.init(0x64_c0_ffee);
    const random = prng.random();
    for (0..1500) |step| {
        const layer = random.uintLessThan(usize, layer_specs.len);
        const x = random.uintLessThan(u16, world.width);
        const y = random.uintLessThan(u16, world.height);
        // Bias toward each layer's fill so chunks return to uniform often.
        const tile = if (random.boolean()) layer_specs[layer].fill else write_tiles[random.uintLessThan(usize, write_tiles.len)];
        if (step % 3 == 0) {
            world.beginDenseCellWriteReserve();
            try world.reserveDenseCellWrite(layer, x, y, tile);
        }
        if (tile == invalid_tile_id) {
            _ = try world.clearDenseTile(layer, x, y);
        } else {
            _ = try world.setDenseTile(layer, x, y, tile);
        }
        reference[layer][@as(usize, y) * world.width + x] = tile;
        try std.testing.expectEqual(tile, world.denseTile(layer, x, y));
        if (step % 97 == 0) {
            const level = random.uintLessThan(u16, 3);
            _ = try world.addSparseTile(level, random.uintLessThan(u16, world.width), random.uintLessThan(u16, world.height), tiles.deco, 0, .obstacle);
        }
        if (step % 50 == 49) {
            // Close the reserve scope so no early block outlives it, then check everything.
            world.beginDenseCellWriteReserve();
            try expectTerrainMatchesReference(&world, &reference);
        }
    }
}

test "clearCellBlocking and refills match the flat reference in uniform blocked chunks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8x8 tiles, 4x4 chunks: four chunks, every one uniform at the start.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const cell_count = cellCount(&world);
    _ = try world.addLevel(0);

    // Two blocking bands and one walkable band the clear must leave alone.
    const fills = [_]TileId{ tiles.dirt, tiles.tree, tiles.grass };
    const depths = [_]WorldDepth{ .floor, .obstacle, .obstacle };
    var reference_storage: [fills.len][64]TileId = undefined;
    var reference: [fills.len][]TileId = undefined;
    for (fills, depths, 0..) |fill, depth, layer| {
        _ = try world.addDenseLayer(0, 0, depth, fill);
        reference[layer] = reference_storage[layer][0..cell_count];
        @memset(reference[layer], fill);
    }
    try expectTerrainMatchesReference(&world, &reference);

    // Exit cells in chunks 0 and 3; the first also holds a blocking sparse tile.
    const exits = [_]CellCoord{ .{ .x = 1, .y = 2 }, .{ .x = 6, .y = 5 } };
    for (0..3) |_| {
        _ = try world.addSparseTile(0, exits[0].x, exits[0].y, tiles.deco, 0, .obstacle);
        try expectTerrainMatchesReference(&world, &reference);
        for (exits) |exit| {
            const cell = @as(usize, exit.y) * world.width + exit.x;
            try std.testing.expect((try world.clearCellBlocking(0, exit.x, exit.y, tiles.cave)) != null);
            reference[0][cell] = tiles.cave;
            reference[1][cell] = invalid_tile_id;
            // No reserve scope is closed here, so a block or slot the clear took and
            // left unused would show up as a live count above the mixed chunks.
            try expectTerrainMatchesReference(&world, &reference);
        }
        for (exits) |exit| {
            const cell = @as(usize, exit.y) * world.width + exit.x;
            _ = try world.setDenseTile(0, exit.x, exit.y, fills[0]);
            _ = try world.setDenseTile(1, exit.x, exit.y, fills[1]);
            reference[0][cell] = fills[0];
            reference[1][cell] = fills[1];
            try expectTerrainMatchesReference(&world, &reference);
        }
        // Refilled: every chunk is uniform again with no block or slot held.
        for (0..fills.len) |layer| try std.testing.expectEqual(@as(usize, 0), liveBlockCount(world.dense_layers.items(.store)[layer]));
        try std.testing.expectEqual(@as(usize, 0), liveSlotCount(world.level_terrain.items[0].blocked));
    }
}

test "a multi-chunk change in one step on two levels writes allocation-free after its reserve" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x16 tiles, 4x4 chunks; the 9x9 region spans 9 chunks per level and fully
    // covers the four chunks (1..2, 1..2).
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    _ = try world.addLevel(0);
    _ = try world.addLevel(-level_z_step);
    const surface = try world.addDenseLayer(0, 0, .floor, tiles.grass);
    const underground = try world.addDenseLayer(1, 0, .floor, tiles.dirt);
    var reference_storage: [2][256]TileId = undefined;
    @memset(&reference_storage[0], tiles.grass);
    @memset(&reference_storage[1], tiles.dirt);
    const reference = [_][]const TileId{ &reference_storage[0], &reference_storage[1] };

    // Explosion: hole the surface and hollow the level below in one step.
    world.beginDenseCellWriteReserve();
    for (3..12) |y| for (3..12) |x| {
        try world.reserveDenseCellWrite(surface, @intCast(x), @intCast(y), invalid_tile_id);
        try world.reserveDenseCellWrite(underground, @intCast(x), @intCast(y), tiles.cave);
    };
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        for (3..12) |y| for (3..12) |x| {
            _ = try world.clearDenseTile(surface, @intCast(x), @intCast(y));
            _ = try world.setDenseTile(underground, @intCast(x), @intCast(y), tiles.cave);
            reference_storage[0][y * 16 + x] = invalid_tile_id;
            reference_storage[1][y * 16 + x] = tiles.cave;
        };
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    world.beginDenseCellWriteReserve();
    try expectTerrainMatchesReference(&world, &reference);
    // Fully hollowed chunks of the level below are open; partly hollowed ones mixed.
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(1, 1 * 4 + 1));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(1, 0));
    try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(1, 3 * 4 + 3));

    // Cave-in: refill both levels in one step; every block and slot returns to uniform.
    for (3..12) |y| for (3..12) |x| {
        _ = try world.setDenseTile(surface, @intCast(x), @intCast(y), tiles.grass);
        _ = try world.setDenseTile(underground, @intCast(x), @intCast(y), tiles.dirt);
        reference_storage[0][y * 16 + x] = tiles.grass;
        reference_storage[1][y * 16 + x] = tiles.dirt;
    };
    try expectTerrainMatchesReference(&world, &reference);
    try std.testing.expectEqual(@as(usize, 0), liveBlockCount(world.dense_layers.items(.store)[surface]));
    try std.testing.expectEqual(@as(usize, 0), liveBlockCount(world.dense_layers.items(.store)[underground]));
    try std.testing.expectEqual(@as(usize, 0), liveSlotCount(world.level_terrain.items[1].blocked));
}

test "repeated dig and fill of one cell re-uniforms its block and reuses one pool entry" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const level = try world.addLevel(0);
    const layer = try world.addDenseLayer(level, 0, .floor, tiles.dirt);
    const chunk = world.chunkGeometry().chunkOf(5, 2);

    for (0..50) |_| {
        _ = try world.setDenseTile(layer, 5, 2, tiles.cave);
        try std.testing.expectEqual(@as(?TileId, null), world.dense_layers.items(.store)[layer].uniformTile(chunk));
        try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(level, chunk));
        try std.testing.expect(!world.levelBlocksMovement(level, 5, 2));
        _ = try world.setDenseTile(layer, 5, 2, tiles.dirt);
        const store = world.dense_layers.items(.store)[layer];
        try std.testing.expectEqual(@as(?TileId, tiles.dirt), store.uniformTile(chunk));
        try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(level, chunk));
        try std.testing.expect(world.levelBlocksMovement(level, 5, 2));
        // One block and one slot were ever taken; each fill released them.
        try std.testing.expectEqual(@as(usize, 1), store.fills.items.len);
        try std.testing.expectEqual(@as(usize, 0), liveBlockCount(store));
        try std.testing.expectEqual(@as(usize, 1), world.level_terrain.items[level].blocked.bits.items.len);
        try std.testing.expectEqual(@as(usize, 0), liveSlotCount(world.level_terrain.items[level].blocked));
    }
}

test "terrain pools grow at their reserve seam, and pool reuse grows nothing" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 32x32 tiles in 4x4 chunks: 64 chunks, more than the pools' first growth holds.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 32,
        .height = 32,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const level = try world.addLevel(0);
    const layer = try world.addDenseLayer(level, 0, .floor, tiles.dirt);
    try std.testing.expect(!world.terrain_pool_growth_logged);
    const Pools = struct {
        blocks: usize,
        slots: usize,

        fn of(w: *const WorldSystem, lvl: u16, layer_index: usize) @This() {
            return .{ .blocks = w.dense_layers.items(.store)[layer_index].fills.capacity, .slots = w.level_terrain.items[lvl].blocked.bits.capacity };
        }
    };
    const empty = Pools.of(&world, level, layer);

    // The first carve into the solid level grows the block pool and the bits pool.
    _ = try world.setDenseTile(layer, 1, 1, tiles.cave);
    try std.testing.expect(world.terrain_pool_growth_logged);
    const first = Pools.of(&world, level, layer);
    try std.testing.expect(first.blocks > empty.blocks and first.slots > empty.slots);
    // The refill releases both; a carve in another chunk reuses them.
    _ = try world.setDenseTile(layer, 1, 1, tiles.dirt);
    _ = try world.setDenseTile(layer, 5, 5, tiles.cave);
    try std.testing.expectEqual(first, Pools.of(&world, level, layer));
    // A batched carve into every chunk outgrows both pools: one reserve each.
    var writes: [64]DenseCellWrite = undefined;
    var chunks: [64]DenseChunkWrites = undefined;
    for (&writes, &chunks, 0..) |*write, *chunk, index| {
        const chunk_x: u16 = @intCast(index % 8);
        const chunk_y: u16 = @intCast(index / 8);
        write.* = .{ .layer = @intCast(layer), .x = chunk_x * 4 + 2, .y = chunk_y * 4 + 2, .tile = tiles.cave };
        chunk.* = .{ .level = level, .chunk_x = chunk_x, .chunk_y = chunk_y, .writes = write[0..1] };
    }
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try world.applyDenseCellWrites(&chunks, null, &events);
    const batched = Pools.of(&world, level, layer);
    try std.testing.expect(batched.blocks > first.blocks and batched.slots > first.slots);
}

test "a uniform chunk stays uniform while another chunk on its level is edited" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const level = try world.addLevel(0);
    const layer = try world.addDenseLayer(level, 0, .floor, tiles.grass);
    for (0..4) |y| for (0..4) |x| {
        _ = try world.setDenseTile(layer, @intCast(x), @intCast(y), if ((x + y) % 2 == 0) tiles.water else tiles.cave);
    };
    _ = try world.addSparseTile(level, 1, 2, tiles.tree, 0, .obstacle);
    const store = world.dense_layers.items(.store)[layer];
    try std.testing.expectEqual(@as(?TileId, null), store.uniformTile(0));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(level, 0));
    for (1..4) |chunk| {
        try std.testing.expectEqual(@as(?TileId, tiles.grass), store.uniformTile(@intCast(chunk)));
        try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, @intCast(chunk)));
    }
    try std.testing.expectEqual(@as(usize, 1), liveBlockCount(store));
    try std.testing.expectEqual(@as(usize, 1), liveSlotCount(world.level_terrain.items[level].blocked));
}

test "addSparseTile reserves the composed-bits slot before committing (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const level = try world.addLevel(0);
    // A walkable sparse tile fills chunk 0's first slot and leaves it OPEN.
    _ = try world.addSparseTile(level, 0, 0, tiles.grass, 0, .floor);
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level, 1, 1, tiles.deco, 0, .obstacle));
        try std.testing.expect(failing.has_induced_failure);
        const run = world.level_terrain.items[level].sparse_runs[0];
        // The row buffer doubled, then the composed-bits reserve failed: the row
        // stays unpublished and the grown capacity stays.
        try std.testing.expectEqual(@as(usize, 1), run.rows.len);
        try std.testing.expectEqual(@as(usize, 2), run.rows.capacity);
        var buffer: [2]u32 = undefined;
        try std.testing.expectEqual(@as(usize, 1), testChunkSparseRows(&world, level, 0, &buffer).len);
        try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));
        try std.testing.expect(!world.levelBlocksMovement(level, 1, 1));
    }
    _ = try world.addSparseTile(level, 1, 1, tiles.deco, 0, .obstacle);
    try std.testing.expect(world.levelBlocksMovement(level, 1, 1));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(level, 0));
}

test "addSparseTile fails as OutOfMemory at 2^32 - 1 rows held, before any reserve, publishing and blocking nothing; one row short reaches the allocator" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const level = try world.addLevel(0);
    _ = try world.addSparseTile(level, 0, 0, tiles.grass, 0, .floor);
    const live_rows = world.sparse_live;
    // The add checks the population before its reserves, so the count needs no row
    // memory behind it. Restored before any reader walks the rows. One short of the
    // cap reaches `setCapacity` on a fresh chunk.
    for ([_]u32{ no_sparse_tile, no_sparse_tile - 1 }) |held| {
        world.sparse_live = held;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        const result = world.addSparseTile(level, 2, 0, tiles.deco, 0, .obstacle);
        world.allocator = std.testing.allocator;
        world.sparse_live = live_rows;
        try std.testing.expectError(error.OutOfMemory, result);
        // At the sentinel nothing is asked of the allocator; one row short, the row reserve is.
        try std.testing.expectEqual(held == no_sparse_tile - 1, failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[level].sparse_runs[1].rows.capacity);
        var buffer: [2]u32 = undefined;
        try std.testing.expectEqual(@as(usize, 1), testChunkSparseRows(&world, level, 0, &buffer).len);
        try std.testing.expectEqual(@as(usize, 0), testChunkSparseRows(&world, level, 1, &buffer).len);
        try std.testing.expect(!world.levelBlocksMovement(level, 2, 0));
        try std.testing.expectEqual(@as(u32, 1), world.sparse_live);
    }
    // With the rows below the sentinel, the same add commits.
    _ = try world.addSparseTile(level, 2, 0, tiles.deco, 0, .obstacle);
    try std.testing.expect(world.levelBlocksMovement(level, 2, 0));
}

// The batched-edit fixture's dense layers: level 0 a grass floor under a grass
// obstacle band, level 1 a dirt floor, level 2 a grass floor under a dirt band.
const batch_layer_levels = [_]u16{ 0, 0, 1, 2, 2 };
const batch_layer_depths = [_]WorldDepth{ .floor, .obstacle, .floor, .floor, .obstacle };

fn batchLayerFill(tiles: TerrainTestTiles, layer: usize) TileId {
    return switch (layer) {
        0, 1, 3 => tiles.grass,
        else => tiles.dirt,
    };
}

// 16x16 tiles in 4x4 chunks (16 per level) on three levels with a few sparse
// obstacles; levels 0 and 1 are resident in the GPU tile store, level 2 is not.
fn testBatchEditWorld(meta: *const WorldTilesetMeta) !WorldSystem {
    return testBatchEditWorldSized(meta, 16, 16);
}

// `testBatchEditWorld` at `width` x `height` (at least 14 each), so a side short of
// whole chunks gives short border chunks.
fn testBatchEditWorldSized(meta: *const WorldTilesetMeta, width: u16, height: u16) !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = width,
        .height = height,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const tiles = try TerrainTestTiles.resolve(&world, meta);
    for (0..3) |level| _ = try world.addLevel(-@as(i32, @intCast(level)) * level_z_step);
    for (batch_layer_levels, batch_layer_depths, 0..) |level, depth, layer| {
        _ = try world.addDenseLayer(level, 0, depth, batchLayerFill(tiles, layer));
    }
    _ = try world.addSparseTile(0, 5, 5, tiles.deco, 0, .obstacle);
    _ = try world.addSparseTile(1, 9, 2, tiles.deco, 0, .obstacle);
    _ = try world.addSparseTile(2, 13, 13, tiles.deco, 0, .obstacle);
    world.render_window = .{ .levels_below = 1 };
    _ = try testSyncGpuTiles(&world, 0);
    return world;
}

// Every byte of a world's chunk terrain, block change marks, and layer render
// flags, for exact comparison.
fn appendTerrainBytes(out: *std.ArrayList(u8), world: *const WorldSystem) !void {
    const allocator = std.testing.allocator;
    for (world.dense_layers.items(.store)) |store| {
        try out.appendSlice(allocator, std.mem.sliceAsBytes(store.dir));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(store.cells.items));
        // Field by field: `BlockFill` has padding bytes.
        for (store.fills.items) |fill| {
            try out.appendSlice(allocator, std.mem.asBytes(&fill.fill));
            try out.appendSlice(allocator, std.mem.asBytes(&fill.unequal_pairs));
            try out.append(allocator, @intFromBool(fill.changed));
        }
        try out.appendSlice(allocator, std.mem.sliceAsBytes(store.free.items));
    }
    for (world.level_terrain.items) |terrain| {
        try out.appendSlice(allocator, std.mem.sliceAsBytes(terrain.blocked.dir));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(terrain.blocked.bits.items));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(terrain.blocked.counts.items));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(terrain.blocked.free.items));
    }
    for (world.dense_layers.items(.render_changed)) |changed| try out.append(allocator, @intFromBool(changed));
    try out.append(allocator, @intFromBool(world.resident_layers_changed));
}

fn expectTerrainBytesEqual(expected: *const WorldSystem, actual: *const WorldSystem) !void {
    var expected_bytes: std.ArrayList(u8) = .empty;
    defer expected_bytes.deinit(std.testing.allocator);
    var actual_bytes: std.ArrayList(u8) = .empty;
    defer actual_bytes.deinit(std.testing.allocator);
    try appendTerrainBytes(&expected_bytes, expected);
    try appendTerrainBytes(&actual_bytes, actual);
    try std.testing.expectEqualSlices(u8, expected_bytes.items, actual_bytes.items);
}

// Flat per-layer reference of the batched-edit fixture, row-major cells.
const BatchReference = struct {
    storage: [batch_layer_levels.len][256]TileId = undefined,

    fn init(tiles: TerrainTestTiles) BatchReference {
        var reference = BatchReference{};
        for (&reference.storage, 0..) |*cells, layer| @memset(cells, batchLayerFill(tiles, layer));
        return reference;
    }

    fn apply(self: *BatchReference, writes: []const DenseCellWrite) void {
        for (writes) |write| self.storage[write.layer][@as(usize, write.y) * 16 + write.x] = write.tile;
    }

    fn layers(self: *const BatchReference) [batch_layer_levels.len][]const TileId {
        var out: [batch_layer_levels.len][]const TileId = undefined;
        for (&out, &self.storage) |*slice, *cells| slice.* = cells;
        return out;
    }
};

// The events a batch from `before` to `after` must emit: every changed (layer, cell)
// in (level, chunk, local cell, layer) order.
fn expectCanonicalBatchEvents(world: *const WorldSystem, before: *const BatchReference, after: *const BatchReference, events: []const WorldTileChangedEvent) !void {
    const geom = world.chunkGeometry();
    var index: usize = 0;
    for (world.level_terrain.items, 0..) |terrain, level_index| {
        for (0..geom.chunkCount()) |chunk_index| {
            const extent = geom.extent(@intCast(chunk_index));
            for (0..geom.blockCells()) |local| {
                const col = local & (geom.chunk_tiles - 1);
                const row = local >> geom.shift;
                if (col >= extent.cols or row >= extent.rows) continue;
                const x: u16 = @intCast(extent.min_x + col);
                const y: u16 = @intCast(extent.min_y + row);
                for (terrain.bandLayers()) |layer| {
                    const old_tile = before.storage[layer][@as(usize, y) * 16 + x];
                    const new_tile = after.storage[layer][@as(usize, y) * 16 + x];
                    if (old_tile == new_tile) continue;
                    try std.testing.expect(index < events.len);
                    try std.testing.expectEqual(WorldTileChangedEvent{
                        .level = @intCast(level_index),
                        .x = x,
                        .y = y,
                        .old_tile_id = old_tile,
                        .new_tile_id = new_tile,
                        .old_blocks_movement = world.flagsFor(old_tile).blocks_movement,
                        .new_blocks_movement = world.flagsFor(new_tile).blocks_movement,
                    }, events[index]);
                    index += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(events.len, index);
}

// A flat write list regrouped chunk-major: writes stable-sorted by (level, chunk),
// so each cell keeps its write order, with one entry per (level, chunk).
const ChunkMajorWrites = struct {
    writes: std.ArrayList(DenseCellWrite) = .empty,
    chunks: std.ArrayList(DenseChunkWrites) = .empty,

    fn init(world: *const WorldSystem, flat: []const DenseCellWrite) !ChunkMajorWrites {
        const allocator = std.testing.allocator;
        var out: ChunkMajorWrites = .{};
        errdefer out.deinit();
        try out.writes.appendSlice(allocator, flat);
        std.mem.sort(DenseCellWrite, out.writes.items, world, writeBefore);
        const writes = out.writes.items;
        var start: usize = 0;
        while (start < writes.len) {
            const key = chunkKey(world, writes[start]);
            var end = start + 1;
            while (end < writes.len and chunkKey(world, writes[end]) == key) end += 1;
            try out.chunks.append(allocator, .{
                .level = world.denseLayerLevel(writes[start].layer),
                .chunk_x = writes[start].x / world.chunk_size_tiles,
                .chunk_y = writes[start].y / world.chunk_size_tiles,
                .writes = writes[start..end],
            });
            start = end;
        }
        return out;
    }

    fn deinit(self: *ChunkMajorWrites) void {
        self.writes.deinit(std.testing.allocator);
        self.chunks.deinit(std.testing.allocator);
    }

    fn chunkKey(world: *const WorldSystem, write: DenseCellWrite) u64 {
        return @as(u64, world.denseLayerLevel(write.layer)) << 32 | world.chunkGeometry().chunkOf(write.x, write.y);
    }

    fn writeBefore(world: *const WorldSystem, lhs: DenseCellWrite, rhs: DenseCellWrite) bool {
        return chunkKey(world, lhs) < chunkKey(world, rhs);
    }
};

// Both stages fanned out at one chunk per range, so every multi-chunk batch spreads
// across workers.
fn testEditThreads(world: *WorldSystem, threads: *ThreadSystem) TerrainEditThreads {
    return .{
        .thread_system = threads,
        .plan_tuner = &world.terrain_edit_plan_tuner,
        .write_tuner = &world.terrain_edit_write_tuner,
        .controls = .{ .adaptive = false, .items_per_range = 1 },
    };
}

// Random writes over every layer and cell, biased toward each layer's fill and
// with repeats, so chunks split, re-uniform, and take several writes per cell.
fn randomBatchWrites(random: std.Random, tiles: TerrainTestTiles, out: []DenseCellWrite) []DenseCellWrite {
    const write_tiles = [_]TileId{ tiles.grass, tiles.dirt, tiles.water, tiles.cave, tiles.tree, invalid_tile_id };
    const count = random.intRangeAtMost(usize, 1, out.len);
    for (out[0..count], 0..) |*write, index| {
        if (index > 0 and random.uintLessThan(u8, 8) == 0) {
            write.* = out[random.uintLessThan(usize, index)];
            write.tile = write_tiles[random.uintLessThan(usize, write_tiles.len)];
            continue;
        }
        const layer = random.uintLessThan(u32, batch_layer_levels.len);
        write.* = .{
            .layer = layer,
            .x = random.uintLessThan(u16, 16),
            .y = random.uintLessThan(u16, 16),
            .tile = if (random.boolean()) batchLayerFill(tiles, layer) else write_tiles[random.uintLessThan(usize, write_tiles.len)],
        };
    }
    return out[0..count];
}

test "a batched dense edit is identical inline and threaded and matches its canonical events" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var serial = try testBatchEditWorld(&meta);
    defer serial.deinit();
    var threaded = try testBatchEditWorld(&meta);
    defer threaded.deinit();
    const tiles = try TerrainTestTiles.resolve(&serial, &meta);
    var reference = BatchReference.init(tiles);

    var serial_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer serial_events.deinit(std.testing.allocator);
    var threaded_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer threaded_events.deinit(std.testing.allocator);
    var write_buffer: [160]DenseCellWrite = undefined;
    var prng = std.Random.DefaultPrng.init(0x53b_7e44);
    for (0..40) |_| {
        const writes = randomBatchWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&serial, writes);
        defer batch.deinit();
        serial_events.clearRetainingCapacity();
        threaded_events.clearRetainingCapacity();
        try serial_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try threaded_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try serial.applyDenseCellWrites(batch.chunks.items, null, &serial_events);
        try threaded.applyDenseCellWrites(batch.chunks.items, testEditThreads(&threaded, &threads), &threaded_events);

        const before = reference;
        reference.apply(writes);
        try std.testing.expectEqualSlices(WorldTileChangedEvent, serial_events.items, threaded_events.items);
        try expectCanonicalBatchEvents(&serial, &before, &reference, serial_events.items);
        try expectTerrainBytesEqual(&serial, &threaded);
        const layers = reference.layers();
        try expectTerrainMatchesReference(&threaded, &layers);
        // Upload both worlds' changes as a frame's sync would.
        _ = try testSyncGpuTiles(&threaded, 0);
        _ = try testSyncGpuTiles(&serial, 0);
    }
}

test "a terrain edit worker cap of zero on a multi-worker ThreadSystem writes the same terrain and events" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var uncapped = try testBatchEditWorld(&meta);
    defer uncapped.deinit();
    var capped = try testBatchEditWorld(&meta);
    defer capped.deinit();
    const tiles = try TerrainTestTiles.resolve(&uncapped, &meta);

    var uncapped_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer uncapped_events.deinit(std.testing.allocator);
    var capped_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer capped_events.deinit(std.testing.allocator);
    var write_buffer: [160]DenseCellWrite = undefined;
    var prng = std.Random.DefaultPrng.init(0x53b_7e44);
    for (0..40) |_| {
        const writes = randomBatchWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&uncapped, writes);
        defer batch.deinit();
        uncapped_events.clearRetainingCapacity();
        capped_events.clearRetainingCapacity();
        try uncapped_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try capped_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try uncapped.applyDenseCellWrites(batch.chunks.items, testEditThreads(&uncapped, &threads), &uncapped_events);
        var capped_threads = testEditThreads(&capped, &threads);
        capped_threads.controls.max_worker_threads = 0;
        try capped.applyDenseCellWrites(batch.chunks.items, capped_threads, &capped_events);
        try std.testing.expectEqualSlices(WorldTileChangedEvent, uncapped_events.items, capped_events.items);
        try expectTerrainBytesEqual(&uncapped, &capped);
    }
}

test "a batched dense edit composes the same tiles and blocked cells as single-cell writes" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var batched = try testBatchEditWorld(&meta);
    defer batched.deinit();
    var single = try testBatchEditWorld(&meta);
    defer single.deinit();
    const tiles = try TerrainTestTiles.resolve(&batched, &meta);

    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    var write_buffer: [160]DenseCellWrite = undefined;
    var prng = std.Random.DefaultPrng.init(0x5_1e6_ce11);
    for (0..40) |_| {
        const writes = randomBatchWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&batched, writes);
        defer batch.deinit();
        events.clearRetainingCapacity();
        try events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try batched.applyDenseCellWrites(batch.chunks.items, null, &events);
        for (writes) |write| _ = try writeDenseTileCell(&single, write.layer, write.x, write.y, write.tile);

        for (0..batched.dense_layers.len) |layer| {
            for (0..batched.height) |y| for (0..batched.width) |x| {
                try std.testing.expectEqual(single.denseTile(layer, @intCast(x), @intCast(y)), batched.denseTile(layer, @intCast(x), @intCast(y)));
            };
            // Both paths re-uniform exactly the chunks left holding one tile.
            const single_store = single.dense_layers.items(.store)[layer];
            const batched_store = batched.dense_layers.items(.store)[layer];
            for (0..batched.chunkCountPerLevel()) |chunk| {
                try std.testing.expectEqual(single_store.uniformTile(@intCast(chunk)), batched_store.uniformTile(@intCast(chunk)));
            }
            try std.testing.expectEqual(liveBlockCount(single_store), liveBlockCount(batched_store));
        }
        for (0..batched.level_terrain.items.len) |level| {
            for (0..batched.height) |y| for (0..batched.width) |x| {
                const level_index: u16 = @intCast(level);
                try std.testing.expectEqual(single.levelBlocksMovement(level_index, @intCast(x), @intCast(y)), batched.levelBlocksMovement(level_index, @intCast(x), @intCast(y)));
            };
        }
        // Upload both worlds' changes as a frame's sync would.
        _ = try testSyncGpuTiles(&batched, 0);
        _ = try testSyncGpuTiles(&single, 0);
    }
}

// Adds `count` sparse tiles at random cells on every level of the batched-edit
// fixture, two in three blocking; the same seed places the same tiles.
fn addRandomSparseTiles(world: *WorldSystem, tiles: TerrainTestTiles, seed: u64, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..world.level_terrain.items.len) |level| {
        for (0..count) |_| {
            const tile = if (random.uintLessThan(u8, 3) == 0) tiles.grass else tiles.deco;
            _ = try world.addSparseTile(@intCast(level), random.uintLessThan(u16, world.width), random.uintLessThan(u16, world.height), tile, 0, .obstacle);
        }
    }
}

test "a batched dense edit over many sparse tiles is identical inline, threaded, and as single-cell writes" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var serial = try testBatchEditWorld(&meta);
    defer serial.deinit();
    var threaded = try testBatchEditWorld(&meta);
    defer threaded.deinit();
    var single = try testBatchEditWorld(&meta);
    defer single.deinit();
    const tiles = try TerrainTestTiles.resolve(&serial, &meta);
    // About a third of each level's cells hold a sparse tile, some cells several.
    for ([_]*WorldSystem{ &serial, &threaded, &single }) |world| try addRandomSparseTiles(world, tiles, 0x5ba7_5e00, 96);

    var serial_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer serial_events.deinit(std.testing.allocator);
    var threaded_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer threaded_events.deinit(std.testing.allocator);
    var write_buffer: [160]DenseCellWrite = undefined;
    var prng = std.Random.DefaultPrng.init(0x5ba7_5e01);
    for (0..40) |_| {
        const writes = randomBatchWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&serial, writes);
        defer batch.deinit();
        serial_events.clearRetainingCapacity();
        threaded_events.clearRetainingCapacity();
        try serial_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try threaded_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try serial.applyDenseCellWrites(batch.chunks.items, null, &serial_events);
        try threaded.applyDenseCellWrites(batch.chunks.items, testEditThreads(&threaded, &threads), &threaded_events);
        for (writes) |write| _ = try writeDenseTileCell(&single, write.layer, write.x, write.y, write.tile);

        try std.testing.expectEqualSlices(WorldTileChangedEvent, serial_events.items, threaded_events.items);
        try expectTerrainBytesEqual(&serial, &threaded);
        for (0..serial.level_terrain.items.len) |level| {
            for (0..serial.height) |y| for (0..serial.width) |x| {
                const level_index: u16 = @intCast(level);
                try std.testing.expectEqual(single.levelBlocksMovement(level_index, @intCast(x), @intCast(y)), serial.levelBlocksMovement(level_index, @intCast(x), @intCast(y)));
            };
        }
        _ = try testSyncGpuTiles(&threaded, 0);
        _ = try testSyncGpuTiles(&serial, 0);
        _ = try testSyncGpuTiles(&single, 0);
    }
}

test "a batched dense edit over sparse tiles in short border chunks is identical inline, threaded, and as single-cell writes" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    // 15x15 tiles in 4x4 chunks: the right column and bottom row of chunks are 3
    // cells short of a full chunk on one or both axes.
    var serial = try testBatchEditWorldSized(&meta, 15, 15);
    defer serial.deinit();
    var threaded = try testBatchEditWorldSized(&meta, 15, 15);
    defer threaded.deinit();
    var single = try testBatchEditWorldSized(&meta, 15, 15);
    defer single.deinit();
    const tiles = try TerrainTestTiles.resolve(&serial, &meta);
    const write_tiles = [_]TileId{ tiles.grass, tiles.dirt, tiles.water, tiles.cave, tiles.tree, invalid_tile_id };

    // Sparse tiles only in the border chunks (x or y at least 12), two in three blocking.
    var prng = std.Random.DefaultPrng.init(0xb0_7de2);
    const random = prng.random();
    for ([_]*WorldSystem{ &serial, &threaded, &single }) |world| {
        var place = std.Random.DefaultPrng.init(0xb0_7de3);
        for (0..world.level_terrain.items.len) |level| {
            for (0..40) |_| {
                const along = place.random().uintLessThan(u16, 15);
                const across = 12 + place.random().uintLessThan(u16, 3);
                const x, const y = if (place.random().boolean()) .{ across, along } else .{ along, across };
                const tile = if (place.random().uintLessThan(u8, 3) == 0) tiles.grass else tiles.deco;
                _ = try world.addSparseTile(@intCast(level), x, y, tile, 0, .obstacle);
            }
        }
    }

    var serial_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer serial_events.deinit(std.testing.allocator);
    var threaded_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer threaded_events.deinit(std.testing.allocator);
    var write_buffer: [160]DenseCellWrite = undefined;
    for (0..40) |_| {
        // Random writes over the whole level, biased toward each layer's fill so
        // chunks split and re-uniform.
        const count = random.intRangeAtMost(usize, 1, write_buffer.len);
        for (write_buffer[0..count]) |*write| {
            const layer = random.uintLessThan(u32, batch_layer_levels.len);
            write.* = .{
                .layer = layer,
                .x = random.uintLessThan(u16, 15),
                .y = random.uintLessThan(u16, 15),
                .tile = if (random.boolean()) batchLayerFill(tiles, layer) else write_tiles[random.uintLessThan(usize, write_tiles.len)],
            };
        }
        const writes = write_buffer[0..count];
        var batch = try ChunkMajorWrites.init(&serial, writes);
        defer batch.deinit();
        serial_events.clearRetainingCapacity();
        threaded_events.clearRetainingCapacity();
        try serial_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try threaded_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try serial.applyDenseCellWrites(batch.chunks.items, null, &serial_events);
        try threaded.applyDenseCellWrites(batch.chunks.items, testEditThreads(&threaded, &threads), &threaded_events);
        for (writes) |write| _ = try writeDenseTileCell(&single, write.layer, write.x, write.y, write.tile);

        try std.testing.expectEqualSlices(WorldTileChangedEvent, serial_events.items, threaded_events.items);
        try expectTerrainBytesEqual(&serial, &threaded);
        for (0..serial.dense_layers.len) |layer| {
            for (0..serial.chunkCountPerLevel()) |chunk| {
                try std.testing.expectEqual(single.dense_layers.items(.store)[layer].uniformTile(@intCast(chunk)), serial.dense_layers.items(.store)[layer].uniformTile(@intCast(chunk)));
            }
        }
        for (0..serial.level_terrain.items.len) |level| {
            for (0..serial.height) |y| for (0..serial.width) |x| {
                const level_index: u16 = @intCast(level);
                try std.testing.expectEqual(single.levelBlocksMovement(level_index, @intCast(x), @intCast(y)), serial.levelBlocksMovement(level_index, @intCast(x), @intCast(y)));
            };
        }
        _ = try testSyncGpuTiles(&threaded, 0);
        _ = try testSyncGpuTiles(&serial, 0);
        _ = try testSyncGpuTiles(&single, 0);
    }
}

test "a batched dense edit marks resident layers identically inline and threaded and the next sync matches the CPU" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var serial = try testBatchEditWorld(&meta);
    defer serial.deinit();
    var threaded = try testBatchEditWorld(&meta);
    defer threaded.deinit();
    const tiles = try TerrainTestTiles.resolve(&serial, &meta);
    // The fixtures' sync batches upload the resident layers whole.
    var serial_gpu: TestGpuStore = .{};
    defer serial_gpu.deinit();
    var threaded_gpu: TestGpuStore = .{};
    defer threaded_gpu.deinit();
    try testApplySync(&serial, &serial_gpu);
    try testApplySync(&threaded, &threaded_gpu);
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    var write_buffer: [160]DenseCellWrite = undefined;
    var prng = std.Random.DefaultPrng.init(0x64_9b);
    for (0..20) |_| {
        const writes = randomBatchWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&serial, writes);
        defer batch.deinit();
        events.clearRetainingCapacity();
        try events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try serial.applyDenseCellWrites(batch.chunks.items, null, &events);
        events.clearRetainingCapacity();
        try threaded.applyDenseCellWrites(batch.chunks.items, testEditThreads(&threaded, &threads), &events);
        // Marks and flags are part of the compared bytes.
        try expectTerrainBytesEqual(&serial, &threaded);

        _ = try testSyncGpuTiles(&serial, 0);
        _ = try testSyncGpuTiles(&threaded, 0);
        try std.testing.expectEqualSlices(TileStoreSpan, serial.gpu_tiles.spans.items, threaded.gpu_tiles.spans.items);
        try std.testing.expectEqualSlices(u32, serial.gpu_tiles.values.items, threaded.gpu_tiles.values.items);
        try testApplySync(&serial, &serial_gpu);
        try testApplySync(&threaded, &threaded_gpu);
        try expectGpuStoreMatches(&serial, &serial_gpu);
        try expectGpuStoreMatches(&threaded, &threaded_gpu);
        try std.testing.expect(!serial.resident_layers_changed and !threaded.resident_layers_changed);
    }
}

test "edits between syncs allocate nothing for the GPU, rendered or not (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // A world with no store (its residency reset, nothing resident) and one whose
    // surface layer is resident: 1000 warmed dig/fill cycles each, single-cell and
    // batched.
    for ([_]bool{ false, true }) |rendered| {
        var world = try testBatchEditWorld(&meta);
        defer world.deinit();
        if (!rendered) world_render.resetGpuResidency(&world);
        try std.testing.expectEqual(rendered, world.dense_layers.items(.gpu_slot)[0] != world_gpu_tiles.no_slot);
        var gpu: TestGpuStore = .{};
        defer gpu.deinit();
        try testApplySync(&world, &gpu);
        const tiles = try TerrainTestTiles.resolve(&world, &meta);
        const dig = [_]DenseCellWrite{ .{ .layer = 0, .x = 1, .y = 1, .tile = tiles.water }, .{ .layer = 0, .x = 5, .y = 1, .tile = tiles.water } };
        const fill = [_]DenseCellWrite{ .{ .layer = 0, .x = 1, .y = 1, .tile = tiles.grass }, .{ .layer = 0, .x = 5, .y = 1, .tile = tiles.grass } };
        const dig_chunks = [_]DenseChunkWrites{ .{ .level = 0, .chunk_x = 0, .chunk_y = 0, .writes = dig[0..1] }, .{ .level = 0, .chunk_x = 1, .chunk_y = 0, .writes = dig[1..2] } };
        const fill_chunks = [_]DenseChunkWrites{ .{ .level = 0, .chunk_x = 0, .chunk_y = 0, .writes = fill[0..1] }, .{ .level = 0, .chunk_x = 1, .chunk_y = 0, .writes = fill[1..2] } };
        var events: std.ArrayList(WorldTileChangedEvent) = .empty;
        defer events.deinit(std.testing.allocator);
        try events.ensureTotalCapacity(std.testing.allocator, dig.len);

        for (0..1001) |cycle| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
            // The first cycle warms the terrain pools and batch scratch.
            if (cycle > 0) world.allocator = failing.allocator();
            defer world.allocator = std.testing.allocator;
            _ = try world.setDenseTile(0, 2, 2, tiles.water);
            _ = try world.setDenseTile(0, 2, 2, tiles.grass);
            events.clearRetainingCapacity();
            try world.applyDenseCellWrites(&dig_chunks, null, &events);
            events.clearRetainingCapacity();
            try world.applyDenseCellWrites(&fill_chunks, null, &events);
            try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        }
        try std.testing.expectEqual(rendered, world.resident_layers_changed);
        if (rendered) {
            _ = try testSyncGpuTiles(&world, 0);
            try testApplySync(&world, &gpu);
            try expectGpuStoreMatches(&world, &gpu);
        }
    }
}

// A multi-chunk, multi-level batch: a 7x7 cave-in hollowing levels 1 and 2 and
// holing level 0's floor, plus a blocking column on level 0's obstacle band.
fn caveInBatchWrites(tiles: TerrainTestTiles, out: *[160]DenseCellWrite) []DenseCellWrite {
    var count: usize = 0;
    for (3..10) |y| for (3..10) |x| {
        const cell_x: u16 = @intCast(x);
        const cell_y: u16 = @intCast(y);
        out[count] = .{ .layer = 0, .x = cell_x, .y = cell_y, .tile = invalid_tile_id };
        out[count + 1] = .{ .layer = 2, .x = cell_x, .y = cell_y, .tile = tiles.cave };
        out[count + 2] = .{ .layer = 4, .x = cell_x, .y = cell_y, .tile = tiles.grass };
        count += 3;
    };
    for (0..11) |y| {
        out[count] = .{ .layer = 1, .x = 12, .y = @intCast(y), .tile = tiles.tree };
        count += 1;
    }
    return out[0..count];
}

// The batched-edit allocation proofs run on the three-level fixture and on the
// wide-band level.
const EditFixture = enum { batch, wide_bands };

fn editFixtureWorld(meta: *const WorldTilesetMeta, fixture: EditFixture) !WorldSystem {
    return switch (fixture) {
        .batch => testBatchEditWorld(meta),
        .wide_bands => testWideBandWorld(meta),
    };
}

// The fixture's multi-chunk cave-in, in flat order.
fn editFixtureCaveIn(tiles: TerrainTestTiles, fixture: EditFixture, out: *[wide_cave_in_writes]DenseCellWrite) []DenseCellWrite {
    return switch (fixture) {
        .batch => caveInBatchWrites(tiles, out[0..160]),
        .wide_bands => wideCaveInWrites(tiles, out),
    };
}

// A flat row-major copy of every dense layer of a world, for
// `expectTerrainMatchesReference`.
const FlatReference = struct {
    cells: []TileId,
    layers: [][]const TileId,
    width: usize,

    fn init(world: *const WorldSystem) !FlatReference {
        const allocator = std.testing.allocator;
        const layer_cells = @as(usize, world.width) * world.height;
        const cells = try allocator.alloc(TileId, world.dense_layers.len * layer_cells);
        errdefer allocator.free(cells);
        const layers = try allocator.alloc([]const TileId, world.dense_layers.len);
        for (layers, 0..) |*layer, index| {
            const layer_slice = cells[index * layer_cells ..][0..layer_cells];
            for (layer_slice, 0..) |*cell, cell_index| cell.* = world.denseTile(index, @intCast(cell_index % world.width), @intCast(cell_index / world.width));
            layer.* = layer_slice;
        }
        return .{ .cells = cells, .layers = layers, .width = world.width };
    }

    fn deinit(self: *FlatReference) void {
        std.testing.allocator.free(self.cells);
        std.testing.allocator.free(self.layers);
    }

    fn apply(self: *FlatReference, writes: []const DenseCellWrite) void {
        const layer_cells = self.cells.len / self.layers.len;
        for (writes) |write| self.cells[write.layer * layer_cells + @as(usize, write.y) * self.width + write.x] = write.tile;
    }
};

fn batchEditAllocationTest(meta: *const WorldTilesetMeta, threads: *ThreadSystem, fixture: EditFixture, fail_index: usize) !bool {
    var world = try editFixtureWorld(meta, fixture);
    defer world.deinit();
    const tiles = try TerrainTestTiles.resolve(&world, meta);
    var write_buffer: [wide_cave_in_writes]DenseCellWrite = undefined;
    const writes = editFixtureCaveIn(tiles, fixture, &write_buffer);
    var batch = try ChunkMajorWrites.init(&world, writes);
    defer batch.deinit();
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(std.testing.allocator);
    try appendTerrainBytes(&before, &world);
    var reference = try FlatReference.init(&world);
    defer reference.deinit();
    reference.apply(writes);

    const edit_threads = testEditThreads(&world, threads);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
    world.allocator = failing.allocator();
    const result = world.applyDenseCellWrites(batch.chunks.items, edit_threads, &events);
    world.allocator = std.testing.allocator;
    if (result) |_| {
        try std.testing.expect(!failing.has_induced_failure);
        try expectTerrainMatchesReference(&world, reference.layers);
        return true;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        // Nothing changed: terrain, composed bits, change marks, render flags, and events.
        var after: std.ArrayList(u8) = .empty;
        defer after.deinit(std.testing.allocator);
        try appendTerrainBytes(&after, &world);
        try std.testing.expectEqualSlices(u8, before.items, after.items);
        try std.testing.expectEqual(@as(usize, 0), events.items.len);
        // The retry succeeds and lands the whole batch.
        try world.applyDenseCellWrites(batch.chunks.items, edit_threads, &events);
        try expectTerrainMatchesReference(&world, reference.layers);
        return false;
    }
}

test "a batched dense edit fails cleanly at every allocation on the multi-worker path and its retry lands (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    for ([_]EditFixture{ .batch, .wide_bands }) |fixture| {
        var fail_index: usize = 0;
        while (!try batchEditAllocationTest(&meta, &threads, fixture, fail_index)) fail_index += 1;
        // Scratch and the touched levels' pools grew.
        try std.testing.expect(fail_index >= 10);
    }
}

test "a warmed batched dense edit allocates nothing (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    for ([_]EditFixture{ .batch, .wide_bands }) |fixture| {
        var world = try editFixtureWorld(&meta, fixture);
        defer world.deinit();
        const tiles = try TerrainTestTiles.resolve(&world, &meta);
        var write_buffer: [wide_cave_in_writes]DenseCellWrite = undefined;
        const writes = editFixtureCaveIn(tiles, fixture, &write_buffer);
        var restore_buffer: [wide_cave_in_writes]DenseCellWrite = undefined;
        const restores = restore_buffer[0..writes.len];
        for (writes, restores) |write, *restore| {
            restore.* = write;
            restore.tile = world.denseTile(write.layer, write.x, write.y);
        }
        var batch = try ChunkMajorWrites.init(&world, writes);
        defer batch.deinit();
        var restore_batch = try ChunkMajorWrites.init(&world, restores);
        defer restore_batch.deinit();
        var events: std.ArrayList(WorldTileChangedEvent) = .empty;
        defer events.deinit(std.testing.allocator);
        try events.ensureTotalCapacity(std.testing.allocator, writes.len);
        const edit_threads = testEditThreads(&world, &threads);
        try world.applyDenseCellWrites(batch.chunks.items, edit_threads, &events);
        events.clearRetainingCapacity();
        try world.applyDenseCellWrites(restore_batch.chunks.items, edit_threads, &events);
        // A frame's sync uploads the changes, as between steps in play.
        _ = try testSyncGpuTiles(&world, 0);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        events.clearRetainingCapacity();
        try world.applyDenseCellWrites(batch.chunks.items, edit_threads, &events);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expectEqual(writes.len, events.items.len);
    }
}

// The wide-band fixture: one 4x4-tile level in 2x2-tile chunks holding more bands
// than one 64-bit band word, walkable grass but for one blocking dirt band, every
// band GPU resident.
const wide_band_count: usize = 70;
const wide_blocking_band: usize = 66;
// Every band's cells (0..3, 0..3): a cave-in across all four chunks.
const wide_cave_in_writes: usize = wide_band_count * 9;

fn wideBandFill(tiles: TerrainTestTiles, band: usize) TileId {
    return if (band == wide_blocking_band) tiles.dirt else tiles.grass;
}

fn testWideBandWorld(meta: *const WorldTilesetMeta) !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const tiles = try TerrainTestTiles.resolve(&world, meta);
    const level = try world.addLevel(0);
    for (0..wide_band_count) |band| _ = try world.addDenseLayer(level, 0, .floor, wideBandFill(tiles, band));
    _ = try testSyncGpuTiles(&world, 0);
    std.debug.assert(world.gpu_tiles.residentLayerCount() == wide_band_count);
    return world;
}

fn wideCaveInWrites(tiles: TerrainTestTiles, out: *[wide_cave_in_writes]DenseCellWrite) []DenseCellWrite {
    var count: usize = 0;
    for (0..wide_band_count) |band| for (0..3) |y| for (0..3) |x| {
        const tile = switch (band % 3) {
            0 => invalid_tile_id,
            1 => tiles.cave,
            else => tiles.dirt,
        };
        out[count] = .{ .layer = @intCast(band), .x = @intCast(x), .y = @intCast(y), .tile = tile };
        count += 1;
    };
    return out[0..count];
}

// Random writes over every band and cell of the wide-band fixture, at least one on
// a band past the first band word.
fn randomWideBandWrites(random: std.Random, tiles: TerrainTestTiles, out: []DenseCellWrite) []DenseCellWrite {
    const write_tiles = [_]TileId{ tiles.grass, tiles.dirt, tiles.water, tiles.cave, tiles.tree, invalid_tile_id };
    const count = random.intRangeAtMost(usize, 2, out.len);
    for (out[0..count], 0..) |*write, index| {
        const band: u32 = if (index == 0) @intCast(wide_band_count - 1) else random.uintLessThan(u32, wide_band_count);
        write.* = .{
            .layer = band,
            .x = random.uintLessThan(u16, 4),
            .y = random.uintLessThan(u16, 4),
            .tile = if (random.boolean()) wideBandFill(tiles, band) else write_tiles[random.uintLessThan(usize, write_tiles.len)],
        };
    }
    return out[0..count];
}

test "a level grows past 64 bands and a batched edit across all of them is identical inline and threaded and matches single-cell writes" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var serial = try testWideBandWorld(&meta);
    defer serial.deinit();
    var threaded = try testWideBandWorld(&meta);
    defer threaded.deinit();
    var single = try testWideBandWorld(&meta);
    defer single.deinit();
    const tiles = try TerrainTestTiles.resolve(&serial, &meta);
    var reference = try FlatReference.init(&serial);
    defer reference.deinit();
    var gpu: TestGpuStore = .{};
    defer gpu.deinit();
    try testApplySync(&threaded, &gpu);

    var serial_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer serial_events.deinit(std.testing.allocator);
    var threaded_events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer threaded_events.deinit(std.testing.allocator);
    var write_buffer: [200]DenseCellWrite = undefined;
    var prng = std.Random.DefaultPrng.init(0x70_ba5d);
    for (0..30) |_| {
        const writes = randomWideBandWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&serial, writes);
        defer batch.deinit();
        serial_events.clearRetainingCapacity();
        threaded_events.clearRetainingCapacity();
        try serial_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try threaded_events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try serial.applyDenseCellWrites(batch.chunks.items, null, &serial_events);
        try threaded.applyDenseCellWrites(batch.chunks.items, testEditThreads(&threaded, &threads), &threaded_events);
        for (writes) |write| _ = try writeDenseTileCell(&single, write.layer, write.x, write.y, write.tile);
        reference.apply(writes);

        try std.testing.expectEqualSlices(WorldTileChangedEvent, serial_events.items, threaded_events.items);
        try expectTerrainBytesEqual(&serial, &threaded);
        try expectTerrainMatchesReference(&threaded, reference.layers);
        try expectTerrainMatchesReference(&single, reference.layers);
        _ = try testSyncGpuTiles(&threaded, 0);
        try testApplySync(&threaded, &gpu);
        try expectGpuStoreMatches(&threaded, &gpu);
        _ = try testSyncGpuTiles(&serial, 0);
        _ = try testSyncGpuTiles(&single, 0);
    }
}

test "a multi-level cave-in lands in one batched step and refills to uniform chunks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testBatchEditWorld(&meta);
    defer world.deinit();
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    // The fixture's sync batch uploads the resident layers whole.
    var gpu_store: TestGpuStore = .{};
    defer gpu_store.deinit();
    try testApplySync(&world, &gpu_store);
    var reference = BatchReference.init(tiles);
    var write_buffer: [160]DenseCellWrite = undefined;
    const writes = caveInBatchWrites(tiles, &write_buffer);
    var batch = try ChunkMajorWrites.init(&world, writes);
    defer batch.deinit();
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);

    try world.applyDenseCellWrites(batch.chunks.items, null, &events);
    const before = reference;
    reference.apply(writes);
    try expectCanonicalBatchEvents(&world, &before, &reference, events.items);
    var layers = reference.layers();
    try expectTerrainMatchesReference(&world, &layers);
    // Level 1's fully hollowed chunk (4..7, 4..7) is open; its partly hollowed ones mixed.
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(1, 1 * 4 + 1));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(1, 0));
    try std.testing.expect(world.levelBlocksMovement(0, 12, 4));
    // A chunk every write left holding one non-fill tile stores no block: level 1's
    // hollowed chunk at the tunnel, the surface's at the hole.
    const stores = world.dense_layers.items(.store);
    try std.testing.expectEqual(@as(?TileId, tiles.cave), stores[2].uniformTile(1 * 4 + 1));
    try std.testing.expectEqual(@as(?TileId, invalid_tile_id), stores[0].uniformTile(1 * 4 + 1));
    // The GPU store reads those chunks back at their new uniform tiles.
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu_store);
    try expectGpuStoreMatches(&world, &gpu_store);

    // The refill in one step returns every block and slot to uniform.
    var refill_buffer: [160]DenseCellWrite = undefined;
    const refills = refill_buffer[0..writes.len];
    for (writes, refills) |write, *refill| refill.* = .{ .layer = write.layer, .x = write.x, .y = write.y, .tile = batchLayerFill(tiles, write.layer) };
    var refill_batch = try ChunkMajorWrites.init(&world, refills);
    defer refill_batch.deinit();
    events.clearRetainingCapacity();
    try world.applyDenseCellWrites(refill_batch.chunks.items, null, &events);
    try std.testing.expectEqual(writes.len, events.items.len);
    reference.apply(refills);
    layers = reference.layers();
    try expectTerrainMatchesReference(&world, &layers);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu_store);
    try expectGpuStoreMatches(&world, &gpu_store);
    for (world.dense_layers.items(.store)) |store| try std.testing.expectEqual(@as(usize, 0), liveBlockCount(store));
    try std.testing.expectEqual(@as(usize, 0), liveSlotCount(world.level_terrain.items[1].blocked));
}

test "a 1x1 border chunk turning uniform at another tile reads back from the GPU store" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 5x5 tiles in 4x4 chunks: chunk 3 is the 1x1 corner (4, 4).
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 5,
        .height = 5,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const level = try world.addLevel(0);
    const layer = try world.addDenseLayer(level, 0, .floor, tiles.grass);
    world.render_window = .{ .levels_below = 0 };
    _ = try testSyncGpuTiles(&world, 0);
    var gpu_store: TestGpuStore = .{};
    defer gpu_store.deinit();
    try testApplySync(&world, &gpu_store);
    const store = &world.dense_layers.items(.store)[layer];

    // Single-cell path, grass -> water in one frame: uniform to uniform, no block.
    _ = try world.setDenseTile(layer, 4, 4, tiles.water);
    try std.testing.expectEqual(@as(?TileId, tiles.water), store.uniformTile(3));
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu_store);
    try expectGpuStoreMatches(&world, &gpu_store);

    // Batched path, water -> cave in one frame.
    const writes = [_]DenseCellWrite{.{ .layer = @intCast(layer), .x = 4, .y = 4, .tile = tiles.cave }};
    const chunks = [_]DenseChunkWrites{.{ .level = level, .chunk_x = 1, .chunk_y = 1, .writes = &writes }};
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try world.applyDenseCellWrites(&chunks, null, &events);
    try std.testing.expectEqual(@as(?TileId, tiles.cave), store.uniformTile(3));
    try std.testing.expectEqual(@as(usize, 0), liveBlockCount(store));
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu_store);
    try expectGpuStoreMatches(&world, &gpu_store);
    try std.testing.expectEqual(@as(?TileId, tiles.cave), testGpuTile(&world, &gpu_store, layer, 4, 4));
}

test "a one-chunk batched dense edit over two layers applies every write and emits one event per write" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var world = try testBatchEditWorld(&meta);
    defer world.deinit();
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    // Two bands of one level in one chunk is still one chunk.
    const writes = [_]DenseCellWrite{
        .{ .layer = 0, .x = 1, .y = 1, .tile = tiles.water },
        .{ .layer = 1, .x = 2, .y = 1, .tile = tiles.tree },
        .{ .layer = 0, .x = 3, .y = 3, .tile = invalid_tile_id },
    };
    const chunks = [_]DenseChunkWrites{.{ .level = 0, .chunk_x = 0, .chunk_y = 0, .writes = &writes }};
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try world.applyDenseCellWrites(&chunks, testEditThreads(&world, &threads), &events);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    for (writes) |write| try std.testing.expectEqual(write.tile, world.denseTile(write.layer, write.x, write.y));
    try std.testing.expect(world.levelBlocksMovement(0, 2, 1));
}

test "a batched dense edit blocks and reopens a whole short border chunk" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    // 14x14 tiles in 4x4 chunks: the corner chunk (3, 3) holds only cells 12..13 x 12..13.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 14,
        .height = 14,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(0, 0, .floor, tiles.grass);
    const corner: u32 = 3 * 4 + 3;

    // A second chunk with one blocked cell, so the batch fans out over two chunks.
    const block_corner = [_]DenseCellWrite{
        .{ .layer = 0, .x = 12, .y = 12, .tile = tiles.dirt },
        .{ .layer = 0, .x = 13, .y = 12, .tile = tiles.dirt },
        .{ .layer = 0, .x = 12, .y = 13, .tile = tiles.dirt },
        .{ .layer = 0, .x = 13, .y = 13, .tile = tiles.dirt },
    };
    const block_single = [_]DenseCellWrite{.{ .layer = 0, .x = 1, .y = 1, .tile = tiles.dirt }};
    const block_chunks = [_]DenseChunkWrites{
        .{ .level = 0, .chunk_x = 0, .chunk_y = 0, .writes = &block_single },
        .{ .level = 0, .chunk_x = 3, .chunk_y = 3, .writes = &block_corner },
    };
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, 5);
    try world.applyDenseCellWrites(&block_chunks, testEditThreads(&world, &threads), &events);
    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    // Every in-level cell blocked: the corner's slot went back and it reads BLOCKED.
    try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(0, corner));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(0, 0));
    try std.testing.expectEqual(@as(usize, 1), liveSlotCount(world.level_terrain.items[0].blocked));

    var reopen_corner = block_corner;
    for (&reopen_corner) |*write| write.tile = tiles.grass;
    const reopen_single = [_]DenseCellWrite{.{ .layer = 0, .x = 1, .y = 1, .tile = tiles.grass }};
    const reopen_chunks = [_]DenseChunkWrites{
        .{ .level = 0, .chunk_x = 0, .chunk_y = 0, .writes = &reopen_single },
        .{ .level = 0, .chunk_x = 3, .chunk_y = 3, .writes = &reopen_corner },
    };
    events.clearRetainingCapacity();
    try world.applyDenseCellWrites(&reopen_chunks, testEditThreads(&world, &threads), &events);
    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(0, corner));
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(0, 0));
    try std.testing.expectEqual(@as(usize, 0), liveSlotCount(world.level_terrain.items[0].blocked));
    try std.testing.expectEqual(@as(usize, 0), liveBlockCount(world.dense_layers.items(.store)[0]));
}

test "a batched carve and restore of one cell leaves its uniform chunk unchanged" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testBatchEditWorld(&meta);
    defer world.deinit();
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    // Level 1's dirt floor (layer 2, GPU resident); chunk (1, 1) is uniform and blocked.
    const writes = [_]DenseCellWrite{
        .{ .layer = 2, .x = 5, .y = 6, .tile = tiles.cave },
        .{ .layer = 2, .x = 5, .y = 6, .tile = tiles.dirt },
    };
    const chunks = [_]DenseChunkWrites{.{ .level = 1, .chunk_x = 1, .chunk_y = 1, .writes = &writes }};
    const slots_before = liveSlotCount(world.level_terrain.items[1].blocked);
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try world.applyDenseCellWrites(&chunks, null, &events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    for (world.dense_layers.items(.store)) |store| try std.testing.expectEqual(@as(usize, 0), liveBlockCount(store));
    try std.testing.expectEqual(slots_before, liveSlotCount(world.level_terrain.items[1].blocked));
    try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(1, 1 * 4 + 1));
    // No cell changed, so no layer is flagged for the GPU sync.
    try std.testing.expect(!world.resident_layers_changed);
    try std.testing.expect(!world.dense_layers.items(.render_changed)[2]);
}

// Applies `chunks` threaded into `events` with exactly `event_capacity` spare
// slots, expects `expected`, and checks the world, its render flags, and `events`
// are untouched.
test "unordered writes across levels and chunks group into (level, chunk) order, keep each chunk's input order, and apply like the writes one by one (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var grouped = try testBatchEditWorldSized(&meta, 16, 16);
    defer grouped.deinit();
    var sequential = try testBatchEditWorldSized(&meta, 16, 16);
    defer sequential.deinit();
    const tiles = try TerrainTestTiles.resolve(&grouped, &meta);
    var prng = std.Random.DefaultPrng.init(0x9e0d_1e55);
    const random = prng.random();
    var writes_buffer: [96]DenseCellWrite = undefined;
    var next: [96]u32 = undefined;
    var out_writes: [96]DenseCellWrite = undefined;
    var out_chunks: [96]DenseChunkWrites = undefined;
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes_buffer.len);
    // Repeated batches: each regroups from empty scratch, and the second warms nothing new.
    for (0..6) |_| {
        const writes = randomBatchWrites(random, tiles, &writes_buffer);
        // Descending (level, chunk) input: the reverse of the order the batch needs.
        std.mem.reverse(DenseCellWrite, writes);
        const chunks = blk: {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
            grouped.allocator = failing.allocator();
            defer grouped.allocator = std.testing.allocator;
            const chunks = grouped.groupDenseCellWrites(writes, next[0..writes.len], out_writes[0..writes.len], out_chunks[0..writes.len]);
            try std.testing.expectEqual(@as(usize, 0), failing.allocations);
            break :blk chunks;
        };
        var total: usize = 0;
        for (chunks, 0..) |entry, index| {
            const chunk = @as(u32, entry.chunk_y) * grouped.chunkGeometry().chunks_x + entry.chunk_x;
            if (index > 0) {
                const previous = chunks[index - 1];
                const previous_chunk = @as(u32, previous.chunk_y) * grouped.chunkGeometry().chunks_x + previous.chunk_x;
                try std.testing.expect(entry.level > previous.level or (entry.level == previous.level and chunk > previous_chunk));
            }
            // The chunk's writes, in the order they arrived.
            var cursor: usize = 0;
            for (writes) |write| {
                if (grouped.denseLayerLevel(write.layer) != entry.level or grouped.chunkGeometry().chunkOf(write.x, write.y) != chunk) continue;
                try std.testing.expectEqual(write, entry.writes[cursor]);
                cursor += 1;
            }
            try std.testing.expectEqual(entry.writes.len, cursor);
            total += cursor;
        }
        try std.testing.expectEqual(writes.len, total);
        try std.testing.expect(grouped.edit_levels.isEmpty());
        for (grouped.edit_level_heads.items) |head| try std.testing.expectEqual(no_edit_write, head);
        for (grouped.edit_chunk_heads) |head| try std.testing.expectEqual(no_edit_write, head);
        for (grouped.level_terrain.items) |terrain| try std.testing.expect(terrain.edit_chunks.isEmpty());

        events.clearRetainingCapacity();
        try grouped.applyDenseCellWrites(chunks, null, &events);
        for (writes) |write| {
            if (write.tile == invalid_tile_id) {
                _ = try sequential.clearDenseTile(write.layer, write.x, write.y);
            } else {
                _ = try sequential.setDenseTile(write.layer, write.x, write.y, write.tile);
            }
        }
        for (0..grouped.dense_layers.len) |layer| for (0..16) |y| for (0..16) |x| {
            try std.testing.expectEqual(sequential.denseTile(layer, @intCast(x), @intCast(y)), grouped.denseTile(layer, @intCast(x), @intCast(y)));
        };
        for (0..grouped.levelCount()) |level| for (0..16) |y| for (0..16) |x| {
            try std.testing.expectEqual(sequential.levelBlocksMovement(@intCast(level), @intCast(x), @intCast(y)), grouped.levelBlocksMovement(@intCast(level), @intCast(x), @intCast(y)));
        };
    }
}

fn expectRejectedBatch(world: *WorldSystem, threads: *ThreadSystem, chunks: []const DenseChunkWrites, event_capacity: usize, expected: anyerror) !void {
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(std.testing.allocator);
    try appendTerrainBytes(&before, world);
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacityPrecise(std.testing.allocator, event_capacity);
    try std.testing.expectError(expected, world.applyDenseCellWrites(chunks, testEditThreads(world, threads), &events));
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(std.testing.allocator);
    try appendTerrainBytes(&after, world);
    try std.testing.expectEqualSlices(u8, before.items, after.items);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try std.testing.expectEqual(event_capacity, events.capacity);
}

test "a batched dense edit on a world with no level is an invalid level" {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    const writes = [_]DenseCellWrite{.{ .layer = 0, .x = 1, .y = 1, .tile = 0 }};
    const chunks = [_]DenseChunkWrites{.{ .level = 0, .chunk_x = 0, .chunk_y = 0, .writes = &writes }};
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try std.testing.expectError(error.InvalidWorldLevel, world.applyDenseCellWrites(&chunks, null, &events));
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "a batched dense edit rejects unordered chunks and invalid writes before any change" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    var world = try testBatchEditWorld(&meta);
    defer world.deinit();
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    // A valid first chunk whose write would split its uniform block.
    const split = [_]DenseCellWrite{.{ .layer = 2, .x = 1, .y = 1, .tile = tiles.cave }};
    const first = DenseChunkWrites{ .level = 1, .chunk_x = 0, .chunk_y = 0, .writes = &split };
    const later = [_]DenseCellWrite{.{ .layer = 2, .x = 5, .y = 1, .tile = tiles.cave }};

    try expectRejectedBatch(&world, &threads, &.{ first, first }, 16, error.UnorderedDenseChunkWrites);
    try expectRejectedBatch(&world, &threads, &.{ .{ .level = 1, .chunk_x = 1, .chunk_y = 0, .writes = &later }, first }, 16, error.UnorderedDenseChunkWrites);
    try expectRejectedBatch(&world, &threads, &.{ first, .{ .level = 3, .chunk_x = 0, .chunk_y = 0, .writes = &later } }, 16, error.InvalidWorldLevel);
    try expectRejectedBatch(&world, &threads, &.{ first, .{ .level = 1, .chunk_x = 4, .chunk_y = 0, .writes = &later } }, 16, error.InvalidWorldCell);

    const bad_layer = [_]DenseCellWrite{.{ .layer = std.math.maxInt(u32), .x = 5, .y = 1, .tile = tiles.cave }};
    try expectRejectedBatch(&world, &threads, &.{ first, .{ .level = 1, .chunk_x = 1, .chunk_y = 0, .writes = &bad_layer } }, 16, error.InvalidWorldLayer);
    // Layer 0 is on level 0, not the chunk's level.
    const other_level = [_]DenseCellWrite{.{ .layer = 0, .x = 5, .y = 1, .tile = tiles.cave }};
    try expectRejectedBatch(&world, &threads, &.{ first, .{ .level = 1, .chunk_x = 1, .chunk_y = 0, .writes = &other_level } }, 16, error.InvalidWorldLayer);
    // (9, 1) lies in chunk (2, 0), not (1, 0).
    const outside = [_]DenseCellWrite{ later[0], .{ .layer = 2, .x = 9, .y = 1, .tile = tiles.cave } };
    try expectRejectedBatch(&world, &threads, &.{ first, .{ .level = 1, .chunk_x = 1, .chunk_y = 0, .writes = &outside } }, 16, error.InvalidWorldCell);
    const bad_tile = [_]DenseCellWrite{.{ .layer = 2, .x = 5, .y = 1, .tile = invalid_tile_id - 1 }};
    try expectRejectedBatch(&world, &threads, &.{ first, .{ .level = 1, .chunk_x = 1, .chunk_y = 0, .writes = &bad_tile } }, 16, error.InvalidWorldTile);
}
