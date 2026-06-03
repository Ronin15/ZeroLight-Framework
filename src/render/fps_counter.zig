// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const Renderer = @import("renderer.zig").Renderer;
const TextureHandle = @import("renderer.zig").TextureHandle;
const c = @import("../platform/sdl.zig").c;

const yellow = c.SDL_Color{ .r = 255, .g = 230, .b = 40, .a = 255 };
const sample_window_ns = std.time.ns_per_s / 4;
const font_size: f32 = 18;
const overlay_layer: i32 = 10_000;
const bytes_per_pixel = 4;

const system_font_paths = [_][:0]const u8{
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

pub const FpsCounter = struct {
    font: ?*c.TTF_Font = null,
    ttf_initialized: bool = false,
    texture: ?TextureHandle = null,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    accumulated_ns: u64 = 0,
    sampled_frames: u32 = 0,
    displayed_fps: u32 = 0,

    pub fn init() FpsCounter {
        if (!c.TTF_Init()) {
            std.log.warn("debug overlay disabled: TTF_Init failed: {s}", .{c.SDL_GetError()});
            return .{};
        }

        const font = openSystemFont() catch {
            std.log.warn("debug overlay disabled: failed to open a system font", .{});
            c.TTF_Quit();
            return .{};
        };

        return .{
            .font = font,
            .ttf_initialized = true,
        };
    }

    pub fn deinit(self: *FpsCounter, renderer: *Renderer) void {
        renderer.waitForIdle();
        self.destroyTexture(renderer);
        if (self.font) |font| {
            c.TTF_CloseFont(font);
            self.font = null;
        }
        if (self.ttf_initialized) {
            c.TTF_Quit();
            self.ttf_initialized = false;
        }
    }

    pub fn available(self: *const FpsCounter) bool {
        return self.font != null;
    }

    pub fn recordSubmittedFrame(self: *FpsCounter, renderer: *Renderer, frame_delta_ns: u64) !void {
        if (!self.available()) return;

        self.sampled_frames += 1;
        self.accumulated_ns += frame_delta_ns;

        if (self.texture == null or self.accumulated_ns >= sample_window_ns) {
            var next_fps = self.displayed_fps;
            if (self.accumulated_ns > 0) {
                next_fps = @intFromFloat(@round(
                    (@as(f64, @floatFromInt(self.sampled_frames)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
                        @as(f64, @floatFromInt(self.accumulated_ns)),
                ));
            }
            self.sampled_frames = 0;
            self.accumulated_ns = 0;
            if (self.texture != null and next_fps == self.displayed_fps) return;

            self.displayed_fps = next_fps;
            try self.rebuildTexture(renderer);
        }
    }

    pub fn render(self: *const FpsCounter, renderer: *Renderer) !void {
        const texture = self.texture orelse return;
        try renderer.drawSprite(.{
            .texture = texture,
            .dest = .{
                .x = 12,
                .y = 10,
                .w = @floatFromInt(self.texture_width),
                .h = @floatFromInt(self.texture_height),
            },
            .layer = overlay_layer,
            .screen_space = true,
        });
    }

    fn rebuildTexture(self: *FpsCounter, renderer: *Renderer) !void {
        const font = self.font orelse return;

        var text_buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrintZ(&text_buffer, "FPS {d}", .{self.displayed_fps});

        const surface = c.TTF_RenderText_Blended(font, text.ptr, text.len, yellow) orelse {
            return ttfError("TTF_RenderText_Blended");
        };
        defer c.SDL_DestroySurface(surface);

        const converted = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse {
            return ttfError("SDL_ConvertSurface");
        };
        defer c.SDL_DestroySurface(converted);

        if (!c.SDL_LockSurface(converted)) {
            return ttfError("SDL_LockSurface");
        }
        defer c.SDL_UnlockSurface(converted);

        const pixels_ptr: [*]const u8 = @ptrCast(converted.*.pixels.?);
        const pitch: usize = @intCast(converted.*.pitch);
        const byte_len = pitch * @as(usize, @intCast(converted.*.h));
        const pixels = pixels_ptr[0..byte_len];
        const width: u32 = @intCast(converted.*.w);
        const height: u32 = @intCast(converted.*.h);

        if (self.texture) |texture| {
            try renderer.replaceTextureFromPixels(texture, pixels, width, height, pitch);
        } else {
            self.texture = try renderer.createTextureFromPixels(pixels, width, height, pitch);
        }
        self.texture_width = width;
        self.texture_height = height;
    }

    fn destroyTexture(self: *FpsCounter, renderer: *Renderer) void {
        if (self.texture) |texture| {
            renderer.destroyTexture(texture);
            self.texture = null;
            self.texture_width = 0;
            self.texture_height = 0;
        }
    }
};

fn openSystemFont() !*c.TTF_Font {
    for (system_font_paths) |path| {
        if (c.TTF_OpenFont(path.ptr, font_size)) |font| {
            return font;
        }
    }

    return error.SdlError;
}

fn ttfError(comptime operation: []const u8) error{SdlError} {
    std.log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.SdlError;
}

test "system font paths include common Linux monospace locations" {
    try std.testing.expect(hasSystemFontPath("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"));
    try std.testing.expect(hasSystemFontPath("/usr/share/fonts/TTF/DejaVuSansMono.ttf"));
    try std.testing.expect(hasSystemFontPath("/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf"));
    try std.testing.expect(hasSystemFontPath("/usr/share/fonts/noto/NotoSansMono-Regular.ttf"));
}

fn hasSystemFontPath(expected: []const u8) bool {
    for (system_font_paths) |path| {
        if (std.mem.eql(u8, path, expected)) return true;
    }
    return false;
}
