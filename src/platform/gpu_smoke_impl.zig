// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const config = @import("../config.zig");
const Renderer = @import("../render/renderer.zig").Renderer;
const sdl = @import("sdl.zig");
const c = sdl.c;

pub fn main(init: std.process.Init) !void {
    var sdl_context = try sdl.SdlContext.init(c.SDL_INIT_VIDEO);
    defer sdl_context.deinit();

    var window = try sdl.Window.create("SDL_GPU Smoke", 320, 180, 0);
    defer window.deinit();

    const app_config = config.AppConfig{
        .app_name = "gpu-smoke",
        .window_title = "SDL_GPU Smoke",
        .gpu_debug = true,
    };
    const assets = AssetStore.init(init.gpa, init.io, app_config.asset_root);

    var renderer = try Renderer.init(init.gpa, window.handle, assets, app_config);
    defer renderer.deinit();

    renderer.beginFrame(app_config.clear_color);
    try renderer.drawRect(.{ .x = 32, .y = 32, .w = 64, .h = 64 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 0);
    switch (try renderer.endFrame()) {
        .submitted => {},
        .skipped_no_swapchain => return error.NoSwapchain,
    }
}
