// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const resources = @import("../resources.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

pub const bytes_per_pixel = 4;

pub const UploadedTexture = struct {
    texture: *c.SDL_GPUTexture,
    desc: resources.TextureDesc,
};

pub fn uploadFromPixels(
    device: *c.SDL_GPUDevice,
    pixels: []const u8,
    width: u32,
    height: u32,
    pitch: usize,
) !UploadedTexture {
    try validatePixels(pixels, width, height, pitch);
    const desc = resources.TextureDesc{
        .width = width,
        .height = height,
    };
    try desc.validate();

    var texture_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    texture_info.type = c.SDL_GPU_TEXTURETYPE_2D;
    texture_info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    texture_info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
    texture_info.width = width;
    texture_info.height = height;
    texture_info.layer_count_or_depth = 1;
    texture_info.num_levels = 1;
    texture_info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;

    const texture = c.SDL_CreateGPUTexture(device, &texture_info) orelse {
        return sdlError("SDL_CreateGPUTexture");
    };
    errdefer c.SDL_ReleaseGPUTexture(device, texture);

    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = try checkedTextureBytes(pixels.len);
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        return sdlError("SDL_MapGPUTransferBuffer");
    };
    const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..pixels.len];
    @memcpy(mapped_bytes, pixels);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const command_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        return sdlError("SDL_AcquireGPUCommandBuffer");
    };
    var command_buffer_finished = false;
    errdefer if (!command_buffer_finished) {
        _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
    };

    const pixels_per_row = try checkedPixelsPerRow(pitch);
    const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
        return sdlError("SDL_BeginGPUCopyPass");
    };
    var copy_pass_open = true;
    errdefer if (copy_pass_open) {
        c.SDL_EndGPUCopyPass(copy_pass);
    };

    var source = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer,
        .offset = 0,
        .pixels_per_row = pixels_per_row,
        .rows_per_layer = height,
    };
    var destination = c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    copy_pass_open = false;

    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        return sdlError("SDL_SubmitGPUCommandBuffer");
    }
    command_buffer_finished = true;

    return .{
        .texture = texture,
        .desc = desc,
    };
}

pub fn validatePixels(pixels: []const u8, width: u32, height: u32, pitch: usize) !void {
    if (width == 0 or height == 0) return error.InvalidTexturePixels;
    if (pitch % bytes_per_pixel != 0) return error.InvalidTexturePixels;

    const min_pitch = std.math.mul(usize, @intCast(width), bytes_per_pixel) catch return error.InvalidTexturePixels;
    if (pitch < min_pitch) return error.InvalidTexturePixels;

    const required_len = std.math.mul(usize, pitch, @intCast(height)) catch return error.InvalidTexturePixels;
    if (pixels.len < required_len) return error.InvalidTexturePixels;
}

fn checkedTextureBytes(byte_count: usize) error{TextureUploadTooLarge}!u32 {
    return std.math.cast(u32, byte_count) orelse error.TextureUploadTooLarge;
}

fn checkedPixelsPerRow(pitch: usize) error{TextureUploadTooLarge}!u32 {
    const pixels_per_row = pitch / bytes_per_pixel;
    return std.math.cast(u32, pixels_per_row) orelse error.TextureUploadTooLarge;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

test "texture pixel validation rejects invalid dimensions pitch and length" {
    const valid_pixels = [_]u8{255} ** 16;

    try std.testing.expectError(error.InvalidTexturePixels, validatePixels(valid_pixels[0..], 0, 1, 4));
    try std.testing.expectError(error.InvalidTexturePixels, validatePixels(valid_pixels[0..], 1, 0, 4));
    try std.testing.expectError(error.InvalidTexturePixels, validatePixels(valid_pixels[0..], 2, 2, 7));
    try std.testing.expectError(error.InvalidTexturePixels, validatePixels(valid_pixels[0..], 2, 2, 4));
    try std.testing.expectError(error.InvalidTexturePixels, validatePixels(valid_pixels[0..15], 2, 2, 8));
}

test "texture pixel validation accepts tightly packed and padded rows" {
    const tight_pixels = [_]u8{255} ** 16;
    const padded_pixels = [_]u8{255} ** 24;

    try validatePixels(tight_pixels[0..], 2, 2, 8);
    try validatePixels(padded_pixels[0..], 2, 2, 12);
}

test "texture upload sizing rejects SDL u32 overflow" {
    try std.testing.expectEqual(@as(u32, 4096), try checkedTextureBytes(4096));
    try std.testing.expectError(error.TextureUploadTooLarge, checkedTextureBytes(@as(usize, std.math.maxInt(u32)) + 1));
    try std.testing.expectEqual(@as(u32, 8), try checkedPixelsPerRow(8 * bytes_per_pixel));
    try std.testing.expectError(
        error.TextureUploadTooLarge,
        checkedPixelsPerRow((@as(usize, std.math.maxInt(u32)) + 1) * bytes_per_pixel),
    );
}
