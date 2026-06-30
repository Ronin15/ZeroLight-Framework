// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned SoA world/tile storage and render preparation.
//! Persistent world data stores stable tile IDs, level/chunk metadata, and
//! gameplay tile flags. Atlas source rectangles borrow `tileset_meta` instead of
//! duplicating rect columns when the caller keeps metadata alive (for example
//! `RuntimeAssets.worldTilesetMeta()` for the engine lifetime). Renderer handles
//! stay outside this owner.

const std = @import("std");
const math = @import("../core/math.zig");
const simd = @import("../core/simd.zig");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const PreparedSprite = @import("../assets/runtime_assets.zig").PreparedSprite;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const manifest = @import("../assets/manifest.zig");
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const Rect = @import("../render/renderer.zig").Rect;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const Renderer = @import("../render/renderer.zig").Renderer;
const TileDataId = @import("../render/renderer.zig").TileDataId;
const TilemapParams = @import("../render/renderer.zig").TilemapParams;
const TileDataEdit = @import("../render/renderer.zig").TileDataEdit;
const Sprite = @import("../render/renderer.zig").Sprite;
const sprite_batch = @import("../render/sprite_batch.zig");
const Position = @import("../render/renderer.zig").Position;
const Uv = @import("../render/renderer.zig").Uv;
const VertexColor = @import("../render/renderer.zig").VertexColor;
const writeWorldSpriteQuad = @import("../render/renderer.zig").writeWorldSpriteQuad;
const TextureId = @import("../render/resources.zig").TextureId;
const TextureDesc = @import("../render/resources.zig").TextureDesc;
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../app/thread_system.zig").WorkerId;
const WorldObstacleChangedEvent = @import("simulation.zig").WorldObstacleChangedEvent;
const WorldTileChangedEvent = @import("simulation.zig").WorldTileChangedEvent;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const ChunkCoord = @import("simulation_scope.zig").ChunkCoord;
const render_depth = @import("render_depth.zig");
const WorldDepth = render_depth.WorldDepth;

pub const TileId = u16;
pub const invalid_tile_id: TileId = std.math.maxInt(TileId);
pub const default_chunk_size_tiles: u16 = 8;
// Z gap between stacked levels (planes). Exceeds the WorldDepth band span so a
// lower plane's bands never sort above a higher plane's. Levels descend by this
// step: level 0 (surface) is highest, deeper levels lower.
pub const level_z_step: i32 = 16;
const k_max_dense_submit_layers: usize = 16;

pub const TileFlags = packed struct(u8) {
    walkable: bool = false,
    blocks_movement: bool = false,
    blocks_vision: bool = false,
    reserved: u5 = 0,
};

