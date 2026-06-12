// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const Renderer = @import("renderer.zig").Renderer;
const text = @import("text.zig");
const FontId = text.FontId;
const PreparedText = text.PreparedText;
const TextRequest = text.TextRequest;
const TextService = text.TextService;

const yellow = config.Color{ .r = 1.0, .g = 0.902, .b = 0.157, .a = 1.0 };
const sample_window_ns = std.time.ns_per_s / 4;
const font_size: f32 = 18;
const font_size_epsilon: f32 = 0.1;
const overlay_layer: i32 = 10_000;

pub const FpsCounter = struct {
    font: FontId = FontId.invalid,
    text: PreparedText = .invalid,
    accumulated_ns: u64 = 0,
    sampled_frames: u32 = 0,
    displayed_fps: u32 = 0,
    active_font_size: f32 = font_size,
    texture_dirty: bool = true,

    pub fn init(text_service: *TextService) FpsCounter {
        return .{
            .font = text_service.defaultFont(),
            .active_font_size = font_size,
        };
    }

    pub fn deinit(self: *FpsCounter) void {
        _ = self;
    }

    pub fn prepareForRender(
        self: *FpsCounter,
        text_service: *TextService,
        renderer: *Renderer,
    ) !void {
        const target_font_size = overlayFontSize(renderer.drawablePixelScale());
        const font_size_changed = !approxEqAbs(self.active_font_size, target_font_size, font_size_epsilon);

        if (font_size_changed) {
            self.font = try text_service.loadFont(text.defaultFontDesc(target_font_size));
            self.active_font_size = target_font_size;
            self.texture_dirty = true;
        }

        if (self.texture_dirty or !self.text.isValid()) {
            try self.prepareTextView(text_service, renderer);
        }
    }

    pub fn recordSubmittedFrame(
        self: *FpsCounter,
        frame_delta_ns: u64,
    ) void {
        self.sampled_frames += 1;
        self.accumulated_ns += frame_delta_ns;
        if (self.accumulated_ns < sample_window_ns) return;

        var next_fps = self.displayed_fps;
        if (self.accumulated_ns > 0) {
            next_fps = @intFromFloat(@round(
                (@as(f64, @floatFromInt(self.sampled_frames)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
                    @as(f64, @floatFromInt(self.accumulated_ns)),
            ));
        }
        self.sampled_frames = 0;
        self.accumulated_ns = 0;
        if (next_fps == self.displayed_fps) return;

        self.displayed_fps = next_fps;
        self.texture_dirty = true;
    }

    pub fn render(self: *const FpsCounter, renderer: *Renderer) !void {
        try text.drawPreparedText(renderer, self.text, .{
            .x = 12,
            .y = 10,
            .layer = overlay_layer,
            .coordinate_space = .drawable,
        });
    }

    fn prepareTextView(self: *FpsCounter, text_service: *TextService, renderer: *Renderer) !void {
        var text_buffer: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&text_buffer, "FPS {d}", .{self.displayed_fps});
        self.text = try text_service.prepareText(renderer, TextRequest.init(label, self.font, yellow));
        self.texture_dirty = false;
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

test "submitted frame sampling marks fps texture dirty after sample window" {
    var fps = FpsCounter{};

    fps.texture_dirty = false;
    fps.recordSubmittedFrame(sample_window_ns);

    try std.testing.expect(fps.texture_dirty);
    try std.testing.expectEqual(@as(u32, 4), fps.displayed_fps);
    try std.testing.expectEqual(@as(u32, 0), fps.sampled_frames);
    try std.testing.expectEqual(@as(u64, 0), fps.accumulated_ns);
}
