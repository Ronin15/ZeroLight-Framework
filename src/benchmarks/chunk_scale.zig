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
//!     open and filled back, each one batched edit. Linear in region chunks. One
//!     extra case (item prefix `1 * 10^10`, 64 chunks at 256² and 8 levels) first
//!     places 32 blocking sparse props in every chunk of the square, so each changed
//!     cell's composed blocked bit also reads its chunk's sparse tiles.
//!   - `chunk-scale-gpu-sync-dig`: the dig workload with a GPU tile sync after the
//!     digs and after the refills (64 blocks taken, then freed). Flat.
//!   - `chunk-scale-gpu-sync-level-enter`: the render window steps one level down
//!     and back, each step one level entering (its window directory and 64 mixed
//!     blocks) and one leaving. Flat across level size and depth.
//!   - `chunk-scale-gpu-sync-pan`: a square window of 2, 6, or 14 chunks over the
//!     two deepest levels pans one chunk across and back, with a visibility update
//!     and a GPU sync after each step; the window and the column it pans into are
//!     all mixed chunks. Each step scans O(layers x e²) window chunks and uploads
//!     the entering column, O(layers x e). Passes when flat across level size and
//!     depth at every edge, and the edge and resident-layer axes match those
//!     orders.
//! The pan and level-enter groups also run 8 and 32 resident layers at 256² and
//! 128 levels (item prefix `layers * 10^9`); every other case renders 2.
//! The GPU sync and batched groups render a fixed 8x8-chunk window over the dig
//! cells (the pan group its own window), so their GPU work follows the window,
//! never the level.
//! Single-cell writes go through the step's reserve seam (`reserveDenseCellWrite`)
//! first. Changes sit on the deepest levels at the level center; each iteration ends
//! at its start state. The item count encodes the case as `level side * 1000 +
//! levels`, plus `region chunks * 10^7` for the two batched groups or `window edge
//! chunks * 10^7` for the pan group. Fixtures and the batches' write lists build
//! once per case outside the timed loop. The batched groups run serial,
//! fixed-thread, and adaptive, with the two deepest levels GPU resident so the
//! merge's render flags are timed; they report each stage's time and the main
//! thread's share.
//! Single-cell digs and GPU syncs are main-thread work, so their groups measure the
//! serial case only. The GPU sync groups drive `syncDenseTileStore` against a
//! headless renderer whose tile store has no GPU buffer: they time planning,
//! commit, and the queued upload batch, which the bench drops after each sync as a
//! frame copy pass would.
//!
//! The `chunk-scale-nav-*` groups add the nav reaction to these changes, with nav built
//! over every level of the same fixture (no render window): each step's change events
//! whose movement blocking flipped are marked dirty and applied as one buffered nav
//! update, as the post-commit reaction does. A config whose nav storage exceeds the
//! bench's nav-size limit is skipped with its figure. `--details` counts the timed
//! reactions that fell back to whole-level work, and its stage shapes are the nav remask
//! and patch of the last level the reaction touched.
//!   - `chunk-scale-nav-dig`: the dig workload's 64 cells dug in one step and refilled in
//!     the next, each step followed by the reaction. Flat.
//!   - `chunk-scale-nav-ramp`: the ramp workload plus the reaction; the untimed reset
//!     refills the cells, drops the links, and applies the reaction. Flat.
//!   - `chunk-scale-nav-cave-in` and `chunk-scale-nav-explosion-fill`: the batched edits,
//!     each followed by the reaction, serial and threaded. `--details` reports the terrain
//!     plan and write stages, the nav reaction (marking and apply), and the rest (the main
//!     thread's share). Linear in region chunks, flat in level size and depth.
//!   - `chunk-scale-nav-level-add`: one level added with a solid floor band, then nav
//!     updated for it. Its revision case (item prefix `1 * 10^7`) first adds a level with a
//!     walkable floor and updates nav (untimed), then times a blocking band added to that
//!     newest level and nav's update. Depth grows by one per iteration (warmup included),
//!     so A/B runs use the same `--warmup` and `--iterations`.
//! Every nav group runs serial and threaded: the threaded cases give the reaction or
//! build the case's thread system (the single-cell world writes stay on the main thread).

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
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
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const SpriteBatch = @import("../render/sprite_batch.zig").SpriteBatch;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const NavUpdateStats = @import("../game/systems/pathfinding.zig").NavUpdateStats;
const min_capacity_floor = @import("../game/systems/pathfinding/types.zig").min_capacity_floor;
const default_max_group_fields = @import("../game/systems/pathfinding/types.zig").default_max_group_fields;
const navSizeCapacity = @import("pathfinding.zig").navSizeCapacity;
const suite = @import("suite.zig");

const level_sides = [_]u16{ 256, 1024, 2048 };
const level_counts = [_]u16{ 8, 32, 128 };
const case_encoding: usize = 1000;
// Encodes the batched groups' region chunks and the pan group's window edge above
// the level side and count.
const case_prefix_encoding: usize = 10_000_000;

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