pub const WorldBuildConfig = struct {
    width_tiles: u16 = 512,
    height_tiles: u16 = 512,
    chunk_size_tiles: u16 = 16,
    seed: u64 = 0x51d1_ea5e_2026_0624,
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

const ProceduralBuildContext = struct {
    tiles: []TileId,
    width: u16,
    height: u16,
    chunk_size_tiles: u16,
    seed: u64,
    ids: ProceduralTiles,
};

const VisibleTileBounds = struct {
    min_x: u16,
    min_y: u16,
    max_x_exclusive: u16,
    max_y_exclusive: u16,
};

// One contiguous run of sparse tiles that share a render depth, expressed as a
// window into `sparse_render_order`. Lets sparse submission touch only the
// tiles at a given depth instead of rescanning every sparse tile per depth.
const SparseDepthRange = struct {
    depth: i32,
    start: u32,
    count: u32,
};

const ChunkColumnRow = struct {
    level_index: u16,
    x: i32,
    y: i32,
    cell_min_x: u16,
    cell_min_y: u16,
    cell_max_x_exclusive: u16,
    cell_max_y_exclusive: u16,
    visible: bool,
};

const DenseLayerRow = struct {
    level_index: u16,
    base_z: i32,
    depth_band: WorldDepth,
};

const SparseTileRow = struct {
    level_index: u16,
    chunk_index: u32,
    cell_index: u32,
    tile_id: TileId,
    depth_value: i32,
    flags: TileFlags,
};

const ChunkColumns = struct {
    rows: std.MultiArrayList(ChunkColumnRow) = .{},

    fn deinit(self: *ChunkColumns, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureTotalCapacity(self: *ChunkColumns, allocator: std.mem.Allocator, count: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, count);
    }

    fn appendAssumeCapacity(
        self: *ChunkColumns,
        level_index: u16,
        chunk_x: i32,
        chunk_y: i32,
        min_x: u16,
        min_y: u16,
        max_x: u16,
        max_y: u16,
        visible: bool,
    ) void {
        self.rows.appendAssumeCapacity(.{
            .level_index = level_index,
            .x = chunk_x,
            .y = chunk_y,
            .cell_min_x = min_x,
            .cell_min_y = min_y,
            .cell_max_x_exclusive = max_x,
            .cell_max_y_exclusive = max_y,
            .visible = visible,
        });
    }
};

pub const WorldSystem = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    tile_size: f32,
    chunk_size_tiles: u16,

    /// Borrowed atlas metadata used for `sourceRect` lookups. Satisfied by
    /// `RuntimeAssets.worldTilesetMeta()` for production startup, or by
    /// `adoptTilesetMeta` for standalone tests/tools that construct a world
    /// without a long-lived runtime catalog.
    tileset_meta: ?*const WorldTilesetMeta = null,
    owned_tileset_meta: ?WorldTilesetMeta = null,
    catalog_valid: std.ArrayList(bool) = .empty,
    catalog_flags: std.ArrayList(TileFlags) = .empty,

    level_base_z: std.ArrayList(i32) = .empty,
    level_links: std.ArrayList(LevelLink) = .empty,

    dense_layers: std.MultiArrayList(DenseLayerRow) = .{},
    dense_tile_ids: std.ArrayList(TileId) = .empty,
    // One renderer-owned tile-data storage buffer per dense layer, built from
    // dense_tile_ids at load. World holds only the opaque handles; the renderer
    // owns and releases the GPU buffers. The tilemap shader reads these directly
    // so no per-tile vertex geometry is built for dense layers.
    dense_layer_tile_buffers: std.ArrayList(TileDataId) = .empty,
    // Per-cell tile-data edits queued by setDenseTile once a layer's storage buffer
    // exists, flushed in one batched copy pass at the render boundary. Empty (and
    // allocation-free) on frames with no tile changes. Invariant: drained every frame
    // gameplay advances — the pause policy blocks gameplay updates whenever render is
    // skipped, so the queue stays bounded without an explicit cap.
    dense_tile_edits: std.ArrayList(TileDataEdit) = .empty,

    sparse_tiles: std.MultiArrayList(SparseTileRow) = .{},

    // Derived render-walk index, rebuilt only when the dense-layer or sparse-tile
    // set changes (tracked by render_index_dirty), never per frame. render_depths
    // is the sorted distinct set of dense+sparse depths; sparse_render_order holds
    // sparse indices grouped by depth (ascending depth, then original index), with
    // sparse_depth_ranges giving the per-depth window into it.
    render_depths: std.ArrayList(i32) = .empty,
    sparse_render_order: std.ArrayList(u32) = .empty,
    sparse_depth_ranges: std.ArrayList(SparseDepthRange) = .empty,
    render_index_dirty: bool = true,

    chunks: std.MultiArrayList(ChunkColumnRow) = .{},
    visible_min_tile_x: u16 = 0,
    visible_min_tile_y: u16 = 0,
    visible_max_tile_x_exclusive: u16 = 0,
    visible_max_tile_y_exclusive: u16 = 0,
    // Visible sparse-tile count cached at each visibility update so the per-frame
    // sprite-command reservation reads it directly instead of rescanning all
    // sparse tiles. Refreshed whenever visibility changes (the only producer that
    // runs before the reservation each render frame).
    visible_sparse_count: usize = 0,
    // Cached visible-window bounds (tile + chunk) from the last visibility update.
    // The window only changes when the camera crosses a tile boundary, so a still
    // camera or a sub-tile pan early-outs instead of rewriting every chunk_visible
    // flag (O(chunks*levels)) and rescanning every sparse tile each render frame.
    visibility_window_valid: bool = false,
    last_min_chunk_x: u16 = 0,
    last_min_chunk_y: u16 = 0,
    last_max_chunk_x: u16 = 0,
    last_max_chunk_y: u16 = 0,

    // World atlas dimensions captured at init: source of truth for the tilemap
    // atlas params and the safe-build runtime-texture-match assert.
    atlas_texture: TextureDesc = .{ .width = 0, .height = 0 },
    // World-constant grid + atlas geometry for the tilemap fragment shader. Built
    // once at init; every dense layer's quad reuses it (only the tile-data buffer
    // differs per layer). See [[dense_layer_tile_buffers]] above.
    tilemap_params: TilemapParams = .{ .grid = .{ 0, 0, 0, 0 }, .atlas = .{ 0, 0, 0, 0 } },
    // The dense-layer tilemap quads need (re)submitting into the renderer's static
    // buffer: true at init and on a structural change (new dense layer). Unlike the
    // old vertex cache this never flips on a pan — the quads are full-world and the
    // camera lives in the shader, so panning uploads nothing.
    dense_quads_dirty: bool = true,
    // The plane the dense geometry was last submitted for. Floors above the active
    // plane are skipped so descending reveals the player's level; a change forces a
    // re-submit even without a structural edit. Sentinel forces the first submit.
    submitted_active_level: u16 = std.math.maxInt(u16),

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
        try world.addUndergroundLevels(meta);
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
            .chunk_size_tiles = @max(config.chunk_size_tiles, 1),
            .atlas_texture = atlasTextureDesc(meta),
        };
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
        var build_context = ProceduralBuildContext{
            .tiles = world.dense_tile_ids.items[world.denseLayerOffset(ground_layer)..][0..world.cellCount()],
            .width = world.width,
            .height = world.height,
            .chunk_size_tiles = world.chunk_size_tiles,
            .seed = config.seed,
            .ids = ids,
        };
        const chunk_count = world.chunkCountPerLevel();
        _ = thread_system.parallelForWithOptions(chunk_count, &build_context, buildProceduralChunk, .{
            .items_per_range = 1,
            .range_alignment_items = 1,
            .adaptive = false,
        });

        try world.addProceduralSparseTiles(level, ids, config.seed);
        try world.rebuildChunks();
        world.tilemap_params = tilemapParamsFor(meta, world.width, world.height, world.tile_size);
        return world;
    }

    pub fn initDemoFromMeta(
        allocator: std.mem.Allocator,
        meta: *const WorldTilesetMeta,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        const tile_size = meta.tileSize();
        const width = ceilTiles(bounds_width, tile_size);
        const height = ceilTiles(bounds_height, tile_size);
        var world = WorldSystem{
            .allocator = allocator,
            .width = width,
            .height = height,
            .tile_size = tile_size,
            .chunk_size_tiles = default_chunk_size_tiles,
            .atlas_texture = atlasTextureDesc(meta),
        };
        errdefer world.deinit();

        try world.buildCatalog(meta);
        const level = try world.addLevel(0);

        const grass = try world.requireTileByName(meta, "grass");
        // Surface accent: grass_patchy stands in for the old `dirt` accent now that
        // `dirt` is a solid underground material (blocks_movement), keeping level 0
        // fully walkable and coherent with the player tile-collision gate.
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
        _ = try world.addSparseTile(level, (width * 3) / 4, (height * 2) / 3, deco, 0, .obstacle);

        try world.rebuildChunks();
        world.tilemap_params = tilemapParamsFor(meta, world.width, world.height, world.tile_size);
        return world;
    }

    /// Transfers standalone tileset metadata ownership into this world so
    /// `sourceRect` lookups remain valid after the caller's local `meta` ends.
    pub fn adoptTilesetMeta(self: *WorldSystem, meta: WorldTilesetMeta) void {
        if (self.owned_tileset_meta) |*owned| owned.deinit();
        self.owned_tileset_meta = meta;
        self.tileset_meta = &self.owned_tileset_meta.?;
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
        self.chunks.deinit(self.allocator);

        self.sparse_depth_ranges.deinit(self.allocator);
        self.sparse_render_order.deinit(self.allocator);
        self.render_depths.deinit(self.allocator);

        self.sparse_tiles.deinit(self.allocator);

        self.dense_tile_edits.deinit(self.allocator);
        self.dense_layer_tile_buffers.deinit(self.allocator);
        self.dense_tile_ids.deinit(self.allocator);
        self.dense_layers.deinit(self.allocator);

        self.level_links.deinit(self.allocator);
        self.level_base_z.deinit(self.allocator);

        self.catalog_flags.deinit(self.allocator);
        self.catalog_valid.deinit(self.allocator);
        if (self.owned_tileset_meta) |*meta| meta.deinit();
        self.owned_tileset_meta = null;
        self.tileset_meta = null;
        self.* = undefined;
    }

    /// Dynamic sprite-command budget the world contributes per frame. Dense tiles
    /// render from the retained static buffer and no longer stream through the
    /// dynamic sprite batch, so only visible sparse tiles count here.
    pub fn reserveRenderRecords(self: *const WorldSystem) usize {
        return self.visible_sparse_count;
    }

    pub fn visibleSparseTileCount(self: *const WorldSystem) usize {
        const bounds = self.visibleTileBounds();
        var visible_sparse_tiles: usize = 0;
        const sparse_chunks = self.sparse_tiles.items(.chunk_index);
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        for (sparse_chunks, sparse_cells) |chunk_index, cell| {
            if (self.isSparseChunkVisible(chunk_index) and self.cellInVisibleBounds(cell, bounds)) {
                visible_sparse_tiles += 1;
            }
        }
        return visible_sparse_tiles;
    }

    pub fn visibleTileCount(self: *const WorldSystem) usize {
        var visible_dense_cells: usize = 0;
        const bounds = self.visibleTileBounds();
        const chunk_visible = self.chunks.items(.visible);
        for (0..self.dense_layers.len) |layer_index| {
            for (0..self.chunks.len) |chunk_index| {
                if (!chunk_visible[chunk_index] or !self.chunkMatchesLayer(chunk_index, layer_index)) continue;
                visible_dense_cells += self.visibleChunkCellCount(chunk_index, bounds);
            }
        }
        var visible_sparse_tiles: usize = 0;
        const sparse_chunks = self.sparse_tiles.items(.chunk_index);
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        for (sparse_chunks, sparse_cells) |chunk_index, cell| {
            if (self.isSparseChunkVisible(chunk_index) and self.cellInVisibleBounds(cell, bounds)) {
                visible_sparse_tiles += 1;
            }
        }
        return visible_dense_cells + visible_sparse_tiles;
    }

    pub fn setVisibleChunksForWorldRect(self: *WorldSystem, rect: Rect, overscan_chunks: u16) void {
        if (self.chunks.len == 0) {
            self.visible_sparse_count = 0;
            return;
        }
        const chunks_x = self.chunksX();
        const chunks_y = self.chunksY();
        const tile_size = self.tile_size;
        const min_tile_x = floorTileClamped(rect.x, tile_size, self.width);
        const min_tile_y = floorTileClamped(rect.y, tile_size, self.height);
        const max_tile_x = floorTileClamped(visibleMaxCoord(rect.x, rect.w), tile_size, self.width);
        const max_tile_y = floorTileClamped(visibleMaxCoord(rect.y, rect.h), tile_size, self.height);
        const min_chunk_x = saturatingSubU16(min_tile_x / self.chunk_size_tiles, overscan_chunks);
        const min_chunk_y = saturatingSubU16(min_tile_y / self.chunk_size_tiles, overscan_chunks);
        const max_chunk_x = @min(chunks_x - 1, max_tile_x / self.chunk_size_tiles + overscan_chunks);
        const max_chunk_y = @min(chunks_y - 1, max_tile_y / self.chunk_size_tiles + overscan_chunks);

        // Early-out when the visible window is unchanged: chunk_visible and the
        // sparse count are fully determined by these bounds, so a still camera or a
        // sub-tile pan needs no rewrite or rescan.
        if (self.visibility_window_valid and
            min_tile_x == self.visible_min_tile_x and min_tile_y == self.visible_min_tile_y and
            max_tile_x + 1 == self.visible_max_tile_x_exclusive and max_tile_y + 1 == self.visible_max_tile_y_exclusive and
            min_chunk_x == self.last_min_chunk_x and min_chunk_y == self.last_min_chunk_y and
            max_chunk_x == self.last_max_chunk_x and max_chunk_y == self.last_max_chunk_y)
        {
            return;
        }
        self.visible_min_tile_x = min_tile_x;
        self.visible_min_tile_y = min_tile_y;
        self.visible_max_tile_x_exclusive = max_tile_x + 1;
        self.visible_max_tile_y_exclusive = max_tile_y + 1;
        self.last_min_chunk_x = min_chunk_x;
        self.last_min_chunk_y = min_chunk_y;
        self.last_max_chunk_x = max_chunk_x;
        self.last_max_chunk_y = max_chunk_y;
        self.visibility_window_valid = true;

        // Visibility is a half-open box test over the chunk-coord columns, four
        // chunks at a time: `c >= min` becomes `c > min-1` and `c <= max` becomes
        // `c < max+1` so it maps onto the greater/less helpers, and the per-axis
        // margins must all be non-negative. Chunk visibility still crops sparse
        // tiles, but no longer drives dense rendering: each dense layer is one
        // full-world tilemap quad, so a pan uploads nothing.
        const min_x = simd.splatInt4(@as(i32, min_chunk_x));
        const max_x = simd.splatInt4(@as(i32, max_chunk_x));
        const min_y = simd.splatInt4(@as(i32, min_chunk_y));
        const max_y = simd.splatInt4(@as(i32, max_chunk_y));
        const count = self.chunks.len;
        const chunk_x = self.chunks.items(.x);
        const chunk_y = self.chunks.items(.y);
        const chunk_visible = self.chunks.items(.visible);
        var index: usize = 0;
        const vectorized_end = simd.vectorizedEnd(count);
        while (index < vectorized_end) : (index += simd.lane_count) {
            const cx = simd.loadInt4(chunk_x[index..]);
            const cy = simd.loadInt4(chunk_y[index..]);
            const dx_low = simd.subInt4(cx, min_x);
            const dx_high = simd.subInt4(max_x, cx);
            const dy_low = simd.subInt4(cy, min_y);
            const dy_high = simd.subInt4(max_y, cy);
            const margin = simd.minInt4(simd.minInt4(dx_low, dx_high), simd.minInt4(dy_low, dy_high));
            inline for (0..simd.lane_count) |lane| {
                chunk_visible[index + lane] = margin[lane] >= 0;
            }
        }
        while (index < count) : (index += 1) {
            const cx = chunk_x[index];
            const cy = chunk_y[index];
            chunk_visible[index] = cx >= @as(i32, min_chunk_x) and cx <= @as(i32, max_chunk_x) and
                cy >= @as(i32, min_chunk_y) and cy <= @as(i32, max_chunk_y);
        }

        // Refresh the cached visible-sparse count from the freshly-updated
        // visibility so reserveRenderRecords stays a no-op scan.
        self.visible_sparse_count = self.visibleSparseTileCount();
    }

    pub fn worldWidthPixels(self: *const WorldSystem) f32 {
        return @as(f32, @floatFromInt(self.width)) * self.tile_size;
    }

    pub fn worldHeightPixels(self: *const WorldSystem) f32 {
        return @as(f32, @floatFromInt(self.height)) * self.tile_size;
    }

    /// Submits each dense layer as one retained world-space tilemap quad: the
    /// fragment shader reads tile ids from the layer's storage buffer and samples
    /// the atlas, so a whole layer is one draw independent of world size. Builds the
    /// per-layer storage buffers on first call. Re-submits only on a structural
    /// change (`dense_quads_dirty`), never on a pan — the quads are full-world and
    /// the camera lives in the vertex shader, so panning uploads nothing.
    pub fn submitStaticDenseGeometry(
        self: *WorldSystem,
        renderer: *Renderer,
        runtime_assets: *const RuntimeAssets,
        active_level: u16,
    ) !void {
        const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
        try self.uploadDenseLayerBuffers(renderer);
        // Re-submit on a structural change OR when the visible plane changed: floors
        // above the player's plane are skipped so they don't occlude the level the
        // player stands on (the render slice follows the player down).
        if (!self.dense_quads_dirty and active_level == self.submitted_active_level) return;

        // The tilemap atlas params are baked from the world atlas dimensions at init;
        // the bound runtime texture must match. Safe-build only, and only on a
        // re-submit (structural change), not still frames.
        if (std.debug.runtime_safety) {
            if (renderer.textureDesc(prepared.texture)) |desc| {
                std.debug.assert(desc.width == self.atlas_texture.width and desc.height == self.atlas_texture.height);
            }
        }

        const layer_count = self.denseLayerCount();
        var submit_layers: [k_max_dense_submit_layers]usize = undefined;
        var submit_count: usize = 0;
        for (0..layer_count) |layer_index| {
            // Skip floors above the player's plane (a lower level index draws on
            // top), so the player and the level they stand on are not occluded.
            if (self.denseLayerLevel(layer_index) < active_level) continue;
            if (submit_count >= k_max_dense_submit_layers) return error.TooManyDenseLayers;
            submit_layers[submit_count] = layer_index;
            submit_count += 1;
        }
        // Back-to-front: deepest plane first so each higher floor composites on top.
        // Storage index order is surface-first (not ascending depth); sorting here
        // keeps the linear `mergeDrawList` path correct and makes tunnel carves
        // visible on the player's plane instead of showing the level below.
        std.mem.sort(usize, submit_layers[0..submit_count], self, denseLayerIndexLessThan);
        try renderer.reserveStaticGeometry(submit_count * 6, submit_count);
        renderer.beginStaticGeometry();
        const world_w = self.worldWidthPixels();
        const world_h = self.worldHeightPixels();
        for (submit_layers[0..submit_count]) |layer_index| {
            // Only the world-space corners (position) are consumed by the tilemap
            // shader; the source/uv are ignored, so the source rect is a placeholder.
            var pos: [6]Position = undefined;
            var uv: [6]Uv = undefined;
            var col: [6]VertexColor = undefined;
            writeWorldSpriteQuad(.{
                .texture = TextureId.invalid,
                .source = .{ .x = 0, .y = 0, .w = self.tile_size, .h = self.tile_size },
                .dest = .{ .x = 0, .y = 0, .w = world_w, .h = world_h },
            }, self.atlas_texture, .{ .positions = &pos, .uvs = &uv, .colors = &col });
            try renderer.appendStaticTilemapSpan(
                prepared.texture,
                self.denseLayerOrder(layer_index),
                .{ .positions = &pos, .uvs = &uv, .colors = &col },
                self.denseLayerTileBuffer(layer_index),
            );
        }
        self.dense_quads_dirty = false;
        self.submitted_active_level = active_level;
    }

    /// Flushes queued per-cell tile edits (digs/builds) to the GPU in one batched
    /// copy pass, then clears the queue. A no-op on frames with no tile changes.
    /// Call once per frame at the render boundary, after the layer buffers exist.
    pub fn flushDenseTileEdits(self: *WorldSystem, renderer: *Renderer) !void {
        if (self.dense_tile_edits.items.len == 0) return;
        try renderer.uploadTileDataEdits(self.dense_tile_edits.items);
        self.dense_tile_edits.clearRetainingCapacity();
    }

    /// Submits the visible sparse tiles at `depth` through the dynamic ordered
    /// stream. Sparse tiles stay dynamic (they are sparse and change independently
    /// of the dense static field); the renderer merges them with dynamic entities
    /// and the static dense spans by render order.
    pub fn submitVisibleSparseAtDepth(
        self: *const WorldSystem,
        renderer: *Renderer,
        runtime_assets: *const RuntimeAssets,
        depth: i32,
    ) !void {
        const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
        const bounds = self.visibleTileBounds();
        try self.submitVisibleSparseRange(renderer, prepared, bounds, depth);
    }

    /// CPU-only sparse submission for benchmarks and headless parity checks. Mirrors
    /// `submitVisibleSparseRange` but writes ordered sprites into `batch` instead of
    /// a live `Renderer`.
    pub fn submitVisibleSparseSprites(
        self: *const WorldSystem,
        batch: *sprite_batch.SpriteBatch,
        texture: TextureId,
        depth: i32,
    ) !usize {
        const bounds = self.visibleTileBounds();
        const range = self.sparseDepthRange(depth) orelse return 0;
        const sparse = self.sparse_tiles.slice();
        const sparse_chunks = sparse.items(.chunk_index);
        const sparse_cells = sparse.items(.cell_index);
        const sparse_tile_ids = sparse.items(.tile_id);
        var submitted: usize = 0;
        for (self.sparse_render_order.items[range.start..][0..range.count]) |index| {
            if (!self.isSparseChunkVisible(sparse_chunks[index])) continue;
            const cell = sparse_cells[index];
            if (!self.cellInVisibleBounds(cell, bounds)) continue;
            const tile_id = sparse_tile_ids[index];
            const x: u16 = @intCast(cell % self.width);
            const y: u16 = @intCast(cell / self.width);
            const source = self.sourceRect(tile_id) orelse return error.MissingTileSourceRect;
            try batch.drawSprite(.{
                .texture = texture,
                .source = source,
                .dest = .{
                    .x = @as(f32, @floatFromInt(x)) * self.tile_size,
                    .y = @as(f32, @floatFromInt(y)) * self.tile_size,
                    .w = self.tile_size,
                    .h = self.tile_size,
                },
                .order = RenderOrder.world(depth),
            });
            submitted += 1;
        }
        return submitted;
    }

    pub fn firstVisibleSparseDepth(self: *const WorldSystem) ?i32 {
        return self.nextVisibleSparseDepthAfter(null);
    }

    /// Returns the next sparse render depth strictly greater than `previous_depth`
    /// (or the first sparse depth for null). Walks the precomputed, ascending
    /// `sparse_depth_ranges`, so discovery is independent of tile count. Callers
    /// must keep the index current via `ensureRenderDepthIndex` before walking.
    pub fn nextVisibleSparseDepthAfter(self: *const WorldSystem, previous_depth: ?i32) ?i32 {
        const ranges = self.sparse_depth_ranges.items;
        if (previous_depth) |previous| {
            for (ranges) |range| {
                if (range.depth > previous) return range.depth;
            }
            return null;
        }
        return if (ranges.len == 0) null else ranges[0].depth;
    }

    pub fn denseTile(self: *const WorldSystem, layer_index: usize, x: u16, y: u16) TileId {
        return self.dense_tile_ids.items[self.denseLayerOffset(layer_index) + self.cellIndex(x, y)];
    }

    pub fn setDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) !?WorldTileChangedEvent {
        try self.validateTileId(tile_id);
        return self.writeDenseTileCell(layer_index, x, y, tile_id);
    }

    /// Clears a dense floor cell to the empty/see-through state (`invalid_tile_id`):
    /// the tilemap shader discards it, revealing the layer drawn below, and
    /// `flagsFor` treats it as non-blocking. This is how a dig punches a hole
    /// through one plane to expose the level beneath.
    pub fn clearDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16) !?WorldTileChangedEvent {
        return self.writeDenseTileCell(layer_index, x, y, invalid_tile_id);
    }

    /// Shared dense-cell write: bounds-checks, updates the CPU tile field (the
    /// source of truth), queues one GPU cell edit once the layer buffer exists,
    /// and returns the compact change event. Tile-id validity is the caller's
    /// concern, so an empty (`invalid_tile_id`) write is allowed here.
    fn writeDenseTileCell(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) !?WorldTileChangedEvent {
        if (layer_index >= self.dense_layers.len) return error.InvalidWorldLayer;
        if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
        const tile_index = self.denseLayerOffset(layer_index) + self.cellIndex(x, y);
        const old_tile_id = self.dense_tile_ids.items[tile_index];
        if (old_tile_id == tile_id) return null;
        const old_blocks_movement = self.flagsFor(old_tile_id).blocks_movement;
        const new_blocks_movement = self.flagsFor(tile_id).blocks_movement;
        self.dense_tile_ids.items[tile_index] = tile_id;
        // Queue the GPU cell update once the layer buffer exists. Before it is built,
        // the initial full upload captures the tile, so no edit is needed.
        const buffer = self.denseLayerTileBuffer(layer_index);
        if (buffer != .invalid) {
            try self.dense_tile_edits.append(self.allocator, .{
                .buffer = buffer,
                .element_index = self.cellIndex(x, y),
                .value = tile_id,
            });
        }
        return .{
            .level = self.dense_layers.items(.level_index)[layer_index],
            .x = x,
            .y = y,
            .old_tile_id = old_tile_id,
            .new_tile_id = tile_id,
            .old_blocks_movement = old_blocks_movement,
            .new_blocks_movement = new_blocks_movement,
        };
    }

    pub fn denseLayerCount(self: *const WorldSystem) usize {
        return self.dense_layers.len;
    }

    /// Widens a dense layer's row-major tile ids into `out` (one `u32` per cell)
    /// for storage-buffer upload. `out.len` must equal `cellCount()`. The row-major
    /// order here is exactly the tilemap shader's `cell.y * width + cell.x` read,
    /// so the GPU lookup matches `cellIndex`. Load-time only (not a frame path).
    fn writeDenseLayerTileData(self: *const WorldSystem, layer_index: usize, out: []u32) void {
        const cells = self.cellCount();
        std.debug.assert(out.len == cells);
        const src = self.dense_tile_ids.items[self.denseLayerOffset(layer_index)..][0..cells];
        for (src, out) |tile, *dst| dst.* = tile;
    }

    /// Builds one renderer-owned tile-data storage buffer per dense layer from
    /// `dense_tile_ids`. Idempotent: a no-op once the buffers exist. Call once at
    /// world load, before the tilemap layers are submitted for drawing.
    pub fn uploadDenseLayerBuffers(self: *WorldSystem, renderer: *Renderer) !void {
        const layer_count = self.denseLayerCount();
        // Resume from the first not-yet-built layer, so a mid-loop failure can be
        // retried to completion and a fully-built world is a no-op.
        if (self.dense_layer_tile_buffers.items.len == layer_count) return;

        const scratch = try self.allocator.alloc(u32, self.cellCount());
        defer self.allocator.free(scratch);
        try self.dense_layer_tile_buffers.ensureTotalCapacity(self.allocator, layer_count);
        for (self.dense_layer_tile_buffers.items.len..layer_count) |layer_index| {
            self.writeDenseLayerTileData(layer_index, scratch);
            const id = try renderer.createTileDataBuffer(scratch, self.tilemap_params);
            self.dense_layer_tile_buffers.appendAssumeCapacity(id);
        }
    }

    /// Releases the renderer-owned tile-data buffers this world created and drops
    /// the local handles, keeping the world's handle list and the renderer in
    /// sync. The symmetric teardown for `uploadDenseLayerBuffers`: call before
    /// rebuilding the dense tilemap when the renderer outlives the world. App
    /// shutdown instead frees these through `Renderer.deinit`.
    pub fn releaseDenseLayerBuffers(self: *WorldSystem, renderer: *Renderer) void {
        renderer.releaseTileDataBuffers();
        self.dense_layer_tile_buffers.clearRetainingCapacity();
    }

    /// The tile-data storage buffer handle for a dense layer (`.invalid` until
    /// `uploadDenseLayerBuffers` has run).
    pub fn denseLayerTileBuffer(self: *const WorldSystem, layer_index: usize) TileDataId {
        if (layer_index >= self.dense_layer_tile_buffers.items.len) return .invalid;
        return self.dense_layer_tile_buffers.items[layer_index];
    }

    pub fn denseTileBlocksMovement(self: *const WorldSystem, layer_index: usize, x: u16, y: u16) bool {
        if (layer_index >= self.dense_layers.len) return true;
        if (x >= self.width or y >= self.height) return true;
        return self.flagsFor(self.denseTile(layer_index, x, y)).blocks_movement;
    }

    /// Level a dense band belongs to. Lets navigation iterate the dense bands of a
    /// single level directly instead of polling per cell across all levels.
    pub fn denseLayerLevel(self: *const WorldSystem, layer_index: usize) u16 {
        return self.dense_layers.items(.level_index)[layer_index];
    }

    /// Level a sparse tile belongs to. Pairs with `sparseTileCellCoord` so a
    /// per-level sparse-cell set can be built in O(sparse), not O(cells x sparse).
    pub fn sparseTileLevel(self: *const WorldSystem, index: usize) u16 {
        return self.sparse_tiles.items(.level_index)[index];
    }

    /// Tile-cell coordinate of a sparse tile, decoded from its stored cell index.
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

    /// Render/plane z baseline for a level. An actor whose `position_z` equals
    /// this draws in that level's render slice.
    pub fn levelBaseZ(self: *const WorldSystem, level_index: u16) i32 {
        return self.level_base_z.items[level_index];
    }

    /// The dense floor layer for a level (first `.floor` band on it), or null if
    /// the level has none. Cold path (dig/traversal, not per-frame per-cell).
    pub fn denseFloorLayerForLevel(self: *const WorldSystem, level_index: u16) ?usize {
        const dense_levels = self.dense_layers.items(.level_index);
        const dense_depth_bands = self.dense_layers.items(.depth_band);
        for (dense_levels, dense_depth_bands, 0..) |dense_level, depth_band, layer_index| {
            if (dense_level != level_index) continue;
            if (depth_band == .floor) return layer_index;
        }
        return null;
    }

    /// Whether a level's floor cell is an empty (dug-through) hole. False when the
    /// level has no floor layer or the cell is out of bounds.
    pub fn denseFloorIsEmpty(self: *const WorldSystem, level_index: u16, x: u16, y: u16) bool {
        if (x >= self.width or y >= self.height) return false;
        const layer = self.denseFloorLayerForLevel(level_index) orelse return false;
        return self.denseTile(layer, x, y) == invalid_tile_id;
    }

    /// If a ramp link touches `(level, cell)`, returns the level on its other end
    /// (the plane you'd traverse to). Also the dedupe check for ramp digging.
    pub fn rampLinkOtherLevel(self: *const WorldSystem, level_index: u16, cell: CellCoord) ?u16 {
        for (self.level_links.items) |link| {
            if (link.kind != .ramp) continue;
            if (link.level_a == level_index and link.cell_a.x == cell.x and link.cell_a.y == cell.y) return link.level_b;
            if (link.level_b == level_index and link.cell_b.x == cell.x and link.cell_b.y == cell.y) return link.level_a;
        }
        return null;
    }

    // Per-level composed navigability: a level's blocked mask is the OR of every
    // dense band assigned to that level plus every sparse obstacle on that level.
    // Out-of-range x/y returns blocked, matching denseTileBlocksMovement; an
    // invalid level also returns blocked (fail-closed) so a bad index can never
    // expose phantom open cells to the pathfinder. Allocation-free: iterates the
    // dense band columns and sparse SoA columns directly with no joins.
    pub fn levelBlocksMovement(self: *const WorldSystem, level_index: u16, x: u16, y: u16) bool {
        if (@as(usize, level_index) >= self.level_base_z.items.len) return true;
        if (x >= self.width or y >= self.height) return true;
        const dense_levels = self.dense_layers.items(.level_index);
        for (dense_levels, 0..) |dense_level, layer_index| {
            if (dense_level != level_index) continue;
            if (self.flagsFor(self.denseTile(layer_index, x, y)).blocks_movement) return true;
        }
        const cell = self.cellIndex(x, y);
        const sparse_levels = self.sparse_tiles.items(.level_index);
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        const sparse_flags = self.sparse_tiles.items(.flags);
        for (sparse_levels, sparse_cells, sparse_flags) |sparse_level, sparse_cell, flags| {
            if (sparse_level != level_index) continue;
            if (sparse_cell != cell) continue;
            if (flags.blocks_movement) return true;
        }
        return false;
    }

    // Appends a persistent inter-level link. Validates both level indices and
    // that both cells lie inside the tile grid before storing. Explicit error
    // set; allocation is bounded to the single append.
    pub fn addLevelLink(self: *WorldSystem, link: LevelLink) error{ InvalidWorldLevel, InvalidWorldCell, OutOfMemory }!void {
        try self.validateLevelIndex(link.level_a);
        try self.validateLevelIndex(link.level_b);
        if (link.cell_a.x >= self.width or link.cell_a.y >= self.height) return error.InvalidWorldCell;
        if (link.cell_b.x >= self.width or link.cell_b.y >= self.height) return error.InvalidWorldCell;
        try self.level_links.append(self.allocator, link);
    }

    pub fn levelLinks(self: *const WorldSystem) []const LevelLink {
        return self.level_links.items;
    }

    pub fn sparseTileCount(self: *const WorldSystem) usize {
        return self.sparse_tiles.len;
    }

    pub fn sparseTileBlocksMovement(self: *const WorldSystem, index: usize) bool {
        if (index >= self.sparse_tiles.len) return false;
        return self.sparse_tiles.items(.flags)[index].blocks_movement;
    }

    pub fn sparseTileRect(self: *const WorldSystem, index: usize) ?Rect {
        if (index >= self.sparse_tiles.len) return null;
        const cell = self.sparse_tiles.items(.cell_index)[index];
        const x: u16 = @intCast(cell % self.width);
        const y: u16 = @intCast(cell / self.width);
        return self.cellRect(x, y);
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

    pub fn chunkCoordForCell(self: *const WorldSystem, x: u16, y: u16) struct { x: i32, y: i32 } {
        return .{
            .x = @intCast(x / self.chunk_size_tiles),
            .y = @intCast(y / self.chunk_size_tiles),
        };
    }

    /// Canonical world-space float position → chunk coordinate, clamped to world
    /// bounds. The movement processor folds an inline copy of this formula in its
    /// integration pass (`writeChunkRow`), kept in parity by the scoped-movement test.
    pub fn chunkCoordForWorldPos(self: *const WorldSystem, world_x: f32, world_y: f32) ChunkCoord {
        const tx: u16 = @intCast(math.worldPosToCell(world_x, self.tile_size, self.width));
        const ty: u16 = @intCast(math.worldPosToCell(world_y, self.tile_size, self.height));
        const raw = self.chunkCoordForCell(tx, ty);
        return .{ .x = raw.x, .y = raw.y };
    }

    /// Camera-visible chunk rectangle as an ActiveRegion. Returns null when no
    /// visibility window has been set yet (e.g. before the first render frame).
    pub fn visibleChunkRegion(self: *const WorldSystem) ?ActiveRegion {
        if (!self.visibility_window_valid or self.chunks.len == 0) return null;
        std.debug.assert(self.last_max_chunk_x >= self.last_min_chunk_x);
        std.debug.assert(self.last_max_chunk_y >= self.last_min_chunk_y);
        return .{
            .min = .{ .x = @intCast(self.last_min_chunk_x), .y = @intCast(self.last_min_chunk_y) },
            .max_exclusive = .{
                .x = @as(i32, self.last_max_chunk_x) + 1,
                .y = @as(i32, self.last_max_chunk_y) + 1,
            },
        };
    }

    /// Camera-visible chunks expanded by `halo` on every side — the simulation
    /// cognition active region. Entities outside this region drop to .locomotion.
    /// Returns null when no visibility window has been set yet.
    pub fn cognitionActiveRegion(self: *const WorldSystem, halo: u16) ?ActiveRegion {
        const visible = self.visibleChunkRegion() orelse return null;
        const h: i32 = @intCast(halo);
        return .{
            .min = .{ .x = visible.min.x - h, .y = visible.min.y - h },
            .max_exclusive = .{ .x = visible.max_exclusive.x + h, .y = visible.max_exclusive.y + h },
        };
    }

    pub fn addLevel(self: *WorldSystem, base_z: i32) !u16 {
        const index = self.level_base_z.items.len;
        if (index > std.math.maxInt(u16)) return error.WorldLevelOverflow;
        try self.level_base_z.ensureUnusedCapacity(self.allocator, 1);
        self.level_base_z.appendAssumeCapacity(base_z);
        errdefer _ = self.level_base_z.pop();
        try self.rebuildChunks();
        return @intCast(index);
    }

    pub fn addDenseLayer(self: *WorldSystem, level_index: u16, base_z: i32, depth: WorldDepth, fill_tile: TileId) !usize {
        try self.validateLevelIndex(level_index);
        try self.validateTileId(fill_tile);
        const layer_index = self.dense_layers.len;
        try self.dense_layers.ensureTotalCapacity(self.allocator, layer_index + 1);
        try self.dense_tile_ids.ensureUnusedCapacity(self.allocator, self.cellCount());
        self.dense_layers.appendAssumeCapacity(.{
            .level_index = level_index,
            .base_z = base_z,
            .depth_band = depth,
        });
        for (0..self.cellCount()) |_| {
            self.dense_tile_ids.appendAssumeCapacity(fill_tile);
        }
        self.render_index_dirty = true;
        // A new dense layer needs its own tilemap quad submitted; its storage buffer
        // is built lazily on the next submit (uploadDenseLayerBuffers resumes).
        self.dense_quads_dirty = true;
        return layer_index;
    }

    /// Adds the two solid underground planes beneath the surface (level 0): a dirt
    /// floor one step down, a dark floor two steps down. Digging a hole in a plane
    /// reveals the one below; stacked by descending `base_z` so the surface draws on
    /// top. Call once on an already-built surface world (its dense layers are the
    /// last appended, so no held tile slice is invalidated).
    pub fn addUndergroundLevels(self: *WorldSystem, meta: *const WorldTilesetMeta) !void {
        const dirt = try self.requireTileByName(meta, "dirt");
        const dirt_dark = try self.requireTileByName(meta, "dirt_dark");
        const level_dirt = try self.addLevel(-level_z_step);
        const level_void = try self.addLevel(-2 * level_z_step);
        _ = try self.addDenseLayer(level_dirt, 0, .floor, dirt);
        _ = try self.addDenseLayer(level_void, 0, .floor, dirt_dark);
    }

    pub fn addSparseTile(
        self: *WorldSystem,
        level_index: u16,
        x: u16,
        y: u16,
        tile_id: TileId,
        base_z: i32,
        depth: WorldDepth,
    ) !?WorldObstacleChangedEvent {
        try self.validateLevelIndex(level_index);
        try self.validateTileId(tile_id);
        if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
        const cell = self.cellIndex(x, y);
        const chunk_index = try self.sparseChunkIndexForCell(level_index, x, y);
        const flags = self.flagsFor(tile_id);
        const world_z = self.worldZForLevel(level_index, base_z, depth);
        try self.sparse_tiles.ensureTotalCapacity(self.allocator, self.sparse_tiles.len + 1);
        self.sparse_tiles.appendAssumeCapacity(.{
            .level_index = level_index,
            .chunk_index = chunk_index,
            .cell_index = cell,
            .tile_id = tile_id,
            .depth_value = world_z,
            .flags = flags,
        });
        self.render_index_dirty = true;
        // The sparse set changed, so the cached visible-sparse count must refresh.
        self.visibility_window_valid = false;
        if (!flags.blocks_movement) return null;
        return .{
            .level = level_index,
            .min_x = x,
            .min_y = y,
            .max_x_exclusive = @min(self.width, x +| 1),
            .max_y_exclusive = @min(self.height, y +| 1),
        };
    }

    fn submitVisibleSparseRange(
        self: *const WorldSystem,
        renderer: *Renderer,
        prepared: PreparedSprite,
        bounds: VisibleTileBounds,
        depth: i32,
    ) !void {
        const range = self.sparseDepthRange(depth) orelse return;
        const sparse = self.sparse_tiles.slice();
        const sparse_chunks = sparse.items(.chunk_index);
        const sparse_cells = sparse.items(.cell_index);
        const sparse_tile_ids = sparse.items(.tile_id);
        for (self.sparse_render_order.items[range.start..][0..range.count]) |index| {
            if (!self.isSparseChunkVisible(sparse_chunks[index])) continue;
            const cell = sparse_cells[index];
            if (!self.cellInVisibleBounds(cell, bounds)) continue;
            const tile_id = sparse_tile_ids[index];
            const x: u16 = @intCast(cell % self.width);
            const y: u16 = @intCast(cell / self.width);
            try self.submitTile(renderer, prepared, tile_id, x, y, RenderOrder.world(depth));
        }
    }

    fn submitTile(
        self: *const WorldSystem,
        renderer: *Renderer,
        prepared: PreparedSprite,
        tile_id: TileId,
        x: u16,
        y: u16,
        order: RenderOrder,
    ) !void {
        const source = self.sourceRect(tile_id) orelse return error.MissingTileSourceRect;
        try renderer.submitOrderedSprite(.{
            .texture = prepared.texture,
            .source = source,
            .dest = .{
                .x = @as(f32, @floatFromInt(x)) * self.tile_size,
                .y = @as(f32, @floatFromInt(y)) * self.tile_size,
                .w = self.tile_size,
                .h = self.tile_size,
            },
            .order = order,
        });
    }

    /// Borrows `meta` for `sourceRect` lookups. Production paths keep metadata
    /// alive via `RuntimeAssets`; standalone tests must call `adoptTilesetMeta`.
    fn buildCatalog(self: *WorldSystem, meta: *const WorldTilesetMeta) !void {
        self.tileset_meta = meta;
        const count = catalogCapacity(meta);
        try self.catalog_valid.ensureTotalCapacity(self.allocator, count);
        try self.catalog_flags.ensureTotalCapacity(self.allocator, count);
        for (0..count) |_| {
            self.catalog_valid.appendAssumeCapacity(false);
            self.catalog_flags.appendAssumeCapacity(.{});
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
        }
    }

    fn rebuildChunks(self: *WorldSystem) !void {
        // The chunk set is changing, so the cached visible-window early-out must
        // repopulate chunk_visible on the next call.
        self.visibility_window_valid = false;
        const chunks_x = ceilDiv(self.width, self.chunk_size_tiles);
        const chunks_y = ceilDiv(self.height, self.chunk_size_tiles);
        const chunk_count = @as(usize, chunks_x) * @as(usize, chunks_y) * self.level_base_z.items.len;
        var next = ChunkColumns{};
        errdefer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, chunk_count);
        for (0..self.level_base_z.items.len) |level_index| {
            for (0..chunks_y) |cy| {
                for (0..chunks_x) |cx| {
                    const min_x: u16 = @intCast(cx * self.chunk_size_tiles);
                    const min_y: u16 = @intCast(cy * self.chunk_size_tiles);
                    const max_x: u16 = @min(self.width, min_x + self.chunk_size_tiles);
                    const max_y: u16 = @min(self.height, min_y + self.chunk_size_tiles);
                    const chunk_x: i32 = @intCast(cx);
                    const chunk_y: i32 = @intCast(cy);
                    next.appendAssumeCapacity(
                        @intCast(level_index),
                        chunk_x,
                        chunk_y,
                        min_x,
                        min_y,
                        max_x,
                        max_y,
                        self.preservedChunkVisible(@intCast(level_index), chunk_x, chunk_y),
                    );
                }
            }
        }

        var old = ChunkColumns{ .rows = self.chunks };
        self.chunks = next.rows;
        next = .{};
        old.deinit(self.allocator);

        try self.rebuildRenderDepthIndex();
        self.dense_quads_dirty = true;
    }

    /// Rebuilds the derived render-walk index if a structural change marked it
    /// dirty. Cheap no-op on a clean world, so it is safe to call every frame at
    /// the render entry point; the const render readers assume it is current.
    pub fn ensureRenderDepthIndex(self: *WorldSystem) !void {
        if (!self.render_index_dirty) return;
        try self.rebuildRenderDepthIndex();
    }

    fn rebuildRenderDepthIndex(self: *WorldSystem) !void {
        const sparse_count = self.sparse_tiles.len;
        const depth_values = self.sparse_tiles.items(.depth_value);

        // Sparse indices grouped by (depth, original index) — a total order, so
        // the per-depth windows below preserve the original submission order.
        self.sparse_render_order.clearRetainingCapacity();
        try self.sparse_render_order.ensureTotalCapacity(self.allocator, sparse_count);
        for (0..sparse_count) |i| self.sparse_render_order.appendAssumeCapacity(@intCast(i));
        std.mem.sort(u32, self.sparse_render_order.items, depth_values, sparseRenderOrderLessThan);

        self.sparse_depth_ranges.clearRetainingCapacity();
        var i: usize = 0;
        while (i < sparse_count) {
            const depth = depth_values[self.sparse_render_order.items[i]];
            const start = i;
            while (i < sparse_count and depth_values[self.sparse_render_order.items[i]] == depth) : (i += 1) {}
            try self.sparse_depth_ranges.append(self.allocator, .{
                .depth = depth,
                .start = @intCast(start),
                .count = @intCast(i - start),
            });
        }

        // Distinct, ascending union of dense-layer and sparse depths.
        self.render_depths.clearRetainingCapacity();
        for (0..self.dense_layers.len) |layer_index| {
            try self.appendRenderDepth(self.denseLayerOrder(layer_index).depth);
        }
        for (self.sparse_depth_ranges.items) |range| {
            try self.appendRenderDepth(range.depth);
        }
        std.mem.sort(i32, self.render_depths.items, {}, std.sort.asc(i32));

        self.render_index_dirty = false;
    }

    fn appendRenderDepth(self: *WorldSystem, depth: i32) !void {
        for (self.render_depths.items) |existing| {
            if (existing == depth) return;
        }
        try self.render_depths.append(self.allocator, depth);
    }

    fn sparseRenderOrderLessThan(depth_values: []const i32, lhs: u32, rhs: u32) bool {
        const lhs_depth = depth_values[lhs];
        const rhs_depth = depth_values[rhs];
        if (lhs_depth != rhs_depth) return lhs_depth < rhs_depth;
        return lhs < rhs;
    }

    fn sparseDepthRange(self: *const WorldSystem, depth: i32) ?SparseDepthRange {
        for (self.sparse_depth_ranges.items) |range| {
            if (range.depth == depth) return range;
        }
        return null;
    }

    fn sourceRect(self: *const WorldSystem, tile_id: TileId) ?Rect {
        const index: usize = tile_id;
        if (index >= self.catalog_valid.items.len or !self.catalog_valid.items[index]) return null;
        const meta = self.tileset_meta orelse return null;
        const rect = meta.sourceRectForId(tile_id) orelse return null;
        return .{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
        };
    }

    fn flagsFor(self: *const WorldSystem, tile_id: TileId) TileFlags {
        const index: usize = tile_id;
        if (index >= self.catalog_flags.items.len) return .{};
        return self.catalog_flags.items[index];
    }

    pub fn requireTileByName(self: *const WorldSystem, meta: *const WorldTilesetMeta, name: []const u8) !TileId {
        _ = self;
        const tile = meta.tileByName(name) orelse return error.RequiredWorldTileMissing;
        return tile.id;
    }

    fn cellCount(self: *const WorldSystem) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    fn cellIndex(self: *const WorldSystem, x: u16, y: u16) u32 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return @intCast(@as(usize, y) * @as(usize, self.width) + @as(usize, x));
    }

    fn denseLayerOffset(self: *const WorldSystem, layer_index: usize) usize {
        return layer_index * self.cellCount();
    }

    fn visibleTileBounds(self: *const WorldSystem) VisibleTileBounds {
        if (self.visible_max_tile_x_exclusive <= self.visible_min_tile_x or
            self.visible_max_tile_y_exclusive <= self.visible_min_tile_y)
        {
            return .{
                .min_x = 0,
                .min_y = 0,
                .max_x_exclusive = self.width,
                .max_y_exclusive = self.height,
            };
        }
        return .{
            .min_x = self.visible_min_tile_x,
            .min_y = self.visible_min_tile_y,
            .max_x_exclusive = @min(self.visible_max_tile_x_exclusive, self.width),
            .max_y_exclusive = @min(self.visible_max_tile_y_exclusive, self.height),
        };
    }

    fn visibleChunkCellCount(self: *const WorldSystem, chunk_index: usize, bounds: VisibleTileBounds) usize {
        const chunks = self.chunks.slice();
        const min_x = @max(chunks.items(.cell_min_x)[chunk_index], bounds.min_x);
        const min_y = @max(chunks.items(.cell_min_y)[chunk_index], bounds.min_y);
        const max_x = @min(chunks.items(.cell_max_x_exclusive)[chunk_index], bounds.max_x_exclusive);
        const max_y = @min(chunks.items(.cell_max_y_exclusive)[chunk_index], bounds.max_y_exclusive);
        if (min_x >= max_x or min_y >= max_y) return 0;
        return @as(usize, max_x - min_x) * @as(usize, max_y - min_y);
    }

    fn cellInVisibleBounds(self: *const WorldSystem, cell: u32, bounds: VisibleTileBounds) bool {
        const x: u16 = @intCast(cell % self.width);
        const y: u16 = @intCast(cell / self.width);
        return x >= bounds.min_x and x < bounds.max_x_exclusive and
            y >= bounds.min_y and y < bounds.max_y_exclusive;
    }

    fn validateLevelIndex(self: *const WorldSystem, level_index: u16) !void {
        if (@as(usize, level_index) >= self.level_base_z.items.len) return error.InvalidWorldLevel;
    }

    fn validateTileId(self: *const WorldSystem, tile_id: TileId) !void {
        if (!self.isValidTileId(tile_id)) return error.InvalidWorldTile;
    }

    fn isValidTileId(self: *const WorldSystem, tile_id: TileId) bool {
        const index: usize = tile_id;
        return index < self.catalog_valid.items.len and self.catalog_valid.items[index];
    }

    fn worldZForLevel(self: *const WorldSystem, level_index: u16, local_z: i32, depth: WorldDepth) i32 {
        const level_z: i64 = @as(i64, self.level_base_z.items[level_index]);
        const value = level_z + @as(i64, local_z) + @as(i64, render_depth.worldZ(depth));
        const min: i64 = std.math.minInt(i32);
        const max: i64 = std.math.maxInt(i32);
        return @intCast(@max(min, @min(max, value)));
    }

    fn denseLayerOrder(self: *const WorldSystem, layer_index: usize) RenderOrder {
        const dense = self.dense_layers.slice();
        return RenderOrder.world(self.worldZForLevel(
            dense.items(.level_index)[layer_index],
            dense.items(.base_z)[layer_index],
            dense.items(.depth_band)[layer_index],
        ));
    }

    fn denseLayerIndexLessThan(self: *const WorldSystem, a: usize, b: usize) bool {
        return self.denseLayerOrder(a).depth < self.denseLayerOrder(b).depth;
    }

    fn chunkMatchesLayer(self: *const WorldSystem, chunk_index: usize, layer_index: usize) bool {
        const chunks = self.chunks.slice();
        const dense = self.dense_layers.slice();
        return chunks.items(.level_index)[chunk_index] == dense.items(.level_index)[layer_index];
    }

    fn preservedChunkVisible(self: *const WorldSystem, level_index: u16, chunk_x: i32, chunk_y: i32) bool {
        const chunks = self.chunks.slice();
        for (0..self.chunks.len) |index| {
            if (chunks.items(.level_index)[index] != level_index) continue;
            if (chunks.items(.x)[index] != chunk_x or chunks.items(.y)[index] != chunk_y) continue;
            return chunks.items(.visible)[index];
        }
        return true;
    }

    fn isSparseChunkVisible(self: *const WorldSystem, chunk_index: u32) bool {
        const index: usize = chunk_index;
        const chunk_visible = self.chunks.items(.visible);
        return index < chunk_visible.len and chunk_visible[index];
    }

    fn sparseChunkIndexForCell(self: *const WorldSystem, level_index: u16, x: u16, y: u16) !u32 {
        const chunks_x = self.chunksX();
        const chunks_y = self.chunksY();
        const chunk_x = x / self.chunk_size_tiles;
        const chunk_y = y / self.chunk_size_tiles;
        const level_offset = @as(usize, level_index) * @as(usize, chunks_x) * @as(usize, chunks_y);
        const chunk_offset = @as(usize, chunk_y) * @as(usize, chunks_x) + @as(usize, chunk_x);
        const index = level_offset + chunk_offset;
        if (index > std.math.maxInt(u32)) return error.WorldChunkOverflow;
        return @intCast(index);
    }

    fn chunksX(self: *const WorldSystem) u16 {
        return ceilDiv(self.width, self.chunk_size_tiles);
    }

    fn chunksY(self: *const WorldSystem) u16 {
        return ceilDiv(self.height, self.chunk_size_tiles);
    }

    fn chunkCountPerLevel(self: *const WorldSystem) usize {
        return @as(usize, self.chunksX()) * @as(usize, self.chunksY());
    }

    fn addProceduralSparseTiles(self: *WorldSystem, level: u16, ids: ProceduralTiles, seed: u64) !void {
        const chunks_x = self.chunksX();
        const chunks_y = self.chunksY();
        for (0..chunks_y) |cy| {
            for (0..chunks_x) |cx| {
                const h = hash2(seed ^ 0x9e37_79b9, cx, cy);
                const min_x: u16 = @intCast(cx * self.chunk_size_tiles);
                const min_y: u16 = @intCast(cy * self.chunk_size_tiles);
                const max_x = @min(self.width, min_x + self.chunk_size_tiles);
                const max_y = @min(self.height, min_y + self.chunk_size_tiles);
                const span_x = @max(max_x - min_x, 1);
                const span_y = @max(max_y - min_y, 1);
                const x: u16 = min_x + @as(u16, @intCast((h >> 8) % span_x));
                const y: u16 = min_y + @as(u16, @intCast((h >> 24) % span_y));
                const center_x = @abs(@as(i32, @intCast(x)) - @as(i32, self.width / 2));
                const center_y = @abs(@as(i32, @intCast(y)) - @as(i32, self.height / 2));
                if ((h & 15) == 0 and center_x > 4 and center_y > 4) {
                    _ = try self.addSparseTile(level, x, y, ids.tree, 0, .obstacle);
                } else if ((h & 63) == 1) {
                    _ = try self.addSparseTile(level, x, y, ids.deco, 0, .obstacle);
                }
            }
        }
    }
};

