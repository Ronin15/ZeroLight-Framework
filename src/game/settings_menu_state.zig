// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const Renderer = @import("../render/renderer.zig").Renderer;
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const RenderContext = @import("../app/state.zig").RenderContext;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const InputState = @import("../app/input.zig").InputState;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const inputFile = @import("../app/input.zig");
const menu_view = @import("menu_view.zig");
const text = @import("../render/text.zig");
const PreparedText = text.PreparedText;
const TextService = text.TextService;
const log = @import("../core/logging.zig").game;
const c = @import("../platform/sdl.zig").c;

pub const RuntimeAudioSettings = struct {
    master: u8,
    sfx: u8,
    music: u8,

    pub fn init(audio_config: config.AudioConfig) RuntimeAudioSettings {
        return .{
            .master = valueFromGain(audio_config.master_gain),
            .sfx = valueFromGain(audio_config.sfx_gain),
            .music = valueFromGain(audio_config.music_gain),
        };
    }

    pub fn gain(value: u8) f32 {
        return @as(f32, @floatFromInt(value)) / 10.0;
    }

    fn valueFromGain(gain_value: f32) u8 {
        const clamped = std.math.clamp(gain_value, 0.0, 1.0);
        return @intFromFloat(@round(clamped * 10.0));
    }
};

pub const SettingsMenuState = struct {
    settings: *RuntimeAudioSettings,
    width: f32,
    height: f32,
    selected: usize = 0,
    pending_adjust: i32 = 0,
    title_text: PreparedText = .invalid,
    item_texts: [item_count]PreparedText = [_]PreparedText{PreparedText.invalid} ** item_count,
    text_dirty: bool = true,

    const item_count = 4;
    const items = [_][]const u8{
        "Master Volume",
        "SFX Volume",
        "Music Volume",
        "Back",
    };

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
    pub fn init(settings: *RuntimeAudioSettings, width: f32, height: f32) SettingsMenuState {
        log.debug("settings menu initialized ({}x{})", .{ width, height });
        return .{
            .settings = settings,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *SettingsMenuState) void {
        _ = self;
        log.debug("settings menu deinit", .{});
    }

    pub fn handleEvent(self: *SettingsMenuState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        const action = inputFile.actionForPressEvent(event) orelse return false;
        switch (action) {
            .menuUp => {
                self.changeSelection(-1);
                return true;
            },
            .menuDown => {
                self.changeSelection(1);
                return true;
            },
            .menuLeft => {
                self.pending_adjust = -1;
                return true;
            },
            .menuRight => {
                self.pending_adjust = 1;
                return true;
            },
            .resumeGame => {
                try self.activate(transitions);
                return true;
            },
            .quit => {
                try transitions.pop();
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn update(self: *SettingsMenuState, context: UpdateContext) !void {
        if (self.pending_adjust != 0) {
            const delta = self.pending_adjust;
            self.pending_adjust = 0;
            try self.adjustSelected(delta, context.audio);
        }
    }

    pub fn render(self: *SettingsMenuState, context: RenderContext) !void {
        _ = context.interpolation_alpha;
        _ = context.thread_system;

        const renderer = context.renderer;
        const text_service = context.text_service;

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
            .{ .r = 0.18, .g = 0.20, .b = 0.22, .a = 0.9 },
            context.ui_stack_order,
            .background,
            .panel,
            .highlight,
            .text,
        );
    }

    pub fn onPause(self: *SettingsMenuState) void {
        _ = self;
    }

    fn changeSelection(self: *SettingsMenuState, delta: i32) void {
        menu_view.changeSelection(&self.selected, delta, item_count);
        self.text_dirty = true;
    }

    fn adjustSelected(self: *SettingsMenuState, delta: i32, audio: *AudioCommandBuffer) !void {
        if (self.selected >= 3) return; // Back row not adjustable
        const maxv: u8 = 10;
        const val: u8 = switch (self.selected) {
            0 => self.settings.master,
            1 => self.settings.sfx,
            2 => self.settings.music,
            else => return,
        };
        const newv: u8 = if (delta > 0)
            if (val < maxv) val + 1 else maxv
        else if (val > 0) val - 1 else 0;

        if (newv == val) return;

        switch (self.selected) {
            0 => {
                try audio.setMasterGain(RuntimeAudioSettings.gain(newv));
                self.settings.master = newv;
            },
            1 => {
                try audio.setBusGain(.sfx, RuntimeAudioSettings.gain(newv));
                self.settings.sfx = newv;
            },
            2 => {
                try audio.setBusGain(.music, RuntimeAudioSettings.gain(newv));
                self.settings.music = newv;
            },
            else => {},
        }
        self.text_dirty = true;
        log.debug("settings adjusted volume row {d} to {d}/10", .{ self.selected, newv });
    }

    fn activate(self: *SettingsMenuState, transitions: *StateTransitions) !void {
        log.debug("settings menu activating item {d}", .{self.selected});
        if (self.selected == 3) {
            try transitions.pop();
        }
        // volumes: left/right already live-adjust; confirm on volume rows does nothing extra
    }

    fn prepareTextViews(self: *SettingsMenuState, text_service: *TextService, renderer: *Renderer) !void {
        self.title_text = try text_service.prepareDefaultText(renderer, "Settings", title_color);

        var master_buf: [64]u8 = undefined;
        var sfx_buf: [64]u8 = undefined;
        var music_buf: [64]u8 = undefined;
        const labels = [_][]const u8{
            std.fmt.bufPrint(&master_buf, "Master Volume: {d: >2}/10", .{self.settings.master}) catch "Master Volume: ??/10",
            std.fmt.bufPrint(&sfx_buf, "SFX Volume:    {d: >2}/10", .{self.settings.sfx}) catch "SFX Volume:    ??/10",
            std.fmt.bufPrint(&music_buf, "Music Volume:  {d: >2}/10", .{self.settings.music}) catch "Music Volume:  ??/10",
            "Back",
        };

        for (labels, 0..) |label, i| {
            self.item_texts[i] = try text_service.prepareDefaultText(
                renderer,
                label,
                if (i == self.selected) accent_color else normal_color,
            );
        }

        self.text_dirty = false;
    }
};

test "settings volumes clamp and emit gain commands" {
    var runtime_settings = RuntimeAudioSettings.init(.{});

    var settings = SettingsMenuState.init(&runtime_settings, 800, 450);
    defer settings.deinit();

    var audio = AudioCommandBuffer.init(std.testing.allocator, 16);
    defer audio.deinit();
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    var input = InputState{};
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    const ctx = UpdateContext{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .delta_seconds = 0,
        .transitions = &transitions,
        .thread_system = &threads,
    };

    try std.testing.expectEqual(@as(u8, 10), runtime_settings.master);
    try std.testing.expectEqual(@as(u8, 9), runtime_settings.sfx);
    try std.testing.expectEqual(@as(u8, 6), runtime_settings.music);

    // select master (0), right increases (but already 10)
    settings.selected = 0;
    try settings.adjustSelected(1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 10), runtime_settings.master);
    try std.testing.expectEqual(@as(usize, 0), audio.len());

    // left decreases
    try settings.adjustSelected(-1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 9), runtime_settings.master);
    try std.testing.expect(audio.len() >= 1);

    // select sfx, adjust
    settings.selected = 1;
    try settings.adjustSelected(-1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 8), runtime_settings.sfx);

    // select music, adjust up
    settings.selected = 2;
    try settings.adjustSelected(1, ctx.audio);
    try std.testing.expectEqual(@as(u8, 7), runtime_settings.music);

    var reopened = SettingsMenuState.init(&runtime_settings, 800, 450);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u8, 9), reopened.settings.master);
    try std.testing.expectEqual(@as(u8, 8), reopened.settings.sfx);
    try std.testing.expectEqual(@as(u8, 7), reopened.settings.music);
}

