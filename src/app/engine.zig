// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetCache = @import("../assets/cache.zig").AssetCache;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const build_options = @import("build_options");
const config = @import("../config.zig");
const DebugOverlay = if (build_options.debug_overlay) @import("../render/debug_overlay.zig").DebugOverlay else @import("../render/debug_overlay_stub.zig").DebugOverlay;
const GameDemoState = @import("../game/game_demo_state.zig").GameDemoState;
const frame_pacer = @import("frame_pacer.zig");
const input_mod = @import("input.zig");
const input_router = @import("input_router.zig");
const log = @import("../core/logging.zig").app;
const Action = input_mod.Action;
const FrameCommands = input_mod.FrameCommands;
const InputState = input_mod.InputState;
const PauseController = @import("pause_controller.zig").PauseController;
const PauseState = @import("../game/pause_state.zig").PauseState;
const Renderer = @import("../render/renderer.zig").Renderer;
const resolution = @import("resolution.zig");
const state_mod = @import("state.zig");
const RenderContext = state_mod.RenderContext;
const State = state_mod.State;
const StateStack = state_mod.StateStack;
const StateTransitions = state_mod.StateTransitions;
const TextService = @import("../render/text.zig").TextService;
const UpdateContext = state_mod.UpdateContext;
const ThreadSystem = @import("thread_system.zig").ThreadSystem;
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
    asset_cache: AssetCache,
    text_service: TextService,
    debug_overlay: DebugOverlay,
    states: StateStack,
    transitions: StateTransitions,
    thread_system: ThreadSystem,
    pause: PauseController,
    input: InputState = .{},
    commands: FrameCommands = .{},
    running: bool = true,

    pub fn init(process_init: std.process.Init, app_config: config.AppConfig) !Engine {
        validateConfig(app_config) catch |err| {
            logInvalidConfig(app_config, err);
            return err;
        };

        const allocator = process_init.gpa;
        const window_title = try allocator.dupeZ(u8, app_config.window_title);
        defer allocator.free(window_title);

        var sdl_context = try sdl.SdlContext.init(c.SDL_INIT_VIDEO);
        errdefer sdl_context.deinit();

        const logical_size = app_config.resolution_policy.logical_size;
        var window = try sdl.Window.create(
            window_title,
            logical_size.width,
            logical_size.height,
            sdl.composeWindowFlags(app_config.resizable, app_config.high_pixel_density),
        );
        errdefer window.deinit();
        if (minimumWindowSizeForPolicy(app_config.resolution_policy)) |minimum_size| {
            try window.setMinimumSize(minimum_size.width, minimum_size.height);
        }

        const assets = AssetStore.init(allocator, process_init.io, app_config.asset_root);
        var renderer = try Renderer.init(allocator, window.handle, assets, app_config);
        errdefer renderer.deinit();
        var asset_cache = AssetCache.init(allocator, assets);
        errdefer asset_cache.deinit(&renderer);

        var text_service = try TextService.init(allocator, assets);
        errdefer text_service.deinit(&renderer);

        var debug_overlay = DebugOverlay.init(&text_service);
        errdefer debug_overlay.deinit();

        var states = StateStack.init(allocator);
        errdefer states.deinit();
        try bootstrapStartupState(&states, allocator, app_config);

        var transitions = StateTransitions.init(allocator);
        errdefer transitions.deinit();

        var thread_system = try ThreadSystem.init(allocator, process_init.io, app_config.threading);
        errdefer thread_system.deinit();

        log.debug(
            "engine initialized: app=\"{s}\" logical={}x{} scale_mode={s} asset_root=\"{s}\" resizable={} high_pixel_density={} gpu_debug={} debug_overlay={} worker_threads={}",
            .{
                app_config.app_name,
                logical_size.width,
                logical_size.height,
                @tagName(app_config.resolution_policy.scale_mode),
                app_config.asset_root,
                app_config.resizable,
                app_config.high_pixel_density,
                app_config.gpu_debug,
                build_options.debug_overlay,
                thread_system.workerThreadCount(),
            },
        );

        return .{
            .allocator = allocator,
            .app_config = app_config,
            .sdl_context = sdl_context,
            .window = window,
            .assets = assets,
            .renderer = renderer,
            .asset_cache = asset_cache,
            .text_service = text_service,
            .debug_overlay = debug_overlay,
            .states = states,
            .transitions = transitions,
            .thread_system = thread_system,
            .pause = PauseController.init(
                @floatFromInt(logical_size.width),
                @floatFromInt(logical_size.height),
            ),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.thread_system.deinit();
        self.transitions.deinit();
        self.states.deinit();
        self.debug_overlay.deinit();
        self.text_service.deinit(&self.renderer);
        self.asset_cache.deinit(&self.renderer);
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
            input_router.routeEvent(self.states.inputRoutingPolicy(), &event, &self.input, &self.commands);
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    log.debug("quit requested by SDL event", .{});
                    self.running = false;
                },
                else => {},
            }
            try self.states.handleEvent(&event, &self.transitions);
            try self.applyTransitions();
        }

        self.debug_overlay.applyCommands(&self.commands);
        if (self.commands.wasPressed(.quit)) {
            log.debug("quit requested by input command", .{});
            self.running = false;
        }
    }

    pub fn framePolicy(self: *const Engine) frame_pacer.FramePolicy {
        return frame_pacer.windowFramePolicy(self.window.handle);
    }

    pub fn applyFrameControls(
        self: *Engine,
        frame_policy: frame_pacer.FramePolicy,
        time_loop: *TimeLoop,
    ) !void {
        if (frame_policy.should_pause_gameplay and !self.pause.isPaused()) {
            log.debug("pausing gameplay while window cannot render", .{});
        }
        try self.pause.applyWindowPolicy(frame_policy, &self.states, &self.input, time_loop, self.nowNs());
        if (!frame_policy.should_pause_gameplay and self.pause.isPaused() and
            (self.commands.wasPressed(Action.resumeGame) or self.commands.wasPressed(Action.pause)))
        {
            log.debug("resuming gameplay by input command", .{});
            self.pause.exit(&self.states, &self.input, time_loop, self.nowNs());
        } else if (!frame_policy.should_pause_gameplay and !self.pause.isPaused() and self.commands.wasPressed(Action.pause)) {
            log.debug("pausing gameplay by input command", .{});
            try self.pause.enter(&self.states, &self.input, time_loop, self.nowNs());
        }
    }

    pub fn update(self: *Engine, delta_seconds: f32) !void {
        try self.states.update(UpdateContext{
            .input = &self.input,
            .delta_seconds = delta_seconds,
            .transitions = &self.transitions,
            .thread_system = &self.thread_system,
        });
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
            try self.states.render(RenderContext{
                .renderer = &self.renderer,
                .asset_cache = &self.asset_cache,
                .text_service = &self.text_service,
                .interpolation_alpha = interpolation_alpha,
                .thread_system = &self.thread_system,
            });
            try self.debug_overlay.render(&self.renderer);
            switch (try self.renderer.endFrame()) {
                .submitted => {
                    try self.debug_overlay.recordSubmittedFrame(&self.text_service, &self.renderer, frame_delta_ns);
                    if (frame_policy.target_frame_ns) |target_frame_ns| {
                        frame_pacer.paceTargetFrame(frame_start_ns, target_frame_ns);
                    }
                },
                .skipped_no_swapchain => {
                    if (!self.pause.isPaused()) {
                        log.debug("swapchain unavailable; pausing gameplay and using fallback pacing", .{});
                    }
                    try self.pause.enter(&self.states, &self.input, time_loop, self.nowNs());
                    frame_pacer.paceFallbackFrame(frame_start_ns);
                },
            }
        } else {
            frame_pacer.paceFallbackFrame(frame_start_ns);
        }
    }

    fn applyTransitions(self: *Engine) !void {
        const previous_routing = self.states.inputRoutingPolicy();
        const result = try self.states.applyTransitions(&self.transitions);
        self.pause.reconcileWithStateStack(&self.states);
        const current_routing = self.states.inputRoutingPolicy();
        if (previous_routing.allowsContext(.gameplay) and !current_routing.allowsContext(.gameplay)) {
            log.debug("releasing held gameplay input because active state routing blocks gameplay", .{});
            self.input.releaseMovement();
        }
        if (result.quit_requested) {
            log.debug("quit requested by state transition", .{});
            self.running = false;
        }
    }
};

