// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Runtime asset cache for renderer-backed resources.
//! Cache lookups are intended for setup, state transitions, and explicit release
//! points. Hot render paths should keep drawing with retained TextureId values.
//! TextureLease is a non-owning token: the cache remains the owner of retain
//! counts and the renderer remains the owner of GPU texture destruction.

const std = @import("std");
const builtin = @import("builtin");
const assets = @import("assets.zig");
const image = @import("image.zig");
const log = @import("../core/logging.zig").assets;
const Renderer = @import("../render/renderer.zig").Renderer;
const TextureId = @import("../render/resources.zig").TextureId;

pub const TextureLease = struct {
    handle: LeaseHandle = LeaseHandle.invalid,
    id: TextureId = TextureId.invalid,
    owner_id: u64 = 0,

    pub fn isAlive(self: TextureLease) bool {
        return self.owner_id != 0 and self.handle.isValid() and self.id.isValid();
    }
};

pub const AssetCache = struct {
    allocator: std.mem.Allocator,
    assets: assets.AssetStore,
    backend: TextureBackend,
    owner_id: u64,
    entries: std.StringHashMapUnmanaged(TextureEntry) = .empty,
    lease_slots: std.ArrayList(LeaseSlot) = .empty,
    first_free_lease_slot: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, assetStore: assets.AssetStore) AssetCache {
        return initWithBackend(allocator, assetStore, rendererBackend());
    }

    pub fn deinit(self: *AssetCache, renderer: *Renderer) void {
        self.deinitWithContext(@ptrCast(renderer));
    }

    pub fn acquireTexture(self: *AssetCache, renderer: *Renderer, relative_path: []const u8) !TextureLease {
        return self.acquireTextureWithContext(@ptrCast(renderer), relative_path);
    }

    pub fn releaseTexture(self: *AssetCache, renderer: *Renderer, lease: *TextureLease) void {
        self.releaseTextureWithContext(@ptrCast(renderer), lease);
    }

    fn initWithBackend(allocator: std.mem.Allocator, assetStore: assets.AssetStore, backend: TextureBackend) AssetCache {
        return .{
            .allocator = allocator,
            .assets = assetStore,
            .backend = backend,
            .owner_id = nextCacheOwnerId(),
        };
    }

    /// Backend-context seam shared by the renderer-facing wrappers and asset
    /// owners that thread their own texture backend (e.g. a `*Renderer` or, in
    /// tests, a fake backend) through the cache. The context must match the
    /// `TextureBackend` the cache was created with.
    pub fn acquireTextureWithContext(
        self: *AssetCache,
        backend_context: *anyopaque,
        relative_path: []const u8,
    ) !TextureLease {
        try assets.validateRelativePath(relative_path);

        if (self.entries.getPtr(relative_path)) |entry| {
            if (entry.retain_count == std.math.maxInt(u32)) return error.TooManyTextureLeases;
            const lease = try self.createLease(entry.path, entry.texture);
            entry.retain_count += 1;
            log.debug("retained cached texture \"{s}\" count={}", .{ entry.path, entry.retain_count });
            return .{
                .handle = lease,
                .id = entry.texture,
                .owner_id = self.owner_id,
            };
        }

        const owned_path = try self.allocator.dupe(u8, relative_path);
        var entry_inserted = false;
        errdefer if (!entry_inserted) self.allocator.free(owned_path);

        var loaded_image = image.loadPng(self.assets, owned_path) catch |err| {
            log.warn("texture asset unavailable \"{s}\": {}", .{ owned_path, err });
            return err;
        };
        defer loaded_image.deinit();

        const texture = try self.backend.upload_image(backend_context, loaded_image);
        var texture_inserted = false;
        errdefer if (!texture_inserted) self.backend.destroy_texture(backend_context, texture);

        try self.entries.put(self.allocator, owned_path, .{
            .path = owned_path,
            .texture = texture,
            .retain_count = 1,
        });
        entry_inserted = true;
        texture_inserted = true;
        errdefer {
            const removed = self.entries.fetchRemove(owned_path);
            std.debug.assert(removed != null);
            self.backend.destroy_texture(backend_context, texture);
            self.allocator.free(owned_path);
        }

        const lease = try self.createLease(owned_path, texture);
        log.debug("loaded cached texture \"{s}\"", .{owned_path});
        return .{
            .handle = lease,
            .id = texture,
            .owner_id = self.owner_id,
        };
    }

    /// Backend-context counterpart to `acquireTextureWithContext`; see its note
    /// on matching the cache's `TextureBackend`.
    /// Inserts startup textures uploaded in one backend batch. Each path must be
    /// unique and not already cached. Returned leases are owned by the caller.
    pub fn insertStartupTexturesBatch(
        self: *AssetCache,
        _: *anyopaque,
        inserts: []const StartupTextureInsert,
        texture_ids: []const TextureId,
    ) ![]TextureLease {
        if (inserts.len != texture_ids.len) return error.InvalidStartupTextureBatch;
        if (inserts.len == 0) return try self.allocator.alloc(TextureLease, 0);

        const leases = try self.allocator.alloc(TextureLease, inserts.len);
        errdefer self.allocator.free(leases);

        var inserted_count: usize = 0;
        errdefer self.rollbackStartupTextureInserts(inserts[0..inserted_count]);

        for (inserts, texture_ids, leases) |insert, texture, *lease| {
            try assets.validateRelativePath(insert.relative_path);
            if (self.entries.contains(insert.relative_path)) return error.DuplicateStartupTexture;

            const owned_path = try self.allocator.dupe(u8, insert.relative_path);
            errdefer self.allocator.free(owned_path);

            try self.entries.put(self.allocator, owned_path, .{
                .path = owned_path,
                .texture = texture,
                .retain_count = 1,
            });
            errdefer {
                const removed = self.entries.fetchRemove(owned_path);
                std.debug.assert(removed != null);
                self.allocator.free(owned_path);
            }

            const handle = try self.createLease(owned_path, texture);
            lease.* = .{
                .handle = handle,
                .id = texture,
                .owner_id = self.owner_id,
            };
            inserted_count += 1;
            log.debug("loaded cached texture \"{s}\"", .{owned_path});
        }

        return leases;
    }

    /// Uploads pre-decoded startup textures in one backend batch, then inserts
    /// them into the cache transactionally.
    pub fn uploadStartupTexturesBatch(
        self: *AssetCache,
        backend_context: *anyopaque,
        inserts: []const StartupTextureInsert,
    ) ![]TextureLease {
        if (inserts.len == 0) return try self.allocator.alloc(TextureLease, 0);

        const images = try self.allocator.alloc(image.LoadedImage, inserts.len);
        defer self.allocator.free(images);
        for (inserts, images) |insert, *out| out.* = insert.image;

        const texture_ids = try self.backend.upload_images_batch(backend_context, self.allocator, images);
        errdefer {
            for (texture_ids) |texture| {
                self.backend.destroy_texture(backend_context, texture);
            }
            self.allocator.free(texture_ids);
        }

        const leases = try self.insertStartupTexturesBatch(backend_context, inserts, texture_ids);
        self.allocator.free(texture_ids);
        return leases;
    }

    pub fn releaseTextureWithContext(self: *AssetCache, backend_context: *anyopaque, lease: *TextureLease) void {
        if (lease.owner_id != self.owner_id) return;
        const handle = lease.handle;
        const texture = lease.id;
        const owner_id = lease.owner_id;
        // Invalidate the caller's token before touching cache state so repeated
        // releases or copied stale leases cannot retire the same texture twice.
        lease.handle = LeaseHandle.invalid;
        lease.id = TextureId.invalid;
        lease.owner_id = 0;
        self.releaseLeaseWithContext(backend_context, handle, texture, owner_id);
    }

    fn releaseLeaseWithContext(
        self: *AssetCache,
        backend_context: *anyopaque,
        handle: LeaseHandle,
        expected_texture: TextureId,
        expected_owner_id: u64,
    ) void {
        if (expected_owner_id == 0 or expected_owner_id != self.owner_id) return;
        if (!expected_texture.isValid()) return;
        const slot = self.resolveLeaseSlot(handle) orelse return;
        // The lease slot generation validates handle freshness; the texture ID
        // and cache owner checks reject copied or forged lease tokens.
        if (!textureIdsEqual(slot.texture, expected_texture)) return;

        const path = slot.path.?;
        const texture = slot.texture;

        self.retireLeaseSlot(handle.index, slot);
        self.releaseCachedTextureWithContext(backend_context, path, texture);
    }

    fn rollbackStartupTextureInserts(self: *AssetCache, inserts: []const StartupTextureInsert) void {
        var index = inserts.len;
        while (index > 0) {
            index -= 1;
            const relative_path = inserts[index].relative_path;
            if (self.entries.fetchRemove(relative_path)) |removed| {
                self.allocator.free(removed.value.path);
            }
        }
    }

    fn releaseCachedTextureWithContext(
        self: *AssetCache,
        backend_context: *anyopaque,
        relative_path: []const u8,
        texture: TextureId,
    ) void {
        const entry = self.entries.getPtr(relative_path) orelse return;
        if (!textureIdsEqual(entry.texture, texture)) return;

        if (entry.retain_count > 1) {
            entry.retain_count -= 1;
            log.debug("released cached texture \"{s}\" count={}", .{ entry.path, entry.retain_count });
            return;
        }

        const removed = self.entries.fetchRemove(relative_path) orelse return;
        self.backend.destroy_texture(backend_context, removed.value.texture);
        self.allocator.free(removed.value.path);
    }

    fn deinitWithContext(self: *AssetCache, backend_context: *anyopaque) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.backend.destroy_texture(backend_context, entry.value_ptr.texture);
            self.allocator.free(entry.value_ptr.path);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
        self.lease_slots.deinit(self.allocator);
        self.lease_slots = .empty;
        self.first_free_lease_slot = null;
    }

    fn createLease(self: *AssetCache, path: []const u8, texture: TextureId) !LeaseHandle {
        if (self.first_free_lease_slot) |index| {
            const slot = &self.lease_slots.items[@intCast(index)];
            const generation = slot.generation;
            self.first_free_lease_slot = slot.next_free;
            slot.* = .{
                .path = path,
                .texture = texture,
                .generation = generation,
                .alive = true,
                .next_free = null,
            };
            return LeaseHandle.init(index, generation) catch unreachable;
        }

        if (self.lease_slots.items.len >= std.math.maxInt(u32)) return error.TooManyTextureLeases;
        const index: u32 = @intCast(self.lease_slots.items.len);
        try self.lease_slots.append(self.allocator, .{
            .path = path,
            .texture = texture,
            .generation = 1,
            .alive = true,
            .next_free = null,
        });
        return LeaseHandle.init(index, 1) catch unreachable;
    }

    fn resolveLeaseSlot(self: *AssetCache, handle: LeaseHandle) ?*LeaseSlot {
        if (!handle.isValid()) return null;
        const index: usize = @intCast(handle.index);
        if (index >= self.lease_slots.items.len) return null;

        const slot = &self.lease_slots.items[index];
        if (!slot.alive) return null;
        if (!handle.matches(handle.index, slot.generation)) return null;
        return slot;
    }

    fn resolveLeaseSlotConst(self: *const AssetCache, handle: LeaseHandle) ?*const LeaseSlot {
        if (!handle.isValid()) return null;
        const index: usize = @intCast(handle.index);
        if (index >= self.lease_slots.items.len) return null;

        const slot = &self.lease_slots.items[index];
        if (!slot.alive) return null;
        if (!handle.matches(handle.index, slot.generation)) return null;
        return slot;
    }

    fn retireLeaseSlot(self: *AssetCache, index: u32, slot: *LeaseSlot) void {
        std.debug.assert(slot.alive);
        slot.path = null;
        slot.texture = TextureId.invalid;
        slot.generation = nextGeneration(slot.generation);
        slot.alive = false;
        slot.next_free = self.first_free_lease_slot;
        self.first_free_lease_slot = index;
    }
};

