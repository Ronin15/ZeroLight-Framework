// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const FrameCommands = @import("../app/input.zig").FrameCommands;
const Renderer = @import("renderer.zig").Renderer;

pub const DebugOverlay = struct {
    pub fn init() DebugOverlay {
        return .{};
    }

    pub fn deinit(self: *DebugOverlay, renderer: *Renderer) void {
        _ = self;
        _ = renderer;
    }

    pub fn applyCommands(self: *DebugOverlay, commands: *const FrameCommands) void {
        _ = self;
        _ = commands;
    }

    pub fn recordSubmittedFrame(self: *DebugOverlay, renderer: *Renderer, frame_delta_ns: u64) !void {
        _ = self;
        _ = renderer;
        _ = frame_delta_ns;
    }

    pub fn render(self: *const DebugOverlay, renderer: *Renderer) !void {
        _ = self;
        _ = renderer;
    }
};
