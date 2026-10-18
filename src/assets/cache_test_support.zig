// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! A fake texture backend for `AssetCache` tests and the asset owners that drive the
//! cache's backend-context seam. Test-only: no production path imports it.

const std = @import("std");
const assets = @import("assets.zig");
const image = @import("image.zig");
const AssetCache = @import("cache.zig").AssetCache;
const TextureBackend = @import("cache.zig").TextureBackend;
const TextureId = @import("../render/resources.zig").TextureId;

pub const FakeBackend = struct {
    upload_count: u32 = 0,
    batch_upload_count: u32 = 0,
    destroy_count: u32 = 0,
    next_index: u32 = 0,
    fail_upload: bool = false,
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_pitch: usize = 0,

    pub fn backend() TextureBackend {
        return .{
            .upload_images_batch = uploadImagesBatch,
            .destroy_texture = destroyTexture,
        };
    }

    fn uploadImage(context: *anyopaque, loaded_image: image.LoadedImage) !TextureId {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_upload) return error.FakeUploadFailed;

        const texture = try TextureId.init(self.next_index, 1);
        self.next_index += 1;
        self.upload_count += 1;
        self.last_width = loaded_image.width;
        self.last_height = loaded_image.height;
        self.last_pitch = loaded_image.pitch;
        return texture;
    }

    fn uploadImagesBatch(context: *anyopaque, allocator: std.mem.Allocator, images: []const image.LoadedImage) ![]TextureId {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_upload) return error.FakeUploadFailed;

        const ids = try allocator.alloc(TextureId, images.len);
        errdefer allocator.free(ids);
        for (images, ids) |loaded_image, *id| {
            id.* = try uploadImage(context, loaded_image);
        }
        self.batch_upload_count += 1;
        return ids;
    }

    fn destroyTexture(context: *anyopaque, texture: TextureId) void {
        _ = texture;
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.destroy_count += 1;
    }
};

/// A cache over `asset_store` whose uploads and destroys go to a `FakeBackend`.
pub fn initCache(allocator: std.mem.Allocator, asset_store: assets.AssetStore) AssetCache {
    return AssetCache.initWithBackend(allocator, asset_store, FakeBackend.backend());
}