pub const LeaseHandle = struct {
    index: u32,
    generation: u32,

    pub const invalid = LeaseHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !LeaseHandle {
        if (index == std.math.maxInt(u32)) return error.InvalidLeaseIndex;
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: LeaseHandle) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }

    pub fn matches(self: LeaseHandle, index: u32, generation: u32) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

const TextureEntry = struct {
    path: []const u8,
    texture: TextureId,
    retain_count: u32,
};

const LeaseSlot = struct {
    path: ?[]const u8 = null,
    texture: TextureId = TextureId.invalid,
    generation: u32 = 1,
    alive: bool = false,
    next_free: ?u32 = null,
};

pub const StartupTextureInsert = struct {
    relative_path: []const u8,
    image: image.LoadedImage,
};

const TextureBackend = struct {
    upload_image: *const fn (*anyopaque, image.LoadedImage) anyerror!TextureId,
    upload_images_batch: *const fn (*anyopaque, std.mem.Allocator, []const image.LoadedImage) anyerror![]TextureId,
    destroy_texture: *const fn (*anyopaque, TextureId) void,
};

fn rendererBackend() TextureBackend {
    return .{
        .upload_image = rendererUploadImage,
        .upload_images_batch = rendererUploadImagesBatch,
        .destroy_texture = rendererDestroyTexture,
    };
}

