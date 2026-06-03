// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const Renderer = @import("../render/renderer.zig").Renderer;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const c = @import("../platform/sdl.zig").c;

pub const DemoState = struct {
    player: Player = .{},
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,

    pub fn init(bounds_width: f32, bounds_height: f32) DemoState {
        return .{
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
        };
    }

    pub fn deinit(self: *DemoState) void {
        _ = self;
    }

    pub fn handleEvent(self: *DemoState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *DemoState, input: *const InputState, delta_seconds: f32, transitions: *StateTransitions) !void {
        _ = transitions;
        self.player.update(input, delta_seconds, self.bounds_width, self.bounds_height);
    }

    pub fn render(self: *DemoState, renderer: *Renderer, interpolation_alpha: f32) !void {
        try self.player.render(renderer, interpolation_alpha);
        try renderer.drawRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, -1);
    }

    pub fn onPause(self: *DemoState) void {
        self.player.onPause();
    }
};