fn validateConfig(app_config: config.AppConfig) !void {
    try app_config.validate();
}

fn logInvalidConfig(app_config: config.AppConfig, err: anyerror) void {
    switch (err) {
        error.InvalidLogicalSize => log.err(
            "logical resolution must be nonzero, got {}x{}",
            .{ app_config.resolution_policy.logical_size.width, app_config.resolution_policy.logical_size.height },
        ),
        error.InvalidConfig => log.err(
            "frames_in_flight must be between 1 and 3, got {}",
            .{app_config.frames_in_flight},
        ),
        else => {},
    }
}

fn minimumWindowSizeForPolicy(policy: resolution.ResolutionPolicy) ?resolution.LogicalSize {
    return switch (policy.scale_mode) {
        .integer_fit => policy.logical_size,
        .fit, .stretch, .overscan => null,
    };
}

fn bootstrapStartupState(states: *StateStack, allocator: std.mem.Allocator, app_config: config.AppConfig) !void {
    const logical_size = app_config.resolution_policy.logical_size;
    // GameDemoState is the startup state until a real MainMenuState exists.
    const game_demo_state_ptr = try allocator.create(GameDemoState);
    var owned_by_state = false;
    errdefer if (!owned_by_state) allocator.destroy(game_demo_state_ptr);
    game_demo_state_ptr.* = try GameDemoState.init(
        allocator,
        @floatFromInt(logical_size.width),
        @floatFromInt(logical_size.height),
    );

    const state = State.fromOwnedPtr(GameDemoState, game_demo_state_ptr);
    owned_by_state = true;
    _ = try states.replaceOwnedGameplay(state);
}

test "integer fit requests logical minimum window size" {
    const minimum_size = minimumWindowSizeForPolicy(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .integer_fit,
    }).?;

    try std.testing.expectEqual(@as(u32, 1280), minimum_size.width);
    try std.testing.expectEqual(@as(u32, 720), minimum_size.height);
}

test "non integer fit policies do not request minimum window size" {
    try std.testing.expectEqual(@as(?resolution.LogicalSize, null), minimumWindowSizeForPolicy(.{ .scale_mode = .fit }));
    try std.testing.expectEqual(@as(?resolution.LogicalSize, null), minimumWindowSizeForPolicy(.{ .scale_mode = .stretch }));
    try std.testing.expectEqual(@as(?resolution.LogicalSize, null), minimumWindowSizeForPolicy(.{ .scale_mode = .overscan }));
}