const region_item_counts = blk: {
    var counts: [region_chunk_counts.len * scale_item_counts.len]usize = undefined;
    for (region_chunk_counts, 0..) |region, region_index| {
        for (scale_item_counts, 0..) |scale, scale_index| {
            counts[region_index * scale_item_counts.len + scale_index] = region * case_prefix_encoding + scale;
        }
    }
    break :blk counts;
};

// Encodes the explosion group's sparse-props case above the region chunks.
const sparse_props_encoding: usize = 10_000_000_000;
// Blocking sparse props per chunk of the sparse-props case: every cell whose
// (3 * x + 5 * y) % 8 is zero, 32 of a 16x16 chunk's cells.
const sparse_props_stride: u16 = 8;
// The sparse-props case's one config: 64 region chunks at 256² and 8 levels.
const sparse_props_item_count: usize = sparse_props_encoding + 64 * case_prefix_encoding + 256 * case_encoding + 8;

const explosion_item_counts = blk: {
    var counts: [region_item_counts.len + 1]usize = undefined;
    @memcpy(counts[0..region_item_counts.len], &region_item_counts);
    counts[region_item_counts.len] = sparse_props_item_count;
    break :blk counts;
};

// Pan group window edges, in chunks; each window and the column it pans into fit
// the smallest level.
const pan_window_edges = [_]u16{ 2, 6, 14 };

// The pan region's columns: the window and the column it pans into.
fn panRegionColumns(window_edge: u16) u16 {
    return window_edge + 1;
}

// The GPU sync groups' resident layers by default: `active_level` and the one below.
const default_resident_layers: u16 = 2;
// The pan and level-enter groups' resident-layer axis, measured at one level size
// and depth deep enough to hold it; the size and depth axes run at the default.
const resident_layer_axis = [_]u16{ 8, 32 };
const resident_layer_axis_scale: usize = @as(usize, level_sides[0]) * case_encoding + level_counts[level_counts.len - 1];
// Encodes a non-default resident-layer count above every other case field.
const resident_layer_encoding: usize = 1_000_000_000;

const pan_item_counts = blk: {
    const scale_cases = pan_window_edges.len * scale_item_counts.len;
    var counts: [scale_cases + pan_window_edges.len * resident_layer_axis.len]usize = undefined;
    for (pan_window_edges, 0..) |edge, edge_index| {
        std.debug.assert(panRegionColumns(edge) <= level_sides[0] / default_chunk_size_tiles);
        for (scale_item_counts, 0..) |scale, scale_index| {
            counts[edge_index * scale_item_counts.len + scale_index] = @as(usize, edge) * case_prefix_encoding + scale;
        }
        for (resident_layer_axis, 0..) |layers, layer_index| {
            counts[scale_cases + edge_index * resident_layer_axis.len + layer_index] =
                @as(usize, layers) * resident_layer_encoding + @as(usize, edge) * case_prefix_encoding + resident_layer_axis_scale;
        }
    }
    break :blk counts;
};

const level_enter_item_counts = blk: {
    var counts: [scale_item_counts.len + resident_layer_axis.len]usize = undefined;
    @memcpy(counts[0..scale_item_counts.len], &scale_item_counts);
    for (resident_layer_axis, scale_item_counts.len..) |layers, index| {
        counts[index] = @as(usize, layers) * resident_layer_encoding + resident_layer_axis_scale;
    }
    break :blk counts;
};

// Elements one pan iteration (a step across and back) uploads: per resident layer
// and step, the entering column's `window_edge` mixed chunks, each a directory word
// and a whole block.
fn expectedPanUploads(window_edge: u16, resident_layers: u16) usize {
    const steps = 2;
    return @as(usize, resident_layers) * steps * window_edge * (1 + tileStoreBlockElements(default_chunk_size_tiles));
}

const dig_cell_count: u16 = 64;
const cave_in_levels: u16 = 4;
// Batched edits are independent chunks; one chunk per range is the fixed controls'
// partition.
const edit_range_alignment_items: usize = 1;
// The fixed render window of the dig, level-enter, and batched groups, in chunks: the
// dig workload's 8x8 chunk square at the level center.
const dig_window_chunks: u16 = 8;

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
    .defaultItemCounts = explosionItemCounts,
    .runCase = runExplosionFillCase,
};

pub const gpu_sync_dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-dig",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runGpuSyncDigCase,
};

pub const gpu_sync_level_enter_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-level-enter",
    .defaultItemCounts = levelEnterItemCounts,
    .runCase = runGpuSyncLevelEnterCase,
};

pub const gpu_sync_pan_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-pan",
    .defaultItemCounts = panItemCounts,
    .runCase = runGpuSyncPanCase,
};

pub const nav_dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-dig",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runNavDigCase,
};

pub const nav_ramp_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-ramp",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runNavRampCase,
};

