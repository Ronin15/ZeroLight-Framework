// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned SoA world/tile storage and render preparation.
//! Persistent world data stores stable tile IDs, level/chunk metadata, and
//! gameplay tile flags. Atlas source rectangles are resolved from `tileset_meta`
//! once at build time and cached into per-tile `catalog_source_x/y/w/h` columns,
//! so hot-path `sourceRect` lookups never re-touch tileset metadata at runtime.
//! Renderer handles stay outside this owner.

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
/// Stack cap for dense submit collection. Sized above the default window
/// (8 level indices × 2 bands). Build-time validation keeps real worlds inside
/// `maxDenseSubmitLayerCount`; overflow here is a defensive submit-time guard.
pub const k_max_dense_submit_stack_cap: usize = 32;

// The renderer's per-draw composited layer window must be able to hold every
// layer this stack can ever submit in one frame; tied here (this file already
// imports renderer.zig) rather than in renderer.zig, to avoid an import cycle.
comptime {
    std.debug.assert(Renderer.k_max_tilemap_window_layers == k_max_dense_submit_stack_cap);
}

// `partitionDenseCompositeBuckets` can never produce more buckets than
// submitted dense layers (one cut point consumes at least one layer), so the
// renderer's composite-draw budget must cover the full submit-stack cap or
// the bucket-count invariant it relies on breaks.
comptime {
    std.debug.assert(Renderer.k_max_dense_composite_draws >= k_max_dense_submit_stack_cap);
}

pub const TileFlags = packed struct(u8) {
    walkable: bool = false,
    blocks_movement: bool = false,
    blocks_vision: bool = false,
    reserved: u5 = 0,
};

/// Vertical dense-floor render visibility policy. Affects static tilemap submit
/// and draw count only; all authored dense layers still retain GPU tile-data
/// buffers. Re-submit fires when `dense_quads_dirty`, `active_level`, or this
/// window changes.
pub const DenseLayerRenderWindow = struct {
    /// Inclusive count of world levels below `active_level` to submit.
    levels_below: u16 = 6,
    /// Optional: when underground (`active_level > 0`), also submit one level
    /// above the player. Off by default — whole-layer tilemaps cannot do per-cell
    /// shaft cull, so enabling this redraws the full ceiling plane and breaks the
    /// render slice following the player down. Hole see-through from the surface
    /// uses `levels_below` while `active_level == 0`.
    ceiling_when_underground: bool = false,

    pub fn maxLevelSpan(self: DenseLayerRenderWindow) u16 {
        var span: u16 = 1 + self.levels_below;
        if (self.ceiling_when_underground) span += 1;
        return span;
    }

    pub fn maxSubmitLayers(self: DenseLayerRenderWindow, max_dense_bands_per_level: u8) usize {
        return @as(usize, self.maxLevelSpan()) * @as(usize, max_dense_bands_per_level);
    }

    pub fn levelInWindow(
        self: DenseLayerRenderWindow,
        active_level: u16,
        world_level: u16,
        max_world_level: u16,
    ) bool {
        if (self.ceiling_when_underground and active_level > 0 and world_level == active_level - 1) {
            return true;
        }
        if (world_level < active_level) return false;
        const deep_limit = @min(
            @as(u32, active_level) +% @as(u32, self.levels_below),
            @as(u32, max_world_level),
        );
        return @as(u32, world_level) <= deep_limit;
    }
};

