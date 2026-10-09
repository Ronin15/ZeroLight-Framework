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
const tile_store_no_link = @import("../render/renderer.zig").tile_store_no_link;
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const tileStoreUniformWord = @import("../render/renderer.zig").tileStoreUniformWord;
const Position = @import("../render/renderer.zig").Position;
const Uv = @import("../render/renderer.zig").Uv;
const VertexColor = @import("../render/renderer.zig").VertexColor;
const VertexColumnsConst = @import("../render/renderer.zig").VertexColumnsConst;
const writeWorldSpriteQuad = @import("../render/renderer.zig").writeWorldSpriteQuad;
const TextureDesc = @import("../render/resources.zig").TextureDesc;
const TileDataId = @import("../render/resources.zig").TileDataId;
const nextGeneration = @import("../render/resources.zig").nextGeneration;
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

    const tile_store = try createSmokeTileStore(&renderer);

    // Sprite submit is reserve-first for allocation-free frames (see
    // Renderer.reserveSpriteCommands). The capacity is grow-only and survives
    // `beginFrame` below. Without it the first rect still works: `drawSprite`
    // grows the command list and `ensureFrameBatchCapacity` grows the
    // prepared/vertex storage and GPU streams.
    try renderer.reserveSpriteCommands(1);

    try renderer.reserveStaticGeometry(12, 2);
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
    const tile_quad = VertexColumnsConst{ .positions = &tile_positions, .uvs = &tile_uvs, .colors = &tile_colors };
    renderer.beginStaticGeometry();
    try appendSmokeTilemap(&renderer, tile_quad, tile_store);

    // Frame A claims store A and draws it. Frame B does not claim it, so its
    // `endFrame` retires the store first (no device drain; SDL frees the buffer
    // after frame A completes) and the retained draw naming it is skipped.
    if (!renderer.claimTileStore(tile_store)) return error.TileStoreNotLive;
    try submitSmokeFrame(&renderer, app_config, "sprite and tilemap on store A");
    try submitSmokeFrame(&renderer, app_config, "sprite after store A sweep");
    if (renderer.claimTileStore(tile_store)) {
        log.err("SDL_GPU smoke tile store survived a frame without a claim", .{});
        return error.TileStoreNotSwept;
    }

    // Frame C: store B takes A's slot under the next generation. A draw re-pointed
    // to B draws; a draw still naming A resolves to no store and is skipped.
    const replacement = try createSmokeTileStore(&renderer);
    if (replacement.index != tile_store.index or replacement.generation != nextGeneration(tile_store.generation)) {
        log.err("SDL_GPU smoke tile store slot was not reused under a new generation", .{});
        return error.TileStoreSlotNotReused;
    }
    renderer.beginStaticGeometry();
    try appendSmokeTilemap(&renderer, tile_quad, tile_store);
    try appendSmokeTilemap(&renderer, tile_quad, replacement);
    try submitSmokeFrame(&renderer, app_config, "tilemap on store B beside a stale draw on store A");
    if (!renderer.claimTileStore(replacement)) {
        log.err("SDL_GPU smoke replacement tile store did not survive its first frame", .{});
        return error.TileStoreNotLive;
    }

    // Frame D: a side-2 directory over three chunks with the window on chunks 1
    // and 2. Chunk 2 wraps onto word 0 and chunk 0, outside the window, discards.
    const wrap_store = try createSmokeWrapTileStore(&renderer);
    var wrap_positions: [6]Position = undefined;
    var wrap_uvs: [6]Uv = undefined;
    var wrap_colors: [6]VertexColor = undefined;
    writeWorldSpriteQuad(.{
        .texture = renderer.white_texture,
        .source = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .dest = .{ .x = 0, .y = 0, .w = 192, .h = 64 },
    }, TextureDesc{ .width = 1, .height = 1 }, .{
        .positions = &wrap_positions,
        .uvs = &wrap_uvs,
        .colors = &wrap_colors,
    });
    renderer.beginStaticGeometry();
    try renderer.appendStaticTilemapSpan(
        renderer.white_texture,
        RenderOrder.world(@backingInt(SmokeDepth.test_tilemap)),
        .{ .positions = &wrap_positions, .uvs = &wrap_uvs, .colors = &wrap_colors },
        wrap_store,
        .{ .first_directory = 0, .count = 1 },
    );
    try submitSmokeFrame(&renderer, app_config, "tilemap with a wrapped toroidal word and a discarded chunk");
    if (!renderer.claimTileStore(wrap_store)) {
        log.err("SDL_GPU smoke wrap tile store did not survive its first frame", .{});
        return error.TileStoreNotLive;
    }
}

