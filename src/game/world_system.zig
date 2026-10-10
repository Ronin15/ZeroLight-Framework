// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned SoA world/tile storage and render preparation.
//! Persistent world data stores stable tile IDs, level/chunk metadata, and
//! gameplay tile flags. Dense tiles, composed movement-blocked bits, and link
//! endpoints are stored per chunk (`world_terrain.zig`) behind the accessors here. Atlas source rectangles are resolved from `tileset_meta`
//! once at build time and cached into per-tile `catalog_source_x/y/w/h` columns,
//! so hot-path `sourceRect` lookups never re-touch tileset metadata at runtime.
//! Renderer handles stay outside this owner.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../core/math.zig");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const PreparedSprite = @import("../assets/runtime_assets.zig").PreparedSprite;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const manifest = @import("../assets/manifest.zig");
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const Rect = @import("../render/renderer.zig").Rect;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const Renderer = @import("../render/renderer.zig").Renderer;
const TilemapParams = @import("../render/renderer.zig").TilemapParams;
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const TileDataId = @import("../render/renderer.zig").TileDataId;
const TileStoreSpan = @import("../render/renderer.zig").TileStoreSpan;
const tile_store_uniform_bit = @import("../render/renderer.zig").tile_store_uniform_bit;
const tile_store_max_side = @import("../render/renderer.zig").tile_store_max_side;
const Sprite = @import("../render/renderer.zig").Sprite;
const sprite_batch = @import("../render/sprite_batch.zig");
const Position = @import("../render/renderer.zig").Position;
const Uv = @import("../render/renderer.zig").Uv;
const VertexColor = @import("../render/renderer.zig").VertexColor;
const writeWorldSpriteQuad = @import("../render/renderer.zig").writeWorldSpriteQuad;
const TextureId = @import("../render/resources.zig").TextureId;
const TextureDesc = @import("../render/resources.zig").TextureDesc;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const JobFn = @import("../app/thread_system.zig").JobFn;
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../app/thread_system.zig").WorkerId;
const WorldObstacleChangedEvent = @import("simulation.zig").WorldObstacleChangedEvent;
const WorldTileChangedEvent = @import("simulation.zig").WorldTileChangedEvent;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const ChunkCoord = @import("simulation_scope.zig").ChunkCoord;
const render_depth = @import("render_depth.zig");
const WorldDepth = render_depth.WorldDepth;
const world_interest = @import("world_interest.zig");
const world_gpu_tiles = @import("world_gpu_tiles.zig");
const GpuTileMirror = @import("world_gpu_tiles.zig").GpuTileMirror;
const log = @import("../core/logging.zig").game;
const logging = @import("../core/logging.zig");
const world_terrain = @import("world_terrain.zig");
const ChunkBits = @import("world_terrain.zig").ChunkBits;
const ChunkBitsStore = @import("world_terrain.zig").ChunkBitsStore;
const ChunkForm = @import("world_terrain.zig").ChunkForm;
const ChunkGeometry = @import("world_terrain.zig").ChunkGeometry;
const DenseLayerStore = @import("world_terrain.zig").DenseLayerStore;
const max_chunk_cells = @import("world_terrain.zig").max_chunk_cells;
const LevelTerrain = @import("world_terrain.zig").LevelTerrain;
const OwnedBlock = @import("world_terrain.zig").OwnedBlock;
const no_link_endpoint = @import("world_terrain.zig").no_link_endpoint;

pub const TileId = u16;
pub const invalid_tile_id: TileId = std.math.maxInt(TileId);
pub const default_chunk_size_tiles: u16 = 16;
/// Largest chunk edge. Terrain, nav, and scope share one edge: a power of two in
/// [1, max_chunk_size_tiles].
pub const max_chunk_size_tiles: u16 = 16;

pub const ChunkGridError = error{ InvalidChunkSize, LevelCellIndexOverflow, ChunkLabelOverflow };

// Cell indices and chunk-local labels are u32 with maxInt as the "none" sentinel.
const chunk_grid_index_sentinel: u64 = std.math.maxInt(u32);