pub const WorldBuildConfig = struct {
    width_tiles: u16 = 512,
    height_tiles: u16 = 512,
    chunk_size_tiles: u16 = 16,
    seed: u64 = 0x51d1_ea5e_2026_0624,
    max_dense_bands_per_level: u8 = 2,
    /// Zero disables the load-time GPU tile-buffer budget gate.
    max_dense_tile_gpu_bytes: usize = 0,
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
    /// Set when `addDenseLayer` fills the band with one tile; cleared on the first
    /// per-cell edit so nav masking can memset uniform blocking layers.
    uniform_fill_tile: ?TileId = null,
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
    // O(1) source-rect cache, indexed like catalog_valid/catalog_flags. Avoids a
    // per-tile hash-map lookup into tileset_meta on the per-frame sparse-tile
    // render path.
    catalog_source_x: std.ArrayList(f32) = .empty,
    catalog_source_y: std.ArrayList(f32) = .empty,
    catalog_source_w: std.ArrayList(f32) = .empty,
    catalog_source_h: std.ArrayList(f32) = .empty,

    level_base_z: std.ArrayList(i32) = .empty,
    level_links: std.ArrayList(LevelLink) = .empty,

    dense_layers: std.MultiArrayList(DenseLayerRow) = .{},
    dense_tile_ids: std.ArrayList(TileId) = .empty,
    // Single renderer-owned tile-data storage buffer holding every dense layer's
    // cells concatenated, mirroring dense_tile_ids's flat layout. Built once from
    // the whole array at load. World holds only the opaque handle; the renderer
    // owns and releases the GPU buffer. Each layer's draw reads only its own
    // slice via denseLayerOffset, so no per-tile vertex geometry is built for
    // dense layers.
    dense_tile_data_buffer: TileDataId = .invalid,
    // Per-cell tile-data edits queued by setDenseTile once a layer's storage buffer
    // exists, flushed in one batched copy pass at the render boundary. Empty (and
    // allocation-free) on frames with no tile changes. Invariant: drained every frame
    // gameplay advances — the pause policy blocks gameplay updates whenever render is
    // skipped, so the queue stays bounded without an explicit cap.
    dense_tile_edits: std.ArrayList(TileDataEdit) = .empty,

    sparse_tiles: std.MultiArrayList(SparseTileRow) = .{},

    // Reverse per-level index over `sparse_tiles`: one growable list of indices
    // per level, indexed by level. Maintained eagerly (appended to) inside
    // `addSparseTile` — the sole sparse-tile inserter, which never removes a
    // tile and never changes a tile's level after insertion — so this needs no
    // dirty flag or deferred rebuild. That matters because gameplay consumers
    // (nav rebuild after a dig, the perception LOS-blocked cache) read it
    // within the same fixed-step tick a tile is placed, well before the next
    // `ensureRenderDepthIndex` render pass would run; a lazily-rebuilt index
    // keyed off the render dirty flag would be stale for them. A future bulk
    // sparse-tile insert path must maintain this the same way. Lets per-level
    // consumers (levelBlocksMovement, NavGrid.markWorldObstacles, perception's
    // blocked-cache rebuild) walk only one level's tiles instead of scanning
    // every sparse tile in the world and filtering by level. Deliberately not
    // shaped like `sparse_render_order` (one flat sorted array + range table):
    // that shape requires a contiguous per-group run, which can only be kept
    // contiguous by a full resort after every insert — exactly the O(n) full
    // rescan this index exists to avoid. Grown lazily up to `level_index + 1`
    // entries the first time a level gets a sparse tile; a level with no
    // sparse tiles yet simply has no entry (the accessor treats that the same
    // as an out-of-range level: an empty slice).
    sparse_level_tiles: std.ArrayList(std.ArrayList(u32)) = .empty,

    // Finer sibling of sparse_level_tiles: outer by level_index, middle by the
    // level-local chunk index (chunkY*chunksX+chunkX, see
    // `localChunkIndexForCell`), inner the sparse_tiles indices in that chunk.
    // Same eager-maintenance contract as sparse_level_tiles (see above) —
    // maintained by `addSparseTile` only, never removed from or resorted.
    sparse_level_chunk_tiles: std.ArrayList(std.ArrayList(std.ArrayList(u32))) = .empty,

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
    // once at init; every dense layer's quad reuses it (only the per-draw cell
    // offset into [[dense_tile_data_buffer]] differs per layer, see above).
    tilemap_params: TilemapParams = .{ .grid = .{ 0, 0, 0, 0 }, .atlas = .{ 0, 0, 0, 0 } },
    // The dense-layer tilemap quads need (re)submitting into the renderer's static
    // buffer: true at init and on a structural change (new dense layer). Unlike the
    // old vertex cache this never flips on a pan — the quads are full-world and the
    // camera lives in the shader, so panning uploads nothing.
    dense_quads_dirty: bool = true,
    // Last dense static submit anchor and window fingerprint. A change forces a
    // re-submit even without a structural edit. Sentinel forces the first submit.
    submitted_active_level: u16 = std.math.maxInt(u16),
    submitted_window: DenseLayerRenderWindow = .{},
    // Last submitted interleave-depth set (sorted ascending, deduplicated by the
    // caller): the depths this frame's composite-draw buckets were cut against.
    // A change forces a re-submit even without a structural/level/window change,
    // since a newly-registered interleave point (e.g. a sparse tile at a new
    // depth becoming relevant) can change where the dense stack must split.
    submitted_interleave_depths: [k_max_dense_submit_stack_cap]i32 = undefined,
    submitted_interleave_count: usize = 0,
    // Cached result from the last time `denseWindowDepthSpan` actually recomputed
    // (rather than reusing this cache): valid exactly when `dense_quads_dirty`,
    // `submitted_active_level`, and `submitted_window` still match the request,
    // since those are the only things that can change the window's real content.
    dense_window_depth_span: ?DenseWindowDepthSpan = null,
    // The submitted layers' own depths (ascending), cached alongside
    // `dense_window_depth_span` on the same recompute condition. Lets
    // `render_prep.collectDenseInterleaveDepths` bucket candidate depths by
    // which gap between adjacent submitted layers they would cut, without
    // recomputing `collectDenseSubmitLayers` a second time.
    dense_window_layer_depths: [k_max_dense_submit_stack_cap]i32 = undefined,
    dense_window_layer_depth_count: usize = 0,
    render_window: DenseLayerRenderWindow = .{},
    max_dense_bands_per_level: u8 = 2,
    max_dense_tile_gpu_bytes: usize = 0,
    dense_bands_per_level: std.ArrayList(u8) = .empty,

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
        try world.validateDenseRenderBudget();
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
        try world.validateDenseRenderBudget();
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
            .render_window = config.render_window,
            .max_dense_bands_per_level = config.max_dense_bands_per_level,
            .max_dense_tile_gpu_bytes = config.max_dense_tile_gpu_bytes,
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
        world.clearDenseLayerUniformFill(ground_layer);
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
        try world.validateDenseRenderBudget();
        return world;
    }

    pub fn deinit(self: *WorldSystem) void {
        self.chunks.deinit(self.allocator);

        self.sparse_depth_ranges.deinit(self.allocator);
        self.sparse_render_order.deinit(self.allocator);
        self.render_depths.deinit(self.allocator);

        self.sparse_tiles.deinit(self.allocator);
        for (self.sparse_level_tiles.items) |*bucket| bucket.deinit(self.allocator);
        self.sparse_level_tiles.deinit(self.allocator);
        for (self.sparse_level_chunk_tiles.items) |*level_chunks| {
            for (level_chunks.items) |*bucket| bucket.deinit(self.allocator);
            level_chunks.deinit(self.allocator);
        }
        self.sparse_level_chunk_tiles.deinit(self.allocator);

        self.dense_tile_edits.deinit(self.allocator);
        self.dense_tile_ids.deinit(self.allocator);
        self.dense_layers.deinit(self.allocator);
        self.dense_bands_per_level.deinit(self.allocator);

        self.level_links.deinit(self.allocator);
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
        self.* = undefined;
    }

    /// Dynamic sprite-command budget the world contributes per frame. Dense tiles
    /// render from the retained static buffer and no longer stream through the
    /// dynamic sprite batch, so only visible sparse tiles count here.
    pub fn reserveRenderRecords(self: *const WorldSystem) usize {
        return self.visible_sparse_count;
    }

    /// Upper bound on dense tilemap static groups submitted in one frame for the
    /// configured render window and per-level band cap.
    pub fn maxDenseSubmitLayerCount(self: *const WorldSystem) usize {
        return self.render_window.maxSubmitLayers(self.max_dense_bands_per_level);
    }

    /// Upper bound on dense tilemap composite draw calls submitted in one frame.
    /// Actual bucket count is data-dependent (which depths need a sandwich point
    /// this frame); this is the worst case the render-prep boundary reserves
    /// static-geometry draw-list capacity for.
    pub fn maxDenseSubmitDrawCount(self: *const WorldSystem) usize {
        _ = self;
        return Renderer.k_max_dense_composite_draws;
    }

    pub fn estimateDenseTileGpuBytes(self: *const WorldSystem) usize {
        return self.denseLayerCount() * self.cellCount() * @sizeOf(u32);
    }

    pub fn validateDenseRenderBudget(self: *const WorldSystem) error{ DenseLayerWindowExceeded, DenseTileGpuBudgetExceeded }!void {
        if (self.maxDenseSubmitLayerCount() > k_max_dense_submit_stack_cap) {
            return error.DenseLayerWindowExceeded;
        }
        for (self.dense_bands_per_level.items) |band_count| {
            if (band_count > self.max_dense_bands_per_level) {
                return error.DenseLayerWindowExceeded;
            }
        }
        if (self.max_dense_tile_gpu_bytes > 0 and self.estimateDenseTileGpuBytes() > self.max_dense_tile_gpu_bytes) {
            return error.DenseTileGpuBudgetExceeded;
        }
    }

    pub fn visibleSparseTileCount(self: *const WorldSystem) usize {
        // The count has no depth-ordering constraint (unlike submitVisibleSparseRange),
        // so walk only the chunks inside the cached visible window via the per-chunk
        // sparse index instead of scanning the whole sparse set every visibility
        // update. The result is identical: every sparse tile in a visible chunk that
        // also passes the finer per-tile bounds test is counted exactly once.
        const region = self.visibleChunkRegion() orelse return 0;
        const bounds = self.visibleTileBounds();
        const chunks_x = self.chunksX();
        const chunks_y = self.chunksY();
        const min_cx: u16 = @intCast(@max(0, region.min.x));
        const min_cy: u16 = @intCast(@max(0, region.min.y));
        const max_cx_exclusive: u16 = @intCast(@min(@as(i32, chunks_x), region.max_exclusive.x));
        const max_cy_exclusive: u16 = @intCast(@min(@as(i32, chunks_y), region.max_exclusive.y));
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        var visible_sparse_tiles: usize = 0;
        var level: u16 = 0;
        while (level < self.level_base_z.items.len) : (level += 1) {
            var cy = min_cy;
            while (cy < max_cy_exclusive) : (cy += 1) {
                var cx = min_cx;
                while (cx < max_cx_exclusive) : (cx += 1) {
                    const local_chunk_index = @as(u32, cy) * @as(u32, chunks_x) + @as(u32, cx);
                    for (self.sparseTileIndicesForChunk(level, local_chunk_index)) |sparse_index| {
                        if (self.cellInVisibleBounds(sparse_cells[sparse_index], bounds)) {
                            visible_sparse_tiles += 1;
                        }
                    }
                }
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

    /// One dense composite draw's slice of `collectDenseSubmitLayers`'s
    /// depth-ascending (deepest-first) output: `submit_layers[start..end]`.
    pub const DenseCompositeBucket = struct {
        start: usize,
        end: usize,
    };

    pub const DenseWindowDepthSpan = struct { min: i32, max: i32 };

    /// Returns the depth span (shallowest/deepest render depth) of whatever
    /// `collectDenseSubmitLayers` would submit for `active_level` this frame, or
    /// null when nothing is in window. Lets callers filter candidate interleave
    /// depths to only the ones that could possibly matter before computing them,
    /// without duplicating the window-selection rule. Reuses the cached span from
    /// the last recompute while `dense_quads_dirty`, `active_level`, and
    /// `render_window` all still match `submitted_active_level`/`submitted_window`
    /// (the same triggers `submitStaticDenseGeometry` gates a re-submit on, so the
    /// window's real dense-layer content is guaranteed unchanged too), sparing a
    /// full dense-layer scan and sort on every still frame. Propagates
    /// `error.TooManyDenseLayers` instead of swallowing it as an empty window.
    pub fn denseWindowDepthSpan(self: *WorldSystem, active_level: u16) error{TooManyDenseLayers}!?DenseWindowDepthSpan {
        if (!self.dense_quads_dirty and
            active_level == self.submitted_active_level and
            windowsEqual(self.render_window, self.submitted_window))
            return self.dense_window_depth_span;

        var submit_layers: [k_max_dense_submit_stack_cap]usize = undefined;
        const submit_count = try self.collectDenseSubmitLayers(active_level, &submit_layers);
        for (submit_layers[0..submit_count], 0..) |layer_index, i| {
            self.dense_window_layer_depths[i] = self.denseLayerOrder(layer_index).depth;
        }
        self.dense_window_layer_depth_count = submit_count;
        const span: ?DenseWindowDepthSpan = if (submit_count == 0) null else .{
            .min = self.dense_window_layer_depths[0],
            .max = self.dense_window_layer_depths[submit_count - 1],
        };
        self.dense_window_depth_span = span;
        return span;
    }

    /// This frame's submitted dense layer depths (ascending, deepest first),
    /// cached by the last `denseWindowDepthSpan` recompute. Callers must call
    /// `denseWindowDepthSpan` for the same `active_level` first in the same
    /// frame (`render_prep.collectDenseInterleaveDepths` does, by construction)
    /// so this reads a fresh cache rather than a stale one from a prior level
    /// or window.
    pub fn denseWindowLayerDepths(self: *const WorldSystem) []const i32 {
        return self.dense_window_layer_depths[0..self.dense_window_layer_depth_count];
    }

    /// The render depth an actor standing on `active_level` draws at. Always
    /// treated as an interleave point so the common case (no other sandwiched
    /// content) still splits off a `ceiling_when_underground` plane exactly like
    /// before this frame's dense stack was collapsed to composite draws.
    pub fn activeLevelActorDepth(self: *const WorldSystem, active_level: u16) i32 {
        return self.worldZForLevel(active_level, 0, .actor);
    }

    /// Submits this frame's dense window as one retained world-space tilemap
    /// quad per composite draw: each draw's fragment shader walks a topmost-first
    /// window of dense layers sharing the combined tile-data buffer, stopping at
    /// the first opaque cell, so a whole run of layers with nothing sandwiched
    /// between them is one draw independent of world size. `interleave_depths`
    /// (sorted ascending, deduplicated) are this frame's cut points — depths
    /// something else (a sparse tile, a dynamic entity) needs to render strictly
    /// between two dense layers; each one splits the stack into another
    /// composite draw at that boundary. Builds the combined storage buffer on
    /// first call. Re-submits on a structural change (`dense_quads_dirty`), an
    /// `active_level`/window change, or an interleave-depth-set change — never
    /// on a pan alone, since the quads are full-world and the camera lives in
    /// the vertex shader.
    pub fn submitStaticDenseGeometry(
        self: *WorldSystem,
        renderer: *Renderer,
        runtime_assets: *const RuntimeAssets,
        active_level: u16,
        interleave_depths: []const i32,
    ) !void {
        const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
        try self.uploadDenseTileDataBuffer(renderer);
        if (!self.dense_quads_dirty and
            active_level == self.submitted_active_level and
            windowsEqual(self.render_window, self.submitted_window) and
            std.mem.eql(i32, self.submitted_interleave_depths[0..self.submitted_interleave_count], interleave_depths))
            return;

        // The tilemap atlas params are baked from the world atlas dimensions at init;
        // the bound runtime texture must match. Safe-build only, and only on a
        // re-submit (structural change), not still frames.
        if (std.debug.runtime_safety) {
            if (renderer.textureDesc(prepared.texture)) |desc| {
                std.debug.assert(desc.width == self.atlas_texture.width and desc.height == self.atlas_texture.height);
            }
        }

        var submit_layers: [k_max_dense_submit_stack_cap]usize = undefined;
        const submit_count = try self.collectDenseSubmitLayers(active_level, &submit_layers);
        std.debug.assert(submit_count <= self.maxDenseSubmitLayerCount());
        renderer.beginStaticGeometry();

        if (submit_count > 0) {
            var buckets: [Renderer.k_max_dense_composite_draws]DenseCompositeBucket = undefined;
            const bucket_count = self.partitionDenseCompositeBuckets(
                submit_layers[0..submit_count],
                interleave_depths,
                &buckets,
            );

            // Only the world-space corners (position) are consumed by the tilemap
            // shader; the source/uv are ignored, so the source rect is a
            // placeholder. Built once and reused for every composite draw.
            const world_w = self.worldWidthPixels();
            const world_h = self.worldHeightPixels();
            var pos: [6]Position = undefined;
            var uv: [6]Uv = undefined;
            var col: [6]VertexColor = undefined;
            writeWorldSpriteQuad(.{
                .texture = TextureId.invalid,
                .source = .{ .x = 0, .y = 0, .w = self.tile_size, .h = self.tile_size },
                .dest = .{ .x = 0, .y = 0, .w = world_w, .h = world_h },
            }, self.atlas_texture, .{ .positions = &pos, .uvs = &uv, .colors = &col });

            for (buckets[0..bucket_count]) |bucket| {
                var window_layers = try self.buildWindowLayers(submit_layers[0..submit_count], bucket.start, bucket.end);
                // True only for the bucket holding the overall shallowest submitted
                // layer (the last bucket, since submit_layers is depth-ascending):
                // the fragment shader's rim-shadow effect must gate on this, not on
                // its own draw-local `resolved_depth == 0`, since a bucket split for
                // an unrelated interleave point elsewhere can put a merely
                // hole-revealed (not truly topmost) tile at `resolved_depth == 0`
                // within its own draw.
                window_layers.is_shallowest_bucket = bucket.end == submit_count;
                // Order = the bucket's own shallowest submitted layer (depth-ascending
                // input means that is the last index in the bucket's range).
                const order = self.denseLayerOrder(submit_layers[bucket.end - 1]);
                try renderer.appendStaticTilemapSpan(
                    prepared.texture,
                    order,
                    .{ .positions = &pos, .uvs = &uv, .colors = &col },
                    self.denseTileDataBuffer(),
                    window_layers,
                );
            }
        }

        self.dense_quads_dirty = false;
        self.submitted_active_level = active_level;
        self.submitted_window = self.render_window;
        self.storeSubmittedInterleaveDepths(interleave_depths);
    }

    fn storeSubmittedInterleaveDepths(self: *WorldSystem, interleave_depths: []const i32) void {
        std.debug.assert(interleave_depths.len <= self.submitted_interleave_depths.len);
        @memcpy(self.submitted_interleave_depths[0..interleave_depths.len], interleave_depths);
        self.submitted_interleave_count = interleave_depths.len;
    }

    /// Cuts `submit_layers` (depth-ascending, deepest-first, per
    /// `collectDenseSubmitLayers`'s contract) into composite-draw buckets: a new
    /// bucket boundary is placed at every point where an `interleave_depths`
    /// value falls strictly between two consecutive submitted layers' depths
    /// (or exactly at the shallower one, since nothing may draw between that
    /// pair once composited together). `interleave_depths` must be sorted
    /// ascending and deduplicated (asserted). Writes bucket ranges into `out`
    /// and returns the count. Every cut point consumes at least one submitted
    /// layer, so `out`'s count can never exceed `submit_layers.len`, which is
    /// itself hard-capped at `k_max_dense_submit_stack_cap` — the comptime
    /// assert tying `Renderer.k_max_dense_composite_draws` to that same cap
    /// makes `out.len` always sufficient, so overflow here is unreachable in
    /// a correct build, not a runtime condition to degrade gracefully around.
    fn partitionDenseCompositeBuckets(
        self: *const WorldSystem,
        submit_layers: []const usize,
        interleave_depths: []const i32,
        out: []DenseCompositeBucket,
    ) usize {
        if (submit_layers.len == 0) return 0;
        if (std.debug.runtime_safety and interleave_depths.len > 1) {
            for (1..interleave_depths.len) |i| {
                std.debug.assert(interleave_depths[i] > interleave_depths[i - 1]);
            }
        }
        var bucket_count: usize = 0;
        var bucket_start: usize = 0;
        var interleave_index: usize = 0;
        for (1..submit_layers.len + 1) |index| {
            var cut = index == submit_layers.len;
            if (!cut) {
                const prev_depth = self.denseLayerOrder(submit_layers[index - 1]).depth;
                const next_depth = self.denseLayerOrder(submit_layers[index]).depth;
                while (interleave_index < interleave_depths.len and interleave_depths[interleave_index] <= prev_depth) {
                    interleave_index += 1;
                }
                if (interleave_index < interleave_depths.len and interleave_depths[interleave_index] <= next_depth) {
                    cut = true;
                }
            }
            if (cut) {
                std.debug.assert(bucket_count < out.len);
                out[bucket_count] = .{ .start = bucket_start, .end = index };
                bucket_count += 1;
                bucket_start = index;
            }
        }
        return bucket_count;
    }

    /// Reverses one bucket's depth-ascending (deepest-first) layer slice into a
    /// topmost-first `TilemapWindowLayers`, since the shader composites from the
    /// top down.
    fn buildWindowLayers(
        self: *const WorldSystem,
        submit_layers: []const usize,
        bucket_start: usize,
        bucket_end: usize,
    ) !Renderer.TilemapWindowLayers {
        var window = Renderer.TilemapWindowLayers{};
        var index = bucket_end;
        while (index > bucket_start) {
            index -= 1;
            const offset = self.denseLayerOffset(submit_layers[index]);
            window.offsets[window.count] = std.math.cast(u32, offset) orelse return error.TileDataOffsetTooLarge;
            window.count += 1;
        }
        return window;
    }

    fn collectDenseSubmitLayers(
        self: *const WorldSystem,
        active_level: u16,
        out: []usize,
    ) error{TooManyDenseLayers}!usize {
        const max_world_level: u16 = self.maxLevelIndex();
        var submit_count: usize = 0;
        const layer_count = self.denseLayerCount();
        for (0..layer_count) |layer_index| {
            const world_level = self.denseLayerLevel(layer_index);
            if (!self.render_window.levelInWindow(active_level, world_level, max_world_level)) continue;
            if (submit_count >= out.len) return error.TooManyDenseLayers;
            out[submit_count] = layer_index;
            submit_count += 1;
        }
        // Back-to-front: deepest plane first so each higher floor composites on top.
        std.mem.sort(usize, out[0..submit_count], self, denseLayerIndexLessThan);
        return submit_count;
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

    /// Distinct sparse render depths registered this frame (`sparse_depth_ranges`
    /// length). Paired with `sparseDepthRangeAt` so a caller that needs the
    /// ascending depth sequence more than once per frame can walk it by index
    /// instead of paying `nextVisibleSparseDepthAfter`'s rescan-from-start cursor
    /// twice. Callers must keep the index current via `ensureRenderDepthIndex`.
    pub fn sparseDepthRangeCount(self: *const WorldSystem) usize {
        return self.sparse_depth_ranges.items.len;
    }

    /// The `index`th distinct sparse render depth, ascending order.
    pub fn sparseDepthRangeAt(self: *const WorldSystem, index: usize) i32 {
        return self.sparse_depth_ranges.items[index].depth;
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
    /// source of truth), queues one GPU cell edit once the combined buffer exists,
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
        self.dense_layers.items(.uniform_fill_tile)[layer_index] = null;
        self.dense_tile_ids.items[tile_index] = tile_id;
        // Queue the GPU cell update once the combined buffer exists. Before it is
        // built, the initial full upload captures the tile, so no edit is needed.
        // element_index is the global flat offset (matches this buffer's layout),
        // not a per-layer-local index.
        const buffer = self.denseTileDataBuffer();
        if (buffer != .invalid) {
            try self.dense_tile_edits.append(self.allocator, .{
                .buffer = buffer,
                .element_index = tile_index,
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

    /// Widens the whole flat dense tile-id array (every dense layer's cells
    /// concatenated, in layer order) into `out` (one `u32` per cell) for
    /// storage-buffer upload. `out.len` must equal `dense_tile_ids.items.len`.
    /// The row-major order within each layer is exactly the tilemap shader's
    /// `cell.y * width + cell.x` read (offset by that layer's own
    /// `denseLayerOffset`), so the GPU lookup matches `cellIndex`. Load-time
    /// only (not a frame path).
    fn widenDenseTileData(self: *const WorldSystem, out: []u32) void {
        std.debug.assert(out.len == self.dense_tile_ids.items.len);
        for (self.dense_tile_ids.items, out) |tile, *dst| dst.* = tile;
    }

    /// Builds the single renderer-owned tile-data storage buffer from the whole
    /// flat `dense_tile_ids` array. Idempotent: a no-op once the buffer exists.
    /// Call once at world load, before the tilemap layers are submitted for
    /// drawing.
    pub fn uploadDenseTileDataBuffer(self: *WorldSystem, renderer: *Renderer) !void {
        if (self.dense_tile_data_buffer != .invalid) return;

        const scratch = try self.allocator.alloc(u32, self.dense_tile_ids.items.len);
        defer self.allocator.free(scratch);
        self.widenDenseTileData(scratch);
        self.dense_tile_data_buffer = try renderer.createTileDataBuffer(scratch, self.tilemap_params);
    }

    /// Releases the renderer-owned tile-data buffer this world created and drops
    /// the local handle, keeping the world's handle and the renderer in sync.
    /// The symmetric teardown for `uploadDenseTileDataBuffer`: call before
    /// rebuilding the dense tilemap when the renderer outlives the world. App
    /// shutdown instead frees this through `Renderer.deinit`.
    pub fn releaseDenseTileDataBuffer(self: *WorldSystem, renderer: *Renderer) void {
        renderer.releaseTileDataBuffers();
        self.dense_tile_data_buffer = .invalid;
    }

    /// The combined tile-data storage buffer handle (`.invalid` until
    /// `uploadDenseTileDataBuffer` has run).
    pub fn denseTileDataBuffer(self: *const WorldSystem) TileDataId {
        return self.dense_tile_data_buffer;
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

    /// Tile-cell coordinate of a sparse tile, decoded from its stored cell index.
    pub fn sparseTileCellCoord(self: *const WorldSystem, index: usize) CellCoord {
        const cell = self.sparse_tiles.items(.cell_index)[index];
        return .{
            .x = @intCast(cell % self.width),
            .y = @intCast(cell / self.width),
        };
    }

    /// Indices into `sparse_tiles` for every sparse tile on `level_index`, in no
    /// particular order. Empty for an out-of-range level and for a level that
    /// has no sparse tiles yet — callers do not need to distinguish the two.
    /// Backed by `sparse_level_tiles`, maintained eagerly by `addSparseTile` (see
    /// that field's doc comment), so this is always current with no rebuild step.
    pub fn sparseTileIndicesForLevel(self: *const WorldSystem, level_index: u16) []const u32 {
        if (level_index >= self.sparse_level_tiles.items.len) return &.{};
        return self.sparse_level_tiles.items[level_index].items;
    }

    /// Indices into `sparse_tiles` for every sparse tile in `chunk_index` (a
    /// level-local chunk offset, `chunkY*chunksX+chunkX` — see
    /// `localChunkIndexForCell`) on `level_index`, in no particular order.
    /// Empty for an out-of-range level or chunk. Backed by
    /// `sparse_level_chunk_tiles`, maintained the same way as
    /// `sparse_level_tiles` (see that field's comment) so this is always
    /// current with no rebuild step. Finer-grained than
    /// `sparseTileIndicesForLevel` for consumers that only need one chunk's
    /// worth of sparse tiles.
    pub fn sparseTileIndicesForChunk(self: *const WorldSystem, level_index: u16, chunk_index: u32) []const u32 {
        if (level_index >= self.sparse_level_chunk_tiles.items.len) return &.{};
        const level_chunks = self.sparse_level_chunk_tiles.items[level_index].items;
        if (chunk_index >= level_chunks.len) return &.{};
        return level_chunks[chunk_index].items;
    }

    // Reserves capacity for one more entry in level_index's sparse_level_tiles
    // bucket, growing the outer list with empty buckets up to level_index
    // first if needed. Mutates no already-committed data — only capacity.
    // Paired with commitSparseLevelIndexEntry so addSparseTile can reserve
    // every sparse structure before committing to any of them (see
    // addSparseTile): either every reservation for a tile succeeds and every
    // commit is then guaranteed to succeed, or the whole call fails with
    // nothing observably changed.
    fn reserveSparseLevelIndexEntry(self: *WorldSystem, level_index: u16) !void {
        const needed_buckets = @as(usize, level_index) + 1;
        if (self.sparse_level_tiles.items.len < needed_buckets) {
            try self.sparse_level_tiles.ensureTotalCapacity(self.allocator, needed_buckets);
            while (self.sparse_level_tiles.items.len < needed_buckets) {
                self.sparse_level_tiles.appendAssumeCapacity(.empty);
            }
        }
        const bucket = &self.sparse_level_tiles.items[level_index];
        try bucket.ensureTotalCapacity(self.allocator, bucket.items.len + 1);
    }

    // Infallible append into level_index's sparse_level_tiles bucket. Call
    // only after reserveSparseLevelIndexEntry(level_index) has succeeded.
    fn commitSparseLevelIndexEntry(self: *WorldSystem, level_index: u16, sparse_index: u32) void {
        self.sparse_level_tiles.items[level_index].appendAssumeCapacity(sparse_index);
    }

    // Reserves capacity for one more entry in (level_index, chunk_index)'s
    // sparse_level_chunk_tiles bucket: grows the outer per-level list, then
    // that level's per-chunk list to chunkCountPerLevel() buckets on first
    // touch, then the target chunk's bucket. Mutates no already-committed
    // data — only capacity and empty placeholder buckets. See
    // reserveSparseLevelIndexEntry for why this is split from its commit.
    fn reserveSparseChunkIndexEntry(self: *WorldSystem, level_index: u16, chunk_index: u32) !void {
        const needed_levels = @as(usize, level_index) + 1;
        if (self.sparse_level_chunk_tiles.items.len < needed_levels) {
            try self.sparse_level_chunk_tiles.ensureTotalCapacity(self.allocator, needed_levels);
            while (self.sparse_level_chunk_tiles.items.len < needed_levels) {
                self.sparse_level_chunk_tiles.appendAssumeCapacity(.empty);
            }
        }
        const level_chunks = &self.sparse_level_chunk_tiles.items[level_index];
        const needed_chunks = self.chunkCountPerLevel();
        if (level_chunks.items.len < needed_chunks) {
            try level_chunks.ensureTotalCapacity(self.allocator, needed_chunks);
            while (level_chunks.items.len < needed_chunks) {
                level_chunks.appendAssumeCapacity(.empty);
            }
        }
        const bucket = &level_chunks.items[chunk_index];
        try bucket.ensureTotalCapacity(self.allocator, bucket.items.len + 1);
    }

    // Infallible append into (level_index, chunk_index)'s
    // sparse_level_chunk_tiles bucket. Call only after
    // reserveSparseChunkIndexEntry(level_index, chunk_index) has succeeded.
    fn commitSparseChunkIndexEntry(self: *WorldSystem, level_index: u16, chunk_index: u32, sparse_index: u32) void {
        self.sparse_level_chunk_tiles.items[level_index].items[chunk_index].appendAssumeCapacity(sparse_index);
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
    // dense band columns directly, and only the sparse tiles on this level via
    // `sparseTileIndicesForLevel` instead of scanning every sparse tile in the
    // world.
    pub fn levelBlocksMovement(self: *const WorldSystem, level_index: u16, x: u16, y: u16) bool {
        if (@as(usize, level_index) >= self.level_base_z.items.len) return true;
        if (x >= self.width or y >= self.height) return true;
        const dense_levels = self.dense_layers.items(.level_index);
        for (dense_levels, 0..) |dense_level, layer_index| {
            if (dense_level != level_index) continue;
            if (self.flagsFor(self.denseTile(layer_index, x, y)).blocks_movement) return true;
        }
        const cell = self.cellIndex(x, y);
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        const sparse_flags = self.sparse_tiles.items(.flags);
        for (self.sparseTileIndicesForLevel(level_index)) |sparse_index| {
            if (sparse_cells[sparse_index] != cell) continue;
            if (sparse_flags[sparse_index].blocks_movement) return true;
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
        const level = try self.appendLevelBaseZ(base_z);
        try self.rebuildChunks();
        return level;
    }

    fn appendLevelBaseZ(self: *WorldSystem, base_z: i32) !u16 {
        const index = self.level_base_z.items.len;
        if (index > std.math.maxInt(u16)) return error.WorldLevelOverflow;
        try self.level_base_z.ensureUnusedCapacity(self.allocator, 1);
        self.level_base_z.appendAssumeCapacity(base_z);
        return @intCast(index);
    }

    pub fn denseLayerUniformFillTile(self: *const WorldSystem, layer_index: usize) ?TileId {
        if (layer_index >= self.dense_layers.len) return null;
        return self.dense_layers.items(.uniform_fill_tile)[layer_index];
    }

    pub fn clearDenseLayerUniformFill(self: *WorldSystem, layer_index: usize) void {
        if (layer_index >= self.dense_layers.len) return;
        self.dense_layers.items(.uniform_fill_tile)[layer_index] = null;
    }

    /// Fails loud instead of silently dropping a layer's cells: the combined
    /// tile-data buffer is built once from the whole flat `dense_tile_ids`
    /// array (`uploadDenseTileDataBuffer`) and is not incrementally resumable,
    /// so a layer added after that build would compute a valid-looking
    /// `denseLayerOffset` whose cells the GPU buffer never actually contains.
    pub fn addDenseLayer(self: *WorldSystem, level_index: u16, base_z: i32, depth: WorldDepth, fill_tile: TileId) !usize {
        if (self.dense_tile_data_buffer != .invalid) return error.DenseLayerAddedAfterUpload;
        try self.validateLevelIndex(level_index);
        try self.validateTileId(fill_tile);
        try self.trackDenseBandForLevel(level_index);
        const layer_index = self.dense_layers.len;
        const cell_count = self.cellCount();
        const tile_offset = self.dense_tile_ids.items.len;
        try self.dense_layers.ensureTotalCapacity(self.allocator, layer_index + 1);
        try self.dense_tile_ids.ensureTotalCapacity(self.allocator, tile_offset + cell_count);
        self.dense_layers.appendAssumeCapacity(.{
            .level_index = level_index,
            .base_z = base_z,
            .depth_band = depth,
            .uniform_fill_tile = fill_tile,
        });
        self.dense_tile_ids.items.len = tile_offset + cell_count;
        @memset(self.dense_tile_ids.items[tile_offset..][0..cell_count], fill_tile);
        self.render_index_dirty = true;
        // A new dense layer needs its own tilemap quad submitted; the combined
        // storage buffer is built lazily on the next submit (uploadDenseTileDataBuffer).
        // The guard above already rejects layers added after that build.
        self.dense_quads_dirty = true;
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
        try self.rebuildChunks();
    }

    /// Adds the two solid underground planes beneath the surface (level 0): a dirt
    /// floor one step down, a dark floor two steps down. Digging a hole in a plane
    /// reveals the one below. Thin wrapper over `addUndergroundLevelStack` for the
    /// legacy three-level demo world.
    pub fn addUndergroundLevels(self: *WorldSystem, meta: *const WorldTilesetMeta) !void {
        try self.addUndergroundLevelStack(meta, 2);
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
        const local_chunk_index = self.localChunkIndexForCell(x, y);
        const flags = self.flagsFor(tile_id);
        const world_z = self.worldZForLevel(level_index, base_z, depth);

        // Reserve capacity in sparse_tiles, sparse_level_tiles, and
        // sparse_level_chunk_tiles before committing to any of them: an OOM
        // partway through would otherwise leave a tile in one structure but
        // invisible to the level/chunk lookups the other two back (nav
        // rebuild, perception's blocked cache). Either all three reservations
        // succeed and the three appends below are then infallible, or the
        // call fails here with none of the three structures changed.
        try self.sparse_tiles.ensureTotalCapacity(self.allocator, self.sparse_tiles.len + 1);
        try self.reserveSparseLevelIndexEntry(level_index);
        try self.reserveSparseChunkIndexEntry(level_index, local_chunk_index);

        const new_index: u32 = @intCast(self.sparse_tiles.len);
        self.sparse_tiles.appendAssumeCapacity(.{
            .level_index = level_index,
            .chunk_index = chunk_index,
            .cell_index = cell,
            .tile_id = tile_id,
            .depth_value = world_z,
            .flags = flags,
        });
        self.commitSparseLevelIndexEntry(level_index, new_index);
        self.commitSparseChunkIndexEntry(level_index, local_chunk_index, new_index);
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
        return .{
            .x = self.catalog_source_x.items[index],
            .y = self.catalog_source_y.items[index],
            .w = self.catalog_source_w.items[index],
            .h = self.catalog_source_h.items[index],
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

    fn trackDenseBandForLevel(self: *WorldSystem, level_index: u16) error{ DenseLayerWindowExceeded, OutOfMemory }!void {
        const slot = @as(usize, level_index) + 1;
        try self.dense_bands_per_level.ensureTotalCapacity(self.allocator, slot);
        while (self.dense_bands_per_level.items.len < slot) {
            self.dense_bands_per_level.appendAssumeCapacity(0);
        }
        const next = self.dense_bands_per_level.items[level_index] +% 1;
        if (next == 0 or next > self.max_dense_bands_per_level) return error.DenseLayerWindowExceeded;
        self.dense_bands_per_level.items[level_index] = next;
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
        const local_chunk_index = self.localChunkIndexForCell(x, y);
        const level_offset = @as(usize, level_index) * @as(usize, chunks_x) * @as(usize, chunks_y);
        const index = level_offset + @as(usize, local_chunk_index);
        if (index > std.math.maxInt(u32)) return error.WorldChunkOverflow;
        return @intCast(index);
    }

    // Flat level-local chunk offset for a cell (chunkY*chunksX+chunkX),
    // identical for every level since width/height/chunk_size_tiles are
    // world-wide, not per-level. Backs sparse_level_chunk_tiles' middle
    // dimension; sparseChunkIndexForCell adds the level offset on top of this
    // for the world-global chunk_index stored on each SparseTileRow.
    fn localChunkIndexForCell(self: *const WorldSystem, x: u16, y: u16) u32 {
        const chunks_x = self.chunksX();
        const chunk_x = x / self.chunk_size_tiles;
        const chunk_y = y / self.chunk_size_tiles;
        return @as(u32, chunk_y) * @as(u32, chunks_x) + @as(u32, chunk_x);
    }

    /// Level-local chunk grid width (world-wide, identical for every level —
    /// see `localChunkIndexForCell`). Exposed for callers (e.g. perception's
    /// LOS-blocked cache patch path) that need to bound a dirty rect to the
    /// overlapping `sparseTileIndicesForChunk` range without duplicating this
    /// grid-shape arithmetic.
    pub fn chunksX(self: *const WorldSystem) u16 {
        return ceilDiv(self.width, self.chunk_size_tiles);
    }

    /// Level-local chunk grid height. See `chunksX`.
    pub fn chunksY(self: *const WorldSystem) u16 {
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
    const chunks_y = ceilDiv(build.height, build.chunk_size_tiles);
    // Threaded worldgen write-range hardening (mirrors movement/collision/perception
    // workers): the dispatched range indexes chunks, and this worker writes each
    // chunk's cells at `y * width + x` (y < height, x < width), so its maximum write
    // index is bounded by `width * height`, which must fit the shared tile buffer.
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= @as(usize, chunks_x) * @as(usize, chunks_y));
    std.debug.assert(@as(usize, build.width) * @as(usize, build.height) <= build.tiles.len);
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

fn windowsEqual(a: DenseLayerRenderWindow, b: DenseLayerRenderWindow) bool {
    return a.levels_below == b.levels_below and a.ceiling_when_underground == b.ceiling_when_underground;
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

test "dense tile-data staging matches denseTile by row-major cell index" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.setDenseTile(0, 2, 1, grass);

    const staging = try std.testing.allocator.alloc(u32, world.dense_tile_ids.items.len);
    defer std.testing.allocator.free(staging);
    world.widenDenseTileData(staging);

    for (0..world.height) |y| {
        for (0..world.width) |x| {
            const xi: u16 = @intCast(x);
            const yi: u16 = @intCast(y);
            // The shader reads tile_ids[cell.y*width + cell.x] from layer 0's own
            // base offset within the combined buffer; denseLayerOffset(0) +
            // cellIndex is that same index, so staging[..] must equal the tile.
            try std.testing.expectEqual(
                @as(u32, world.denseTile(0, xi, yi)),
                staging[world.denseLayerOffset(0) + world.cellIndex(xi, yi)],
            );
        }
    }
}

test "setDenseTile queues a GPU cell edit only once the combined buffer exists" {
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

    // Simulate the combined storage buffer having been built (uploadDenseTileDataBuffer
    // needs a renderer, unavailable headless).
    world.dense_tile_data_buffer = @enumFromInt(0);

    _ = try world.setDenseTile(0, 1, 0, grass);
    try std.testing.expectEqual(@as(usize, 1), world.dense_tile_edits.items.len);
    const edit = world.dense_tile_edits.items[0];
    try std.testing.expectEqual(world.denseLayerOffset(0) + @as(usize, world.cellIndex(1, 0)), edit.element_index);
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

test "sparseTileIndicesForLevel returns exactly this level's sparse tile indices" {
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
    const level2 = try world.addLevel(20); // added but never given a sparse tile
    const deco = try world.requireTileByName(&meta, "deco_0");

    // Interleave insertion order across levels so a level's grouping cannot be
    // inferred from insertion order alone — only the level field decides it.
    _ = try world.addSparseTile(level0, 1, 1, deco, 0, .obstacle); // sparse index 0
    _ = try world.addSparseTile(level1, 2, 2, deco, 0, .obstacle); // sparse index 1
    _ = try world.addSparseTile(level0, 3, 3, deco, 0, .obstacle); // sparse index 2
    _ = try world.addSparseTile(level1, 4, 4, deco, 0, .obstacle); // sparse index 3
    _ = try world.addSparseTile(level0, 5, 5, deco, 0, .obstacle); // sparse index 4

    try expectSparseIndexSetEqual(&.{ 0, 2, 4 }, world.sparseTileIndicesForLevel(level0));
    try expectSparseIndexSetEqual(&.{ 1, 3 }, world.sparseTileIndicesForLevel(level1));
    // A real level with no sparse tiles placed on it yet.
    try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForLevel(level2));
    // An out-of-range level.
    try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForLevel(99));
}

test "sparseTileIndicesForChunk returns exactly the chunk-scoped subset of sparseTileIndicesForLevel" {
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
    // level1 > 0 so its global chunk_index (level_index*chunkCountPerLevel +
    // local) differs from the level-local one this index is keyed by,
    // proving the two are not conflated.
    _ = try world.addSparseTile(level1, 2, 2, deco, 0, .obstacle); // level1 chunk3
    _ = try world.addSparseTile(level1, 0, 1, deco, 0, .obstacle); // level1 chunk0

    const chunks_x: u32 = 2;
    for ([_]u16{ level0, level1 }) |level| {
        const level_indices = world.sparseTileIndicesForLevel(level);
        var chunk: u32 = 0;
        while (chunk < 4) : (chunk += 1) {
            var expected: std.ArrayList(u32) = .empty;
            defer expected.deinit(std.testing.allocator);
            for (level_indices) |sparse_index| {
                const cell = world.sparseTileCellCoord(sparse_index);
                const cell_chunk = @as(u32, cell.y / 2) * chunks_x + @as(u32, cell.x / 2);
                if (cell_chunk == chunk) try expected.append(std.testing.allocator, sparse_index);
            }
            try expectSparseIndexSetEqual(expected.items, world.sparseTileIndicesForChunk(level, chunk));
        }
    }

    // Out-of-range level and out-of-range chunk both return empty, matching
    // sparseTileIndicesForLevel's out-of-range contract.
    try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForChunk(99, 0));
    try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForChunk(level0, 99));
}

test "addSparseTile reserves sparse_tiles, sparse_level_tiles, and sparse_level_chunk_tiles before committing any of them (FailingAllocator)" {
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

    // Case 1: sparse_tiles' own reservation fails on the very first
    // addSparseTile call ever, before sparse_level_tiles or
    // sparse_level_chunk_tiles have any entries to compare against.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level0, 0, 0, deco, 0, .obstacle));
        try std.testing.expectEqual(@as(usize, 0), world.sparse_tiles.len);
        try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForLevel(level0));
        try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForChunk(level0, 0));
    }

    // Warm up with one real insert (level0, chunk0) so the next two cases can
    // isolate a single fresh reservation each, with every other structure
    // already carrying spare capacity from this insert.
    _ = try world.addSparseTile(level0, 0, 0, deco, 0, .obstacle); // sparse index 0
    try std.testing.expectEqual(@as(usize, 1), world.sparse_tiles.len);

    // Case 2: a new level's sparse_level_tiles bucket needs its first-ever
    // reservation. sparse_tiles has spare capacity from the warm-up insert
    // and needs no allocation for this call.
    const level1 = try world.addLevel(10);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level1, 0, 0, deco, 0, .obstacle));
        try std.testing.expectEqual(@as(usize, 1), world.sparse_tiles.len);
        try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForLevel(level1));
        try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForChunk(level1, 0));
    }

    // Case 3: a new chunk bucket on the already-warmed level0 needs its
    // first-ever reservation. sparse_tiles and level0's sparse_level_tiles
    // bucket both have spare capacity and need no allocation for this call.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;

        // Cell (3,3) is level-local chunk 3 (chunkY=1*2+chunkX=1), untouched
        // by the level0/chunk0 warm-up insert above.
        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level0, 3, 3, deco, 0, .obstacle));
        try std.testing.expectEqual(@as(usize, 1), world.sparse_tiles.len);
        try expectSparseIndexSetEqual(&.{0}, world.sparseTileIndicesForLevel(level0));
        try expectSparseIndexSetEqual(&.{}, world.sparseTileIndicesForChunk(level0, 3));
    }
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
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 16, 16);
    defer world.deinit();
    try world.addUndergroundLevelStack(&meta, 10);
    try std.testing.expectEqual(@as(usize, 11), world.levelCount());
    try std.testing.expect(world.denseFloorLayerForLevel(10) != null);
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

