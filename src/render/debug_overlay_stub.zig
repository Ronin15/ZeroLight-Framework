// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const FrameCommands = @import("../app/input.zig").FrameCommands;
const Renderer = @import("renderer.zig").Renderer;
const TextService = @import("text.zig").TextService;

pub const DebugOverlay = struct {
    pub fn init(text_service: *TextService) DebugOverlay {
        _ = text_service;
        return .{};
    }

    pub fn deinit(self: *DebugOverlay) void {
        _ = self;
    }

    pub fn applyCommands(self: *DebugOverlay, commands: *const FrameCommands) void {
        _ = self;
        _ = commands;
    }

    pub fn prepareForRender(
        self: *DebugOverlay,
        text_service: *TextService,
        renderer: *Renderer,
    ) !void {
        _ = self;
        _ = text_service;
        _ = renderer;
    }

    pub fn recordSubmittedFrame(
        self: *DebugOverlay,
        frame_delta_ns: u64,
    ) void {
        _ = self;
        _ = frame_delta_ns;
    }

    pub fn render(self: *const DebugOverlay, renderer: *Renderer) !void {
        _ = self;
        _ = renderer;
    }
};
