// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `WorldSystem`'s first content: the procedural and demo surface worlds and the solid
//! underground level stack, with the procedural ground painted chunk by chunk over the
//! thread system. Free functions over `*WorldSystem`, which exposes the public ones as
//! its methods.

const std = @import("std");
const WorldTilesetMeta = @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const TilemapParams = @import("../../render/renderer.zig").TilemapParams;
const TextureDesc = @import("../../render/resources.zig").TextureDesc;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const runStage = @import("../../app/thread_system.zig").runStage;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const world_terrain = @import("terrain.zig");
const ChunkGeometry = @import("terrain.zig").ChunkGeometry;
const no_sparse_tile = @import("terrain.zig").no_sparse_tile;
const WorldSystem = @import("system.zig").WorldSystem;
const WorldBuildConfig = @import("system.zig").WorldBuildConfig;
const TileId = @import("system.zig").TileId;
const TileFlags = @import("system.zig").TileFlags;
const invalid_tile_id = @import("system.zig").invalid_tile_id;
const level_z_step = @import("system.zig").level_z_step;
const validateChunkGrid = @import("system.zig").validateChunkGrid;
const catalogFlags = @import("system.zig").catalogFlags;

const ProceduralTiles = struct {
    grass: TileId,
    grass_patchy: TileId,
    path: TileId,
    stone: TileId,
    water: TileId,
    shore: TileId,
    cliff: TileId,
    tree: TileId,
    deco: TileId,
};

// The paint's range alignment in chunks: one cache line of its narrowest written
// column (`blocked_counts`), so neighbouring ranges share at most their boundary line
// in every column it writes.
const paint_range_alignment_items = thread_shared_record_alignment / @sizeOf(u16);
comptime {
    // A chunk's cells block is at least one `TileId` (`chunk_size_tiles = 1`).
    for ([_]usize{ @sizeOf(u16), @sizeOf(TileId), @sizeOf(world_terrain.BlockFill), @sizeOf(world_terrain.ChunkBits) }) |element_size| {
        std.debug.assert(paint_range_alignment_items * element_size >= thread_shared_record_alignment);
    }
}

// Threaded procedural fill of one dense layer. Each chunk owns block `chunk` of
// `block_cells` and slot `chunk` of the level's composed bits, so workers write
// disjoint ranges; the layer must be its level's only band and the level must
// have no sparse tiles yet, so the composed bits follow from this layer alone.
const ProceduralBuildContext = struct {
    // The paint's dispatched range count, set before dispatch.
    range_count: usize = 0,
    geom: ChunkGeometry,
    block_cells: []TileId,
    block_fills: []world_terrain.BlockFill,
    blocked_bits: []world_terrain.ChunkBits,
    blocked_counts: []u16,
    catalog_flags: []const TileFlags,
    seed: u64,
    ids: ProceduralTiles,
};

/// The procedural surface world (level 0) of `config`'s size and seed: the catalog,
/// one floor band painted chunk by chunk on `thread_system`, and obstacle sparse
/// tiles, with no underground level (`initProcedural` adds them). The same config
/// builds the same world for any worker count.
pub fn initProceduralFromMeta(
    allocator: std.mem.Allocator,
    meta: *const WorldTilesetMeta,
    config: WorldBuildConfig,
    thread_system: *ThreadSystem,
) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = @max(config.width_tiles, 1),
        .height = @max(config.height_tiles, 1),
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = config.chunk_size_tiles,
        .atlas_texture = atlasTextureDesc(meta),
        .render_window = config.render_window,
    };
    try validateChunkGrid(world.width, world.height, world.chunk_size_tiles);
    errdefer world.deinit();

    try world.buildCatalog(meta);
    const level = try world.addLevel(0);
    const ids = ProceduralTiles{
        .grass = try world.requireTileByName(meta, "grass"),
        .grass_patchy = try world.requireTileByName(meta, "grass_patchy"),
        .path = try world.requireTileByName(meta, "path_0"),
        .stone = try world.requireTileByName(meta, "stone_floor"),
        .water = try world.requireTileByName(meta, "water_1"),
        .shore = try world.requireTileByName(meta, "water_shore_0"),
        .cliff = try world.requireTileByName(meta, "cliff_0"),
        .tree = try world.requireTileByName(meta, "tree_0"),
        .deco = try world.requireTileByName(meta, "deco_0"),
    };

    const ground_layer = try world.addDenseLayer(level, 0, .floor, ids.grass);
    try buildProceduralGround(&world, level, ground_layer, ids, config.seed, thread_system);
    try addProceduralSparseTiles(&world, level, ids, config.seed);
    world.tilemap_params = tilemapParamsFor(meta, world.width, world.height, world.tile_size);
    return world;
}