test "dense render window includes six levels below surface play" {
    const window: DenseLayerRenderWindow = .{};
    const max_level: u16 = 31;
    try std.testing.expect(window.levelInWindow(0, 0, max_level));
    try std.testing.expect(window.levelInWindow(0, 6, max_level));
    try std.testing.expect(!window.levelInWindow(0, 7, max_level));
}

test "dense render window skips floors above the player underground" {
    const window: DenseLayerRenderWindow = .{};
    const max_level: u16 = 50;
    try std.testing.expect(!window.levelInWindow(20, 0, max_level));
    try std.testing.expect(!window.levelInWindow(20, 19, max_level));
    try std.testing.expect(window.levelInWindow(20, 20, max_level));
    try std.testing.expect(window.levelInWindow(20, 26, max_level));
    try std.testing.expect(!window.levelInWindow(20, 27, max_level));
}

test "dense render window optional ceiling band is opt-in" {
    const window: DenseLayerRenderWindow = .{ .ceiling_when_underground = true };
    const max_level: u16 = 50;
    try std.testing.expect(window.levelInWindow(20, 19, max_level));
    try std.testing.expect(!window.levelInWindow(20, 18, max_level));
}

test "collectDenseSubmitLayers caps surface play to render window" {
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
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..32) |level_index| {
        const level = try world.addLevel(@intCast(@as(i32, @intCast(level_index)) * level_z_step));
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(0, &layers);
    try std.testing.expectEqual(@as(usize, 7), count);
    for (layers[0..count]) |layer_index| {
        const level = world.denseLayerLevel(layer_index);
        try std.testing.expect(level <= 6);
    }
    for (1..count) |sorted_index| {
        try std.testing.expect(
            world.denseLayerOrder(layers[sorted_index - 1]).depth <
                world.denseLayerOrder(layers[sorted_index]).depth,
        );
    }
}