fn buildProceduralChunk(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const build: *ProceduralBuildContext = @ptrCast(@alignCast(context));
    const chunks_x = ceilDiv(build.width, build.chunk_size_tiles);
    for (range.start..range.end) |chunk_index| {
        const chunk_x: u16 = @intCast(chunk_index % chunks_x);
        const chunk_y: u16 = @intCast(chunk_index / chunks_x);
        const min_x: u16 = chunk_x * build.chunk_size_tiles;
        const min_y: u16 = chunk_y * build.chunk_size_tiles;
        const max_x = @min(build.width, min_x + build.chunk_size_tiles);
        const max_y = @min(build.height, min_y + build.chunk_size_tiles);
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var x = min_x;
            while (x < max_x) : (x += 1) {
                build.tiles[@as(usize, y) * @as(usize, build.width) + x] = proceduralGroundTile(build.*, x, y);
            }
        }
    }
}

fn proceduralGroundTile(build: ProceduralBuildContext, x: u16, y: u16) TileId {
    const center_y: i32 = @intCast(build.height / 2);
    const river_wave = @as(i32, @intCast(hash2(build.seed, x / 12, y / 32) % 9)) - 4;
    const y_i: i32 = @intCast(y);
    if (@abs(y_i - center_y - river_wave) <= 2) return build.ids.water;
    if (@abs(y_i - center_y - river_wave) <= 3) return build.ids.shore;

    const ridge = hash2(build.seed ^ 0xa17a_5eed, x / 8, y / 8);
    if ((ridge & 0xff) < 18 and y > build.height / 5) return build.ids.cliff;

    if (x == build.width / 2 or y == build.height / 2) return build.ids.path;

    const h = hash2(build.seed, x, y);
    if ((h & 31) == 0) return build.ids.stone;
    // `dirt` is a solid underground material now; the surface accent is grass_patchy.
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

fn catalogCapacity(meta: *const WorldTilesetMeta) usize {
    var max_id: usize = 0;
    for (0..meta.tileCount()) |index| {
        const tile = meta.tileAtIndex(index) orelse continue;
        max_id = @max(max_id, tile.id);
    }
    return max_id + 1;
}

fn ceilTiles(value: f32, tile_size: f32) u16 {
    const tiles = @ceil(value / tile_size);
    return @intFromFloat(@max(tiles, 1));
}

fn ceilDiv(value: u16, divisor: u16) u16 {
    return (value + divisor - 1) / divisor;
}

fn floorTileClamped(value: f32, tile_size: f32, max_tiles: u16) u16 {
    return @intCast(math.worldPosToCell(value, tile_size, max_tiles));
}

fn visibleMaxCoord(origin: f32, extent: f32) f32 {
    if (extent <= 0) return origin;
    return @max(origin, origin + extent - 0.001);
}

fn saturatingSubU16(value: u16, amount: u16) u16 {
    return if (value > amount) value - amount else 0;
}

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

fn testWorldMeta() !WorldTilesetMeta {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    return try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
}

fn containsDepth(depths: []const i32, value: i32) bool {
    for (depths) |depth| {
        if (depth == value) return true;
    }
    return false;
}

fn sparseDepthIndexLessForTest(values: []const i32, a: u32, b: u32) bool {
    if (values[a] != values[b]) return values[a] < values[b];
    return a < b;
}

test "world render depth index orders sparse tiles by depth then insertion" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addDenseLayer(level, 0, .floor, grass);

    // Insertion order is deliberately not depth order, with repeated depths.
    const bands = [_]WorldDepth{ .obstacle, .floor, .effect, .floor, .obstacle, .effect };
    for (bands, 0..) |band, i| {
        const x: u16 = @intCast(i + 1);
        _ = try world.addSparseTile(level, x, 1, if (i % 2 == 0) tree else deco, 0, band);
    }
    try world.rebuildChunks();

    // render_depths is strictly ascending and covers every dense and sparse depth.
    const depths = world.render_depths.items;
    try std.testing.expect(depths.len > 0);
    for (depths[1..], 1..) |depth, idx| {
        try std.testing.expect(depths[idx - 1] < depth);
    }
    for (0..world.dense_layers.len) |layer| {
        try std.testing.expect(containsDepth(depths, world.denseLayerOrder(layer).depth));
    }
    const sparse_depth_values = world.sparse_tiles.items(.depth_value);
    for (sparse_depth_values) |depth| {
        try std.testing.expect(containsDepth(depths, depth));
    }

    // Reference order: original indices sorted by (depth, insertion index) — the
    // exact order the old scan-per-depth path visited matching sparse tiles in.
    var reference: [bands.len]u32 = undefined;
    for (0..bands.len) |i| reference[i] = @intCast(i);
    std.mem.sort(u32, &reference, sparse_depth_values, sparseDepthIndexLessForTest);

    // Actual order produced by walking render_depths through the range index.
    var actual: [bands.len]u32 = undefined;
    var count: usize = 0;
    for (depths) |depth| {
        const range = world.sparseDepthRange(depth) orelse continue;
        for (world.sparse_render_order.items[range.start..][0..range.count]) |index| {
            try std.testing.expectEqual(depth, sparse_depth_values[index]);
            actual[count] = index;
            count += 1;
        }
    }
    try std.testing.expectEqual(bands.len, count);
    try std.testing.expectEqualSlices(u32, &reference, actual[0..count]);
}