/// The demo surface covering `bounds_width` x `bounds_height`, cut into
/// `chunk_size_tiles` chunks (`validateChunkGrid`): one walkable floor band with
/// path cross lines and accent tiles, and two obstacle sparse tiles.
pub fn initDemoFromMetaWithChunkSize(
    allocator: std.mem.Allocator,
    meta: *const WorldTilesetMeta,
    bounds_width: f32,
    bounds_height: f32,
    chunk_size_tiles: u16,
) !WorldSystem {
    const tile_size = meta.tileSize();
    const width = try ceilTiles(bounds_width, tile_size);
    const height = try ceilTiles(bounds_height, tile_size);
    var world = WorldSystem{
        .allocator = allocator,
        .width = width,
        .height = height,
        .tile_size = tile_size,
        .chunk_size_tiles = chunk_size_tiles,
        .atlas_texture = atlasTextureDesc(meta),
    };
    try validateChunkGrid(world.width, world.height, world.chunk_size_tiles);
    errdefer world.deinit();

    try world.buildCatalog(meta);
    const level = try world.addLevel(0);

    const grass = try world.requireTileByName(meta, "grass");
    // Walkable accents only, so the surface stays fully walkable.
    const grass_patchy = try world.requireTileByName(meta, "grass_patchy");
    const path = try world.requireTileByName(meta, "path_0");
    const stone = try world.requireTileByName(meta, "stone_floor");
    const deco = try world.requireTileByName(meta, "deco_0");

    const ground_layer = try world.addDenseLayer(level, 0, .floor, grass);
    const mid_y = height / 2;
    const mid_x = width / 2;
    for (0..height) |y| {
        for (0..width) |x| {
            const tile: TileId = if (x == mid_x or y == mid_y)
                path
            else if ((x + y) % 11 == 0)
                grass_patchy
            else if ((x * 3 + y) % 17 == 0)
                stone
            else
                grass;
            _ = try world.setDenseTile(ground_layer, @intCast(x), @intCast(y), tile);
        }
    }

    _ = try world.addSparseTile(level, width / 4, height / 3, deco, 0, .obstacle);
    // Widened so a side past a third of u16 does not wrap; each result is below its side.
    _ = try world.addSparseTile(level, @intCast(@as(u32, width) * 3 / 4), @intCast(@as(u32, height) * 2 / 3), deco, 0, .obstacle);

    world.tilemap_params = tilemapParamsFor(meta, world.width, world.height, world.tile_size);
    return world;
}

/// Adds `underground_count` solid underground planes beneath the surface (level 0),
/// each one step deeper with descending `base_z` so the surface draws on top.
/// Materials alternate `dirt` / `dirt_dark` by depth. Call once on an already-built
/// surface world (its dense layers are the last appended, so no held tile slice is
/// invalidated).
pub fn addUndergroundLevelStack(self: *WorldSystem, meta: *const WorldTilesetMeta, underground_count: u16) !void {
    const dirt = try self.requireTileByName(meta, "dirt");
    const dirt_dark = try self.requireTileByName(meta, "dirt_dark");
    try self.level_base_z.ensureUnusedCapacity(self.allocator, underground_count);
    var depth_index: u16 = 0;
    while (depth_index < underground_count) : (depth_index += 1) {
        const depth_below_surface = depth_index + 1;
        const base_z = -@as(i32, @intCast(depth_below_surface)) * level_z_step;
        const level = try self.addLevel(base_z);
        const fill = if (depth_index % 2 == 0) dirt else dirt_dark;
        _ = try self.addDenseLayer(level, 0, .floor, fill);
    }
}