/// O(1) loud index-width check for one level of `width` x `height` cells cut into
/// `chunk_size`-cell chunks: the edge is a power of two in [1, max_chunk_size_tiles],
/// every cell index is below the u32 sentinel, and so is every chunk-local label
/// (`chunk * (chunk_size² + 1) + local`). World create, level add, and the nav build
/// call it before sizing anything from these widths.
pub fn validateChunkGrid(width: usize, height: usize, chunk_size: u16) ChunkGridError!void {
    if (chunk_size == 0 or chunk_size > max_chunk_size_tiles or !std.math.isPowerOfTwo(chunk_size)) {
        return error.InvalidChunkSize;
    }
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

/// Vertical dense-floor render visibility policy: the levels whose dense layers are
/// resident in the world's GPU tile store and submitted, and whose sparse tiles
/// draw. Re-submit fires when `dense_quads_dirty`, `active_level`, or this window
/// changes.
pub const DenseLayerRenderWindow = struct {
    /// Inclusive count of world levels below `active_level` to submit.
    levels_below: u16 = 6,
    /// Optional: when underground (`active_level > 0`), also submit one level
    /// above the player. Off by default — whole-layer tilemaps cannot do per-cell
    /// shaft cull, so enabling this redraws the full ceiling plane and breaks the
    /// render slice following the player down. Hole see-through from the surface
    /// uses `levels_below` while `active_level == 0`.
    ceiling_when_underground: bool = false,

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

// One contiguous run of window sparse tiles that share a render depth, as a slice
// of `SparseWindow.tiles`.
const SparseDepthRange = struct {
    depth: i32,
    start: u32,
    count: u32,
};

// The sparse tiles the render window draws: those on the window's levels inside
// its tile bounds, ordered by (depth, cell, tile id), with one range per distinct
// depth. Rebuilt by the window update when the window moves or `dirty` is set
// (a tile added or removed inside the current window, or a removal that moved a
// row the list holds); render-only.
const SparseWindow = struct {
    tiles: std.ArrayList(u32) = .empty,
    ranges: std.ArrayList(SparseDepthRange) = .empty,
    dirty: bool = true,

    fn deinit(self: *SparseWindow, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.tiles.deinit(allocator);
    }
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

const ReservedChunk = struct {
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

/// Threading for a batched dense edit, with one tuner per stage. `adaptive` and
/// `items_per_range` pin a fixed partition for benchmark controls.
pub const TerrainEditThreads = struct {
    thread_system: *ThreadSystem,
    plan_tuner: *AdaptiveWorkTuner,
    write_tuner: *AdaptiveWorkTuner,
    adaptive: bool = true,
    items_per_range: ?usize = null,

    fn plan(self: TerrainEditThreads) TerrainEditStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.plan_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }

    fn write(self: TerrainEditThreads) TerrainEditStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.write_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }
};

// One stage of a batched dense edit: the shared thread system and that stage's tuner.
const TerrainEditStageThreads = struct {
    thread_system: *ThreadSystem,
    tuner: *AdaptiveWorkTuner,
    adaptive: bool,
    items_per_range: ?usize,
};

const DenseEditStatus = enum { ok, invalid_layer, invalid_cell, invalid_tile };

// One bit per band of a level over a caller-owned window of words: a group's
// written or claimed bands in `DenseEditScratch.masks`.
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
const edit_scratch_alignment: usize = 64;
const EditFinalsList = std.ArrayListAligned(TileId, .fromByteUnits(edit_scratch_alignment));
const EditTouchedList = std.ArrayListAligned(ChunkBits, .fromByteUnits(edit_scratch_alignment));
const EditOwnedList = std.ArrayListAligned(?OwnedBlock, .fromByteUnits(edit_scratch_alignment));
const EditBandList = std.ArrayListAligned(u32, .fromByteUnits(edit_scratch_alignment));

// Scratch of `applyDenseCellWrites`, kept at its high water.
const DenseEditScratch = struct {
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

    fn deinit(self: *DenseEditScratch, allocator: std.mem.Allocator) void {
        self.groups.deinit(allocator);
        self.masks.deinit(allocator);
        self.finals.deinit(allocator);
        self.touched.deinit(allocator);
        self.owned.deinit(allocator);
        self.written_bands.deinit(allocator);
        self.band_counts.deinit(allocator);
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
    sparse_cells: []const u32,
    sparse_flags: []const TileFlags,
    sparse_level_chunk_tiles: []const std.ArrayList(std.ArrayList(u32)),
    range_count: usize,
};

// Render-path state of the dense window, sized at the GPU sync's plan to the
// window's layer count so the frame's submit allocates nothing. Render-only.
const DenseRenderScratch = struct {
    // The window's layers, topmost first (`collectDenseSubmitLayers`).
    desired: std.ArrayList(u32) = .empty,
    // Resident layers, deepest first, and their render depths (ascending).
    layers: std.ArrayList(u32) = .empty,
    layer_depths: std.ArrayList(i32) = .empty,
    // render_prep's interleave candidates and per-gap flags.
    interleave: std.ArrayList(i32) = .empty,
    gap_filled: std.ArrayList(bool) = .empty,
    buckets: std.ArrayList(WorldSystem.DenseCompositeBucket) = .empty,
    // The interleave depths the last submit cut against.
    submitted_interleave: std.ArrayList(i32) = .empty,

    fn deinit(self: *DenseRenderScratch, allocator: std.mem.Allocator) void {
        self.desired.deinit(allocator);
        self.layers.deinit(allocator);
        self.layer_depths.deinit(allocator);
        self.interleave.deinit(allocator);
        self.gap_filled.deinit(allocator);
        self.buckets.deinit(allocator);
        self.submitted_interleave.deinit(allocator);
    }

    // Room for a resident set of `count` layers in every per-frame list.
    fn reserve(self: *DenseRenderScratch, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!void {
        try self.layers.ensureTotalCapacity(allocator, count);
        try self.layer_depths.ensureTotalCapacity(allocator, count);
        try self.interleave.ensureTotalCapacity(allocator, count);
        try self.gap_filled.ensureTotalCapacity(allocator, count);
        try self.buckets.ensureTotalCapacity(allocator, count);
        try self.submitted_interleave.ensureTotalCapacity(allocator, count);
    }
};

const SparseTileRow = struct {
    level_index: u16,
    cell_index: u32,
    tile_id: TileId,
    depth_value: i32,
    flags: TileFlags,
    // The row's position in its level list (`sparse_level_tiles`) and its chunk list
    // (`sparse_level_chunk_tiles`), so a removal fixes both lists in O(1).
    level_pos: u32,
    chunk_pos: u32,
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
    chunk_geom: ChunkGeometry = .{ .width = 0, .height = 0, .edge = 0, .shift = 0, .chunks_x = 0, .chunks_y = 0 },

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

    // Each row's `store` holds that layer's tiles by chunk.
    dense_layers: std.MultiArrayList(DenseLayerRow) = .{},
    // Chunks given an early block or slot by `reserveDenseCellWrite` in the current
    // reserve scope; the next scope returns the ones no write used to uniform.
    dense_reserved_chunks: std.ArrayList(ReservedChunk) = .empty,
    dense_edit: DenseEditScratch = .{},
    // The batched edit's per-stage tuners and last batches (`applyDenseCellWrites`).
    terrain_edit_plan_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    terrain_edit_write_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    last_terrain_edit_plan_batch: BatchStats = .{},
    last_terrain_edit_write_batch: BatchStats = .{},
    // Telemetry: reserves that grew a dense block or composed-bits pool. Pools grow
    // geometrically at their reserve seams; the first growth logs once.
    terrain_pool_grows: u64 = 0,
    terrain_pool_growth_logged: bool = false,
    // Mirror of the renderer-owned GPU tile store holding the render window's dense
    // layers by chunk; `syncDenseTileStore` uploads what changed. Edits hold no GPU
    // memory: a change on a resident layer sets the layer's `render_changed` and
    // this flag, and the next sync scans that layer's window chunks for blocks
    // marked changed (`BlockFill.changed`). Render-only; never read by simulation.
    gpu_tiles: GpuTileMirror = .{},
    gpu_edits_pending: bool = false,
    // The GPU directory side for the last visibility rect: a power of two covering
    // any chunk window a rect of that size can touch, so a pan keeps the layout.
    render_side: u32 = 0,
    dense_render: DenseRenderScratch = .{},
    // Residency inputs of the last GPU sync; a change re-derives the resident layers.
    gpu_resident_level: u16 = std.math.maxInt(u16),
    gpu_resident_window: DenseLayerRenderWindow = .{},
    gpu_residency_dirty: bool = true,

    sparse_tiles: std.MultiArrayList(SparseTileRow) = .{},

    // Reverse per-level index over `sparse_tiles`: one growable list of indices
    // per level, indexed by level, in no order. Maintained eagerly by
    // `addSparseTile` (the sole inserter, which never changes a tile's level after
    // insertion) and `removeSparseTile` (a swap-remove through the row's stored
    // positions), so this needs no dirty flag or deferred rebuild. That matters
    // because gameplay consumers (nav rebuild after a dig) read it within the same
    // fixed-step tick a tile is placed, well before the next render window update would run; a
    // lazily-rebuilt index keyed off a render dirty flag would be stale for
    // them. A future bulk sparse-tile insert path must maintain this the same
    // way. Lets per-level consumers walk only one level's tiles instead of
    // scanning every sparse tile in the world and filtering by level. Grown lazily up to `level_index + 1`
    // entries the first time a level gets a sparse tile; a level with no
    // sparse tiles yet simply has no entry (the accessor treats that the same
    // as an out-of-range level: an empty slice).
    sparse_level_tiles: std.ArrayList(std.ArrayList(u32)) = .empty,

    // Finer sibling of sparse_level_tiles: outer by level_index, middle by the
    // level-local chunk index (chunkY*chunksX+chunkX, see
    // `localChunkIndexForCell`), inner the sparse_tiles indices in that chunk.
    // Same eager-maintenance contract as sparse_level_tiles (see above).
    sparse_level_chunk_tiles: std.ArrayList(std.ArrayList(std.ArrayList(u32))) = .empty,

    sparse_window: SparseWindow = .{},

    visible_min_tile_x: u16 = 0,
    visible_min_tile_y: u16 = 0,
    visible_max_tile_x_exclusive: u16 = 0,
    visible_max_tile_y_exclusive: u16 = 0,
    // Whether the visible_*/last_* window has been set. Until then nothing renders:
    // the GPU store holds no layer and the sparse window holds no tile. The window
    // changes only when the camera crosses a tile edge, so a still camera or a
    // sub-tile pan leaves it and the sparse window as they are.
    visible_window_set: bool = false,
    // Active level of the last visibility update; sparse tiles draw only on the
    // render window's levels around it.
    visible_active_level: u16 = 0,
    // `render_window` as of the last window update: the levels the sparse list holds.
    visible_render_window: DenseLayerRenderWindow = .{},
    last_min_chunk_x: u16 = 0,
    last_min_chunk_y: u16 = 0,
    last_max_chunk_x: u16 = 0,
    last_max_chunk_y: u16 = 0,

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
    // Last dense static submit anchor and window fingerprint. A change forces a
    // re-submit even without a structural edit. Sentinel forces the first submit.
    submitted_active_level: u16 = std.math.maxInt(u16),
    submitted_window: DenseLayerRenderWindow = .{},
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
        try validateChunkGrid(world.width, world.height, world.chunk_size_tiles);
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
        for (self.sparse_level_tiles.items) |*bucket| bucket.deinit(self.allocator);
        self.sparse_level_tiles.deinit(self.allocator);
        for (self.sparse_level_chunk_tiles.items) |*level_chunks| {
            for (level_chunks.items) |*bucket| bucket.deinit(self.allocator);
            level_chunks.deinit(self.allocator);
        }
        self.sparse_level_chunk_tiles.deinit(self.allocator);

        self.gpu_tiles.deinit(self.allocator);
        self.dense_render.deinit(self.allocator);
        self.dense_reserved_chunks.deinit(self.allocator);
        self.dense_edit.deinit(self.allocator);
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

    /// Dynamic sprite-command budget the world contributes per frame. Dense tiles
    /// render from the retained static buffer and no longer stream through the
    /// dynamic sprite batch, so only the window's sparse tiles count here. Read
    /// after `setVisibleChunksForWorldRect`.
    pub fn reserveRenderRecords(self: *const WorldSystem) usize {
        return self.sparse_window.tiles.items.len;
    }

    /// Upper bound on dense tilemap composite draws submitted this frame: one per
    /// resident layer, the most `partitionDenseCompositeBuckets` can cut. Read after
    /// `syncDenseTileStore`, which sets the resident layers.
    pub fn maxDenseSubmitDrawCount(self: *const WorldSystem) usize {
        return self.dense_render.layers.items.len;
    }

    /// Inclusive tile and chunk bounds of a world rect; see `chunkWindowForWorldRect`.
    const ChunkWindow = struct {
        min_tile_x: u16,
        min_tile_y: u16,
        max_tile_x: u16,
        max_tile_y: u16,
        min_chunk_x: u16,
        min_chunk_y: u16,
        max_chunk_x: u16,
        max_chunk_y: u16,
    };

    /// Tile bounds of `rect` clamped to the world, and chunk bounds widened by
    /// `overscan_chunks` and clamped to the chunk grid. The one chunk-math source
    /// shared by the render visibility window (`setVisibleChunksForWorldRect`)
    /// and the pure simulation scope region (`chunkRegionForWorldRect`), so the
    /// two cannot drift apart. Requires at least one chunk.
    fn chunkWindowForWorldRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16) ChunkWindow {
        std.debug.assert(self.levelCount() > 0);
        const chunks_x = self.chunksX();
        const chunks_y = self.chunksY();
        const tile_size = self.tile_size;
        const min_tile_x = floorTileClamped(rect.x, tile_size, self.width);
        const min_tile_y = floorTileClamped(rect.y, tile_size, self.height);
        const max_tile_x = lastTileClamped(rect.x, rect.w, tile_size, self.width);
        const max_tile_y = lastTileClamped(rect.y, rect.h, tile_size, self.height);
        return .{
            .min_tile_x = min_tile_x,
            .min_tile_y = min_tile_y,
            .max_tile_x = max_tile_x,
            .max_tile_y = max_tile_y,
            .min_chunk_x = saturatingSubU16(min_tile_x / self.chunk_size_tiles, overscan_chunks),
            .min_chunk_y = saturatingSubU16(min_tile_y / self.chunk_size_tiles, overscan_chunks),
            .max_chunk_x = @min(chunks_x - 1, max_tile_x / self.chunk_size_tiles + overscan_chunks),
            .max_chunk_y = @min(chunks_y - 1, max_tile_y / self.chunk_size_tiles + overscan_chunks),
        };
    }

    /// Chunk rectangle covering `rect` plus `overscan_chunks`, clamped to the
    /// world, as an ActiveRegion (level 0). Pure: reads no render visibility
    /// state, so fixed-step simulation scope can derive from a fixed-step view
    /// rect. Returns null when the world has no chunks.
    pub fn chunkRegionForWorldRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16) ?ActiveRegion {
        if (self.levelCount() == 0) return null;
        const window = self.chunkWindowForWorldRect(rect, overscan_chunks);
        std.debug.assert(window.max_chunk_x >= window.min_chunk_x);
        std.debug.assert(window.max_chunk_y >= window.min_chunk_y);
        return .{
            .min = .{ .x = @intCast(window.min_chunk_x), .y = @intCast(window.min_chunk_y) },
            .max_exclusive = .{
                .x = @as(i32, window.max_chunk_x) + 1,
                .y = @as(i32, window.max_chunk_y) + 1,
            },
        };
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
        if (self.levelCount() == 0) return;
        const render_side = self.renderSideForRect(rect, overscan_chunks);
        const window = self.chunkWindowForWorldRect(rect, overscan_chunks);
        if (self.visible_window_set and !self.sparse_window.dirty and active_level == self.visible_active_level and
            windowsEqual(self.render_window, self.visible_render_window) and
            window.min_tile_x == self.visible_min_tile_x and window.min_tile_y == self.visible_min_tile_y and
            window.max_tile_x + 1 == self.visible_max_tile_x_exclusive and window.max_tile_y + 1 == self.visible_max_tile_y_exclusive and
            window.min_chunk_x == self.last_min_chunk_x and window.min_chunk_y == self.last_min_chunk_y and
            window.max_chunk_x == self.last_max_chunk_x and window.max_chunk_y == self.last_max_chunk_y)
        {
            self.render_side = render_side;
            return;
        }

        // Count, reserve, then commit: an allocation failure changes nothing.
        const tile_count = self.walkWindowSparseTiles(window, active_level, null);
        try self.sparse_window.tiles.ensureTotalCapacity(self.allocator, tile_count);
        try self.sparse_window.ranges.ensureTotalCapacity(self.allocator, tile_count);

        self.render_side = render_side;
        self.visible_min_tile_x = window.min_tile_x;
        self.visible_min_tile_y = window.min_tile_y;
        self.visible_max_tile_x_exclusive = window.max_tile_x + 1;
        self.visible_max_tile_y_exclusive = window.max_tile_y + 1;
        self.last_min_chunk_x = window.min_chunk_x;
        self.last_min_chunk_y = window.min_chunk_y;
        self.last_max_chunk_x = window.max_chunk_x;
        self.last_max_chunk_y = window.max_chunk_y;
        self.visible_window_set = true;
        self.visible_active_level = active_level;
        self.visible_render_window = self.render_window;
        self.fillWindowSparseTiles(window, active_level, tile_count);
        self.sparse_window.dirty = false;
    }

    // Counts the sparse tiles on the render window's levels around `active_level`
    // inside the window's tile bounds, appending each to `out` (reserved for them)
    // when given. Walks only the chunks under the tile bounds, never the overscan
    // ring: O(window levels × those chunks + their sparse tiles).
    fn walkWindowSparseTiles(self: *const WorldSystem, window: ChunkWindow, active_level: u16, out: ?*std.ArrayList(u32)) usize {
        const levels = self.renderWindowLevels(active_level) orelse return 0;
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        const chunks_x = self.chunksX();
        const min_cx = window.min_tile_x / self.chunk_size_tiles;
        const max_cx = window.max_tile_x / self.chunk_size_tiles;
        const min_cy = window.min_tile_y / self.chunk_size_tiles;
        const max_cy = window.max_tile_y / self.chunk_size_tiles;
        var count: usize = 0;
        var level = levels.first;
        while (level <= levels.last) : (level += 1) {
            if (!self.render_window.levelInWindow(active_level, @intCast(level), levels.max_level)) continue;
            var cy = min_cy;
            while (cy <= max_cy) : (cy += 1) {
                var cx = min_cx;
                while (cx <= max_cx) : (cx += 1) {
                    const chunk = @as(u32, cy) * @as(u32, chunks_x) + @as(u32, cx);
                    for (self.sparseTileIndicesForChunk(@intCast(level), chunk)) |sparse_index| {
                        if (!self.cellInWindowTiles(sparse_cells[sparse_index], window)) continue;
                        if (out) |tiles| tiles.appendAssumeCapacity(sparse_index);
                        count += 1;
                    }
                }
            }
        }
        return count;
    }

    // Fills the reserved sparse window with the `tile_count` tiles
    // `walkWindowSparseTiles` counted, sorts them by (depth, cell, tile id), and
    // builds one range per distinct depth. Allocation-free; an empty window skips
    // the walk and sort.
    fn fillWindowSparseTiles(self: *WorldSystem, window: ChunkWindow, active_level: u16, tile_count: usize) void {
        const tiles = &self.sparse_window.tiles;
        const ranges = &self.sparse_window.ranges;
        std.debug.assert(tiles.capacity >= tile_count and ranges.capacity >= tile_count);
        tiles.clearRetainingCapacity();
        ranges.clearRetainingCapacity();
        if (tile_count == 0) return;
        const sparse = self.sparse_tiles.slice();
        const order = SparseWindowOrder{
            .depths = sparse.items(.depth_value),
            .cells = sparse.items(.cell_index),
            .tile_ids = sparse.items(.tile_id),
        };
        _ = self.walkWindowSparseTiles(window, active_level, tiles);
        std.debug.assert(tiles.items.len == tile_count);
        std.mem.sort(u32, tiles.items, order, SparseWindowOrder.lessThan);

        var start: usize = 0;
        while (start < tiles.items.len) {
            const depth = order.depths[tiles.items[start]];
            var end = start + 1;
            while (end < tiles.items.len and order.depths[tiles.items[end]] == depth) : (end += 1) {}
            // Window tiles index `sparse_tiles`, whose indices fit u32.
            ranges.appendAssumeCapacity(.{ .depth = depth, .start = @intCast(start), .count = @intCast(end - start) });
            start = end;
        }
    }

    // Draw order of window sparse tiles: depth, then cell, then tile id. Never the
    // tile's index, so removing and moving rows cannot change what draws on top.
    const SparseWindowOrder = struct {
        depths: []const i32,
        cells: []const u32,
        tile_ids: []const TileId,

        fn lessThan(self: SparseWindowOrder, lhs: u32, rhs: u32) bool {
            if (self.depths[lhs] != self.depths[rhs]) return self.depths[lhs] < self.depths[rhs];
            if (self.cells[lhs] != self.cells[rhs]) return self.cells[lhs] < self.cells[rhs];
            return self.tile_ids[lhs] < self.tile_ids[rhs];
        }
    };

    // Whether `cell` is inside the window's tile bounds (the rect's tiles, without
    // the chunk overscan).
    fn cellInWindowTiles(self: *const WorldSystem, cell: u32, window: ChunkWindow) bool {
        const x = cell % self.width;
        const y = cell / self.width;
        return x >= window.min_tile_x and x <= window.max_tile_x and
            y >= window.min_tile_y and y <= window.max_tile_y;
    }

    // A power-of-two side covering every chunk window a rect of this size touches:
    // its chunk span plus one for alignment and the overscan on both sides, clamped
    // to the level's chunk grid. Depends only on the rect size, so a pan keeps it.
    fn renderSideForRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16) u32 {
        const geom = self.chunkGeometry();
        const chunk_px = @as(f32, @floatFromInt(geom.edge)) * self.tile_size;
        const overscan = 1 + 2 * @as(u32, overscan_chunks);
        const span_x = rectChunkSpan(rect.w, chunk_px, geom.chunks_x) + overscan;
        const span_y = rectChunkSpan(rect.h, chunk_px, geom.chunks_y) + overscan;
        const grid_side = std.math.ceilPowerOfTwoAssert(u32, @max(geom.chunks_x, geom.chunks_y));
        const max_side = @min(grid_side, tile_store_max_side);
        return @min(std.math.ceilPowerOfTwo(u32, @max(span_x, span_y)) catch max_side, max_side);
    }

    // The render chunk window as the GPU mirror's half-open window. Requires a set window.
    fn renderChunkWindow(self: *const WorldSystem) world_gpu_tiles.ChunkWindow {
        return .{
            .min_x = self.last_min_chunk_x,
            .min_y = self.last_min_chunk_y,
            .max_x = @as(u32, self.last_max_chunk_x) + 1,
            .max_y = @as(u32, self.last_max_chunk_y) + 1,
        };
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

    /// The render depth an actor standing on `active_level` draws at. Always
    /// treated as an interleave point so the common case (no other sandwiched
    /// content) still splits off a `ceiling_when_underground` plane exactly like
    /// before this frame's dense stack was collapsed to composite draws.
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
    ) !void {
        const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
        if (!self.dense_quads_dirty and
            active_level == self.submitted_active_level and
            windowsEqual(self.render_window, self.submitted_window) and
            std.mem.eql(i32, self.dense_render.submitted_interleave.items, interleave_depths))
            return;

        // The tilemap atlas params are baked from the world atlas dimensions at init;
        // the bound runtime texture must match. Safe-build only, and only on a
        // re-submit, not still frames.
        if (std.debug.runtime_safety) {
            if (renderer.textureDesc(prepared.texture)) |desc| {
                std.debug.assert(desc.width == self.atlas_texture.width and desc.height == self.atlas_texture.height);
            }
        }

        const layers = self.dense_render.layers.items;
        try self.dense_render.buckets.resize(self.allocator, layers.len);
        try self.dense_render.submitted_interleave.ensureTotalCapacity(self.allocator, interleave_depths.len);
        renderer.beginStaticGeometry();

        if (layers.len > 0) {
            const buckets = self.dense_render.buckets.items;
            const bucket_count = self.partitionDenseCompositeBuckets(layers, interleave_depths, buckets);

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
                var window_layers = self.buildWindowLayers(bucket.start, bucket.end);
                // True only for the bucket holding the overall shallowest resident
                // layer (the last bucket, since `layers` is depth-ascending): the
                // fragment shader's rim shadow gates on this, not on its own
                // draw-local `resolved_depth == 0`, since a bucket split for an
                // unrelated interleave point can put a merely hole-revealed tile at
                // `resolved_depth == 0` within its own draw.
                window_layers.is_shallowest_bucket = bucket.end == layers.len;
                // Order = the bucket's own shallowest layer (the last in its range).
                const order = self.denseLayerOrder(layers[bucket.end - 1]);
                try renderer.appendStaticTilemapSpan(
                    prepared.texture,
                    order,
                    .{ .positions = &pos, .uvs = &uv, .colors = &col },
                    self.gpu_tiles.store,
                    window_layers,
                );
            }
        }

        self.dense_quads_dirty = false;
        self.submitted_active_level = active_level;
        self.submitted_window = self.render_window;
        self.dense_render.submitted_interleave.clearRetainingCapacity();
        self.dense_render.submitted_interleave.appendSliceAssumeCapacity(interleave_depths);
    }

    /// Cuts `layers` (depth-ascending, deepest first) into composite-draw buckets:
    /// a new bucket boundary is placed at every point where an `interleave_depths`
    /// value falls strictly between two consecutive layers' depths (or exactly at
    /// the shallower one, since nothing may draw between that pair once composited
    /// together). `interleave_depths` must be sorted ascending and deduplicated
    /// (asserted). Writes bucket ranges into `out` (at least `layers.len` long) and
    /// returns the count; every cut consumes at least one layer, so the count never
    /// exceeds `layers.len`.
    fn partitionDenseCompositeBuckets(
        self: *const WorldSystem,
        layers: []const u32,
        interleave_depths: []const i32,
        out: []DenseCompositeBucket,
    ) usize {
        if (layers.len == 0) return 0;
        std.debug.assert(out.len >= layers.len);
        if (std.debug.runtime_safety and interleave_depths.len > 1) {
            for (1..interleave_depths.len) |i| {
                std.debug.assert(interleave_depths[i] > interleave_depths[i - 1]);
            }
        }
        var bucket_count: usize = 0;
        var bucket_start: usize = 0;
        var interleave_index: usize = 0;
        for (1..layers.len + 1) |index| {
            var cut = index == layers.len;
            if (!cut) {
                const prev_depth = self.denseLayerOrder(layers[index - 1]).depth;
                const next_depth = self.denseLayerOrder(layers[index]).depth;
                while (interleave_index < interleave_depths.len and interleave_depths[interleave_index] <= prev_depth) {
                    interleave_index += 1;
                }
                if (interleave_index < interleave_depths.len and interleave_depths[interleave_index] <= next_depth) {
                    cut = true;
                }
            }
            if (cut) {
                out[bucket_count] = .{ .start = bucket_start, .end = index };
                bucket_count += 1;
                bucket_start = index;
            }
        }
        return bucket_count;
    }

    /// The chain of one bucket of resident layers (`dense_render.layers[start..end]`,
    /// deepest first): its topmost layer's directory and the layer count. The
    /// resident layers chain topmost-first, so the walk visits exactly the bucket.
    fn buildWindowLayers(self: *const WorldSystem, bucket_start: usize, bucket_end: usize) Renderer.TilemapWindowLayers {
        std.debug.assert(bucket_start < bucket_end);
        const topmost = self.dense_render.layers.items[bucket_end - 1];
        const slot = self.dense_layers.items(.gpu_slot)[topmost];
        return .{
            .first_directory = self.gpu_tiles.slotDirectory(slot),
            .count = @intCast(bucket_end - bucket_start),
        };
    }

    const RenderWindowLevels = struct { first: u32, last: u32, max_level: u16 };

    // The level range `render_window` can hold around `active_level`; callers still
    // filter each level with `levelInWindow`. Null for a world with no levels.
    fn renderWindowLevels(self: *const WorldSystem, active_level: u16) ?RenderWindowLevels {
        if (self.levelCount() == 0) return null;
        const max_level = self.maxLevelIndex();
        return .{
            .first = if (self.render_window.ceiling_when_underground and active_level > 0) active_level - 1 else active_level,
            .last = @min(@as(u32, active_level) + self.render_window.levels_below, @as(u32, max_level)),
            .max_level = max_level,
        };
    }

    /// The dense layers of the render window's levels around `active_level`, topmost
    /// first (back-to-front reversed), in `dense_render.desired`. Visits only the
    /// window's levels through their band lists: O(window layers log window layers).
    fn collectDenseSubmitLayers(self: *WorldSystem, active_level: u16) error{OutOfMemory}![]const u32 {
        const desired = &self.dense_render.desired;
        desired.clearRetainingCapacity();
        const levels = self.renderWindowLevels(active_level) orelse return desired.items;
        var count: usize = 0;
        var level = levels.first;
        while (level <= levels.last) : (level += 1) {
            if (!self.render_window.levelInWindow(active_level, @intCast(level), levels.max_level)) continue;
            count += self.level_terrain.items[level].bandLayers().len;
        }
        try desired.ensureTotalCapacity(self.allocator, count);
        level = levels.first;
        while (level <= levels.last) : (level += 1) {
            if (!self.render_window.levelInWindow(active_level, @intCast(level), levels.max_level)) continue;
            desired.appendSliceAssumeCapacity(self.level_terrain.items[level].bandLayers());
        }
        std.mem.sort(u32, desired.items, self, denseLayerIndexLessThan);
        std.mem.reverse(u32, desired.items);
        return desired.items;
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
    /// set moves; never depends on chunks or levels outside the window. An error
    /// leaves residency and change marks for a retry. Claims the
    /// store for this frame; the renderer retires it the first frame this is not
    /// called, and the next call re-uploads the window into a new store.
    pub fn syncDenseTileStore(self: *WorldSystem, renderer: *Renderer, active_level: u16) !void {
        const mirror = &self.gpu_tiles;
        if (mirror.store.isValid() and !renderer.claimTileStore(mirror.store)) self.resetGpuResidency();
        if (self.levelCount() == 0 or !self.visible_window_set) return;
        const sync_plan = try self.planDenseGpuSync(active_level);
        const old_store = mirror.store;
        if (sync_plan.span_count > 0 and (!old_store.isValid() or mirror.store_side != sync_plan.side)) {
            var params = self.tilemap_params;
            params.layer_meta[2] = self.chunkGeometry().shift;
            params.layer_meta[3] = @intCast(sync_plan.side);
            params.window = sync_plan.window.uniform();
            // Held from creation: a retry after a failed reserve reuses this empty
            // store instead of creating another. It holds no resident layer yet, and
            // the retry's plan still enters every window layer.
            mirror.store = try renderer.createTileStore(.{ .element_capacity = @max(1, sync_plan.required_elements), .params = params });
            mirror.store_side = sync_plan.side;
        }
        if (sync_plan.span_count > 0) {
            try renderer.reserveTileStoreUploads(mirror.store, sync_plan.required_elements, sync_plan.span_count, sync_plan.value_count);
        }
        self.commitDenseGpuSync(&sync_plan, active_level);
        if (sync_plan.relayout and sync_plan.span_count == 0) {
            // A new layout with nothing resident leaves the old store unclaimed.
            mirror.store = .invalid;
            mirror.store_side = 0;
        }
        if (sync_plan.layers_changed or !std.meta.eql(old_store, mirror.store)) self.dense_quads_dirty = true;
        if (sync_plan.span_count > 0) try renderer.queueTileStoreUploads(mirror.store, mirror.spans.items, mirror.values.items);
        if (sync_plan.residency_changed and mirror.store.isValid()) renderer.setTileStoreWindow(mirror.store, mirror.window.uniform());
        if (!mirror.resident_bytes_reported and mirror.store.isValid()) {
            mirror.resident_bytes_reported = true;
            if (comptime logging.enabled(.info)) log.info("GPU tile store: {d} resident layers over {d} window chunks, {d} resident bytes", .{
                mirror.residentLayerCount(),
                mirror.window.count(),
                mirror.residentBytes(),
            });
        }
    }

    // The renderer retired the store: nothing is resident any more, so the next
    // sync lays the window out anew and the draws re-submit. O(resident layers).
    fn resetGpuResidency(self: *WorldSystem) void {
        self.gpu_tiles.reset(self.dense_layers.items(.gpu_slot), self.dense_layers.items(.render_changed));
        self.gpu_edits_pending = false;
        self.dense_render.layers.clearRetainingCapacity();
        self.dense_render.layer_depths.clearRetainingCapacity();
        self.gpu_residency_dirty = true;
        self.dense_quads_dirty = true;
    }

    // Sizes this frame's GPU tile sync and reserves its growth, the frame's dense
    // render scratch included; re-derives the resident set only when the layer set,
    // active level, level window, chunk window, or directory side changed. Requires
    // a set render window.
    fn planDenseGpuSync(self: *WorldSystem, active_level: u16) !world_gpu_tiles.SyncPlan {
        std.debug.assert(self.visible_window_set);
        const geom = self.chunkGeometry();
        const visible = self.renderChunkWindow();
        const fitted = world_gpu_tiles.fitWindow(self.render_side, visible);
        const window = fitted.window;
        if (!window.eql(visible) and !self.gpu_tiles.window_clip_reported) {
            @branchHint(.cold);
            self.gpu_tiles.window_clip_reported = true;
            log.warn("render chunk window clipped to {d}x{d} chunks; store width", .{ window.width(), window.height() });
        }
        const rederive = self.gpu_residency_dirty or
            active_level != self.gpu_resident_level or
            !windowsEqual(self.render_window, self.gpu_resident_window) or
            !window.eql(self.gpu_tiles.window) or
            fitted.side != self.gpu_tiles.side or
            !self.gpu_tiles.layoutMatchesStore();
        const rows = self.dense_layers.slice();
        const layer_changed: ?[]const bool = if (self.gpu_edits_pending) rows.items(.render_changed) else null;
        if (!rederive) {
            return self.gpu_tiles.plan(self.allocator, geom, rows.items(.store), rows.items(.gpu_slot), layer_changed, null);
        }
        const desired = try self.collectDenseSubmitLayers(active_level);
        try self.dense_render.reserve(self.allocator, desired.len);
        const fit = world_gpu_tiles.residentLayerFit(fitted.side, tileStoreBlockElements(geom.edge));
        return self.gpu_tiles.plan(self.allocator, geom, rows.items(.store), rows.items(.gpu_slot), layer_changed, .{
            .layers = fitResidentLayers(desired, fit, &self.gpu_tiles.width_drop_reported),
            .window = window,
            .side = fitted.side,
        });
    }

    // The window layers (topmost first) the store width holds: the first `fit`, so
    // the deepest drop. Reports a drop once per world through `reported`.
    fn fitResidentLayers(desired: []const u32, fit: usize, reported: *bool) []const u32 {
        const resident = desired[0..@min(desired.len, fit)];
        if (resident.len < desired.len and !reported.*) {
            @branchHint(.cold);
            reported.* = true;
            log.warn("{d} deepest window layers not drawn; store width", .{desired.len - resident.len});
        }
        return resident;
    }

    // Applies the sync and, when the resident set moved, rebuilds the resident
    // layers (deepest first) and their depths from the chain. O(resident layers).
    fn commitDenseGpuSync(self: *WorldSystem, sync_plan: *const world_gpu_tiles.SyncPlan, active_level: u16) void {
        const rows = self.dense_layers.slice();
        self.gpu_tiles.commit(sync_plan, self.chunkGeometry(), rows.items(.store), rows.items(.gpu_slot), rows.items(.render_changed));
        // The commit cleared every resident layer's flag; non-resident ones are never set.
        if (sync_plan.edits) self.gpu_edits_pending = false;
        self.gpu_resident_level = active_level;
        self.gpu_resident_window = self.render_window;
        self.gpu_residency_dirty = false;
        if (!sync_plan.residency_changed) return;
        const order = self.gpu_tiles.order.items;
        const layers = &self.dense_render.layers;
        const depths = &self.dense_render.layer_depths;
        std.debug.assert(layers.capacity >= order.len and depths.capacity >= order.len);
        layers.clearRetainingCapacity();
        depths.clearRetainingCapacity();
        var index = order.len;
        while (index > 0) {
            index -= 1;
            const layer = self.gpu_tiles.slot_layer.items[order[index]];
            layers.appendAssumeCapacity(layer);
            depths.appendAssumeCapacity(self.denseLayerOrder(layer).depth);
        }
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
    ) !void {
        const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
        const range = self.sparse_window.ranges.items[range_index];
        const sparse = self.sparse_tiles.slice();
        const sparse_cells = sparse.items(.cell_index);
        const sparse_tile_ids = sparse.items(.tile_id);
        for (self.sparse_window.tiles.items[range.start..][0..range.count]) |index| {
            const cell = sparse_cells[index];
            const x: u16 = @intCast(cell % self.width);
            const y: u16 = @intCast(cell / self.width);
            try self.submitTile(renderer, prepared, sparse_tile_ids[index], x, y, RenderOrder.world(range.depth));
        }
    }

    /// CPU-only sparse submission for benchmarks and headless parity checks. Mirrors
    /// `submitVisibleSparseRange` but writes ordered sprites into `batch` instead of
    /// a live `Renderer`. Returns the sprites written.
    pub fn submitVisibleSparseSprites(
        self: *const WorldSystem,
        batch: *sprite_batch.SpriteBatch,
        texture: TextureId,
        range_index: usize,
    ) !usize {
        const range = self.sparse_window.ranges.items[range_index];
        const sparse = self.sparse_tiles.slice();
        const sparse_cells = sparse.items(.cell_index);
        const sparse_tile_ids = sparse.items(.tile_id);
        for (self.sparse_window.tiles.items[range.start..][0..range.count]) |index| {
            const cell = sparse_cells[index];
            const x: u16 = @intCast(cell % self.width);
            const y: u16 = @intCast(cell / self.width);
            const source = self.sourceRect(sparse_tile_ids[index]) orelse return error.MissingTileSourceRect;
            try batch.drawSprite(.{
                .texture = texture,
                .source = source,
                .dest = .{
                    .x = @as(f32, @floatFromInt(x)) * self.tile_size,
                    .y = @as(f32, @floatFromInt(y)) * self.tile_size,
                    .w = self.tile_size,
                    .h = self.tile_size,
                },
                .order = RenderOrder.world(range.depth),
            });
        }
        return range.count;
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

    /// Writes one dense cell. Reserves its growth first, so an OOM changes nothing;
    /// after `reserveDenseCellWrite` for this cell it allocates nothing. O(1) plus a
    /// one-time O(edge²) block materialize, plus O(bands + sparse tiles in the chunk)
    /// to recompose the cell's movement-blocked bit.
    pub fn setDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) !?WorldTileChangedEvent {
        try self.validateTileId(tile_id);
        return self.writeDenseTileCell(layer_index, x, y, tile_id);
    }

    /// Clears a dense floor cell to the empty/see-through state (`invalid_tile_id`):
    /// the tilemap shader discards it, revealing the layer drawn below, and
    /// `flagsFor` treats it as non-blocking. This is how a dig punches a hole
    /// through one plane to expose the level beneath. Same costs as `setDenseTile`.
    pub fn clearDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16) !?WorldTileChangedEvent {
        return self.writeDenseTileCell(layer_index, x, y, invalid_tile_id);
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
    /// Reads are unchanged. O(bands + sparse tiles in the chunk), plus a one-time
    /// O(edge²) block and pool growth.
    pub fn reserveDenseCellWrite(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) !void {
        if (layer_index >= self.dense_layers.len) return error.InvalidWorldLayer;
        if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
        const geom = self.chunkGeometry();
        const chunk = geom.chunkOf(x, y);
        const local = geom.localOf(x, y);
        const store = &self.dense_layers.items(.store)[layer_index];
        if (store.tile(geom, x, y) == tile_id) return;
        const level = self.denseLayerLevel(layer_index);
        const blocked = &self.level_terrain.items[level].blocked;
        const needs_block = store.writeNeedsBlock(chunk, tile_id);
        const needs_slot = blocked.setNeedsSlot(chunk, local, self.composedBlockedWith(level, x, y, layer_index, tile_id));

        // Fallible growth first; the commits below only take what it guaranteed.
        try self.dense_reserved_chunks.ensureUnusedCapacity(self.allocator, @as(usize, @intFromBool(needs_block)) + @intFromBool(needs_slot));
        if (needs_block) try self.ensureDenseBlocks(store, geom.blockCells(), 1);
        if (needs_slot) try self.ensureBlockedSlots(blocked, 1);
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
    /// (`invalid_tile_id`) write is allowed here. Every growth (tile block, bits
    /// slot) is ensured before the first mutation, so an OOM leaves the world
    /// unchanged and retryable; the GPU side allocates nothing.
    fn writeDenseTileCell(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) !?WorldTileChangedEvent {
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
        const new_composed = self.composedBlockedWith(level, x, y, layer_index, tile_id);
        if (store.writeNeedsBlock(chunk, tile_id)) try self.ensureDenseBlocks(store, geom.blockCells(), 1);
        if (blocked.setNeedsSlot(chunk, local, new_composed)) try self.ensureBlockedSlots(blocked, 1);

        store.write(geom, chunk, local, tile_id);
        blocked.set(geom, chunk, local, new_composed);
        // A layer outside the render window flags nothing: it uploads whole when it
        // enters.
        self.markRenderChanged(self.dense_layers.items(.gpu_slot), self.dense_layers.items(.render_changed), layer_index);
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
    ) !void {
        self.last_terrain_edit_plan_batch = .{};
        self.last_terrain_edit_write_batch = .{};
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
        try scratch.groups.ensureTotalCapacity(self.allocator, chunks.len);
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
        const mask_words = @max(1, (band_stride + 63) / 64);
        const finals_stride = band_stride * max_chunk_cells;
        const touched_stride = std.mem.alignForward(usize, band_stride * @sizeOf(ChunkBits), edit_scratch_alignment) / @sizeOf(ChunkBits);
        const owned_stride = std.mem.alignForward(usize, band_stride, edit_scratch_alignment / std.math.gcd(@sizeOf(?OwnedBlock), edit_scratch_alignment));
        const written_bands_stride = std.mem.alignForward(usize, band_stride, edit_scratch_alignment / @sizeOf(u32));
        comptime std.debug.assert(max_chunk_cells * @sizeOf(TileId) % edit_scratch_alignment == 0);
        try scratch.masks.ensureTotalCapacity(self.allocator, groups.len * 2 * mask_words);
        try scratch.finals.ensureTotalCapacity(self.allocator, participant_count * finals_stride);
        try scratch.touched.ensureTotalCapacity(self.allocator, participant_count * touched_stride);
        try scratch.owned.ensureTotalCapacity(self.allocator, participant_count * owned_stride);
        try scratch.written_bands.ensureTotalCapacity(self.allocator, participant_count * written_bands_stride);
        try scratch.band_counts.ensureTotalCapacity(self.allocator, band_stride);
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
        if (stage_threads) |stage| {
            self.last_terrain_edit_plan_batch = dispatchTerrainEditStage(stage.plan(), groups.len, &plan_job, denseEditPlanJob);
        } else {
            self.last_terrain_edit_plan_batch = .{ .item_count = groups.len, .ran_inline = true };
            for (0..groups.len) |group_index| planDenseEditGroup(&plan_job, group_index);
        }

        // The first invalid write in group order fails the batch before any growth.
        for (groups) |group| switch (group.plan.status) {
            .ok => {},
            .invalid_layer => return error.InvalidWorldLayer,
            .invalid_cell => return error.InvalidWorldCell,
            .invalid_tile => return error.InvalidWorldTile,
        };

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
                    try self.ensureDenseBlocks(&stores[terrain.bands.items[band]], block_cells, band_counts[band]);
                    band_counts[band] = 0;
                }
            }
            try self.ensureBlockedSlots(&terrain.blocked, slot_count);
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
            .sparse_cells = self.sparse_tiles.items(.cell_index),
            .sparse_flags = self.sparse_tiles.items(.flags),
            .sparse_level_chunk_tiles = self.sparse_level_chunk_tiles.items,
            .range_count = 1,
        };
        if (stage_threads) |stage| {
            self.last_terrain_edit_write_batch = dispatchTerrainEditStage(stage.write(), groups.len, &write_job, denseEditWriteJob);
        } else {
            self.last_terrain_edit_write_batch = .{ .item_count = groups.len, .ran_inline = true };
            for (0..groups.len) |group_index| writeDenseEditGroup(&write_job, group_index, 0);
        }

        // Ordered merge: compact the event windows in group order (each window starts
        // at or after the merged length), flag the resident written layers of each
        // group that changed a cell, then return chunks left uniform to the pools.
        const gpu_slots = rows.items(.gpu_slot);
        const render_changed = rows.items(.render_changed);
        var merged: usize = 0;
        for (groups, 0..) |group, group_index| {
            const window = event_windows[group.start..][0..group.change_count];
            if (merged != group.start) std.mem.copyForwards(WorldTileChangedEvent, event_windows[merged..][0..window.len], window);
            merged += window.len;
            if (group.change_count == 0) continue;
            const written = groupBandBits(masks, mask_words, group_index, false);
            var cursor: u32 = 0;
            while (written.next(cursor)) |band| : (cursor = band + 1) self.markRenderChanged(gpu_slots, render_changed, levels[group.level].bands.items[band]);
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

    // Flags resident `layer_index` (columns `gpu_slots`, `render_changed`) for the
    // next GPU sync after one of its cells changed; a layer outside the render window
    // uploads whole when it enters. O(1).
    fn markRenderChanged(self: *WorldSystem, gpu_slots: []const u32, render_changed: []bool, layer_index: usize) void {
        if (gpu_slots[layer_index] == world_gpu_tiles.no_slot) return;
        render_changed[layer_index] = true;
        self.gpu_edits_pending = true;
    }

    // The terrain pools' reserve seams: each counts a reserve that grew its pool.
    fn ensureDenseBlocks(self: *WorldSystem, store: *DenseLayerStore, block_cells: usize, count: usize) error{OutOfMemory}!void {
        if (try store.ensureAvailable(self.allocator, block_cells, count)) self.countTerrainPoolGrowth();
    }

    fn ensureBlockedSlots(self: *WorldSystem, blocked: *ChunkBitsStore, count: usize) error{OutOfMemory}!void {
        if (try blocked.ensureAvailable(self.allocator, count)) self.countTerrainPoolGrowth();
    }

    fn countTerrainPoolGrowth(self: *WorldSystem) void {
        @branchHint(.cold);
        self.terrain_pool_grows += 1;
        if (self.terrain_pool_growth_logged) return;
        self.terrain_pool_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test) log.info(
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
        return self.sparseBlocksCell(level, geom.chunkOf(x, y), self.cellIndex(x, y));
    }

    fn sparseBlocksCell(self: *const WorldSystem, level: u16, chunk: u32, cell: u32) bool {
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        const sparse_flags = self.sparse_tiles.items(.flags);
        for (self.sparseTileIndicesForChunk(level, chunk)) |sparse_index| {
            if (sparse_cells[sparse_index] == cell and sparse_flags[sparse_index].blocks_movement) return true;
        }
        return false;
    }

    pub fn denseLayerCount(self: *const WorldSystem) usize {
        return self.dense_layers.len;
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

    /// Tile-cell coordinate of a sparse tile, decoded from its stored cell index. A
    /// sparse index is valid only until the next sparse tile removal.
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
    /// The slice and its indices are valid only until the next sparse tile add or
    /// removal.
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
    /// worth of sparse tiles. The slice and its indices are valid only until the
    /// next sparse tile add or removal.
    pub fn sparseTileIndicesForChunk(self: *const WorldSystem, level_index: u16, chunk_index: u32) []const u32 {
        return chunkSparseTiles(self.sparse_level_chunk_tiles.items, level_index, chunk_index);
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
    /// the level has none. O(bands on the level).
    pub fn denseFloorLayerForLevel(self: *const WorldSystem, level_index: u16) ?usize {
        if (@as(usize, level_index) >= self.level_terrain.items.len) return null;
        const dense_depth_bands = self.dense_layers.items(.depth_band);
        for (self.level_terrain.items[level_index].bandLayers()) |layer_index| {
            if (dense_depth_bands[layer_index] == .floor) return layer_index;
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

    /// Per-level composed navigability: whether any dense band on the level or any
    /// sparse obstacle on it blocks the cell. Out-of-range x/y returns blocked,
    /// matching denseTileBlocksMovement; an invalid level also returns blocked
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

    /// Reserves everything `addLevelLink(link)` needs without committing it: the
    /// link row and its two endpoint entries (each level holds its chunk heads from
    /// create). Validates the link first. O(1) amortized. Call before a world mutate
    /// that must pair with `addLevelLink`.
    pub fn reserveLevelLink(self: *WorldSystem, link: LevelLink) error{ InvalidWorldLevel, InvalidWorldCell, LevelLinkIndexOverflow, OutOfMemory }!void {
        try self.validateLevelLink(link);
        // Two endpoint entries per link must stay below the u32 list sentinel.
        if (self.level_links.items.len >= no_link_endpoint / 2) return error.LevelLinkIndexOverflow;
        try self.level_links.ensureUnusedCapacity(self.allocator, 1);
        try self.link_endpoint_next.ensureUnusedCapacity(self.allocator, 2);
    }

    /// Appends a persistent inter-level link and indexes both endpoints by chunk.
    /// Allocation-free after `reserveLevelLink(link)`; otherwise it reserves first, so
    /// an OOM adds nothing. O(1) after the reserve.
    pub fn addLevelLink(self: *WorldSystem, link: LevelLink) error{ InvalidWorldLevel, InvalidWorldCell, LevelLinkIndexOverflow, OutOfMemory }!void {
        try self.reserveLevelLink(link);
        const geom = self.chunkGeometry();
        const endpoint_a: u32 = @intCast(self.level_links.items.len * 2);
        self.level_links.appendAssumeCapacity(link);
        const heads_a = self.level_terrain.items[link.level_a].link_heads;
        const chunk_a = geom.chunkOf(link.cell_a.x, link.cell_a.y);
        self.link_endpoint_next.appendAssumeCapacity(heads_a[chunk_a]);
        heads_a[chunk_a] = endpoint_a;
        const heads_b = self.level_terrain.items[link.level_b].link_heads;
        const chunk_b = geom.chunkOf(link.cell_b.x, link.cell_b.y);
        self.link_endpoint_next.appendAssumeCapacity(heads_b[chunk_b]);
        heads_b[chunk_b] = endpoint_a + 1;
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

    /// A sparse index is valid only until the next sparse tile removal.
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
        if (!self.visible_window_set or self.levelCount() == 0) return null;
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

    /// Adds an empty level (no bands, every chunk open, no link endpoints). Touches
    /// only its own directories: O(chunks per level), whatever the depth.
    pub fn addLevel(self: *WorldSystem, base_z: i32) !u16 {
        return self.appendLevelBaseZ(base_z);
    }

    // Every level of a world, whether built, literal-constructed, or added in play,
    // enters here, so the loud index-width checks run before anything is sized
    // from them. All growth precedes the commit, so an OOM adds no level.
    fn appendLevelBaseZ(self: *WorldSystem, base_z: i32) !u16 {
        try validateChunkGrid(self.width, self.height, self.chunk_size_tiles);
        const index = self.level_base_z.items.len;
        if (index > std.math.maxInt(u16)) return error.WorldLevelOverflow;
        const geom = ChunkGeometry.init(self.width, self.height, self.chunk_size_tiles);
        std.debug.assert(index == 0 or std.meta.eql(self.chunk_geom, geom));
        self.chunk_geom = geom;
        try self.level_base_z.ensureUnusedCapacity(self.allocator, 1);
        try self.level_terrain.ensureUnusedCapacity(self.allocator, 1);
        const terrain = try LevelTerrain.init(self.allocator, self.chunkCountPerLevel());
        self.level_terrain.appendAssumeCapacity(terrain);
        self.level_base_z.appendAssumeCapacity(base_z);
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
    pub fn addDenseLayer(self: *WorldSystem, level_index: u16, base_z: i32, depth: WorldDepth, fill_tile: TileId) !usize {
        try self.validateLevelIndex(level_index);
        try self.validateTileId(fill_tile);

        const terrain = &self.level_terrain.items[level_index];
        const layer_index = self.dense_layers.len;
        if (layer_index > std.math.maxInt(u32)) return error.WorldLayerOverflow;
        try self.dense_layers.ensureUnusedCapacity(self.allocator, 1);
        try terrain.bands.ensureUnusedCapacity(self.allocator, 1);
        var store = try DenseLayerStore.init(self.allocator, self.chunkCountPerLevel(), fill_tile);
        errdefer store.deinit(self.allocator);

        // Commit: band list, layer row, and composed bits are all infallible from here.
        self.dense_layers.appendAssumeCapacity(.{
            .level_index = level_index,
            // At most one band per dense layer, and layer indices fit u32 (checked above).
            .band = @intCast(terrain.bands.items.len),
            .base_z = base_z,
            .depth_band = depth,
            .store = store,
            .gpu_slot = world_gpu_tiles.no_slot,
            .render_changed = false,
        });
        terrain.bands.appendAssumeCapacity(@intCast(layer_index));
        if (self.flagsFor(fill_tile).blocks_movement) {
            for (0..terrain.blocked.dir.len) |chunk| terrain.blocked.setChunk(@intCast(chunk), true);
            terrain.content_revision +%= 1;
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
        const local_chunk_index = self.localChunkIndexForCell(x, y);
        const flags = self.flagsFor(tile_id);
        const world_z = self.worldZForLevel(level_index, base_z, depth);

        // Reserve capacity in sparse_tiles, sparse_level_tiles,
        // sparse_level_chunk_tiles, and the level's composed bits before
        // committing to any of them: an OOM partway through would otherwise leave
        // a tile in one structure but invisible to the lookups the others back
        // (nav rebuild, levelBlocksMovement and the LOS that reads it). Either
        // every reservation succeeds and the commits below are then infallible,
        // or the call fails here with none of the structures changed.
        const geom = self.chunkGeometry();
        const local_cell = geom.localOf(x, y);
        const blocked = &self.level_terrain.items[level_index].blocked;
        try self.sparse_tiles.ensureTotalCapacity(self.allocator, self.sparse_tiles.len + 1);
        try self.reserveSparseLevelIndexEntry(level_index);
        try self.reserveSparseChunkIndexEntry(level_index, local_chunk_index);
        if (flags.blocks_movement and blocked.setNeedsSlot(local_chunk_index, local_cell, true)) {
            try self.ensureBlockedSlots(blocked, 1);
        }

        const new_index: u32 = @intCast(self.sparse_tiles.len);
        // Each list holds at most every row, so its positions fit u32 like the index.
        const level_pos: u32 = @intCast(self.sparse_level_tiles.items[level_index].items.len);
        const chunk_pos: u32 = @intCast(self.sparse_level_chunk_tiles.items[level_index].items[local_chunk_index].items.len);
        self.sparse_tiles.appendAssumeCapacity(.{
            .level_index = level_index,
            .cell_index = cell,
            .tile_id = tile_id,
            .depth_value = world_z,
            .flags = flags,
            .level_pos = level_pos,
            .chunk_pos = chunk_pos,
        });
        self.commitSparseLevelIndexEntry(level_index, new_index);
        self.commitSparseChunkIndexEntry(level_index, local_chunk_index, new_index);
        if (flags.blocks_movement) blocked.set(geom, local_chunk_index, local_cell, true);
        // Only a tile the current window draws rebuilds its sparse list.
        if (self.sparseTileInWindow(level_index, x, y)) self.sparse_window.dirty = true;
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
    pub fn reserveClearCellBlocking(self: *WorldSystem, level_index: u16, x: u16, y: u16, floor_tile: TileId) !void {
        try self.validateLevelIndex(level_index);
        if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
        try self.validateTileId(floor_tile);
        // A blocking floor tile would leave the cell blocked.
        if (self.flagsFor(floor_tile).blocks_movement) return error.InvalidWorldTile;
        if (!self.cellComposedBlocked(level_index, x, y)) return;

        const geom = self.chunkGeometry();
        const chunk = geom.chunkOf(x, y);
        const stores = self.dense_layers.items(.store);
        const floor_layer = self.denseFloorLayerForLevel(level_index);
        const terrain = &self.level_terrain.items[level_index];
        var block_count: usize = 0;
        for (terrain.bandLayers()) |layer| {
            if (!self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) continue;
            block_count += @intFromBool(stores[layer].writeNeedsBlock(chunk, clearedBandTile(layer, floor_layer, floor_tile)));
        }
        const needs_slot = terrain.blocked.setNeedsSlot(chunk, geom.localOf(x, y), false);

        // Fallible growth first; each materialized chunk is recorded for the scope.
        try self.dense_reserved_chunks.ensureUnusedCapacity(self.allocator, block_count + @intFromBool(needs_slot));
        for (terrain.bandLayers()) |layer| {
            if (!self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) continue;
            if (!stores[layer].writeNeedsBlock(chunk, clearedBandTile(layer, floor_layer, floor_tile))) continue;
            try self.ensureDenseBlocks(&stores[layer], geom.blockCells(), 1);
            stores[layer].materializeChunk(geom.blockCells(), chunk);
            self.dense_reserved_chunks.appendAssumeCapacity(.{ .kind = .dense_block, .owner = layer, .chunk = chunk });
        }
        if (needs_slot) {
            try self.ensureBlockedSlots(&terrain.blocked, 1);
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
    pub fn clearCellBlocking(self: *WorldSystem, level_index: u16, x: u16, y: u16, floor_tile: TileId) !?WorldObstacleChangedEvent {
        try self.reserveClearCellBlocking(level_index, x, y, floor_tile);
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
            self.markRenderChanged(gpu_slots, render_changed, layer);
            changed = true;
        }

        // Backwards, so each swap-remove moves into the visited position only an
        // entry already visited.
        const cell = self.cellIndex(x, y);
        const sparse_cells = self.sparse_tiles.items(.cell_index);
        const sparse_flags = self.sparse_tiles.items(.flags);
        var position = self.sparseTileIndicesForChunk(level_index, chunk).len;
        while (position > 0) {
            position -= 1;
            const sparse_index = self.sparseTileIndicesForChunk(level_index, chunk)[position];
            if (sparse_cells[sparse_index] != cell or !sparse_flags[sparse_index].blocks_movement) continue;
            self.removeSparseTile(sparse_index);
            changed = true;
        }
        if (!changed) return null;

        const composed = self.cellComposedBlocked(level_index, x, y);
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

    // Removes sparse row `index` from its level list, its chunk list, and the rows,
    // each by swap-remove: the entry moved into a freed list position, and the last
    // row's two entries, are repointed through the rows' stored positions. The window
    // list rebuilds at the next window update when it may hold the removed or the
    // moved row. The caller recomposes the cell's blocked bit. O(1), allocation-free.
    fn removeSparseTile(self: *WorldSystem, index: u32) void {
        const geom = self.chunkGeometry();
        const rows = self.sparse_tiles.slice();
        const levels = rows.items(.level_index);
        const cells = rows.items(.cell_index);
        const level_positions = rows.items(.level_pos);
        const chunk_positions = rows.items(.chunk_pos);
        const last: u32 = @intCast(self.sparse_tiles.len - 1);

        const level = levels[index];
        const coord = self.cellCoordOf(cells[index]);
        const level_list = &self.sparse_level_tiles.items[level];
        const level_pos = level_positions[index];
        std.debug.assert(level_list.items[level_pos] == index);
        _ = level_list.swapRemove(level_pos);
        if (level_pos < level_list.items.len) level_positions[level_list.items[level_pos]] = level_pos;
        const chunk_list = &self.sparse_level_chunk_tiles.items[level].items[geom.chunkOf(coord.x, coord.y)];
        const chunk_pos = chunk_positions[index];
        std.debug.assert(chunk_list.items[chunk_pos] == index);
        _ = chunk_list.swapRemove(chunk_pos);
        if (chunk_pos < chunk_list.items.len) chunk_positions[chunk_list.items[chunk_pos]] = chunk_pos;
        if (self.sparseTileInWindow(level, coord.x, coord.y)) self.sparse_window.dirty = true;

        if (index != last) {
            const moved_level = levels[last];
            const moved = self.cellCoordOf(cells[last]);
            self.sparse_level_tiles.items[moved_level].items[level_positions[last]] = index;
            self.sparse_level_chunk_tiles.items[moved_level].items[geom.chunkOf(moved.x, moved.y)].items[chunk_positions[last]] = index;
            if (self.sparseTileInWindow(moved_level, moved.x, moved.y)) self.sparse_window.dirty = true;
        }
        self.sparse_tiles.swapRemove(index);
    }

    // The cell's composed movement-blocked bit from its bands and sparse tiles as
    // they stand. O(bands + sparse tiles in the chunk).
    fn cellComposedBlocked(self: *const WorldSystem, level: u16, x: u16, y: u16) bool {
        const geom = self.chunkGeometry();
        const stores = self.dense_layers.items(.store);
        for (self.level_terrain.items[level].bandLayers()) |layer| {
            if (self.flagsFor(stores[layer].tile(geom, x, y)).blocks_movement) return true;
        }
        return self.sparseBlocksCell(level, geom.chunkOf(x, y), self.cellIndex(x, y));
    }

    // Tile-cell coordinate of a cell index (below width * height, so both fit u16).
    fn cellCoordOf(self: *const WorldSystem, cell: u32) CellCoord {
        return .{ .x = @intCast(cell % self.width), .y = @intCast(cell / self.width) };
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
        return catalogFlags(self.catalog_flags.items, tile_id);
    }

    fn chunkGeometry(self: *const WorldSystem) ChunkGeometry {
        std.debug.assert(self.chunk_geom.edge != 0);
        return self.chunk_geom;
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

    // Whether the current render window draws a sparse tile at (x, y) on `level`:
    // the level is in the window around its active level and the cell is inside
    // its tile bounds. False before a window is set.
    fn sparseTileInWindow(self: *const WorldSystem, level: u16, x: u16, y: u16) bool {
        if (!self.visible_window_set) return false;
        if (!self.visible_render_window.levelInWindow(self.visible_active_level, level, self.maxLevelIndex())) return false;
        return x >= self.visible_min_tile_x and x < self.visible_max_tile_x_exclusive and
            y >= self.visible_min_tile_y and y < self.visible_max_tile_y_exclusive;
    }

    fn validateLevelIndex(self: *const WorldSystem, level_index: u16) !void {
        if (@as(usize, level_index) >= self.level_base_z.items.len) return error.InvalidWorldLevel;
    }

    fn validateTileId(self: *const WorldSystem, tile_id: TileId) !void {
        if (!self.isValidTileId(tile_id)) return error.InvalidWorldTile;
    }

    fn isValidTileId(self: *const WorldSystem, tile_id: TileId) bool {
        return catalogValid(self.catalog_valid.items, tile_id);
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

    // Depth, then layer index, so equal depths keep layer order whatever the input order.
    fn denseLayerIndexLessThan(self: *const WorldSystem, a: u32, b: u32) bool {
        const depth_a = self.denseLayerOrder(a).depth;
        const depth_b = self.denseLayerOrder(b).depth;
        if (depth_a != depth_b) return depth_a < depth_b;
        return a < b;
    }

    // Flat level-local chunk offset for a cell (chunkY*chunksX+chunkX),
    // identical for every level since width/height/chunk_size_tiles are
    // world-wide, not per-level. Backs sparse_level_chunk_tiles' middle
    // dimension.
    fn localChunkIndexForCell(self: *const WorldSystem, x: u16, y: u16) u32 {
        const chunks_x = self.chunksX();
        const chunk_x = x / self.chunk_size_tiles;
        const chunk_y = y / self.chunk_size_tiles;
        return @as(u32, chunk_y) * @as(u32, chunks_x) + @as(u32, chunk_x);
    }

    /// Level-local chunk grid width (world-wide, identical for every level —
    /// see `localChunkIndexForCell`). Exposed for callers that walk chunks by
    /// index (nav's world-obstacle mark, chunk benches) without duplicating this
    /// grid-shape arithmetic.
    pub fn chunksX(self: *const WorldSystem) u16 {
        return ceilDiv(self.width, self.chunk_size_tiles);
    }

    /// Level-local chunk grid height. See `chunksX`.
    pub fn chunksY(self: *const WorldSystem) u16 {
        return ceilDiv(self.height, self.chunk_size_tiles);
    }

    /// Chunks per level (`chunksX() * chunksY()`), the length of every per-level
    /// chunk directory.
    pub fn chunkCountPerLevel(self: *const WorldSystem) usize {
        return @as(usize, self.chunksX()) * @as(usize, self.chunksY());
    }

    // Fills one level's only dense band and its composed bits chunk by chunk on the
    // thread system: each chunk owns its own block and slot, then the main thread
    // returns all-fill blocks and uniform bits to uniform in O(chunks).
    fn buildProceduralGround(self: *WorldSystem, level: u16, layer_index: usize, ids: ProceduralTiles, seed: u64, thread_system: *ThreadSystem) !void {
        const geom = self.chunkGeometry();
        const terrain = &self.level_terrain.items[level];
        std.debug.assert(terrain.bandLayers().len == 1 and terrain.bandLayers()[0] == layer_index);
        std.debug.assert(self.sparseTileIndicesForLevel(level).len == 0);
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
    }

    fn addProceduralSparseTiles(self: *WorldSystem, level: u16, ids: ProceduralTiles, seed: u64) !void {
        const chunks_x = self.chunksX();
        const chunks_y = self.chunksY();
        var added_blocking = false;
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
                    added_blocking = added_blocking or self.flagsFor(ids.tree).blocks_movement;
                } else if ((h & 63) == 1) {
                    _ = try self.addSparseTile(level, x, y, ids.deco, 0, .obstacle);
                    added_blocking = added_blocking or self.flagsFor(ids.deco).blocks_movement;
                }
            }
        }
        if (added_blocking) self.level_terrain.items[level].content_revision +%= 1;
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
                    bits[local / 64] |= @as(u64, 1) << @intCast(local % 64);
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

// Pre-selects the batch shape so the job can assert range.index against it.
fn dispatchTerrainEditStage(stage: TerrainEditStageThreads, item_count: usize, job: anytype, job_fn: JobFn) BatchStats {
    const selection = stage.thread_system.selectBatchProfile(stage.tuner, .{
        .item_count = item_count,
        .items_per_range = stage.items_per_range,
        .range_alignment_items = 1,
        .adaptive = stage.adaptive,
    });
    job.range_count = selection.range_count;
    return stage.thread_system.parallelForWithOptions(item_count, job, job_fn, .{
        .adaptive = stage.adaptive,
        .adaptive_tuner = selection.active_tuner,
        .items_per_range = stage.items_per_range,
        .range_alignment_items = 1,
        .selected_profile = selection.profile,
    });
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

    for (group.writes) |write| {
        const band = job.layer_bands[write.layer];
        const local = geom.localOf(write.x, write.y);
        finals[@as(usize, band) * max_chunk_cells + local] = write.tile;
        touched[band][local / 64] |= @as(u64, 1) << @intCast(local % 64);
    }
    var any_touched: ChunkBits = @splat(0);
    for (written_list) |band| {
        for (&any_touched, touched[band]) |*word, band_word| word.* |= band_word;
    }

    const events = job.events[group.start..][0..group.writes.len];
    var change_count: usize = 0;
    const edge_mask: u32 = geom.edge - 1;
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
// rule as `WorldSystem.composedBlockedWith`, kept separate for the per-changed-cell
// cost. O(bands).
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
fn sparseBlockedBits(job: *const DenseEditWriteJob, geom: ChunkGeometry, level: u16, chunk: u32) ChunkBits {
    var bits: ChunkBits = @splat(0);
    for (chunkSparseTiles(job.sparse_level_chunk_tiles, level, chunk)) |sparse_index| {
        if (!job.sparse_flags[sparse_index].blocks_movement) continue;
        const cell = job.sparse_cells[sparse_index];
        // A cell index is below width * height, so both coordinates fit u16.
        const x: u16 = @intCast(cell % job.width);
        const y: u16 = @intCast(cell / job.width);
        std.debug.assert(geom.chunkOf(x, y) == chunk);
        const local = geom.localOf(x, y);
        bits[local / 64] |= @as(u64, 1) << @intCast(local % 64);
    }
    return bits;
}

// Indices into the sparse tile rows of `level`'s tiles in `chunk`.
fn chunkSparseTiles(level_chunk_tiles: []const std.ArrayList(std.ArrayList(u32)), level: u16, chunk: u32) []const u32 {
    if (level >= level_chunk_tiles.len) return &.{};
    const level_chunks = level_chunk_tiles[level].items;
    if (chunk >= level_chunks.len) return &.{};
    return level_chunks[chunk].items;
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
    // `dirt` is a solid underground material now; the surface accent is grass_patchy.
    if ((h & 7) == 0) return build.ids.grass_patchy;
    return build.ids.grass;
}

fn catalogValid(catalog_valid: []const bool, tile_id: TileId) bool {
    const index: usize = tile_id;
    return index < catalog_valid.len and catalog_valid[index];
}

fn catalogFlags(catalog_flags: []const TileFlags, tile_id: TileId) TileFlags {
    const index: usize = tile_id;
    if (index >= catalog_flags.len) return .{};
    return catalog_flags[index];
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

// The last tile a span from `origin` of `extent` pixels covers, clamped to the
// grid: an end exactly on a tile edge excludes the tile starting there, at any f32
// magnitude. Never before the span's first tile.
fn lastTileClamped(origin: f32, extent: f32, tile_size: f32, max_tiles: u16) u16 {
    const first = floorTileClamped(origin, tile_size, max_tiles);
    if (!(extent > 0)) return first;
    const end_tiles = @ceil((origin + extent) / tile_size);
    return @max(first, floorTileClamped(end_tiles - 1, 1, max_tiles));
}

// Chunks a pixel extent spans at most, capped at `chunks`.
fn rectChunkSpan(extent: f32, chunk_px: f32, chunks: u32) u32 {
    if (!(extent > 0)) return 0;
    const span = @ceil(extent / chunk_px);
    if (!(span < @as(f32, @floatFromInt(chunks)))) return chunks;
    return @intFromFloat(span);
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

/// Minimal grass-filled surface world (one dense floor layer, one chunk when
/// `max(width,height) <= max_chunk_size_tiles`). Prefer this over `initDemoFromMeta`
/// in unit tests that only need levels/dense layers, not demo terrain paint.
fn testMinimalSurfaceWorld(meta: *const WorldTilesetMeta, width: u16, height: u16) !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = width,
        .height = height,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = max_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(meta, "grass");
    _ = try world.addDenseLayer(level, 0, .floor, grass);
    return world;
}

const TestGpuStore = @import("world_test_support.zig").TestGpuStore;

// Runs one GPU tile sync without a renderer; the upload batch stays in
// `world.gpu_tiles.spans`/`values`. A world with no render window set renders its
// whole extent.
fn testSyncGpuTiles(world: *WorldSystem, active_level: u16) !world_gpu_tiles.SyncPlan {
    if (!world.visible_window_set) try testShowWholeWorld(world, active_level);
    const sync_plan = try world.planDenseGpuSync(active_level);
    world.commitDenseGpuSync(&sync_plan, active_level);
    return sync_plan;
}

// The window layers around `active_level`, deepest first, copied into `out`.
fn testSubmitLayers(world: *WorldSystem, active_level: u16, out: []u32) ![]u32 {
    const desired = try world.collectDenseSubmitLayers(active_level);
    const layers = out[0..desired.len];
    for (desired, 0..) |layer, index| layers[desired.len - 1 - index] = layer;
    return layers;
}

fn testShowWholeWorld(world: *WorldSystem, active_level: u16) !void {
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = world.worldWidthPixels(), .h = world.worldHeightPixels() }, 0, active_level);
}

// Sets the render window to exactly the chunks [min, min + size) on both axes.
fn testShowChunks(world: *WorldSystem, min_x: u16, min_y: u16, size_x: u16, size_y: u16, active_level: u16) !void {
    const chunk_px = @as(f32, @floatFromInt(world.chunk_size_tiles)) * world.tile_size;
    try world.setVisibleChunksForWorldRect(.{
        .x = @as(f32, @floatFromInt(min_x)) * chunk_px,
        .y = @as(f32, @floatFromInt(min_y)) * chunk_px,
        .w = @as(f32, @floatFromInt(size_x)) * chunk_px,
        .h = @as(f32, @floatFromInt(size_y)) * chunk_px,
    }, 0, active_level);
}

// Applies the last sync's upload batch to `gpu`.
fn testApplySync(world: *const WorldSystem, gpu: *TestGpuStore) !void {
    try gpu.apply(world.gpu_tiles.spans.items, world.gpu_tiles.values.items);
}

// The tile `gpu` shows for resident `layer` at (x, y), or null outside the window.
fn testGpuTile(world: *const WorldSystem, gpu: *const TestGpuStore, layer: usize, x: u16, y: u16) ?TileId {
    const mirror = &world.gpu_tiles;
    const slot = world.dense_layers.items(.gpu_slot)[layer];
    std.debug.assert(slot != world_gpu_tiles.no_slot);
    return gpu.tileAt(world.chunkGeometry(), mirror.side, mirror.window, mirror.slotDirectory(slot), x, y);
}

// Every resident layer reads back its CPU tiles over the window and nothing
// outside it, and the chain from the topmost resident layer composites them in
// depth order.
fn expectGpuStoreMatches(world: *const WorldSystem, gpu: *const TestGpuStore) !void {
    const mirror = &world.gpu_tiles;
    const layers = world.dense_render.layers.items;
    try std.testing.expectEqual(mirror.residentLayerCount(), layers.len);
    for (world.dense_layers.items(.gpu_slot), 0..) |slot, layer| {
        if (slot == world_gpu_tiles.no_slot) continue;
        for (0..world.height) |y| for (0..world.width) |x| {
            const gpu_tile = testGpuTile(world, gpu, layer, @intCast(x), @intCast(y));
            const chunk_x = @as(u32, @intCast(x)) >> world.chunkGeometry().shift;
            const chunk_y = @as(u32, @intCast(y)) >> world.chunkGeometry().shift;
            if (mirror.window.contains(chunk_x, chunk_y)) {
                try std.testing.expectEqual(@as(?TileId, world.denseTile(layer, @intCast(x), @intCast(y))), gpu_tile);
            } else {
                try std.testing.expectEqual(@as(?TileId, null), gpu_tile);
            }
        };
    }
    if (layers.len == 0) return;
    const top_slot = world.dense_layers.items(.gpu_slot)[layers[layers.len - 1]];
    for (0..world.height) |y| for (0..world.width) |x| {
        const shown = gpu.composite(world.chunkGeometry(), mirror.side, mirror.window, mirror.slotDirectory(top_slot), layers.len, invalid_tile_id, @intCast(x), @intCast(y)) orelse continue;
        var expected: TileId = invalid_tile_id;
        var index = layers.len;
        while (index > 0) {
            index -= 1;
            expected = world.denseTile(layers[index], @intCast(x), @intCast(y));
            if (expected != invalid_tile_id) break;
        }
        try std.testing.expectEqual(expected, shown);
    };
}

// A 16x16 world in 4-tile chunks with `level_count` empty levels; the render
// window holds the active level and one below.
fn testSparseWindowWorld(meta: *const WorldTilesetMeta, allocator: std.mem.Allocator, level_count: u16) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 1 },
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    for (0..level_count) |level_index| {
        _ = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
    }
    return world;
}

// Sets the render window to the tiles [x, x + edge) x [0, edge) plus `overscan` chunks.
fn testShowTiles(world: *WorldSystem, x: u16, edge: u16, overscan: u16, active_level: u16) !void {
    const tile_px = world.tile_size;
    try world.setVisibleChunksForWorldRect(.{
        .x = @as(f32, @floatFromInt(x)) * tile_px,
        .y = 0,
        .w = @as(f32, @floatFromInt(edge)) * tile_px,
        .h = @as(f32, @floatFromInt(edge)) * tile_px,
    }, overscan, active_level);
}

const TestSparseKey = struct { depth: i32, cell: u32, tile_id: TileId };

fn testSparseKeyLessThan(_: void, lhs: TestSparseKey, rhs: TestSparseKey) bool {
    if (lhs.depth != rhs.depth) return lhs.depth < rhs.depth;
    if (lhs.cell != rhs.cell) return lhs.cell < rhs.cell;
    return lhs.tile_id < rhs.tile_id;
}

// The window's sparse tiles as (depth, cell, tile id), in list order, into `out`.
fn testWindowSparseKeys(world: *const WorldSystem, out: []TestSparseKey) []TestSparseKey {
    const sparse = world.sparse_tiles.slice();
    const tiles = world.sparse_window.tiles.items;
    for (tiles, out[0..tiles.len]) |index, *key| {
        key.* = .{
            .depth = sparse.items(.depth_value)[index],
            .cell = sparse.items(.cell_index)[index],
            .tile_id = sparse.items(.tile_id)[index],
        };
    }
    return out[0..tiles.len];
}

// Every range is one depth, ranges ascend by depth, and together they cover the
// window's tiles exactly once in list order.
fn expectSparseRangesCoverWindow(world: *const WorldSystem) !void {
    const depths = world.sparse_tiles.items(.depth_value);
    const tiles = world.sparse_window.tiles.items;
    var next_start: u32 = 0;
    for (0..world.sparseDepthRangeCount()) |range_index| {
        const range = world.sparse_window.ranges.items[range_index];
        try std.testing.expectEqual(next_start, range.start);
        try std.testing.expect(range.count > 0);
        if (range_index > 0) try std.testing.expect(world.sparseDepthRangeAt(range_index - 1) < range.depth);
        try std.testing.expectEqual(range.depth, world.sparseDepthRangeAt(range_index));
        for (tiles[range.start..][0..range.count]) |index| try std.testing.expectEqual(range.depth, depths[index]);
        next_start += range.count;
    }
    try std.testing.expectEqual(tiles.len, next_start);
}

test "the window sparse list holds exactly the window's tiles ordered by depth, then cell, then tile id" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const tree = try world.requireTileByName(&meta, "tree_0");
    const deco = try world.requireTileByName(&meta, "deco_0");

    // Insertion order is neither depth nor cell order, with repeated depths and two
    // tile ids sharing a cell and depth.
    const Placement = struct { level: u16, x: u16, y: u16, tile: TileId, depth: WorldDepth };
    const placements = [_]Placement{
        .{ .level = 0, .x = 5, .y = 2, .tile = tree, .depth = .obstacle },
        .{ .level = 1, .x = 1, .y = 1, .tile = deco, .depth = .floor },
        .{ .level = 0, .x = 2, .y = 2, .tile = deco, .depth = .obstacle },
        .{ .level = 0, .x = 3, .y = 0, .tile = deco, .depth = .effect },
        .{ .level = 0, .x = 3, .y = 0, .tile = tree, .depth = .effect },
        .{ .level = 0, .x = 0, .y = 5, .tile = tree, .depth = .floor },
        .{ .level = 1, .x = 4, .y = 4, .tile = tree, .depth = .floor },
        // Outside: in an overscan chunk but past the tile bounds, outside the
        // chunk window, and on a level below the render window.
        .{ .level = 0, .x = 7, .y = 1, .tile = tree, .depth = .obstacle },
        .{ .level = 0, .x = 13, .y = 13, .tile = tree, .depth = .obstacle },
        .{ .level = 2, .x = 1, .y = 1, .tile = tree, .depth = .obstacle },
    };
    const inside_count = 7;
    var expected: [placements.len]TestSparseKey = undefined;
    for (placements, 0..) |placement, index| {
        _ = try world.addSparseTile(placement.level, placement.x, placement.y, placement.tile, 0, placement.depth);
        expected[index] = .{
            .depth = world.worldZForLevel(placement.level, 0, placement.depth),
            .cell = world.cellIndex(placement.x, placement.y),
            .tile_id = placement.tile,
        };
    }
    std.mem.sort(TestSparseKey, expected[0..inside_count], {}, testSparseKeyLessThan);

    // Tiles [0, 6) with one chunk of overscan: chunks [0, 3) on both axes.
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expectEqual(@as(usize, inside_count), world.reserveRenderRecords());
    var actual: [placements.len]TestSparseKey = undefined;
    try std.testing.expectEqualSlices(TestSparseKey, expected[0..inside_count], testWindowSparseKeys(&world, &actual));
    try expectSparseRangesCoverWindow(&world);

    // The batch path submits the same tiles, range by range.
    var batch = sprite_batch.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    batch.beginFrame();
    var submitted: usize = 0;
    for (0..world.sparseDepthRangeCount()) |range_index| {
        submitted += try world.submitVisibleSparseSprites(&batch, try TextureId.init(1, 1), range_index);
    }
    try std.testing.expectEqual(@as(usize, inside_count), submitted);
}

test "two same-depth sparse tiles in one window draw in the same order whichever was added first" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    const Placement = struct { x: u16, tile: []const u8 };
    // Same depth: two cells, and two tile ids on one of them.
    const placements = [_]Placement{ .{ .x = 3, .tile = "tree_0" }, .{ .x = 1, .tile = "deco_0" }, .{ .x = 1, .tile = "tree_0" } };
    var orders: [2][placements.len]TestSparseKey = undefined;
    for (&orders, 0..) |*order, pass| {
        var world = try testSparseWindowWorld(&meta, std.testing.allocator, 1);
        defer world.deinit();
        for (0..placements.len) |step| {
            const placement = placements[if (pass == 0) step else placements.len - 1 - step];
            _ = try world.addSparseTile(0, placement.x, 1, try world.requireTileByName(&meta, placement.tile), 0, .obstacle);
        }
        try testShowTiles(&world, 0, 4, 0, 0);
        try std.testing.expectEqual(@as(usize, 1), world.sparseDepthRangeCount());
        _ = testWindowSparseKeys(&world, order);
    }
    try std.testing.expectEqualSlices(TestSparseKey, &orders[0], &orders[1]);
    for (orders[0][1..], 1..) |key, index| try std.testing.expect(testSparseKeyLessThan({}, orders[0][index - 1], key));
}

test "a sparse tile added outside the window leaves the list untouched; one inside appears after the next window update" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);

    // Outside: past the tile bounds in an overscan chunk, and below the level window.
    _ = try world.addSparseTile(0, 7, 1, deco, 0, .effect);
    _ = try world.addSparseTile(2, 1, 1, deco, 0, .effect);
    try std.testing.expect(!world.sparse_window.dirty);
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    try std.testing.expectEqual(@as(usize, 1), world.sparseDepthRangeCount());

    // Inside, on the level below: listed from the next window update.
    _ = try world.addSparseTile(1, 2, 2, deco, 0, .effect);
    try std.testing.expect(world.sparse_window.dirty);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expect(!world.sparse_window.dirty);
    try std.testing.expectEqualSlices(u32, &.{ 3, 0 }, world.sparse_window.tiles.items);
    try expectSparseRangesCoverWindow(&world);
}

test "a render window change under a still camera relists the window's sparse levels" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    for (0..3) |level| _ = try world.addSparseTile(@intCast(level), 1, 1, deco, 0, .floor);
    try testShowTiles(&world, 0, 4, 0, 0);
    // Levels 0 and 1, deepest first.
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, world.sparse_window.tiles.items);

    world.render_window = .{ .levels_below = 2 };
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, world.sparse_window.tiles.items);
    try expectSparseRangesCoverWindow(&world);
}

test "an active level change under a still camera relists the window's sparse levels" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .floor);
    _ = try world.addSparseTile(2, 1, 1, deco, 0, .floor);
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    // Level 1 renders levels 1 and 2.
    try testShowTiles(&world, 0, 4, 0, 1);
    try std.testing.expectEqualSlices(u32, &.{1}, world.sparse_window.tiles.items);
}

test "an out-of-memory window update leaves the previous window and its sparse list intact (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 1);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    // More tiles than the first list's capacity, in the chunks right of the window.
    for (0..64) |index| {
        _ = try world.addSparseTile(0, 8 + @as(u16, @intCast(index % 8)), @intCast(index / 8), deco, 0, .effect);
    }
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    const region = world.visibleChunkRegion().?;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    world.allocator = failing.allocator();
    // A pan onto the dense chunks fails: the window and list stay as they were.
    try std.testing.expectError(error.OutOfMemory, testShowTiles(&world, 8, 8, 0, 0));
    try std.testing.expectEqual(region, world.visibleChunkRegion().?);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    try std.testing.expectEqual(@as(usize, 1), world.sparseDepthRangeCount());

    // An in-window add that cannot be listed keeps the list dirty for the retry.
    world.allocator = std.testing.allocator;
    for (0..64) |_| _ = try world.addSparseTile(0, 2, 2, deco, 0, .effect);
    world.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, testShowTiles(&world, 0, 4, 0, 0));
    try std.testing.expect(world.sparse_window.dirty);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);

    world.allocator = std.testing.allocator;
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expect(!world.sparse_window.dirty);
    try std.testing.expectEqual(@as(usize, 65), world.reserveRenderRecords());
    try testShowTiles(&world, 8, 8, 0, 0);
    try std.testing.expectEqual(@as(usize, 64), world.reserveRenderRecords());
    try expectSparseRangesCoverWindow(&world);
}

