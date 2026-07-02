// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AudioCommandBuffer = @import("audio.zig").AudioCommandBuffer;
const AudioService = @import("audio.zig").AudioService;
const AssetCache = @import("../assets/cache.zig").AssetCache;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const build_options = @import("build_options");
const config = @import("../config.zig");
const DebugOverlay = if (build_options.debug_overlay) @import("../render/debug_overlay.zig").DebugOverlay else @import("../render/debug_overlay_stub.zig").DebugOverlay;
const GameDemoState = @import("../game/game_demo_state.zig").GameDemoState;
const MainMenuState = @import("../game/main_menu_state.zig").MainMenuState;
const SettingsMenuState = @import("../game/settings_menu_state.zig").SettingsMenuState;
const frame_pacer = @import("frame_pacer.zig");
const input_router = @import("input_router.zig");
const log = @import("../core/logging.zig").app;
const Action = @import("input.zig").Action;
const FrameCommands = @import("input.zig").FrameCommands;
const InputState = @import("input.zig").InputState;
const PauseController = @import("pause_controller.zig").PauseController;
const PauseState = @import("../game/pause_state.zig").PauseState;
const Renderer = @import("../render/renderer.zig").Renderer;
const FrameResult = @import("../render/renderer.zig").FrameResult;
const SpritePrepStats = @import("../render/renderer.zig").SpritePrepStats;
const resolution = @import("resolution.zig");
const runtime_perf_log = @import("runtime_perf_log.zig");
const RenderContext = @import("state.zig").RenderContext;
const State = @import("state.zig").State;
const StateStack = @import("state.zig").StateStack;
const StateTransitions = @import("state.zig").StateTransitions;
const state_policy = @import("state.zig").state_policy;
const TextService = @import("../render/text.zig").TextService;
const UpdateContext = @import("state.zig").UpdateContext;
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
    audio_service: AudioService,
    audio_commands: AudioCommandBuffer,
    renderer: Renderer,
    asset_cache: AssetCache,
    runtime_assets: RuntimeAssets,
    text_service: TextService,
    debug_overlay: DebugOverlay,
    states: StateStack,
    transitions: StateTransitions,
    thread_system: ThreadSystem,
    perf_log: runtime_perf_log.RuntimePerfLog,
    pause: PauseController,
    input: InputState = .{},
    commands: FrameCommands = .{},
    running: bool = true,
    swapchain_blocked: bool = false,

    pub fn init(process_init: std.process.Init, app_config: config.AppConfig) !Engine {
        validateConfig(app_config) catch |err| {
            logInvalidConfig(app_config, err);
            return err;
        };

        const allocator = process_init.gpa;
        const window_title = try allocator.dupeZ(u8, app_config.window_title);
        defer allocator.free(window_title);

        const sdl_flags = c.SDL_INIT_VIDEO | if (app_config.audio.enabled) c.SDL_INIT_AUDIO else 0;
        var sdl_context = try sdl.SdlContext.init(sdl_flags);
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
        var audio_service = try AudioService.init(allocator, assets, app_config.audio);
        errdefer audio_service.deinit();
        var audio_commands = AudioCommandBuffer.init(allocator, app_config.audio.max_commands_per_step);
        errdefer audio_commands.deinit();
        try audio_commands.reserve();

        var renderer = try Renderer.init(allocator, window.handle, assets, app_config);
        errdefer renderer.deinit();
        var asset_cache = AssetCache.init(allocator, assets);
        errdefer asset_cache.deinit(&renderer);

        var runtime_assets = RuntimeAssets.init(allocator);
        try runtime_assets.preload(assets, &asset_cache, &renderer, &audio_service);
        errdefer runtime_assets.deinit(&asset_cache, &renderer);

        var text_service = try TextService.init(allocator, assets);
        errdefer text_service.deinit(&renderer);

        // DebugOverlay/FpsCounter must capture only a FontId from text_service, not
        // a *TextService: Engine is returned by value below, so the address of this
        // local would dangle. Per-frame use takes &self.text_service explicitly.
        var debug_overlay = DebugOverlay.init(&text_service);
        errdefer debug_overlay.deinit();

        var states = StateStack.init(allocator);
        errdefer states.deinit();
        try bootstrapStartupState(&states, allocator, app_config);

        var transitions = StateTransitions.init(allocator);
        errdefer transitions.deinit();
        try transitions.reserve(StateTransitions.default_capacity);

        var thread_system = try ThreadSystem.init(allocator, process_init.io, app_config.threading);
        errdefer thread_system.deinit();

        log.debug(
            "engine initialized: app=\"{s}\" logical={}x{} scale_mode={s} asset_root=\"{s}\" resizable={} high_pixel_density={} gpu_debug={} debug_overlay={} audio_enabled={} worker_threads={}",
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
                app_config.audio.enabled,
                thread_system.workerThreadCount(),
            },
        );

        return .{
            .allocator = allocator,
            .app_config = app_config,
            .sdl_context = sdl_context,
            .window = window,
            .assets = assets,
            .audio_service = audio_service,
            .audio_commands = audio_commands,
            .renderer = renderer,
            .asset_cache = asset_cache,
            .runtime_assets = runtime_assets,
            .text_service = text_service,
            .debug_overlay = debug_overlay,
            .states = states,
            .transitions = transitions,
            .thread_system = thread_system,
            .perf_log = runtime_perf_log.RuntimePerfLog.init(if (comptime runtime_perf_log.enabled) c.SDL_GetTicksNS() else 0),
            .pause = PauseController.init(
                @floatFromInt(logical_size.width),
                @floatFromInt(logical_size.height),
            ),
        };
    }

    pub fn deinit(self: *Engine) void {
        // Tear states (and any pending transition payloads) down before the thread
        // system so a state that drains or awaits worker work in its deinit still
        // has a live pool to do it against.
        self.transitions.deinit();
        self.states.deinit();
        self.thread_system.deinit();
        self.debug_overlay.deinit();
        self.text_service.deinit(&self.renderer);
        self.runtime_assets.deinit(&self.asset_cache, &self.renderer);
        self.asset_cache.deinit(&self.renderer);
        self.renderer.deinit();
        self.audio_commands.deinit();
        self.audio_service.deinit();
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
        const perf_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        var event_count: u64 = 0;
        var event: c.SDL_Event = undefined;
        // State transitions queued by handleEvent are deferred until applyTransitions
        // below, so the active stack (and thus the routing policy) cannot change mid
        // batch. Compute the policy once rather than per polled event.
        const routing_policy = self.states.inputRoutingPolicy();
        while (c.SDL_PollEvent(&event)) {
            if (comptime runtime_perf_log.enabled) {
                event_count += 1;
                self.recordPresentationEventMetrics(event.type);
            }
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    log.debug("quit requested by SDL event", .{});
                    self.running = false;
                },
                else => {},
            }
            const consumed = try self.states.handleEvent(&event, &self.transitions);
            if (!consumed) {
                input_router.routeEvent(routing_policy, &event, &self.input, &self.commands);
            }
        }
        try self.applyTransitions();

        self.debug_overlay.applyCommands(&self.commands);
        if (self.commands.wasPressed(.quit)) {
            log.debug("quit requested by input command", .{});
            self.running = false;
        }
        if (comptime runtime_perf_log.enabled) {
            self.perf_log.recordMetric(.sdl_events, event_count);
            self.perf_log.recordTiming(.events, elapsedNs(perf_start_ns, self.nowNs()));
        }
    }

    pub fn framePolicy(self: *const Engine) frame_pacer.FramePolicy {
        const policy = frame_pacer.windowFramePolicy(self.window.handle);
        if (self.swapchain_blocked) return frame_pacer.gameplayBlockedPolicy(policy);
        return policy;
    }

    pub fn applyFrameControls(
        self: *Engine,
        frame_policy: frame_pacer.FramePolicy,
        time_loop: *TimeLoop,
    ) !void {
        const perf_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        defer if (comptime runtime_perf_log.enabled) {
            self.perf_log.recordTiming(.frame_controls, elapsedNs(perf_start_ns, self.nowNs()));
        };

        const was_paused = self.pause.isPaused();
        if (frame_policy.should_pause_gameplay and !self.pause.isPaused() and self.states.isGameplayActive()) {
            log.debug("pausing gameplay while window cannot render", .{});
        }
        try self.pause.applyWindowPolicy(frame_policy, &self.states, &self.input, time_loop, self.nowNs());
        if (!frame_policy.should_pause_gameplay and self.pause.isPaused() and
            (self.commands.wasPressed(Action.resumeGame) or self.commands.wasPressed(Action.pause)))
        {
            log.debug("resuming gameplay by input command", .{});
            self.pause.exit(&self.states, &self.input, time_loop, self.nowNs());
        } else if (!frame_policy.should_pause_gameplay and !self.pause.isPaused() and self.commands.wasPressed(Action.pause) and self.states.isGameplayActive()) {
            log.debug("pausing gameplay by input command", .{});
            try self.pause.enterUser(&self.states, &self.input, time_loop, self.nowNs());
        }
        const is_paused = self.pause.isPaused();
        if (was_paused != is_paused) {
            self.audio_service.setPaused(is_paused);
        }
    }

    pub fn update(self: *Engine, delta_seconds: f32) !void {
        const perf_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        const perf_context = if (comptime runtime_perf_log.enabled) runtime_perf_log.Context.bind(&self.perf_log) else runtime_perf_log.Context{};
        self.audio_commands.beginStep();
        const perf_state_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        try self.states.update(UpdateContext{
            .input = &self.input,
            .audio = &self.audio_commands,
            .runtime_assets = &self.runtime_assets,
            .delta_seconds = delta_seconds,
            .transitions = &self.transitions,
            .thread_system = &self.thread_system,
            .perf = perf_context,
        });
        const perf_transition_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        if (comptime runtime_perf_log.enabled) {
            self.perf_log.recordTiming(.state_update, elapsedNs(perf_state_start_ns, perf_transition_start_ns));
        }
        try self.applyTransitions();
        const perf_audio_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        if (comptime runtime_perf_log.enabled) {
            self.perf_log.recordTiming(.state_transitions, elapsedNs(perf_transition_start_ns, perf_audio_start_ns));
        }
        self.audio_service.drain(&self.audio_commands);
        if (comptime runtime_perf_log.enabled) {
            const perf_end_ns = self.nowNs();
            self.perf_log.recordTiming(.audio_drain, elapsedNs(perf_audio_start_ns, perf_end_ns));
            self.perf_log.recordTiming(.app_tick, elapsedNs(perf_start_ns, perf_end_ns));
        }
    }

    pub fn renderFrame(
        self: *Engine,
        frame_policy: frame_pacer.FramePolicy,
        interpolation_alpha: f32,
        frame_start_ns: u64,
        frame_delta_ns: u64,
        time_loop: *TimeLoop,
    ) !void {
        const perf_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
        var perf_result: runtime_perf_log.FrameResult = undefined;
        var perf_sprite_prep: SpritePrepStats = undefined;
        if (comptime runtime_perf_log.enabled) {
            perf_result = .no_render;
            perf_sprite_prep = .{};
        }
        const perf_context = if (comptime runtime_perf_log.enabled) runtime_perf_log.Context.bind(&self.perf_log) else runtime_perf_log.Context{};
        if (frame_policy.can_render) {
            if (self.swapchain_blocked) {
                const perf_end_frame_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
                const frame_result = try self.renderer.submitSwapchainRecoveryFrame(self.app_config.clear_color);
                if (comptime runtime_perf_log.enabled) {
                    self.perf_log.recordTiming(.render_end_frame, elapsedNs(perf_end_frame_start_ns, self.nowNs()));
                }
                self.finishRenderedFrame(frame_result, SpritePrepStats{}, frame_policy, frame_start_ns, frame_delta_ns, perf_start_ns, time_loop, &perf_result, &perf_sprite_prep);
            } else {
                self.renderer.beginFrame(self.app_config.clear_color);
                const perf_enqueue_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
                try self.states.render(RenderContext{
                    .renderer = &self.renderer,
                    .runtime_assets = &self.runtime_assets,
                    .text_service = &self.text_service,
                    .interpolation_alpha = interpolation_alpha,
                    .thread_system = &self.thread_system,
                    .perf = perf_context,
                });
                if (comptime runtime_perf_log.enabled) {
                    self.perf_log.recordTiming(.render_enqueue, elapsedNs(perf_enqueue_start_ns, self.nowNs()));
                }
                // Gameplay states reserve stacked UI headroom; this grows for the
                // debug overlay after all stacked states finish enqueue.
                try self.renderer.reserveSpriteCommands(
                    self.renderer.spriteCommandCount() + Renderer.kOverlayCommandHeadroom,
                );
                const perf_overlay_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
                try self.debug_overlay.prepareForRender(&self.text_service, &self.renderer);
                try self.debug_overlay.render(&self.renderer);
                if (comptime runtime_perf_log.enabled) {
                    self.perf_log.recordTiming(.render_overlay, elapsedNs(perf_overlay_start_ns, self.nowNs()));
                }
                const perf_end_frame_start_ns = if (comptime runtime_perf_log.enabled) self.nowNs() else 0;
                const frame_result = try self.renderer.endFrame(&self.thread_system);
                if (comptime runtime_perf_log.enabled) {
                    self.perf_log.recordTiming(.render_end_frame, elapsedNs(perf_end_frame_start_ns, self.nowNs()));
                }
                const sprite_prep = if (comptime runtime_perf_log.enabled) self.renderer.spritePrepStats() else SpritePrepStats{};
                self.finishRenderedFrame(frame_result, sprite_prep, frame_policy, frame_start_ns, frame_delta_ns, perf_start_ns, time_loop, &perf_result, &perf_sprite_prep);
            }
        } else {
            if (comptime runtime_perf_log.enabled) {
                self.perf_log.recordTiming(.render_total, elapsedNs(perf_start_ns, self.nowNs()));
            }
            frame_pacer.paceFallbackFrame(frame_start_ns);
        }
        if (comptime runtime_perf_log.enabled) {
            self.perf_log.recordFrame(self.nowNs(), .{
                .frame_delta_ns = frame_delta_ns,
                .fixed_updates = time_loop.updates_this_frame,
                .hit_update_cap = time_loop.hit_update_cap,
                .result = perf_result,
                .sprite_prep = perf_sprite_prep,
            });
        }
    }

    /// Shared post-`endFrame` handling for both the normal and swapchain-recovery
    /// render paths: records perf, clears or sets the render-blocked pause, and
    /// paces the frame. `sprite_prep` is the prep stats to record on this path
    /// (empty for the recovery frame).
    fn finishRenderedFrame(
        self: *Engine,
        frame_result: FrameResult,
        sprite_prep: SpritePrepStats,
        frame_policy: frame_pacer.FramePolicy,
        frame_start_ns: u64,
        frame_delta_ns: u64,
        perf_start_ns: u64,
        time_loop: *TimeLoop,
        perf_result: *runtime_perf_log.FrameResult,
        perf_sprite_prep: *SpritePrepStats,
    ) void {
        switch (frame_result) {
            .submitted => {
                if (comptime runtime_perf_log.enabled) {
                    perf_result.* = .submitted;
                    perf_sprite_prep.* = sprite_prep;
                }
                if (self.swapchain_blocked) {
                    log.debug("swapchain available again; clearing render-blocked gameplay pause", .{});
                }
                self.swapchain_blocked = false;
                self.debug_overlay.recordSubmittedFrame(frame_delta_ns);
                if (comptime runtime_perf_log.enabled) {
                    self.perf_log.recordTiming(.render_total, elapsedNs(perf_start_ns, self.nowNs()));
                }
                if (frame_policy.target_frame_ns) |target_frame_ns| {
                    frame_pacer.paceTargetFrame(frame_start_ns, target_frame_ns);
                }
            },
            .skipped_no_swapchain => {
                if (comptime runtime_perf_log.enabled) {
                    perf_result.* = .skipped_no_swapchain;
                    perf_sprite_prep.* = sprite_prep;
                }
                self.swapchain_blocked = true;
                if (self.states.isGameplayActive()) {
                    if (!self.pause.isPaused()) {
                        log.debug("swapchain unavailable; pausing gameplay and using fallback pacing", .{});
                    }
                    // Entering the policy pause allocates a PauseState. This frame
                    // is already degraded (no swapchain); if the allocation fails,
                    // log and keep running on fallback pacing rather than aborting
                    // the loop — the next frame retries the pause.
                    self.pause.enterPolicy(&self.states, &self.input, time_loop, self.nowNs()) catch |err| {
                        log.warn("could not enter swapchain-loss pause policy: {s}", .{@errorName(err)});
                    };
                }
                if (comptime runtime_perf_log.enabled) {
                    self.perf_log.recordTiming(.render_total, elapsedNs(perf_start_ns, self.nowNs()));
                }
                frame_pacer.paceFallbackFrame(frame_start_ns);
            },
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
        self.audio_service.setPaused(self.pause.isPaused());
    }

    fn recordPresentationEventMetrics(self: *Engine, event_type: u32) void {
        if (!isPresentationEvent(event_type)) return;

        self.perf_log.recordMetric(.sdl_presentation_events, 1);
        switch (event_type) {
            c.SDL_EVENT_WINDOW_RESIZED,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            c.SDL_EVENT_WINDOW_METAL_VIEW_RESIZED,
            => self.perf_log.recordMetric(.sdl_window_resize_events, 1),

            c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN,
            c.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN,
            => self.perf_log.recordMetric(.sdl_window_fullscreen_events, 1),

            c.SDL_EVENT_WINDOW_DISPLAY_CHANGED,
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
            c.SDL_EVENT_DISPLAY_ORIENTATION,
            c.SDL_EVENT_DISPLAY_ADDED,
            c.SDL_EVENT_DISPLAY_REMOVED,
            c.SDL_EVENT_DISPLAY_MOVED,
            c.SDL_EVENT_DISPLAY_DESKTOP_MODE_CHANGED,
            c.SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED,
            c.SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED,
            c.SDL_EVENT_DISPLAY_USABLE_BOUNDS_CHANGED,
            => self.perf_log.recordMetric(.sdl_window_display_events, 1),

            c.SDL_EVENT_WINDOW_FOCUS_GAINED,
            c.SDL_EVENT_WINDOW_FOCUS_LOST,
            => self.perf_log.recordMetric(.sdl_window_focus_events, 1),

            c.SDL_EVENT_WINDOW_SHOWN,
            c.SDL_EVENT_WINDOW_HIDDEN,
            c.SDL_EVENT_WINDOW_EXPOSED,
            c.SDL_EVENT_WINDOW_MINIMIZED,
            c.SDL_EVENT_WINDOW_MAXIMIZED,
            c.SDL_EVENT_WINDOW_RESTORED,
            c.SDL_EVENT_WINDOW_OCCLUDED,
            => self.perf_log.recordMetric(.sdl_window_visibility_events, 1),

            c.SDL_EVENT_WINDOW_MOVED,
            => self.perf_log.recordMetric(.sdl_window_move_events, 1),

            else => {},
        }
    }
};