// Fills one level's only dense band and its composed bits chunk by chunk on the
// thread system: each chunk owns its own block and slot, then the main thread
// returns all-fill blocks and uniform bits to uniform in O(chunks).
fn buildProceduralGround(self: *WorldSystem, level: u16, layer_index: usize, ids: ProceduralTiles, seed: u64, thread_system: *ThreadSystem) !void {
    const geom = self.chunkGeometry();
    const terrain = &self.level_terrain.items[level];
    std.debug.assert(terrain.bandLayers().len == 1 and terrain.bandLayers()[0] == layer_index);
    // The fill composes from the band alone: the level holds no sparse tile yet.
    std.debug.assert(std.mem.allEqual(u32, terrain.sparse_heads, no_sparse_tile));
    const store = &self.dense_layers.items(.store)[layer_index];
    try store.reserveEveryChunk(self.allocator, geom);
    try terrain.blocked.reserveEveryChunk(self.allocator, geom);
    store.materializeEveryChunk(geom);
    terrain.blocked.materializeEveryChunk(geom);

    var build_context = ProceduralBuildContext{
        .geom = geom,
        .block_cells = store.cells.items,
        .block_fills = store.fills.items,
        .blocked_bits = terrain.blocked.bits.items,
        .blocked_counts = terrain.blocked.counts.items,
        .catalog_flags = self.catalog_flags.items,
        .seed = seed,
        .ids = ids,
    };
    // A one-off under the world's fresh paint tuner (`rebuild_tuner_config`).
    const paint_batch = runStage(Dispatch.init(thread_system, &self.ground_build_tuner, .{}), geom.chunkCount(), paint_range_alignment_items, &build_context, &build_context.range_count, buildProceduralChunk);
    if (comptime runtime_perf_log.enabled) self.perf.last_paint_batch = paint_batch;
    store.finishChunkFill();
    terrain.blocked.finishChunkFill(geom);
    terrain.content_revision +%= 1;
    self.content_revision +%= 1;
}

fn addProceduralSparseTiles(self: *WorldSystem, level: u16, ids: ProceduralTiles, seed: u64) !void {
    const geom = self.chunkGeometry();
    var added_blocking = false;
    for (0..geom.chunks_y) |cy| {
        for (0..geom.chunks_x) |cx| {
            const h = hash2(seed ^ 0x9e37_79b9, cx, cy);
            const extent = geom.extent(@intCast(cy * geom.chunks_x + cx));
            const min_x = extent.min_x;
            const min_y = extent.min_y;
            const span_x = extent.cols;
            const span_y = extent.rows;
            const x: u16 = min_x + @as(u16, @intCast((h >> 8) % span_x));
            const y: u16 = min_y + @as(u16, @intCast((h >> 24) % span_y));
            const center_x = @abs(@as(i32, @intCast(x)) - @as(i32, self.width / 2));
            const center_y = @abs(@as(i32, @intCast(y)) - @as(i32, self.height / 2));
            if ((h & 15) == 0 and center_x > 4 and center_y > 4) {
                _ = try self.addSparseTile(level, x, y, ids.tree, 0, .obstacle);
                added_blocking = added_blocking or self.flagsFor(ids.tree).blocks_movement;
            } else if ((h & 63) == 1) {
                _ = try self.addSparseTile(level, x, y, ids.deco, 0, .obstacle);
                added_blocking = added_blocking or self.flagsFor(ids.deco).blocks_movement;
            }
        }
    }
    if (added_blocking) {
        self.level_terrain.items[level].content_revision +%= 1;
        self.content_revision +%= 1;
    }
}

