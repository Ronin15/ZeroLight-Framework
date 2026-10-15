// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned SoA world/tile storage and render preparation.
//! Persistent world data stores stable tile IDs, level/chunk metadata, and
//! gameplay tile flags. Dense tiles, composed movement-blocked bits, and link
//! endpoints are stored per chunk (`terrain.zig`) behind the accessors here. Atlas source rectangles are resolved from `tileset_meta`
//! once at build time and cached into per-tile `catalog_source_x/y/w/h` columns,
//! so hot-path `sourceRect` lookups never re-touch tileset metadata at runtime.
//! Renderer handles stay outside this owner.

const std = @import("std");
const math = @import("../../core/math.zig");
const RuntimeAssets = @import("../../assets/runtime_assets.zig").RuntimeAssets;
const WorldTilesetMeta = @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const Rect = @import("../../render/renderer.zig").Rect;
const Renderer = @import("../../render/renderer.zig").Renderer;
const TileStoreError = @import("../../render/renderer.zig").TileStoreError;
const TilemapParams = @import("../../render/renderer.zig").TilemapParams;
const sprite_batch = @import("../../render/sprite_batch.zig");
const TextureId = @import("../../render/resources.zig").TextureId;
const TextureDesc = @import("../../render/resources.zig").TextureDesc;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const ActiveRegion = @import("../simulation_scope.zig").ActiveRegion;
const ChunkCoord = @import("../simulation_scope.zig").ChunkCoord;
const render_depth = @import("../render_depth.zig");
const WorldDepth = render_depth.WorldDepth;
const world_interest = @import("interest.zig");
const world_gpu_tiles = @import("gpu_tiles.zig");
const world_render = @import("render.zig");
const world_edit = @import("edit.zig");
const DenseEditScratch = @import("edit.zig").DenseEditScratch;
const ReservedChunk = @import("edit.zig").ReservedChunk;
const DenseLayerRenderWindow = @import("render.zig").DenseLayerRenderWindow;
const DenseRenderScratch = @import("render.zig").DenseRenderScratch;
const RenderLevels = @import("render.zig").RenderLevels;
const SparseWindow = @import("render.zig").SparseWindow;
const VisibleView = @import("render.zig").VisibleView;
const GpuTileMirror = @import("gpu_tiles.zig").GpuTileMirror;
const world_terrain = @import("terrain.zig");
const ChunkBits = @import("terrain.zig").ChunkBits;
const ChunkBitsStore = @import("terrain.zig").ChunkBitsStore;
const ChunkForm = @import("terrain.zig").ChunkForm;
const ChunkGeometry = @import("terrain.zig").ChunkGeometry;
const DenseLayerStore = @import("terrain.zig").DenseLayerStore;
const LevelTerrain = @import("terrain.zig").LevelTerrain;
const no_link_endpoint = @import("terrain.zig").no_link_endpoint;
const no_sparse_tile = @import("terrain.zig").no_sparse_tile;
const no_edit_write = @import("terrain.zig").no_edit_write;
const OrderedIndexSet = @import("../systems/chunk_list_map.zig").OrderedIndexSet;

pub const TileId = @import("terrain.zig").TileId;
pub const invalid_tile_id: TileId = std.math.maxInt(TileId);
pub const default_chunk_size_tiles: u16 = 16;
/// Largest chunk edge. Terrain, nav, and scope share one edge: a power of two in
/// [1, max_chunk_size_tiles]. The terrain's bit and tile blocks are sized from it.
pub const max_chunk_size_tiles: u16 = world_terrain.max_chunk_edge;

pub const ChunkGridError = error{ InvalidChunkSize, LevelCellIndexOverflow, ChunkLabelOverflow };
/// What adding a level can fail with: a grid past its index widths, a level index past
/// `u16`, or allocator OOM (nothing added).
pub const LevelAddError = ChunkGridError || error{ WorldLevelOverflow, OutOfMemory };
/// What a terrain write can fail with: an invalid level, layer, cell, or tile, or
/// allocator OOM; each leaves the world unchanged.
pub const WorldEditError = error{ InvalidWorldLevel, InvalidWorldLayer, InvalidWorldCell, InvalidWorldTile, OutOfMemory };

// `WorldSystem.chunk_geom` before its first level: `chunk_tiles` 0, which no real grid has
// (`ChunkGeometry.empty` has 1), so `chunkGeometry` can assert a level exists.
const no_level_chunk_geom: ChunkGeometry = .{ .width = 0, .height = 0, .chunk_tiles = 0, .shift = 0, .chunks_x = 0, .chunks_y = 0 };

// Cell indices and chunk-local labels are u32 with maxInt as the "none" sentinel.
const chunk_grid_index_sentinel: u64 = std.math.maxInt(u32);

/// O(1) loud index-width check for one level of `width` x `height` cells cut into
/// `chunk_size`-cell chunks: the edge is a power of two in [1, max_chunk_size_tiles],
/// each side and every cell index is below the u32 sentinel (so `ChunkGeometry`'s u32
/// sides hold), and so is the label space `chunks * (chunk_size² + 1)`, which bounds a
/// nav level's node rows. World create, level add, and the nav build call it before
/// sizing anything from these widths.
pub fn validateChunkGrid(width: usize, height: usize, chunk_size: u16) ChunkGridError!void {
    if (chunk_size == 0 or chunk_size > max_chunk_size_tiles or !std.math.isPowerOfTwo(chunk_size)) {
        return error.InvalidChunkSize;
    }
    // A zero side leaves no cell, so the cell-count check alone would pass any other side.
    if (width >= chunk_grid_index_sentinel or height >= chunk_grid_index_sentinel) return error.LevelCellIndexOverflow;
    const cell_count = std.math.mul(u64, width, height) catch return error.LevelCellIndexOverflow;
    if (cell_count >= chunk_grid_index_sentinel) return error.LevelCellIndexOverflow;
    const chunk_edge: u64 = chunk_size;
    const chunks_x = width / chunk_edge + @intFromBool(width % chunk_edge != 0);
    const chunks_y = height / chunk_edge + @intFromBool(height % chunk_edge != 0);
    const chunk_count = std.math.mul(u64, chunks_x, chunks_y) catch return error.ChunkLabelOverflow;
    const label_space = std.math.mul(u64, chunk_count, chunk_edge * chunk_edge + 1) catch return error.ChunkLabelOverflow;
    if (label_space >= chunk_grid_index_sentinel) return error.ChunkLabelOverflow;
}
// Z gap between stacked levels (planes). Exceeds the WorldDepth band span so a
// lower plane's bands never sort above a higher plane's. Levels descend by this
// step: level 0 (surface) is highest, deeper levels lower.
pub const level_z_step: i32 = 16;
// GPU tile blocks pack two tile ids per u32 element (`renderer.zig` `packTileData`).
comptime {
    std.debug.assert(@bitSizeOf(TileId) == 16);
}

pub const TileFlags = packed struct(u8) {
    walkable: bool = false,
    blocks_movement: bool = false,
    blocks_vision: bool = false,
    reserved: u5 = 0,
};

// Half-open tile bounds of a world rect, clamped to the level.
const TileBounds = struct {
    min_x: u16,
    min_y: u16,
    max_x: u16,
    max_y: u16,

    pub fn contains(self: TileBounds, x: u32, y: u32) bool {
        return x >= self.min_x and x < self.max_x and y >= self.min_y and y < self.max_y;
    }
};

/// A world rect's render window: its tile bounds, and the chunks of those tiles widened by
/// the overscan and clamped to the chunk grid (both half-open).
pub const ViewWindow = struct {
    tiles: TileBounds,
    chunks: world_gpu_tiles.ChunkWindow,
};

pub const WorldBuildConfig = struct {
    width_tiles: u16 = 512,
    height_tiles: u16 = 512,
    chunk_size_tiles: u16 = 16,
    seed: u64 = 0x51d1_ea5e_2026_0624,
    /// Underground dense floors below the surface (level 0). Default 31 → 32 total levels.
    underground_level_count: u16 = 31,
    render_window: DenseLayerRenderWindow = .{},
};

// Stable tile-cell coordinate used by persistent world facts (e.g. LevelLink).
// Carries only grid indices, never world-space or live nav/render handles.
pub const CellCoord = struct {
    x: u16,
    y: u16,
};

pub const LevelLinkKind = enum {
    ramp,
    stair,
    teleport,
};

// Persistent inter-level connectivity fact. Holds only stable level indices and
// tile-cell coordinates plus a traversal cost — never live nav node indices,
// renderer/SDL handles, or prepared draw records. Pathfinding converts these to
// nav-graph edges at build/query time.
pub const LevelLink = struct {
    kind: LevelLinkKind,
    level_a: u16,
    cell_a: CellCoord,
    level_b: u16,
    cell_b: CellCoord,
    traversal_cost: u32,
    bidirectional: bool,
};

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

// Threaded procedural fill of one dense layer. Each chunk owns block `chunk` of
// `block_cells` and slot `chunk` of the level's composed bits, so workers write
// disjoint ranges; the layer must be its level's only band and the level must
// have no sparse tiles yet, so the composed bits follow from this layer alone.
const ProceduralBuildContext = struct {
    geom: ChunkGeometry,
    block_cells: []TileId,
    block_fills: []world_terrain.BlockFill,
    blocked_bits: []world_terrain.ChunkBits,
    blocked_counts: []u16,
    catalog_flags: []const TileFlags,
    seed: u64,
    ids: ProceduralTiles,
};

const DenseLayerRow = struct {
    level_index: u16,
    // Position in its level's band list (`LevelTerrain.bands`); fixed at add.
    band: u32,
    base_z: i32,
    depth_band: WorldDepth,
    store: DenseLayerStore,
    // Resident slot in the GPU tile store mirror, or `world_gpu_tiles.no_slot` when
    // the layer is outside the render window.
    gpu_slot: u32,
    // Render-only: a cell changed on this layer while resident since the last GPU
    // sync, which scans its window chunks' change marks. False while not resident.
    render_changed: bool,
};

const SparseTileRow = struct {
    level_index: u16,
    cell_index: u32,
    tile_id: TileId,
    depth_value: i32,
    flags: TileFlags,
    // The row's neighbours in its chunk's list (`LevelTerrain.sparse_heads`), newest
    // first, or `no_sparse_tile`, so an add or a removal relinks it in O(1). Row-index
    // links, not `std.DoublyLinkedList`: std links node pointers, and a swap-remove moves
    // rows of this MultiArrayList.
    chunk_next: u32,
    chunk_prev: u32,
};

