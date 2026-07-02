// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Opaque loading screen for constructing gameplay states from Engine-owned
//! runtime catalogs without letting menus or gameplay states own app services.

const std = @import("std");
const GameDemoState = @import("game_demo_state.zig").GameDemoState;
const WorldBuildConfig = @import("world_system.zig").WorldBuildConfig;
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const RenderContext = @import("../app/state.zig").RenderContext;
const State = @import("../app/state.zig").State;
const StateStack = @import("../app/state.zig").StateStack;
const StateTransitions = @import("../app/state.zig").StateTransitions;
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
};

pub const LoadingState = struct {
    allocator: std.mem.Allocator,
    target: LoadTarget,
    width: f32,
    height: f32,
    world_build_config: WorldBuildConfig,
    phase: LoadingPhase = .pending,
    title_text: PreparedText = .invalid,
    status_text: PreparedText = .invalid,
    text_dirty: bool = true,
    rendered_once: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        target: LoadTarget,
        width: f32,
        height: f32,
        world_build_config: WorldBuildConfig,
    ) LoadingState {
        log.debug("loading state initialized target={s} bounds={}x{}", .{ @tagName(target), width, height });
        return .{
            .allocator = allocator,
            .target = target,
            .width = width,
            .height = height,
            .world_build_config = world_build_config,
        };
    }

    pub fn deinit(self: *LoadingState) void {
        log.debug("loading state deinit target={s} phase={s}", .{ @tagName(self.target), @tagName(self.phase) });
    }

    pub fn handleEvent(self: *LoadingState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *LoadingState, context: UpdateContext) !void {
        if (self.phase == .complete) return;
        if (!self.rendered_once) return;
        switch (self.target) {
            .game_demo => try self.loadGameDemo(context),
        }
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
        self.rendered_once = true;
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
    }

    pub fn onPause(self: *LoadingState) void {
        _ = self;
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
    };
}

fn elapsedNs(start_ns: u64, end_ns: u64) u64 {
    return if (end_ns > start_ns) end_ns - start_ns else 0;
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

test "loading state requires runtime world metadata before building demo" {
    var loading = LoadingState.init(std.testing.allocator, .game_demo, 800, 450, test_world_build_config);
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
    try std.testing.expectError(error.WorldTilesetMetadataUnavailable, loading.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    }));
}

test "loading state runtime metadata fixture exposes installed atlases" {
    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);
    try std.testing.expect(runtime_assets.worldTilesetMeta() != null);
    try std.testing.expect(runtime_assets.spriteAtlasMeta(.grim_characters) != null);
}

test "loading state builds gameplay from runtime atlas metadata" {
    var loading = LoadingState.init(std.testing.allocator, .game_demo, 800, 450, test_world_build_config);
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
    var loading = LoadingState.init(std.testing.allocator, .game_demo, 800, 450, test_world_build_config);
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
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
    try std.testing.expectEqual(LoadingPhase.pending, loading.phase);
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
