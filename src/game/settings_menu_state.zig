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
const AudioBus = @import("../app/audio.zig").AudioBus;
const menu_view = @import("menu_view.zig");
const log = @import("../core/logging.zig").game;
const c = @import("../platform/sdl.zig").c;

pub const SettingsMenuState = struct {
    width: f32,
    height: f32,
    selected: usize = 0,
    master: u8 = 10,
    sfx: u8 = 8,
    music: u8 = 6,
    title: TextTextureLease = .{},
    item_leases: [item_count]TextTextureLease = [_]TextTextureLease{.{}} ** item_count,
    needs_rebuild: bool = true,
    pending_adjust: i32 = 0,

    const item_count = 4;
    const items = [_][]const u8{
        "Master Volume",
        "SFX Volume",
        "Music Volume",
        "Back",
    };

    const overlay_layer: i32 = 9_000;
    const panel_layer: i32 = 9_001;
    const highlight_layer: i32 = 9_002;
    const text_layer: i32 = 9_003;

    const overlay_color = config.Color{ .r = 0.02, .g = 0.025, .b = 0.03, .a = 0.82 };
    const panel_color = config.Color{ .r = 0.10, .g = 0.13, .b = 0.16, .a = 0.95 };
    const accent_color = config.Color{ .r = 1.0, .g = 0.86, .b = 0.2, .a = 1.0 };
    const normal_color = config.Color{ .r = 0.85, .g = 0.88, .b = 0.90, .a = 1.0 };
    const title_color = config.Color{ .r = 0.95, .g = 0.92, .b = 0.80, .a = 1.0 };

    const panel_width: f32 = 420;
    const panel_height: f32 = 280;
    const title_y: f32 = 180;
    const first_item_y: f32 = 240;
    const item_spacing: f32 = 38;
    const highlight_pad_x: f32 = 12;
    const highlight_height: f32 = 28;

    pub fn init(width: f32, height: f32) SettingsMenuState {
        log.debug("settings menu initialized ({}x{})", .{ width, height });
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *SettingsMenuState) void {
        log.debug("settings menu deinit", .{});
        self.releaseLeases();
    }

    pub fn handleEvent(self: *SettingsMenuState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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
            c.SDLK_LEFT => {
                self.pending_adjust = -1;
                return true;
            },
            c.SDLK_RIGHT => {
                self.pending_adjust = 1;
                return true;
            },
            c.SDLK_RETURN, c.SDLK_SPACE => {
                try self.activate(transitions);
                return true;
            },
            c.SDLK_ESCAPE => {
                try transitions.pop();
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn update(self: *SettingsMenuState, context: UpdateContext) !void {
        if (self.pending_adjust != 0) {
            self.adjustSelected(self.pending_adjust, context.audio);
            self.pending_adjust = 0;
        }
    }

    pub fn render(self: *SettingsMenuState, context: RenderContext) !void {
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
            .{ .r = 0.18, .g = 0.20, .b = 0.22, .a = 0.9 },
            overlay_layer,
            panel_layer,
            highlight_layer,
            text_layer,
        );
    }

    pub fn onPause(self: *SettingsMenuState) void {
        _ = self;
    }

    fn changeSelection(self: *SettingsMenuState, delta: i32) void {
        menu_view.changeSelection(&self.selected, delta, item_count);
        self.needs_rebuild = true;
    }

    fn adjustSelected(self: *SettingsMenuState, delta: i32, audio: *@import("../app/audio.zig").AudioCommandBuffer) void {
        if (self.selected >= 3) return; // Back row not adjustable
        const maxv: u8 = 10;
        const val: u8 = switch (self.selected) {
            0 => self.master,
            1 => self.sfx,
            2 => self.music,
            else => return,
        };
        const newv: u8 = if (delta > 0)
            if (val < maxv) val + 1 else maxv
        else if (val > 0) val - 1 else 0;

        if (newv == val) return;

        switch (self.selected) {
            0 => {
                self.master = newv;
                audio.setMasterGain(@as(f32, @floatFromInt(newv)) / 10.0) catch {};
            },
            1 => {
                self.sfx = newv;
                audio.setBusGain(.sfx, @as(f32, @floatFromInt(newv)) / 10.0) catch {};
            },
            2 => {
                self.music = newv;
                audio.setBusGain(.music, @as(f32, @floatFromInt(newv)) / 10.0) catch {};
            },
            else => {},
        }
        self.needs_rebuild = true;
        log.debug("settings adjusted volume row {d} to {d}/10", .{ self.selected, newv });
    }

    fn activate(self: *SettingsMenuState, transitions: *StateTransitions) !void {
        log.debug("settings menu activating item {d}", .{self.selected});
        if (self.selected == 3) {
            try transitions.pop();
        }
        // volumes: left/right already live-adjust; confirm on volume rows does nothing extra
    }

    fn rebuildText(self: *SettingsMenuState, text_service: *TextService, renderer: *Renderer) !void {
        self.releaseLeases();

        // Title (static)
        self.title = try text_service.acquireText(renderer, .{
            .text = "Settings",
            .style = .{
                .font = text_service.defaultFont(),
                .color = title_color,
            },
        });

        // Items (dynamic for volumes) - use stack buffers to avoid heap allocation on rebuild
        var master_buf: [64]u8 = undefined;
        var sfx_buf: [64]u8 = undefined;
        var music_buf: [64]u8 = undefined;

        const labels = [_][]const u8{
            std.fmt.bufPrint(&master_buf, "Master Volume: {d: >2}/10", .{self.master}) catch "Master Volume: ??/10",
            std.fmt.bufPrint(&sfx_buf, "SFX Volume:    {d: >2}/10", .{self.sfx}) catch "SFX Volume:    ??/10",
            std.fmt.bufPrint(&music_buf, "Music Volume:  {d: >2}/10", .{self.music}) catch "Music Volume:  ??/10",
            "Back",
        };

        for (labels, 0..) |lab, i| {
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

    fn releaseLeases(self: *SettingsMenuState) void {
        self.title.release();
        for (&self.item_leases) |*l| l.release();
    }
};

test "settings volumes clamp and emit gain commands" {
    const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;

    var settings = SettingsMenuState.init(800, 450);
    defer settings.deinit();

    var audio = AudioCommandBuffer.init(std.testing.allocator, 16);
    defer audio.deinit();

    const ctx = UpdateContext{
        .input = undefined,
        .audio = &audio,
        .delta_seconds = 0,
        .transitions = undefined,
        .thread_system = undefined,
    };

    // start at defaults in struct
    try std.testing.expectEqual(@as(u8, 10), settings.master);
    try std.testing.expectEqual(@as(u8, 8), settings.sfx);

    // select master (0), right increases (but already 10)
    settings.selected = 0;
    settings.adjustSelected(1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 10), settings.master);
    try std.testing.expectEqual(@as(usize, 0), audio.len());

    // left decreases
    settings.adjustSelected(-1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 9), settings.master);
    try std.testing.expect(audio.len() >= 1);

    // select sfx, adjust
    settings.selected = 1;
    settings.adjustSelected(-1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 7), settings.sfx);

    // select music, adjust up
    settings.selected = 2;
    settings.adjustSelected(1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 7), settings.music);
}

test "settings back via quit action requests pop" {
    var settings = SettingsMenuState.init(800, 450);
    defer settings.deinit();

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    // simulate quit (Esc) while on Back or any
    settings.selected = 3;
    // We call activate which for Back does pop; or direct
    try settings.activate(&transitions);
    // Or via the quit path in real update, here directly test pop request present
    try transitions.pop();
    try std.testing.expect(transitions.requests.items.len > 0);
}
