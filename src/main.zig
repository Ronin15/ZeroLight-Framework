// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("assets.zig").AssetStore;
const build_options = @import("build_options");
const config = @import("config.zig");
const DemoScene = @import("demo_scene.zig").DemoScene;
const frame_pacer = @import("frame_pacer.zig");
const InputState = @import("input.zig").InputState;
const Renderer = @import("renderer.zig").Renderer;
const Scene = @import("scene.zig").Scene;
const SceneStack = @import("scene.zig").SceneStack;
const TimeLoop = @import("time_loop.zig").TimeLoop;
const c = @import("sdl.zig").c;

pub fn main(init: std.process.Init) !void {
    const app_config = config.AppConfig{
        .app_name = build_options.app_name,
        .window_title = build_options.window_title,
        .asset_root = build_options.asset_root,
        .gpu_debug = build_options.gpu_debug,
    };
    const window_title = app_config.window_title ++ "\x00";

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        return sdlError("SDL_Init");
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        window_title.ptr,
        @intCast(app_config.logical_width),
        @intCast(app_config.logical_height),
        if (app_config.resizable) c.SDL_WINDOW_RESIZABLE else 0,
    ) orelse {
        return sdlError("SDL_CreateWindow");
    };
    defer c.SDL_DestroyWindow(window);

    const allocator = init.gpa;
    const assets = AssetStore.init(allocator, init.io, app_config.asset_root);
    var renderer = try Renderer.init(allocator, window, assets, app_config);
    defer renderer.deinit();

    var demo_scene = DemoScene.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    );
    var scenes = SceneStack.init(allocator);
    try scenes.replace(Scene.from(DemoScene, &demo_scene));
    defer scenes.deinit();

    var input = InputState{};
    var time_loop = TimeLoop.init(c.SDL_GetTicksNS());
    var running = true;
    while (running) {
        const fallback_frame_start_ns = c.SDL_GetTicksNS();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_ESCAPE) {
                        running = false;
                    }
                    input.handleEvent(&event);
                    scenes.handleEvent(&event);
                },
                c.SDL_EVENT_KEY_UP => {
                    input.handleEvent(&event);
                    scenes.handleEvent(&event);
                },
                else => scenes.handleEvent(&event),
            }
        }
        if (!running) break;

        const should_render = frame_pacer.windowCanRender(window);
        const frame_started = if (should_render) try renderer.beginFrame(app_config.clear_color) else false;

        time_loop.beginFrame(c.SDL_GetTicksNS());

        while (time_loop.shouldUpdate()) {
            scenes.update(&input, TimeLoop.fixed_delta_seconds);
            time_loop.finishUpdate();
        }

        if (frame_started) {
            try scenes.render(&renderer, time_loop.interpolationAlpha());
            try renderer.endFrame();
        } else {
            frame_pacer.paceFallbackFrame(fallback_frame_start_ns);
        }
    }
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    std.log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.SdlError;
}