fn validateConfig(app_config: config.AppConfig) !void {
    try app_config.validate();
}

fn isPresentationEvent(event_type: u32) bool {
    return (event_type >= c.SDL_EVENT_WINDOW_FIRST and event_type <= c.SDL_EVENT_WINDOW_LAST) or
        (event_type >= c.SDL_EVENT_DISPLAY_FIRST and event_type <= c.SDL_EVENT_DISPLAY_LAST);
}

fn elapsedNs(start_ns: u64, end_ns: u64) u64 {
    return if (end_ns > start_ns) end_ns - start_ns else 0;
}

fn logInvalidConfig(app_config: config.AppConfig, err: anyerror) void {
    switch (err) {
        error.InvalidLogicalSize => log.err(
            "logical resolution must be nonzero, got {}x{}",
            .{ app_config.resolution_policy.logical_size.width, app_config.resolution_policy.logical_size.height },
        ),
        error.InvalidAssetRoot => log.err(
            "asset_root must be a non-empty, traversal-safe relative path, got \"{s}\"",
            .{app_config.asset_root},
        ),
        error.InvalidConfig => log.err(
            "frames_in_flight must be between 1 and 3, got {}",
            .{app_config.frames_in_flight},
        ),
        error.InvalidAudioConfig => log.err(
            "invalid audio config: tracks={} commands={} master_gain={} sfx_gain={} music_gain={} paused_music_gain={} spatial_units_per_meter={}",
            .{
                app_config.audio.max_sfx_tracks,
                app_config.audio.max_commands_per_step,
                app_config.audio.master_gain,
                app_config.audio.sfx_gain,
                app_config.audio.music_gain,
                app_config.audio.paused_music_gain,
                app_config.audio.spatial_units_per_meter,
            },
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
    // Main menu is the default startup state; gameplay is launched from it.
    const menu_ptr = try allocator.create(MainMenuState);
    var owned_by_state = false;
    errdefer if (!owned_by_state) allocator.destroy(menu_ptr);
    menu_ptr.* = MainMenuState.init(
        allocator,
        @floatFromInt(logical_size.width),
        @floatFromInt(logical_size.height),
        app_config.audio,
    );

    const state = State.fromOwnedPtr(MainMenuState, menu_ptr);
    owned_by_state = true;
    _ = try states.replaceOwnedState(state, state_policy.opaque_screen);
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

test "presentation timing classifier recognizes window and display event ranges" {
    try std.testing.expect(isPresentationEvent(c.SDL_EVENT_WINDOW_RESIZED));
    try std.testing.expect(isPresentationEvent(c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN));
    try std.testing.expect(isPresentationEvent(c.SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED));
    try std.testing.expect(!isPresentationEvent(c.SDL_EVENT_QUIT));
}
