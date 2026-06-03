// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

pub const SdlContext = struct {
    pub fn init(flags: c.SDL_InitFlags) !SdlContext {
        if (!c.SDL_Init(flags)) {
            return sdlError("SDL_Init");
        }
        return .{};
    }

    pub fn deinit(self: *SdlContext) void {
        _ = self;
        c.SDL_Quit();
    }
};

pub const Window = struct {
    handle: *c.SDL_Window,

    pub fn create(title: [:0]const u8, width: u32, height: u32, flags: c.SDL_WindowFlags) !Window {
        const handle = c.SDL_CreateWindow(title.ptr, @intCast(width), @intCast(height), flags) orelse {
            return sdlError("SDL_CreateWindow");
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        c.SDL_DestroyWindow(self.handle);
    }
};

pub fn sdlError(comptime operation: []const u8) error{SdlError} {
    std.log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.SdlError;
}
