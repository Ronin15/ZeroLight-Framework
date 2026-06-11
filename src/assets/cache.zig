// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Runtime asset cache for renderer-backed resources.
//! Cache lookups are intended for setup, state transitions, and explicit release
//! points. Hot render paths should keep drawing with retained TextureId values.

const std = @import("std");
const assets = @import("assets.zig");
const image = @import("image.zig");
const log = @import("../core/logging.zig").assets;
const Renderer = @import("../render/renderer.zig").Renderer;
const TextureId = @import("../render/resources.zig").TextureId;

pub const TextureLease = struct {
    handle: LeaseHandle = LeaseHandle.invalid,
    id: TextureId = TextureId.invalid,

    pub fn isAlive(self: TextureLease) bool {
        return self.handle.isValid() and self.id.isValid();
    }
};

pub const AssetCache = struct {
    allocator: std.mem.Allocator,
    assets: assets.AssetStore,
    backend: TextureBackend,
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
        self.releaseTextureLeaseWithContext(@ptrCast(renderer), lease);
    }

    fn initWithBackend(allocator: std.mem.Allocator, assetStore: assets.AssetStore, backend: TextureBackend) AssetCache {
        return .{
            .allocator = allocator,
            .assets = assetStore,
            .backend = backend,
        };
    }

    fn acquireTextureWithContext(
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
        };
    }

    fn releaseTextureLeaseWithContext(self: *AssetCache, backend_context: *anyopaque, lease: *TextureLease) void {
        const handle = lease.handle;
        lease.handle = LeaseHandle.invalid;
        lease.id = TextureId.invalid;
        self.releaseLeaseWithContext(backend_context, handle);
    }

    fn releaseLeaseWithContext(
        self: *AssetCache,
        backend_context: *anyopaque,
        handle: LeaseHandle,
    ) void {
        const slot = self.resolveLeaseSlot(handle) orelse return;
        const path = slot.path.?;
        const texture = slot.texture;

        self.retireLeaseSlot(handle.index, slot);
        self.releaseTextureWithContext(backend_context, path, texture);
    }

    fn releaseTextureWithContext(
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

const TextureBackend = struct {
    upload_image: *const fn (*anyopaque, image.LoadedImage) anyerror!TextureId,
    destroy_texture: *const fn (*anyopaque, TextureId) void,
};

fn rendererBackend() TextureBackend {
    return .{
        .upload_image = rendererUploadImage,
        .destroy_texture = rendererDestroyTexture,
    };
}

fn rendererUploadImage(context: *anyopaque, loaded_image: image.LoadedImage) !TextureId {
    const renderer: *Renderer = @ptrCast(@alignCast(context));
    return renderer.createTextureFromPixels(loaded_image.pixels, loaded_image.width, loaded_image.height, loaded_image.pitch);
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

const FakeBackend = struct {
    upload_count: u32 = 0,
    destroy_count: u32 = 0,
    next_index: u32 = 0,
    fail_upload: bool = false,
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_pitch: usize = 0,

    fn backend() TextureBackend {
        return .{
            .upload_image = uploadImage,
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

    fn destroyTexture(context: *anyopaque, texture: TextureId) void {
        _ = texture;
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.destroy_count += 1;
    }
};

fn testCache(allocator: std.mem.Allocator) AssetCache {
    return AssetCache.initWithBackend(
        allocator,
        assets.AssetStore.init(allocator, std.testing.io, "assets"),
        FakeBackend.backend(),
    );
}

test "duplicate texture acquires reuse the same cached id" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var first = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    defer cache.releaseTextureLeaseWithContext(&fake, &first);
    var second = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    defer cache.releaseTextureLeaseWithContext(&fake, &second);

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

    cache.releaseTextureLeaseWithContext(&fake, &first);
    try std.testing.expect(!first.isAlive());
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);

    cache.releaseTextureLeaseWithContext(&fake, &second);
    try std.testing.expect(!second.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "explicit texture lease release is idempotent" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var lease = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    cache.releaseTextureLeaseWithContext(&fake, &lease);
    cache.releaseTextureLeaseWithContext(&fake, &lease);

    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "copied stale texture lease release does not touch freed cache path" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);
    defer cache.deinitWithContext(&fake);

    var lease = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");
    var copied = lease;

    cache.releaseTextureLeaseWithContext(&fake, &lease);
    cache.releaseTextureLeaseWithContext(&fake, &copied);

    try std.testing.expect(!lease.isAlive());
    try std.testing.expect(!copied.isAlive());
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
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

test "cache deinit destroys remaining live textures" {
    const allocator = std.testing.allocator;
    var fake = FakeBackend{};
    var cache = testCache(allocator);

    _ = try cache.acquireTextureWithContext(&fake, "test/cache_probe.png");

    cache.deinitWithContext(&fake);
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}