pub const WorldSystem = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    tile_size: f32,
    chunk_size_tiles: u16,
    // The level chunk grid of `width`, `height`, and `chunk_size_tiles`, which never
    // change after create. Set when the first level is added: every level enters
    // through `appendLevelBaseZ`, and no chunk storage exists before it.
    chunk_geom: ChunkGeometry = no_level_chunk_geom,

    /// Borrowed atlas metadata used for `sourceRect` lookups. Satisfied by
    /// `RuntimeAssets.worldTilesetMeta()` for production startup, or by
    /// `adoptTilesetMeta` for standalone tests/tools that construct a world
    /// without a long-lived runtime catalog.
    tileset_meta: ?*const WorldTilesetMeta = null,
    owned_tileset_meta: ?WorldTilesetMeta = null,
    catalog_valid: std.ArrayList(bool) = .empty,
    catalog_flags: std.ArrayList(TileFlags) = .empty,
    // O(1) source-rect cache, indexed like catalog_valid/catalog_flags. Avoids a
    // per-tile hash-map lookup into tileset_meta on the per-frame sparse-tile
    // render path.
    catalog_source_x: std.ArrayList(f32) = .empty,
    catalog_source_y: std.ArrayList(f32) = .empty,
    catalog_source_w: std.ArrayList(f32) = .empty,
    catalog_source_h: std.ArrayList(f32) = .empty,

    level_base_z: std.ArrayList(i32) = .empty,
    // Parallel to `level_base_z`: each level's band list, composed blocked bits,
    // and link-endpoint heads, sized by its own chunk count.
    level_terrain: std.ArrayList(LevelTerrain) = .empty,
    // Append-only; a link's endpoints are `2 * index` (a) and `2 * index + 1` (b).
    level_links: std.ArrayList(LevelLink) = .empty,
    // Intrusive per-(level, chunk) endpoint lists over `level_links`, headed by
    // `LevelTerrain.link_heads`; entry `e` is the next endpoint after `e`.
    link_endpoint_next: std.ArrayList(u32) = .empty,
    // Advances with every level's `content_revision`, so a reader checks one value per
    // step and walks levels only when it moved.
    content_revision: u32 = 0,

    // Each row's `store` holds that layer's tiles by chunk.
    dense_layers: std.MultiArrayList(DenseLayerRow) = .{},
    // Chunks given an early block or slot by `reserveDenseCellWrite` in the current
    // reserve scope; the next scope returns the ones no write used to uniform.
    dense_reserved_chunks: std.ArrayList(ReservedChunk) = .empty,
    dense_edit: DenseEditScratch = .{},
    // Grouping scratch of a batch of writes given in any order (`groupDenseCellWrites`),
    // empty between batches: the levels holding a write (popped in order), each level's
    // write chain (first and last write, per level), and one world-wide pair of chunk
    // chain ends reused level by level (every level shares one chunk grid). Grown at
    // level add. The chains link write indices into the caller's `next` slice, not
    // `std.SinglyLinkedList` nodes: the writes are a borrowed slice with no node to embed.
    edit_levels: OrderedIndexSet = .{},
    edit_level_heads: std.ArrayList(u32) = .empty,
    edit_level_tails: std.ArrayList(u32) = .empty,
    edit_chunk_heads: []u32 = &.{},
    edit_chunk_tails: []u32 = &.{},
    // The batched edit's per-stage tuners and last batches (`applyDenseCellWrites`).
    terrain_edit_plan_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    terrain_edit_write_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    last_terrain_edit_plan_batch: BatchStats = .{},
    last_terrain_edit_write_batch: BatchStats = .{},
    // Telemetry: reserves that grew a dense block or composed-bits pool. Pools grow
    // geometrically at their reserve seams; the first growth logs once.
    terrain_pool_grows: u64 = 0,
    terrain_pool_growth_logged: bool = false,
    // Telemetry: reserves that grew the batched edit's scratch; the first logs once.
    dense_edit_scratch_grows: u64 = 0,
    dense_edit_scratch_growth_logged: bool = false,
    // Mirror of the renderer-owned GPU tile store holding the render window's dense
    // layers by chunk; `syncDenseTileStore` uploads what changed. Edits hold no GPU
    // memory: a change on a resident layer sets the layer's `render_changed` and
    // this flag, and the next sync scans that layer's window chunks for blocks
    // marked changed (`BlockFill.changed`). Render-only; never read by simulation.
    gpu_tiles: GpuTileMirror = .{},
    resident_layers_changed: bool = false,
    // The GPU directory side for the last visibility rect: a power of two covering
    // any chunk window a rect of that size can touch, so a pan keeps the layout.
    render_side: u32 = 0,
    dense_render: DenseRenderScratch = .{},
    // The levels the last GPU sync laid out; a change re-derives the resident layers.
    gpu_resident_levels: ?RenderLevels = null,
    gpu_residency_dirty: bool = true,

    // Each row is linked into its (level, chunk) list (`LevelTerrain.sparse_heads`).
    sparse_tiles: std.MultiArrayList(SparseTileRow) = .{},
    sparse_window: SparseWindow = .{},
    // The last visibility update's window and levels, null until the first. Until
    // then nothing renders: the GPU store holds no layer and the sparse window holds
    // no tile. The window changes only when the camera crosses a tile edge, so a
    // still camera or a sub-tile pan leaves it and the sparse window as they are.
    visible: ?VisibleView = null,

    // World atlas dimensions captured at init: source of truth for the tilemap
    // atlas params and the safe-build runtime-texture-match assert.
    atlas_texture: TextureDesc = .{ .width = 0, .height = 0 },
    // World-constant grid + atlas geometry for the tilemap fragment shader. Built
    // once at init; the GPU tile store adds the chunk geometry and resident window,
    // and each composite draw adds its layer chain.
    tilemap_params: TilemapParams = .{ .grid = .{ 0, 0, 0, 0 }, .atlas = .{ 0, 0, 0, 0 } },
    // The dense-layer tilemap quads need (re)submitting into the renderer's static
    // buffer: true at init and when the resident layers or the store change. Never
    // set by a pan: the quads are full-world, the camera lives in the shader, and
    // the chunk window is a store uniform.
    dense_quads_dirty: bool = true,
    // The levels the last dense static submit drew; a change forces a re-submit even
    // without a structural edit. Null forces the first submit.
    submitted_levels: ?RenderLevels = null,
    render_window: DenseLayerRenderWindow = .{},

    interest_markers: world_interest.InterestMarkerStore = .{},

    pub fn initDemo(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        const meta = runtime_assets.worldTilesetMeta() orelse return error.WorldTilesetMetadataUnavailable;
        var world = try initDemoFromMeta(allocator, meta, bounds_width, bounds_height);
        errdefer world.deinit();
        try world.addUndergroundLevels(meta);
        return world;
    }

    pub fn initProcedural(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        config: WorldBuildConfig,
        thread_system: *ThreadSystem,
    ) !WorldSystem {
        const meta = runtime_assets.worldTilesetMeta() orelse return error.WorldTilesetMetadataUnavailable;
        var world = try initProceduralFromMeta(allocator, meta, config, thread_system);
        errdefer world.deinit();
        try world.addUndergroundLevelStack(meta, config.underground_level_count);
        return world;
    }

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
        try world.buildProceduralGround(level, ground_layer, ids, config.seed, thread_system);
        try world.addProceduralSparseTiles(level, ids, config.seed);
        world.tilemap_params = tilemapParamsFor(meta, world.width, world.height, world.tile_size);
        return world;
    }

    pub fn initDemoFromMeta(
        allocator: std.mem.Allocator,
        meta: *const WorldTilesetMeta,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        return initDemoFromMetaWithChunkSize(allocator, meta, bounds_width, bounds_height, default_chunk_size_tiles);
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

    /// Transfers standalone tileset metadata ownership into this world so
    /// `sourceRect` lookups remain valid after the caller's local `meta` ends.
    /// Does not cache a self-pointer: `WorldSystem` is moved by value; read
    /// via `tilesetMeta()`.
    pub fn adoptTilesetMeta(self: *WorldSystem, meta: WorldTilesetMeta) void {
        if (self.owned_tileset_meta) |*owned| owned.deinit();
        self.owned_tileset_meta = meta;
    }

    /// Resolves the tileset metadata to read, preferring an owned value (safe
    /// across moves of `WorldSystem`) over a borrowed pointer set by `buildCatalog`.
    pub fn tilesetMeta(self: *const WorldSystem) ?*const WorldTilesetMeta {
        return if (self.owned_tileset_meta) |*m| m else self.tileset_meta;
    }

    /// Prefer `initDemo` with `RuntimeAssets` so tileset metadata is not parsed
    /// again at world construction. Call `adoptTilesetMeta` when the caller's
    /// `meta` would not outlive the returned world.
    pub fn initDemoFromMetaWithUnderground(
        allocator: std.mem.Allocator,
        meta: *const WorldTilesetMeta,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        var world = try initDemoFromMeta(allocator, meta, bounds_width, bounds_height);
        errdefer world.deinit();
        try world.addUndergroundLevels(meta);
        return world;
    }

    pub fn deinit(self: *WorldSystem) void {
        self.sparse_window.deinit(self.allocator);

        self.sparse_tiles.deinit(self.allocator);

        self.gpu_tiles.deinit(self.allocator);
        self.dense_render.deinit(self.allocator);
        self.dense_reserved_chunks.deinit(self.allocator);
        self.dense_edit.deinit(self.allocator);
        self.edit_levels.deinit(self.allocator);
        self.edit_level_heads.deinit(self.allocator);
        self.edit_level_tails.deinit(self.allocator);
        self.allocator.free(self.edit_chunk_heads);
        self.allocator.free(self.edit_chunk_tails);
        for (self.dense_layers.items(.store)) |*store| store.deinit(self.allocator);
        self.dense_layers.deinit(self.allocator);

        self.link_endpoint_next.deinit(self.allocator);
        self.level_links.deinit(self.allocator);
        for (self.level_terrain.items) |*terrain| terrain.deinit(self.allocator);
        self.level_terrain.deinit(self.allocator);
        self.level_base_z.deinit(self.allocator);

        self.catalog_source_h.deinit(self.allocator);
        self.catalog_source_w.deinit(self.allocator);
        self.catalog_source_y.deinit(self.allocator);
        self.catalog_source_x.deinit(self.allocator);
        self.catalog_flags.deinit(self.allocator);
        self.catalog_valid.deinit(self.allocator);
        if (self.owned_tileset_meta) |*meta| meta.deinit();
        self.owned_tileset_meta = null;
        self.tileset_meta = null;
        self.interest_markers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addInterestMarker(self: *WorldSystem, spec: world_interest.InterestMarker) !world_interest.InterestMarkerId {
        return self.interest_markers.addMarker(spec);
    }

    /// Dynamic sprite-command budget the world contributes per frame: the window's
    /// sparse tiles (dense tiles draw from the retained static buffer). Read after
    /// `setVisibleChunksForWorldRect`.
    pub fn reserveRenderRecords(self: *const WorldSystem) usize {
        return self.sparse_window.tiles.items.len;
    }

    /// Upper bound on dense tilemap composite draws submitted this frame: one per
    /// resident layer, the most `partitionDenseCompositeBuckets` can cut. Read after
    /// `syncDenseTileStore`, which sets the resident layers.
    pub fn maxDenseSubmitDrawCount(self: *const WorldSystem) usize {
        return self.dense_render.layers.items.len;
    }

    /// Tile bounds of `rect` clamped to the world, and chunk bounds widened by
    /// `overscan_chunks` and clamped to the chunk grid. The one chunk-math source
    /// shared by the render visibility window (`setVisibleChunksForWorldRect`)
    /// and the pure simulation scope region (`chunkRegionForWorldRect`), so the
    /// two cannot drift apart. Requires at least one chunk.
    pub fn viewWindowForWorldRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16) ViewWindow {
        std.debug.assert(self.levelCount() > 0);
        const geom = self.chunkGeometry();
        const tile_size = self.tile_size;
        const min_tile_x = floorTileClamped(rect.x, tile_size, self.width);
        const min_tile_y = floorTileClamped(rect.y, tile_size, self.height);
        // The last covered tile is below the u16 width/height, so one past it fits u16.
        const max_tile_x: u16 = @intCast(math.lastCellOfSpan(rect.x, rect.x + rect.w, tile_size, self.width) + 1);
        const max_tile_y: u16 = @intCast(math.lastCellOfSpan(rect.y, rect.y + rect.h, tile_size, self.height) + 1);
        return .{
            .tiles = .{ .min_x = min_tile_x, .min_y = min_tile_y, .max_x = max_tile_x, .max_y = max_tile_y },
            .chunks = .{
                .min_x = (@as(u32, min_tile_x) >> geom.shift) -| overscan_chunks,
                .min_y = (@as(u32, min_tile_y) >> geom.shift) -| overscan_chunks,
                .max_x = @min(geom.chunks_x, ((@as(u32, max_tile_x) - 1) >> geom.shift) + 1 + overscan_chunks),
                .max_y = @min(geom.chunks_y, ((@as(u32, max_tile_y) - 1) >> geom.shift) + 1 + overscan_chunks),
            },
        };
    }

    /// Chunk rectangle covering `rect` plus `overscan_chunks`, clamped to the
    /// world, as an ActiveRegion (level 0). Pure: reads no render visibility
    /// state, so fixed-step simulation scope can derive from a fixed-step view
    /// rect. Returns null when the world has no chunks.
    pub fn chunkRegionForWorldRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16) ?ActiveRegion {
        if (self.levelCount() == 0) return null;
        return activeRegionOf(self.viewWindowForWorldRect(rect, overscan_chunks).chunks);
    }

    /// `chunkRegionForWorldRect(rect, overscan_chunks)` expanded by `halo` chunks
    /// on every side (unclamped) — the simulation cognition active region.
    /// Entities outside it drop to .locomotion. Returns null when the world has
    /// no chunks.
    pub fn cognitionRegionForWorldRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16, halo: u16) ?ActiveRegion {
        const view = self.chunkRegionForWorldRect(rect, overscan_chunks) orelse return null;
        const h: i32 = halo;
        return .{
            .min = .{ .x = view.min.x - h, .y = view.min.y - h },
            .max_exclusive = .{ .x = view.max_exclusive.x + h, .y = view.max_exclusive.y + h },
        };
    }

    /// Sets the render chunk window, the GPU directory side for the rect's size, and
    /// the active level it renders around, and rebuilds the window's sparse list.
    /// O(1) when the window, level, and `render_window` are unchanged and no tile was
    /// added inside the window; otherwise O(window levels × window chunks + V log V)
    /// for the V sparse
    /// tiles in the window, never depending on the world's sparse count, level size,
    /// or depth. Out of memory leaves the window and its sparse list as they were and
    /// the next call retries.
    pub fn setVisibleChunksForWorldRect(self: *WorldSystem, rect: Rect, overscan_chunks: u16, active_level: u16) error{OutOfMemory}!void {
        return world_render.setVisibleChunksForWorldRect(self, rect, overscan_chunks, active_level);
    }

    pub fn worldWidthPixels(self: *const WorldSystem) f32 {
        return @as(f32, @floatFromInt(self.width)) * self.tile_size;
    }

    pub fn worldHeightPixels(self: *const WorldSystem) f32 {
        return @as(f32, @floatFromInt(self.height)) * self.tile_size;
    }

    /// One dense composite draw's slice of `collectDenseSubmitLayers`'s
    /// depth-ascending (deepest-first) output: `submit_layers[start..end]`.
    pub const DenseCompositeBucket = struct {
        start: usize,
        end: usize,
    };

    pub const DenseWindowDepthSpan = struct { min: i32, max: i32 };

    /// The depth span (deepest/shallowest render depth) of the resident dense
    /// layers the next submit draws, or null when none is resident. Read after
    /// `syncDenseTileStore`. O(1).
    pub fn denseWindowDepthSpan(self: *const WorldSystem) ?DenseWindowDepthSpan {
        const depths = self.dense_render.layer_depths.items;
        if (depths.len == 0) return null;
        return .{ .min = depths[0], .max = depths[depths.len - 1] };
    }

    /// The resident dense layers' render depths, ascending (deepest first), as of
    /// the last `syncDenseTileStore`.
    pub fn denseWindowLayerDepths(self: *const WorldSystem) []const i32 {
        return self.dense_render.layer_depths.items;
    }

    /// Scratch for render_prep's interleave candidates: room for one depth per gap
    /// between resident layers, and those gaps' flags cleared. Allocation-free:
    /// sized when the resident set was planned.
    pub fn denseInterleaveScratch(self: *WorldSystem) struct { depths: []i32, gap_filled: []bool } {
        const scratch = &self.dense_render;
        const gaps = scratch.layers.items.len -| 1;
        std.debug.assert(scratch.interleave.capacity >= gaps and scratch.gap_filled.capacity >= gaps);
        scratch.interleave.items.len = gaps;
        scratch.gap_filled.items.len = gaps;
        @memset(scratch.gap_filled.items, false);
        return .{ .depths = scratch.interleave.items, .gap_filled = scratch.gap_filled.items };
    }

    /// The render depth an actor standing on `active_level` draws at. Always an
    /// interleave point, so with nothing else sandwiched the stack still splits at
    /// the actor and a `ceiling_when_underground` plane draws above it.
    pub fn activeLevelActorDepth(self: *const WorldSystem, active_level: u16) i32 {
        return self.worldZForLevel(active_level, 0, .actor);
    }

    /// Submits this frame's resident dense layers as one retained world-space
    /// tilemap quad per composite draw: each draw's fragment shader walks a chain of
    /// layer directories in the world's GPU tile store from its topmost layer,
    /// stopping at the first opaque cell, so a run of layers with nothing sandwiched
    /// between them is one draw independent of world size and window depth.
    /// `interleave_depths` (sorted ascending, deduplicated) are this frame's cut
    /// points: depths something else (a sparse tile, a dynamic entity) needs to
    /// render strictly between two dense layers; each splits the stack into another
    /// draw. Requires `syncDenseTileStore` for the same `active_level` first.
    /// Re-submits on a layer or store change (`dense_quads_dirty`), an
    /// `active_level`/window change, or an interleave-depth-set change, never on a
    /// pan alone: the quads are full-world, the camera lives in the vertex shader,
    /// and the resident chunk window is a store uniform. Allocation-free within the
    /// sync's reserve.
    pub fn submitStaticDenseGeometry(
        self: *WorldSystem,
        renderer: *Renderer,
        runtime_assets: *const RuntimeAssets,
        active_level: u16,
        interleave_depths: []const i32,
    ) error{ WorldTilesetTextureUnavailable, OutOfMemory, Overflow, StaticGeometryTooLarge }!void {
        return world_render.submitStaticDenseGeometry(self, renderer, runtime_assets, active_level, interleave_depths);
    }

    /// Brings the world's GPU tile store in line with the render window around
    /// `active_level`: the dense layers of the window's levels, each over the
    /// render chunk window in a toroidal directory chained topmost-first. Layers
    /// entering upload their directory and their mixed window chunks' blocks; layers
    /// leaving free theirs; a pan across a chunk boundary uploads only the chunks
    /// entering; a changed resident chunk uploads once, its word or its whole block;
    /// all in the next frame copy pass. Creates the store, content-sized, on first
    /// need and whenever the directory side changes; layers past the store's `u32`
    /// width are dropped deepest first and reported once. Call once per frame on
    /// the main thread before `submitStaticDenseGeometry` and swapchain acquisition.
    /// O(1) when nothing changed; O(window chunks) per resident layer changed since the
    /// last sync; O(resident layers × window chunks) when the window, level, or layer
    /// set moves; never depends on chunks or levels outside the window. Every
    /// fallible step (plan, store creation, upload reserve) precedes the mirror
    /// commit, and the queue after it cannot fail, so an error leaves residency and
    /// change marks for a retry. Claims the
    /// store for this frame; the renderer retires it the first frame this is not
    /// called, and the next call re-uploads the window into a new store.
    pub fn syncDenseTileStore(self: *WorldSystem, renderer: *Renderer, active_level: u16) TileStoreError!void {
        return world_render.syncDenseTileStore(self, renderer, active_level);
    }

    /// Submits the window's sparse tiles in depth range `range_index` (below
    /// `sparseDepthRangeCount`) through the dynamic ordered stream, in (cell, tile
    /// id) order. Sparse tiles stay dynamic (they are sparse and change
    /// independently of the dense static field); the renderer merges them with
    /// dynamic entities and the static dense spans by render order. O(tiles in the
    /// range).
    pub fn submitVisibleSparseRange(
        self: *const WorldSystem,
        renderer: *Renderer,
        runtime_assets: *const RuntimeAssets,
        range_index: usize,
    ) error{ WorldTilesetTextureUnavailable, MissingTileSourceRect, OutOfMemory }!void {
        return world_render.submitVisibleSparseRange(self, renderer, runtime_assets, range_index);
    }

    /// `submitVisibleSparseRange` into a CPU sprite `batch` instead of a live
    /// `Renderer`, for headless parity checks and benches. Returns the sprites written.
    pub fn submitVisibleSparseSprites(
        self: *const WorldSystem,
        batch: *sprite_batch.SpriteBatch,
        texture: TextureId,
        range_index: usize,
    ) error{ MissingTileSourceRect, OutOfMemory }!usize {
        return world_render.submitVisibleSparseSprites(self, batch, texture, range_index);
    }

    /// Distinct render depths of the window's sparse tiles, as of the last
    /// `setVisibleChunksForWorldRect`. Ranges are ascending by depth, so walking
    /// them by index is the window's sparse draw order.
    pub fn sparseDepthRangeCount(self: *const WorldSystem) usize {
        return self.sparse_window.ranges.items.len;
    }

    /// The render depth of window sparse range `index`.
    pub fn sparseDepthRangeAt(self: *const WorldSystem, index: usize) i32 {
        return self.sparse_window.ranges.items[index].depth;
    }

    pub fn denseTile(self: *const WorldSystem, layer_index: usize, x: u16, y: u16) TileId {
        std.debug.assert(x < self.width and y < self.height);
        return self.dense_layers.items(.store)[layer_index].tile(self.chunkGeometry(), x, y);
    }

    pub const setDenseTile = world_edit.setDenseTile;
    pub const clearDenseTile = world_edit.clearDenseTile;
    pub const beginDenseCellWriteReserve = world_edit.beginDenseCellWriteReserve;
    pub const reserveDenseCellWrite = world_edit.reserveDenseCellWrite;
    pub const applyDenseCellWrites = world_edit.applyDenseCellWrites;
    pub const groupDenseCellWrites = world_edit.groupDenseCellWrites;
    pub const reserveDenseCellWrites = world_edit.reserveDenseCellWrites;

    pub fn denseLayerCount(self: *const WorldSystem) usize {
        return self.dense_layers.len;
    }

    /// The level a dense layer is a band of.
    pub fn denseLayerLevel(self: *const WorldSystem, layer_index: usize) u16 {
        return self.dense_layers.items(.level_index)[layer_index];
    }

    /// Tile-cell coordinate of a sparse tile, decoded from its stored cell index. A
    /// sparse index is valid only until the next sparse tile removal.
    pub fn sparseTileCellCoord(self: *const WorldSystem, index: usize) CellCoord {
        const cell = self.sparse_tiles.items(.cell_index)[index];
        return .{
            .x = @intCast(cell % self.width),
            .y = @intCast(cell / self.width),
        };
    }

    pub fn levelCount(self: *const WorldSystem) usize {
        return self.level_base_z.items.len;
    }

    /// The deepest valid level index, or 0 when there are no levels. Shared by
    /// every window-membership check that needs `levelInWindow`'s upper bound.
    pub fn maxLevelIndex(self: *const WorldSystem) u16 {
        return if (self.levelCount() == 0) 0 else @intCast(self.levelCount() - 1);
    }

    /// Render/plane z baseline for a level. An actor whose `position_z` equals
    /// this draws in that level's render slice.
    pub fn levelBaseZ(self: *const WorldSystem, level_index: u16) i32 {
        return self.level_base_z.items[level_index];
    }

    /// The dense floor layer for a level (first `.floor` band on it), or null if
    /// the level has none. O(1): the level records it when the band is added.
    pub fn denseFloorLayerForLevel(self: *const WorldSystem, level_index: u16) ?usize {
        if (@as(usize, level_index) >= self.level_terrain.items.len) return null;
        const layer = self.level_terrain.items[level_index].floorLayer() orelse return null;
        return layer;
    }

    /// Whether a level's floor cell is an empty (dug-through) hole. False when the
    /// level has no floor layer or the cell is out of bounds.
    pub fn denseFloorIsEmpty(self: *const WorldSystem, level_index: u16, x: u16, y: u16) bool {
        if (x >= self.width or y >= self.height) return false;
        const layer = self.denseFloorLayerForLevel(level_index) orelse return false;
        return self.denseTile(layer, x, y) == invalid_tile_id;
    }

    /// If a ramp link touches `(level, cell)`, returns the level on its other end
    /// (the plane you'd traverse to); the oldest such link wins. Also the dedupe
    /// check for ramp digging. O(link endpoints in the cell's chunk).
    pub fn rampLinkOtherLevel(self: *const WorldSystem, level_index: u16, cell: CellCoord) ?u16 {
        if (@as(usize, level_index) >= self.level_terrain.items.len) return null;
        if (cell.x >= self.width or cell.y >= self.height) return null;
        var endpoints = self.levelChunkLinkEndpoints(level_index, self.chunkGeometry().chunkOf(cell.x, cell.y));
        // Newest first, so the last match is the oldest.
        var oldest: ?u16 = null;
        while (endpoints.next()) |endpoint| {
            if (endpoint.kind != .ramp) continue;
            if (endpoint.cell.x == cell.x and endpoint.cell.y == cell.y) oldest = endpoint.other_level;
        }
        return oldest;
    }

    /// Which end of a `LevelLink` an endpoint is.
    pub const LinkSide = enum { a, b };

    /// One link endpoint in a (level, chunk): the link's row in `levelLinks()`, the
    /// end that lies here, and the link's other end.
    pub const LinkEndpoint = struct {
        link: u32,
        side: LinkSide,
        kind: LevelLinkKind,
        cell: CellCoord,
        other_level: u16,
        other_cell: CellCoord,
        traversal_cost: u32,
        bidirectional: bool,
    };

    /// Walks one (level, chunk)'s link endpoints, newest first. Valid until the next
    /// link add.
    pub const LinkEndpointIterator = struct {
        links: []const LevelLink,
        next_endpoints: []const u32,
        endpoint: u32,

        pub fn next(self: *LinkEndpointIterator) ?LinkEndpoint {
            if (self.endpoint == no_link_endpoint) return null;
            const endpoint = self.endpoint;
            self.endpoint = self.next_endpoints[endpoint];
            const link = self.links[endpoint / 2];
            const at_a = endpoint % 2 == 0;
            return .{
                .link = endpoint / 2,
                .side = if (at_a) .a else .b,
                .kind = link.kind,
                .cell = if (at_a) link.cell_a else link.cell_b,
                .other_level = if (at_a) link.level_b else link.level_a,
                .other_cell = if (at_a) link.cell_b else link.cell_a,
                .traversal_cost = link.traversal_cost,
                .bidirectional = link.bidirectional,
            };
        }
    };

    /// The link endpoints in `chunk` (level-local, `chunkY * chunksX + chunkX`) on
    /// `level_index`, newest first; empty for an invalid level or chunk. O(1) to
    /// create, O(1) per endpoint.
    pub fn levelChunkLinkEndpoints(self: *const WorldSystem, level_index: u16, chunk: u32) LinkEndpointIterator {
        var endpoints = LinkEndpointIterator{
            .links = self.level_links.items,
            .next_endpoints = self.link_endpoint_next.items,
            .endpoint = no_link_endpoint,
        };
        if (@as(usize, level_index) >= self.level_terrain.items.len) return endpoints;
        const heads = self.level_terrain.items[level_index].link_heads;
        if (chunk < heads.len) endpoints.endpoint = heads[chunk];
        return endpoints;
    }

    /// The number of link endpoints `levelChunkLinkEndpoints(level_index, chunk)` yields;
    /// 0 for an invalid level or chunk. O(1).
    pub fn levelChunkLinkEndpointCount(self: *const WorldSystem, level_index: u16, chunk: u32) u32 {
        if (@as(usize, level_index) >= self.level_terrain.items.len) return 0;
        const counts = self.level_terrain.items[level_index].link_counts;
        return if (chunk < counts.len) counts[chunk] else 0;
    }

    /// Per-level composed navigability: whether any dense band on the level or any
    /// sparse obstacle on it blocks the cell. Out-of-range x/y returns blocked,
    /// as an out-of-range dense tile does; an invalid level also returns blocked
    /// (fail-closed) so a bad index can never expose phantom open cells to the
    /// pathfinder. O(1): the chunk's composed-bits entry plus one bit.
    pub fn levelBlocksMovement(self: *const WorldSystem, level_index: u16, x: u16, y: u16) bool {
        if (@as(usize, level_index) >= self.level_terrain.items.len) return true;
        if (x >= self.width or y >= self.height) return true;
        const geom = self.chunkGeometry();
        return self.level_terrain.items[level_index].blocked.get(geom.chunkOf(x, y), geom.localOf(x, y));
    }

    /// One level's composed movement-blocked bits with the geometry that indexes
    /// them, for a reader that tests many cells of one level (a line-of-sight
    /// ray): for an in-bounds cell, `blocked.get(geom.chunkOf(x, y),
    /// geom.localOf(x, y))` equals `levelBlocksMovement`. The caller bounds-checks
    /// cells. Valid while the world is not mutated (a level add can move it).
    pub const LevelBlockedView = struct {
        blocked: *const ChunkBitsStore,
        geom: ChunkGeometry,
    };

    /// `LevelBlockedView` for `level_index`, or null for an invalid level (readers
    /// fail closed, as `levelBlocksMovement` does). O(1).
    pub fn levelBlockedView(self: *const WorldSystem, level_index: u16) ?LevelBlockedView {
        if (@as(usize, level_index) >= self.level_terrain.items.len) return null;
        return .{ .blocked = &self.level_terrain.items[level_index].blocked, .geom = self.chunkGeometry() };
    }

    /// The chunk's composed movement-blocked form on `level_index`: every cell open,
    /// every cell blocked, or mixed (read cells through `levelBlocksMovement`). O(1).
    /// `chunk` is level-local (`chunkY * chunksX + chunkX`).
    pub fn levelChunkBlockedForm(self: *const WorldSystem, level_index: u16, chunk: u32) ChunkForm {
        return self.level_terrain.items[level_index].blocked.form(chunk);
    }

    /// A mixed chunk's composed movement-blocked bits on `level_index` (bit
    /// `row * chunk_size_tiles + column` per in-level cell, out-of-level bits clear), or
    /// null for an OPEN or BLOCKED chunk. Valid until the level's next terrain write. O(1).
    pub fn levelChunkBlockedBits(self: *const WorldSystem, level_index: u16, chunk: u32) ?*const ChunkBits {
        const blocked = &self.level_terrain.items[level_index].blocked;
        if (blocked.form(chunk) != .mixed) return null;
        return &blocked.bits.items[blocked.dir[chunk]];
    }

    /// The level's content revision: it changes whenever the level's composed
    /// movement-blocked bits change through a path that emits no per-cell event (a blocking
    /// dense layer add, a procedural fill). Compared with `!=`; O(1).
    pub fn levelContentRevision(self: *const WorldSystem, level_index: u16) u32 {
        return self.level_terrain.items[level_index].content_revision;
    }

    /// The world-wide content revision: it changes with every level's content revision, so
    /// a reader compares it once and walks `levelContentRevision` only when it moved. O(1).
    pub fn contentRevision(self: *const WorldSystem) u32 {
        return self.content_revision;
    }

    /// Reserves everything `addLevelLink(link)` needs without committing it: the
    /// link row and its two endpoint entries (each level holds its chunk heads from
    /// create). Validates the link first; at 2^31 - 1 links it fails as `OutOfMemory`, like
    /// the allocator. O(1) amortized. Call before a world mutate that must pair with
    /// `addLevelLink`.
    pub fn reserveLevelLink(self: *WorldSystem, link: LevelLink) error{ InvalidWorldLevel, InvalidWorldCell, OutOfMemory }!void {
        try self.validateLevelLink(link);
        // Two endpoint entries per link stay below the u32 list sentinel: exhausting it needs
        // 2^32 - 2 live endpoint entries, so it fails as the allocator does.
        if (self.level_links.items.len >= no_link_endpoint / 2) return error.OutOfMemory;
        try self.level_links.ensureUnusedCapacity(self.allocator, 1);
        try self.link_endpoint_next.ensureUnusedCapacity(self.allocator, 2);
    }

    /// Appends a persistent inter-level link and indexes both endpoints by chunk.
    /// Allocation-free after `reserveLevelLink(link)`; otherwise it reserves first, so
    /// an OOM adds nothing. O(1) after the reserve.
    pub fn addLevelLink(self: *WorldSystem, link: LevelLink) error{ InvalidWorldLevel, InvalidWorldCell, OutOfMemory }!void {
        try self.reserveLevelLink(link);
        const geom = self.chunkGeometry();
        const endpoint_a: u32 = @intCast(self.level_links.items.len * 2);
        self.level_links.appendAssumeCapacity(link);
        const terrain_a = &self.level_terrain.items[link.level_a];
        const chunk_a = geom.chunkOf(link.cell_a.x, link.cell_a.y);
        self.link_endpoint_next.appendAssumeCapacity(terrain_a.link_heads[chunk_a]);
        terrain_a.link_heads[chunk_a] = endpoint_a;
        terrain_a.link_counts[chunk_a] += 1;
        const terrain_b = &self.level_terrain.items[link.level_b];
        const chunk_b = geom.chunkOf(link.cell_b.x, link.cell_b.y);
        self.link_endpoint_next.appendAssumeCapacity(terrain_b.link_heads[chunk_b]);
        terrain_b.link_heads[chunk_b] = endpoint_a + 1;
        terrain_b.link_counts[chunk_b] += 1;
    }

    fn validateLevelLink(self: *const WorldSystem, link: LevelLink) error{ InvalidWorldLevel, InvalidWorldCell }!void {
        try self.validateLevelIndex(link.level_a);
        try self.validateLevelIndex(link.level_b);
        if (link.cell_a.x >= self.width or link.cell_a.y >= self.height) return error.InvalidWorldCell;
        if (link.cell_b.x >= self.width or link.cell_b.y >= self.height) return error.InvalidWorldCell;
    }

    pub fn levelLinks(self: *const WorldSystem) []const LevelLink {
        return self.level_links.items;
    }

    pub fn sparseTileCount(self: *const WorldSystem) usize {
        return self.sparse_tiles.len;
    }

    /// A sparse index is valid only until the next sparse tile removal.
    pub fn sparseTileBlocksMovement(self: *const WorldSystem, index: usize) bool {
        if (index >= self.sparse_tiles.len) return false;
        return self.sparse_tiles.items(.flags)[index].blocks_movement;
    }

    pub fn cellRect(self: *const WorldSystem, x: u16, y: u16) ?Rect {
        if (x >= self.width or y >= self.height) return null;
        return .{
            .x = @as(f32, @floatFromInt(x)) * self.tile_size,
            .y = @as(f32, @floatFromInt(y)) * self.tile_size,
            .w = self.tile_size,
            .h = self.tile_size,
        };
    }

    /// Maps a world-space point to its containing cell, or `null` when the point
    /// lies outside the world bounds. Inverse of `cellRect`; traversal-safe.
    pub fn cellContaining(self: *const WorldSystem, world_x: f32, world_y: f32) ?struct { x: u16, y: u16 } {
        if (world_x < 0 or world_y < 0) return null;
        const cell_x = @as(u32, @intFromFloat(world_x / self.tile_size));
        const cell_y = @as(u32, @intFromFloat(world_y / self.tile_size));
        if (cell_x >= self.width or cell_y >= self.height) return null;
        return .{ .x = @intCast(cell_x), .y = @intCast(cell_y) };
    }

    /// The chunk holding cell (x, y). Pure arithmetic on the chunk edge, so it needs no
    /// level.
    pub fn chunkCoordForCell(self: *const WorldSystem, x: u16, y: u16) struct { x: i32, y: i32 } {
        return .{ .x = x / self.chunk_size_tiles, .y = y / self.chunk_size_tiles };
    }

    /// Canonical world-space float position → chunk coordinate, clamped to world
    /// bounds. The scope chunk-derivation pass (`SimulationScopeSystem.deriveChunks`)
    /// mirrors this formula over the movement-body range each step.
    pub fn chunkCoordForWorldPos(self: *const WorldSystem, world_x: f32, world_y: f32) ChunkCoord {
        const tx: u16 = @intCast(math.worldPosToCell(world_x, self.tile_size, self.width));
        const ty: u16 = @intCast(math.worldPosToCell(world_y, self.tile_size, self.height));
        const raw = self.chunkCoordForCell(tx, ty);
        return .{ .x = raw.x, .y = raw.y };
    }

    /// Camera-visible chunk rectangle as an ActiveRegion. Returns null when no
    /// visibility window has been set yet (e.g. before the first render frame).
    /// Render-only: the window follows the interpolated render camera, so no
    /// simulation path may read it — fixed-step scope uses
    /// `chunkRegionForWorldRect` / `cognitionRegionForWorldRect` instead.
    pub fn visibleChunkRegion(self: *const WorldSystem) ?ActiveRegion {
        const view = self.visible orelse return null;
        if (self.levelCount() == 0) return null;
        return activeRegionOf(view.window.chunks);
    }

    /// Adds an empty level (no bands, every chunk open, no link endpoints). Touches
    /// only its own directories: O(chunks per level), whatever the depth.
    pub fn addLevel(self: *WorldSystem, base_z: i32) LevelAddError!u16 {
        return self.appendLevelBaseZ(base_z);
    }

    // Every level of a world, whether built, literal-constructed, or added in play,
    // enters here, so the loud index-width checks run before anything is sized
    // from them. All growth precedes the commit, so an OOM adds no level.
    fn appendLevelBaseZ(self: *WorldSystem, base_z: i32) LevelAddError!u16 {
        try validateChunkGrid(self.width, self.height, self.chunk_size_tiles);
        const index = self.level_base_z.items.len;
        if (index > std.math.maxInt(u16)) return error.WorldLevelOverflow;
        const geom = ChunkGeometry.init(self.width, self.height, self.chunk_size_tiles);
        std.debug.assert(index == 0 or std.meta.eql(self.chunk_geom, geom));
        self.chunk_geom = geom;
        try self.level_base_z.ensureUnusedCapacity(self.allocator, 1);
        try self.level_terrain.ensureUnusedCapacity(self.allocator, 1);
        _ = try self.edit_levels.reserve(self.allocator, index + 1);
        try self.edit_level_heads.ensureUnusedCapacity(self.allocator, 1);
        try self.edit_level_tails.ensureUnusedCapacity(self.allocator, 1);
        if (self.edit_chunk_heads.len < geom.chunkCount()) {
            const heads = try self.allocator.alloc(u32, geom.chunkCount());
            errdefer self.allocator.free(heads);
            const tails = try self.allocator.alloc(u32, geom.chunkCount());
            @memset(heads, no_edit_write);
            self.allocator.free(self.edit_chunk_heads);
            self.allocator.free(self.edit_chunk_tails);
            self.edit_chunk_heads = heads;
            self.edit_chunk_tails = tails;
        }
        const terrain = try LevelTerrain.init(self.allocator, geom.chunkCount());
        self.level_terrain.appendAssumeCapacity(terrain);
        self.level_base_z.appendAssumeCapacity(base_z);
        self.edit_level_heads.appendAssumeCapacity(no_edit_write);
        self.edit_level_tails.appendAssumeCapacity(no_edit_write);
        // The deepest level bounds the render window's dense submit and GPU
        // residency. The visible sparse count is unchanged: the new level is empty.
        self.dense_quads_dirty = true;
        self.gpu_residency_dirty = true;
        return @intCast(index);
    }

    /// Adds a dense band on `level_index`, every chunk uniform at `fill_tile`, at load
    /// or in play; never refused for capacity. O(chunks per level): the layer's
    /// directory, plus marking the level's composed chunks BLOCKED when `fill_tile`
    /// blocks movement; the level's band list grows geometrically. A layer on a level
    /// in the render window enters the GPU tile store at the next sync.
    ///
    /// Every growth is reserved before the band list, layer row, and composed bits
    /// are written, so an OOM leaves them retryable.
    pub fn addDenseLayer(self: *WorldSystem, level_index: u16, base_z: i32, depth: WorldDepth, fill_tile: TileId) error{ InvalidWorldLevel, InvalidWorldTile, OutOfMemory }!usize {
        try self.validateLevelIndex(level_index);
        try self.validateTileId(fill_tile);

        const terrain = &self.level_terrain.items[level_index];
        const layer_index = self.dense_layers.len;
        // Layer indices stay below `no_floor_layer`: exhausting them needs 2^32 - 1 live layers,
        // so it fails as the allocator does.
        if (layer_index >= world_terrain.no_floor_layer) return error.OutOfMemory;
        try self.dense_layers.ensureUnusedCapacity(self.allocator, 1);
        try terrain.bands.ensureUnusedCapacity(self.allocator, 1);
        var store = try DenseLayerStore.init(self.allocator, self.chunkCountPerLevel(), fill_tile);
        errdefer store.deinit(self.allocator);

        // Commit: band list, layer row, and composed bits are all infallible from here.
        self.dense_layers.appendAssumeCapacity(.{
            .level_index = level_index,
            // At most one band per dense layer, and layer indices are below `no_floor_layer`
            // (checked above).
            .band = @intCast(terrain.bands.items.len),
            .base_z = base_z,
            .depth_band = depth,
            .store = store,
            .gpu_slot = world_gpu_tiles.no_slot,
            .render_changed = false,
        });
        terrain.bands.appendAssumeCapacity(@intCast(layer_index));
        if (depth == .floor and terrain.floor_layer == world_terrain.no_floor_layer) terrain.floor_layer = @intCast(layer_index);
        if (self.flagsFor(fill_tile).blocks_movement) {
            for (0..terrain.blocked.dir.len) |chunk| terrain.blocked.setChunk(@intCast(chunk), true);
            terrain.content_revision +%= 1;
            self.content_revision +%= 1;
        }
        // The window's draws and GPU residency include the new layer from the next frame.
        self.dense_quads_dirty = true;
        self.gpu_residency_dirty = true;
        return layer_index;
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
            const level = try self.appendLevelBaseZ(base_z);
            const fill = if (depth_index % 2 == 0) dirt else dirt_dark;
            _ = try self.addDenseLayer(level, 0, .floor, fill);
        }
    }

    /// Adds the two solid underground planes beneath the surface (level 0): a dirt
    /// floor one step down, a dark floor two steps down. Digging a hole in a plane
    /// reveals the one below. The demo world's two-plane stack
    /// (`addUndergroundLevelStack`).
    pub fn addUndergroundLevels(self: *WorldSystem, meta: *const WorldTilesetMeta) !void {
        try self.addUndergroundLevelStack(meta, 2);
    }

    pub const addSparseTile = world_edit.addSparseTile;
    pub const reserveClearCellBlocking = world_edit.reserveClearCellBlocking;
    pub const clearCellBlocking = world_edit.clearCellBlocking;

    /// Builds the tile catalog of a directly constructed world, before its first
    /// level. Borrows `meta` for `sourceRect` lookups. Production paths keep metadata
    /// alive via `RuntimeAssets`; standalone callers must call `adoptTilesetMeta`.
    pub fn buildCatalog(self: *WorldSystem, meta: *const WorldTilesetMeta) !void {
        self.tileset_meta = meta;
        const count = catalogCapacity(meta);
        try self.catalog_valid.ensureTotalCapacity(self.allocator, count);
        try self.catalog_flags.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_x.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_y.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_w.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_h.ensureTotalCapacity(self.allocator, count);
        for (0..count) |_| {
            self.catalog_valid.appendAssumeCapacity(false);
            self.catalog_flags.appendAssumeCapacity(.{});
            self.catalog_source_x.appendAssumeCapacity(0);
            self.catalog_source_y.appendAssumeCapacity(0);
            self.catalog_source_w.appendAssumeCapacity(0);
            self.catalog_source_h.appendAssumeCapacity(0);
        }

        for (0..meta.tileCount()) |index| {
            const tile = meta.tileAtIndex(index) orelse continue;
            const tile_index: usize = tile.id;
            self.catalog_valid.items[tile_index] = true;
            self.catalog_flags.items[tile_index] = .{
                .walkable = tile.properties.walkable,
                .blocks_movement = tile.properties.blocks_movement,
                .blocks_vision = tile.properties.blocks_vision,
            };
            self.catalog_source_x.items[tile_index] = tile.x;
            self.catalog_source_y.items[tile_index] = tile.y;
            self.catalog_source_w.items[tile_index] = tile.width;
            self.catalog_source_h.items[tile_index] = tile.height;
        }
    }

    /// The atlas source rect of `tile_id`, or null for a tile outside the catalog.
    pub fn sourceRect(self: *const WorldSystem, tile_id: TileId) ?Rect {
        const index: usize = tile_id;
        if (index >= self.catalog_valid.items.len or !self.catalog_valid.items[index]) return null;
        return .{
            .x = self.catalog_source_x.items[index],
            .y = self.catalog_source_y.items[index],
            .w = self.catalog_source_w.items[index],
            .h = self.catalog_source_h.items[index],
        };
    }

    /// The catalog flags of `tile_id`; empty flags (nothing blocks) for a tile outside
    /// the catalog. O(1).
    pub fn flagsFor(self: *const WorldSystem, tile_id: TileId) TileFlags {
        return catalogFlags(self.catalog_flags.items, tile_id);
    }

    /// The level chunk grid. Requires a level.
    pub fn chunkGeometry(self: *const WorldSystem) ChunkGeometry {
        std.debug.assert(self.chunk_geom.chunk_tiles != no_level_chunk_geom.chunk_tiles);
        return self.chunk_geom;
    }

    pub fn requireTileByName(self: *const WorldSystem, meta: *const WorldTilesetMeta, name: []const u8) !TileId {
        _ = self;
        const tile = meta.tileByName(name) orelse return error.RequiredWorldTileMissing;
        return tile.id;
    }

    /// Row-major index of cell (x, y), which must be inside the level.
    pub fn cellIndex(self: *const WorldSystem, x: u16, y: u16) u32 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return @intCast(@as(usize, y) * @as(usize, self.width) + @as(usize, x));
    }

    /// Fails with `error.InvalidWorldLevel` unless `level_index` names an existing level.
    pub fn validateLevelIndex(self: *const WorldSystem, level_index: u16) error{InvalidWorldLevel}!void {
        if (@as(usize, level_index) >= self.level_base_z.items.len) return error.InvalidWorldLevel;
    }

    /// Fails with `error.InvalidWorldTile` unless `tile_id` is in the catalog.
    pub fn validateTileId(self: *const WorldSystem, tile_id: TileId) error{InvalidWorldTile}!void {
        if (!self.isValidTileId(tile_id)) return error.InvalidWorldTile;
    }

    fn isValidTileId(self: *const WorldSystem, tile_id: TileId) bool {
        return catalogValid(self.catalog_valid.items, tile_id);
    }

    /// The render depth of `local_z` in `depth` on `level_index`, clamped to `i32`.
    pub fn worldZForLevel(self: *const WorldSystem, level_index: u16, local_z: i32, depth: WorldDepth) i32 {
        const level_z: i64 = @as(i64, self.level_base_z.items[level_index]);
        const value = level_z + @as(i64, local_z) + @as(i64, render_depth.worldZ(depth));
        const min: i64 = std.math.minInt(i32);
        const max: i64 = std.math.maxInt(i32);
        return @intCast(@max(min, @min(max, value)));
    }

    /// Level-local chunk grid width (every level shares one grid). Requires a level.
    pub fn chunksX(self: *const WorldSystem) u16 {
        // At most the u16 width.
        return @intCast(self.chunkGeometry().chunks_x);
    }

    /// Level-local chunk grid height. See `chunksX`.
    pub fn chunksY(self: *const WorldSystem) u16 {
        return @intCast(self.chunkGeometry().chunks_y);
    }

    /// Chunks per level, the length of every per-level chunk directory. Requires a level.
    pub fn chunkCountPerLevel(self: *const WorldSystem) usize {
        return self.chunkGeometry().chunkCount();
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
        _ = thread_system.parallelForWithOptions(geom.chunkCount(), &build_context, buildProceduralChunk, .{
            .items_per_range = 1,
            .range_alignment_items = 1,
            .adaptive = false,
        });
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
};