test "world render depth index refreshes after runtime sparse insert" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    // Construction leaves the index current.
    try std.testing.expect(!world.render_index_dirty);
    try world.ensureRenderDepthIndex();

    const tree = try world.requireTileByName(&meta, "tree_0");
    const new_depth = world.worldZForLevel(0, 0, .effect);
    try std.testing.expect(!containsDepth(world.render_depths.items, new_depth));

    _ = try world.addSparseTile(0, 2, 1, tree, 0, .effect);
    try std.testing.expect(world.render_index_dirty);

    try world.ensureRenderDepthIndex();
    try std.testing.expect(!world.render_index_dirty);
    try std.testing.expect(containsDepth(world.render_depths.items, new_depth));
    // Every sparse tile is represented exactly once in the render order.
    try std.testing.expectEqual(world.sparse_tiles.len, world.sparse_render_order.items.len);
}

fn setSpriteAvailableForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId, texture: TextureId) void {
    runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{
        .status = .available,
        .lease = .{ .id = texture },
    };
}

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

test "dense layer tile-data staging matches denseTile by row-major cell index" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.setDenseTile(0, 2, 1, grass);

    const staging = try std.testing.allocator.alloc(u32, world.cellCount());
    defer std.testing.allocator.free(staging);
    world.writeDenseLayerTileData(0, staging);

    for (0..world.height) |y| {
        for (0..world.width) |x| {
            const xi: u16 = @intCast(x);
            const yi: u16 = @intCast(y);
            // The shader reads tile_ids[cell.y*width + cell.x]; cellIndex is that
            // same index, so staging[cellIndex] must equal the logical tile.
            try std.testing.expectEqual(
                @as(u32, world.denseTile(0, xi, yi)),
                staging[world.cellIndex(xi, yi)],
            );
        }
    }
}

