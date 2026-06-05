// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const log = @import("../core/logging.zig").assets;

pub const AssetStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) AssetStore {
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
        };
    }

    pub fn readAlloc(self: AssetStore, relative_path: []const u8, max_bytes: usize) ![]u8 {
        const path = try self.resolveReadablePath(relative_path);
        defer self.allocator.free(path);

        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_bytes));
    }

    pub fn resolvePath(self: AssetStore, relative_path: []const u8) ![]u8 {
        try validateRelativePath(relative_path);
        return std.fs.path.join(self.allocator, &.{ self.root, relative_path });
    }

    pub fn resolveReadablePath(self: AssetStore, relative_path: []const u8) ![]u8 {
        const primary_path = try self.resolvePath(relative_path);
        std.Io.Dir.cwd().access(self.io, primary_path, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound => {
                self.allocator.free(primary_path);
                return self.resolveReadableExeRelativePath(relative_path);
            },
            else => {
                self.allocator.free(primary_path);
                return err;
            },
        };
        return primary_path;
    }

    fn resolveReadableExeRelativePath(self: AssetStore, relative_path: []const u8) ![]u8 {
        const exe_dir = try std.process.executableDirPathAlloc(self.io, self.allocator);
        defer self.allocator.free(exe_dir);

        const path = try std.fs.path.join(self.allocator, &.{ exe_dir, self.root, relative_path });
        std.Io.Dir.cwd().access(self.io, path, .{ .read = true }) catch |err| {
            self.allocator.free(path);
            return err;
        };
        log.debug("resolved asset via executable-relative fallback: {s}", .{relative_path});
        return path;
    }
};

pub fn validateRelativePath(relative_path: []const u8) !void {
    if (relative_path.len == 0 or std.fs.path.isAbsolute(relative_path)) {
        return error.InvalidAssetPath;
    }

    var components = std.fs.path.componentIterator(relative_path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidAssetPath;
        }
    }
}

test "asset paths are rooted under configured asset directory" {
    const allocator = std.testing.allocator;
    const assets = AssetStore.init(allocator, std.testing.io, "assets");

    const path = try assets.resolvePath("shaders/sprite.vert.spv");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("assets/shaders/sprite.vert.spv", path);
}

test "readable asset paths prefer configured asset directory" {
    const allocator = std.testing.allocator;
    const assets = AssetStore.init(allocator, std.testing.io, "assets");

    const path = try assets.resolveReadablePath("shaders/sprite.vert.glsl");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("assets/shaders/sprite.vert.glsl", path);
}

test "asset paths reject empty absolute and parent traversal paths" {
    const allocator = std.testing.allocator;
    const assets = AssetStore.init(allocator, std.testing.io, "assets");

    try std.testing.expectError(error.InvalidAssetPath, assets.resolvePath(""));
    try std.testing.expectError(error.InvalidAssetPath, assets.resolvePath("/tmp/file.png"));
    try std.testing.expectError(error.InvalidAssetPath, assets.resolvePath("../file.png"));
    try std.testing.expectError(error.InvalidAssetPath, assets.resolvePath("sprites/../file.png"));
    try std.testing.expectError(error.InvalidAssetPath, assets.resolvePath("./file.png"));
}

test "readable asset paths return missing file errors instead of unchecked fallbacks" {
    const allocator = std.testing.allocator;
    const assets = AssetStore.init(allocator, std.testing.io, "assets");

    try std.testing.expectError(error.FileNotFound, assets.resolveReadablePath("missing/nope.bin"));
}

test "readAlloc enforces maximum byte limit" {
    const allocator = std.testing.allocator;
    const assets = AssetStore.init(allocator, std.testing.io, "assets");

    try std.testing.expectError(error.StreamTooLong, assets.readAlloc("shaders/sprite.vert.glsl", 1));
}
