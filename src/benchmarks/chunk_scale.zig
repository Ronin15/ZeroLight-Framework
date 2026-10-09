// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Chunk-owned terrain scaling: one fixed-size terrain change per timed iteration
//! on worlds of every level size and depth. The change is the same at every level
//! size and depth, so the cost model expects each group flat across both axes:
//!   - `chunk-scale-dig`: 64 single-cell digs and refills, each in its own chunk.
//!   - `chunk-scale-ramp`: 64 ramp digs, each in its own chunk on the deepest level
//!     and linked to the level above, the way `DigController` digs a ramp: the
//!     dedupe lookup, one reserve scope for the tile write and the link, the write,
//!     and the link add. Links are append-only in play, so each iteration's reset
//!     (untimed) refills the cells and drops the links. Flat.
//!   - `chunk-scale-cave-in`: a chunk-aligned tunnel region of 4, 64, or 256 chunks,
//!     a quarter on each of four stacked levels, collapses to solid and is carved
//!     back, each one batched edit (`applyDenseCellWrites`). Linear in region chunks.
//!   - `chunk-scale-explosion-fill`: a disk inscribed in a 4-, 64-, or 256-chunk
//!     square on the deepest level (touching fewer chunks than the square) is blown
//!     open and filled back, each one batched edit. Linear in region chunks.
//!   - `chunk-scale-gpu-sync-dig`: the dig workload with a GPU tile sync after the
//!     digs and after the refills (64 blocks taken, then freed). Flat.
//!   - `chunk-scale-gpu-sync-level-enter`: the render window steps one level down
//!     and back, each step one level entering (its directory and 64 mixed blocks)
//!     and one leaving. Linear in chunks per level, flat across depth.
//! Single-cell writes go through the step's reserve seam (`reserveDenseCellWrite`)
//! first. Changes sit on the deepest levels at the level center; each iteration ends
//! at its start state. The item count encodes the case as `level side * 1000 +
//! levels`, plus `region chunks * 10^7` for the two batched groups. Fixtures and the
//! batches' write lists build once per case outside the timed loop. The batched
//! groups run serial, fixed-thread, and adaptive, with the two deepest levels
//! GPU resident so the GPU edit merge is timed; they report each stage's time and
//! the main thread's share. Single-cell digs and GPU syncs are main-thread work, so
//! their groups measure the serial case only. The GPU
//! sync groups drive `syncDenseTileStore` against a headless renderer whose tile
//! store has no GPU buffer: they time planning, commit, and the queued upload
//! batch, which the bench drops after each sync as a frame copy pass would.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const DigConfig = @import("../game/dig_controller.zig").DigConfig;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const CellCoord = @import("../game/world_system.zig").CellCoord;
const LevelLink = @import("../game/world_system.zig").LevelLink;
const no_link_endpoint = @import("../game/world_terrain.zig").no_link_endpoint;
const DenseCellWrite = @import("../game/world_system.zig").DenseCellWrite;
const DenseChunkWrites = @import("../game/world_system.zig").DenseChunkWrites;
const TerrainEditThreads = @import("../game/world_system.zig").TerrainEditThreads;
const WorldTileChangedEvent = @import("../game/simulation.zig").WorldTileChangedEvent;
const TileId = @import("../game/world_system.zig").TileId;
const invalid_tile_id = @import("../game/world_system.zig").invalid_tile_id;
const level_z_step = @import("../game/world_system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
const Renderer = @import("../render/renderer.zig").Renderer;
const TilemapParams = @import("../render/renderer.zig").TilemapParams;
const tile_store_max_elements = @import("../render/renderer.zig").tile_store_max_elements;
const SpriteBatch = @import("../render/sprite_batch.zig").SpriteBatch;
const suite = @import("suite.zig");

const level_sides = [_]u16{ 256, 1024, 2048 };
const level_counts = [_]u16{ 8, 32, 128 };
const case_encoding: usize = 1000;

const scale_item_counts = blk: {
    var counts: [level_sides.len * level_counts.len]usize = undefined;
    for (level_sides, 0..) |side, side_index| {
        for (level_counts, 0..) |levels, level_index| {
            counts[side_index * level_counts.len + level_index] = @as(usize, side) * case_encoding + levels;
        }
    }
    break :blk counts;
};

// Region sizes of the batched groups, in chunks touched by one edit.
const region_chunk_counts = [_]usize{ 4, 64, 256 };
const region_encoding: usize = 10_000_000;

const region_item_counts = blk: {
    var counts: [region_chunk_counts.len * scale_item_counts.len]usize = undefined;
    for (region_chunk_counts, 0..) |region, region_index| {
        for (scale_item_counts, 0..) |scale, scale_index| {
            counts[region_index * scale_item_counts.len + scale_index] = region * region_encoding + scale;
        }
    }
    break :blk counts;
};

const dig_cell_count: u16 = 64;
const cave_in_levels: u16 = 4;
// Batched edits are independent chunks; one chunk per range is the fixed controls'
// partition.
const edit_range_alignment_items: usize = 1;
// The GPU sync groups render a two-level window: `active_level` and the one below.
const gpu_window_levels_below: u16 = 1;

pub const dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-dig",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runDigCase,
};

