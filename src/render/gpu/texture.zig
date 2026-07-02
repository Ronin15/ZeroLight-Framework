// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! GPU texture upload from CPU pixels. The caller owns the returned SDL texture
//! until it is registered and released through `Renderer` / `resources.zig`.

const std = @import("std");
const resources = @import("../resources.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

pub const bytes_per_pixel = 4;

/// Live GPU texture plus the descriptor used to register it in the renderer catalog.
/// Release through `Renderer` registration teardown (`SDL_ReleaseGPUTexture`).
pub const UploadedTexture = struct {
    texture: *c.SDL_GPUTexture,
    desc: resources.TextureDesc,
};

pub const BatchUploadItem = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    pitch: usize,
};

const PreparedBatchUpload = struct {
    texture: *c.SDL_GPUTexture,
    desc: resources.TextureDesc,
    required_len: usize,
    pixels_per_row: u32,
};

/// Validates pixels, uploads to new GPU textures, and submits one command buffer
/// with one copy pass over all regions. Caller owns each `UploadedTexture.texture`
/// until registered/released. The returned slice is always allocator-owned (including
/// empty batches) and must be freed by the caller. Transfer buffer is single-use per
/// call; all `SDL_UploadToGPUTexture` calls pass `cycle=false`.
pub fn uploadTexturesBatch(
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    items: []const BatchUploadItem,
) ![]UploadedTexture {
    if (items.len == 0) return try allocator.alloc(UploadedTexture, 0);

    const prepared = try allocator.alloc(PreparedBatchUpload, items.len);
    defer allocator.free(prepared);
    var prepared_count: usize = 0;
    errdefer for (prepared[0..prepared_count]) |entry| {
        c.SDL_ReleaseGPUTexture(device, entry.texture);
    };

    var total_transfer_bytes: usize = 0;
    for (items, prepared) |item, *out| {
        try validatePixels(item.pixels, item.width, item.height, item.pitch);
        const required_len = try requiredPixelBytes(item.height, item.pitch);
        const pixels_per_row = try checkedPixelsPerRow(item.pitch);
        const desc = resources.TextureDesc{
            .width = item.width,
            .height = item.height,
        };
        try desc.validate();

        var texture_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        texture_info.type = c.SDL_GPU_TEXTURETYPE_2D;
        texture_info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        texture_info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        texture_info.width = item.width;
        texture_info.height = item.height;
        texture_info.layer_count_or_depth = 1;
        texture_info.num_levels = 1;
        texture_info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;

        const texture = c.SDL_CreateGPUTexture(device, &texture_info) orelse {
            return sdlError("SDL_CreateGPUTexture");
        };

        out.* = .{
            .texture = texture,
            .desc = desc,
            .required_len = required_len,
            .pixels_per_row = pixels_per_row,
        };
        prepared_count += 1;
        total_transfer_bytes = std.math.add(usize, total_transfer_bytes, required_len) catch return error.TextureUploadTooLarge;
    }

    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = try checkedTextureBytes(total_transfer_bytes);
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        return sdlError("SDL_MapGPUTransferBuffer");
    };
    const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..total_transfer_bytes];

    var transfer_offset: usize = 0;
    for (items, prepared) |item, prep| {
        @memcpy(mapped_bytes[transfer_offset..][0..prep.required_len], item.pixels[0..prep.required_len]);
        transfer_offset = std.math.add(usize, transfer_offset, prep.required_len) catch return error.TextureUploadTooLarge;
    }
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const command_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        return sdlError("SDL_AcquireGPUCommandBuffer");
    };
    var command_buffer_finished = false;
    errdefer if (!command_buffer_finished) {
        _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
        return sdlError("SDL_BeginGPUCopyPass");
    };
    var copy_pass_open = true;
    errdefer if (copy_pass_open) {
        c.SDL_EndGPUCopyPass(copy_pass);
    };

    transfer_offset = 0;
    for (prepared) |prep| {
        var source = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer,
            .offset = @intCast(transfer_offset),
            .pixels_per_row = prep.pixels_per_row,
            .rows_per_layer = prep.desc.height,
        };
        var destination = c.SDL_GPUTextureRegion{
            .texture = prep.texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = prep.desc.width,
            .h = prep.desc.height,
            .d = 1,
        };
        c.SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
        transfer_offset = std.math.add(usize, transfer_offset, prep.required_len) catch return error.TextureUploadTooLarge;
    }
    c.SDL_EndGPUCopyPass(copy_pass);
    copy_pass_open = false;

    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        return sdlError("SDL_SubmitGPUCommandBuffer");
    }
    command_buffer_finished = true;

    const uploaded = try allocator.alloc(UploadedTexture, items.len);
    errdefer allocator.free(uploaded);
    for (prepared, uploaded) |prep, *out| {
        out.* = .{
            .texture = prep.texture,
            .desc = prep.desc,
        };
    }
    return uploaded;
}

/// Validates pixels, uploads to a new GPU texture, and submits a one-shot command
/// buffer. Caller owns `UploadedTexture.texture` until registered/released.
pub fn uploadFromPixels(
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    pixels: []const u8,
    width: u32,
    height: u32,
    pitch: usize,
) !UploadedTexture {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const uploaded = try uploadTexturesBatch(arena.allocator(), device, &.{.{
        .pixels = pixels,
        .width = width,
        .height = height,
        .pitch = pitch,
    }});
    return uploaded[0];
}

pub fn validatePixels(pixels: []const u8, width: u32, height: u32, pitch: usize) !void {
    if (width == 0 or height == 0) return error.InvalidTexturePixels;
    if (pitch % bytes_per_pixel != 0) return error.InvalidTexturePixels;

    const min_pitch = std.math.mul(usize, @intCast(width), bytes_per_pixel) catch return error.InvalidTexturePixels;
    if (pitch < min_pitch) return error.InvalidTexturePixels;

    const required_len = try requiredPixelBytes(height, pitch);
    if (pixels.len < required_len) return error.InvalidTexturePixels;
}

pub fn requiredPixelBytes(height: u32, pitch: usize) error{InvalidTexturePixels}!usize {
    return std.math.mul(usize, pitch, @intCast(height)) catch error.InvalidTexturePixels;
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

test "required pixel bytes uses pitch times height" {
    try std.testing.expectEqual(@as(usize, 24), try requiredPixelBytes(2, 12));
}

test "texture batch empty result is allocator owned" {
    const allocator = std.testing.allocator;
    const uploaded = try uploadTexturesBatch(allocator, @ptrFromInt(1), &.{});
    defer allocator.free(uploaded);
    try std.testing.expectEqual(@as(usize, 0), uploaded.len);
}
