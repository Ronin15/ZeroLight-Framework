// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const FpsCounter = @import("fps_counter.zig").FpsCounter;
const FrameCommands = @import("../app/input.zig").FrameCommands;
const Renderer = @import("renderer.zig").Renderer;
const TextService = @import("text.zig").TextService;

pub const DebugOverlay = struct {
    visible: bool = false,
    fps_counter: FpsCounter = .{},

    pub fn init(text_service: *TextService) DebugOverlay {
        return .{ .fps_counter = FpsCounter.init(text_service) };
    }

    pub fn deinit(self: *DebugOverlay) void {
        self.fps_counter.deinit();
    }

    pub fn applyCommands(self: *DebugOverlay, commands: *const FrameCommands) void {
        if (commands.wasPressed(.toggleDebugOverlay)) {
            self.visible = !self.visible;
        }
    }

    pub fn prepareForRender(
        self: *DebugOverlay,
        text_service: *TextService,
        renderer: *Renderer,
    ) !void {
        if (!self.visible) return;
        try self.fps_counter.prepareForRender(text_service, renderer);
    }

    pub fn recordSubmittedFrame(
        self: *DebugOverlay,
        frame_delta_ns: u64,
    ) void {
        if (!self.visible) return;
        self.fps_counter.recordSubmittedFrame(frame_delta_ns);
    }

    pub fn render(self: *const DebugOverlay, renderer: *Renderer) !void {
        if (!self.visible) return;
        try self.fps_counter.render(renderer);
    }
};