fn buildProceduralChunk(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const build: *ProceduralBuildContext = @ptrCast(@alignCast(context));
    const geom = build.geom;
    const block_cells = geom.blockCells();
    const chunk_count = geom.chunkCount();
    // The range covers chunks; chunk `c` writes only block `c`, fill row `c`, bits
    // slot `c`, and count `c`.
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= chunk_count);
    std.debug.assert(range.index < build.range_count);
    std.debug.assert(build.block_cells.len == chunk_count * block_cells);
    std.debug.assert(build.block_fills.len == chunk_count);
    std.debug.assert(build.blocked_bits.len == chunk_count);
    std.debug.assert(build.blocked_counts.len == chunk_count);
    for (range.start..range.end) |chunk_index| {
        const extent = geom.extent(@intCast(chunk_index));
        const cells = build.block_cells[chunk_index * block_cells ..][0..block_cells];
        const fill = build.block_fills[chunk_index].fill;
        // Out-of-level cells of a border chunk hold the fill and are never written.
        @memset(cells, fill);
        var bits: world_terrain.ChunkBits = @splat(0);
        var blocked_count: u16 = 0;
        for (0..extent.rows) |row| {
            for (0..extent.cols) |col| {
                const x: u16 = @intCast(extent.min_x + col);
                const y: u16 = @intCast(extent.min_y + row);
                const tile = proceduralGroundTile(build.*, x, y);
                const local = (row << geom.shift) | col;
                cells[local] = tile;
                if (catalogFlags(build.catalog_flags, tile).blocks_movement) {
                    world_terrain.setBit(&bits, @intCast(local));
                    blocked_count += 1;
                }
            }
        }
        // A chunk left holding one tile records it so `finishChunkFill` re-uniforms it.
        const unequal_pairs = world_terrain.chainUnequalPairs(cells, geom.shift, extent);
        build.block_fills[chunk_index] = .{ .fill = if (unequal_pairs == 0) cells[0] else fill, .unequal_pairs = unequal_pairs, .changed = true };
        build.blocked_bits[chunk_index] = bits;
        build.blocked_counts[chunk_index] = blocked_count;
    }
}

fn proceduralGroundTile(build: ProceduralBuildContext, x: u16, y: u16) TileId {
    const width = build.geom.width;
    const height = build.geom.height;
    const center_y: i32 = @intCast(height / 2);
    const river_wave = @as(i32, @intCast(hash2(build.seed, x / 12, y / 32) % 9)) - 4;
    const y_i: i32 = @intCast(y);
    if (@abs(y_i - center_y - river_wave) <= 2) return build.ids.water;
    if (@abs(y_i - center_y - river_wave) <= 3) return build.ids.shore;

    const ridge = hash2(build.seed ^ 0xa17a_5eed, x / 8, y / 8);
    if ((ridge & 0xff) < 18 and y > height / 5) return build.ids.cliff;

    if (x == width / 2 or y == height / 2) return build.ids.path;

    const h = hash2(build.seed, x, y);
    if ((h & 31) == 0) return build.ids.stone;
    // The surface accent is walkable, keeping the surface open.
    if ((h & 7) == 0) return build.ids.grass_patchy;
    return build.ids.grass;
}

fn atlasTextureDesc(meta: *const WorldTilesetMeta) TextureDesc {
    const atlas = meta.atlas();
    return .{ .width = atlas.width, .height = atlas.height };
}

// World-constant tilemap shader params. The fragment shader derives the atlas cell
// straight from the tile id as a tight grid (col = id % columns, row = id / columns),
// with tile_size as both the world cell size and the atlas tile pixel size. That
// layout is enforced for every tile at meta load by validateGridEntry, so the shader
// needs no per-tile source rect.
fn tilemapParamsFor(meta: *const WorldTilesetMeta, width: u16, height: u16, tile_size: f32) TilemapParams {
    const atlas = meta.atlas();
    return .{
        .grid = .{
            tile_size,
            @floatFromInt(width),
            @floatFromInt(height),
            @floatFromInt(invalid_tile_id),
        },
        .atlas = .{
            @floatFromInt(meta.columns()),
            @floatFromInt(atlas.width),
            @floatFromInt(atlas.height),
            tile_size,
        },
    };
}

