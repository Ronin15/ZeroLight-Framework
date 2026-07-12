// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Opaque loading screen for constructing gameplay states from Engine-owned
//! runtime catalogs without letting menus or gameplay states own app services.

const std = @import("std");
const GameDemoState = @import("game_demo_state.zig").GameDemoState;
const WorldBuildConfig = @import("world_system.zig").WorldBuildConfig;
const RuntimeAudioSettings = @import("settings_menu_state.zig").RuntimeAudioSettings;
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const inputFile = @import("../app/input.zig");
const RenderContext = @import("../app/state.zig").RenderContext;
const State = @import("../app/state.zig").State;
const StateStack = @import("../app/state.zig").StateStack;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const state_policy = @import("../app/state.zig").state_policy;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const manifest = @import("../assets/manifest.zig");
const sprite_atlas_meta = @import("../assets/sprite_atlas_meta.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const Renderer = @import("../render/renderer.zig").Renderer;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const TextureId = @import("../render/resources.zig").TextureId;
const TextService = @import("../render/text.zig").TextService;
const PreparedText = @import("../render/text.zig").PreparedText;
const text = @import("../render/text.zig");
const log = @import("../core/logging.zig").game;
const c = @import("../platform/sdl.zig").c;

pub const LoadTarget = enum {
    game_demo,
};

const LoadingPhase = enum {
    pending,
    complete,
    failed,
};

pub const LoadingState = struct {
    allocator: std.mem.Allocator,
    target: LoadTarget,
    width: f32,
    height: f32,
    world_build_config: WorldBuildConfig,
    /// Snapshot of the launching menu's volumes so a failed load can rebuild
    /// `MainMenuState` with the same settings after this state is replaced away.
    audio_settings: RuntimeAudioSettings,
    phase: LoadingPhase = .pending,
    title_text: PreparedText = .invalid,
    status_text: PreparedText = .invalid,
    text_dirty: bool = true,
    /// Latched only after a full loading frame successfully prepares status text
    /// and draws, so a failed first-frame prepare cannot unlock world build.
    rendered_once: bool = false,
    /// Logs the first build failure only; subsequent update ticks stay quiet.
    failure_logged: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        target: LoadTarget,
        width: f32,
        height: f32,
        world_build_config: WorldBuildConfig,
        audio_settings: RuntimeAudioSettings,
    ) LoadingState {
        log.debug("loading state initialized target={s} bounds={}x{}", .{ @tagName(target), width, height });
        return .{
            .allocator = allocator,
            .target = target,
            .width = width,
            .height = height,
            .world_build_config = world_build_config,
            .audio_settings = audio_settings,
        };
    }

    pub fn deinit(self: *LoadingState) void {
        log.debug("loading state deinit target={s} phase={s}", .{ @tagName(self.target), @tagName(self.phase) });
    }

    pub fn handleEvent(self: *LoadingState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        // Only `.failed` is interactive: Escape/East (quit) or Enter/Space/South
        // (confirm) replace back to the main menu with preserved audio settings.
        // Pending stays non-consuming so FrameCommands can still observe process quit.
        if (self.phase != .failed) return false;
        const action = inputFile.actionForPressEvent(event) orelse return false;
        switch (action) {
            .quit, .resume_game => {
                try self.returnToMainMenu(transitions);
                return true;
            },
            else => return false,
        }
    }

    pub fn update(self: *LoadingState, context: UpdateContext) !void {
        switch (self.phase) {
            .complete, .failed => return,
            .pending => {},
        }
        if (!self.rendered_once) return;
        self.loadGameDemo(context) catch |err| {
            if (!self.failure_logged) {
                // Recovered degradation: stay on the loading screen in `.failed`
                // instead of aborting the fixed-step loop. `warn` (not `err`) so
                // intentional build-failure tests are not treated as test errors.
                log.warn("loading state failed to build gameplay: {s}", .{@errorName(err)});
                self.failure_logged = true;
            }
            self.phase = .failed;
            self.text_dirty = true;
            // Expected build failures stay on the loading screen; do not rethrow
            // into the fixed-step loop (that aborts the process).
            return;
        };
        self.phase = .complete;
        self.text_dirty = true;
    }

    pub fn render(self: *LoadingState, context: RenderContext) !void {
        _ = context.interpolation_alpha;
        _ = context.thread_system;
        try context.renderer.submitOrderedRectInSpace(
            .{ .x = 0, .y = 0, .w = self.width, .h = self.height },
            .{ .r = 0.045, .g = 0.052, .b = 0.058, .a = 1.0 },
            RenderOrder.uiInStack(context.ui_stack_order, .background),
            .logical,
        );
        const text_service = context.text_service;
        if (self.text_dirty or !self.title_text.isValid()) {
            try self.prepareTextViews(text_service, context.renderer);
        }
        try text.drawPreparedText(context.renderer, self.title_text, .{
            .x = self.width * 0.5,
            .y = self.height * 0.42,
            .anchor = .top_center,
            .order = RenderOrder.uiInStack(context.ui_stack_order, .text),
        });
        try text.drawPreparedText(context.renderer, self.status_text, .{
            .x = self.width * 0.5,
            .y = self.height * 0.5,
            .anchor = .top_center,
            .order = RenderOrder.uiInStack(context.ui_stack_order, .text),
        });
        // Latch only after a full frame prepared status text and submitted draws.
        self.rendered_once = true;
    }

    pub fn onPause(self: *LoadingState) void {
        _ = self;
    }

    fn returnToMainMenu(self: *LoadingState, transitions: *StateTransitions) !void {
        // Local import keeps the top-level cycle with main_menu_state (which
        // creates LoadingState on Start) from binding both modules' type graphs.
        const MainMenuState = @import("main_menu_state.zig").MainMenuState;
        log.debug("loading state returning to main menu after failure", .{});
        try transitions.replace(
            MainMenuState,
            MainMenuState.init(
                self.allocator,
                self.width,
                self.height,
                .{
                    .master_gain = RuntimeAudioSettings.gain(self.audio_settings.master),
                    .sfx_gain = RuntimeAudioSettings.gain(self.audio_settings.sfx),
                    .music_gain = RuntimeAudioSettings.gain(self.audio_settings.music),
                },
            ),
            state_policy.opaque_screen,
        );
    }

    fn loadGameDemo(self: *LoadingState, context: UpdateContext) !void {
        log.debug("loading state building game demo world", .{});
        const perf_start_ns = if (comptime runtime_perf_log.enabled) c.SDL_GetTicksNS() else 0;
        defer if (comptime runtime_perf_log.enabled) {
            context.perf.recordTiming(.loading_build, elapsedNs(perf_start_ns, c.SDL_GetTicksNS()));
        };
        const game_ptr = try self.allocator.create(GameDemoState);
        var initialized = false;
        var owned_by_transition = false;
        errdefer if (!owned_by_transition) {
            if (initialized) game_ptr.deinit();
            self.allocator.destroy(game_ptr);
        };

        game_ptr.* = try GameDemoState.initProceduralWithRuntimeAssets(
            self.allocator,
            context.runtime_assets,
            context.asset_store,
            self.world_build_config,
            context.thread_system,
            self.width,
            self.height,
        );
        initialized = true;
        const state = State.fromOwnedPtr(GameDemoState, game_ptr);
        owned_by_transition = true;
        try context.transitions.replaceOwnedGameplay(state);
        log.debug("loading state queued game demo transition", .{});
    }

    fn prepareTextViews(self: *LoadingState, text_service: *TextService, renderer: *Renderer) !void {
        self.title_text = try text_service.prepareDefaultText(renderer, "Loading", .{ .r = 0.92, .g = 0.94, .b = 0.95, .a = 1.0 });
        self.status_text = try text_service.prepareDefaultText(renderer, statusLabel(self.phase), .{ .r = 0.66, .g = 0.72, .b = 0.76, .a = 1.0 });
        self.text_dirty = false;
    }
};