test "a warmed window update allocates nothing across pans and an in-window add (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 2);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    for (0..16) |index| {
        const x: u16 = @intCast(index % 16);
        _ = try world.addSparseTile(@intCast(index % 2), x, 1, deco, 0, if (index % 3 == 0) .floor else .effect);
    }
    // Warm the list to the widest window, then add one tile inside the left window.
    try testShowTiles(&world, 0, 16, 0, 0);
    try testShowTiles(&world, 0, 8, 0, 0);
    _ = try world.addSparseTile(1, 3, 3, deco, 0, .marker);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    world.allocator = failing.allocator();
    defer world.allocator = std.testing.allocator;
    try testShowTiles(&world, 0, 8, 0, 0);
    try std.testing.expectEqual(@as(usize, 9), world.reserveRenderRecords());
    try testShowTiles(&world, 8, 8, 0, 0);
    try testShowTiles(&world, 0, 16, 0, 1);
    try testShowTiles(&world, 0, 8, 0, 0);
    try std.testing.expectEqual(@as(usize, 9), world.reserveRenderRecords());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "the window sparse list is the same at 1k and 64k tiles outside the window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    const window_depths = [_]WorldDepth{ .floor, .obstacle, .effect, .marker };
    var lists: [2][8]TestSparseKey = undefined;
    for ([_]usize{ 1_000, 64_000 }, &lists) |outside_count, *list| {
        var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
        defer world.deinit();
        const deco = try world.requireTileByName(&meta, "deco_0");
        for (0..8) |index| {
            _ = try world.addSparseTile(0, @intCast(index), 2, deco, 0, window_depths[index % window_depths.len]);
        }
        // Outside: the right half on the window's levels, anywhere on the level
        // below the render window.
        for (0..outside_count) |index| {
            const level: u16 = @intCast(index % 3);
            const x: u16 = @intCast(if (level == 2) index % 16 else 8 + index % 8);
            _ = try world.addSparseTile(level, x, @intCast(index / 3 % 16), deco, 0, window_depths[index % window_depths.len]);
        }
        try testShowTiles(&world, 0, 8, 0, 0);
        try std.testing.expectEqual(@as(usize, 8), world.reserveRenderRecords());
        try std.testing.expectEqual(window_depths.len, world.sparseDepthRangeCount());
        _ = testWindowSparseKeys(&world, list);
    }
    try std.testing.expectEqualSlices(TestSparseKey, &lists[0], &lists[1]);
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