fn buildProceduralChunk(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const build: *ProceduralBuildContext = @ptrCast(@alignCast(context));
    const geom = build.geom;
    const block_cells = geom.blockCells();
    const chunk_count = geom.chunkCount();
    // The dispatched range indexes chunks (one per range); chunk `c` writes only
    // block `c`, fill row `c`, bits slot `c`, and count `c`.
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= chunk_count);
    std.debug.assert(range.index < chunk_count);
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

/// Whether `tile_id` is in the catalog column `catalog_valid` (`WorldSystem.catalog_valid`).
/// Takes the column, not the world, so a worker job reads it without the world. O(1).
pub fn catalogValid(catalog_valid: []const bool, tile_id: TileId) bool {
    const index: usize = tile_id;
    return index < catalog_valid.len and catalog_valid[index];
}

/// The flags of `tile_id` in the catalog column `catalog_flags`; empty flags for a tile
/// outside it. Takes the column, not the world, so a worker job reads it. O(1).
pub fn catalogFlags(catalog_flags: []const TileFlags, tile_id: TileId) TileFlags {
    const index: usize = tile_id;
    if (index >= catalog_flags.len) return .{};
    return catalog_flags[index];
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

fn catalogCapacity(meta: *const WorldTilesetMeta) usize {
    var max_id: usize = 0;
    for (0..meta.tileCount()) |index| {
        const tile = meta.tileAtIndex(index) orelse continue;
        max_id = @max(max_id, tile.id);
    }
    return max_id + 1;
}

// Tiles covering `value`, at least one. A count past a u16 world side (inf and NaN
// included) fails before any conversion.
fn ceilTiles(value: f32, tile_size: f32) error{LevelCellIndexOverflow}!u16 {
    const tiles = @ceil(value / tile_size);
    if (!(tiles <= std.math.maxInt(u16))) return error.LevelCellIndexOverflow;
    return @intFromFloat(@max(tiles, 1));
}

fn floorTileClamped(value: f32, tile_size: f32, max_tiles: u16) u16 {
    return @intCast(math.worldPosToCell(value, tile_size, max_tiles));
}

// The chunk window as a simulation-scope region (level 0).
fn activeRegionOf(chunks: world_gpu_tiles.ChunkWindow) ActiveRegion {
    std.debug.assert(chunks.max_x > chunks.min_x and chunks.max_y > chunks.min_y);
    // Chunk indices are below the u16-wide grid, so they fit i32.
    return .{
        .min = .{ .x = @intCast(chunks.min_x), .y = @intCast(chunks.min_y) },
        .max_exclusive = .{ .x = @intCast(chunks.max_x), .y = @intCast(chunks.max_y) },
    };
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
const WorldTileChangedEvent = @import("../simulation.zig").WorldTileChangedEvent;
const DenseCellWrite = @import("edit.zig").DenseCellWrite;
const DenseChunkWrites = @import("edit.zig").DenseChunkWrites;

test "world dense layer uses row-major indexing" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    try std.testing.expectEqual(@as(u16, 3), world.width);
    try std.testing.expectEqual(@as(u16, 2), world.height);
    try std.testing.expectEqual(@as(u32, 0), world.cellIndex(0, 0));
    try std.testing.expectEqual(@as(u32, 1), world.cellIndex(1, 0));
    try std.testing.expectEqual(@as(u32, 3), world.cellIndex(0, 1));

    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.setDenseTile(0, 2, 1, grass);
    try std.testing.expectEqual(grass, world.denseTile(0, 2, 1));
}

test "world rejects invalid tile ids before render" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();

    const invalid = invalid_tile_id;
    try std.testing.expectError(error.InvalidWorldTile, world.addDenseLayer(0, 0, .floor, invalid));
    try std.testing.expectError(error.InvalidWorldTile, world.setDenseTile(0, 0, 0, invalid));
    try std.testing.expectError(error.InvalidWorldTile, world.addSparseTile(0, 0, 0, invalid, 0, .obstacle));
}

