// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Render-resource contracts for future slot-backed texture and sampler ownership.
//! Draw submission should use validated IDs, not hash lookups or raw long-lived indices.

const std = @import("std");

pub const TextureId = struct {
    index: u32,
    generation: u32,

    pub const invalid = TextureId{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !TextureId {
        if (index == std.math.maxInt(u32)) return error.InvalidTextureIndex;
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: TextureId) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }

    pub fn matches(self: TextureId, index: u32, generation: u32) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

/// Opaque handle to a renderer-owned tilemap tile-data storage buffer. World and
/// game code hold these per dense layer; the renderer owns the GPU resource. The
/// enum's value is the buffer's index in the renderer registry.
pub const TileDataId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,
};

pub const TextureFormat = enum {
    rgba8_unorm,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat = .rgba8_unorm,

    pub fn validate(self: TextureDesc) !void {
        if (self.width == 0 or self.height == 0) return error.InvalidTextureSize;
    }
};

pub const FilterMode = enum {
    nearest,
    linear,
};

pub const AddressMode = enum {
    clamp_to_edge,
    repeat,
};

pub const SamplerDesc = struct {
    min_filter: FilterMode = .nearest,
    mag_filter: FilterMode = .nearest,
    address_u: AddressMode = .clamp_to_edge,
    address_v: AddressMode = .clamp_to_edge,
};

pub fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

test "texture ids reject generation zero and match slots exactly" {
    try std.testing.expectError(error.InvalidTextureIndex, TextureId.init(std.math.maxInt(u32), 1));
    try std.testing.expectError(error.InvalidGeneration, TextureId.init(3, 0));

    const id = try TextureId.init(3, 7);
    try std.testing.expect(id.isValid());
    try std.testing.expect(id.matches(3, 7));
    try std.testing.expect(!id.matches(3, 8));
    try std.testing.expect(!TextureId.invalid.isValid());
}

test "texture descriptors require non-zero dimensions" {
    try std.testing.expectError(error.InvalidTextureSize, (TextureDesc{ .width = 0, .height = 16 }).validate());
    try std.testing.expectError(error.InvalidTextureSize, (TextureDesc{ .width = 16, .height = 0 }).validate());
    try (TextureDesc{ .width = 16, .height = 16 }).validate();
}

test "resource generations skip the invalid zero value" {
    try std.testing.expectEqual(@as(u32, 6), nextGeneration(5));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(std.math.maxInt(u32)));
}