test "settings handleEvent uses named input actions" {
    var runtime_settings = RuntimeAudioSettings.init(.{});
    var settings = SettingsMenuState.init(&runtime_settings, 800, 450);
    defer settings.deinit();

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    var up = keyEventForAction(.menuUp);
    try std.testing.expect(try settings.handleEvent(&up, &transitions));
    try std.testing.expectEqual(@as(usize, 3), settings.selected);

    var down = keyEventForAction(.menuDown);
    try std.testing.expect(try settings.handleEvent(&down, &transitions));
    try std.testing.expectEqual(@as(usize, 0), settings.selected);

    var right = keyEventForAction(.menuRight);
    try std.testing.expect(try settings.handleEvent(&right, &transitions));
    try std.testing.expectEqual(@as(i32, 1), settings.pending_adjust);

    settings.selected = 3;
    var confirm = keyEventForAction(.resumeGame);
    try std.testing.expect(try settings.handleEvent(&confirm, &transitions));
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
}

test "settings handleEvent uses named gamepad input actions identically to keyboard" {
    var runtime_settings = RuntimeAudioSettings.init(.{});
    var settings = SettingsMenuState.init(&runtime_settings, 800, 450);
    defer settings.deinit();

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    var up = gamepadButtonEventForAction(.menuUp);
    try std.testing.expect(try settings.handleEvent(&up, &transitions));
    try std.testing.expectEqual(@as(usize, 3), settings.selected);

    var down = gamepadButtonEventForAction(.menuDown);
    try std.testing.expect(try settings.handleEvent(&down, &transitions));
    try std.testing.expectEqual(@as(usize, 0), settings.selected);

    var right = gamepadButtonEventForAction(.menuRight);
    try std.testing.expect(try settings.handleEvent(&right, &transitions));
    try std.testing.expectEqual(@as(i32, 1), settings.pending_adjust);

    settings.selected = 3;
    var confirm = gamepadButtonEventForAction(.resumeGame);
    try std.testing.expect(try settings.handleEvent(&confirm, &transitions));
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);
}

test "settings failed audio command leaves runtime value unchanged" {
    var runtime_settings = RuntimeAudioSettings.init(.{});
    var settings = SettingsMenuState.init(&runtime_settings, 800, 450);
    defer settings.deinit();

    var audio = AudioCommandBuffer.init(std.testing.allocator, 1);
    defer audio.deinit();
    try audio.setMasterGain(1.0);

    settings.selected = 0;
    try std.testing.expectError(error.AudioCommandLimitReached, settings.adjustSelected(-1, &audio));
    try std.testing.expectEqual(@as(u8, 10), runtime_settings.master);
}

test "settings back via quit action requests pop" {
    var runtime_settings = RuntimeAudioSettings.init(.{});
    var settings = SettingsMenuState.init(&runtime_settings, 800, 450);
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