test "collectDenseSubmitLayers deep play follows player level not surface" {
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
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..50) |level_index| {
        const level = try world.addLevel(@intCast(@as(i32, @intCast(level_index)) * level_z_step));
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(20, &layers);
    try std.testing.expectEqual(@as(usize, 7), count);
    for (layers[0..count]) |layer_index| {
        const level = world.denseLayerLevel(layer_index);
        try std.testing.expect(level >= 20 and level <= 26);
    }
}

test "collectDenseSubmitLayers shifts with player level transitions" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const surface_count = try world.collectDenseSubmitLayers(0, &layers);
    try std.testing.expectEqual(@as(usize, 3), surface_count);
    var saw_surface = false;
    for (layers[0..surface_count]) |layer_index| {
        if (world.denseLayerLevel(layer_index) == 0) saw_surface = true;
    }
    try std.testing.expect(saw_surface);

    const dirt_count = try world.collectDenseSubmitLayers(1, &layers);
    try std.testing.expectEqual(@as(usize, 2), dirt_count);
    for (layers[0..dirt_count]) |layer_index| {
        try std.testing.expect(world.denseLayerLevel(layer_index) >= 1);
    }

    const void_count = try world.collectDenseSubmitLayers(2, &layers);
    try std.testing.expectEqual(@as(usize, 1), void_count);
    try std.testing.expectEqual(@as(u16, 2), world.denseLayerLevel(layers[0]));
}