fn statusLabel(phase: LoadingPhase) []const u8 {
    return switch (phase) {
        .pending => "Building world",
        .complete => "Starting",
        .failed => "Failed to load — Esc to return",
    };
}

fn elapsedNs(start_ns: u64, end_ns: u64) u64 {
    return if (end_ns > start_ns) end_ns - start_ns else 0;
}

fn defaultTestAudioSettings() RuntimeAudioSettings {
    return RuntimeAudioSettings.init(.{});
}

// Minimal world build config for tests: keeps `loadGameDemo` on its real
// `initProceduralWithRuntimeAssets` path without building a production-scale
// (256x256, 31-underground-level) world under `zig build test`.
const test_world_build_config = WorldBuildConfig{
    .width_tiles = 8,
    .height_tiles = 8,
    .chunk_size_tiles = 8,
    .underground_level_count = 0,
};

fn headlessRendererForTest(allocator: std.mem.Allocator) !Renderer {
    const sprite_batch = @import("../render/sprite_batch.zig");
    return .{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
        .white_texture = try TextureId.init(1, 1),
    };
}

fn deinitHeadlessRenderer(renderer: *Renderer, allocator: std.mem.Allocator) void {
    renderer.batch.deinit();
    renderer.static_positions.deinit(allocator);
    renderer.static_uvs.deinit(allocator);
    renderer.static_colors.deinit(allocator);
    renderer.static_groups.deinit(allocator);
    renderer.draw_list.deinit(allocator);
}

