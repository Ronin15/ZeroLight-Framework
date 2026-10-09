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

    renderer.beginStaticGeometry();
    try smokeTransferGrowth(&renderer, app_config, init.gpa);
    try smokeTileUploadOom(&renderer, app_config, init.gpa, tile_quad);
}

// Frames uploading a small, a larger, then a small batch: only the larger one
// replaces the pooled transfer, with at least twice its previous size, and the
// small one after it reuses the grown transfer.
fn smokeTransferGrowth(renderer: *Renderer, app_config: config.AppConfig, allocator: std.mem.Allocator) !void {
    const small_elements: u32 = 1;
    const larger_elements: u32 = renderer.tile_upload_transfer_byte_size / @sizeOf(u32) + 1;
    const values = try allocator.alloc(u32, larger_elements);
    defer allocator.free(values);
    @memset(values, tileStoreUniformWord(1));
    const store = try renderer.createTileStore(.{
        .element_capacity = larger_elements,
        .params = smokeTileParams(),
    });
    const grows_before = renderer.tile_upload_transfer_grows;
    const bytes_before = renderer.tile_upload_transfer_byte_size;
    try submitSmokeUploadFrame(renderer, app_config, store, values[0..small_elements], "small transfer upload");
    try submitSmokeUploadFrame(renderer, app_config, store, values, "larger transfer upload");
    try submitSmokeUploadFrame(renderer, app_config, store, values[0..small_elements], "small upload after transfer growth");
    const grows = renderer.tile_upload_transfer_grows - grows_before;
    if (grows != 1) {
        log.err("SDL_GPU smoke tile upload transfer grew {d} times over small/larger/small, expected 1", .{grows});
        return error.TransferGrowthMismatch;
    }
    if (renderer.tile_upload_transfer_byte_size < @as(u64, bytes_before) * 2) {
        log.err("SDL_GPU smoke tile upload transfer grew {d} -> {d} bytes, less than double", .{
            bytes_before,
            renderer.tile_upload_transfer_byte_size,
        });
        return error.TransferGrowthNotGeometric;
    }
    log.info("SDL_GPU smoke tile upload transfer grew once over small/larger/small uploads ({d} -> {d} bytes)", .{
        bytes_before,
        renderer.tile_upload_transfer_byte_size,
    });
}

fn submitSmokeUploadFrame(
    renderer: *Renderer,
    app_config: config.AppConfig,
    store: TileDataId,
    values: []const u32,
    comptime label: []const u8,
) !void {
    if (!renderer.claimTileStore(store)) return error.TileStoreNotLive;
    // Value counts fit u32: the store's capacity bounds them.
    const count: u32 = @intCast(values.len);
    const spans = [_]TileStoreSpan{.{ .dst_element = 0, .count = count }};
    try renderer.reserveTileStoreUploads(store, count, spans.len, values.len);
    try renderer.queueTileStoreUploads(store, &spans, values);
    try submitSmokeFrame(renderer, app_config, label);
}

// Store state an out-of-memory reserve must leave unchanged.
const TileStoreUploadState = struct {
    element_capacity: u32,
    pending_spans: usize,
    pending_values: usize,
    growth_source: ?*c.SDL_GPUBuffer,
};

fn tileStoreUploadState(renderer: *const Renderer, id: TileDataId) TileStoreUploadState {
    const store = renderer.tile_stores.items[id.index];
    return .{
        .element_capacity = store.element_capacity,
        .pending_spans = store.pending_spans.items.len,
        .pending_values = store.pending_values.items.len,
        .growth_source = store.growth_source,
    };
}

