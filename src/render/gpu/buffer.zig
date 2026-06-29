// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const sprite_batch = @import("../sprite_batch.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

pub fn createVertexBuffer(device: *c.SDL_GPUDevice, byte_size: u32) !*c.SDL_GPUBuffer {
    var buffer_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    buffer_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    buffer_info.size = byte_size;
    return c.SDL_CreateGPUBuffer(device, &buffer_info) orelse {
        return sdlError("SDL_CreateGPUBuffer");
    };
}

pub fn createVertexTransferBuffer(device: *c.SDL_GPUDevice, byte_size: u32) !*c.SDL_GPUTransferBuffer {
    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = byte_size;
    return c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
}

/// Byte size of one per-attribute vertex column (`vertex_capacity` elements of
/// `element_size` bytes each), rejecting overflow of the SDL `u32` size field.
pub fn columnBytes(vertex_capacity: usize, element_size: usize) error{GpuBufferTooLarge}!u32 {
    const bytes = std.math.mul(usize, vertex_capacity, element_size) catch return error.GpuBufferTooLarge;
    return checkedGpuBytes(bytes);
}

pub fn stageVertices(device: *c.SDL_GPUDevice, transfer_buffer: *c.SDL_GPUTransferBuffer, bytes: []const u8) !void {
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, true) orelse {
        return sdlError("SDL_MapGPUTransferBuffer");
    };
    const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..bytes.len];
    @memcpy(mapped_bytes, bytes);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);
}

pub fn recordVertexUpload(
    command_buffer: *c.SDL_GPUCommandBuffer,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    vertex_buffer: *c.SDL_GPUBuffer,
    bytes: []const u8,
) !void {
    const upload_size = try checkedGpuBytes(bytes.len);
    const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
        return sdlError("SDL_BeginGPUCopyPass");
    };
    var copy_pass_open = true;
    errdefer if (copy_pass_open) {
        c.SDL_EndGPUCopyPass(copy_pass);
    };

    var source = c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
    };
    var destination = c.SDL_GPUBufferRegion{
        .buffer = vertex_buffer,
        .offset = 0,
        .size = upload_size,
    };
    c.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, true);
    c.SDL_EndGPUCopyPass(copy_pass);
    copy_pass_open = false;
}

/// One tile-data storage element. `u32` (not the world's `u16`) keeps the
/// storage layout portable — no 16-bit storage extension — and leaves room to
/// pack variant/light/AO bits later without changing the buffer type.
pub const StorageElement = u32;

/// Creates a graphics-storage-read buffer holding `data` (one element per cell,
/// row-major) and uploads it once via a transient command buffer. The returned
/// buffer is read by the tilemap fragment shader; the caller owns its release.
pub fn uploadStorageData(device: *c.SDL_GPUDevice, data: []const StorageElement) !*c.SDL_GPUBuffer {
    if (data.len == 0) return error.EmptyStorageBuffer;
    const bytes = std.mem.sliceAsBytes(data);
    const upload_size = try checkedGpuBytes(bytes.len);

    var buffer_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    buffer_info.usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
    buffer_info.size = upload_size;
    const buffer = c.SDL_CreateGPUBuffer(device, &buffer_info) orelse {
        return sdlError("SDL_CreateGPUBuffer");
    };
    errdefer c.SDL_ReleaseGPUBuffer(device, buffer);

    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = upload_size;
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        return sdlError("SDL_MapGPUTransferBuffer");
    };
    const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..bytes.len];
    @memcpy(mapped_bytes, bytes);
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
    var source = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = transfer, .offset = 0 };
    var destination = c.SDL_GPUBufferRegion{ .buffer = buffer, .offset = 0, .size = upload_size };
    c.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, false);
    c.SDL_EndGPUCopyPass(copy_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        return sdlError("SDL_SubmitGPUCommandBuffer");
    }
    command_buffer_finished = true;
    return buffer;
}

/// One storage-buffer cell edit: write `value` at `element_index` of `buffer`.
pub const StorageRegion = struct {
    buffer: *c.SDL_GPUBuffer,
    element_index: usize,
    value: StorageElement,
};