test "a synced store reads back every resident window tile through splits, edits, re-uniforms, and pans" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8x8 tiles in 4x4 chunks: a 2x2 chunk grid, every chunk starting uniform.
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
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(level, 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();

    // Entering: one directory, no blocks while every chunk is uniform.
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), world.gpu_tiles.spans.items.len);
    try expectGpuStoreMatches(&world, &gpu);

    // One step splits all four chunks (a multi-chunk change), then edits one of
    // them again in the same step.
    for ([_][2]u16{ .{ 1, 1 }, .{ 6, 0 }, .{ 0, 7 }, .{ 7, 7 }, .{ 2, 1 } }) |cell| {
        _ = try world.setDenseTile(layer, cell[0], cell[1], water);
    }
    _ = try world.clearDenseTile(layer, 2, 1);
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);

    // Repeated dig and fill: a chunk returning to one tile frees its block, and the
    // next split reuses it, so the store never grows.
    const high_water = world.gpu_tiles.high_water;
    for (0..3) |_| {
        _ = try world.setDenseTile(layer, 1, 1, grass);
        _ = try world.setDenseTile(layer, 2, 1, grass);
        _ = try testSyncGpuTiles(&world, level);
        try testApplySync(&world, &gpu);
        try expectGpuStoreMatches(&world, &gpu);
        _ = try world.setDenseTile(layer, 3, 3, water);
        _ = try testSyncGpuTiles(&world, level);
        try testApplySync(&world, &gpu);
        try expectGpuStoreMatches(&world, &gpu);
        _ = try world.setDenseTile(layer, 3, 3, grass);
        try std.testing.expectEqual(high_water, world.gpu_tiles.high_water);
    }

    // Pans one chunk at a time around the grid with a 1x1 window: every step reads
    // back, including edits made while a chunk was outside the window.
    const steps = [_][2]u16{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } };
    for (steps, 0..) |step, index| {
        try testShowChunks(&world, step[0], step[1], 1, 1, level);
        _ = try world.setDenseTile(layer, @intCast(4 + index % 4), 5, if (index % 2 == 0) water else grass);
        _ = try testSyncGpuTiles(&world, level);
        try testApplySync(&world, &gpu);
        try expectGpuStoreMatches(&world, &gpu);
    }
}

