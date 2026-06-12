// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const Renderer = @import("../render/renderer.zig").Renderer;
const RenderContext = @import("../app/state.zig").RenderContext;
const State = @import("../app/state.zig").State;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const inputFile = @import("../app/input.zig");
const GameDemoState = @import("game_demo_state.zig").GameDemoState;
const SettingsMenuState = @import("settings_menu_state.zig").SettingsMenuState;
const RuntimeAudioSettings = @import("settings_menu_state.zig").RuntimeAudioSettings;
const menu_view = @import("menu_view.zig");
const text = @import("../render/text.zig");
const PreparedText = text.PreparedText;
const TextService = text.TextService;
const log = @import("../core/logging.zig").game;
const c = @import("../platform/sdl.zig").c;

pub const MainMenuState = struct {
    allocator: std.mem.Allocator,
    width: f32,
    height: f32,
    audio_settings: RuntimeAudioSettings,
    selected: usize = 0,
    title_text: PreparedText = .invalid,
    item_texts: [item_count]PreparedText = [_]PreparedText{PreparedText.invalid} ** item_count,
    text_dirty: bool = true,

    const item_count = 3;
    const items = [_][]const u8{
        "Start Game",
        "Settings",
        "Quit",
    };

    const overlay_layer: i32 = 8_500;
    const panel_layer: i32 = 8_501;
    const highlight_layer: i32 = 8_502;
    const text_layer: i32 = 8_503;

    const overlay_color = config.Color{ .r = 0.04, .g = 0.06, .b = 0.08, .a = 0.95 };
    const panel_color = config.Color{ .r = 0.08, .g = 0.10, .b = 0.12, .a = 0.92 };
    const accent_color = config.Color{ .r = 1.0, .g = 0.86, .b = 0.2, .a = 1.0 };
    const normal_color = config.Color{ .r = 0.82, .g = 0.86, .b = 0.88, .a = 1.0 };
    const title_color = config.Color{ .r = 0.96, .g = 0.93, .b = 0.78, .a = 1.0 };

    const panel_width: f32 = 380;
    const panel_height: f32 = 260;
    const title_y: f32 = 200;
    const first_item_y: f32 = 270;
    const item_spacing: f32 = 42;
    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, audio_config: config.AudioConfig) MainMenuState {
        log.debug("main menu initialized ({}x{})", .{ width, height });
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .audio_settings = RuntimeAudioSettings.init(audio_config),
        };
    }

    pub fn deinit(self: *MainMenuState) void {
        _ = self;
        log.debug("main menu deinit", .{});
    }

    pub fn handleEvent(self: *MainMenuState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        if (event.type != c.SDL_EVENT_KEY_DOWN or event.key.repeat) return false;
        const action = inputFile.actionForKey(event.key.key) orelse return false;
        switch (action) {
            .menuUp => {
                self.changeSelection(-1);
                return true;
            },
            .menuDown => {
                self.changeSelection(1);
                return true;
            },
            .resumeGame => {
                try self.activate(transitions);
                return true;
            },
            .quit => {
                try transitions.quit();
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn update(self: *MainMenuState, context: UpdateContext) !void {
        _ = self;
        _ = context;
    }

    pub fn render(self: *MainMenuState, context: RenderContext) !void {
        _ = context.interpolation_alpha;
        _ = context.thread_system;

        const renderer = context.renderer;
        const text_service = context.text_service orelse return;

        if (self.text_dirty or !self.title_text.isValid()) {
            try self.prepareTextViews(text_service, renderer);
        }

        try menu_view.renderList(
            renderer,
            self.width,
            self.height,
            self.title_text,
            &self.item_texts,
            self.selected,
            title_y,
            first_item_y,
            item_spacing,
            panel_width,
            panel_height,
            overlay_color,
            panel_color,
            .{ .r = 0.16, .g = 0.18, .b = 0.20, .a = 0.85 },
            overlay_layer,
            panel_layer,
            highlight_layer,
            text_layer,
        );
    }

    pub fn onPause(self: *MainMenuState) void {
        _ = self;
    }

    fn changeSelection(self: *MainMenuState, delta: i32) void {
        menu_view.changeSelection(&self.selected, delta, item_count);
        self.text_dirty = true;
    }

    fn activate(self: *MainMenuState, transitions: *StateTransitions) !void {
        log.debug("main menu activating item {d}", .{self.selected});
        switch (self.selected) {
            0 => {
                const game_ptr = try self.allocator.create(GameDemoState);
                var initialized = false;
                var owned_by_transition = false;
                errdefer if (!owned_by_transition) {
                    if (initialized) game_ptr.deinit();
                    self.allocator.destroy(game_ptr);
                };

                game_ptr.* = try GameDemoState.init(self.allocator, self.width, self.height);
                initialized = true;
                const state = State.fromOwnedPtr(GameDemoState, game_ptr);
                owned_by_transition = true;
                try transitions.replaceOwnedGameplay(state);
            },
            1 => {
                try transitions.pushModal(SettingsMenuState, SettingsMenuState.init(&self.audio_settings, self.width, self.height));
            },
            2 => {
                try transitions.quit();
            },
            else => {},
        }
    }

    fn prepareTextViews(self: *MainMenuState, text_service: *TextService, renderer: *Renderer) !void {
        self.title_text = try text_service.prepareDefaultText(renderer, "Zig SDL3 GPU", title_color);
        for (items, 0..) |label, i| {
            self.item_texts[i] = try text_service.prepareDefaultText(
                renderer,
                label,
                if (i == self.selected) accent_color else normal_color,
            );
        }

        self.text_dirty = false;
    }
};

test "main menu selection wraps and activates produce transitions" {
    var menu = MainMenuState.init(std.testing.allocator, 800, 450, .{});
    defer menu.deinit();

    try std.testing.expectEqual(@as(usize, 0), menu.selected);

    menu.changeSelection(-1);
    try std.testing.expectEqual(@as(usize, 2), menu.selected); // wrap

    menu.changeSelection(1);
    try std.testing.expectEqual(@as(usize, 0), menu.selected);

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    // Force start
    menu.selected = 0;
    try menu.activate(&transitions);
    try std.testing.expect(transitions.requests.items.len > 0);
}

test "main menu handleEvent uses named input actions" {
    var menu = MainMenuState.init(std.testing.allocator, 800, 450, .{});
    defer menu.deinit();

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    var up = keyEventForAction(.menuUp);
    try std.testing.expect(try menu.handleEvent(&up, &transitions));
    try std.testing.expectEqual(@as(usize, 2), menu.selected);

    var down = keyEventForAction(.menuDown);
    try std.testing.expect(try menu.handleEvent(&down, &transitions));
    try std.testing.expectEqual(@as(usize, 0), menu.selected);

    menu.selected = 2;
    var confirm = keyEventForAction(.resumeGame);
    try std.testing.expect(try menu.handleEvent(&confirm, &transitions));
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
}

test "main menu owns runtime audio settings for settings modals" {
    var menu = MainMenuState.init(std.testing.allocator, 800, 450, .{
        .master_gain = 0.7,
        .sfx_gain = 0.2,
        .music_gain = 0.9,
    });
    defer menu.deinit();

    try std.testing.expectEqual(@as(u8, 7), menu.audio_settings.master);
    try std.testing.expectEqual(@as(u8, 2), menu.audio_settings.sfx);
    try std.testing.expectEqual(@as(u8, 9), menu.audio_settings.music);

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    menu.selected = 1;
    try menu.activate(&transitions);
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
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
