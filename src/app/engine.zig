// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const build_options = @import("build_options");
const config = @import("../config.zig");
const DebugOverlay = if (build_options.debug_overlay) @import("../render/debug_overlay.zig").DebugOverlay else @import("../render/debug_overlay_stub.zig").DebugOverlay;
const DemoState = @import("../game/demo_state.zig").DemoState;
const frame_pacer = @import("frame_pacer.zig");
const input_mod = @import("input.zig");
const Action = input_mod.Action;
const FrameCommands = input_mod.FrameCommands;
const InputState = input_mod.InputState;
const PauseController = @import("pause_controller.zig").PauseController;
const PauseState = @import("../game/pause_state.zig").PauseState;
const Renderer = @import("../render/renderer.zig").Renderer;
const state_mod = @import("state.zig");
const StateStack = state_mod.StateStack;
const StateTransitions = state_mod.StateTransitions;
const TimeLoop = @import("time_loop.zig").TimeLoop;
const sdl = @import("../platform/sdl.zig");
const c = sdl.c;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    app_config: config.AppConfig,
    sdl_context: sdl.SdlContext,
    window: sdl.Window,
    assets: AssetStore,
    renderer: Renderer,
    debug_overlay: DebugOverlay,
    states: StateStack,
    transitions: StateTransitions,
    pause: PauseController,
    input: InputState = .{},
    commands: FrameCommands = .{},
    running: bool = true,

    pub fn init(process_init: std.process.Init, app_config: config.AppConfig) !Engine {
        const allocator = process_init.gpa;
        const window_title = try allocator.dupeZ(u8, app_config.window_title);
        defer allocator.free(window_title);

        var sdl_context = try sdl.SdlContext.init(c.SDL_INIT_VIDEO);
        errdefer sdl_context.deinit();

        var window = try sdl.Window.create(
            window_title,
            app_config.logical_width,
            app_config.logical_height,
            if (app_config.resizable) c.SDL_WINDOW_RESIZABLE else 0,
        );
        errdefer window.deinit();

        const assets = AssetStore.init(allocator, process_init.io, app_config.asset_root);
        var renderer = try Renderer.init(allocator, window.handle, assets, app_config);
        errdefer renderer.deinit();

        var debug_overlay = DebugOverlay.init();
        errdefer debug_overlay.deinit(&renderer);

        var states = StateStack.init(allocator);
        errdefer states.deinit();
        try bootstrapStartupState(&states, app_config);

        var transitions = StateTransitions.init(allocator);
        errdefer transitions.deinit();

        return .{
            .allocator = allocator,
            .app_config = app_config,
            .sdl_context = sdl_context,
            .window = window,
            .assets = assets,
            .renderer = renderer,
            .debug_overlay = debug_overlay,
            .states = states,
            .transitions = transitions,
            .pause = PauseController.init(
                @floatFromInt(app_config.logical_width),
                @floatFromInt(app_config.logical_height),
            ),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.transitions.deinit();
        self.states.deinit();
        self.debug_overlay.deinit(&self.renderer);
        self.renderer.deinit();
        self.window.deinit();
        self.sdl_context.deinit();
    }

    pub fn isRunning(self: *const Engine) bool {
        return self.running;
    }

    pub fn nowNs(self: *const Engine) u64 {
        _ = self;
        return c.SDL_GetTicksNS();
    }

    pub fn beginFrame(self: *Engine) u64 {
        const frame_start_ns = self.nowNs();
        self.commands.beginFrame();
        return frame_start_ns;
    }

    pub fn handleEvents(self: *Engine) !void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            self.commands.handleEvent(&event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => self.running = false,
                else => {},
            }
            if (!self.pause.isPaused()) {
                self.input.handleEvent(&event);
            }
            try self.states.handleEvent(&event, &self.transitions);
            try self.applyTransitions();
        }

        self.debug_overlay.applyCommands(&self.commands);
        if (self.commands.wasPressed(.quit)) self.running = false;
    }

    pub fn framePolicy(self: *const Engine) frame_pacer.FramePolicy {
        return frame_pacer.windowFramePolicy(self.window.handle);
    }

    pub fn applyFrameControls(
        self: *Engine,
        frame_policy: frame_pacer.FramePolicy,
        time_loop: *TimeLoop,
    ) !void {
        try self.pause.applyWindowPolicy(frame_policy, &self.states, &self.input, time_loop, self.nowNs());
        if (!frame_policy.should_pause_gameplay and self.pause.isPaused() and
            (self.commands.wasPressed(Action.resumeGame) or self.commands.wasPressed(Action.pause)))
        {
            self.pause.exit(&self.states, &self.input, time_loop, self.nowNs());
        } else if (!frame_policy.should_pause_gameplay and !self.pause.isPaused() and self.commands.wasPressed(Action.pause)) {
            try self.pause.enter(&self.states, &self.input, time_loop, self.nowNs());
        }
    }

    pub fn update(self: *Engine, delta_seconds: f32) !void {
        try self.states.update(&self.input, delta_seconds, &self.transitions);
        try self.applyTransitions();
    }

    pub fn renderFrame(
        self: *Engine,
        frame_policy: frame_pacer.FramePolicy,
        interpolation_alpha: f32,
        frame_start_ns: u64,
        frame_delta_ns: u64,
        time_loop: *TimeLoop,
    ) !void {
        if (frame_policy.can_render) {
            self.renderer.beginFrame(self.app_config.clear_color);
            try self.states.render(&self.renderer, interpolation_alpha);
            try self.debug_overlay.render(&self.renderer);
            switch (try self.renderer.endFrame()) {
                .submitted => {
                    try self.debug_overlay.recordSubmittedFrame(&self.renderer, frame_delta_ns);
                    if (frame_policy.target_frame_ns) |target_frame_ns| {
                        frame_pacer.paceTargetFrame(frame_start_ns, target_frame_ns);
                    }
                },
                .skipped_no_swapchain => {
                    try self.pause.enter(&self.states, &self.input, time_loop, self.nowNs());
                    frame_pacer.paceFallbackFrame(frame_start_ns);
                },
            }
        } else {
            frame_pacer.paceFallbackFrame(frame_start_ns);
        }
    }

    fn applyTransitions(self: *Engine) !void {
        const result = try self.states.applyTransitions(&self.transitions);
        if (result.quit_requested) {
            self.running = false;
        }
    }
};

fn bootstrapStartupState(states: *StateStack, app_config: config.AppConfig) !void {
    // DemoState is the template startup state until a real MainMenuState exists.
    _ = try states.replaceGameplay(DemoState, DemoState.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    ));
}