pub const nav_cave_in_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-cave-in",
    .defaultItemCounts = regionItemCounts,
    .runCase = runNavCaveInCase,
};

pub const nav_explosion_fill_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-explosion-fill",
    .defaultItemCounts = regionItemCounts,
    .runCase = runNavExplosionFillCase,
};

pub const nav_level_add_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-level-add",
    .defaultItemCounts = levelAddItemCounts,
    .runCase = runNavLevelAddCase,
};

// The level-add group's revision case, encoded above the level side and count.
const level_add_revision_case: usize = 1;

const level_add_item_counts = blk: {
    var counts: [2 * scale_item_counts.len]usize = undefined;
    @memcpy(counts[0..scale_item_counts.len], &scale_item_counts);
    for (scale_item_counts, scale_item_counts.len..) |scale, index| {
        counts[index] = level_add_revision_case * case_prefix_encoding + scale;
    }
    break :blk counts;
};

fn levelAddItemCounts(_: suite.Profile) []const usize {
    return &level_add_item_counts;
}

fn scaleItemCounts(_: suite.Profile) []const usize {
    return &scale_item_counts;
}

fn regionItemCounts(_: suite.Profile) []const usize {
    return &region_item_counts;
}

fn explosionItemCounts(_: suite.Profile) []const usize {
    return &explosion_item_counts;
}

fn panItemCounts(_: suite.Profile) []const usize {
    return &pan_item_counts;
}

fn levelEnterItemCounts(_: suite.Profile) []const usize {
    return &level_enter_item_counts;
}

const Workload = enum { dig, ramp, gpu_sync_dig, gpu_sync_level_enter, gpu_sync_pan };

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

fn runGpuSyncPanCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_pan);
}