/// Seeds valid prepared-text handles and skips `prepareTextViews` so a headless
/// render path can exercise the draw+latch success branch without a text backend.
fn seedPreparedTextForTest(loading: *LoadingState) !void {
    loading.title_text = .{ .texture = try TextureId.init(2, 1), .width = 48, .height = 18 };
    loading.status_text = .{ .texture = try TextureId.init(3, 1), .width = 96, .height = 18 };
    loading.text_dirty = false;
}

test "loading state build failure latches failed phase without rethrowing" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();
    loading.rendered_once = true;

    var input = InputState{};
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    // Missing world tileset metadata is an expected build failure: stay on the
    // loading screen in `.failed` instead of aborting the fixed-step loop.
    try loading.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets"),
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    });
    try std.testing.expectEqual(LoadingPhase.failed, loading.phase);
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
    try std.testing.expect(loading.failure_logged);
    try std.testing.expectEqualStrings("Failed to load — Esc to return", statusLabel(loading.phase));

    // A later tick must not re-attempt the build or rethrow.
    try loading.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets"),
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    });
    try std.testing.expectEqual(LoadingPhase.failed, loading.phase);
}

test "loading state failed phase Escape returns to main menu with audio settings" {
    const MainMenuState = @import("main_menu_state.zig").MainMenuState;
    const audio_settings = RuntimeAudioSettings{
        .master = 7,
        .sfx = 2,
        .music = 9,
    };
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        audio_settings,
    );
    defer loading.deinit();
    loading.phase = .failed;

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    const quit_event = keyEventForAction(.quit);
    try std.testing.expect(try loading.handleEvent(&quit_event, &transitions));
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();
    _ = try stack.applyTransitions(&transitions);
    const active = stack.active() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(@typeName(MainMenuState), active.type_name);

    const menu: *MainMenuState = @ptrCast(@alignCast(active.ptr));
    try std.testing.expectEqual(@as(u8, 7), menu.audio_settings.master);
    try std.testing.expectEqual(@as(u8, 2), menu.audio_settings.sfx);
    try std.testing.expectEqual(@as(u8, 9), menu.audio_settings.music);
}

test "loading state failed phase confirm and gamepad East also return to main menu" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();
    loading.phase = .failed;

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    const confirm = keyEventForAction(.resume_game);
    try std.testing.expect(try loading.handleEvent(&confirm, &transitions));
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
    transitions.clear();

    const gamepad_quit = gamepadButtonEventForAction(.quit);
    try std.testing.expect(try loading.handleEvent(&gamepad_quit, &transitions));
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
}

test "loading state pending phase does not consume quit" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    const quit_event = keyEventForAction(.quit);
    try std.testing.expect(!(try loading.handleEvent(&quit_event, &transitions)));
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
}

test "loading state runtime metadata fixture exposes installed atlases" {
    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);
    try std.testing.expect(runtime_assets.worldTilesetMeta() != null);
    try std.testing.expect(runtime_assets.spriteAtlasMeta(.grim_characters) != null);
}

test "loading state builds gameplay from runtime atlas metadata" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();
    loading.rendered_once = true;

    var input = InputState{};
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);

    // Drives the real LoadingState -> GameDemoState transition end to end (not
    // just the fixture setup above), so a break in initProceduralWithRuntimeAssets
    // or the transition wiring itself fails this test instead of shipping silently.
    try loading.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets"),
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();
    _ = try stack.applyTransitions(&transitions);
    const active = stack.active() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(@typeName(GameDemoState), active.type_name);
}

test "loading state waits for first render before building gameplay" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();

    var input = InputState{};
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);

    try loading.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets"),
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
    try std.testing.expectEqual(LoadingPhase.pending, loading.phase);
}