test "world chunks map cells by chunk size" {
    // Pure coord math: two chunks wide/tall is enough; no catalog or demo paint.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 2 * default_chunk_size_tiles,
        .height = 2 * default_chunk_size_tiles,
        .tile_size = 32,
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    defer world.deinit();

    const first = world.chunkCoordForCell(0, 0);
    try std.testing.expectEqual(@as(i32, 0), first.x);
    try std.testing.expectEqual(@as(i32, 0), first.y);
    const next = world.chunkCoordForCell(default_chunk_size_tiles, default_chunk_size_tiles);
    try std.testing.expectEqual(@as(i32, 1), next.x);
    try std.testing.expectEqual(@as(i32, 1), next.y);
}

test "world create rejects a chunk size that is zero, not a power of two, or above the maximum" {
    for ([_]u16{ 0, 3, 6, 12, 2 * max_chunk_size_tiles }) |bad_chunk_size| {
        var world = WorldSystem{
            .allocator = std.testing.allocator,
            .width = 16,
            .height = 16,
            .tile_size = 32,
            .chunk_size_tiles = bad_chunk_size,
        };
        defer world.deinit();
        try std.testing.expectError(error.InvalidChunkSize, world.addLevel(0));
        try std.testing.expectEqual(@as(usize, 0), world.levelCount());
    }
    var chunk_size: u16 = 1;
    while (chunk_size <= max_chunk_size_tiles) : (chunk_size *= 2) {
        try validateChunkGrid(16, 16, chunk_size);
    }

    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    try std.testing.expectError(error.InvalidChunkSize, WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, .{
        .width_tiles = 16,
        .height_tiles = 16,
        .chunk_size_tiles = 2 * max_chunk_size_tiles,
        .underground_level_count = 0,
    }, &threads));
}