// Fails each allocation of a growing reserve folded into a carried batch in turn:
// every OOM leaves the store's capacity, pending batch, and growth source as they
// were, the first success queues without allocating, and the frame draws the store.
fn smokeTileUploadOom(
    renderer: *Renderer,
    app_config: config.AppConfig,
    allocator: std.mem.Allocator,
    quad: VertexColumnsConst,
) !void {
    const store = try renderer.createTileStore(.{
        .element_capacity = smoke_directory_elements,
        .params = smokeTileParams(),
    });
    const batch = smokeTileBatch();
    // A carried batch no frame recorded, so the next reserve also sizes the merge.
    try renderer.reserveTileStoreUploads(store, smoke_directory_elements, 1, smoke_directory_elements);
    try renderer.queueTileStoreUploads(store, batch.spans[0..1], batch.values[0..smoke_directory_elements]);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 64) return error.TileUploadOomSweepDidNotFinish;
        const before = tileStoreUploadState(renderer, store);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        renderer.allocator = failing.allocator();
        defer renderer.allocator = allocator;
        renderer.reserveTileStoreUploads(store, smoke_block + smoke_block_elements, batch.spans.len, batch.values.len) catch |err| switch (err) {
            error.OutOfMemory => {
                if (!std.meta.eql(before, tileStoreUploadState(renderer, store))) {
                    log.err("SDL_GPU smoke tile upload reserve changed the store on OOM at fail index {d}", .{fail_index});
                    return error.TileUploadOomChangedStore;
                }
                continue;
            },
            else => return err,
        };
        const allocations = failing.allocations;
        try renderer.queueTileStoreUploads(store, &batch.spans, &batch.values);
        if (failing.allocations != allocations) {
            log.err("SDL_GPU smoke tile upload queue allocated after its reserve", .{});
            return error.TileUploadQueueAllocated;
        }
        break;
    }
    if (fail_index == 0) {
        log.err("SDL_GPU smoke tile upload reserve never ran out of memory; the sweep checked nothing", .{});
        return error.TileUploadOomSweepVacuous;
    }

    renderer.beginStaticGeometry();
    try appendSmokeTilemap(renderer, quad, store);
    try submitSmokeFrame(renderer, app_config, "tilemap after an OOM-swept growing upload");
    const after = tileStoreUploadState(renderer, store);
    if (after.pending_spans != 0 or after.growth_source != null or !renderer.claimTileStore(store)) {
        log.err("SDL_GPU smoke OOM-swept tile store did not flush and survive its frame", .{});
        return error.TileUploadNotFlushed;
    }
    log.info("SDL_GPU smoke tile upload reserve left the store unchanged on {d} OOM fail indices, then drew", .{fail_index});
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
    const batch = smokeTileBatch();
    const tile_store = try renderer.createTileStore(.{
        .element_capacity = smoke_directory_elements,
        .params = smokeTileParams(),
    });
    try renderer.reserveTileStoreUploads(tile_store, smoke_block + smoke_block_elements, batch.spans.len, batch.values.len);
    try renderer.queueTileStoreUploads(tile_store, &batch.spans, &batch.values);
    return tile_store;
}

const smoke_invalid_tile_id: u16 = 65535;
const smoke_chunk_edge: u16 = 4;
const smoke_block_elements = tileStoreBlockElements(smoke_chunk_edge);
// Directories A (at 0) and B (at 2), one word plus a link each.
const smoke_directory_elements: u32 = 4;
const smoke_block: u32 = smoke_directory_elements;

const SmokeTileBatch = struct {
    spans: [2]TileStoreSpan,
    values: [smoke_directory_elements + smoke_block_elements]u32,
};

fn smokeTileBatch() SmokeTileBatch {
    const directory_b: u32 = 2;
    var block_cells: [smoke_chunk_edge * smoke_chunk_edge]u16 = @splat(1);
    block_cells[0] = smoke_invalid_tile_id;
    var batch: SmokeTileBatch = .{
        .spans = .{
            .{ .dst_element = 0, .count = smoke_directory_elements },
            .{ .dst_element = smoke_block, .count = smoke_block_elements },
        },
        .values = undefined,
    };
    batch.values[0] = smoke_block; // A: chunk (0, 0) is mixed
    batch.values[1] = directory_b; // A's link
    batch.values[2] = tileStoreUniformWord(1); // B: chunk (0, 0) is uniform
    batch.values[3] = tile_store_no_link; // B is the deepest
    packTileData(&block_cells, batch.values[smoke_directory_elements..]);
    return batch;
}

fn smokeTileParams() TilemapParams {
    var tile_params = TilemapParams{
        .grid = .{ 16.0, 3.0, 1.0, @floatFromInt(smoke_invalid_tile_id) },
        .atlas = .{ 1.0, 1.0, 1.0, 16.0 },
        .window = .{ 0, 0, 1, 1 },
    };
    tile_params.layer_meta[2] = @ctz(smoke_chunk_edge);
    tile_params.layer_meta[3] = 1;
    return tile_params;
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
