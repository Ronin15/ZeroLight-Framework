// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const renderer_file = @import("renderer.zig");
const Renderer = renderer_file.Renderer;
const RenderOrder = renderer_file.RenderOrder;
const text = @import("text.zig");
const FontId = text.FontId;
const PreparedText = text.PreparedText;
const TextRequest = text.TextRequest;
const TextService = text.TextService;

const yellow = config.Color{ .r = 1.0, .g = 0.902, .b = 0.157, .a = 1.0 };
const sample_window_ns = std.time.ns_per_s / 4;
const font_size: f32 = 18;
const font_size_epsilon: f32 = 0.1;

pub const FpsCounter = struct {
    font: FontId = FontId.invalid,
    prefix: PreparedText = .invalid,
    digits: [10]PreparedText = [_]PreparedText{PreparedText.invalid} ** 10,
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

        if (self.texture_dirty or !self.glyphsValid()) {
            try self.prepareGlyphs(text_service, renderer);
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
    }

    pub fn render(self: *const FpsCounter, renderer: *Renderer) !void {
        var x: f32 = 12;
        const y: f32 = 10;
        try text.drawPreparedText(renderer, self.prefix, .{
            .x = x,
            .y = y,
            .order = RenderOrder.debug(.overlay),
            .coordinate_space = .drawable,
        });
        x += @floatFromInt(self.prefix.width);

        var buffer: [16]u8 = undefined;
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{self.displayed_fps}) catch "0";
        for (digits) |digit| {
            const prepared = self.digits[digit - '0'];
            try text.drawPreparedText(renderer, prepared, .{
                .x = x,
                .y = y,
                .order = RenderOrder.debug(.overlay),
                .coordinate_space = .drawable,
            });
            x += @floatFromInt(prepared.width);
        }
    }

    fn prepareGlyphs(self: *FpsCounter, text_service: *TextService, renderer: *Renderer) !void {
        self.prefix = try text_service.prepareText(renderer, TextRequest.init("FPS ", self.font, yellow));
        for (&self.digits, 0..) |*digit_text, index| {
            const digit = [_]u8{@intCast('0' + index)};
            digit_text.* = try text_service.prepareText(renderer, TextRequest.init(&digit, self.font, yellow));
        }
        self.texture_dirty = false;
    }

    fn glyphsValid(self: *const FpsCounter) bool {
        if (!self.prefix.isValid()) return false;
        for (self.digits) |digit| {
            if (!digit.isValid()) return false;
        }
        return true;
    }
};

/// Drawable-space pixel height of the FPS line at a given pixel scale. Public so
/// other debug overlays (e.g. the AI scope HUD) can offset below the FPS line
/// with a gap that tracks it exactly across DPI scales.
pub fn overlayFontSize(drawable_pixel_scale: f32) f32 {
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

test "submitted frame sampling updates fps without dirtying cached glyphs" {
    var fps = FpsCounter{};

    fps.texture_dirty = false;
    fps.recordSubmittedFrame(sample_window_ns);

    try std.testing.expect(!fps.texture_dirty);
    try std.testing.expectEqual(@as(u32, 4), fps.displayed_fps);
    try std.testing.expectEqual(@as(u32, 0), fps.sampled_frames);
    try std.testing.expectEqual(@as(u64, 0), fps.accumulated_ns);
}

test "fps counter uses fixed glyph set" {
    try std.testing.expectEqual(@as(usize, 10), @typeInfo(@TypeOf((FpsCounter{}).digits)).array.len);
}