test "collectDenseSubmitLayers includes every band on an in-window level" {
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
    const grass = try world.requireTileByName(&meta, "grass");
    const level = try world.addLevel(0);
    _ = try world.addDenseLayer(level, 0, .floor, grass);
    _ = try world.addDenseLayer(level, 0, .obstacle, grass);

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(0, &layers);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "denseWindowDepthSpan returns the submitted window's shallowest and deepest depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    const span = (try world.denseWindowDepthSpan(0)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(world.denseLayerOrder(2).depth, span.min);
    try std.testing.expectEqual(world.denseLayerOrder(0).depth, span.max);
}

test "denseWindowDepthSpan returns null when nothing is in window" {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = 32,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();

    try std.testing.expect((try world.denseWindowDepthSpan(0)) == null);
}

test "denseWindowDepthSpan caches the span until dirty, level, or window changes" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    const first = (try world.denseWindowDepthSpan(0)) orelse return error.TestExpectedEqual;

    // denseWindowDepthSpan itself never clears dense_quads_dirty or updates the
    // submitted_* fields (only an actual submitStaticDenseGeometry call does);
    // set them here to simulate "already submitted for this level/window" so the
    // cache-hit path below is reachable without a live Renderer.
    world.dense_quads_dirty = false;
    world.submitted_active_level = 0;
    world.submitted_window = world.render_window;

    // Mutate the underlying layer order directly (bypassing addDenseLayer, which
    // would mark dense_quads_dirty) to prove a clean-cache call really skips
    // recomputation instead of coincidentally landing on the same answer.
    const swapped = world.denseLayerOrder(0).depth + 1000;
    world.dense_layers.items(.base_z)[0] += 1000;
    const cached = (try world.denseWindowDepthSpan(0)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(first.min, cached.min);
    try std.testing.expectEqual(first.max, cached.max);
    try std.testing.expect(cached.max != swapped);

    world.dense_quads_dirty = true;
    const recomputed = (try world.denseWindowDepthSpan(0)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(swapped, recomputed.max);
}

test "denseWindowDepthSpan propagates TooManyDenseLayers instead of swallowing it" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 40 },
        .max_dense_bands_per_level = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..k_max_dense_submit_stack_cap + 1) |_| {
        const level = try world.addLevel(0);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    try std.testing.expectError(error.TooManyDenseLayers, world.denseWindowDepthSpan(0));
}