fn rendererUploadImage(context: *anyopaque, loaded_image: image.LoadedImage) !TextureId {
    const renderer: *Renderer = @ptrCast(@alignCast(context));
    return renderer.createTextureFromPixels(loaded_image.pixels, loaded_image.width, loaded_image.height, loaded_image.pitch);
}

fn rendererUploadImagesBatch(context: *anyopaque, allocator: std.mem.Allocator, images: []const image.LoadedImage) ![]TextureId {
    _ = allocator;
    const renderer: *Renderer = @ptrCast(@alignCast(context));
    return renderer.createTexturesFromPixelsBatch(images);
}

fn rendererDestroyTexture(context: *anyopaque, texture: TextureId) void {
    const renderer: *Renderer = @ptrCast(@alignCast(context));
    renderer.destroyTexture(texture);
}

fn textureIdsEqual(lhs: TextureId, rhs: TextureId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

var next_cache_owner_id = std.atomic.Value(u64).init(1);

fn nextCacheOwnerId() u64 {
    const id = next_cache_owner_id.fetchAdd(1, .monotonic);
    return if (id == 0) next_cache_owner_id.fetchAdd(1, .monotonic) else id;
}

const FakeBackend = struct {
    upload_count: u32 = 0,
    batch_upload_count: u32 = 0,
    destroy_count: u32 = 0,
    next_index: u32 = 0,
    fail_upload: bool = false,
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_pitch: usize = 0,

    fn backend() TextureBackend {
        return .{
            .upload_image = uploadImage,
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

var test_startup_pixels = [_]u8{255} ** 4;

fn testStartupImage() image.LoadedImage {
    return .{
        .allocator = std.testing.allocator,
        .pixels = test_startup_pixels[0..],
        .width = 1,
        .height = 1,
        .pitch = 4,
    };
}

fn testCache(allocator: std.mem.Allocator) AssetCache {
    return AssetCache.initWithBackend(
        allocator,
        assets.AssetStore.init(allocator, std.testing.io, "assets"),
        FakeBackend.backend(),
    );
}

pub const testing = if (builtin.is_test) struct {
    pub const Backend = FakeBackend;

    pub fn initCache(allocator: std.mem.Allocator, assetStore: assets.AssetStore) AssetCache {
        return AssetCache.initWithBackend(allocator, assetStore, Backend.backend());
    }

    pub fn deinitCache(cache: *AssetCache, fake: *Backend) void {
        cache.deinitWithContext(fake);
    }

    pub fn uploadCount(fake: *const Backend) u32 {
        return fake.upload_count;
    }

    pub fn destroyCount(fake: *const Backend) u32 {
        return fake.destroy_count;
    }

    pub fn entryCount(cache: *const AssetCache) usize {
        return cache.entries.count();
    }

    pub fn batchUploadCount(fake: *const Backend) u32 {
        return fake.batch_upload_count;
    }
} else struct {};

test "duplicate texture acquires reuse the same cached id" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var first = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    defer cache.releaseTextureWithContext(&fake, &first);
    var second = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    defer cache.releaseTextureWithContext(&fake, &second);

    try std.testing.expectEqual(@as(u32, 1), fake.upload_count);
    try std.testing.expect(fake.last_width > 0);
    try std.testing.expect(fake.last_height > 0);
    try std.testing.expect(fake.last_pitch >= fake.last_width * 4);
    try std.testing.expect(textureIdsEqual(first.id, second.id));
    try std.testing.expect(first.isAlive());
    try std.testing.expect(second.isAlive());
}

test "texture leases destroy only after final release" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var first = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    var second = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");

    cache.releaseTextureWithContext(&fake, &first);
    try std.testing.expect(!first.isAlive());
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);

    cache.releaseTextureWithContext(&fake, &second);
    try std.testing.expect(!second.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "explicit texture lease release is idempotent" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var lease = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    cache.releaseTextureWithContext(&fake, &lease);
    cache.releaseTextureWithContext(&fake, &lease);

    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "copied stale texture lease release does not touch freed cache path" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var lease = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    var copied = lease;

    cache.releaseTextureWithContext(&fake, &lease);
    cache.releaseTextureWithContext(&fake, &copied);

    try std.testing.expect(!lease.isAlive());
    try std.testing.expect(!copied.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "texture lease release validates the texture id before retiring a slot" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var lease = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    var forged = lease;
    forged.id = try TextureId.init(999, 1);

    cache.releaseTextureWithContext(&fake, &forged);
    try std.testing.expect(!forged.isAlive());
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);
    try std.testing.expect(cache.resolveLeaseSlotConst(lease.handle) != null);

    cache.releaseTextureWithContext(&fake, &lease);
    try std.testing.expect(!lease.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "texture lease release validates the owning cache before retiring a slot" {
    const allocator = std.testing.allocator;
    var fake_a = FakeBackend{};
    var cache_a = testCache(allocator);
    defer cache_a.deinitWithContext(&fake_a);

    var fake_b = FakeBackend{};
    var cache_b = testCache(allocator);
    defer cache_b.deinitWithContext(&fake_b);

    var lease_a = try cache_a.acquireTextureWithContext(&fake_a, "test/cache_probe.png");
    var lease_b = try cache_b.acquireTextureWithContext(&fake_b, "test/cache_probe.png");
    var foreign = lease_a;

    cache_b.releaseTextureWithContext(&fake_b, &foreign);
    try std.testing.expect(foreign.isAlive());
    try std.testing.expectEqual(@as(u32, 0), fake_b.destroy_count);
    try std.testing.expect(cache_b.resolveLeaseSlotConst(lease_b.handle) != null);

    cache_a.releaseTextureWithContext(&fake_a, &foreign);
    try std.testing.expect(!foreign.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake_a.destroy_count);

    cache_b.releaseTextureWithContext(&fake_b, &lease_b);
    try std.testing.expectEqual(@as(u32, 1), fake_b.destroy_count);
    try std.testing.expectEqual(@as(u32, 1), fake_a.destroy_count);
    try std.testing.expect(lease_a.isAlive());
    cache_a.releaseTextureWithContext(&fake_a, &lease_a);
    try std.testing.expect(!lease_a.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake_a.destroy_count);
}

test "texture lease is a non owning token" {
    try std.testing.expect(!@hasField(TextureLease, "cache"));
    try std.testing.expect(!@hasField(TextureLease, "backend_context"));
}

test "invalid texture paths fail before backend upload" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    try std.testing.expectError(error.InvalidAssetPath, cache.acquireTextureWithContext(&fake, "../bad.png"));
    try std.testing.expectEqual(@as(u32, 0), fake.upload_count);
}

test "texture upload failures leave no cached entry" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{ .fail_upload = true };
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    try std.testing.expectError(error.FakeUploadFailed, cache.acquireTextureWithContext(&fake, "test/cache_probe.png"));
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
}

test "startup texture batch insert rejects mismatch duplicate and empty success" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    const empty = try cache.insertStartupTexturesBatch(&fake, &.{}, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const texture_a = try TextureId.init(0, 1);
    const texture_b = try TextureId.init(1, 1);
    const inserts = [_]StartupTextureInsert{
        .{ .relative_path = "sprites/batch_a.png", .image = testStartupImage() },
        .{ .relative_path = "sprites/batch_b.png", .image = testStartupImage() },
    };
    const leases = try cache.insertStartupTexturesBatch(&fake, &inserts, &.{ texture_a, texture_b });
    defer allocator.free(leases);
    try std.testing.expectEqual(@as(usize, 2), leases.len);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());

    try std.testing.expectError(
        error.InvalidStartupTextureBatch,
        cache.insertStartupTexturesBatch(&fake, &inserts, &.{texture_a}),
    );

    const duplicate_inserts = [_]StartupTextureInsert{
        .{ .relative_path = "sprites/batch_a.png", .image = testStartupImage() },
        .{ .relative_path = "sprites/batch_c.png", .image = testStartupImage() },
    };
    try std.testing.expectError(
        error.DuplicateStartupTexture,
        cache.insertStartupTexturesBatch(&fake, &duplicate_inserts, &.{ texture_a, texture_b }),
    );
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());
}