test "chunk label width fails loudly at its u32 boundary" {
    // chunk_size 1 gives 2 labels per chunk: 65535 x 32768 cells is the largest
    // 65535-wide level whose label space stays below the sentinel.
    try validateChunkGrid(65535, 32768, 1);
    try std.testing.expectError(error.ChunkLabelOverflow, validateChunkGrid(65535, 32769, 1));
    // Largest edge: a 2048² level fits; a u16-wide level does not.
    try validateChunkGrid(2048, 2048, max_chunk_size_tiles);
    try std.testing.expectError(error.ChunkLabelOverflow, validateChunkGrid(65535, 65535, max_chunk_size_tiles));
    // Cell indices reach the sentinel before any label does.
    try std.testing.expectError(error.LevelCellIndexOverflow, validateChunkGrid(65537, 65535, max_chunk_size_tiles));
    try std.testing.expectError(error.LevelCellIndexOverflow, validateChunkGrid(std.math.maxInt(usize), 2, 1));
    // A side at the u32 sentinel fails even when the other side leaves no cell.
    try std.testing.expectError(error.LevelCellIndexOverflow, validateChunkGrid(std.math.maxInt(u32), 0, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, validateChunkGrid(0, @as(usize, 1) << 32, 1));
    try validateChunkGrid(std.math.maxInt(u32) - 1, 0, 1);

    // A world over the label boundary is refused at its first level, before any storage.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 65535,
        .height = 32769,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try std.testing.expectError(error.ChunkLabelOverflow, world.addLevel(0));
    try std.testing.expectEqual(@as(usize, 0), world.levelCount());
}

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

test "world add level keeps chunks renderable without manual rebuild" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);

    for (world.level_terrain.items) |terrain| {
        try std.testing.expectEqual(world.chunkCountPerLevel(), terrain.blocked.dir.len);
    }
}