test "an edit outside the window uploads nothing; its chunk reads back edited when it enters" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x4 tiles in 4x4 chunks: a 4x1 chunk grid, the window one chunk wide.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 16,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    try testShowChunks(&world, 0, 0, 1, 1, 0);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);

    // Chunk 2 is outside the window: its dig uploads nothing.
    _ = try world.setDenseTile(layer, 9, 1, water);
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);

    // The window reaches it: the chunk uploads whole and reads back edited.
    try testShowChunks(&world, 2, 0, 1, 1, 0);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, layer, 9, 1));
    try expectGpuStoreMatches(&world, &gpu);
}

test "an evicted layer's edits upload nothing; it reads back edited when it returns" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const surface = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.addDenseLayer(try world.addLevel(-level_z_step), 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);

    // An edit made while resident, then the layer leaves before the next sync: the
    // sync that evicts it uploads only the entering layer's directory.
    _ = try world.setDenseTile(surface, 1, 1, water);
    _ = try testSyncGpuTiles(&world, 1);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), world.gpu_tiles.spans.items.len);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[surface]);
    // Edits while not resident upload nothing either.
    _ = try world.setDenseTile(surface, 6, 6, water);
    _ = try testSyncGpuTiles(&world, 1);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);

    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, surface, 1, 1));
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, surface, 6, 6));
    try expectGpuStoreMatches(&world, &gpu);
}

