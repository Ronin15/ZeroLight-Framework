// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Text/font contracts for future centralized SDL_ttf ownership and cached UI text.
//! Fonts should come from installed assets; debug overlay text can later consume this service.

const std = @import("std");
const assets = @import("../assets/assets.zig");
const config = @import("../config.zig");

pub const FontId = struct {
    index: u32,
    generation: u32,

    pub const invalid = FontId{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !FontId {
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: FontId) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }
};

pub const FontDesc = struct {
    asset_path: []const u8,
    point_size: u16,

    pub fn validate(self: FontDesc) !void {
        try assets.validateRelativePath(self.asset_path);
        if (self.point_size == 0) return error.InvalidFontSize;
    }
};

pub const TextAlign = enum {
    left,
    center,
    right,
};

pub const TextStyle = struct {
    font: FontId,
    color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },

    pub fn validate(self: TextStyle) !void {
        if (!self.font.isValid()) return error.InvalidFont;
    }
};

pub const TextLayoutOptions = struct {
    max_width: ?u32 = null,
    alignment: TextAlign = .left,
    wrap: bool = false,

    pub fn validate(self: TextLayoutOptions) !void {
        if (self.max_width) |width| {
            if (width == 0) return error.InvalidTextWidth;
        }
    }
};

test "font descriptors require asset-backed relative paths and positive size" {
    try (FontDesc{ .asset_path = "fonts/ui.ttf", .point_size = 18 }).validate();
    try std.testing.expectError(error.InvalidAssetPath, (FontDesc{ .asset_path = "../ui.ttf", .point_size = 18 }).validate());
    try std.testing.expectError(error.InvalidFontSize, (FontDesc{ .asset_path = "fonts/ui.ttf", .point_size = 0 }).validate());
}

test "text styles require valid font ids" {
    try std.testing.expectError(error.InvalidFont, (TextStyle{ .font = FontId.invalid }).validate());

    const font = try FontId.init(1, 1);
    try (TextStyle{ .font = font }).validate();
}

test "text layout options reject zero width" {
    try (TextLayoutOptions{ .max_width = null }).validate();
    try (TextLayoutOptions{ .max_width = 240, .wrap = true }).validate();
    try std.testing.expectError(error.InvalidTextWidth, (TextLayoutOptions{ .max_width = 0 }).validate());
}
