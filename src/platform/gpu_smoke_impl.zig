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
const Position = @import("../render/renderer.zig").Position;
const Uv = @import("../render/renderer.zig").Uv;
const VertexColor = @import("../render/renderer.zig").VertexColor;
const writeWorldSpriteQuad = @import("../render/renderer.zig").writeWorldSpriteQuad;
const TextureDesc = @import("../render/resources.zig").TextureDesc;
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

    const tiles = [_]u32{ 1, 1, 1, 1 };
    const tile_params = TilemapParams{
        .grid = .{ 16.0, 2.0, 2.0, 65535.0 },
        .atlas = .{ 1.0, 1.0, 1.0, 16.0 },
    };
    const tile_data = try renderer.createTileDataBuffer(&tiles, tile_params);

    try renderer.reserveStaticGeometry(6, 1);
    renderer.beginStaticGeometry();
    var tile_positions: [6]Position = undefined;
    var tile_uvs: [6]Uv = undefined;
    var tile_colors: [6]VertexColor = undefined;
    writeWorldSpriteQuad(.{
        .texture = renderer.white_texture,
        .source = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .dest = .{ .x = 0, .y = 0, .w = 32, .h = 32 },
    }, TextureDesc{ .width = 1, .height = 1 }, .{
        .positions = &tile_positions,
        .uvs = &tile_uvs,
        .colors = &tile_colors,
    });
    try renderer.appendStaticTilemapSpan(
        renderer.white_texture,
        RenderOrder.world(@intFromEnum(SmokeDepth.test_tilemap)),
        .{ .positions = &tile_positions, .uvs = &tile_uvs, .colors = &tile_colors },
        tile_data,
    );

    renderer.beginFrame(app_config.clear_color);
    try renderer.submitOrderedRectInSpace(
        .{ .x = 96, .y = 32, .w = 64, .h = 64 },
        .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        RenderOrder.world(@intFromEnum(SmokeDepth.test_rect)),
        .world,
    );
    switch (try renderer.endFrame(null)) {
        .submitted => log.debug("SDL_GPU smoke submitted sprite and tilemap frame", .{}),
        .skipped_no_swapchain => {
            log.err("SDL_GPU smoke could not acquire a swapchain texture", .{});
            return error.NoSwapchain;
        },
    }
}