test "a reset GPU mirror re-enters every resident layer at the next sync" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8x8 tiles in 4x4 chunks on two levels, one layer each.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const surface = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    const below = try world.addDenseLayer(try world.addLevel(-level_z_step), 0, .floor, grass);
    var before = TestGpuStore{};
    defer before.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &before);
    // Split one chunk on each layer and sync, then edit once more without a sync.
    _ = try world.setDenseTile(surface, 1, 1, water);
    _ = try world.setDenseTile(below, 6, 6, water);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &before);
    _ = try world.setDenseTile(surface, 5, 1, water);
    world.gpu_tiles.store = .{ .index = 0, .generation = 1 };
    world.dense_quads_dirty = false;

    // The renderer retired the store: nothing stays resident or drawn.
    world.resetGpuResidency();
    try std.testing.expect(!world.gpu_tiles.store.isValid());
    for (world.dense_layers.items(.gpu_slot)) |slot| try std.testing.expectEqual(world_gpu_tiles.no_slot, slot);
    try std.testing.expectEqual(@as(usize, 0), world.maxDenseSubmitDrawCount());
    try std.testing.expect(world.dense_quads_dirty);

    // A new store starts empty: the next sync uploads the window whole, the edit
    // made since the last sync included.
    var after = TestGpuStore{};
    defer after.deinit();
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expect(sync_plan.relayout);
    try testApplySync(&world, &after);
    try std.testing.expectEqual(@as(usize, 2), world.maxDenseSubmitDrawCount());
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &after, surface, 5, 1));
    try expectGpuStoreMatches(&world, &after);
}

test "after a GPU residency reset the re-submitted static tilemap draws name the store the next sync holds" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();
    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    // Headless: the static-geometry path never dereferences GPU handles.
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
    defer deinitStaticTestRenderer(&renderer);

    const retired = TileDataId{ .index = 0, .generation = 1 };
    world.gpu_tiles.store = retired;
    _ = try testSyncGpuTiles(&world, 0);
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try expectStaticTilemapStore(&renderer, retired);

    // A failed claim resets residency; the next sync re-enters the window and
    // creates a store, here the next generation of the same slot.
    world.resetGpuResidency();
    const replacement = TileDataId{ .index = 0, .generation = 2 };
    _ = try testSyncGpuTiles(&world, 0);
    world.gpu_tiles.store = replacement;
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try expectStaticTilemapStore(&renderer, replacement);
}

fn deinitStaticTestRenderer(renderer: *Renderer) void {
    const allocator = renderer.allocator;
    renderer.batch.deinit();
    renderer.static_positions.deinit(allocator);
    renderer.static_uvs.deinit(allocator);
    renderer.static_colors.deinit(allocator);
    renderer.static_groups.deinit(allocator);
    renderer.tilemap_window_layers.deinit(allocator);
    renderer.draw_list.deinit(allocator);
    for (renderer.tile_stores.items) |*store| {
        store.pending_spans.deinit(allocator);
        store.pending_values.deinit(allocator);
    }
    renderer.tile_stores.deinit(allocator);
    renderer.tile_merge_spans.deinit(allocator);
    renderer.tile_merge_values.deinit(allocator);
}

fn expectStaticTilemapStore(renderer: *const Renderer, store: TileDataId) !void {
    var tilemap_draws: usize = 0;
    for (renderer.static_groups.items) |group| {
        if (group.material != .tilemap) continue;
        tilemap_draws += 1;
        try std.testing.expectEqual(store, group.tile_data);
    }
    try std.testing.expect(tilemap_draws > 0);
}

// Registers a store with no GPU buffer in a headless renderer and hands it to
// `world`, laid out for its render window, so syncs validate and queue uploads
// without touching SDL. The capacity covers any test world, so no sync grows it.
fn attachFakeTileStore(renderer: *Renderer, world: *WorldSystem) !*@TypeOf(renderer.tile_stores.items[0]) {
    try renderer.tile_stores.append(renderer.allocator, .{
        .buffer = @ptrFromInt(0x1000),
        .element_capacity = 1 << 20,
        .params = std.mem.zeroes(TilemapParams),
    });
    world.gpu_tiles.store = .{ .index = @intCast(renderer.tile_stores.items.len - 1), .generation = 1 };
    world.gpu_tiles.store_side = world.render_side;
    return &renderer.tile_stores.items[renderer.tile_stores.items.len - 1];
}

test "syncDenseTileStore claims its live store every frame and drops a retired one with its residency" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    // Level 1 holds no layer, so syncing there needs no store and never creates one.
    _ = try world.addLevel(-level_z_step);
    try testShowWholeWorld(&world, 0);

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
    defer deinitStaticTestRenderer(&renderer);
    const store = try attachFakeTileStore(&renderer, &world);

    // Every sync claims the live store, even one with nothing to upload, and moves
    // its window uniform to the render window.
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(store.claimed);
    try std.testing.expectEqual([4]u32{ 0, 0, 2, 2 }, store.params.window);
    try std.testing.expect(world.dense_layers.items(.gpu_slot)[layer] != world_gpu_tiles.no_slot);
    store.claimed = false;
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(store.claimed);

    // The renderer retired the store (generation advanced): the next sync drops
    // the stale id and every resident layer, and re-submits the draws.
    store.generation = 2;
    world.dense_quads_dirty = false;
    try world.syncDenseTileStore(&renderer, 1);
    try std.testing.expect(!world.gpu_tiles.store.isValid());
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[layer]);
    try std.testing.expect(world.dense_quads_dirty);
}

test "a new directory side with nothing resident lets the old store go and re-submits the draws" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x16 tiles in 4x4 chunks; level 1 holds no layer.
    var world = WorldSystem{
        .allocator = allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.addLevel(-level_z_step);
    try testShowChunks(&world, 0, 0, 1, 1, 0);
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
    defer deinitStaticTestRenderer(&renderer);
    const store = try attachFakeTileStore(&renderer, &world);
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(world.gpu_tiles.store.isValid());
    try std.testing.expectEqual([4]u32{ 0, 0, 1, 1 }, store.params.window);

    // A wider rect needs a larger side; on a level with no layer nothing uploads,
    // so the world stops naming (and claiming) the old store's layout.
    try testShowChunks(&world, 0, 0, 3, 3, 1);
    world.dense_quads_dirty = false;
    try world.syncDenseTileStore(&renderer, 1);
    try std.testing.expect(!world.gpu_tiles.store.isValid());
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[layer]);
    try std.testing.expect(world.dense_quads_dirty);
    try std.testing.expectEqual(@as(usize, 0), world.maxDenseSubmitDrawCount());
}

test "setDenseTile on a resident layer uploads at the next sync; one outside the level window uploads when it enters" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();
    world.render_window = .{ .levels_below = 0 };
    const water = try world.requireTileByName(&meta, "water_1");
    const grass = try world.requireTileByName(&meta, "grass");
    const below = world.denseFloorLayerForLevel(1).?;
    var gpu = TestGpuStore{};
    defer gpu.deinit();

    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    // Not resident: nothing uploads.
    _ = try world.setDenseTile(below, 2, 1, grass);
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);
    // Resident: the next sync uploads it; an unchanged tile uploads nothing.
    _ = try world.setDenseTile(0, 1, 0, water);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, 0, 1, 0));
    try std.testing.expect((try world.setDenseTile(0, 1, 0, water)) == null);
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);

    _ = try testSyncGpuTiles(&world, 1);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, grass), testGpuTile(&world, &gpu, below, 2, 1));
    try expectGpuStoreMatches(&world, &gpu);
}

test "reserveDenseCellWrite covers N writes across uniform chunks on a resident layer (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8x8 tiles, 4x4 chunks: three writes land in three different uniform chunks and
    // split three composed chunks; two more share the first chunk.
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
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(level, 0, .floor, grass);
    // Resident in the GPU tile store, so every write also reaches the GPU.
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);

    const writes = [_][2]u16{ .{ 0, 0 }, .{ 5, 1 }, .{ 2, 6 }, .{ 1, 0 }, .{ 3, 3 } };
    world.beginDenseCellWriteReserve();
    for (writes) |cell| try world.reserveDenseCellWrite(layer, cell[0], cell[1], water);
    // Reads are unchanged by the reserve.
    for (writes) |cell| {
        try std.testing.expectEqual(grass, world.denseTile(layer, cell[0], cell[1]));
        try std.testing.expect(!world.levelBlocksMovement(level, cell[0], cell[1]));
    }
    // One block and one slot per distinct chunk, not per write.
    try std.testing.expectEqual(@as(usize, 3), world.dense_layers.items(.store)[layer].liveBlockCount());
    try std.testing.expectEqual(@as(usize, 3), world.level_terrain.items[level].blocked.liveSlotCount());
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
    try world.reserveDenseCellWrite(layer, 6, 6, water);
    try std.testing.expectEqual(@as(?TileId, null), world.dense_layers.items(.store)[layer].uniformTile(3));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(level, 3));
    world.beginDenseCellWriteReserve();
    try std.testing.expectEqual(@as(?TileId, grass), world.dense_layers.items(.store)[layer].uniformTile(3));
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 3));
    try std.testing.expectEqual(@as(usize, 3), world.dense_layers.items(.store)[layer].liveBlockCount());

    // Reserving a write that changes nothing reserves nothing.
    try world.reserveDenseCellWrite(layer, 0, 0, water);
    try std.testing.expectEqual(@as(usize, 0), world.dense_reserved_chunks.items.len);
}

test "a split chunk uploads its word and whole block; later edits re-upload the block once" {
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
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    // One chunk: a directory of side 1 (one word and the link) at 0, blocks after it.
    const block = world_gpu_tiles.directoryWords(1);

    // Splitting the chunk uploads its directory word and its whole block.
    _ = try world.setDenseTile(layer, 2, 0, water);
    _ = try testSyncGpuTiles(&world, level);
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = 0, .count = 1 },
        .{ .dst_element = block, .count = 8 },
    }, world.gpu_tiles.spans.items);
    try testApplySync(&world, &gpu);

    // Three edits, one cell twice, then the same frame again: the block uploads
    // whole once, valued from the chunk store, and nothing after.
    _ = try world.setDenseTile(layer, 1, 0, water);
    _ = try world.setDenseTile(layer, 0, 0, water);
    _ = try world.clearDenseTile(layer, 0, 0);
    _ = try testSyncGpuTiles(&world, level);
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = block, .count = 8 },
    }, world.gpu_tiles.spans.items);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);
    _ = try testSyncGpuTiles(&world, level);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);
}

