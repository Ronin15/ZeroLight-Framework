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

pub fn validateUploadBytes(byte_count: usize, buffer_byte_size: u32) error{GpuUploadOutOfBounds}!void {
    if (byte_count > std.math.maxInt(u32) or byte_count > buffer_byte_size) {
        return error.GpuUploadOutOfBounds;
    }
}

pub fn stageVertices(
    device: *c.SDL_GPUDevice,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    transfer_byte_size: u32,
    bytes: []const u8,
) !void {
    try validateUploadBytes(bytes.len, transfer_byte_size);
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, true) orelse {
        return sdlError("SDL_MapGPUTransferBuffer");
    };
    const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..bytes.len];
    @memcpy(mapped_bytes, bytes);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);
}

/// RAII wrapper for one SDL_GPU copy pass. Batch multiple uploads in a single
/// pass via `recordVertexUploadInPass` / `recordStorageSpansInPass`, then end
/// once with `end`. `cycle` is a per-destination-buffer decision, not a
/// per-pass one: pass `cycle=true` on every full-buffer rewrite regardless of
/// how many other uploads (to other buffers) share this pass, since skipping
/// it lets a later in-flight frame overwrite data a still-in-flight draw is
/// reading from that same buffer. Only a partial write into a retained buffer
/// (e.g. tile-store spans) should pass `cycle=false`.
pub const CopyPassScope = struct {
    pass: *c.SDL_GPUCopyPass,
    open: bool = true,

    /// Callers must `defer scope.end()` on every success path.
    pub fn begin(command_buffer: *c.SDL_GPUCommandBuffer) !CopyPassScope {
        const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
            return sdlError("SDL_BeginGPUCopyPass");
        };
        return .{ .pass = copy_pass };
    }

    pub fn end(self: *CopyPassScope) void {
        if (self.open) {
            c.SDL_EndGPUCopyPass(self.pass);
            self.open = false;
        }
    }
};

pub fn recordVertexUploadInPass(
    copy_pass: *c.SDL_GPUCopyPass,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    transfer_byte_size: u32,
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_buffer_byte_size: u32,
    bytes: []const u8,
    cycle: bool,
) !void {
    const upload_size = try checkedGpuBytes(bytes.len);
    try validateUploadBytes(bytes.len, vertex_buffer_byte_size);
    try validateUploadBytes(bytes.len, transfer_byte_size);

    var source = c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
    };
    var destination = c.SDL_GPUBufferRegion{
        .buffer = vertex_buffer,
        .offset = 0,
        .size = upload_size,
    };
    c.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, cycle);
}

/// One-shot vertex upload that opens/ends its own copy pass. Treats
/// `vertex_buffer_byte_size` as both transfer and destination capacity (paired
/// streams share that size). Callers that stage separately, share a pass, or
/// need distinct transfer vs vertex sizes must use `stageVertices` +
/// `recordVertexUploadInPass` instead.
pub fn recordVertexUpload(
    command_buffer: *c.SDL_GPUCommandBuffer,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_buffer_byte_size: u32,
    bytes: []const u8,
) !void {
    var copy_pass_scope = try CopyPassScope.begin(command_buffer);
    defer copy_pass_scope.end();
    try recordVertexUploadInPass(
        copy_pass_scope.pass,
        transfer_buffer,
        vertex_buffer_byte_size,
        vertex_buffer,
        vertex_buffer_byte_size,
        bytes,
        true,
    );
}

/// One tile-store storage element: a directory word or two packed `u16` tile ids
/// (see `renderer.zig` tile store layout). A `u32` element keeps the storage
/// layout portable, with no 16-bit storage extension.
pub const StorageElement = u32;

/// `count` consecutive elements written at `dst_element`; their values are staged
/// contiguously in span order.
pub const StorageSpan = struct {
    dst_element: u32,
    count: u32,

    pub fn end(self: StorageSpan) u64 {
        return @as(u64, self.dst_element) + self.count;
    }
};

/// Creates a graphics-storage-read buffer of `element_capacity` elements for the
/// tilemap fragment shader. Contents are undefined until written; the caller owns
/// its release.
pub fn createStorageBuffer(device: *c.SDL_GPUDevice, element_capacity: u32) !*c.SDL_GPUBuffer {
    if (element_capacity == 0) return error.EmptyStorageBuffer;
    var buffer_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    buffer_info.usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
    buffer_info.size = try storageByteSize(element_capacity);
    return c.SDL_CreateGPUBuffer(device, &buffer_info) orelse {
        return sdlError("SDL_CreateGPUBuffer");
    };
}

/// Checks one upload batch before it is staged: spans nonempty, strictly increasing
/// and non-overlapping, inside `element_capacity`, with counts summing to
/// `value_count`.
pub fn validateStorageSpans(spans: []const StorageSpan, value_count: usize, element_capacity: u32) error{GpuUploadOutOfBounds}!void {
    var total: u64 = 0;
    var previous_end: u64 = 0;
    for (spans, 0..) |span, index| {
        if (span.count == 0) return error.GpuUploadOutOfBounds;
        if (index > 0 and span.dst_element < previous_end) return error.GpuUploadOutOfBounds;
        if (span.end() > element_capacity) return error.GpuUploadOutOfBounds;
        previous_end = span.end();
        total += span.count;
    }
    if (total != value_count) return error.GpuUploadOutOfBounds;
}