test "partitionDenseCompositeBuckets returns a single bucket with no interleave depths in window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(0, &layers);

    var buckets: [Renderer.k_max_dense_composite_draws]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = world.partitionDenseCompositeBuckets(layers[0..count], &.{}, &buckets);

    try std.testing.expectEqual(@as(usize, 1), bucket_count);
    try std.testing.expectEqual(@as(usize, 0), buckets[0].start);
    try std.testing.expectEqual(count, buckets[0].end);
}

test "partitionDenseCompositeBuckets splits off the ceiling layer at the active level's own actor depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .ceiling_when_underground = true },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..5) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(2, &layers);
    try std.testing.expectEqual(@as(usize, 4), count);

    // The active level's own actor depth is the only interleave point — mirrors
    // today's ceiling-vs-window split, now expressed as the general rule.
    const interleave = [_]i32{world.activeLevelActorDepth(2)};
    var buckets: [Renderer.k_max_dense_composite_draws]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = world.partitionDenseCompositeBuckets(layers[0..count], &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, 2), bucket_count);
    try std.testing.expectEqual(@as(usize, 3), buckets[0].end - buckets[0].start);
    try std.testing.expectEqual(@as(usize, 1), buckets[1].end - buckets[1].start);
    try std.testing.expectEqual(@as(u16, 1), world.denseLayerLevel(layers[buckets[1].start]));
}