test "setDenseTile queues a GPU cell edit only once the layer buffer exists" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    const water = try world.requireTileByName(&meta, "water_1");
    const grass = try world.requireTileByName(&meta, "grass");

    // Before the storage buffer is built, a dig records no edit: the initial full
    // upload will capture the tile.
    _ = try world.setDenseTile(0, 2, 1, water);
    try std.testing.expectEqual(@as(usize, 0), world.dense_tile_edits.items.len);

    // Simulate the layer's storage buffer having been built (uploadDenseLayerBuffers
    // needs a renderer, unavailable headless).
    try world.dense_layer_tile_buffers.append(std.testing.allocator, @enumFromInt(0));

    _ = try world.setDenseTile(0, 1, 0, grass);
    try std.testing.expectEqual(@as(usize, 1), world.dense_tile_edits.items.len);
    const edit = world.dense_tile_edits.items[0];
    try std.testing.expectEqual(@as(usize, world.cellIndex(1, 0)), edit.element_index);
    try std.testing.expectEqual(@as(u32, grass), edit.value);

    // A flushed queue is cleared; an unchanged tile records nothing.
    world.dense_tile_edits.clearRetainingCapacity();
    try std.testing.expect((try world.setDenseTile(0, 1, 0, grass)) == null);
    try std.testing.expectEqual(@as(usize, 0), world.dense_tile_edits.items.len);
}

