// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const FpsCounter = @import("fps_counter.zig").FpsCounter;
const FrameCommands = @import("../app/input.zig").FrameCommands;
const Renderer = @import("renderer.zig").Renderer;

pub const DebugOverlay = struct {
    visible: bool = false,
    fps_counter: FpsCounter = .{},

    pub fn init() DebugOverlay {
        return .{ .fps_counter = FpsCounter.init() };
    }

    pub fn deinit(self: *DebugOverlay, renderer: *Renderer) void {
        self.fps_counter.deinit(renderer);
    }

    pub fn applyCommands(self: *DebugOverlay, commands: *const FrameCommands) void {
        if (commands.wasPressed(.toggleDebugOverlay) and self.fps_counter.available()) {
            self.visible = !self.visible;
        }
    }

    pub fn recordSubmittedFrame(self: *DebugOverlay, renderer: *Renderer, frame_delta_ns: u64) !void {
        if (!self.visible) return;
        try self.fps_counter.recordSubmittedFrame(renderer, frame_delta_ns);
    }

    pub fn render(self: *const DebugOverlay, renderer: *Renderer) !void {
        if (!self.visible) return;
        try self.fps_counter.render(renderer);
    }
};