test "world add level preserves the existing visible chunk window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 2,
        .height = 1,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    // Window over chunk (1,0) only: chunk (0,0) is hidden.
    try world.setVisibleChunksForWorldRect(.{ .x = meta.tileSize(), .y = 0, .w = meta.tileSize(), .h = meta.tileSize() }, 0, 0);
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);

    const region = world.visibleChunkRegion() orelse return error.ExpectedRegion;
    try std.testing.expect(!region.containsChunk(.{ .x = 0, .y = 0 }));
    try std.testing.expect(region.containsChunk(.{ .x = 1, .y = 0 }));
}

test "world dense and sparse rendering respects z levels and chunk level filtering" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    _ = try world.addSparseTile(level1, 0, 0, deco, 0, .obstacle);

    try std.testing.expectEqual(@as(usize, 2), world.level_terrain.items.len);

    try std.testing.expectEqual(render_depth.worldZ(.floor), world.worldZForLevel(level0, 0, .floor));
    try std.testing.expectEqual(@as(i32, 8), world.worldZForLevel(level1, 0, .floor));
    try std.testing.expectEqual(@as(i32, 9), world.worldZForLevel(level1, 0, .obstacle));
}

test "the visible chunk region covers exactly the chunks a world rect touches" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 4×4 tiles, chunk_size=2 → 2×2 chunk grid; each full chunk is 4 cells.
    const tile_size = meta.tileSize();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = tile_size,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level, 0, .floor, grass);

    const chunk_pixels = @as(f32, @floatFromInt(2)) * tile_size;
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = chunk_pixels, .h = chunk_pixels }, 0, 0);
    var region = world.visibleChunkRegion() orelse return error.ExpectedRegion;
    try std.testing.expectEqual(ChunkCoord{ .x = 0, .y = 0 }, region.min);
    try std.testing.expectEqual(ChunkCoord{ .x = 1, .y = 1 }, region.max_exclusive);

    try world.setVisibleChunksForWorldRect(.{ .x = chunk_pixels, .y = chunk_pixels, .w = chunk_pixels, .h = chunk_pixels }, 0, 0);
    region = world.visibleChunkRegion() orelse return error.ExpectedRegion;
    try std.testing.expectEqual(ChunkCoord{ .x = 1, .y = 1 }, region.min);
    try std.testing.expectEqual(ChunkCoord{ .x = 2, .y = 2 }, region.max_exclusive);
}

test "level blocks movement is the OR of dense bands and sparse obstacles" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const deco = try world.requireTileByName(&meta, "deco_0");

    // Two dense bands, both grass-filled (non-blocking), then a blocker placed in
    // a different cell of each band so neither cell is covered by both bands.
    const band_a = try world.addDenseLayer(level, 0, .floor, grass);
    const band_b = try world.addDenseLayer(level, 0, .obstacle, grass);
    _ = try world.setDenseTile(band_a, 1, 1, tree);
    _ = try world.setDenseTile(band_b, 5, 3, tree);
    // A sparse obstacle on the same level contributes to the composed mask.
    _ = try world.addSparseTile(level, 6, 6, deco, 0, .obstacle);

    // Each blocker is reported by the composed level query.
    try std.testing.expect(world.levelBlocksMovement(level, 1, 1));
    try std.testing.expect(world.levelBlocksMovement(level, 5, 3));
    try std.testing.expect(world.levelBlocksMovement(level, 6, 6));
    // An untouched open cell stays open.
    try std.testing.expect(!world.levelBlocksMovement(level, 0, 0));
    try std.testing.expect(!world.levelBlocksMovement(level, 4, 4));
    // Out-of-range cells are blocked.
    try std.testing.expect(world.levelBlocksMovement(level, world.width, 0));
    try std.testing.expect(world.levelBlocksMovement(level, 0, world.height));
    // An invalid level fails closed.
    try std.testing.expect(world.levelBlocksMovement(7, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), world.levelCount());
}

test "level navigability does not collapse across levels" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    const tree = try world.requireTileByName(&meta, "tree_0");

    const band0 = try world.addDenseLayer(level0, 0, .floor, grass);
    const band1 = try world.addDenseLayer(level1, 0, .floor, grass);
    _ = band0;
    // Block cell (2,2) on level 1 only.
    _ = try world.setDenseTile(band1, 2, 2, tree);

    try std.testing.expectEqual(@as(usize, 2), world.levelCount());
    try std.testing.expect(world.levelBlocksMovement(level1, 2, 2));
    // The same cell on level 0 must stay open: levels do not collapse.
    try std.testing.expect(!world.levelBlocksMovement(level0, 2, 2));
}

test "levelBlocksMovement scopes sparse obstacles to their own level at the same cell" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const level2 = try world.addLevel(20);
    const deco = try world.requireTileByName(&meta, "deco_0");

    // Same cell coordinate, obstacle placed on level 1 only. Level 0 and level
    // 2 share the coordinate but must stay open — proves the per-level sparse
    // index does not leak another level's obstacle into this cell's query.
    _ = try world.addSparseTile(level1, 4, 4, deco, 0, .obstacle);

    try std.testing.expect(!world.levelBlocksMovement(level0, 4, 4));
    try std.testing.expect(world.levelBlocksMovement(level1, 4, 4));
    try std.testing.expect(!world.levelBlocksMovement(level2, 4, 4));
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

test "level link store round-trips and validates inputs" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    _ = try world.addLevel(0);
    _ = try world.addLevel(10);
    try std.testing.expectEqual(@as(usize, 0), world.levelLinks().len);

    const link = LevelLink{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 1, .y = 2 },
        .level_b = 1,
        .cell_b = .{ .x = 3, .y = 4 },
        .traversal_cost = 5,
        .bidirectional = true,
    };
    try world.addLevelLink(link);

    const links = world.levelLinks();
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqual(LevelLinkKind.stair, links[0].kind);
    try std.testing.expectEqual(@as(u16, 1), links[0].level_b);
    try std.testing.expectEqual(@as(u16, 3), links[0].cell_b.x);
    try std.testing.expectEqual(@as(u32, 5), links[0].traversal_cost);
    try std.testing.expect(links[0].bidirectional);

    // Invalid level index is rejected.
    try std.testing.expectError(error.InvalidWorldLevel, world.addLevelLink(.{
        .kind = .ramp,
        .level_a = 0,
        .cell_a = .{ .x = 0, .y = 0 },
        .level_b = 2,
        .cell_b = .{ .x = 0, .y = 0 },
        .traversal_cost = 1,
        .bidirectional = false,
    }));
    // Out-of-bounds cell is rejected.
    try std.testing.expectError(error.InvalidWorldCell, world.addLevelLink(.{
        .kind = .teleport,
        .level_a = 0,
        .cell_a = .{ .x = 0, .y = 0 },
        .level_b = 1,
        .cell_b = .{ .x = world.width, .y = 0 },
        .traversal_cost = 1,
        .bidirectional = false,
    }));
    // No partial append from rejected links.
    try std.testing.expectEqual(@as(usize, 1), world.levelLinks().len);
}

test "visibleChunkRegion returns null before any visibility call" {
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
    _ = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(0, 0, .floor, grass);

    // No setVisibleChunksForWorldRect call yet — window is invalid.
    try std.testing.expect(world.visibleChunkRegion() == null);
}

test "visibleChunkRegion returns correct half-open bounds after setVisibleChunksForWorldRect" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 4×4 tiles, chunk_size_tiles=2 → 2×2 grid of chunks (0,0)–(1,1)
    const tile_size = meta.tileSize();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = tile_size,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    _ = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(0, 0, .floor, grass);

    // Show chunk (0,0) only — rect covering just the first chunk (tiles 0–1).
    const chunk_pixels = @as(f32, @floatFromInt(2)) * tile_size;
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = chunk_pixels, .h = chunk_pixels }, 0, 0);

    const region = world.visibleChunkRegion() orelse return error.ExpectedRegion;
    try std.testing.expectEqual(@as(i32, 0), region.min.x);
    try std.testing.expectEqual(@as(i32, 0), region.min.y);
    try std.testing.expectEqual(@as(i32, 1), region.max_exclusive.x);
    try std.testing.expectEqual(@as(i32, 1), region.max_exclusive.y);
    try std.testing.expect(region.containsChunk(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!region.containsChunk(.{ .x = 1, .y = 0 }));
}

test "cognitionRegionForWorldRect expands the rect's chunk region by halo on all sides" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    const tile_size = meta.tileSize();
    // 8×8 tiles, chunk_size_tiles=2 → 4×4 chunk grid
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = tile_size,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    _ = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(0, 0, .floor, grass);

    // Rect covering chunks (1,1)–(2,2) (2×2 chunk region in the middle).
    const chunk_pixels = @as(f32, @floatFromInt(2)) * tile_size;
    const rect = Rect{ .x = chunk_pixels, .y = chunk_pixels, .w = chunk_pixels * 2, .h = chunk_pixels * 2 };

    const view = world.chunkRegionForWorldRect(rect, 0) orelse return error.ExpectedRegion;
    try std.testing.expectEqual(@as(i32, 1), view.min.x);
    try std.testing.expectEqual(@as(i32, 1), view.min.y);
    try std.testing.expectEqual(@as(i32, 3), view.max_exclusive.x);
    try std.testing.expectEqual(@as(i32, 3), view.max_exclusive.y);
    const cognition = world.cognitionRegionForWorldRect(rect, 0, 4) orelse return error.ExpectedRegion;

    // Halo of 4 expands each side by 4 chunks.
    try std.testing.expectEqual(view.min.x - 4, cognition.min.x);
    try std.testing.expectEqual(view.min.y - 4, cognition.min.y);
    try std.testing.expectEqual(view.max_exclusive.x + 4, cognition.max_exclusive.x);
    try std.testing.expectEqual(view.max_exclusive.y + 4, cognition.max_exclusive.y);
    // Chunks within the view are inside the cognition region.
    try std.testing.expect(cognition.containsChunk(.{ .x = 1, .y = 1 }));
    // Chunk well outside the view but within the halo is still included.
    try std.testing.expect(cognition.containsChunk(.{ .x = -1, .y = -1 }));
    // Pure: deriving a scope region never sets the render visibility window.
    try std.testing.expect(world.visibleChunkRegion() == null);
}

test "chunkRegionForWorldRect matches the render visibility window for the same rect and overscan" {
    // 8×8 tiles, chunk_size_tiles=2 → 4×4 chunk grid. Render and sim share one
    // chunk-math helper; this pins that they agree, including overscan clamping.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    // No levels yet → no chunks → no region.
    try std.testing.expect(world.chunkRegionForWorldRect(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, 1) == null);
    _ = try world.addLevel(0);

    const rects = [_]Rect{
        .{ .x = 0, .y = 0, .w = 64, .h = 64 },
        .{ .x = 70, .y = 130, .w = 50, .h = 90 },
        .{ .x = -500, .y = 900, .w = 20, .h = 20 },
    };
    for (rects) |rect| {
        for ([_]u16{ 0, 1, 3 }) |overscan| {
            try world.setVisibleChunksForWorldRect(rect, overscan, 0);
            const visible = world.visibleChunkRegion() orelse return error.ExpectedRegion;
            const region = world.chunkRegionForWorldRect(rect, overscan) orelse return error.ExpectedRegion;
            try std.testing.expectEqual(visible, region);
            try std.testing.expect(region.min.x >= 0 and region.min.y >= 0);
            try std.testing.expect(region.max_exclusive.x <= 4 and region.max_exclusive.y <= 4);
        }
    }
}

test "chunkCoordForWorldPos clamps out-of-range and non-finite positions" {
    // 8×8 tiles, chunk_size_tiles=2 → 4×4 chunk grid; valid chunks [0,3].
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();

    // In-range maps normally.
    try std.testing.expectEqual(ChunkCoord{ .x = 1, .y = 2 }, world.chunkCoordForWorldPos(3 * 32, 5 * 32));
    // Negative and far-past-bounds saturate to the grid edges instead of panicking.
    try std.testing.expectEqual(ChunkCoord{ .x = 0, .y = 0 }, world.chunkCoordForWorldPos(-1.0e9, -1.0));
    try std.testing.expectEqual(ChunkCoord{ .x = 3, .y = 3 }, world.chunkCoordForWorldPos(1.0e9, 1.0e9));
    // Non-finite inputs are guarded by the shared saturating helper.
    try std.testing.expectEqual(ChunkCoord{ .x = 3, .y = 0 }, world.chunkCoordForWorldPos(std.math.inf(f32), std.math.nan(f32)));
}

