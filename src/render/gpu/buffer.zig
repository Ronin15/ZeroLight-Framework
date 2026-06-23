// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const sprite_batch = @import("../sprite_batch.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

pub fn createVertexBuffer(device: *c.SDL_GPUDevice, vertex_capacity: usize) !*c.SDL_GPUBuffer {
    var buffer_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    buffer_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    buffer_info.size = try vertexByteSize(vertex_capacity);
    return c.SDL_CreateGPUBuffer(device, &buffer_info) orelse {
        return sdlError("SDL_CreateGPUBuffer");
    };
}

pub fn createVertexTransferBuffer(device: *c.SDL_GPUDevice, vertex_capacity: usize) !*c.SDL_GPUTransferBuffer {
    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = try vertexByteSize(vertex_capacity);
    return c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
}

pub fn stageVertices(device: *c.SDL_GPUDevice, transfer_buffer: *c.SDL_GPUTransferBuffer, vertices: []const sprite_batch.Vertex) !void {
    const bytes = std.mem.sliceAsBytes(vertices);
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
    vertices: []const sprite_batch.Vertex,
) !void {
    const bytes = std.mem.sliceAsBytes(vertices);
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

fn vertexByteSize(vertex_capacity: usize) error{GpuBufferTooLarge}!u32 {
    const bytes = std.math.mul(usize, vertex_capacity, @sizeOf(sprite_batch.Vertex)) catch return error.GpuBufferTooLarge;
    return checkedGpuBytes(bytes);
}

fn checkedGpuBytes(byte_count: usize) error{GpuBufferTooLarge}!u32 {
    return std.math.cast(u32, byte_count) orelse error.GpuBufferTooLarge;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

test "vertex buffer byte sizing rejects overflow and SDL u32 overflow" {
    try std.testing.expectEqual(
        @as(u32, @sizeOf(sprite_batch.Vertex) * 4),
        try vertexByteSize(4),
    );
    try std.testing.expectError(error.GpuBufferTooLarge, vertexByteSize(std.math.maxInt(usize)));
    try std.testing.expectError(
        error.GpuBufferTooLarge,
        vertexByteSize(@as(usize, std.math.maxInt(u32)) / @sizeOf(sprite_batch.Vertex) + 1),
    );
}

test "GPU byte sizing rejects values above SDL u32 limit" {
    try std.testing.expectEqual(@as(u32, 4096), try checkedGpuBytes(4096));
    try std.testing.expectError(error.GpuBufferTooLarge, checkedGpuBytes(@as(usize, std.math.maxInt(u32)) + 1));
}