test "two resident layers on one level upload to their own directories and blocks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 3, 1);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer1 = try world.addDenseLayer(0, 0, .obstacle, water);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    const slots = world.dense_layers.items(.gpu_slot);
    try std.testing.expect(world.gpu_tiles.slotDirectory(slots[0]) != world.gpu_tiles.slotDirectory(slots[layer1]));

    // Edits in both layers in one frame write separate blocks; neither layer reads
    // the other's cells.
    _ = try world.setDenseTile(0, 2, 0, water);
    _ = try world.setDenseTile(layer1, 0, 0, grass);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);
    _ = try world.clearDenseTile(0, 2, 0);
    _ = try world.setDenseTile(layer1, 1, 0, grass);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 2), world.gpu_tiles.spans.items.len);
    try expectGpuStoreMatches(&world, &gpu);
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

    // The block pool fails first; then, warmed, the composed-bits slot. Each OOM
    // leaves the chunk's tiles and form, the composed bits, and the layer's render
    // flag exactly as they were.
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
        try std.testing.expect(!world.gpu_edits_pending);
    }

    // Retry with a working allocator succeeds and is consistent.
    const changed = (try world.setDenseTile(layer, 1, 1, water)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(water, changed.new_tile_id);
    try std.testing.expectEqual(water, world.denseTile(layer, 1, 1));
    try std.testing.expectEqual(@as(?TileId, null), world.dense_layers.items(.store)[layer].uniformTile(0));
    try std.testing.expect(world.levelBlocksMovement(level, 1, 1));
    try std.testing.expect(world.dense_layers.items(.render_changed)[layer] and world.gpu_edits_pending);
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
    // Level 1 reuses level-local chunk indices; its tiles stay in its own buckets.
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

// Every sparse row is listed exactly once in its level list and once in its chunk
// list, at its stored positions, and the lists list nothing else.
fn expectSparseIndexConsistent(world: *const WorldSystem) !void {
    const rows = world.sparse_tiles.slice();
    const geom = world.chunkGeometry();
    var level_total: usize = 0;
    for (world.sparse_level_tiles.items, 0..) |list, level| {
        level_total += list.items.len;
        for (list.items, 0..) |row, position| {
            try std.testing.expect(row < rows.len);
            try std.testing.expectEqual(level, rows.items(.level_index)[row]);
            try std.testing.expectEqual(position, rows.items(.level_pos)[row]);
        }
    }
    try std.testing.expectEqual(rows.len, level_total);
    var chunk_total: usize = 0;
    for (world.sparse_level_chunk_tiles.items, 0..) |level_chunks, level| {
        for (level_chunks.items, 0..) |list, chunk| {
            chunk_total += list.items.len;
            for (list.items, 0..) |row, position| {
                try std.testing.expect(row < rows.len);
                try std.testing.expectEqual(level, rows.items(.level_index)[row]);
                const coord = world.sparseTileCellCoord(row);
                try std.testing.expectEqual(chunk, geom.chunkOf(coord.x, coord.y));
                try std.testing.expectEqual(position, rows.items(.chunk_pos)[row]);
            }
        }
    }
    try std.testing.expectEqual(rows.len, chunk_total);
}

// The sparse rows as sorted (level, cell, tile id) keys, into `out`.
const TestSparseRowKey = struct { level: u16, cell: u32, tile_id: TileId };

fn testSparseRowKeys(world: *const WorldSystem, out: []TestSparseRowKey) []TestSparseRowKey {
    const rows = world.sparse_tiles.slice();
    for (out[0..rows.len], 0..) |*key, row| key.* = .{
        .level = rows.items(.level_index)[row],
        .cell = rows.items(.cell_index)[row],
        .tile_id = rows.items(.tile_id)[row],
    };
    std.mem.sort(TestSparseRowKey, out[0..rows.len], {}, testSparseRowKeyLessThan);
    return out[0..rows.len];
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
    for (removals, 0..) |removal, step| {
        const list = world.sparseTileIndicesForChunk(removal.level, removal.chunk);
        if (removal.at == .middle) try std.testing.expect(list.len >= 3);
        const position = switch (removal.at) {
            .first => 0,
            .middle => list.len / 2,
            .last => list.len - 1,
        };
        const removed = list[position];
        const coord = world.sparseTileCellCoord(removed);
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
        // Every remaining tile still blocks its cell.
        for (0..world.sparseTileCount()) |row| {
            const remaining = world.sparseTileCellCoord(row);
            try std.testing.expect(world.levelBlocksMovement(world.sparse_tiles.items(.level_index)[row], remaining.x, remaining.y));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), world.sparseTileCount());
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
    var level_capacity: usize = 0;
    for (0..16) |cycle| {
        for (0..3) |_| _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
        _ = try world.addSparseTile(0, 6, 6, deco, 0, .obstacle);
        try std.testing.expectEqual(@as(usize, 5), world.sparseTileCount());
        try std.testing.expect((try world.clearCellBlocking(0, 1, 1, tunnel)) != null);
        try std.testing.expect((try world.clearCellBlocking(0, 6, 6, tunnel)) != null);

        try std.testing.expectEqual(@as(usize, 1), world.sparseTileCount());
        try std.testing.expectEqual(@as(usize, 1), world.sparseTileIndicesForLevel(0).len);
        try expectSparseIndexConsistent(&world);
        // No blocked cell remains, so the level holds no composed-bits slot.
        try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[0].blocked.liveSlotCount());
        if (cycle == 0) {
            row_capacity = world.sparse_tiles.capacity;
            level_capacity = world.sparse_level_tiles.items[0].capacity;
        }
        try std.testing.expectEqual(row_capacity, world.sparse_tiles.capacity);
        try std.testing.expectEqual(level_capacity, world.sparse_level_tiles.items[0].capacity);
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
    const slots_before = world.level_terrain.items[0].blocked.liveSlotCount();

    // Walkable floor and overlay with a walkable decal, and a hole: nothing to clear.
    try std.testing.expectEqual(@as(?WorldObstacleChangedEvent, null), try world.clearCellBlocking(0, 2, 2, tunnel));
    try std.testing.expectEqual(@as(?WorldObstacleChangedEvent, null), try world.clearCellBlocking(0, 3, 3, tunnel));
    try std.testing.expectEqual(grass, world.denseTile(floor, 2, 2));
    try std.testing.expectEqual(grass, world.denseTile(overlay, 2, 2));
    try std.testing.expectEqual(invalid_tile_id, world.denseTile(floor, 3, 3));
    try std.testing.expectEqual(@as(usize, 1), world.sparseTileCount());
    try std.testing.expectEqual(slots_before, world.level_terrain.items[0].blocked.liveSlotCount());

    // A blocking floor clears to the floor tile; the walkable overlay and decal stay.
    _ = try world.setDenseTile(floor, 2, 2, dirt);
    try std.testing.expect(world.levelBlocksMovement(0, 2, 2));
    try std.testing.expect((try world.clearCellBlocking(0, 2, 2, tunnel)) != null);
    try std.testing.expectEqual(tunnel, world.denseTile(floor, 2, 2));
    try std.testing.expectEqual(grass, world.denseTile(overlay, 2, 2));
    try std.testing.expectEqual(@as(usize, 1), world.sparseTileCount());
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
    try std.testing.expectEqual(@as(usize, 0), world.sparseTileCount());
    try std.testing.expect(!world.levelBlocksMovement(0, 1, 1));
    try std.testing.expect(world.levelBlocksMovement(0, 0, 1));
    try expectSparseIndexConsistent(&world);
}

test "a cleared sparse tile no longer blocks and is not in the window list; an unrelated removal keeps the draw order" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 2);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const stone = try world.requireTileByName(&meta, "stone_floor");
    const tunnel = try world.requireTileByName(&meta, "cave_0");

    // Row 0 lies outside the window; the last row lies inside it, so removing row 0
    // moves an in-window row.
    _ = try world.addSparseTile(0, 12, 12, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 2, 2, tree, 0, .obstacle);
    _ = try world.addSparseTile(0, 2, 2, stone, 0, .floor);
    _ = try world.addSparseTile(1, 3, 1, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 5, 6, deco, 0, .effect);
    _ = try world.addSparseTile(0, 1, 7, tree, 0, .obstacle);
    try testShowTiles(&world, 0, 8, 0, 0);
    var keys_buf: [8]TestSparseKey = undefined;
    var before_buf: [8]TestSparseKey = undefined;
    const before = testWindowSparseKeys(&world, &before_buf);
    try std.testing.expectEqual(@as(usize, 5), before.len);

    // The unrelated removal moves a window row: the list rebuilds, same draw order.
    try std.testing.expect((try world.clearCellBlocking(0, 12, 12, tunnel)) != null);
    try std.testing.expect(world.sparse_window.dirty);
    try testShowTiles(&world, 0, 8, 0, 0);
    try std.testing.expectEqualSlices(TestSparseKey, before, testWindowSparseKeys(&world, &keys_buf));
    try expectSparseRangesCoverWindow(&world);

    // Clearing (2, 2) drops its blocking tree and keeps the walkable decal.
    try std.testing.expect(world.levelBlocksMovement(0, 2, 2));
    try std.testing.expect((try world.clearCellBlocking(0, 2, 2, tunnel)) != null);
    try std.testing.expect(!world.levelBlocksMovement(0, 2, 2));
    try std.testing.expect(world.sparse_window.dirty);
    try testShowTiles(&world, 0, 8, 0, 0);
    const after = testWindowSparseKeys(&world, &keys_buf);
    try std.testing.expectEqual(@as(usize, 4), after.len);
    const cleared_cell = world.cellIndex(2, 2);
    for (after) |key| try std.testing.expect(key.cell != cleared_cell or key.tile_id == stone);
    try expectSparseRangesCoverWindow(&world);
    try expectSparseIndexConsistent(&world);
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

test "dense layer submit order sorts back to front by render depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var indices: [3]u32 = .{ 0, 1, 2 };
    std.mem.sort(u32, &indices, &world, WorldSystem.denseLayerIndexLessThan);
    try std.testing.expectEqual(@as(i32, -34), world.denseLayerOrder(indices[0]).depth);
    try std.testing.expectEqual(@as(i32, -18), world.denseLayerOrder(indices[1]).depth);
    try std.testing.expectEqual(@as(i32, -2), world.denseLayerOrder(indices[2]).depth);
}

test "underground dense layers append in storage order not ascending render depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
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

    // A higher base-z level carries a strictly higher order; the ordered draw list
    // interleaves each dense tilemap quad with dynamic entities by this depth.
    try std.testing.expect(world.denseLayerOrder(lower_layer).depth < world.denseLayerOrder(upper_layer).depth);

    // A structural change (new level or layer) arms a quad re-submit.
    try std.testing.expect(world.dense_quads_dirty);
    world.dense_quads_dirty = false;

    // A dig changes tile-data, not quad geometry, so it does not re-arm a re-submit
    // (the GPU buffer is updated directly by the dig hook).
    _ = try world.setDenseTile(lower_layer, 3, 3, water);
    try std.testing.expect(!world.dense_quads_dirty);

    // A pan changes chunk visibility (crops sparse tiles) but not the full-world
    // dense quads, so it does not re-arm a re-submit either.
    try world.setVisibleChunksForWorldRect(.{ .x = 1024, .y = 1024, .w = 128, .h = 128 }, 0, 0);
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

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;
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

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 20, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 7), count);
    for (layers[0..count]) |layer_index| {
        const level = world.denseLayerLevel(layer_index);
        try std.testing.expect(level >= 20 and level <= 26);
    }
}

test "collectDenseSubmitLayers shifts with player level transitions" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layer_buffer: [64]u32 = undefined;
    var layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const surface_count = layers.len;
    try std.testing.expectEqual(@as(usize, 3), surface_count);
    var saw_surface = false;
    for (layers[0..surface_count]) |layer_index| {
        if (world.denseLayerLevel(layer_index) == 0) saw_surface = true;
    }
    try std.testing.expect(saw_surface);

    layers = try testSubmitLayers(&world, 1, &layer_buffer);
    const dirt_count = layers.len;
    try std.testing.expectEqual(@as(usize, 2), dirt_count);
    for (layers[0..dirt_count]) |layer_index| {
        try std.testing.expect(world.denseLayerLevel(layer_index) >= 1);
    }

    layers = try testSubmitLayers(&world, 2, &layer_buffer);
    const void_count = layers.len;
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

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "denseWindowDepthSpan returns the resident layers' deepest and shallowest depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    // Nothing is resident before the first sync.
    try std.testing.expect(world.denseWindowDepthSpan() == null);
    _ = try testSyncGpuTiles(&world, 0);
    const span = world.denseWindowDepthSpan() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(world.denseLayerOrder(2).depth, span.min);
    try std.testing.expectEqual(world.denseLayerOrder(0).depth, span.max);
    try std.testing.expectEqual(@as(usize, 3), world.denseWindowLayerDepths().len);

    // The span follows the resident set to the next level at the next sync.
    _ = try testSyncGpuTiles(&world, 1);
    const deeper = world.denseWindowDepthSpan() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(world.denseLayerOrder(2).depth, deeper.min);
    try std.testing.expectEqual(world.denseLayerOrder(1).depth, deeper.max);
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

    try std.testing.expect(world.denseWindowDepthSpan() == null);
}

test "partitionDenseCompositeBuckets returns a single bucket with no interleave depths in window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;

    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
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

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 2, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 4), count);

    // The active level's own actor depth is the only interleave point — mirrors
    // today's ceiling-vs-window split, now expressed as the general rule.
    const interleave = [_]i32{world.activeLevelActorDepth(2)};
    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
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

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 7), count);

    // A synthetic sandwich point (e.g. a sparse tile) between level 5 and level
    // 4's own floor depths — neither is the active level (0) nor the window's
    // shallowest layer. This is the case an active-level-only design would miss.
    const interleave = [_]i32{world.worldZForLevel(5, 0, .effect)};
    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = world.partitionDenseCompositeBuckets(layers[0..count], &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, 2), bucket_count);
    try std.testing.expectEqual(@as(usize, 2), buckets[0].end - buckets[0].start);
    try std.testing.expectEqual(@as(usize, 5), buckets[1].end - buckets[1].start);
    try std.testing.expectEqual(@as(u16, 5), world.denseLayerLevel(layers[buckets[0].end - 1]));
    try std.testing.expectEqual(@as(u16, 4), world.denseLayerLevel(layers[buckets[1].start]));
}

test "partitionDenseCompositeBuckets produces one bucket per cut point when every gap is cut" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 40 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const level_count = 40;
    for (0..level_count) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    try std.testing.expectEqual(@as(usize, level_count), layers.len);

    // One interleave point strictly between every consecutive pair: one bucket per
    // layer, the most a partition can produce.
    var interleave: [level_count - 1]i32 = undefined;
    for (&interleave, 0..) |*depth, i| {
        const deeper = world.denseLayerOrder(layers[i]).depth;
        const shallower = world.denseLayerOrder(layers[i + 1]).depth;
        depth.* = deeper + @divTrunc(shallower - deeper, 2);
    }

    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = world.partitionDenseCompositeBuckets(layers, &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, level_count), bucket_count);
    for (buckets[0..bucket_count]) |bucket| {
        try std.testing.expectEqual(@as(usize, 1), bucket.end - bucket.start);
    }
}

test "buildWindowLayers names each bucket's topmost resident directory and its layer count" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);
    _ = try testSyncGpuTiles(&world, 0);

    // Resident layers are deepest first (dirt_dark, dirt, grass); the shader walks
    // a chain topmost first, so a bucket starts at its shallowest layer.
    const layers = world.dense_render.layers.items;
    try std.testing.expectEqual(@as(usize, 3), layers.len);
    const slots = world.dense_layers.items(.gpu_slot);
    const whole = world.buildWindowLayers(0, 3);
    try std.testing.expectEqual(world.gpu_tiles.slotDirectory(slots[layers[2]]), whole.first_directory);
    try std.testing.expectEqual(@as(u32, 3), whole.count);
    const deeper = world.buildWindowLayers(0, 2);
    try std.testing.expectEqual(world.gpu_tiles.slotDirectory(slots[layers[1]]), deeper.first_directory);
    try std.testing.expectEqual(@as(u32, 2), deeper.count);
}

test "submitStaticDenseGeometry marks only the bucket holding the shallowest submitted layer, regardless of where an unrelated interleave point splits the stack" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();

    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const level1 = try world.addLevel(-level_z_step);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    _ = try testSyncGpuTiles(&world, 0);

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
    defer deinitStaticTestRenderer(&renderer);

    // No interleave points this frame: both layers merge into one bucket,
    // which must be marked shallowest (the common case the rim-shadow effect
    // was originally written for).
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try std.testing.expectEqual(@as(usize, 1), renderer.tilemap_window_layers.items.len);
    try std.testing.expect(renderer.tilemap_window_layers.items[0].is_shallowest_bucket);

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

    try std.testing.expectEqual(@as(usize, 2), renderer.tilemap_window_layers.items.len);
    try std.testing.expect(!renderer.tilemap_window_layers.items[0].is_shallowest_bucket);
    try std.testing.expect(renderer.tilemap_window_layers.items[1].is_shallowest_bucket);
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

test "a dense layer added on a resident level enters the GPU tile store at the next sync" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();
    const water = try world.requireTileByName(&meta, "water_1");
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), world.gpu_tiles.residentLayerCount());

    const added = try world.addDenseLayer(0, 0, .obstacle, water);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[added]);
    _ = try world.clearDenseTile(added, 1, 1);
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 1), sync_plan.enter_count);
    try testApplySync(&world, &gpu);
    try std.testing.expect(world.dense_layers.items(.gpu_slot)[added] != world_gpu_tiles.no_slot);
    try std.testing.expectEqual(@as(usize, 2), world.gpu_tiles.residentLayerCount());
    try expectGpuStoreMatches(&world, &gpu);
}

test "a level whose full-level GPU store would overflow u32 is created and renders a window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8192x8192 cells in 16-cell chunks: a whole-level directory set and block per
    // chunk would pass the u32 byte width, a window-sized store does not come near.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8192,
        .height = 8192,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.setDenseTile(layer, 8000, 8000, water);
    try testShowChunks(&world, 499, 499, 2, 2, 0);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    // One directory of side 4 and the one mixed chunk's block.
    try std.testing.expectEqual(world_gpu_tiles.directoryWords(4) + tileStoreBlockElements(16), sync_plan.required_elements);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, layer, 8000, 8000));
}

test "GPU store bytes are the same for the same window at 64 and 512 tiles a side" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var bytes: [2]u64 = undefined;
    for ([_]u16{ 64, 512 }, &bytes) |side, *out| {
        var world = WorldSystem{
            .allocator = std.testing.allocator,
            .width = side,
            .height = side,
            .tile_size = meta.tileSize(),
            .chunk_size_tiles = 16,
            .render_window = .{ .levels_below = 1 },
        };
        defer world.deinit();
        try world.buildCatalog(&meta);
        const grass = try world.requireTileByName(&meta, "grass");
        const water = try world.requireTileByName(&meta, "water_1");
        for (0..3) |level_index| {
            const layer = try world.addDenseLayer(try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step), 0, .floor, grass);
            // Every chunk of the level is mixed.
            for (0..side / 16) |chunk_y| for (0..side / 16) |chunk_x| {
                _ = try world.setDenseTile(layer, @intCast(chunk_x * 16 + 3), @intCast(chunk_y * 16 + 3), water);
            };
        }
        try testShowChunks(&world, 1, 1, 2, 2, 0);
        _ = try testSyncGpuTiles(&world, 0);
        out.* = world.gpu_tiles.residentBytes();
    }
    try std.testing.expectEqual(bytes[0], bytes[1]);
    // Two resident layers: a side-4 directory and four blocks each.
    try std.testing.expectEqual(@as(u64, 2 * (world_gpu_tiles.directoryWords(4) + 4 * tileStoreBlockElements(16)) * 4), bytes[0]);
}

test "GPU residency follows the window and a pan uploads only entering chunks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 32x8 tiles in 4x4 chunks: an 8x2 chunk grid on four levels, two in the window.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 32,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 1 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    var layers: [4]usize = undefined;
    for (&layers, 0..) |*layer, level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        layer.* = try world.addDenseLayer(level, 0, .floor, grass);
        // Every chunk of every level is mixed.
        for (0..8) |chunk_x| for (0..2) |chunk_y| {
            _ = try world.setDenseTile(layer.*, @intCast(chunk_x * 4 + 1), @intCast(chunk_y * 4 + 2), water);
        };
    }
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    const slots = world.dense_layers.items(.gpu_slot);
    const block_elements = tileStoreBlockElements(4);

    // A 2x2 chunk window over levels 0 and 1: two directories and four blocks each;
    // chunks outside the window upload nothing.
    try testShowChunks(&world, 0, 0, 2, 2, 0);
    var sync_plan = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 2), sync_plan.enter_count);
    try std.testing.expectEqual(@as(usize, 2 * (1 + 4)), world.gpu_tiles.spans.items.len);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, slots[layers[2]]);
    try expectGpuStoreMatches(&world, &gpu);

    // A pan inside the same chunks uploads nothing.
    try world.setVisibleChunksForWorldRect(.{ .x = 3, .y = 3, .w = 2 * 4 * world.tile_size - 6, .h = 2 * 4 * world.tile_size - 6 }, 0, 0);
    sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), sync_plan.span_count);

    // A long pan right, one chunk per step: each step uploads the entering column
    // (a word and a block per chunk and layer), frees the leaving column's blocks,
    // and the store's high water stays flat.
    const high_water = world.gpu_tiles.high_water;
    for (1..7) |step| {
        try testShowChunks(&world, @intCast(step), 0, 2, 2, 0);
        sync_plan = try testSyncGpuTiles(&world, 0);
        try testApplySync(&world, &gpu);
        try std.testing.expectEqual(@as(usize, 2 * 2 * 2), world.gpu_tiles.spans.items.len);
        try std.testing.expectEqual(@as(usize, 2 * 2 * (1 + block_elements)), world.gpu_tiles.values.items.len);
        try std.testing.expectEqual(high_water, world.gpu_tiles.high_water);
        try expectGpuStoreMatches(&world, &gpu);
    }

    // Moving down one level: level 0 leaves, level 2 enters, level 1 keeps its
    // directory and rewrites only its link.
    const kept_directory = world.gpu_tiles.slotDirectory(slots[layers[1]]);
    sync_plan = try testSyncGpuTiles(&world, 1);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), sync_plan.enter_count);
    try std.testing.expectEqual(@as(usize, 1), sync_plan.evict_count);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, slots[layers[0]]);
    try std.testing.expectEqual(kept_directory, world.gpu_tiles.slotDirectory(slots[layers[1]]));
    try std.testing.expectEqual(high_water, world.gpu_tiles.high_water);
    try expectGpuStoreMatches(&world, &gpu);
}