/// Uploads a batch of single-cell edits (the dig path) in one transfer buffer +
/// one copy pass + one submit, so a multi-cell edit is a single GPU round-trip
/// rather than one per cell. Edits may target different buffers. `cycle = false`
/// is mandatory for partial-region writes: `cycle = true` would rotate the whole
/// buffer to fresh memory and leave every un-written cell garbage. The tradeoff is
/// a write may race a prior in-flight frame's read of the same cell (self-correcting
/// next frame), the same in-place pattern as the initial full upload.
pub fn uploadStorageRegions(device: *c.SDL_GPUDevice, edits: []const StorageRegion) !void {
    if (edits.len == 0) return;
    const element_size: u32 = @sizeOf(StorageElement);
    const total_bytes = try storageByteSize(edits.len);

    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = total_bytes;
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        return sdlError("SDL_MapGPUTransferBuffer");
    };
    const values = @as([*]StorageElement, @ptrCast(@alignCast(mapped)))[0..edits.len];
    for (edits, values) |edit, *slot| slot.* = edit.value;
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
    for (edits, 0..) |edit, i| {
        const dst_byte_offset = std.math.mul(usize, edit.element_index, element_size) catch return error.GpuBufferTooLarge;
        var source = c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = transfer,
            .offset = @intCast(i * element_size),
        };
        var destination = c.SDL_GPUBufferRegion{
            .buffer = edit.buffer,
            .offset = try checkedGpuBytes(dst_byte_offset),
            .size = element_size,
        };
        c.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, false);
    }
    c.SDL_EndGPUCopyPass(copy_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        return sdlError("SDL_SubmitGPUCommandBuffer");
    }
    command_buffer_finished = true;
}

/// Byte size of a `count`-element storage buffer, rejecting overflow of the
/// SDL `u32` size field.
pub fn storageByteSize(element_count: usize) error{GpuBufferTooLarge}!u32 {
    const bytes = std.math.mul(usize, element_count, @sizeOf(StorageElement)) catch return error.GpuBufferTooLarge;
    return checkedGpuBytes(bytes);
}

fn checkedGpuBytes(byte_count: usize) error{GpuBufferTooLarge}!u32 {
    return std.math.cast(u32, byte_count) orelse error.GpuBufferTooLarge;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

test "per-column vertex byte sizing matches element size and rejects overflow" {
    // Position/Uv columns are 8 bytes/vertex (FLOAT2); the color column is 16
    // bytes/vertex (FLOAT4).
    try std.testing.expectEqual(@as(u32, 8 * 4), try columnBytes(4, @sizeOf(sprite_batch.Position)));
    try std.testing.expectEqual(@as(u32, 8 * 4), try columnBytes(4, @sizeOf(sprite_batch.Uv)));
    try std.testing.expectEqual(@as(u32, 16 * 4), try columnBytes(4, @sizeOf(sprite_batch.VertexColor)));

    try std.testing.expectError(error.GpuBufferTooLarge, columnBytes(std.math.maxInt(usize), @sizeOf(sprite_batch.Position)));
    try std.testing.expectError(
        error.GpuBufferTooLarge,
        columnBytes(@as(usize, std.math.maxInt(u32)) / @sizeOf(sprite_batch.VertexColor) + 1, @sizeOf(sprite_batch.VertexColor)),
    );
}

test "storage byte sizing is 4 bytes per element and rejects overflow" {
    try std.testing.expectEqual(@as(u32, 16), try storageByteSize(4));
    try std.testing.expectError(error.GpuBufferTooLarge, storageByteSize(std.math.maxInt(usize)));
    try std.testing.expectError(
        error.GpuBufferTooLarge,
        storageByteSize(@as(usize, std.math.maxInt(u32)) / @sizeOf(StorageElement) + 1),
    );
}

test "GPU byte sizing rejects values above SDL u32 limit" {
    try std.testing.expectEqual(@as(u32, 4096), try checkedGpuBytes(4096));
    try std.testing.expectError(error.GpuBufferTooLarge, checkedGpuBytes(@as(usize, std.math.maxInt(u32)) + 1));
}