const Fixture = struct {
    world: WorldSystem,
    dirt: TileId,
    tunnel: TileId,
    ramp: TileId,
    // A blocking sparse prop.
    prop: TileId,
    side: u16,
    levels: u16,
    // GPU sync groups only: a headless renderer holding the world's tile store.
    renderer: ?Renderer = null,
    // Pan group only: the window edge and its start chunk.
    pan_window_edge: u16 = 0,
    // GPU sync groups: levels below the active level in the render window.
    gpu_levels_below: u16 = default_resident_layers - 1,
    pan_origin_chunk_x: u16 = 0,
    pan_origin_chunk_y: u16 = 0,

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
    // grows it (growth would create a GPU buffer), laid out for the render window
    // already set, so no sync creates a store either.
    fn attachHeadlessTileStore(self: *Fixture, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.world.visible_window_set);
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
            .params = std.mem.zeroes(TilemapParams),
        });
        self.world.gpu_tiles.store = .{ .index = 0, .generation = 1 };
        self.world.gpu_tiles.store_side = self.world.render_side;
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
        return self.levels - 1 - self.gpu_levels_below;
    }

    // Sets the pan window `step_chunks` right of its start, around the GPU active
    // level, with no overscan.
    fn setPanWindow(self: *Fixture, step_chunks: u16) !void {
        try self.setChunkWindow(self.pan_origin_chunk_x + step_chunks, self.pan_origin_chunk_y, self.pan_window_edge);
    }

    // Sets the fixed render window over the dig cells' chunk square, with the two
    // deepest levels in the level window.
    fn setDigWindow(self: *Fixture) !void {
        self.world.render_window = .{ .levels_below = self.gpu_levels_below };
        const origin_chunk = self.side / default_chunk_size_tiles / 2 - dig_window_chunks / 2;
        try self.setChunkWindow(origin_chunk, origin_chunk, dig_window_chunks);
    }

    // A rect exactly covering `edge` x `edge` chunks from (min_chunk_x, min_chunk_y).
    fn setChunkWindow(self: *Fixture, min_chunk_x: u16, min_chunk_y: u16, edge: u16) !void {
        const chunk_px = @as(f32, @floatFromInt(default_chunk_size_tiles)) * self.world.tile_size;
        const extent = @as(f32, @floatFromInt(edge)) * chunk_px;
        try self.world.setVisibleChunksForWorldRect(.{
            .x = @as(f32, @floatFromInt(min_chunk_x)) * chunk_px,
            .y = @as(f32, @floatFromInt(min_chunk_y)) * chunk_px,
            .w = extent,
            .h = extent,
        }, 0, self.gpuActiveLevel());
        const region = self.world.visibleChunkRegion().?;
        std.debug.assert(region.min.x == min_chunk_x and region.min.y == min_chunk_y);
        std.debug.assert(region.max_exclusive.x == min_chunk_x + edge and region.max_exclusive.y == min_chunk_y + edge);
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
    const prop = try world.requireTileByName(&meta, "deco_0");
    for (0..levels) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, if (level_index == 0) grass else dirt);
        std.debug.assert(layer == level);
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;
    return .{ .world = world, .dirt = dirt, .tunnel = tunnel, .ramp = ramp, .prop = prop, .side = side, .levels = levels };
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload) !suite.RunStats {
    if (case.usesThreadSystem()) return suite.RunStats.skipped("single-cell digs, ramps, and GPU syncs run on the main thread");
    const encoded_layers = item_count / resident_layer_encoding;
    const resident_layers: u16 = if (encoded_layers == 0) default_resident_layers else @intCast(encoded_layers);
    const window_edge: u16 = @intCast(item_count % resident_layer_encoding / case_prefix_encoding);
    const scale = item_count % case_prefix_encoding;
    const side: u16 = @intCast(scale / case_encoding);
    const levels: u16 = @intCast(scale % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);
    std.debug.assert((workload == .gpu_sync_pan) == (window_edge > 0));

    std.debug.assert(resident_layers == default_resident_layers or workload == .gpu_sync_pan or workload == .gpu_sync_level_enter);
    std.debug.assert(resident_layers + 1 <= levels);
    var fixture = try buildFixture(allocator, io, side, levels);
    defer fixture.deinit();
    fixture.gpu_levels_below = resident_layers - 1;
    switch (workload) {
        .gpu_sync_dig => {
            try fixture.setDigWindow();
            try fixture.attachHeadlessTileStore(allocator);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .gpu_sync_level_enter => {
            try fixture.setDigWindow();
            try fixture.attachHeadlessTileStore(allocator);
            // 64 mixed chunks on each level the window crosses.
            for (fixture.gpuActiveLevel() - 1..fixture.levels) |level| _ = try digCells(&fixture, @intCast(level), fixture.tunnel, null);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1);
        },
        .gpu_sync_pan => {
            fixture.world.render_window = .{ .levels_below = fixture.gpu_levels_below };
            const columns = panRegionColumns(window_edge);
            const chunks_per_side = side / default_chunk_size_tiles;
            std.debug.assert(columns <= chunks_per_side);
            fixture.pan_window_edge = window_edge;
            fixture.pan_origin_chunk_x = (chunks_per_side - columns) / 2;
            fixture.pan_origin_chunk_y = (chunks_per_side - window_edge) / 2;
            for (fixture.gpuActiveLevel()..fixture.levels) |level| {
                try mixRegion(&fixture, @intCast(level), columns, window_edge);
            }
            try fixture.setPanWindow(0);
            try fixture.attachHeadlessTileStore(allocator);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .dig, .ramp => {},
    }

    for (0..options.warmup_iterations) |_| {
        _ = try runIteration(&fixture, workload);
        if (workload == .ramp) try undoRamps(&fixture, null);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var cells_changed: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        cells_changed = try runIteration(&fixture, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), suite.serialBatch(cells_changed, 1));
        if (workload == .ramp) try undoRamps(&fixture, null);
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
        .ramp => digRamps(fixture, null),
        .gpu_sync_dig => blk: {
            const level = fixture.levels - 1;
            _ = try digCells(fixture, level, fixture.tunnel, null);
            const split = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            _ = try digCells(fixture, level, fixture.dirt, null);
            break :blk split + try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .gpu_sync_level_enter => blk: {
            const entered = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            break :blk entered + try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1);
        },
        .gpu_sync_pan => blk: {
            try fixture.setPanWindow(1);
            const panned = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            try fixture.setPanWindow(0);
            const uploaded = panned + try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            if (uploaded != expectedPanUploads(fixture.pan_window_edge, fixture.gpu_levels_below + 1)) return error.PanUploadCountMismatch;
            break :blk uploaded;
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

// A step's tile change events, recorded by the dig and ramp workloads when given one.
const ChangeLog = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(WorldTileChangedEvent) = .empty,

    fn deinit(self: *ChangeLog) void {
        self.events.deinit(self.allocator);
    }

    fn record(self: *ChangeLog, event: WorldTileChangedEvent) !void {
        try self.events.append(self.allocator, event);
    }
};

// 64 ramps on the deepest level, each linked to the level above; returns the ramps dug.
fn digRamps(fixture: *Fixture, changes: ?*ChangeLog) !usize {
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
        const changed = (try world.setDenseTile(layer, cell.x, cell.y, fixture.ramp)) orelse return error.RampTileUnchanged;
        if (changes) |log| try log.record(changed);
        try world.addLevelLink(link);
    }
    return dig_cell_count;
}

// Returns the ramp workload to its start state: each ramp cell back to dirt and every
// link dropped. Links are append-only in play, so the bench truncates the link rows
// and clears the ramp chunks' endpoint heads on both levels.
// Relies on WorldSystem internals: `level_links`, `link_endpoint_next`, and
// `LevelTerrain.link_heads` (one head per chunk, `no_link_endpoint` when empty).
fn undoRamps(fixture: *Fixture, changes: ?*ChangeLog) !void {
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
        const changed = (try world.setDenseTile(layer, cell.x, cell.y, fixture.dirt)) orelse return error.RampTileUnchanged;
        if (changes) |log| try log.record(changed);
        const chunk_coord = world.chunkCoordForCell(cell.x, cell.y);
        const chunk_index: usize = @intCast(chunk_coord.y * @as(i32, world.chunksX()) + chunk_coord.x);
        world.level_terrain.items[level].link_heads[chunk_index] = no_link_endpoint;
        world.level_terrain.items[level - 1].link_heads[chunk_index] = no_link_endpoint;
    }
    world.level_links.clearRetainingCapacity();
    world.link_endpoint_next.clearRetainingCapacity();
}