pub const ramp_group = suite.BenchmarkGroup{
    .name = "chunk-scale-ramp",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runRampCase,
};

pub const cave_in_group = suite.BenchmarkGroup{
    .name = "chunk-scale-cave-in",
    .defaultItemCounts = regionItemCounts,
    .runCase = runCaveInCase,
};

pub const explosion_fill_group = suite.BenchmarkGroup{
    .name = "chunk-scale-explosion-fill",
    .defaultItemCounts = regionItemCounts,
    .runCase = runExplosionFillCase,
};

pub const gpu_sync_dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-dig",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runGpuSyncDigCase,
};

pub const gpu_sync_level_enter_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-level-enter",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runGpuSyncLevelEnterCase,
};

fn scaleItemCounts(_: suite.Profile) []const usize {
    return &scale_item_counts;
}

fn regionItemCounts(_: suite.Profile) []const usize {
    return &region_item_counts;
}

const Workload = enum { dig, ramp, gpu_sync_dig, gpu_sync_level_enter };

const BatchWorkload = enum { cave_in, explosion_fill };

fn runDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .dig);
}

fn runRampCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .ramp);
}

fn runCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runBatchCase(allocator, io, options, case, item_count, .cave_in);
}

fn runExplosionFillCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runBatchCase(allocator, io, options, case, item_count, .explosion_fill);
}

fn runGpuSyncDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_dig);
}

fn runGpuSyncLevelEnterCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_level_enter);
}