test "world rejects invalid tile ids before render" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 64, 64);
    defer world.deinit();

    const invalid = invalid_tile_id;
    try std.testing.expectError(error.InvalidWorldTile, world.addDenseLayer(0, 0, .floor, invalid));
    try std.testing.expectError(error.InvalidWorldTile, world.setDenseTile(0, 0, 0, invalid));
    try std.testing.expectError(error.InvalidWorldTile, world.addSparseTile(0, 0, 0, invalid, 0, .obstacle));
}

test "world dense tile mutation returns compact change event" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
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
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    const tree = try world.requireTileByName(&meta, "tree_0");
    const changed = (try world.addSparseTile(0, 2, 1, tree, 0, .obstacle)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), changed.level);
    try std.testing.expectEqual(@as(u16, 2), changed.min_x);
    try std.testing.expectEqual(@as(u16, 1), changed.min_y);
    try std.testing.expectEqual(@as(u16, 3), changed.max_x_exclusive);
    try std.testing.expectEqual(@as(u16, 2), changed.max_y_exclusive);
}

test "world chunks map cells by chunk size" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();

    const first = world.chunkCoordForCell(0, 0);
    try std.testing.expectEqual(@as(i32, 0), first.x);
    try std.testing.expectEqual(@as(i32, 0), first.y);
    const next = world.chunkCoordForCell(default_chunk_size_tiles, default_chunk_size_tiles);
    try std.testing.expectEqual(@as(i32, 1), next.x);
    try std.testing.expectEqual(@as(i32, 1), next.y);
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

    try std.testing.expectEqual(@as(usize, 2), world.chunks.len);
    try std.testing.expectEqual(@as(usize, 2), world.visibleTileCount());
}