// Writes `tile` into the dig workload's 64 cells on `level`, one per chunk, in one step.
fn digCells(fixture: *Fixture, level: u16, tile: TileId, changes: ?*ChangeLog) !usize {
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
            } else if (try world.setDenseTile(layer, x, y, tile)) |changed| {
                if (changes) |log| try log.record(changed);
            }
        }
    }
    return dig_cell_count;
}

// Makes every chunk of the pan region on `level` mixed: one tunnel cell per chunk
// in `columns` x `rows` chunks from the pan origin, in one step.
fn mixRegion(fixture: *Fixture, level: u16, columns: u16, rows: u16) !void {
    const world = &fixture.world;
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    world.beginDenseCellWriteReserve();
    for (0..2) |pass| {
        for (0..rows) |row| for (0..columns) |col| {
            const x = (fixture.pan_origin_chunk_x + @as(u16, @intCast(col))) * chunk + 5;
            const y = (fixture.pan_origin_chunk_y + @as(u16, @intCast(row))) * chunk + 7;
            if (pass == 0) {
                try world.reserveDenseCellWrite(layer, x, y, fixture.tunnel);
            } else if (try world.setDenseTile(layer, x, y, fixture.tunnel) == null) {
                return error.PanRegionCellUnchanged;
            }
        };
    }
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

// Places blocking sparse props on the explosion level over its whole region square,
// `sparse_props_stride` cells apart in a skewed pattern.
fn addExplosionProps(fixture: *Fixture, region_chunks: usize) !void {
    const world = &fixture.world;
    const square_chunks = std.math.sqrt(region_chunks);
    std.debug.assert(square_chunks * square_chunks == region_chunks);
    const chunk_edge = default_chunk_size_tiles;
    const origin: u16 = (fixture.side / 2 / chunk_edge - @as(u16, @intCast(square_chunks / 2))) * chunk_edge;
    const square_cells: u16 = @intCast(square_chunks * chunk_edge);
    for (origin..origin + square_cells) |y| for (origin..origin + square_cells) |x| {
        if ((3 * x + 5 * y) % sparse_props_stride != 0) continue;
        // Only a blocking tile reports an obstacle change.
        if (try world.addSparseTile(fixture.levels - 1, @intCast(x), @intCast(y), fixture.prop, 0, .obstacle) == null) return error.SparsePropNotBlocking;
    };
}

// Per-stage time of one iteration's two batched edits.
const BatchTiming = struct {
    plan_ns: u64 = 0,
    write_ns: u64 = 0,
    // Stage time spent on workers: a stage that ran inline reports its duration but
    // ran on the main thread.
    off_main_ns: u64 = 0,

    fn add(self: *BatchTiming, world: *const WorldSystem) void {
        for ([_]BatchStats{ world.last_terrain_edit_plan_batch, world.last_terrain_edit_write_batch }) |batch| {
            if (!batch.ran_inline) self.off_main_ns += batch.batch_duration_ns;
        }
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
    const sparse_props = item_count / sparse_props_encoding != 0;
    std.debug.assert(!sparse_props or workload == .explosion_fill);
    const region_chunks = item_count % sparse_props_encoding / case_prefix_encoding;
    const scale = item_count % case_prefix_encoding;
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
    if (sparse_props) try addExplosionProps(&fixture, region_chunks);
    // The two deepest levels are GPU resident over the fixed window, so edits there
    // flag their layers; each iteration's sync uploads them outside the timed region.
    try fixture.setDigWindow();
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
        // Main is everything but the stages that ran on workers.
        main_total += elapsed_ns -| timing.off_main_ns;
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

// The nav groups' fixture: the chunk-scale world with nav built over every level and no
// entities.
const NavFixture = struct {
    base: Fixture,
    data: DataSystem,
    system: PathfindingSystem,
    changes: ChangeLog,
    // The case's thread system for the dig and ramp reactions; null runs them serial.
    threads: ?*ThreadSystem = null,

    fn deinit(self: *NavFixture) void {
        self.changes.deinit();
        self.system.deinit();
        self.data.deinit();
        self.base.deinit();
        self.* = undefined;
    }

    // Marks every changed cell whose movement blocking flipped, as the post-commit
    // reaction filters its tile events; returns the cells marked.
    fn markBlockingChanges(self: *NavFixture, events: []const WorldTileChangedEvent) !usize {
        var marked: usize = 0;
        for (events) |event| {
            if (event.old_blocks_movement == event.new_blocks_movement) continue;
            try self.system.markNavDirty(event.level, event.x, event.y);
            marked += 1;
        }
        return marked;
    }

    // Applies the marked cells as one buffered nav update; returns 1 when it fell back
    // to relabeling or rebuilding whole levels, else 0.
    fn react(self: *NavFixture, thread_system: ?*ThreadSystem) !NavUpdateStats {
        const stats = try self.system.applyBufferedNavUpdates(&self.data, &self.base.world, thread_system);
        if (stats.incremental_rebuilds != 1) return error.NavReactionUnchanged;
        return stats;
    }

    // The recorded step's reaction: marks its blocking changes (at least `min_marked`)
    // and applies them; returns the fallback count.
    fn reactToChanges(self: *NavFixture, min_marked: usize) !usize {
        const marked = try self.markBlockingChanges(self.changes.events.items);
        self.changes.events.clearRetainingCapacity();
        if (marked < min_marked) return error.NavWorkloadUnmarked;
        return navFallbacks(try self.react(self.threads));
    }
};

// 1 when a nav reaction fell back to whole-level work.
fn navFallbacks(stats: NavUpdateStats) usize {
    return @intFromBool(stats.full_relabel != 0 or stats.edge_cap_fallback != 0);
}

// No path requests: the agent budget stays at its floor.
fn navSizeConfig(side: u16, levels: usize, participant_count: usize) suite.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .participant_count = participant_count,
        .agent_budget = min_capacity_floor,
        .group_fields = default_max_group_fields,
    };
}

fn buildNavFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !NavFixture {
    var base = try buildFixture(allocator, io, side, levels);
    errdefer base.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &base.world, thread_system);
    return .{ .base = base, .data = data, .system = system, .changes = .{ .allocator = allocator } };
}