const Fixture = struct {
    world: WorldSystem,
    dirt: TileId,
    tunnel: TileId,
    ramp: TileId,
    side: u16,
    levels: u16,
    // GPU sync groups only: a headless renderer holding the world's tile store.
    renderer: ?Renderer = null,

    fn deinit(self: *Fixture) void {
        if (self.renderer) |*renderer| {
            for (renderer.tile_stores.items) |*store| {
                store.pending_spans.deinit(renderer.allocator);
                store.pending_values.deinit(renderer.allocator);
            }
            renderer.tile_stores.deinit(renderer.allocator);
            renderer.tile_merge_spans.deinit(renderer.allocator);
            renderer.tile_merge_values.deinit(renderer.allocator);
            renderer.batch.deinit();
        }
        self.world.deinit();
        self.* = undefined;
    }

    // Gives the world a tile store with no GPU buffer, large enough that no sync
    // grows it (growth would create a GPU buffer).
    fn attachHeadlessTileStore(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.renderer = Renderer{
            .allocator = allocator,
            .device = undefined,
            .window = undefined,
            .pipeline = undefined,
            .tilemap_pipeline = undefined,
            .sampler = undefined,
            .vertex_streams = undefined,
            .batch_capacity_vertices = 0,
            .batch = SpriteBatch.init(allocator),
        };
        const renderer = &self.renderer.?;
        try renderer.tile_stores.append(allocator, .{
            // Never dereferenced: syncs only validate and queue.
            .buffer = @ptrFromInt(0x1000),
            .element_capacity = tile_store_max_elements,
            .directory_elements = 0,
            .block_elements = 1,
            .params = std.mem.zeroes(TilemapParams),
        });
        self.world.gpu_tiles.store = @fromBackingInt(0);
        self.world.render_window = .{ .levels_below = gpu_window_levels_below };
    }

    // One GPU tile sync; returns the elements it uploads and drops the batch.
    fn syncGpuTiles(self: *Fixture, active_level: u16) !usize {
        const renderer = &self.renderer.?;
        try self.world.syncDenseTileStore(renderer, active_level);
        const store = &renderer.tile_stores.items[0];
        const uploaded = store.pending_values.items.len;
        store.pending_spans.clearRetainingCapacity();
        store.pending_values.clearRetainingCapacity();
        return uploaded;
    }

    // The window's top level for the GPU sync groups: the deepest level is resident.
    fn gpuActiveLevel(self: *const Fixture) u16 {
        return self.levels - 1 - gpu_window_levels_below;
    }

    // Floor layer of `level`; level `i` owns layer `i`.
    fn floor(self: *const Fixture, level: u16) usize {
        _ = self;
        return level;
    }
};

// A grass surface over `levels - 1` solid dirt levels, each one uniform dense band.
fn buildFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16) !Fixture {
    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var meta_owned = true;
    defer if (meta_owned) meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = side,
        .height = side,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const dirt = try world.requireTileByName(&meta, "dirt");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    const ramp = (try DigConfig.fromMeta(&meta)).ramp_tile;
    for (0..levels) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, if (level_index == 0) grass else dirt);
        std.debug.assert(layer == level);
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;
    return .{ .world = world, .dirt = dirt, .tunnel = tunnel, .ramp = ramp, .side = side, .levels = levels };
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload) !suite.RunStats {
    if (case.usesThreadSystem()) return suite.RunStats.skipped("single-cell digs, ramps, and GPU syncs run on the main thread");
    const side: u16 = @intCast(item_count / case_encoding);
    const levels: u16 = @intCast(item_count % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);

    var fixture = try buildFixture(allocator, io, side, levels);
    defer fixture.deinit();
    switch (workload) {
        .gpu_sync_dig => {
            try fixture.attachHeadlessTileStore(allocator);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .gpu_sync_level_enter => {
            try fixture.attachHeadlessTileStore(allocator);
            // 64 mixed chunks on each level the window crosses.
            for (fixture.gpuActiveLevel() - 1..fixture.levels) |level| _ = try digCells(&fixture, @intCast(level), fixture.tunnel);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1);
        },
        .dig, .ramp => {},
    }

    for (0..options.warmup_iterations) |_| {
        _ = try runIteration(&fixture, workload);
        if (workload == .ramp) try undoRamps(&fixture);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var cells_changed: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        cells_changed = try runIteration(&fixture, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), suite.serialBatch(cells_changed, 1));
        if (workload == .ramp) try undoRamps(&fixture);
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written
    // (elements uploaded for the GPU sync groups).
    stats.output_count = cells_changed;
    stats.items_per_second = if (stats.mean_ns == 0) 0 else @intCast(@as(u128, cells_changed) * std.time.ns_per_s / stats.mean_ns);
    return stats;
}

// One timed change and its reversal; returns the cells written, or the elements
// uploaded for the GPU sync groups.
fn runIteration(fixture: *Fixture, workload: Workload) !usize {
    return switch (workload) {
        .dig => digAndRefill(fixture),
        .ramp => digRamps(fixture),
        .gpu_sync_dig => blk: {
            const level = fixture.levels - 1;
            _ = try digCells(fixture, level, fixture.tunnel);
            const split = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            _ = try digCells(fixture, level, fixture.dirt);
            break :blk split + try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .gpu_sync_level_enter => blk: {
            const entered = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            break :blk entered + try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1);
        },
    };
}

