// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const InputState = @import("../app/input.zig").InputState;
const Renderer = @import("../render/renderer.zig").Renderer;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const c = @import("../platform/sdl.zig").c;

pub const PauseState = struct {
    width: f32,
    height: f32,

    const overlay_layer: i32 = 9_000;
    const icon_layer: i32 = 9_001;
    const overlay_color = config.Color{ .r = 0.02, .g = 0.025, .b = 0.03, .a = 0.68 };
    const panel_color = config.Color{ .r = 0.12, .g = 0.15, .b = 0.18, .a = 0.9 };
    const accent_color = config.Color{ .r = 1.0, .g = 0.86, .b = 0.2, .a = 1.0 };

    pub fn init(width: f32, height: f32) PauseState {
        return .{ .width = width, .height = height };
    }

    pub fn deinit(self: *PauseState) void {
        _ = self;
    }

    pub fn handleEvent(self: *PauseState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *PauseState, input: *const InputState, delta_seconds: f32, transitions: *StateTransitions) !void {
        _ = self;
        _ = input;
        _ = delta_seconds;
        _ = transitions;
    }

    pub fn render(self: *PauseState, renderer: *Renderer, interpolation_alpha: f32) !void {
        _ = interpolation_alpha;

        try drawScreenRect(renderer, .{ .x = 0, .y = 0, .w = self.width, .h = self.height }, overlay_color, overlay_layer);

        const panel_width: f32 = 220;
        const panel_height: f32 = 132;
        const panel_x = (self.width - panel_width) * 0.5;
        const panel_y = (self.height - panel_height) * 0.5;
        try drawScreenRect(renderer, .{
            .x = panel_x,
            .y = panel_y,
            .w = panel_width,
            .h = panel_height,
        }, panel_color, icon_layer);

        const bar_width: f32 = 28;
        const bar_height: f32 = 72;
        const gap: f32 = 24;
        const left_x = (self.width - gap) * 0.5 - bar_width;
        const right_x = (self.width + gap) * 0.5;
        const bar_y = (self.height - bar_height) * 0.5;

        try drawScreenRect(renderer, .{ .x = left_x, .y = bar_y, .w = bar_width, .h = bar_height }, accent_color, icon_layer + 1);
        try drawScreenRect(renderer, .{ .x = right_x, .y = bar_y, .w = bar_width, .h = bar_height }, accent_color, icon_layer + 1);
    }

    pub fn onPause(self: *PauseState) void {
        _ = self;
    }
};

fn drawScreenRect(renderer: *Renderer, rect: @import("../render/renderer.zig").Rect, color: config.Color, layer: i32) !void {
    try renderer.drawSprite(.{
        .texture = renderer.white_texture,
        .dest = rect,
        .tint = color,
        .layer = layer,
        .screen_space = true,
    });
}