// Gives the nav reaction's remask and patch stages this case's tuners and control
// config; nav stage items are independent chunks, one per range for the fixed controls.
fn setNavStageControls(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    system.nav_remask_tuner = suite.adaptiveTunerForCase(case, edit_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    system.nav_patch_tuner = suite.adaptiveTunerForCase(case, edit_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    system.nav_thread_adaptive = case.adaptive;
    system.nav_thread_items_per_range = if (case.adaptive) null else case.itemsPerRange(edit_range_alignment_items) orelse 1;
}

fn navStageTunersSettled(system: *const PathfindingSystem) bool {
    return system.nav_remask_tuner.isSettled() and system.nav_patch_tuner.isSettled();
}

fn initCaseThreads(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase) !?ThreadSystem {
    if (!case.usesThreadSystem()) return null;
    return try ThreadSystem.init(allocator, io, .{
        .max_worker_threads = case.maxWorkerThreads(),
        .items_per_range = suite.default_items_per_range,
    });
}

const NavWorkload = enum { dig, ramp };

fn runNavDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavCase(allocator, io, options, case, item_count, .dig);
}

fn runNavRampCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavCase(allocator, io, options, case, item_count, .ramp);
}

fn runNavCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: NavWorkload) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    std.debug.assert(item_count < case_prefix_encoding);
    const side: u16 = @intCast(item_count / case_encoding);
    const levels: u16 = @intCast(item_count % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = navSizeConfig(side, levels, participant_count);
    const group_name = switch (workload) {
        .dig => nav_dig_group.name,
        .ramp => nav_ramp_group.name,
    };
    if (suite.navSizeSkip(group_name, item_count, case, size_config)) |skip| return skip;

    var nav = try buildNavFixture(allocator, io, side, levels, navSizeCapacity(size_config), thread_ptr);
    defer nav.deinit();
    nav.threads = thread_ptr;
    setNavStageControls(&nav.system, case);

    for (0..options.warmup_iterations) |_| {
        _ = try runNavIteration(&nav, workload);
        if (workload == .ramp) try resetNavRamps(&nav);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!navStageTunersSettled(&nav.system) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runNavIteration(&nav, workload);
            if (workload == .ramp) try resetNavRamps(&nav);
        }
    }
    const remask_settled = if (case.adaptive) nav.system.nav_remask_tuner.isSettled() else false;
    const patch_settled = if (case.adaptive) nav.system.nav_patch_tuner.isSettled() else false;
    var accumulator = suite.StatsAccumulator.init(item_count);
    var cells_changed: usize = 0;
    var fallbacks: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const result = try runNavIteration(&nav, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), nav.system.graph.last_remask_batch);
        cells_changed = result.cells;
        fallbacks += result.fallbacks;
        if (workload == .ramp) try resetNavRamps(&nav);
    }
    var stats = accumulator.finish();
    stats.output_count = cells_changed;
    stats.nav_fallbacks = fallbacks;
    stats.items_per_second = suite.itemsPerSecond(cells_changed, stats.mean_ns);
    stats.batch = suite.batchSummaryFromBatch(nav.system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(nav.system.graph.last_patch_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(nav.system.nav_remask_tuner.report(), remask_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(nav.system.nav_patch_tuner.report(), patch_settled);
    }
    return stats;
}

const NavIteration = struct { cells: usize, fallbacks: usize };

// One timed change with its nav reaction. The dig workload digs and refills its 64 cells
// in two steps; the ramp workload digs its 64 ramps. Each step's reaction marks the
// step's blocking changes, every workload cell among them.
fn runNavIteration(nav: *NavFixture, workload: NavWorkload) !NavIteration {
    const level = nav.base.levels - 1;
    switch (workload) {
        .dig => {
            _ = try digCells(&nav.base, level, nav.base.tunnel, &nav.changes);
            var fallbacks = try nav.reactToChanges(dig_cell_count);
            _ = try digCells(&nav.base, level, nav.base.dirt, &nav.changes);
            fallbacks += try nav.reactToChanges(dig_cell_count);
            return .{ .cells = @as(usize, dig_cell_count) * 2, .fallbacks = fallbacks };
        },
        .ramp => {
            const ramps = try digRamps(&nav.base, &nav.changes);
            return .{ .cells = ramps, .fallbacks = try nav.reactToChanges(dig_cell_count) };
        },
    }
}

// Returns the ramp workload and its nav to the start state (untimed).
fn resetNavRamps(nav: *NavFixture) !void {
    try undoRamps(&nav.base, &nav.changes);
    _ = try nav.reactToChanges(dig_cell_count);
}

fn runNavCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavBatchCase(allocator, io, options, case, item_count, .cave_in);
}