test "a window of 80 resident layers composites in one chained draw" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 39 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    var deepest_floor: usize = 0;
    for (0..40) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        deepest_floor = try world.addDenseLayer(level, 0, .floor, grass);
        const obstacle = try world.addDenseLayer(level, 0, .obstacle, water);
        // Holes everywhere but the deepest floor, so (1, 1) composites through all 80.
        _ = try world.clearDenseTile(obstacle, 1, 1);
        if (level_index + 1 < 40) _ = try world.clearDenseTile(deepest_floor, 1, 1);
    }
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 80), world.maxDenseSubmitDrawCount());
    try expectGpuStoreMatches(&world, &gpu);

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
    defer deinitStaticTestRenderer(&renderer);
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try std.testing.expectEqual(@as(usize, 1), renderer.static_groups.items.len);
    const chain = renderer.tilemap_window_layers.items[0];
    try std.testing.expectEqual(@as(u32, 80), chain.count);
    // The draw's chain reaches the deepest floor's tile through 79 holes.
    const mirror = &world.gpu_tiles;
    try std.testing.expectEqual(@as(?TileId, grass), gpu.composite(world.chunkGeometry(), mirror.side, mirror.window, chain.first_directory, chain.count, invalid_tile_id, 1, 1));
    try std.testing.expectEqual(world.dense_layers.items(.gpu_slot)[deepest_floor], mirror.order.items[mirror.order.items.len - 1]);
}

test "a chunk window wider than the largest directory side is clipped to it and syncs" {
    // 40000x1 tiles in 1-tile chunks: a rect over the whole level spans more chunks
    // than any directory side can map. No layer, so no directory is allocated.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 40000,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 1.0e9, .h = 1.0e9 }, 2, 0);
    try std.testing.expectEqual(tile_store_max_side, world.render_side);
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(tile_store_max_side, sync_plan.side);
    try std.testing.expectEqual(tile_store_max_side, world.gpu_tiles.window.width());
    try std.testing.expectEqual(@as(u32, 1), world.gpu_tiles.window.height());
    try std.testing.expect(world.gpu_tiles.window_clip_reported);
    try std.testing.expectEqual(@as(usize, 0), sync_plan.span_count);
}

test "the store width keeps the topmost window layers and reports the drop once" {
    const desired = [_]u32{ 7, 3, 5, 1 };
    var reported = false;
    try std.testing.expectEqualSlices(u32, &desired, WorldSystem.fitResidentLayers(&desired, 9, &reported));
    try std.testing.expect(!reported);
    // Past the fit, the deepest layers drop and the report latches.
    try std.testing.expectEqualSlices(u32, &.{ 7, 3 }, WorldSystem.fitResidentLayers(&desired, 2, &reported));
    try std.testing.expect(reported);
    try std.testing.expectEqualSlices(u32, &.{7}, WorldSystem.fitResidentLayers(&desired, 1, &reported));
    try std.testing.expect(reported);
    try std.testing.expectEqual(@as(usize, 0), WorldSystem.fitResidentLayers(&desired, 0, &reported).len);
}

test "a store created for a sync that never committed gets the whole window at the next sync" {
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
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.setDenseTile(layer, 1, 1, water);
    try testShowChunks(&world, 0, 0, 1, 1, 0);
    world.gpu_tiles.store = .{ .index = 0, .generation = 1 };
    world.gpu_tiles.store_side = world.render_side;
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expect(world.gpu_tiles.layoutMatchesStore());

    // A sync at another side created its store and failed before committing,
    // and the window is back at the old side. The mirror's layout describes the
    // old store, so the next sync lays the window out anew rather than uploading
    // only what changed into an empty store.
    world.gpu_tiles.store = .{ .index = 1, .generation = 1 };
    world.gpu_tiles.store_side = world.render_side * 2;
    try std.testing.expect(!world.gpu_tiles.layoutMatchesStore());
    var fresh = TestGpuStore{};
    defer fresh.deinit();
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expect(sync_plan.relayout);
    try testApplySync(&world, &fresh);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &fresh, layer, 1, 1));
    try expectGpuStoreMatches(&world, &fresh);
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
    try std.testing.expectEqual(@as(u16, 1040), world.visible_max_tile_x_exclusive);
    // A rect ending just past the edge takes the next tile; a tiny rect keeps its tile.
    const past = world.chunkRegionForWorldRect(.{ .x = 32_768, .y = 32_768, .w = 512.01, .h = 1 }, 0).?;
    try std.testing.expectEqual(@as(i32, 66), past.max_exclusive.x);
    const tiny = world.chunkRegionForWorldRect(.{ .x = 33_280, .y = 0, .w = 0.001, .h = 0.001 }, 0).?;
    try std.testing.expectEqual(ChunkCoord{ .x = 65, .y = 0 }, tiny.min);
    try std.testing.expectEqual(ChunkCoord{ .x = 66, .y = 1 }, tiny.max_exclusive);
}

test "the render directory side covers the rect's chunk span plus alignment and overscan, clamped to the grid" {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 2048,
        .height = 512,
        .tile_size = 32,
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    // 1280x720 px over 512 px chunks: 3 chunks wide + 1 for alignment.
    try world.setVisibleChunksForWorldRect(.{ .x = 100, .y = 100, .w = 1280, .h = 720 }, 0, 0);
    try std.testing.expectEqual(@as(u32, 4), world.render_side);
    // One chunk of overscan on each side: 3 + 1 + 2.
    try world.setVisibleChunksForWorldRect(.{ .x = 100, .y = 100, .w = 1280, .h = 720 }, 1, 0);
    try std.testing.expectEqual(@as(u32, 8), world.render_side);
    // A rect wider than the level clamps to the grid's power of two (128 chunks).
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 1.0e9, .h = 1.0e9 }, 3, 0);
    try std.testing.expectEqual(@as(u32, 128), world.render_side);
    // Every window the side covers fits it.
    const region = world.visibleChunkRegion().?;
    try std.testing.expect(region.max_exclusive.x - region.min.x <= 128);
}

test "the window sparse list is the same at 8 and 128 levels for the same window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var lists: [2][3]TestSparseKey = undefined;
    for ([_]u16{ 8, 128 }, &lists) |level_count, *list| {
        var world = WorldSystem{
            .allocator = std.testing.allocator,
            .width = 16,
            .height = 16,
            .tile_size = meta.tileSize(),
            .chunk_size_tiles = 4,
            .render_window = .{ .levels_below = 2 },
        };
        defer world.deinit();
        try world.buildCatalog(&meta);
        const deco = try world.requireTileByName(&meta, "deco_0");
        for (0..level_count) |level_index| {
            const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
            // Two tiles per level, one inside the visible rect and one outside it.
            _ = try world.addSparseTile(level, 1, 1, deco, 0, .obstacle);
            _ = try world.addSparseTile(level, 14, 14, deco, 0, .obstacle);
        }
        try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 4 * meta.tileSize(), .h = 4 * meta.tileSize() }, 0, 3);
        // Levels 3, 4, 5 are in the window: one tile each.
        try std.testing.expectEqual(@as(usize, 3), world.reserveRenderRecords());
        _ = testWindowSparseKeys(&world, list);
    }
    try std.testing.expectEqualSlices(TestSparseKey, &lists[0], &lists[1]);
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

// Brute-force composed blocked bit: OR over every dense layer on the level, then
// every sparse tile on the level at this cell.
fn bruteForceLevelBlocked(world: *const WorldSystem, level: u16, x: u16, y: u16) bool {
    for (0..world.denseLayerCount()) |layer| {
        if (world.denseLayerLevel(layer) != level) continue;
        if (world.flagsFor(world.denseTile(layer, x, y)).blocks_movement) return true;
    }
    for (world.sparseTileIndicesForLevel(level)) |sparse_index| {
        const cell = world.sparseTileCellCoord(sparse_index);
        if (cell.x == x and cell.y == y and world.sparseTileBlocksMovement(sparse_index)) return true;
    }
    return false;
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
        try std.testing.expectEqual(mixed_chunks, store.liveBlockCount());
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
            try std.testing.expectEqual(blocked_cells, terrain.blocked.blockedCount(geom, chunk));
            mixed_chunks += @intFromBool(expected_form == .mixed);
        }
        try std.testing.expectEqual(mixed_chunks, terrain.blocked.liveSlotCount());
    }
}

const TerrainTestTiles = struct {
    grass: TileId,
    dirt: TileId,
    water: TileId,
    cave: TileId,
    tree: TileId,
    deco: TileId,

    fn resolve(world: *const WorldSystem, meta: *const WorldTilesetMeta) !TerrainTestTiles {
        return .{
            .grass = try world.requireTileByName(meta, "grass"),
            .dirt = try world.requireTileByName(meta, "dirt"),
            .water = try world.requireTileByName(meta, "water_1"),
            .cave = try world.requireTileByName(meta, "cave_0"),
            .tree = try world.requireTileByName(meta, "tree_0"),
            .deco = try world.requireTileByName(meta, "deco_0"),
        };
    }
};

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
    const cell_count = world.cellCount();

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
    const cell_count = world.cellCount();
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
        for (0..fills.len) |layer| try std.testing.expectEqual(@as(usize, 0), world.dense_layers.items(.store)[layer].liveBlockCount());
        try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[0].blocked.liveSlotCount());
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
    try std.testing.expectEqual(@as(usize, 0), world.dense_layers.items(.store)[surface].liveBlockCount());
    try std.testing.expectEqual(@as(usize, 0), world.dense_layers.items(.store)[underground].liveBlockCount());
    try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[1].blocked.liveSlotCount());
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
        try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());
        try std.testing.expectEqual(@as(usize, 1), world.level_terrain.items[level].blocked.bits.items.len);
        try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[level].blocked.liveSlotCount());
    }
}

test "terrain pool growth is counted at its reserve seam and pool reuse counts nothing" {
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
    try std.testing.expectEqual(@as(u64, 0), world.terrain_pool_grows);
    try std.testing.expect(!world.terrain_pool_growth_logged);

    // The first carve into the solid level grows the block pool and the bits pool.
    _ = try world.setDenseTile(layer, 1, 1, tiles.cave);
    try std.testing.expectEqual(@as(u64, 2), world.terrain_pool_grows);
    try std.testing.expect(world.terrain_pool_growth_logged);
    // The refill releases both; a carve in another chunk reuses them.
    _ = try world.setDenseTile(layer, 1, 1, tiles.dirt);
    _ = try world.setDenseTile(layer, 5, 5, tiles.cave);
    try std.testing.expectEqual(@as(u64, 2), world.terrain_pool_grows);
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
    try std.testing.expectEqual(@as(u64, 4), world.terrain_pool_grows);
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
    try std.testing.expectEqual(@as(usize, 1), store.liveBlockCount());
    try std.testing.expectEqual(@as(usize, 1), world.level_terrain.items[level].blocked.liveSlotCount());
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
    // A walkable sparse tile warms every sparse list for chunk 0 and leaves it OPEN.
    _ = try world.addSparseTile(level, 0, 0, tiles.grass, 0, .floor);
    try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, world.addSparseTile(level, 1, 1, tiles.deco, 0, .obstacle));
        try std.testing.expectEqual(@as(usize, 1), world.sparse_tiles.len);
        try std.testing.expectEqual(@as(usize, 1), world.sparseTileIndicesForChunk(level, 0).len);
        try std.testing.expectEqual(ChunkForm.open, world.levelChunkBlockedForm(level, 0));
        try std.testing.expect(!world.levelBlocksMovement(level, 1, 1));
    }
    _ = try world.addSparseTile(level, 1, 1, tiles.deco, 0, .obstacle);
    try std.testing.expect(world.levelBlocksMovement(level, 1, 1));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(level, 0));
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
            // At most the two level lists' growth plus the new level's own directory
            // and link heads.
            try std.testing.expect(failing.allocations <= 4);
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
        }
    }
    // An invalid level or chunk yields nothing.
    var missing_level = world.levelChunkLinkEndpoints(3, 0);
    try std.testing.expect(missing_level.next() == null);
    var missing_chunk = world.levelChunkLinkEndpoints(1, @intCast(geom.chunkCount()));
    try std.testing.expect(missing_chunk.next() == null);
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
        for (world.sparseTileIndicesForLevel(0)) |index| blocking_sparse = blocking_sparse or world.sparseTileBlocksMovement(index);
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
    try out.append(allocator, @intFromBool(world.gpu_edits_pending));
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
                const col = local & (geom.edge - 1);
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
        .adaptive = false,
        .items_per_range = 1,
    };
}

fn editRanInline(world: *const WorldSystem) bool {
    return world.last_terrain_edit_plan_batch.ran_inline and world.last_terrain_edit_write_batch.ran_inline;
}

fn editRanThreaded(world: *const WorldSystem) bool {
    return !world.last_terrain_edit_plan_batch.ran_inline and !world.last_terrain_edit_write_batch.ran_inline;
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
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    var threaded_batches: usize = 0;
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
        try std.testing.expect(editRanInline(&serial));
        if (editRanThreaded(&threaded)) threaded_batches += 1;

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
    try std.testing.expect(threaded_batches > 0);
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
        for (writes) |write| _ = try single.writeDenseTileCell(write.layer, write.x, write.y, write.tile);

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
            try std.testing.expectEqual(single_store.liveBlockCount(), batched_store.liveBlockCount());
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
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    var threaded_batches: usize = 0;
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
        for (writes) |write| _ = try single.writeDenseTileCell(write.layer, write.x, write.y, write.tile);
        if (editRanThreaded(&threaded)) threaded_batches += 1;

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
    try std.testing.expect(threaded_batches > 0);
}

test "a batched dense edit over sparse tiles in short border chunks is identical inline, threaded, and as single-cell writes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    var threaded_batches: usize = 0;
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
        for (writes) |write| _ = try single.writeDenseTileCell(write.layer, write.x, write.y, write.tile);
        if (editRanThreaded(&threaded)) threaded_batches += 1;

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
    try std.testing.expect(threaded_batches > 0);
}

test "a batched dense edit marks resident layers identically inline and threaded and the next sync matches the CPU" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    var threaded_batches: usize = 0;
    for (0..20) |_| {
        const writes = randomBatchWrites(prng.random(), tiles, &write_buffer);
        var batch = try ChunkMajorWrites.init(&serial, writes);
        defer batch.deinit();
        events.clearRetainingCapacity();
        try events.ensureTotalCapacity(std.testing.allocator, writes.len);
        try serial.applyDenseCellWrites(batch.chunks.items, null, &events);
        events.clearRetainingCapacity();
        try threaded.applyDenseCellWrites(batch.chunks.items, testEditThreads(&threaded, &threads), &events);
        if (editRanThreaded(&threaded)) threaded_batches += 1;
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
        try std.testing.expect(!serial.gpu_edits_pending and !threaded.gpu_edits_pending);
    }
    try std.testing.expect(threaded_batches > 0);
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
        if (!rendered) world.resetGpuResidency();
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
        try std.testing.expectEqual(rendered, world.gpu_edits_pending);
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
        try std.testing.expect(editRanThreaded(&world));
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
        try std.testing.expect(editRanThreaded(&world));
        try expectTerrainMatchesReference(&world, reference.layers);
        return false;
    }
}

test "a batched dense edit fails cleanly at every allocation on the multi-worker path and its retry lands (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
        try std.testing.expect(editRanThreaded(&world));
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
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    var threaded_batches: usize = 0;
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
        for (writes) |write| _ = try single.writeDenseTileCell(write.layer, write.x, write.y, write.tile);
        if (editRanThreaded(&threaded)) threaded_batches += 1;
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
    try std.testing.expect(threaded_batches > 0);
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
    for (world.dense_layers.items(.store)) |store| try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());
    try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[1].blocked.liveSlotCount());
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
    try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu_store);
    try expectGpuStoreMatches(&world, &gpu_store);
    try std.testing.expectEqual(@as(?TileId, tiles.cave), testGpuTile(&world, &gpu_store, layer, 4, 4));
}

test "a one-chunk batched dense edit runs inline" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    try std.testing.expect(editRanInline(&world));
    try std.testing.expectEqual(@as(usize, 1), world.last_terrain_edit_plan_batch.item_count);
    try std.testing.expectEqual(@as(usize, 1), world.last_terrain_edit_write_batch.item_count);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(world.levelBlocksMovement(0, 2, 1));
}

test "a batched dense edit blocks and reopens a whole short border chunk" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    try std.testing.expect(editRanThreaded(&world));
    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    // Every in-level cell blocked: the corner's slot went back and it reads BLOCKED.
    try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(0, corner));
    try std.testing.expectEqual(ChunkForm.mixed, world.levelChunkBlockedForm(0, 0));
    try std.testing.expectEqual(@as(usize, 1), world.level_terrain.items[0].blocked.liveSlotCount());

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
    try std.testing.expectEqual(@as(usize, 0), world.level_terrain.items[0].blocked.liveSlotCount());
    try std.testing.expectEqual(@as(usize, 0), world.dense_layers.items(.store)[0].liveBlockCount());
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
    const slots_before = world.level_terrain.items[1].blocked.liveSlotCount();
    var events: std.ArrayList(WorldTileChangedEvent) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacity(std.testing.allocator, writes.len);
    try world.applyDenseCellWrites(&chunks, null, &events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    for (world.dense_layers.items(.store)) |store| try std.testing.expectEqual(@as(usize, 0), store.liveBlockCount());
    try std.testing.expectEqual(slots_before, world.level_terrain.items[1].blocked.liveSlotCount());
    try std.testing.expectEqual(ChunkForm.blocked, world.levelChunkBlockedForm(1, 1 * 4 + 1));
    // No cell changed, so no layer is flagged for the GPU sync.
    try std.testing.expect(!world.gpu_edits_pending);
    try std.testing.expect(!world.dense_layers.items(.render_changed)[2]);
}

// Applies `chunks` threaded into `events` with exactly `event_capacity` spare
// slots, expects `expected`, and checks the world, its render flags, and `events`
// are untouched.
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
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