test "world add level preserves existing chunk visibility" {
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
    world.chunks.items(.visible)[0] = false;
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);

    const chunk_visible = world.chunks.items(.visible);
    try std.testing.expectEqual(@as(usize, 4), world.chunks.len);
    try std.testing.expect(!chunk_visible[0]);
    try std.testing.expect(chunk_visible[1]);
    try std.testing.expect(chunk_visible[2]);
    try std.testing.expect(chunk_visible[3]);
    try std.testing.expectEqual(@as(usize, 3), world.visibleTileCount());
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
    try world.rebuildChunks();

    try std.testing.expectEqual(@as(usize, 2), world.chunks.len);
    try std.testing.expectEqual(@as(usize, 3), world.visibleTileCount());

    try std.testing.expectEqual(render_depth.worldZ(.floor), world.worldZForLevel(level0, 0, .floor));
    try std.testing.expectEqual(@as(i32, 8), world.worldZForLevel(level1, 0, .floor));
    try std.testing.expectEqual(@as(i32, 9), world.worldZForLevel(level1, 0, .obstacle));
}

test "procedural world build uses thread system chunk ranges and visible culling" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var meta = try testWorldMeta();
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var world = try WorldSystem.initProceduralFromMeta(std.testing.allocator, &meta, .{
        .width_tiles = 64,
        .height_tiles = 64,
        .chunk_size_tiles = 8,
        .seed = 1234,
    }, &threads);
    defer world.deinit();

    try std.testing.expectEqual(@as(u16, 64), world.width);
    try std.testing.expectEqual(@as(u16, 64), world.height);

    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 128, .h = 128 }, 0);
    const near_origin = world.visibleTileCount();
    try std.testing.expect(near_origin > 0);
    try std.testing.expect(near_origin < world.cellCount());

    world.setVisibleChunksForWorldRect(.{ .x = 1600, .y = 1600, .w = 128, .h = 128 }, 0);
    try std.testing.expect(world.visibleTileCount() > 0);
}