fn digAndRefill(fixture: *Fixture) !usize {
    const world = &fixture.world;
    const level = fixture.levels - 1;
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - 4 * chunk;
    var cell_index: u16 = 0;
    while (cell_index < dig_cell_count) : (cell_index += 1) {
        const x = origin + (cell_index % 8) * chunk + 5;
        const y = origin + (cell_index / 8) * chunk + 7;
        world.beginDenseCellWriteReserve();
        try world.reserveDenseCellWrite(layer, x, y, fixture.tunnel);
        _ = try world.setDenseTile(layer, x, y, fixture.tunnel);
        world.beginDenseCellWriteReserve();
        try world.reserveDenseCellWrite(layer, x, y, fixture.dirt);
        _ = try world.setDenseTile(layer, x, y, fixture.dirt);
    }
    return @as(usize, dig_cell_count) * 2;
}

// The ramp workload's cell `cell_index`: one per chunk of an 8x8 chunk square at the
// level center, like the dig workload's.
fn rampCell(fixture: *const Fixture, cell_index: u16) CellCoord {
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - 4 * chunk;
    return .{ .x = origin + (cell_index % 8) * chunk + 5, .y = origin + (cell_index / 8) * chunk + 7 };
}

// 64 ramps on the deepest level, each linked to the level above; returns the ramps dug.
fn digRamps(fixture: *Fixture) !usize {
    const world = &fixture.world;
    const level = fixture.levels - 1;
    const layer = fixture.floor(level);
    var cell_index: u16 = 0;
    while (cell_index < dig_cell_count) : (cell_index += 1) {
        const cell = rampCell(fixture, cell_index);
        if (world.rampLinkOtherLevel(level, cell) != null) return error.RampAlreadyLinked;
        const link = LevelLink{
            .kind = .ramp,
            .level_a = level,
            .cell_a = cell,
            .level_b = level - 1,
            .cell_b = cell,
            .traversal_cost = 1,
            .bidirectional = true,
        };
        world.beginDenseCellWriteReserve();
        try world.reserveDenseCellWrite(layer, cell.x, cell.y, fixture.ramp);
        try world.reserveLevelLink(link);
        if (try world.setDenseTile(layer, cell.x, cell.y, fixture.ramp) == null) return error.RampTileUnchanged;
        try world.addLevelLink(link);
    }
    return dig_cell_count;
}

// Returns the ramp workload to its start state: each ramp cell back to dirt and every
// link dropped. Links are append-only in play, so the bench truncates the link rows
// and clears the ramp chunks' endpoint heads on both levels.
// Relies on WorldSystem internals: `level_links`, `link_endpoint_next`, and
// `LevelTerrain.link_heads` (one head per chunk, `no_link_endpoint` when empty).
fn undoRamps(fixture: *Fixture) !void {
    const world = &fixture.world;
    const level = fixture.levels - 1;
    const layer = fixture.floor(level);
    if (world.levelLinks().len != dig_cell_count) return error.RampLinkCountMismatch;
    var cell_index: u16 = 0;
    while (cell_index < dig_cell_count) : (cell_index += 1) {
        const cell = rampCell(fixture, cell_index);
        if (world.rampLinkOtherLevel(level, cell) != level - 1) return error.RampNotLinked;
        world.beginDenseCellWriteReserve();
        try world.reserveDenseCellWrite(layer, cell.x, cell.y, fixture.dirt);
        if (try world.setDenseTile(layer, cell.x, cell.y, fixture.dirt) == null) return error.RampTileUnchanged;
        const chunk_coord = world.chunkCoordForCell(cell.x, cell.y);
        const chunk_index: usize = @intCast(chunk_coord.y * @as(i32, world.chunksX()) + chunk_coord.x);
        world.level_terrain.items[level].link_heads[chunk_index] = no_link_endpoint;
        world.level_terrain.items[level - 1].link_heads[chunk_index] = no_link_endpoint;
    }
    world.level_links.clearRetainingCapacity();
    world.link_endpoint_next.clearRetainingCapacity();
}