test "partitionDenseCompositeBuckets splits at a synthetic interleave point on a deeper non-active level" {
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
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..7) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(0, &layers);
    try std.testing.expectEqual(@as(usize, 7), count);

    // A synthetic sandwich point (e.g. a sparse tile) between level 5 and level
    // 4's own floor depths — neither is the active level (0) nor the window's
    // shallowest layer. This is the case an active-level-only design would miss.
    const interleave = [_]i32{world.worldZForLevel(5, 0, .effect)};
    var buckets: [Renderer.k_max_dense_composite_draws]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = world.partitionDenseCompositeBuckets(layers[0..count], &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, 2), bucket_count);
    try std.testing.expectEqual(@as(usize, 2), buckets[0].end - buckets[0].start);
    try std.testing.expectEqual(@as(usize, 5), buckets[1].end - buckets[1].start);
    try std.testing.expectEqual(@as(u16, 5), world.denseLayerLevel(layers[buckets[0].end - 1]));
    try std.testing.expectEqual(@as(u16, 4), world.denseLayerLevel(layers[buckets[1].start]));
}

test "partitionDenseCompositeBuckets produces one bucket per cut point at the proven worst case, no fold or error" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 40 },
        .max_dense_bands_per_level = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..k_max_dense_submit_stack_cap) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(0, &layers);
    try std.testing.expectEqual(k_max_dense_submit_stack_cap, count);

    // One interleave point strictly between every consecutive submitted-layer
    // pair: `submit_layers.len - 1` cut points, the mathematically-proven
    // worst case bucket count `Renderer.k_max_dense_composite_draws` is now
    // sized to cover exactly, so this never folds or errors even here.
    var interleave: [k_max_dense_submit_stack_cap - 1]i32 = undefined;
    for (0..k_max_dense_submit_stack_cap - 1) |i| {
        const deeper = world.denseLayerOrder(layers[i]).depth;
        const shallower = world.denseLayerOrder(layers[i + 1]).depth;
        interleave[i] = deeper + @divTrunc(shallower - deeper, 2);
    }

    var buckets: [Renderer.k_max_dense_composite_draws]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = world.partitionDenseCompositeBuckets(layers[0..count], &interleave, &buckets);

    try std.testing.expectEqual(k_max_dense_submit_stack_cap, bucket_count);
    for (0..bucket_count) |i| {
        try std.testing.expectEqual(@as(usize, 1), buckets[i].end - buckets[i].start);
    }
}

