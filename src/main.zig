// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("assets.zig").AssetStore;
const build_options = @import("build_options");
const config = @import("config.zig");
const DebugOverlay = if (build_options.debug_overlay) @import("debug_overlay.zig").DebugOverlay else @import("debug_overlay_stub.zig").DebugOverlay;
const DemoState = @import("demo_state.zig").DemoState;
const frame_pacer = @import("frame_pacer.zig");
const input_mod = @import("input.zig");
const Action = input_mod.Action;
const FrameCommands = input_mod.FrameCommands;
const InputState = @import("input.zig").InputState;
const PauseController = @import("pause_controller.zig").PauseController;
const PauseState = @import("pause_state.zig").PauseState;
const Renderer = @import("renderer.zig").Renderer;
const state_mod = @import("state.zig");
const State = state_mod.State;
const StateStack = state_mod.StateStack;
const TimeLoop = @import("time_loop.zig").TimeLoop;
const sdl = @import("sdl.zig");
const c = sdl.c;

pub fn main(init: std.process.Init) !void {
    const app_config = config.AppConfig{
        .app_name = build_options.app_name,
        .window_title = build_options.window_title,
        .asset_root = build_options.asset_root,
        .gpu_debug = build_options.gpu_debug,
    };
    const window_title: [:0]const u8 = app_config.window_title ++ "\x00";

    var sdl_context = try sdl.SdlContext.init(c.SDL_INIT_VIDEO);
    defer sdl_context.deinit();

    var window = try sdl.Window.create(
        window_title,
        app_config.logical_width,
        app_config.logical_height,
        if (app_config.resizable) c.SDL_WINDOW_RESIZABLE else 0,
    );
    defer window.deinit();

    const allocator = init.gpa;
    const assets = AssetStore.init(allocator, init.io, app_config.asset_root);
    var renderer = try Renderer.init(allocator, window.handle, assets, app_config);
    defer renderer.deinit();

    var debug_overlay = DebugOverlay.init();
    defer debug_overlay.deinit(&renderer);

    var demo_state = DemoState.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    );
    defer demo_state.deinit();
    var states = StateStack.init(allocator);
    _ = try states.replaceGameplay(State.from(DemoState, &demo_state));

    var pause_state = PauseState.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    );
    defer pause_state.deinit();
    defer states.deinit();
    var pause = PauseController{};

    var input = InputState{};
    var commands = FrameCommands{};
    var time_loop = TimeLoop.init(c.SDL_GetTicksNS());
    var running = true;
    while (running) {
        const frame_start_ns = c.SDL_GetTicksNS();
        commands.beginFrame();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            commands.handleEvent(&event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                else => {},
            }
            if (!pause.isPaused()) {
                input.handleEvent(&event);
            }
            states.handleEvent(&event);
        }
        debug_overlay.applyCommands(&commands);
        if (commands.wasPressed(.quit)) running = false;
        if (!running) break;

        const frame_policy = frame_pacer.windowFramePolicy(window.handle);
        try pause.applyWindowPolicy(frame_policy, &states, &input, &time_loop, &pause_state, c.SDL_GetTicksNS());
        if (!frame_policy.should_pause_gameplay and pause.isPaused() and
            (commands.wasPressed(Action.resumeGame) or commands.wasPressed(Action.pause)))
        {
            pause.exit(&states, &input, &time_loop, c.SDL_GetTicksNS());
        } else if (!frame_policy.should_pause_gameplay and !pause.isPaused() and commands.wasPressed(Action.pause)) {
            try pause.enter(&states, &input, &time_loop, &pause_state, c.SDL_GetTicksNS());
        }

        const frame_time_ns = c.SDL_GetTicksNS();
        const frame_delta_ns = if (frame_time_ns > time_loop.last_time_ns) frame_time_ns - time_loop.last_time_ns else 0;
        time_loop.beginFrame(frame_time_ns);

        while (time_loop.shouldUpdate()) {
            states.update(&input, TimeLoop.fixed_delta_seconds);
            time_loop.finishUpdate();
        }

        if (frame_policy.can_render) {
            renderer.beginFrame(app_config.clear_color);
            try states.render(&renderer, time_loop.interpolationAlpha());
            try debug_overlay.render(&renderer);
            switch (try renderer.endFrame()) {
                .submitted => {
                    try debug_overlay.recordSubmittedFrame(&renderer, frame_delta_ns);
                    if (frame_policy.target_frame_ns) |target_frame_ns| {
                        frame_pacer.paceTargetFrame(frame_start_ns, target_frame_ns);
                    }
                },
                .skipped_no_swapchain => {
                    try pause.enter(&states, &input, &time_loop, &pause_state, c.SDL_GetTicksNS());
                    frame_pacer.paceFallbackFrame(frame_start_ns);
                },
            }
        } else {
            frame_pacer.paceFallbackFrame(frame_start_ns);
        }
    }
}