// Writes `tile` into the dig workload's 64 cells on `level`, one per chunk, in one step.
fn digCells(fixture: *Fixture, level: u16, tile: TileId) !usize {
    const world = &fixture.world;
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - 4 * chunk;
    world.beginDenseCellWriteReserve();
    for (0..2) |pass| {
        var cell_index: u16 = 0;
        while (cell_index < dig_cell_count) : (cell_index += 1) {
            const x = origin + (cell_index % 8) * chunk + 5;
            const y = origin + (cell_index / 8) * chunk + 7;
            if (pass == 0) {
                try world.reserveDenseCellWrite(layer, x, y, tile);
            } else {
                _ = try world.setDenseTile(layer, x, y, tile);
            }
        }
    }
    return dig_cell_count;
}

// The two batched edits of one iteration, each the other's reversal, built once in
// chunk-major order: `forward_chunks[i]` and `back_chunks[i]` cover the same cells.
const BatchEdit = struct {
    forward: std.ArrayList(DenseCellWrite) = .empty,
    back: std.ArrayList(DenseCellWrite) = .empty,
    spans: std.ArrayList(ChunkSpan) = .empty,
    forward_chunks: std.ArrayList(DenseChunkWrites) = .empty,
    back_chunks: std.ArrayList(DenseChunkWrites) = .empty,
    events: std.ArrayList(WorldTileChangedEvent) = .empty,

    const ChunkSpan = struct {
        level: u16,
        chunk_x: u16,
        chunk_y: u16,
        start: usize,
        end: usize,
    };

    fn deinit(self: *BatchEdit, allocator: std.mem.Allocator) void {
        self.forward.deinit(allocator);
        self.back.deinit(allocator);
        self.spans.deinit(allocator);
        self.forward_chunks.deinit(allocator);
        self.back_chunks.deinit(allocator);
        self.events.deinit(allocator);
    }

    // Opens the next chunk; chunks open in (level, chunk_y, chunk_x) order.
    fn beginChunk(self: *BatchEdit, allocator: std.mem.Allocator, level: u16, chunk_x: u16, chunk_y: u16) !void {
        const start = self.forward.items.len;
        try self.spans.append(allocator, .{ .level = level, .chunk_x = chunk_x, .chunk_y = chunk_y, .start = start, .end = start });
    }

    fn add(self: *BatchEdit, allocator: std.mem.Allocator, layer: usize, x: u16, y: u16, forward_tile: TileId, back_tile: TileId) !void {
        try self.forward.append(allocator, .{ .layer = @intCast(layer), .x = x, .y = y, .tile = forward_tile });
        try self.back.append(allocator, .{ .layer = @intCast(layer), .x = x, .y = y, .tile = back_tile });
        self.spans.items[self.spans.items.len - 1].end = self.forward.items.len;
    }

    // Builds the chunk lists once every write is in, dropping chunks no cell landed in.
    fn finish(self: *BatchEdit, allocator: std.mem.Allocator) !void {
        for (self.spans.items) |span| {
            if (span.end == span.start) continue;
            try self.forward_chunks.append(allocator, .{ .level = span.level, .chunk_x = span.chunk_x, .chunk_y = span.chunk_y, .writes = self.forward.items[span.start..span.end] });
            try self.back_chunks.append(allocator, .{ .level = span.level, .chunk_x = span.chunk_x, .chunk_y = span.chunk_y, .writes = self.back.items[span.start..span.end] });
        }
        try self.events.ensureTotalCapacity(allocator, self.forward.items.len);
    }
};