fn runNavExplosionFillCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavBatchCase(allocator, io, options, case, item_count, .explosion_fill);
}

// Per-stage time of one iteration's two batched edits and their nav reactions, and the
// reactions' fallbacks.
const NavBatchTiming = struct {
    terrain: BatchTiming = .{},
    nav_ns: u64 = 0,
    // Nav reaction stage time spent on workers.
    nav_off_main_ns: u64 = 0,
    fallbacks: usize = 0,
};

fn navTunersSettled(nav: *const NavFixture) bool {
    return tunersSettled(&nav.base.world) and navStageTunersSettled(&nav.system);
}

// One timed batched change and its reversal, each followed by its nav reaction (marking
// and apply, timed as the nav stage); returns the cells written.
fn runNavBatchIteration(io: std.Io, nav: *NavFixture, edit: *BatchEdit, edit_threads: ?TerrainEditThreads, thread_system: ?*ThreadSystem, timing: *NavBatchTiming) !usize {
    for ([_][]const DenseChunkWrites{ edit.forward_chunks.items, edit.back_chunks.items }) |chunks| {
        try applyBatch(&nav.base.world, chunks, &edit.events, edit_threads);
        timing.terrain.add(&nav.base.world);
        const start_ns = suite.nowNs(io);
        if (try nav.markBlockingChanges(edit.events.items) == 0) return error.NavWorkloadUnmarked;
        const nav_stats = try nav.react(thread_system);
        timing.nav_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        timing.fallbacks += navFallbacks(nav_stats);
        timing.nav_off_main_ns += nav_stats.off_main_stage_ns;
    }
    return edit.forward.items.len + edit.back.items.len;
}