test "loading state successful render latches rendered_once" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();
    try seedPreparedTextForTest(&loading);
    try std.testing.expect(!loading.rendered_once);

    var renderer = try headlessRendererForTest(std.testing.allocator);
    defer deinitHeadlessRenderer(&renderer, std.testing.allocator);
    renderer.beginFrame(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    // Background rect + title + status = 3 sprite submits.
    try renderer.reserveSpriteCommands(3);

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    // prepareTextViews is skipped (seeded handles + text_dirty=false); the dummy
    // text service pointer is never dereferenced on the success path under test.
    var dummy_text: TextService = undefined;

    try loading.render(.{
        .renderer = &renderer,
        .runtime_assets = &runtime_assets,
        .text_service = &dummy_text,
        .interpolation_alpha = 0,
        .thread_system = &threads,
    });
    try std.testing.expect(loading.rendered_once);
    try std.testing.expectEqual(@as(usize, 3), renderer.spriteCommandCount());
}

test "loading state render failure leaves rendered_once false" {
    var loading = LoadingState.init(
        std.testing.allocator,
        .game_demo,
        800,
        450,
        test_world_build_config,
        defaultTestAudioSettings(),
    );
    defer loading.deinit();
    try seedPreparedTextForTest(&loading);

    var renderer = try headlessRendererForTest(std.testing.allocator);
    defer deinitHeadlessRenderer(&renderer, std.testing.allocator);
    // Frame-reserved with zero capacity: the first sprite submit overflows and
    // aborts before the latch, proving a partial draw cannot unlock world build.
    renderer.batch.frame_reserved = true;

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var dummy_text: TextService = undefined;

    try std.testing.expectError(error.SpriteCommandOverflow, loading.render(.{
        .renderer = &renderer,
        .runtime_assets = &runtime_assets,
        .text_service = &dummy_text,
        .interpolation_alpha = 0,
        .thread_system = &threads,
    }));
    try std.testing.expect(!loading.rendered_once);
}

fn runtimeAssetsWithDemoMetadataForTest() !RuntimeAssets {
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    runtime_assets.sprite_slots[manifest.spriteIndex(.world_tileset)] = .{ .status = .available };
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    runtime_assets.atlas_meta[manifest.spriteIndex(.world_tileset)] = .{
        .world_tileset = try world_tileset_meta.load(
            std.testing.allocator,
            asset_store,
            manifest.spriteSpec(.world_tileset).metadata_path.?,
        ),
    };
    errdefer deinitRuntimeAssetMetadataForTest(&runtime_assets);
    runtime_assets.atlas_meta[manifest.spriteIndex(.grim_characters)] = .{
        .sprite_atlas = try sprite_atlas_meta.load(
            std.testing.allocator,
            asset_store,
            .grim_characters,
            manifest.spriteSpec(.grim_characters).metadata_path.?,
        ),
    };
    return runtime_assets;
}

fn deinitRuntimeAssetMetadataForTest(runtime_assets: *RuntimeAssets) void {
    for (&runtime_assets.atlas_meta) |*slot| {
        if (slot.*) |*meta| {
            switch (meta.*) {
                .world_tileset => |*world_meta| world_meta.deinit(),
                .sprite_atlas => |*atlas_meta| atlas_meta.deinit(),
            }
        }
        slot.* = null;
    }
}

fn keyEventForAction(action: inputFile.Action) c.SDL_Event {
    for (inputFile.default_key_bindings) |binding| {
        if (binding.action == action) {
            return c.SDL_Event{ .key = .{
                .type = c.SDL_EVENT_KEY_DOWN,
                .reserved = 0,
                .timestamp = 0,
                .windowID = 0,
                .which = 0,
                .scancode = 0,
                .key = binding.key,
                .mod = 0,
                .raw = 0,
                .down = true,
                .repeat = false,
            } };
        }
    }
    unreachable;
}

fn gamepadButtonEventForAction(action: inputFile.Action) c.SDL_Event {
    for (inputFile.default_gamepad_bindings) |binding| {
        if (binding.action == action) {
            return c.SDL_Event{ .gbutton = .{
                .type = c.SDL_EVENT_GAMEPAD_BUTTON_DOWN,
                .reserved = 0,
                .timestamp = 0,
                .which = 0,
                .button = @intCast(binding.button),
                .down = true,
                .padding1 = 0,
                .padding2 = 0,
            } };
        }
    }
    unreachable;
}