test "visible tile count crops inside visible chunks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 32,
        .height = 32,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level, 0, .floor, grass);

    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, 0);
    try std.testing.expectEqual(@as(usize, 4), world.visibleTileCount());

    world.setVisibleChunksForWorldRect(.{ .x = 512, .y = 512, .w = 64, .h = 64 }, 0);
    try std.testing.expectEqual(@as(usize, 4), world.visibleTileCount());
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
    // Out-of-range cells are blocked, matching denseTileBlocksMovement.
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

test "underground demo levels are solid dirt until a cell is dug walkable" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
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

test "dense layer submit order sorts back to front by render depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var indices: [3]usize = .{ 0, 1, 2 };
    std.mem.sort(usize, &indices, &world, WorldSystem.denseLayerIndexLessThan);
    try std.testing.expectEqual(@as(i32, -34), world.denseLayerOrder(indices[0]).depth);
    try std.testing.expectEqual(@as(i32, -18), world.denseLayerOrder(indices[1]).depth);
    try std.testing.expectEqual(@as(i32, -2), world.denseLayerOrder(indices[2]).depth);
}

test "underground dense layers append in storage order not ascending render depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    try std.testing.expectEqual(@as(usize, 3), world.denseLayerCount());
    const grass_depth = world.denseLayerOrder(0).depth;
    const dirt_depth = world.denseLayerOrder(1).depth;
    const dirt_dark_depth = world.denseLayerOrder(2).depth;
    // Back-to-front draw order: dirt_dark, dirt, grass (grass on top).
    try std.testing.expect(dirt_dark_depth < dirt_depth and dirt_depth < grass_depth);
    // `submitStaticDenseGeometry` walks dense_layer index order (surface first):
    // depths descend with index, so a linear merge must not assume ascending input.
    try std.testing.expect(grass_depth > dirt_depth and dirt_depth > dirt_dark_depth);
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

test "dense layers order by z level and quads re-submit only on structural change" {
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

    const lower_level = try world.addLevel(0);
    const upper_level = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const lower_layer = try world.addDenseLayer(lower_level, 0, .floor, grass);
    const upper_layer = try world.addDenseLayer(upper_level, 0, .floor, grass);
    try world.rebuildChunks();

    // A higher base-z level carries a strictly higher order; the ordered draw list
    // interleaves each dense tilemap quad with dynamic entities by this depth.
    try std.testing.expect(world.denseLayerOrder(lower_layer).depth < world.denseLayerOrder(upper_layer).depth);

    // A structural change (new layer / chunk rebuild) arms a quad re-submit.
    try std.testing.expect(world.dense_quads_dirty);
    world.dense_quads_dirty = false;

    // A dig changes tile-data, not quad geometry, so it does not re-arm a re-submit
    // (the GPU buffer is updated directly by the dig hook).
    _ = try world.setDenseTile(lower_layer, 3, 3, water);
    try std.testing.expect(!world.dense_quads_dirty);

    // A pan changes chunk visibility (crops sparse tiles) but not the full-world
    // dense quads, so it does not re-arm a re-submit either.
    world.setVisibleChunksForWorldRect(.{ .x = 1024, .y = 1024, .w = 128, .h = 128 }, 0);
    try std.testing.expect(!world.dense_quads_dirty);
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
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = chunk_pixels, .h = chunk_pixels }, 0);

    const region = world.visibleChunkRegion() orelse return error.ExpectedRegion;
    try std.testing.expectEqual(@as(i32, 0), region.min.x);
    try std.testing.expectEqual(@as(i32, 0), region.min.y);
    try std.testing.expectEqual(@as(i32, 1), region.max_exclusive.x);
    try std.testing.expectEqual(@as(i32, 1), region.max_exclusive.y);
    try std.testing.expect(region.containsChunk(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!region.containsChunk(.{ .x = 1, .y = 0 }));
}

test "cognitionActiveRegion expands by halo on all sides" {
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

    // Show chunks (1,1)–(2,2) (2×2 chunk region in the middle).
    const chunk_pixels = @as(f32, @floatFromInt(2)) * tile_size;
    world.setVisibleChunksForWorldRect(.{
        .x = chunk_pixels,
        .y = chunk_pixels,
        .w = chunk_pixels * 2,
        .h = chunk_pixels * 2,
    }, 0);

    const visible = world.visibleChunkRegion() orelse return error.ExpectedRegion;
    const cognition = world.cognitionActiveRegion(4) orelse return error.ExpectedRegion;

    // Halo of 4 expands each side by 4 chunks.
    try std.testing.expectEqual(visible.min.x - 4, cognition.min.x);
    try std.testing.expectEqual(visible.min.y - 4, cognition.min.y);
    try std.testing.expectEqual(visible.max_exclusive.x + 4, cognition.max_exclusive.x);
    try std.testing.expectEqual(visible.max_exclusive.y + 4, cognition.max_exclusive.y);
    // Chunks within visible region are inside cognition region.
    try std.testing.expect(cognition.containsChunk(.{ .x = 1, .y = 1 }));
    // Chunk well outside visible but within halo is still included.
    try std.testing.expect(cognition.containsChunk(.{ .x = -1, .y = -1 }));
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
