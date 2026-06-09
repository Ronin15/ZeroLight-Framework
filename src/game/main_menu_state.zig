// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const Renderer = @import("../render/renderer.zig").Renderer;
const TextTextureLease = @import("../render/text.zig").TextTextureLease;
const TextService = @import("../render/text.zig").TextService;
const RenderContext = @import("../app/state.zig").RenderContext;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const GameDemoState = @import("game_demo_state.zig").GameDemoState;
const SettingsMenuState = @import("settings_menu_state.zig").SettingsMenuState;
const menu_view = @import("menu_view.zig");
const log = @import("../core/logging.zig").game;
const c = @import("../platform/sdl.zig").c;

pub const MainMenuState = struct {
    allocator: std.mem.Allocator,
    width: f32,
    height: f32,
    selected: usize = 0,
    title: TextTextureLease = .{},
    item_leases: [item_count]TextTextureLease = [_]TextTextureLease{.{}} ** item_count,
    needs_rebuild: bool = true,

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
    const highlight_pad_x: f32 = 10;
    const highlight_height: f32 = 30;

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32) MainMenuState {
        log.debug("main menu initialized ({}x{})", .{ width, height });
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *MainMenuState) void {
        log.debug("main menu deinit", .{});
        self.releaseLeases();
    }

    pub fn handleEvent(self: *MainMenuState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        if (event.type != c.SDL_EVENT_KEY_DOWN or event.key.repeat) return false;
        const key = event.key.key;
        switch (key) {
            c.SDLK_UP => {
                self.changeSelection(-1);
                return true;
            },
            c.SDLK_DOWN => {
                self.changeSelection(1);
                return true;
            },
            c.SDLK_RETURN, c.SDLK_SPACE => {
                try self.activate(transitions);
                return true;
            },
            c.SDLK_ESCAPE => {
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

        if (self.needs_rebuild or !self.title.isAlive()) {
            self.rebuildText(text_service, renderer) catch return;
        }

        try menu_view.renderList(
            renderer,
            self.width,
            self.height,
            self.title,
            &self.item_leases,
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
        self.needs_rebuild = true;
    }

    fn activate(self: *MainMenuState, transitions: *StateTransitions) !void {
        log.debug("main menu activating item {d}", .{self.selected});
        switch (self.selected) {
            0 => {
                // Launch gameplay
                try transitions.replaceGameplay(GameDemoState, try GameDemoState.init(self.allocator, self.width, self.height));
            },
            1 => {
                try transitions.pushModal(SettingsMenuState, SettingsMenuState.init(self.width, self.height));
            },
            2 => {
                try transitions.quit();
            },
            else => {},
        }
    }

    fn rebuildText(self: *MainMenuState, text_service: *TextService, renderer: *Renderer) !void {
        self.releaseLeases();

        self.title = try text_service.acquireText(renderer, .{
            .text = "Zig SDL3 GPU",
            .style = .{
                .font = text_service.defaultFont(),
                .color = title_color,
            },
        });

        for (items, 0..) |lab, i| {
            const col = if (i == self.selected) accent_color else normal_color;
            self.item_leases[i] = try text_service.acquireText(renderer, .{
                .text = lab,
                .style = .{
                    .font = text_service.defaultFont(),
                    .color = col,
                },
            });
        }

        self.needs_rebuild = false;
    }

    fn releaseLeases(self: *MainMenuState) void {
        self.title.release();
        for (&self.item_leases) |*l| l.release();
    }
};

test "main menu selection wraps and activates produce transitions" {
    var menu = MainMenuState.init(std.testing.allocator, 800, 450);
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
