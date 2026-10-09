// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const build_options = @import("build_options");
const config = @import("../config.zig");
const log = @import("../core/logging.zig").platform;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const Renderer = @import("../render/renderer.zig").Renderer;
const TilemapParams = @import("../render/renderer.zig").TilemapParams;
const TileStoreSpan = @import("../render/renderer.zig").TileStoreSpan;
const packTileData = @import("../render/renderer.zig").packTileData;
const tile_store_directory_slots = @import("../render/renderer.zig").tile_store_directory_slots;
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const tileStoreUniformWord = @import("../render/renderer.zig").tileStoreUniformWord;
const TilemapWindowLayers = Renderer.TilemapWindowLayers;
const Position = @import("../render/renderer.zig").Position;
const Uv = @import("../render/renderer.zig").Uv;
const VertexColor = @import("../render/renderer.zig").VertexColor;
const writeWorldSpriteQuad = @import("../render/renderer.zig").writeWorldSpriteQuad;
const TextureDesc = @import("../render/resources.zig").TextureDesc;
const TileDataId = @import("../render/resources.zig").TileDataId;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const sdl = @import("sdl.zig");
const c = sdl.c;

const SmokeDepth = enum(i32) {
    test_rect,
    test_tilemap,
};

pub fn main(init: std.process.Init) !void {
    var sdl_context = try sdl.SdlContext.init(c.SDL_INIT_VIDEO);
    defer sdl_context.deinit();

    const app_config = config.AppConfig{
        .app_name = "gpu-smoke",
        .window_title = "SDL_GPU Smoke",
        .asset_root = build_options.asset_root,
        .gpu_debug = true,
    };
    try app_config.validate();
    var window = try sdl.Window.create(
        "SDL_GPU Smoke",
        320,
        180,
        sdl.composeWindowFlags(app_config.resizable, app_config.high_pixel_density),
    );
    defer window.deinit();
    const assets = AssetStore.init(init.gpa, init.io, app_config.asset_root);

    var renderer = try Renderer.init(init.gpa, window.handle, assets, app_config);
    defer renderer.deinit();

    // A 3x1 grid in one 4x4-cell chunk, two layers in directory slots 0 and 1 of a
    // tile store: the topmost layer is a mixed chunk (a block with one dug hole,
    // invalid_tile_id) and the layer beneath it a uniform chunk. This exercises the
    // fragment shader's directory lookup on both word kinds and its multi-layer
    // compositing loop end to end: the hole falls through from a block read in
    // slot 0 to a uniform word in slot 1. The store starts with no block room, so
    // queueing the block grows it: the frame copy pass copies the old buffer's
    // unwritten directory words forward around the two uploaded ones.
    const invalid_tile_id: u16 = 65535;
    const chunk_edge: u16 = 4;
    const block_elements = comptime tileStoreBlockElements(chunk_edge);
    const directory_elements: u32 = tile_store_directory_slots;
    var block_cells: [chunk_edge * chunk_edge]u16 = @splat(1);
    block_cells[0] = invalid_tile_id;
    var values: [2 + block_elements]u32 = undefined;
    values[0] = 0; // slot 0: block 0
    values[1] = tileStoreUniformWord(1); // slot 1: uniform
    packTileData(&block_cells, values[2..]);
    const spans = [_]TileStoreSpan{
        .{ .dst_element = 0, .count = 2 },
        .{ .dst_element = directory_elements, .count = block_elements },
    };
    var tile_params = TilemapParams{
        .grid = .{ 16.0, 3.0, 1.0, @floatFromInt(invalid_tile_id) },
        .atlas = .{ 1.0, 1.0, 1.0, 16.0 },
    };
    tile_params.layer_meta[2] = @ctz(chunk_edge);
    tile_params.layer_meta[3] = 1;
    const tile_store = try renderer.createTileStore(.{
        .directory_elements = directory_elements,
        .block_elements = block_elements,
        .element_capacity = directory_elements,
        .params = tile_params,
    });
    try renderer.reserveTileStoreUploads(tile_store, directory_elements + block_elements, spans.len, values.len);
    try renderer.queueTileStoreUploads(tile_store, &spans, &values);

    // Sprite submit is reserve-first for allocation-free frames (see
    // Renderer.reserveSpriteCommands). The capacity is grow-only and survives
    // `beginFrame` below. Without it the first rect still works: `drawSprite`
    // grows the command list and `ensureFrameBatchCapacity` grows the
    // prepared/vertex storage and GPU streams.
    try renderer.reserveSpriteCommands(1);

    try renderer.reserveStaticGeometry(6, 1);
    renderer.beginStaticGeometry();
    var tile_positions: [6]Position = undefined;
    var tile_uvs: [6]Uv = undefined;
    var tile_colors: [6]VertexColor = undefined;
    writeWorldSpriteQuad(.{
        .texture = renderer.white_texture,
        .source = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .dest = .{ .x = 0, .y = 0, .w = 48, .h = 16 },
    }, TextureDesc{ .width = 1, .height = 1 }, .{
        .positions = &tile_positions,
        .uvs = &tile_uvs,
        .colors = &tile_colors,
    });
    // Topmost-first directory offsets (slot * chunks per level): the holed layer in
    // slot 0, the solid layer in slot 1.
    var window_layers = TilemapWindowLayers{};
    window_layers.count = 2;
    window_layers.offsets[0] = 0;
    window_layers.offsets[1] = 1;
    try renderer.appendStaticTilemapSpan(
        renderer.white_texture,
        RenderOrder.world(@backingInt(SmokeDepth.test_tilemap)),
        .{ .positions = &tile_positions, .uvs = &tile_uvs, .colors = &tile_colors },
        tile_store,
        window_layers,
    );

    // Frame 1 claims the store and draws it. Frame 2 does not claim it, so its
    // `endFrame` retires the store (no device drain; SDL frees the buffer after
    // frame 1 completes), the retained tilemap draw resolves to nothing and is
    // skipped, and the id is stale afterwards.
    if (!renderer.claimTileStore(tile_store)) return error.TileStoreNotLive;
    try submitSmokeFrame(&renderer, app_config, "sprite and tilemap");
    try submitSmokeFrame(&renderer, app_config, "sprite after tile store sweep");
    if (renderer.claimTileStore(tile_store)) {
        log.err("SDL_GPU smoke tile store survived a frame without a claim", .{});
        return error.TileStoreNotSwept;
    }
    try smokeWorldTileStoreAcrossHiddenFrame(init.gpa, &renderer, app_config, assets);
}

