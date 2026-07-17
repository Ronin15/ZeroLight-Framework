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

    /// Retires prefix + digit glyphs (idle once if any live). Safe no-op when
    /// nothing has been prepared. Call before destroying the owning renderer /
    /// text service so in-flight frames finish sampling prior textures.
    pub fn deinit(self: *FpsCounter, text_service: *TextService, renderer: *Renderer) void {
        self.releaseGlyphs(text_service, renderer);
    }

    /// Backend-context counterpart for unit tests (`FakeBackend`). Does not idle
    /// the GPU — production teardown goes through `deinit` / `destroyPreparedTexts`.
    pub fn deinitWithContext(self: *FpsCounter, text_service: *TextService, backend_context: *anyopaque) void {
        self.releaseGlyphsWithContext(text_service, backend_context);
    }

    fn releaseGlyphs(self: *FpsCounter, text_service: *TextService, renderer: *Renderer) void {
        // destroyPreparedTexts idles once for the whole batch when any glyph is
        // live — same single-idle pattern as the font/DPI retire path.
        var glyphs: [11]PreparedText = undefined;
        glyphs[0] = self.prefix;
        @memcpy(glyphs[1..], self.digits[0..]);
        text_service.destroyPreparedTexts(renderer, &glyphs);
        self.prefix = .invalid;
        self.digits = [_]PreparedText{PreparedText.invalid} ** 10;
        self.texture_dirty = true;
    }

    fn releaseGlyphsWithContext(self: *FpsCounter, text_service: *TextService, backend_context: *anyopaque) void {
        var glyphs: [11]PreparedText = undefined;
        glyphs[0] = self.prefix;
        @memcpy(glyphs[1..], self.digits[0..]);
        text_service.destroyPreparedTextsWithContext(backend_context, &glyphs);
        self.prefix = .invalid;
        self.digits = [_]PreparedText{PreparedText.invalid} ** 10;
        self.texture_dirty = true;
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
            // Idle once before glyph retirement so in-flight frames finish sampling
            // prior textures. Mid-prepare errdefer only releases never-submitted
            // textures (no idle needed). First prepare has nothing to retire.
            if (self.glyphsValid()) {
                renderer.waitForIdle();
            }
            try self.prepareGlyphs(text_service, @ptrCast(renderer));
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

    /// Prepares the fixed glyph set through `backend_context` (a `*Renderer` in
    /// production, or a text `FakeBackend` in unit tests). Caller must have
    /// already idled the GPU when retiring previously displayed live textures.
    fn prepareGlyphs(self: *FpsCounter, text_service: *TextService, backend_context: *anyopaque) !void {
        // Prepare the full new set first so a mid-prepare failure leaves the
        // previously displayed glyphs intact. On success, retire old entries whose
        // textures differ (font/DPI change) so the text cache does not grow for
        // app lifetime. Same-key cache hits share the old texture handle — skip
        // those so we do not free the just-prepared set.
        const new_prefix = try text_service.prepareTextWithContext(backend_context, TextRequest.init("FPS ", self.font, yellow));
        errdefer {
            // Only retire on failure when this is a newly allocated cache entry,
            // not a hit that still backs the currently displayed prefix.
            if (!preparedTextSharesTexture(self.prefix, new_prefix)) {
                var partial = [_]PreparedText{new_prefix};
                text_service.destroyPreparedTextsWithContext(backend_context, &partial);
            }
        }

        var new_digits = [_]PreparedText{PreparedText.invalid} ** 10;
        var prepared_digits: usize = 0;
        errdefer {
            for (new_digits[0..prepared_digits], 0..) |digit_text, index| {
                if (preparedTextSharesTexture(self.digits[index], digit_text)) {
                    new_digits[index] = .invalid;
                }
            }
            text_service.destroyPreparedTextsWithContext(backend_context, new_digits[0..prepared_digits]);
        }
        for (&new_digits, 0..) |*digit_text, index| {
            const digit = [_]u8{@intCast('0' + index)};
            digit_text.* = try text_service.prepareTextWithContext(backend_context, TextRequest.init(&digit, self.font, yellow));
            prepared_digits += 1;
        }

        var old_glyphs: [11]PreparedText = undefined;
        old_glyphs[0] = self.prefix;
        @memcpy(old_glyphs[1..], self.digits[0..]);
        for (&old_glyphs, 0..) |*old, index| {
            if (!old.isValid()) continue;
            const new_glyph = if (index == 0) new_prefix else new_digits[index - 1];
            if (preparedTextSharesTexture(old.*, new_glyph)) {
                old.* = .invalid;
            }
        }
        text_service.destroyPreparedTextsWithContext(backend_context, &old_glyphs);

        self.prefix = new_prefix;
        self.digits = new_digits;
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

fn preparedTextSharesTexture(a: PreparedText, b: PreparedText) bool {
    return a.isValid() and b.isValid() and a.texture.matches(b.texture.index, b.texture.generation);
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

test "prepareGlyphs twice with same keys does not destroy shared live textures" {
    const allocator = std.testing.allocator;
    var fake = text.FakeBackend{};
    var service = try text.initFakeTextService(allocator, &fake);
    defer service.deinitWithContext(&fake);

    var fps = FpsCounter{
        .font = service.defaultFont(),
        .texture_dirty = true,
    };
    defer fps.deinitWithContext(&service, &fake);

    try fps.prepareGlyphs(&service, &fake);
    try std.testing.expect(fps.glyphsValid());
    try std.testing.expectEqual(@as(u32, 11), fake.render_count); // prefix + 0-9
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);
    try std.testing.expectEqual(@as(u32, 11), text.countLiveTextEntries(&service));

    const first_prefix = fps.prefix;
    const first_digit0 = fps.digits[0];
    const destroy_after_first = fake.destroy_count;

    fps.texture_dirty = true;
    try fps.prepareGlyphs(&service, &fake);
    try std.testing.expect(fps.glyphsValid());
    // Cache hits: no new renders, no destroys of shared live textures.
    try std.testing.expectEqual(@as(u32, 11), fake.render_count);
    try std.testing.expectEqual(destroy_after_first, fake.destroy_count);
    try std.testing.expect(preparedTextSharesTexture(first_prefix, fps.prefix));
    try std.testing.expect(preparedTextSharesTexture(first_digit0, fps.digits[0]));
    try std.testing.expectEqual(@as(u32, 11), text.countLiveTextEntries(&service));
}

test "prepareGlyphs with different font retires prior glyphs and keeps cache bounded" {
    const allocator = std.testing.allocator;
    var fake = text.FakeBackend{};
    var service = try text.initFakeTextService(allocator, &fake);
    defer service.deinitWithContext(&fake);

    var fps = FpsCounter{
        .font = service.defaultFont(),
        .texture_dirty = true,
    };
    defer fps.deinitWithContext(&service, &fake);

    try fps.prepareGlyphs(&service, &fake);
    try std.testing.expectEqual(@as(u32, 11), fake.render_count);
    try std.testing.expectEqual(@as(u32, 11), text.countLiveTextEntries(&service));
    const old_prefix = fps.prefix;
    const old_digit0 = fps.digits[0];

    const alt_path = try allocator.dupe(u8, text.default_font_path);
    var alt_path_owned = true;
    errdefer if (alt_path_owned) allocator.free(alt_path);
    const alt_font = try service.registerFont(.{
        .asset_path = alt_path,
        .point_size = font_size * 2,
    }, @ptrFromInt(2));
    alt_path_owned = false;

    fps.font = alt_font;
    fps.texture_dirty = true;
    try fps.prepareGlyphs(&service, &fake);

    try std.testing.expect(fps.glyphsValid());
    try std.testing.expectEqual(@as(u32, 22), fake.render_count);
    // Prior 11 glyphs retired; only the new set remains live.
    try std.testing.expectEqual(@as(u32, 11), fake.destroy_count);
    try std.testing.expectEqual(@as(u32, 11), text.countLiveTextEntries(&service));
    try std.testing.expect(!preparedTextSharesTexture(old_prefix, fps.prefix));
    try std.testing.expect(!preparedTextSharesTexture(old_digit0, fps.digits[0]));
    try std.testing.expect(!old_prefix.texture.matches(fps.prefix.texture.index, fps.prefix.texture.generation));
}

test "prepareGlyphs mid-prepare failure keeps old glyphs and destroys only non-shared new" {
    const allocator = std.testing.allocator;
    var fake = text.FakeBackend{};
    var service = try text.initFakeTextService(allocator, &fake);
    defer service.deinitWithContext(&fake);

    var fps = FpsCounter{
        .font = service.defaultFont(),
        .texture_dirty = true,
    };
    defer fps.deinitWithContext(&service, &fake);

    try fps.prepareGlyphs(&service, &fake);
    const old_prefix = fps.prefix;
    const old_digits = fps.digits;
    try std.testing.expectEqual(@as(u32, 11), fake.render_count);
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);

    // Force a different font so every glyph is a cache miss, then fail partway
    // through the new set.
    const alt_path = try allocator.dupe(u8, text.default_font_path);
    var alt_path_owned = true;
    errdefer if (alt_path_owned) allocator.free(alt_path);
    const alt_font = try service.registerFont(.{
        .asset_path = alt_path,
        .point_size = font_size * 2,
    }, @ptrFromInt(2));
    alt_path_owned = false;
    fps.font = alt_font;
    fps.texture_dirty = true;

    // After 11 first-prepare renders, allow 6 new successes (prefix + digits
    // 0-4) then fail on the 7th new attempt (digit 5).
    fake.fail_at_render_count = 11 + 6;
    try std.testing.expectError(error.FakeRenderFailed, fps.prepareGlyphs(&service, &fake));

    // Old displayed set is intact.
    try std.testing.expect(preparedTextSharesTexture(old_prefix, fps.prefix));
    for (old_digits, fps.digits) |old, current| {
        try std.testing.expect(preparedTextSharesTexture(old, current));
    }
    try std.testing.expect(fps.texture_dirty);

    // Exactly the non-shared partial new set was destroyed: prefix + 5 digits.
    try std.testing.expectEqual(@as(u32, 6), fake.destroy_count);
    // Live entries are only the original 11 (partial new ones retired).
    try std.testing.expectEqual(@as(u32, 11), text.countLiveTextEntries(&service));
}

test "deinit releases prepared glyphs and clears handles" {
    const allocator = std.testing.allocator;
    var fake = text.FakeBackend{};
    var service = try text.initFakeTextService(allocator, &fake);
    defer service.deinitWithContext(&fake);

    var fps = FpsCounter{
        .font = service.defaultFont(),
        .texture_dirty = true,
    };

    try fps.prepareGlyphs(&service, &fake);
    try std.testing.expect(fps.glyphsValid());
    try std.testing.expectEqual(@as(u32, 11), text.countLiveTextEntries(&service));
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);

    fps.deinitWithContext(&service, &fake);

    try std.testing.expect(!fps.glyphsValid());
    try std.testing.expect(!fps.prefix.isValid());
    for (fps.digits) |digit| {
        try std.testing.expect(!digit.isValid());
    }
    try std.testing.expect(fps.texture_dirty);
    try std.testing.expectEqual(@as(u32, 11), fake.destroy_count);
    try std.testing.expectEqual(@as(u32, 0), text.countLiveTextEntries(&service));
}

test "deinit is safe when no glyphs have been prepared" {
    const allocator = std.testing.allocator;
    var fake = text.FakeBackend{};
    var service = try text.initFakeTextService(allocator, &fake);
    defer service.deinitWithContext(&fake);

    var fps = FpsCounter{
        .font = service.defaultFont(),
    };
    fps.deinitWithContext(&service, &fake);
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);
    try std.testing.expect(!fps.glyphsValid());
}