test "buildWindowLayers reverses a bucket's deepest-first layers to topmost-first offsets" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layers: [k_max_dense_submit_stack_cap]usize = undefined;
    const count = try world.collectDenseSubmitLayers(0, &layers);
    try std.testing.expectEqual(@as(usize, 3), count);

    const window = try world.buildWindowLayers(layers[0..count], 0, count);

    try std.testing.expectEqual(@as(u8, 3), window.count);
    // submit_layers is deepest-first (dirt_dark, dirt, grass); the window must be
    // topmost-first (grass, dirt, dirt_dark) since the shader composites downward.
    try std.testing.expectEqual(@as(u32, @intCast(world.denseLayerOffset(layers[2]))), window.offsets[0]);
    try std.testing.expectEqual(@as(u32, @intCast(world.denseLayerOffset(layers[1]))), window.offsets[1]);
    try std.testing.expectEqual(@as(u32, @intCast(world.denseLayerOffset(layers[0]))), window.offsets[2]);
}

test "submitStaticDenseGeometry marks only the bucket holding the shallowest submitted layer, regardless of where an unrelated interleave point splits the stack" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 64, 64);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const level1 = try world.addLevel(-level_z_step);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    world.dense_tile_data_buffer = @enumFromInt(0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));

    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.batch.deinit();
    defer renderer.static_positions.deinit(allocator);
    defer renderer.static_uvs.deinit(allocator);
    defer renderer.static_colors.deinit(allocator);
    defer renderer.static_groups.deinit(allocator);
    defer renderer.draw_list.deinit(allocator);

    // No interleave points this frame: both layers merge into one bucket,
    // which must be marked shallowest (the common case the rim-shadow effect
    // was originally written for).
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try std.testing.expectEqual(@as(usize, 1), renderer.tilemap_window_layer_count);
    try std.testing.expect(renderer.tilemap_window_layers[0].is_shallowest_bucket);

    // An unrelated interleave point (e.g. a dynamic entity or sparse tile
    // elsewhere on the map, nothing to do with this cell's own geometry)
    // strictly between the two layers' depths splits them into two buckets.
    // The deeper bucket -- exactly what a hole in the surface layer would
    // reveal -- must never be marked shallowest, matching the shader's
    // "tile visible through the hole is left alone" contract regardless of
    // how the CPU happened to bucket the draws this frame.
    world.dense_quads_dirty = true;
    const surface_depth = world.denseLayerOrder(0).depth;
    const deeper_depth = world.denseLayerOrder(1).depth;
    const cut = deeper_depth + @divTrunc(surface_depth - deeper_depth, 2);
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{cut});

    try std.testing.expectEqual(@as(usize, 2), renderer.tilemap_window_layer_count);
    try std.testing.expect(!renderer.tilemap_window_layers[0].is_shallowest_bucket);
    try std.testing.expect(renderer.tilemap_window_layers[1].is_shallowest_bucket);
}

test "addDenseLayer rejects bands beyond configured per-level cap" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .max_dense_bands_per_level = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const level = try world.addLevel(0);
    _ = try world.addDenseLayer(level, 0, .floor, grass);
    _ = try world.addDenseLayer(level, 0, .obstacle, grass);
    try std.testing.expectError(error.DenseLayerWindowExceeded, world.addDenseLayer(level, 0, .effect, grass));
}

test "addDenseLayer fails loud once the combined tile-data buffer already exists" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 64, 64);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const level = try world.addLevel(0);

    // Simulate the combined storage buffer having been built (uploadDenseTileDataBuffer
    // needs a renderer, unavailable headless): a layer added after this point would
    // compute a valid-looking denseLayerOffset whose cells the GPU buffer never
    // actually contains, so the call must fail loud instead of silently dropping it.
    world.dense_tile_data_buffer = @enumFromInt(0);

    try std.testing.expectError(error.DenseLayerAddedAfterUpload, world.addDenseLayer(level, 0, .floor, grass));
}

test "validateDenseRenderBudget rejects oversized render window stack cap" {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = 32,
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 20, .ceiling_when_underground = true },
        .max_dense_bands_per_level = 2,
    };
    defer world.deinit();
    try std.testing.expectError(error.DenseLayerWindowExceeded, world.validateDenseRenderBudget());
}

test "validateDenseRenderBudget rejects dense tile gpu budget overrun" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .max_dense_tile_gpu_bytes = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const level = try world.addLevel(0);
    _ = try world.addDenseLayer(level, 0, .floor, grass);
    try std.testing.expectError(error.DenseTileGpuBudgetExceeded, world.validateDenseRenderBudget());
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