test "addDenseLayer grows a level's band list and fails without a partial band (FailingAllocator)" {
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
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const dirt = try world.requireTileByName(&meta, "dirt");

    // Every allocation of each add (the row storage, the band list, the layer's
    // chunk directory) fails in turn and commits no band, row, or bit; the first
    // index past them adds. The blocking adds past the band list's first growth
    // cover a growth of a list that already holds bands.
    for (0..70) |band| {
        const fill = if (band % 2 == 0) grass else dirt;
        var fail_index: usize = 0;
        const added = while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
            world.allocator = failing.allocator();
            defer world.allocator = std.testing.allocator;
            if (world.addDenseLayer(level, 0, .floor, fill)) |layer| break layer else |err| try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(band, world.dense_layers.len);
            try std.testing.expectEqual(band, world.level_terrain.items[level].bandLayers().len);
            // Only an added blocking band blocks the level.
            try std.testing.expectEqual(band > 1, world.levelBlocksMovement(level, 3, 3));
        };
        try std.testing.expect(fail_index >= 1);
        try std.testing.expectEqual(band, added);
        try std.testing.expectEqual(@as(u32, @intCast(band)), world.dense_layers.items(.band)[added]);
        try std.testing.expectEqual(@as(u32, @intCast(added)), world.level_terrain.items[level].bandLayers()[band]);
    }
    try std.testing.expectEqual(@as(usize, 70), world.level_terrain.items[level].bandLayers().len);
    for (0..world.chunkCountPerLevel()) |chunk| {
        try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(level, @intCast(chunk)));
    }
}

test "a rect ending exactly on a tile edge at large pixel coordinates excludes the next tile and chunk" {
    // 2048x2048 cells in 16-cell chunks of 32 px: x = 33,280 px is the edge between
    // tile 1039 and 1040, chunks 64 and 65, where f32 spacing is about 0.004 px.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 2048,
        .height = 2048,
        .tile_size = 32,
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    const rect = Rect{ .x = 32_768, .y = 32_768, .w = 512, .h = 512 };
    const scope = world.chunkRegionForWorldRect(rect, 0) orelse return error.ExpectedRegion;
    try std.testing.expectEqual(ChunkCoord{ .x = 64, .y = 64 }, scope.min);
    try std.testing.expectEqual(ChunkCoord{ .x = 65, .y = 65 }, scope.max_exclusive);
    try world.setVisibleChunksForWorldRect(rect, 0, 0);
    try std.testing.expectEqual(scope, world.visibleChunkRegion().?);
    try std.testing.expectEqual(@as(u16, 1040), world.visible.?.window.tiles.max_x);
    // A rect ending just past the edge takes the next tile; a tiny rect keeps its tile.
    const past = world.chunkRegionForWorldRect(.{ .x = 32_768, .y = 32_768, .w = 512.01, .h = 1 }, 0).?;
    try std.testing.expectEqual(@as(i32, 66), past.max_exclusive.x);
    const tiny = world.chunkRegionForWorldRect(.{ .x = 33_280, .y = 0, .w = 0.001, .h = 0.001 }, 0).?;
    try std.testing.expectEqual(ChunkCoord{ .x = 65, .y = 0 }, tiny.min);
    try std.testing.expectEqual(ChunkCoord{ .x = 66, .y = 1 }, tiny.max_exclusive);
}

fn moveWorldByValue(world: WorldSystem) WorldSystem {
    return world;
}

test "tilesetMeta resolves correctly after WorldSystem is moved by value" {
    const meta = try testWorldMeta();
    const expected_tile_size = meta.tileSize();

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = expected_tile_size,
        .chunk_size_tiles = 2,
    };
    world.adoptTilesetMeta(meta);

    var moved = moveWorldByValue(world);
    defer moved.deinit();

    const resolved = moved.tilesetMeta() orelse return error.TestExpectedTilesetMeta;
    try std.testing.expectEqual(expected_tile_size, resolved.tileSize());
    // `world` (the pre-move original) stays alive for this whole test, so a
    // value-only comparison would still pass against the pre-fix behavior of
    // caching `&world.owned_tileset_meta` at adopt time: that stale pointer
    // still reads correct bytes since `world` was never freed. Assert pointer
    // identity against `moved`'s own field to actually discriminate the fix.
    try std.testing.expect(resolved == &moved.owned_tileset_meta.?);
}

test "levelChunkBlockedBits holds a mixed chunk's cells and nothing for uniform chunks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 6x6 tiles in 4-tile chunks: a full chunk and three border chunks.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 6,
        .height = 6,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const tiles = try TerrainTestTiles.resolve(&world, &meta);
    _ = try world.addLevel(0);
    const floor = try world.addDenseLayer(0, 0, .floor, tiles.grass);
    for ([_][2]u16{ .{ 1, 2 }, .{ 3, 0 }, .{ 5, 5 } }) |cell| _ = try world.setDenseTile(floor, cell[0], cell[1], tiles.dirt);
    for (0..4) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        const bits = world.levelChunkBlockedBits(0, chunk) orelse {
            try std.testing.expect(world.levelChunkBlockedForm(0, chunk) != .mixed);
            continue;
        };
        try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(0, chunk));
        const geom = world.chunkGeometry();
        const extent = geom.extent(chunk);
        for (0..4) |row| for (0..4) |col| {
            const local: u32 = @intCast(row * 4 + col);
            const in_level = col < extent.cols and row < extent.rows;
            const expected = in_level and world.levelBlocksMovement(0, @intCast(extent.min_x + col), @intCast(extent.min_y + row));
            try std.testing.expectEqual(expected, world_terrain.bitIsSet(bits, local));
        };
    }
    try std.testing.expect(world.levelChunkBlockedBits(0, 0) != null);
    try std.testing.expect(world.levelChunkBlockedBits(0, 2) == null);
}

test "addLevel touches only its own directory and fails without a partial level (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
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
    for (0..5) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, tiles.dirt);
        _ = try world.setDenseTile(layer, @intCast(level_index), 3, tiles.cave);
    }
    const chunk_count = world.chunkCountPerLevel();
    var level_dirs: [5][]const u32 = undefined;
    var level_dir_copies: [5][64]u32 = undefined;
    var layer_dirs: [5][]const u32 = undefined;
    for (0..5) |index| {
        level_dirs[index] = world.level_terrain.items[index].blocked.dir;
        @memcpy(level_dir_copies[index][0..chunk_count], level_dirs[index]);
        layer_dirs[index] = world.dense_layers.items(.store)[index].dir;
    }

    // Every allocation addLevel makes fails in turn and leaves no partial level,
    // until the first index past its last allocation succeeds.
    var fail_index: usize = 0;
    const added = while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        if (world.addLevel(-5 * level_z_step)) |level| {
            // At most the two level lists', the edit level set's, and its two chain-end
            // lists' growth, plus the new level's own per-chunk directories: composed
            // bits, link heads and counts, sparse heads, and the one-tier edit chunk set.
            try std.testing.expect(failing.allocations <= 10);
            break level;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(@as(usize, 5), world.levelCount());
        try std.testing.expectEqual(@as(usize, 5), world.level_terrain.items.len);
    };
    try std.testing.expect(fail_index >= 1);
    try std.testing.expectEqual(@as(u16, 5), added);
    const terrain = world.level_terrain.items[added];
    try std.testing.expectEqual(chunk_count, terrain.blocked.dir.len);
    try std.testing.expectEqual(@as(usize, 0), terrain.bandLayers().len);
    for (0..chunk_count) |chunk| try std.testing.expectEqual(ChunkForm.open, terrain.blocked.form(@intCast(chunk)));
    // Its link heads exist from create, every chunk without an endpoint.
    try std.testing.expectEqual(chunk_count, terrain.link_heads.len);
    for (terrain.link_heads) |head| try std.testing.expectEqual(no_link_endpoint, head);
    // Every earlier level and layer directory is the same allocation with the same entries.
    for (0..5) |index| {
        try std.testing.expectEqual(level_dirs[index].ptr, world.level_terrain.items[index].blocked.dir.ptr);
        try std.testing.expectEqualSlices(u32, level_dir_copies[index][0..chunk_count], world.level_terrain.items[index].blocked.dir);
        try std.testing.expectEqual(layer_dirs[index].ptr, world.dense_layers.items(.store)[index].dir.ptr);
    }
}

fn rampLinkForTest(level_a: u16, cell_a: CellCoord, level_b: u16, cell_b: CellCoord) LevelLink {
    return .{
        .kind = .ramp,
        .level_a = level_a,
        .cell_a = cell_a,
        .level_b = level_b,
        .cell_b = cell_b,
        .traversal_cost = 1,
        .bidirectional = true,
    };
}

fn linkEndpointsInChunk(world: *const WorldSystem, level: u16, chunk: u32) usize {
    const heads = world.level_terrain.items[level].link_heads;
    var count: usize = 0;
    var endpoint = heads[chunk];
    while (endpoint != no_link_endpoint) : (endpoint = world.link_endpoint_next.items[endpoint]) count += 1;
    return count;
}

test "rampLinkOtherLevel walks only the cell's chunk list and keeps the oldest ramp" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x16 tiles, 4x4 chunks.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    for (0..3) |level| _ = try world.addLevel(-@as(i32, @intCast(level)) * level_z_step);

    try world.addLevelLink(rampLinkForTest(1, .{ .x = 5, .y = 5 }, 0, .{ .x = 5, .y = 5 }));
    try world.addLevelLink(rampLinkForTest(2, .{ .x = 5, .y = 6 }, 1, .{ .x = 5, .y = 6 }));
    var stair = rampLinkForTest(1, .{ .x = 5, .y = 5 }, 2, .{ .x = 9, .y = 9 });
    stair.kind = .stair;
    try world.addLevelLink(stair);
    try world.addLevelLink(rampLinkForTest(2, .{ .x = 13, .y = 13 }, 1, .{ .x = 1, .y = 1 }));
    // A younger ramp at an existing endpoint never shadows the oldest one.
    try world.addLevelLink(rampLinkForTest(1, .{ .x = 5, .y = 5 }, 2, .{ .x = 5, .y = 5 }));

    try std.testing.expectEqual(@as(?u16, 0), world.rampLinkOtherLevel(1, .{ .x = 5, .y = 5 }));
    try std.testing.expectEqual(@as(?u16, 1), world.rampLinkOtherLevel(0, .{ .x = 5, .y = 5 }));
    try std.testing.expectEqual(@as(?u16, 2), world.rampLinkOtherLevel(1, .{ .x = 5, .y = 6 }));
    try std.testing.expectEqual(@as(?u16, 1), world.rampLinkOtherLevel(2, .{ .x = 5, .y = 6 }));
    try std.testing.expectEqual(@as(?u16, 2), world.rampLinkOtherLevel(1, .{ .x = 1, .y = 1 }));
    try std.testing.expectEqual(@as(?u16, 1), world.rampLinkOtherLevel(2, .{ .x = 13, .y = 13 }));
    try std.testing.expectEqual(@as(?u16, 1), world.rampLinkOtherLevel(2, .{ .x = 5, .y = 5 }));
    // A stair endpoint, a linked chunk's unlinked cell, a linked level's unlinked
    // chunk, and a missing level resolve to nothing.
    try std.testing.expectEqual(@as(?u16, null), world.rampLinkOtherLevel(2, .{ .x = 9, .y = 9 }));
    try std.testing.expectEqual(@as(?u16, null), world.rampLinkOtherLevel(1, .{ .x = 6, .y = 5 }));
    try std.testing.expectEqual(@as(?u16, null), world.rampLinkOtherLevel(0, .{ .x = 1, .y = 1 }));
    try std.testing.expectEqual(@as(?u16, null), world.rampLinkOtherLevel(3, .{ .x = 5, .y = 5 }));

    // Level 1's chunk (1,1) holds exactly the four endpoints in it; its other chunks
    // hold only the (1,1) endpoint, in chunk (0,0).
    const geom = world.chunkGeometry();
    try std.testing.expectEqual(@as(usize, 4), linkEndpointsInChunk(&world, 1, geom.chunkOf(5, 5)));
    try std.testing.expectEqual(@as(usize, 1), linkEndpointsInChunk(&world, 1, geom.chunkOf(1, 1)));
    var level1_endpoints: usize = 0;
    for (0..geom.chunkCount()) |chunk| level1_endpoints += linkEndpointsInChunk(&world, 1, @intCast(chunk));
    try std.testing.expectEqual(@as(usize, 5), level1_endpoints);
}