/// Records `spans` into an open copy pass, reading their values from
/// `transfer_buffer` starting at element `transfer_first_element`. Always
/// `cycle=false`: the destination is a retained, partially written tile store.
/// Records nothing when a span leaves the buffer or the staged values overrun
/// the transfer.
pub fn recordStorageSpansInPass(
    copy_pass: *c.SDL_GPUCopyPass,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    transfer_byte_size: u32,
    transfer_first_element: u32,
    buffer: *c.SDL_GPUBuffer,
    element_capacity: u32,
    spans: []const StorageSpan,
) !void {
    // Bounds are checked for the whole batch before the first upload is recorded.
    var staged_elements: usize = transfer_first_element;
    for (spans) |span| {
        if (span.end() > element_capacity) return error.GpuUploadOutOfBounds;
        staged_elements += span.count;
    }
    if (try storageByteSize(staged_elements) > transfer_byte_size) return error.GpuUploadOutOfBounds;

    var source_element: usize = transfer_first_element;
    for (spans) |span| {
        var source = c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = transfer_buffer,
            .offset = try storageByteSize(source_element),
        };
        var destination = c.SDL_GPUBufferRegion{
            .buffer = buffer,
            .offset = try storageByteSize(span.dst_element),
            .size = try storageByteSize(span.count),
        };
        c.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, false);
        source_element += span.count;
    }
}

/// Records a buffer-to-buffer copy of `count` elements at the same element offset in
/// both buffers into an open copy pass (`cycle=false`).
pub fn recordStorageCopyInPass(
    copy_pass: *c.SDL_GPUCopyPass,
    source_buffer: *c.SDL_GPUBuffer,
    destination_buffer: *c.SDL_GPUBuffer,
    first_element: u32,
    count: u32,
) error{GpuBufferTooLarge}!void {
    const offset = try storageByteSize(first_element);
    var source = c.SDL_GPUBufferLocation{ .buffer = source_buffer, .offset = offset };
    var destination = c.SDL_GPUBufferLocation{ .buffer = destination_buffer, .offset = offset };
    c.SDL_CopyGPUBufferToBuffer(copy_pass, &source, &destination, try storageByteSize(count), false);
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

test "vertex upload validation rejects oversized staging slices" {
    try std.testing.expectError(error.GpuUploadOutOfBounds, validateUploadBytes(4096, 1024));
    try validateUploadBytes(512, 1024);
}

test "storage span in-pass recording rejects spans past the transfer staging" {
    const spans = [_]StorageSpan{
        .{ .dst_element = 0, .count = 1 },
        .{ .dst_element = 4, .count = 2 },
    };
    // Three staged values need 12 bytes; an 8-byte transfer fails before any upload.
    try std.testing.expectError(
        error.GpuUploadOutOfBounds,
        recordStorageSpansInPass(@ptrFromInt(1), @ptrFromInt(2), 2 * @sizeOf(StorageElement), 0, @ptrFromInt(3), 8, &spans),
    );
    try std.testing.expectError(
        error.GpuUploadOutOfBounds,
        recordStorageSpansInPass(@ptrFromInt(1), @ptrFromInt(2), 64, 0, @ptrFromInt(3), 5, &spans),
    );
}

test "vertex upload in-pass validation rejects oversized transfer staging" {
    const bytes: [16]u8 = @splat(0);
    try std.testing.expectError(
        error.GpuUploadOutOfBounds,
        recordVertexUploadInPass(@ptrFromInt(1), @ptrFromInt(2), 8, @ptrFromInt(3), 16, &bytes, false),
    );
}

test "storage span validation requires sorted disjoint in-bounds spans matching the value count" {
    const ok = [_]StorageSpan{
        .{ .dst_element = 0, .count = 4 },
        .{ .dst_element = 4, .count = 1 },
        .{ .dst_element = 7, .count = 1 },
    };
    try validateStorageSpans(&ok, 6, 8);
    try std.testing.expectError(error.GpuUploadOutOfBounds, validateStorageSpans(&ok, 5, 8));
    try std.testing.expectError(error.GpuUploadOutOfBounds, validateStorageSpans(&ok, 6, 7));
    const overlapping = [_]StorageSpan{
        .{ .dst_element = 0, .count = 4 },
        .{ .dst_element = 3, .count = 1 },
    };
    try std.testing.expectError(error.GpuUploadOutOfBounds, validateStorageSpans(&overlapping, 5, 8));
    const unsorted = [_]StorageSpan{
        .{ .dst_element = 4, .count = 1 },
        .{ .dst_element = 0, .count = 1 },
    };
    try std.testing.expectError(error.GpuUploadOutOfBounds, validateStorageSpans(&unsorted, 2, 8));
    const empty_span = [_]StorageSpan{.{ .dst_element = 0, .count = 0 }};
    try std.testing.expectError(error.GpuUploadOutOfBounds, validateStorageSpans(&empty_span, 0, 8));
}
