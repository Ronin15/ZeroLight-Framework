// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! CPU-side image loading for runtime assets.

const std = @import("std");
const AssetStore = @import("assets.zig").AssetStore;
const log = @import("../core/logging.zig").assets;
const sdl = @import("../platform/sdl.zig");
const c = sdl.c;

pub const ImageFormat = enum {
    rgba8,
};

pub const LoadedImage = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    pitch: usize,
    format: ImageFormat = .rgba8,

    pub fn deinit(self: *LoadedImage) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn loadPng(assets: AssetStore, relative_path: []const u8) !LoadedImage {
    const path = assets.resolveReadablePath(relative_path) catch |err| {
        return err;
    };
    defer assets.allocator.free(path);

    const path_z = try assets.allocator.dupeZ(u8, path);
    defer assets.allocator.free(path_z);

    const loaded = c.SDL_LoadPNG(path_z.ptr) orelse {
        log.err("SDL_LoadPNG failed for image \"{s}\": {s}", .{ relative_path, c.SDL_GetError() });
        return error.SdlError;
    };
    defer c.SDL_DestroySurface(loaded);

    const converted = c.SDL_ConvertSurface(loaded, c.SDL_PIXELFORMAT_RGBA32) orelse {
        log.err("SDL_ConvertSurface failed for image \"{s}\": {s}", .{ relative_path, c.SDL_GetError() });
        return error.SdlError;
    };
    defer c.SDL_DestroySurface(converted);

    if (!c.SDL_LockSurface(converted)) {
        log.err("SDL_LockSurface failed for image \"{s}\": {s}", .{ relative_path, c.SDL_GetError() });
        return error.SdlError;
    }
    defer c.SDL_UnlockSurface(converted);

    const pixels = converted.*.pixels orelse return error.SdlError;
    const width: u32 = @intCast(converted.*.w);
    const height: u32 = @intCast(converted.*.h);
    const pitch: usize = @intCast(converted.*.pitch);
    const byte_len = pitch * @as(usize, @intCast(converted.*.h));
    const owned_pixels = try assets.allocator.dupe(u8, @as([*]const u8, @ptrCast(pixels))[0..byte_len]);
    errdefer assets.allocator.free(owned_pixels);

    log.debug("loaded PNG image \"{s}\" {}x{} pitch={}", .{ relative_path, width, height, pitch });
    return .{
        .allocator = assets.allocator,
        .pixels = owned_pixels,
        .width = width,
        .height = height,
        .pitch = pitch,
    };
}

test "PNG image loader decodes asset fixture as RGBA8" {
    const assets = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var image = try loadPng(assets, "test/cache_probe.png");
    defer image.deinit();

    try std.testing.expectEqual(ImageFormat.rgba8, image.format);
    try std.testing.expect(image.width > 0);
    try std.testing.expect(image.height > 0);
    try std.testing.expect(image.pitch >= image.width * 4);
    try std.testing.expect(image.pixels.len >= image.pitch * image.height);
}

test "PNG image loader rejects invalid and missing paths" {
    const assets = AssetStore.init(std.testing.allocator, std.testing.io, "assets");

    try std.testing.expectError(error.InvalidAssetPath, loadPng(assets, "../bad.png"));
    try std.testing.expectError(error.FileNotFound, loadPng(assets, "missing/nope.png"));
}