// A world renders, is hidden for one frame (no sync, so its store is swept), and
// renders again: its next sync creates a new store and the re-submitted static
// tilemap draws name that store, which draws live.
fn smokeWorldTileStoreAcrossHiddenFrame(
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    app_config: config.AppConfig,
    assets: AssetStore,
) !void {
    var meta = try world_tileset_meta.load(allocator, assets, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 96, 64);
    defer world.deinit();
    // A blank texture at the atlas size stands in for the tileset; the smoke checks
    // store lifetime, not tile art.
    const atlas = meta.atlas();
    const pixels = try allocator.alloc(u8, @as(usize, atlas.width) * atlas.height * 4);
    defer allocator.free(pixels);
    @memset(pixels, 255);
    const atlas_texture = try renderer.createTextureFromPixels(pixels, atlas.width, atlas.height, @as(usize, atlas.width) * 4);
    var runtime_assets = RuntimeAssets.init(allocator);
    runtime_assets.sprite_slots[manifest.spriteIndex(.world_tileset)] = .{ .status = .available, .lease = .{ .id = atlas_texture } };

    const first = try submitWorldSmokeFrame(renderer, app_config, &world, &runtime_assets);
    try submitSmokeFrame(renderer, app_config, "world hidden");
    if (renderer.claimTileStore(first)) return error.TileStoreNotSwept;
    const second = try submitWorldSmokeFrame(renderer, app_config, &world, &runtime_assets);
    if (first.index == second.index and first.generation == second.generation) return error.TileStoreNotRecreated;
}

// One frame drawing `world`; returns its store after checking every static tilemap
// draw names it and it is live.
fn submitWorldSmokeFrame(
    renderer: *Renderer,
    app_config: config.AppConfig,
    world: *WorldSystem,
    runtime_assets: *const RuntimeAssets,
) !TileDataId {
    renderer.beginFrame(app_config.clear_color);
    try world.syncDenseTileStore(renderer, 0);
    try world.submitStaticDenseGeometry(renderer, runtime_assets, 0, &.{});
    const store = world.gpu_tiles.store;
    var tilemap_draws: usize = 0;
    for (renderer.static_groups.items) |group| {
        if (group.material != .tilemap) continue;
        tilemap_draws += 1;
        if (group.tile_data.index != store.index or group.tile_data.generation != store.generation) {
            log.err("SDL_GPU smoke static tilemap draw names a stale tile store", .{});
            return error.StaleTileStoreDraw;
        }
    }
    if (tilemap_draws == 0) return error.NoWorldTilemapDraw;
    if (!renderer.claimTileStore(store)) return error.TileStoreNotLive;
    switch (try renderer.endFrame(null)) {
        .submitted => log.debug("SDL_GPU smoke submitted world frame on tile store {d}:{d}", .{ store.index, store.generation }),
        .skipped_no_swapchain => {
            log.err("SDL_GPU smoke could not acquire a swapchain texture", .{});
            return error.NoSwapchain;
        },
    }
    return store;
}

fn submitSmokeFrame(renderer: *Renderer, app_config: config.AppConfig, comptime label: []const u8) !void {
    renderer.beginFrame(app_config.clear_color);
    try renderer.submitOrderedRectInSpace(
        .{ .x = 96, .y = 32, .w = 64, .h = 64 },
        .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        RenderOrder.world(@backingInt(SmokeDepth.test_rect)),
        .world,
    );
    switch (try renderer.endFrame(null)) {
        .submitted => log.debug("SDL_GPU smoke submitted " ++ label ++ " frame", .{}),
        .skipped_no_swapchain => {
            log.err("SDL_GPU smoke could not acquire a swapchain texture", .{});
            return error.NoSwapchain;
        },
    }
}