// Tiles covering `value`, at least one. A count past a u16 world side (inf and NaN
// included) fails before any conversion.
fn ceilTiles(value: f32, tile_size: f32) error{LevelCellIndexOverflow}!u16 {
    const tiles = @ceil(value / tile_size);
    if (!(tiles <= std.math.maxInt(u16))) return error.LevelCellIndexOverflow;
    return @intFromFloat(@max(tiles, 1));
}

// Worldgen's own fixed mix, not std's hashes, so a std hash change never moves a
// generated world.
fn hash2(seed: u64, x: anytype, y: anytype) u64 {
    var value = seed;
    value ^= @as(u64, @intCast(x)) *% 0x9e37_79b9_7f4a_7c15;
    value = std.math.rotl(u64, value, 27);
    value ^= @as(u64, @intCast(y)) *% 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 30;
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 27;
    value *%= 0x94d0_49bb_1331_11eb;
    value ^= value >> 31;
    return value;
}

const testWorldMeta = @import("test_support.zig").testWorldMeta;
const testMinimalSurfaceWorld = @import("test_support.zig").testMinimalSurfaceWorld;
const bruteForceLevelBlocked = @import("test_support.zig").bruteForceLevelBlocked;
const TerrainTestTiles = @import("test_support.zig").TerrainTestTiles;

const liveBlockCount = @import("test_support.zig").liveBlockCount;

test "demo bounds past a u16 world side fail loudly instead of converting" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    const tile_size = meta.tileSize();
    const widest = @as(f32, std.math.maxInt(u16)) * tile_size;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, widest, tile_size);
    defer world.deinit();
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), world.width);
    try std.testing.expectError(error.LevelCellIndexOverflow, WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, widest + tile_size, tile_size));
    try std.testing.expectError(error.LevelCellIndexOverflow, WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 1.0e30, 1.0e30));
    try std.testing.expectError(error.LevelCellIndexOverflow, WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, std.math.inf(f32), tile_size));
}

test "addUndergroundLevelStack honors requested depth below an existing surface" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 1, 1);
    defer world.deinit();
    try world.addUndergroundLevelStack(&meta, 10);
    try std.testing.expectEqual(@as(usize, 11), world.levelCount());
    try std.testing.expect(world.denseFloorLayerForLevel(10) != null);
}

test "underground demo levels are solid dirt until a cell is dug walkable" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    try std.testing.expectEqual(@as(usize, 3), world.levelCount());

    // The two underground floors block movement by default (mining: solid until dug).
    try std.testing.expect(world.levelBlocksMovement(1, 2, 2));
    try std.testing.expect(world.levelBlocksMovement(2, 2, 2));
    // The surface plane stays open at the same cell — levels do not collapse.
    try std.testing.expect(!world.levelBlocksMovement(0, 2, 2));

    // Carving a level-1 cell to the walkable tunnel tile opens it.
    const cave_0 = try world.requireTileByName(&meta, "cave_0");
    const floor1 = world.denseFloorLayerForLevel(1).?;
    _ = try world.setDenseTile(floor1, 2, 2, cave_0);
    try std.testing.expect(!world.levelBlocksMovement(1, 2, 2));
}

// 16x12 tiles in 2x2 chunks: 48 chunks, so the paint crosses aligned ranges and its last
// range is partial (32 + 16).
const procedural_range_test_config = WorldBuildConfig{
    .width_tiles = 16,
    .height_tiles = 12,
    .chunk_size_tiles = 2,
    .underground_level_count = 0,
};

