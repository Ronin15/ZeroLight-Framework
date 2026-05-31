// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

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
        return std.fs.path.join(self.allocator, &.{ self.root, relative_path });
    }

    pub fn resolveReadablePath(self: AssetStore, relative_path: []const u8) ![]u8 {
        const primary_path = try self.resolvePath(relative_path);
        std.Io.Dir.cwd().access(self.io, primary_path, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound => {
                self.allocator.free(primary_path);
                return self.resolveExeRelativePath(relative_path);
            },
            else => {
                self.allocator.free(primary_path);
                return err;
            },
        };
        return primary_path;
    }

    fn resolveExeRelativePath(self: AssetStore, relative_path: []const u8) ![]u8 {
        const exe_dir = try std.process.executableDirPathAlloc(self.io, self.allocator);
        defer self.allocator.free(exe_dir);

        return std.fs.path.join(self.allocator, &.{ exe_dir, self.root, relative_path });
    }
};

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
