// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! A fake text backend and fixtures for `TextService` tests and its consumers'. Test-only:
//! no production path imports it.

const std = @import("std");
const assets = @import("../assets/assets.zig");
const c = @import("../platform/sdl.zig").c;
const TextureId = @import("resources.zig").TextureId;
const text = @import("text.zig");
const TextBackend = text.TextBackend;
const TextRequest = text.TextRequest;
const TextService = text.TextService;
const RenderedText = text.RenderedText;
const default_font_path = text.default_font_path;
const default_font_size = text.default_font_size;

/// In-process text backend for unit tests. Tracks render/destroy counts and can
/// fail after N successful renders to exercise mid-prepare cleanup.
pub const FakeBackend = struct {
    next_texture_index: u32 = 0,
    render_count: u32 = 0,
    destroy_count: u32 = 0,
    /// When set, any render attempted while `render_count >=` this value fails
    /// with `error.FakeRenderFailed` without advancing the count.
    fail_at_render_count: ?u32 = null,

    pub fn backend() TextBackend {
        return .{
            .render_text = renderText,
            .destroy_texture = destroyTexture,
            .close_font = closeFont,
        };
    }

    fn renderText(context: *anyopaque, font: *c.TTF_Font, request: TextRequest) !RenderedText {
        _ = font;
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_at_render_count) |limit| {
            if (self.render_count >= limit) return error.FakeRenderFailed;
        }
        const texture = try TextureId.init(self.next_texture_index, 1);
        self.next_texture_index += 1;
        self.render_count += 1;
        return .{
            .texture = texture,
            .width = @intCast(request.text.len * 8),
            .height = 18,
        };
    }

    fn destroyTexture(context: *anyopaque, texture: TextureId) void {
        _ = texture;
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.destroy_count += 1;
    }

    fn closeFont(font: *c.TTF_Font) void {
        _ = font;
    }
};

pub fn initFakeTextService(allocator: std.mem.Allocator, fake: *FakeBackend) !TextService {
    var service = TextService.initWithBackend(
        allocator,
        assets.AssetStore.init(allocator, std.testing.io, "assets"),
        FakeBackend.backend(),
    );
    const owned_path = try allocator.dupe(u8, default_font_path);
    errdefer allocator.free(owned_path);
    service.default_font = try service.registerFont(.{
        .asset_path = owned_path,
        .point_size = default_font_size,
    }, @ptrFromInt(1));
    fake.* = .{};
    return service;
}

pub fn countLiveTextEntries(service: *const TextService) u32 {
    var live: u32 = 0;
    for (service.entries.items) |slot| {
        if (slot.alive) live += 1;
    }
    return live;
}