fn runNavBatchCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: BatchWorkload) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const region_chunks = item_count / case_prefix_encoding;
    const scale = item_count % case_prefix_encoding;
    const side: u16 = @intCast(scale / case_encoding);
    const levels: u16 = @intCast(scale % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);

    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = navSizeConfig(side, levels, participant_count);
    const group_name = switch (workload) {
        .cave_in => nav_cave_in_group.name,
        .explosion_fill => nav_explosion_fill_group.name,
    };
    if (suite.navSizeSkip(group_name, item_count, case, size_config)) |skip| return skip;

    var nav = try buildNavFixture(allocator, io, side, levels, navSizeCapacity(size_config), thread_ptr);
    defer nav.deinit();
    var edit = switch (workload) {
        .cave_in => try buildCaveInEdit(allocator, &nav.base, region_chunks),
        .explosion_fill => try buildExplosionEdit(allocator, &nav.base, region_chunks),
    };
    defer edit.deinit(allocator);
    // The cave-in region starts carved, so each iteration collapses then re-carves it.
    if (workload == .cave_in) {
        try applyBatch(&nav.base.world, edit.back_chunks.items, &edit.events, null);
        _ = try nav.markBlockingChanges(edit.events.items);
        _ = try nav.react(null);
    }

    const world = &nav.base.world;
    const system = &nav.system;
    world.terrain_edit_plan_tuner = suite.adaptiveTunerForCase(case, edit_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    world.terrain_edit_write_tuner = suite.adaptiveTunerForCase(case, edit_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    setNavStageControls(system, case);
    const edit_threads: ?TerrainEditThreads = if (threads) |*thread_system| .{
        .thread_system = thread_system,
        .plan_tuner = &world.terrain_edit_plan_tuner,
        .write_tuner = &world.terrain_edit_write_tuner,
        .adaptive = case.adaptive,
        .items_per_range = if (case.adaptive) null else case.itemsPerRange(edit_range_alignment_items) orelse 1,
    } else null;

    var unused_timing: NavBatchTiming = .{};
    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| {
        _ = try runNavBatchIteration(io, &nav, &edit, edit_threads, thread_ptr, &unused_timing);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!navTunersSettled(&nav) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runNavBatchIteration(io, &nav, &edit, edit_threads, thread_ptr, &unused_timing);
        }
    }
    const remask_settled = if (case.adaptive) system.nav_remask_tuner.isSettled() else false;
    const patch_settled = if (case.adaptive) system.nav_patch_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var plan_total: u128 = 0;
    var write_total: u128 = 0;
    var nav_total: u128 = 0;
    var main_total: u128 = 0;
    var fallbacks: usize = 0;
    var cells_changed: usize = 0;
    for (0..options.iterations) |_| {
        var timing: NavBatchTiming = .{};
        const start_ns = suite.nowNs(io);
        cells_changed = try runNavBatchIteration(io, &nav, &edit, edit_threads, thread_ptr, &timing);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, system.graph.last_remask_batch);
        plan_total += timing.terrain.plan_ns;
        write_total += timing.terrain.write_ns;
        nav_total += timing.nav_ns;
        fallbacks += timing.fallbacks;
        // Main is everything but the terrain and nav reaction stages that ran on workers.
        main_total += elapsed_ns -| (timing.terrain.off_main_ns + timing.nav_off_main_ns);
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written.
    stats.output_count = cells_changed;
    stats.nav_fallbacks = fallbacks;
    stats.items_per_second = suite.itemsPerSecond(cells_changed, stats.mean_ns);
    stats.batch = suite.batchSummaryFromBatch(system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(system.graph.last_patch_batch);
    if (stats.iterations > 0) {
        const iterations: u128 = stats.iterations;
        stats.terrain_edit_phases = .{
            .plan_ns = @intCast(plan_total / iterations),
            .write_ns = @intCast(write_total / iterations),
            .nav_ns = @intCast(nav_total / iterations),
            .main_ns = @intCast(main_total / iterations),
        };
    }
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.nav_remask_tuner.report(), remask_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(system.nav_patch_tuner.report(), patch_settled);
    }
    return stats;
}

fn runNavLevelAddCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const case_code = item_count / case_prefix_encoding;
    std.debug.assert(case_code <= level_add_revision_case);
    const revision = case_code == level_add_revision_case;
    const scale = item_count % case_prefix_encoding;
    const side: u16 = @intCast(scale / case_encoding);
    const levels: u16 = @intCast(scale % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);
    // Every iteration (warmup included) adds a level, so the size check holds at the
    // deepest the run gets.
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = navSizeConfig(side, levels + options.warmup_iterations + options.iterations, participant_count);
    if (suite.navSizeSkip(nav_level_add_group.name, item_count, case, size_config)) |skip| return skip;

    var nav = try buildNavFixture(allocator, io, side, levels, navSizeCapacity(size_config), thread_ptr);
    defer nav.deinit();
    nav.threads = thread_ptr;
    for (0..options.warmup_iterations) |_| _ = try levelAddIteration(io, &nav, revision);
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        accumulator.record(try levelAddIteration(io, &nav, revision), suite.serialBatch(1, 1));
    }
    var stats = accumulator.finish();
    stats.output_count = nav.base.world.levelCount();
    // One level (or band) added per iteration.
    stats.items_per_second = suite.itemsPerSecond(1, stats.mean_ns);
    return stats;
}

// One level-add iteration; returns its timed span. The main case adds a level with a
// solid floor band, then updates nav. The revision case first adds a level with a
// walkable floor and updates nav (untimed), then adds a blocking band to that newest
// level and updates nav, so each level gains at most one band.
fn levelAddIteration(io: std.Io, nav: *NavFixture, revision: bool) !u64 {
    const world = &nav.base.world;
    const new_level_z = -@as(i32, @intCast(world.levelCount())) * level_z_step;
    if (revision) {
        const level = try world.addLevel(new_level_z);
        _ = try world.addDenseLayer(level, 0, .floor, nav.base.tunnel);
        try nav.system.rebuildStaticNavGridWithWorld(&nav.data, world, nav.threads);
        const start_ns = suite.nowNs(io);
        _ = try world.addDenseLayer(level, 0, .obstacle, nav.base.dirt);
        try nav.system.rebuildStaticNavGridWithWorld(&nav.data, world, nav.threads);
        return suite.elapsedNs(start_ns, suite.nowNs(io));
    }
    const start_ns = suite.nowNs(io);
    const level = try world.addLevel(new_level_z);
    _ = try world.addDenseLayer(level, 0, .floor, nav.base.dirt);
    try nav.system.rebuildStaticNavGridWithWorld(&nav.data, world, nav.threads);
    return suite.elapsedNs(start_ns, suite.nowNs(io));
}