// Cave-in: `region_chunks / 4` chunks in a chunk-aligned square at the center of each
// of the four deepest levels, tunnel to be collapsed to dirt and carved back.
fn buildCaveInEdit(allocator: std.mem.Allocator, fixture: *const Fixture, region_chunks: usize) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const square_chunks = std.math.sqrt(region_chunks / cave_in_levels);
    std.debug.assert(square_chunks * square_chunks * cave_in_levels == region_chunks);
    const chunk_edge = default_chunk_size_tiles;
    const origin_chunk: u16 = fixture.side / 2 / chunk_edge - @as(u16, @intCast(square_chunks / 2));
    for (fixture.levels - cave_in_levels..fixture.levels) |level_index| {
        const level: u16 = @intCast(level_index);
        const layer = fixture.floor(level);
        for (0..square_chunks) |row| for (0..square_chunks) |col| {
            const chunk_x = origin_chunk + @as(u16, @intCast(col));
            const chunk_y = origin_chunk + @as(u16, @intCast(row));
            try edit.beginChunk(allocator, level, chunk_x, chunk_y);
            for (0..chunk_edge) |dy| for (0..chunk_edge) |dx| {
                const x = chunk_x * chunk_edge + @as(u16, @intCast(dx));
                const y = chunk_y * chunk_edge + @as(u16, @intCast(dy));
                try edit.add(allocator, layer, x, y, fixture.dirt, fixture.tunnel);
            };
        };
    }
    try edit.finish(allocator);
    return edit;
}

// Explosion: the cells of the deepest level whose centers lie in the disk inscribed
// in a chunk-aligned `sqrt(region_chunks)` square at the level center, blown open
// to empty and filled back with dirt. The square's corner chunks the disk misses
// are not part of the edit.
fn buildExplosionEdit(allocator: std.mem.Allocator, fixture: *const Fixture, region_chunks: usize) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const square_chunks = std.math.sqrt(region_chunks);
    std.debug.assert(square_chunks * square_chunks == region_chunks);
    const chunk_edge = default_chunk_size_tiles;
    const radius: i32 = @intCast(square_chunks * chunk_edge / 2);
    const center: i32 = fixture.side / 2;
    const origin_chunk: u16 = fixture.side / 2 / chunk_edge - @as(u16, @intCast(square_chunks / 2));
    const level = fixture.levels - 1;
    const layer = fixture.floor(level);
    for (0..square_chunks) |row| for (0..square_chunks) |col| {
        const chunk_x = origin_chunk + @as(u16, @intCast(col));
        const chunk_y = origin_chunk + @as(u16, @intCast(row));
        try edit.beginChunk(allocator, level, chunk_x, chunk_y);
        for (0..chunk_edge) |dy| for (0..chunk_edge) |dx| {
            const x = chunk_x * chunk_edge + @as(u16, @intCast(dx));
            const y = chunk_y * chunk_edge + @as(u16, @intCast(dy));
            const offset_x = @as(i32, x) - center;
            const offset_y = @as(i32, y) - center;
            if ((2 * offset_x + 1) * (2 * offset_x + 1) + (2 * offset_y + 1) * (2 * offset_y + 1) > 4 * radius * radius) continue;
            try edit.add(allocator, layer, x, y, invalid_tile_id, fixture.dirt);
        };
    };
    try edit.finish(allocator);
    return edit;
}

// Per-stage time of one iteration's two batched edits.
const BatchTiming = struct {
    plan_ns: u64 = 0,
    write_ns: u64 = 0,

    fn add(self: *BatchTiming, world: *const WorldSystem) void {
        self.plan_ns += world.last_terrain_edit_plan_batch.batch_duration_ns;
        self.write_ns += world.last_terrain_edit_write_batch.batch_duration_ns;
    }
};

fn applyBatch(world: *WorldSystem, chunks: []const DenseChunkWrites, events: *std.ArrayList(WorldTileChangedEvent), threads: ?TerrainEditThreads) !void {
    events.clearRetainingCapacity();
    try world.applyDenseCellWrites(chunks, threads, events);
}

// One timed batched change and its reversal; returns the cells written.
fn runBatchIteration(fixture: *Fixture, edit: *BatchEdit, threads: ?TerrainEditThreads, timing: *BatchTiming) !usize {
    try applyBatch(&fixture.world, edit.forward_chunks.items, &edit.events, threads);
    timing.add(&fixture.world);
    try applyBatch(&fixture.world, edit.back_chunks.items, &edit.events, threads);
    timing.add(&fixture.world);
    return edit.forward.items.len + edit.back.items.len;
}

