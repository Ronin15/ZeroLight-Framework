// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const Renderer = @import("renderer.zig").Renderer;
const text_mod = @import("text.zig");
const FontId = text_mod.FontId;
const TextService = text_mod.TextService;
const TextTextureLease = text_mod.TextTextureLease;

const yellow = config.Color{ .r = 1.0, .g = 0.902, .b = 0.157, .a = 1.0 };
const sample_window_ns = std.time.ns_per_s / 4;
const font_size: f32 = 18;
const font_size_epsilon: f32 = 0.1;
const overlay_layer: i32 = 10_000;

pub const FpsCounter = struct {
    font: FontId = FontId.invalid,
    texture: TextTextureLease = .{},
    accumulated_ns: u64 = 0,
    sampled_frames: u32 = 0,
    displayed_fps: u32 = 0,
    active_font_size: f32 = font_size,

    pub fn init(text_service: *TextService) FpsCounter {
        return .{
            .font = text_service.defaultFont(),
            .active_font_size = font_size,
        };
    }

    pub fn deinit(self: *FpsCounter) void {
        self.texture.release();
    }

    pub fn recordSubmittedFrame(
        self: *FpsCounter,
        text_service: *TextService,
        renderer: *Renderer,
        frame_delta_ns: u64,
    ) !void {
        self.sampled_frames += 1;
        self.accumulated_ns += frame_delta_ns;
        const target_font_size = overlayFontSize(renderer.drawablePixelScale());
        const font_size_changed = !approxEqAbs(self.active_font_size, target_font_size, font_size_epsilon);

        if (!self.texture.isAlive() or self.accumulated_ns >= sample_window_ns or font_size_changed) {
            var next_fps = self.displayed_fps;
            if (self.accumulated_ns > 0) {
                next_fps = @intFromFloat(@round(
                    (@as(f64, @floatFromInt(self.sampled_frames)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
                        @as(f64, @floatFromInt(self.accumulated_ns)),
                ));
            }
            self.sampled_frames = 0;
            self.accumulated_ns = 0;
            if (self.texture.isAlive() and next_fps == self.displayed_fps and !font_size_changed) return;

            self.displayed_fps = next_fps;
            if (font_size_changed) {
                self.font = try text_service.loadFont(text_mod.defaultFontDesc(target_font_size));
                self.active_font_size = target_font_size;
            }
            try self.rebuildTexture(text_service, renderer);
        }
    }

    pub fn render(self: *const FpsCounter, renderer: *Renderer) !void {
        if (!self.texture.isAlive()) return;
        try renderer.drawSprite(.{
            .texture = self.texture.texture,
            .dest = .{
                .x = 12,
                .y = 10,
                .w = @floatFromInt(self.texture.width),
                .h = @floatFromInt(self.texture.height),
            },
            .layer = overlay_layer,
            .coordinate_space = .drawable,
        });
    }

    fn rebuildTexture(self: *FpsCounter, text_service: *TextService, renderer: *Renderer) !void {
        var text_buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "FPS {d}", .{self.displayed_fps});

        const next_texture = try text_service.acquireText(renderer, .{
            .text = text,
            .style = .{
                .font = self.font,
                .color = yellow,
            },
        });
        self.texture.release();
        self.texture = next_texture;
    }
};

fn overlayFontSize(drawable_pixel_scale: f32) f32 {
    return font_size * @max(1.0, drawable_pixel_scale);
}

fn approxEqAbs(a: f32, b: f32, tolerance: f32) bool {
    return @abs(a - b) <= tolerance;
}

test "overlay font size follows drawable pixel scale" {
    try std.testing.expectEqual(@as(f32, 18), overlayFontSize(1));
    try std.testing.expectEqual(@as(f32, 36), overlayFontSize(2));
    try std.testing.expectEqual(@as(f32, 18), overlayFontSize(0.5));
}
