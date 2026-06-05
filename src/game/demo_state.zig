// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const std = @import("std");
const DataSystem = @import("data_system.zig").DataSystem;
const Player = @import("player.zig").Player;
const state_mod = @import("../app/state.zig");
const RenderContext = state_mod.RenderContext;
const StateTransitions = state_mod.StateTransitions;
const UpdateContext = state_mod.UpdateContext;
const c = @import("../platform/sdl.zig").c;

pub const DemoState = struct {
    data: DataSystem,
    player: Player,
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,

    pub fn init(allocator: std.mem.Allocator, bounds_width: f32, bounds_height: f32) !DemoState {
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const player = try Player.spawn(&data);

        return .{
            .data = data,
            .player = player,
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
        };
    }

    pub fn deinit(self: *DemoState) void {
        self.data.deinit();
    }

    pub fn handleEvent(self: *DemoState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *DemoState, context: UpdateContext) !void {
        _ = context.transitions;
        _ = context.thread_system;
        try self.player.update(&self.data, context.input, context.delta_seconds, self.bounds_width, self.bounds_height);
    }

    pub fn render(self: *DemoState, context: RenderContext) !void {
        _ = context.thread_system;
        try self.player.render(&self.data, context.renderer, context.interpolation_alpha);
        try context.renderer.drawRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, -1);
    }

    pub fn onPause(self: *DemoState) void {
        self.player.onPause(&self.data);
    }
};