fn tunersSettled(world: *const WorldSystem) bool {
    return world.terrain_edit_plan_tuner.isSettled() and world.terrain_edit_write_tuner.isSettled();
}

fn runBatchCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: BatchWorkload) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const region_chunks = item_count / region_encoding;
    const scale = item_count % region_encoding;
    const side: u16 = @intCast(scale / case_encoding);
    const levels: u16 = @intCast(scale % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    var fixture = try buildFixture(allocator, io, side, levels);
    defer fixture.deinit();
    // The two deepest levels are GPU resident, so every edit there queues GPU edits;
    // each iteration's sync drains them outside the timed region.
    try fixture.attachHeadlessTileStore(allocator);
    _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
    var edit = switch (workload) {
        .cave_in => try buildCaveInEdit(allocator, &fixture, region_chunks),
        .explosion_fill => try buildExplosionEdit(allocator, &fixture, region_chunks),
    };
    defer edit.deinit(allocator);
    // The cave-in region starts carved, so each iteration collapses then re-carves it.
    if (workload == .cave_in) {
        try applyBatch(&fixture.world, edit.back_chunks.items, &edit.events, null);
        _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
    }

    const world = &fixture.world;
    world.terrain_edit_plan_tuner = suite.adaptiveTunerForCase(case, edit_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    world.terrain_edit_write_tuner = suite.adaptiveTunerForCase(case, edit_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    const edit_threads: ?TerrainEditThreads = if (threads) |*thread_system| .{
        .thread_system = thread_system,
        .plan_tuner = &world.terrain_edit_plan_tuner,
        .write_tuner = &world.terrain_edit_write_tuner,
        .adaptive = case.adaptive,
        .items_per_range = if (case.adaptive) null else case.itemsPerRange(edit_range_alignment_items) orelse 1,
    } else null;

    var unused_timing: BatchTiming = .{};
    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| {
        _ = try runBatchIteration(&fixture, &edit, edit_threads, &unused_timing);
        _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!tunersSettled(world) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runBatchIteration(&fixture, &edit, edit_threads, &unused_timing);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        }
    }
    const plan_settled = if (case.adaptive) world.terrain_edit_plan_tuner.isSettled() else false;
    const write_settled = if (case.adaptive) world.terrain_edit_write_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var plan_total: u128 = 0;
    var write_total: u128 = 0;
    var main_total: u128 = 0;
    var cells_changed: usize = 0;
    for (0..options.iterations) |_| {
        var timing: BatchTiming = .{};
        const start_ns = suite.nowNs(io);
        cells_changed = try runBatchIteration(&fixture, &edit, edit_threads, &timing);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, world.last_terrain_edit_write_batch);
        plan_total += timing.plan_ns;
        write_total += timing.write_ns;
        // Inline stages report no duration, so in the serial case all of it is main.
        main_total += elapsed_ns -| (timing.plan_ns + timing.write_ns);
        _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written; the
    // batches' item count is the chunks one edit touched.
    stats.output_count = cells_changed;
    stats.items_per_second = if (stats.mean_ns == 0) 0 else @intCast(@as(u128, cells_changed) * std.time.ns_per_s / stats.mean_ns);
    stats.batch = suite.batchSummaryFromBatch(world.last_terrain_edit_write_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(world.last_terrain_edit_plan_batch);
    if (stats.iterations > 0) {
        const iterations: u128 = stats.iterations;
        stats.terrain_edit_phases = .{
            .plan_ns = @intCast(plan_total / iterations),
            .write_ns = @intCast(write_total / iterations),
            .main_ns = @intCast(main_total / iterations),
        };
    }
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(world.terrain_edit_write_tuner.report(), write_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(world.terrain_edit_plan_tuner.report(), plan_settled);
    }
    return stats;
}