test "procedural world build is identical serial and threaded" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var worker_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer worker_threads.deinit();

    var serial = try WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, procedural_range_test_config, &serial_threads);
    defer serial.deinit();
    var threaded = try WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, procedural_range_test_config, &worker_threads);
    defer threaded.deinit();
    // More than one aligned range, the last one partial: the fresh paint tuner's first
    // selection is the full pool.
    try std.testing.expect(threaded.chunkCountPerLevel() > paint_range_alignment_items);
    try std.testing.expect(threaded.chunkCountPerLevel() % paint_range_alignment_items != 0);

    try std.testing.expectEqual(serial.sparse_tiles.len, threaded.sparse_tiles.len);
    for (0..serial.height) |y| for (0..serial.width) |x| {
        const xi: u16 = @intCast(x);
        const yi: u16 = @intCast(y);
        try std.testing.expectEqual(serial.denseTile(0, xi, yi), threaded.denseTile(0, xi, yi));
        try std.testing.expectEqual(serial.levelBlocksMovement(0, xi, yi), threaded.levelBlocksMovement(0, xi, yi));
        // The threaded composition equals a brute-force scan of the band and sparse tiles.
        try std.testing.expectEqual(bruteForceLevelBlocked(&threaded, 0, xi, yi), threaded.levelBlocksMovement(0, xi, yi));
    };
    const serial_store = serial.dense_layers.items(.store)[0];
    const threaded_store = threaded.dense_layers.items(.store)[0];
    for (0..serial.chunkCountPerLevel()) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        try std.testing.expectEqual(serial_store.uniformTile(chunk), threaded_store.uniformTile(chunk));
        try std.testing.expectEqual(serial.levelChunkBlockedForm(0, chunk), threaded.levelChunkBlockedForm(0, chunk));
    }
    try std.testing.expectEqual(liveBlockCount(serial_store), liveBlockCount(threaded_store));
    // The procedural ground is mixed somewhere, so the threaded fill really ran.
    try std.testing.expect(liveBlockCount(threaded_store) > 0);
    try expectUniformExactlyWhenOneTile(&threaded, 0);
}

// Every chunk of `layer` is uniform exactly when its in-level cells hold one tile, by
// brute force over the cells.
fn expectUniformExactlyWhenOneTile(world: *const WorldSystem, layer: usize) !void {
    const geom = world.chunkGeometry();
    const store = world.dense_layers.items(.store)[layer];
    for (0..geom.chunkCount()) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        const extent = geom.extent(chunk);
        const first = world.denseTile(layer, extent.min_x, extent.min_y);
        var one_tile = true;
        for (0..extent.rows) |row| for (0..extent.cols) |col| {
            one_tile = one_tile and world.denseTile(layer, @intCast(extent.min_x + col), @intCast(extent.min_y + row)) == first;
        };
        try std.testing.expectEqual(if (one_tile) @as(?TileId, first) else null, store.uniformTile(chunk));
    }
}

test "procedural ground that paints a chunk with one non-fill tile leaves it uniform" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 18x16 tiles in 4x4 chunks: a short border column of chunks too.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 18,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    const stone = try world.requireTileByName(&meta, "stone_floor");
    const level = try world.addLevel(0);
    const layer = try world.addDenseLayer(level, 0, .floor, tiles.grass);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    const all_stone = ProceduralTiles{
        .grass = stone,
        .grass_patchy = stone,
        .path = stone,
        .stone = stone,
        .water = stone,
        .shore = stone,
        .cliff = stone,
        .tree = stone,
        .deco = stone,
    };
    try buildProceduralGround(&world, level, layer, all_stone, 0x5703e, &threads);
    const store = world.dense_layers.items(.store)[layer];
    for (0..world.chunkCountPerLevel()) |chunk| {
        try std.testing.expectEqual(@as(?TileId, stone), store.uniformTile(@intCast(chunk)));
    }
    try std.testing.expectEqual(@as(usize, 0), liveBlockCount(store));
}

// The range-crossing config, so each fresh world's paint dispatches on the pool.
fn buildProceduralWorldForAllocationTest(allocator: std.mem.Allocator, meta: *const WorldTilesetMeta, threads: *ThreadSystem) !void {
    var world = try WorldSystem.initProceduralFromMeta(allocator, meta, procedural_range_test_config, threads);
    world.deinit();
}

test "procedural world build fails cleanly at every allocation on the multi-worker path (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildProceduralWorldForAllocationTest, .{ &meta, &threads });
}