test "startup texture batch upload uses one backend batch and rolls back partial insert" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    const inserts = [_]StartupTextureInsert{
        .{ .relative_path = "sprites/upload_a.png", .image = testStartupImage() },
        .{ .relative_path = "sprites/upload_a.png", .image = testStartupImage() },
    };
    try std.testing.expectError(error.DuplicateStartupTexture, cache.uploadStartupTexturesBatch(&fake, &inserts));
    try std.testing.expectEqual(@as(u32, 1), fake.batch_upload_count);
    try std.testing.expectEqual(@as(u32, 2), fake.destroy_count);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());

    const good_inserts = [_]StartupTextureInsert{
        .{ .relative_path = "sprites/upload_b.png", .image = testStartupImage() },
        .{ .relative_path = "sprites/upload_c.png", .image = testStartupImage() },
    };
    const leases = try cache.uploadStartupTexturesBatch(&fake, &good_inserts);
    defer allocator.free(leases);
    defer for (leases) |*lease| cache.releaseTextureWithContext(&fake, lease);
    try std.testing.expectEqual(@as(u32, 2), fake.batch_upload_count);
    try std.testing.expectEqual(@as(usize, 2), leases.len);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());
}

test "cache deinit destroys remaining live textures" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);

    _ = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");

    cache.deinitWithContext(&fake);
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}