// A 3x1 grid in one 4x4-cell chunk, two chained layers in a tile store of
// directory side 1 with the window over chunk (0, 0): directory A at 0 holds the
// chunk's block (at 4, one dug hole, invalid_tile_id) and links to directory B at
// 2, a uniform chunk with no link. This exercises the fragment shader's toroidal
// lookup on both word kinds, the window check, and the chain walk end to end: the
// hole falls through from A's block to B's uniform word. The store starts at 4
// elements, so queueing the block grows it: the frame copy pass copies the old
// buffer's contents forward around the uploaded spans.
fn createSmokeTileStore(renderer: *Renderer) !TileDataId {
    const invalid_tile_id: u16 = 65535;
    const chunk_edge: u16 = 4;
    const block_elements = comptime tileStoreBlockElements(chunk_edge);
    const directory_a: u32 = 0;
    const directory_b: u32 = 2;
    const block: u32 = 4;
    var block_cells: [chunk_edge * chunk_edge]u16 = @splat(1);
    block_cells[0] = invalid_tile_id;
    var values: [4 + block_elements]u32 = undefined;
    values[0] = block; // A: chunk (0, 0) is mixed
    values[1] = directory_b; // A's link
    values[2] = tileStoreUniformWord(1); // B: chunk (0, 0) is uniform
    values[3] = tile_store_no_link; // B is the deepest
    packTileData(&block_cells, values[4..]);
    const spans = [_]TileStoreSpan{
        .{ .dst_element = directory_a, .count = 4 },
        .{ .dst_element = block, .count = block_elements },
    };
    var tile_params = TilemapParams{
        .grid = .{ 16.0, 3.0, 1.0, @floatFromInt(invalid_tile_id) },
        .atlas = .{ 1.0, 1.0, 1.0, 16.0 },
        .window = .{ 0, 0, 1, 1 },
    };
    tile_params.layer_meta[2] = @ctz(chunk_edge);
    tile_params.layer_meta[3] = 1;
    const tile_store = try renderer.createTileStore(.{
        .element_capacity = 4,
        .params = tile_params,
    });
    try renderer.reserveTileStoreUploads(tile_store, block + block_elements, spans.len, values.len);
    try renderer.queueTileStoreUploads(tile_store, &spans, &values);
    return tile_store;
}

// A 12x4 grid in three 4x4-cell chunks, one layer in a directory of side 2 at 0
// with the window over chunks 1 and 2: chunk 1 at word 1 is uniform, chunk 2 wraps
// to word 0 and holds a block at 5 with one hole; chunk 0 also maps to word 0 but
// lies outside the window, so its pixels discard instead of reading chunk 2's block.
fn createSmokeWrapTileStore(renderer: *Renderer) !TileDataId {
    const invalid_tile_id: u16 = 65535;
    const chunk_edge: u16 = 4;
    const block_elements = comptime tileStoreBlockElements(chunk_edge);
    const block: u32 = 5;
    var block_cells: [chunk_edge * chunk_edge]u16 = @splat(1);
    block_cells[5] = invalid_tile_id;
    var values: [5 + block_elements]u32 = undefined;
    values[0] = block; // chunks 0 and 2: chunk 2's block
    values[1] = tileStoreUniformWord(1); // chunk 1
    values[2] = tileStoreUniformWord(invalid_tile_id); // unused row
    values[3] = tileStoreUniformWord(invalid_tile_id);
    values[4] = tile_store_no_link;
    packTileData(&block_cells, values[5..]);
    const spans = [_]TileStoreSpan{
        .{ .dst_element = 0, .count = 5 },
        .{ .dst_element = block, .count = block_elements },
    };
    var tile_params = TilemapParams{
        .grid = .{ 16.0, 12.0, 4.0, @floatFromInt(invalid_tile_id) },
        .atlas = .{ 1.0, 1.0, 1.0, 16.0 },
        .window = .{ 1, 0, 3, 1 },
    };
    tile_params.layer_meta[2] = @ctz(chunk_edge);
    tile_params.layer_meta[3] = 2;
    const tile_store = try renderer.createTileStore(.{
        .element_capacity = block + block_elements,
        .params = tile_params,
    });
    try renderer.reserveTileStoreUploads(tile_store, block + block_elements, spans.len, values.len);
    try renderer.queueTileStoreUploads(tile_store, &spans, &values);
    return tile_store;
}

// Appends one retained tilemap draw over `quad` reading `tile_store`: the chain
// from directory A (the holed layer) through B (the solid layer).
fn appendSmokeTilemap(renderer: *Renderer, quad: VertexColumnsConst, tile_store: TileDataId) !void {
    try renderer.appendStaticTilemapSpan(
        renderer.white_texture,
        RenderOrder.world(@backingInt(SmokeDepth.test_tilemap)),
        quad,
        tile_store,
        .{ .first_directory = 0, .count = 2 },
    );
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