test "levelChunkLinkEndpoints yields exactly the chunk's endpoints, newest first" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x16 tiles, 4x4 chunks.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    for (0..3) |level| _ = try world.addLevel(-@as(i32, @intCast(level)) * level_z_step);

    try world.addLevelLink(rampLinkForTest(1, .{ .x = 5, .y = 5 }, 0, .{ .x = 5, .y = 5 }));
    try world.addLevelLink(rampLinkForTest(2, .{ .x = 5, .y = 6 }, 1, .{ .x = 6, .y = 6 }));
    var stair = rampLinkForTest(1, .{ .x = 4, .y = 4 }, 2, .{ .x = 15, .y = 15 });
    stair.kind = .stair;
    stair.traversal_cost = 7;
    stair.bidirectional = false;
    try world.addLevelLink(stair);
    // Both ends on one level and in one chunk.
    var teleport = rampLinkForTest(1, .{ .x = 7, .y = 7 }, 1, .{ .x = 6, .y = 4 });
    teleport.kind = .teleport;
    try world.addLevelLink(teleport);
    try world.addLevelLink(rampLinkForTest(0, .{ .x = 0, .y = 0 }, 2, .{ .x = 1, .y = 1 }));

    const geom = world.chunkGeometry();
    const links = world.levelLinks();
    for (0..world.levelCount()) |level_index| {
        const level: u16 = @intCast(level_index);
        for (0..geom.chunkCount()) |chunk_index| {
            const chunk: u32 = @intCast(chunk_index);
            var expected_count: usize = 0;
            for (links) |link| {
                expected_count += @intFromBool(link.level_a == level and geom.chunkOf(link.cell_a.x, link.cell_a.y) == chunk);
                expected_count += @intFromBool(link.level_b == level and geom.chunkOf(link.cell_b.x, link.cell_b.y) == chunk);
            }
            var endpoints = world.levelChunkLinkEndpoints(level, chunk);
            var count: usize = 0;
            var previous: ?u32 = null;
            while (endpoints.next()) |endpoint| : (count += 1) {
                const link = links[endpoint.link];
                const at_a = endpoint.side == .a;
                try std.testing.expectEqual(level, if (at_a) link.level_a else link.level_b);
                try std.testing.expectEqual(if (at_a) link.cell_a else link.cell_b, endpoint.cell);
                try std.testing.expectEqual(chunk, geom.chunkOf(endpoint.cell.x, endpoint.cell.y));
                try std.testing.expectEqual(if (at_a) link.level_b else link.level_a, endpoint.other_level);
                try std.testing.expectEqual(if (at_a) link.cell_b else link.cell_a, endpoint.other_cell);
                try std.testing.expectEqual(link.kind, endpoint.kind);
                try std.testing.expectEqual(link.traversal_cost, endpoint.traversal_cost);
                try std.testing.expectEqual(link.bidirectional, endpoint.bidirectional);
                // Newest first: endpoint ids strictly descend, so none repeats.
                const id = endpoint.link * 2 + @intFromBool(!at_a);
                if (previous) |newer| try std.testing.expect(id < newer);
                previous = id;
            }
            try std.testing.expectEqual(expected_count, count);
            // The O(1) count equals the list walk.
            try std.testing.expectEqual(count, world.levelChunkLinkEndpointCount(level, chunk));
        }
    }
    // An invalid level or chunk yields nothing.
    var missing_level = world.levelChunkLinkEndpoints(3, 0);
    try std.testing.expect(missing_level.next() == null);
    var missing_chunk = world.levelChunkLinkEndpoints(1, @intCast(geom.chunkCount()));
    try std.testing.expect(missing_chunk.next() == null);
    try std.testing.expectEqual(@as(u32, 0), world.levelChunkLinkEndpointCount(3, 0));
    try std.testing.expectEqual(@as(u32, 0), world.levelChunkLinkEndpointCount(1, @intCast(geom.chunkCount())));
}

test "reserveLevelLink makes addLevelLink allocation-free and a failed add changes nothing (FailingAllocator)" {
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
    for (0..3) |level| _ = try world.addLevel(-@as(i32, @intCast(level)) * level_z_step);

    // Each allocation of a first link (the row, the endpoints) fails in turn and
    // adds no link; the levels' chunk heads exist from create.
    const first = rampLinkForTest(1, .{ .x = 2, .y = 2 }, 0, .{ .x = 2, .y = 2 });
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, world.reserveLevelLink(first));
        try std.testing.expectError(error.OutOfMemory, world.addLevelLink(first));
        try std.testing.expectEqual(@as(usize, 0), world.levelLinks().len);
        try std.testing.expectEqual(@as(usize, 0), world.link_endpoint_next.items.len);
        try std.testing.expectEqual(@as(?u16, null), world.rampLinkOtherLevel(1, .{ .x = 2, .y = 2 }));
        // Free what the failed reserve kept so the next index fails a later allocation.
        world.allocator = std.testing.allocator;
        world.level_links.clearAndFree(std.testing.allocator);
        world.link_endpoint_next.clearAndFree(std.testing.allocator);
    }

    const second = rampLinkForTest(2, .{ .x = 6, .y = 6 }, 1, .{ .x = 6, .y = 6 });
    try world.reserveLevelLink(first);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try world.addLevelLink(first);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    try world.reserveLevelLink(second);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try world.addLevelLink(second);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    try std.testing.expectEqual(@as(?u16, 0), world.rampLinkOtherLevel(1, .{ .x = 2, .y = 2 }));
    try std.testing.expectEqual(@as(?u16, 1), world.rampLinkOtherLevel(2, .{ .x = 6, .y = 6 }));
    try std.testing.expectEqual(@as(?u16, 2), world.rampLinkOtherLevel(1, .{ .x = 6, .y = 6 }));
}

test "reserveLevelLink fails as OutOfMemory at 2^31 - 1 links held, adding nothing, and reserves one link short of it" {
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
    _ = try world.addLevel(0);
    _ = try world.addLevel(-level_z_step);
    const link = rampLinkForTest(1, .{ .x = 2, .y = 2 }, 0, .{ .x = 2, .y = 2 });
    // The link list reads `held` rows with room for one more: the reserve reads only its
    // length and capacity, so no row memory backs the count. Restored before deinit.
    var spare: [1]LevelLink = undefined;
    const real_links = world.level_links;
    defer world.level_links = real_links;
    const limit: usize = no_link_endpoint / 2;
    for ([_]usize{ limit, limit - 1 }) |held| {
        world.level_links.items = (&spare).ptr[0..held];
        world.level_links.capacity = held + 1;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        if (held == limit) {
            // Fails before asking the allocator: no endpoint entry reserved, no head moved.
            try std.testing.expectError(error.OutOfMemory, world.reserveLevelLink(link));
            try std.testing.expectError(error.OutOfMemory, world.addLevelLink(link));
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 0), world.link_endpoint_next.capacity);
            try std.testing.expectEqual(no_link_endpoint, world.level_terrain.items[0].link_heads[0]);
            try std.testing.expectEqual(no_link_endpoint, world.level_terrain.items[1].link_heads[0]);
        } else {
            // One short of the limit, only the endpoint entries need memory.
            try std.testing.expectError(error.OutOfMemory, world.reserveLevelLink(link));
            try std.testing.expect(failing.has_induced_failure);
            world.allocator = std.testing.allocator;
            try world.reserveLevelLink(link);
            try std.testing.expect(world.link_endpoint_next.capacity >= 2);
        }
        try std.testing.expectEqual(held, world.levelLinks().len);
    }
}

test "addDenseLayer fails as OutOfMemory at 2^32 - 1 layers held, before any reserve, adding no band; one layer short reaches the allocator" {
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
    const live_layers = world.dense_layers.len;
    // The layers read `held` rows: the add checks only the length before its reserves, so
    // no layer memory backs the count. Restored before any reader walks the layers.
    for ([_]usize{ world_terrain.no_floor_layer, world_terrain.no_floor_layer - 1 }) |held| {
        world.dense_layers.len = held;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        const result = world.addDenseLayer(level, 0, .floor, tiles.grass);
        world.allocator = std.testing.allocator;
        world.dense_layers.len = live_layers;
        try std.testing.expectError(error.OutOfMemory, result);
        // At the sentinel nothing is asked of the allocator; one layer short, the row
        // reserve is.
        try std.testing.expectEqual(held == world_terrain.no_floor_layer - 1, failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[level].bands.items.len);
        try std.testing.expectEqual(world_terrain.no_floor_layer, world.level_terrain.items[level].floor_layer);
    }
    // Below the sentinel the same add commits.
    try std.testing.expectEqual(live_layers, try world.addDenseLayer(level, 0, .floor, tiles.grass));
}

const procedural_test_config = WorldBuildConfig{
    .width_tiles = 16,
    .height_tiles = 16,
    .chunk_size_tiles = 4,
    .underground_level_count = 0,
};

test "procedural world build is identical serial and threaded" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var worker_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer worker_threads.deinit();

    var serial = try WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, procedural_test_config, &serial_threads);
    defer serial.deinit();
    var threaded = try WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, procedural_test_config, &worker_threads);
    defer threaded.deinit();

    try std.testing.expectEqual(serial.sparseTileCount(), threaded.sparseTileCount());
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
    try std.testing.expectEqual(serial_store.liveBlockCount(), threaded_store.liveBlockCount());
    // The procedural ground is mixed somewhere, so the threaded fill really ran.
    try std.testing.expect(threaded_store.liveBlockCount() > 0);
    try expectUniformExactlyWhenOneTile(&threaded, 0);
}

test "a blocking dense layer add and procedural fills advance the level's content revision; a non-blocking layer add, a dig, and a batched dense edit do not" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    // Procedural: the ground fill once, the sparse pass once when it placed a
    // blocking tile; the walkable ground band add itself nothing. Seeds cover both
    // a sparse pass with and one without a blocking tile.
    var seen_blocking_sparse = [2]bool{ false, false };
    for (0..32) |seed| {
        var config = procedural_test_config;
        config.seed = seed;
        var world = try WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, config, &threads);
        defer world.deinit();
        var blocking_sparse = false;
        for (0..world.sparseTileCount()) |index| blocking_sparse = blocking_sparse or world.sparseTileBlocksMovement(index);
        seen_blocking_sparse[@intFromBool(blocking_sparse)] = true;
        try std.testing.expectEqual(@as(u32, 1) + @intFromBool(blocking_sparse), world.level_terrain.items[0].content_revision);
    }
    try std.testing.expect(seen_blocking_sparse[0] and seen_blocking_sparse[1]);

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
    try std.testing.expectEqual(@as(u32, 0), world.level_terrain.items[level].content_revision);
    const floor = try world.addDenseLayer(level, 0, .floor, tiles.grass);
    try std.testing.expectEqual(@as(u32, 0), world.level_terrain.items[level].content_revision);
    _ = try world.addDenseLayer(level, 0, .obstacle, tiles.dirt);
    try std.testing.expectEqual(@as(u32, 1), world.level_terrain.items[level].content_revision);
    // Underground levels are solid bands added the same way.
    try world.addUndergroundLevelStack(&meta, 2);
    for (world.level_terrain.items[1..]) |terrain| try std.testing.expectEqual(@as(u32, 1), terrain.content_revision);

    // Evented changes leave it: a dig, a batched edit, and a blocking sparse tile.
    const below = world.denseFloorLayerForLevel(1).?;
    _ = (try world.setDenseTile(below, 1, 1, tiles.cave)).?;
    const writes = [_]DenseCellWrite{ .{ .layer = @intCast(below), .x = 2, .y = 2, .tile = tiles.cave }, .{ .layer = @intCast(below), .x = 6, .y = 6, .tile = tiles.cave } };
    const chunks = [_]DenseChunkWrites{ .{ .level = 1, .chunk_x = 0, .chunk_y = 0, .writes = writes[0..1] }, .{ .level = 1, .chunk_x = 1, .chunk_y = 1, .writes = writes[1..2] } };
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try world.applyDenseCellWrites(&chunks, null, &events);
    try std.testing.expectEqual(writes.len, events.items.len);
    _ = try world.setDenseTile(floor, 3, 3, tiles.water);
    _ = try world.addSparseTile(level, 5, 5, tiles.tree, 0, .obstacle);
    try std.testing.expectEqual(@as(u32, 1), world.level_terrain.items[level].content_revision);
    try std.testing.expectEqual(@as(u32, 1), world.level_terrain.items[1].content_revision);
}

test "levelContentRevision reads each level's revision and contentRevision moves with every level bump" {
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
    const surface = try world.addLevel(0);
    const below = try world.addLevel(-level_z_step);
    const start = world.contentRevision();
    _ = try world.addDenseLayer(surface, 0, .floor, tiles.grass);
    // A walkable layer and a dig change no revision.
    _ = (try world.setDenseTile(world.denseFloorLayerForLevel(surface).?, 1, 1, tiles.cave)).?;
    try std.testing.expectEqual(start, world.contentRevision());
    _ = try world.addDenseLayer(below, 0, .obstacle, tiles.dirt);
    try std.testing.expectEqual(world.level_terrain.items[below].content_revision, world.levelContentRevision(below));
    try std.testing.expectEqual(@as(u32, 0), world.levelContentRevision(surface));
    try std.testing.expect(world.contentRevision() != start);
    const after_below = world.contentRevision();
    _ = try world.addDenseLayer(surface, 0, .obstacle, tiles.dirt);
    try std.testing.expectEqual(@as(u32, 1), world.levelContentRevision(surface));
    try std.testing.expect(world.contentRevision() != after_below);
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
    try world.buildProceduralGround(level, layer, all_stone, 0x5703e, &threads);
    const store = world.dense_layers.items(.store)[layer];
    for (0..world.chunkCountPerLevel()) |chunk| {
        try std.testing.expectEqual(@as(?TileId, stone), store.uniformTile(@intCast(chunk)));
    }
    try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());
}

fn buildProceduralWorldForAllocationTest(allocator: std.mem.Allocator, meta: *const WorldTilesetMeta, threads: *ThreadSystem) !void {
    var world = try WorldSystem.initProceduralFromMeta(allocator, meta, procedural_test_config, threads);
    world.deinit();
}

test "procedural world build fails cleanly at every allocation on the multi-worker path (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildProceduralWorldForAllocationTest, .{ &meta, &threads });
}
