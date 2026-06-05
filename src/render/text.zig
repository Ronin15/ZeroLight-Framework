// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Asset-backed SDL_ttf service for cached UI and debug text.
//! Text rendering is synchronous and intended for explicit content/style changes,
//! not per-frame draw submission.

const std = @import("std");
const assets_mod = @import("../assets/assets.zig");
const AssetStore = assets_mod.AssetStore;
const config = @import("../config.zig");
const log = @import("../core/logging.zig").render;
const Renderer = @import("renderer.zig").Renderer;
const TextureId = @import("resources.zig").TextureId;
const c = @import("../platform/sdl.zig").c;

pub const default_font_path = "fonts/NotoSansMono-Regular.ttf";
const default_font_size: f32 = 18;

pub fn defaultFontDesc(point_size: f32) FontDesc {
    return .{
        .asset_path = default_font_path,
        .point_size = point_size,
    };
}

pub const FontId = struct {
    index: u32,
    generation: u32,

    pub const invalid = FontId{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !FontId {
        if (index == std.math.maxInt(u32)) return error.InvalidFontIndex;
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: FontId) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }

    pub fn matches(self: FontId, index: u32, generation: u32) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

pub const TextTextureId = struct {
    index: u32,
    generation: u32,

    pub const invalid = TextTextureId{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !TextTextureId {
        if (index == std.math.maxInt(u32)) return error.InvalidTextTextureIndex;
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: TextTextureId) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }

    pub fn matches(self: TextTextureId, index: u32, generation: u32) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

pub const TextTextureLease = struct {
    service: ?*TextService = null,
    backend_context: ?*anyopaque = null,
    handle: TextLeaseHandle = TextLeaseHandle.invalid,
    id: TextTextureId = TextTextureId.invalid,
    texture: TextureId = TextureId.invalid,
    width: u32 = 0,
    height: u32 = 0,

    pub fn isAlive(self: TextTextureLease) bool {
        const service = self.service orelse return false;
        return self.backend_context != null and
            self.id.isValid() and
            self.texture.isValid() and
            service.resolveLeaseSlotConst(self.handle) != null;
    }

    pub fn release(self: *TextTextureLease) void {
        const service = self.service orelse return;
        const backend_context = self.backend_context orelse return;
        const handle = self.handle;

        self.service = null;
        self.backend_context = null;
        self.handle = TextLeaseHandle.invalid;
        self.id = TextTextureId.invalid;
        self.texture = TextureId.invalid;
        self.width = 0;
        self.height = 0;

        service.releaseLeaseWithContext(backend_context, handle);
    }
};

pub const FontDesc = struct {
    asset_path: []const u8,
    point_size: f32,

    pub fn validate(self: FontDesc) !void {
        try assets_mod.validateRelativePath(self.asset_path);
        if (self.point_size <= 0 or self.point_size != self.point_size) return error.InvalidFontSize;
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
        try validateColor(self.color);
    }
};

pub const TextLayoutOptions = struct {
    max_width: ?u32 = null,
    alignment: TextAlign = .left,
    wrap: bool = false,

    pub fn validate(self: TextLayoutOptions) !void {
        if (self.max_width) |width| {
            if (width == 0) return error.InvalidTextWidth;
        } else if (self.wrap) {
            return error.InvalidTextWidth;
        }
    }
};

pub const TextRequest = struct {
    text: []const u8,
    style: TextStyle,
    layout: TextLayoutOptions = .{},

    pub fn validate(self: TextRequest) !void {
        if (self.text.len == 0) return error.InvalidText;
        try self.style.validate();
        try self.layout.validate();
    }
};

pub const RenderedText = struct {
    texture: TextureId,
    width: u32,
    height: u32,
};

pub const TextService = struct {
    allocator: std.mem.Allocator,
    assets: AssetStore,
    backend: TextBackend,
    fonts: std.ArrayList(FontSlot) = .empty,
    entries: std.ArrayList(TextEntrySlot) = .empty,
    lease_slots: std.ArrayList(TextLeaseSlot) = .empty,
    first_free_font_slot: ?u32 = null,
    first_free_entry_slot: ?u32 = null,
    first_free_lease_slot: ?u32 = null,
    default_font: FontId = FontId.invalid,
    ttf_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, assets: AssetStore) !TextService {
        var service = initWithBackend(allocator, assets, rendererBackend());
        errdefer service.deinitAfterFailedInit();

        if (!c.TTF_Init()) {
            log.err("TTF_Init failed: {s}", .{c.SDL_GetError()});
            return error.SdlError;
        }
        service.ttf_initialized = true;
        service.default_font = try service.loadFont(defaultFontDesc(default_font_size));
        return service;
    }

    pub fn deinit(self: *TextService, renderer: *Renderer) void {
        renderer.waitForIdle();
        self.deinitWithContext(@ptrCast(renderer));
    }

    pub fn defaultFont(self: *const TextService) FontId {
        return self.default_font;
    }

    pub fn loadFont(self: *TextService, desc: FontDesc) !FontId {
        try desc.validate();

        if (self.findFont(desc)) |font| {
            return font;
        }

        const path = self.assets.resolveReadablePath(desc.asset_path) catch |err| {
            log.err("failed to resolve font asset \"{s}\": {}", .{ desc.asset_path, err });
            return err;
        };
        defer self.allocator.free(path);

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const font = c.TTF_OpenFont(path_z.ptr, desc.point_size) orelse {
            log.err("TTF_OpenFont failed for font \"{s}\": {s}", .{ desc.asset_path, c.SDL_GetError() });
            return error.SdlError;
        };
        errdefer self.backend.close_font(font);

        const owned_path = try self.allocator.dupe(u8, desc.asset_path);
        errdefer self.allocator.free(owned_path);

        return try self.registerFont(.{
            .asset_path = owned_path,
            .point_size = desc.point_size,
        }, font);
    }

    pub fn acquireText(
        self: *TextService,
        renderer: *Renderer,
        request: TextRequest,
    ) !TextTextureLease {
        return self.acquireTextWithContext(@ptrCast(renderer), request);
    }

    fn initWithBackend(allocator: std.mem.Allocator, assets: AssetStore, backend: TextBackend) TextService {
        return .{
            .allocator = allocator,
            .assets = assets,
            .backend = backend,
        };
    }

    fn deinitWithContext(self: *TextService, backend_context: *anyopaque) void {
        var entry_index: u32 = 0;
        while (entry_index < self.entries.items.len) : (entry_index += 1) {
            const slot = &self.entries.items[@intCast(entry_index)];
            if (!slot.alive) continue;
            self.backend.destroy_texture(backend_context, slot.texture);
            self.allocator.free(slot.key.?.text);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
        self.first_free_entry_slot = null;

        for (self.fonts.items) |slot| {
            if (!slot.alive) continue;
            self.backend.close_font(slot.font.?);
            self.allocator.free(slot.desc.?.asset_path);
        }
        self.fonts.deinit(self.allocator);
        self.fonts = .empty;
        self.first_free_font_slot = null;

        self.lease_slots.deinit(self.allocator);
        self.lease_slots = .empty;
        self.first_free_lease_slot = null;
        self.default_font = FontId.invalid;

        if (self.ttf_initialized) {
            c.TTF_Quit();
            self.ttf_initialized = false;
        }
    }

    fn deinitAfterFailedInit(self: *TextService) void {
        const no_backend_context: *anyopaque = @ptrFromInt(1);
        self.deinitWithContext(no_backend_context);
    }

    fn acquireTextWithContext(
        self: *TextService,
        backend_context: *anyopaque,
        request: TextRequest,
    ) !TextTextureLease {
        try request.validate();
        const font_slot = self.resolveFontSlot(request.style.font) orelse return error.InvalidFont;
        const key = TextCacheKey.fromRequest(request);

        if (self.findEntry(key)) |entry_id| {
            const entry = self.resolveEntrySlot(entry_id).?;
            if (entry.retain_count == std.math.maxInt(u32)) return error.TooManyTextLeases;
            const lease = try self.createLease(entry_id, entry.texture, entry.width, entry.height);
            entry.retain_count += 1;
            return .{
                .service = self,
                .backend_context = backend_context,
                .handle = lease,
                .id = entry_id,
                .texture = entry.texture,
                .width = entry.width,
                .height = entry.height,
            };
        }

        const owned_text = try self.allocator.dupe(u8, request.text);
        var text_owned = true;
        errdefer if (text_owned) self.allocator.free(owned_text);

        var owned_key = key;
        owned_key.text = owned_text;

        const rendered = try self.backend.render_text(backend_context, font_slot.font.?, request);
        var rendered_owned = true;
        errdefer if (rendered_owned) self.backend.destroy_texture(backend_context, rendered.texture);

        const entry_id = try self.createEntry(owned_key, rendered);
        text_owned = false;
        rendered_owned = false;
        var entry_owned = true;
        errdefer if (entry_owned) self.releaseEntryWithContext(backend_context, entry_id);

        const lease = try self.createLease(entry_id, rendered.texture, rendered.width, rendered.height);
        entry_owned = false;
        return .{
            .service = self,
            .backend_context = backend_context,
            .handle = lease,
            .id = entry_id,
            .texture = rendered.texture,
            .width = rendered.width,
            .height = rendered.height,
        };
    }

    fn findFont(self: *const TextService, desc: FontDesc) ?FontId {
        for (self.fonts.items, 0..) |slot, index| {
            if (!slot.alive) continue;
            if (fontDescEql(slot.desc.?, desc)) {
                return FontId.init(@intCast(index), slot.generation) catch unreachable;
            }
        }
        return null;
    }

    fn registerFont(self: *TextService, desc: FontDesc, font: *c.TTF_Font) !FontId {
        if (self.first_free_font_slot) |index| {
            const slot = &self.fonts.items[@intCast(index)];
            const generation = slot.generation;
            self.first_free_font_slot = slot.next_free;
            slot.* = .{
                .font = font,
                .desc = desc,
                .generation = generation,
                .alive = true,
                .next_free = null,
            };
            return FontId.init(index, generation) catch unreachable;
        }

        if (self.fonts.items.len >= std.math.maxInt(u32)) return error.TooManyFonts;
        const index: u32 = @intCast(self.fonts.items.len);
        try self.fonts.append(self.allocator, .{
            .font = font,
            .desc = desc,
            .generation = 1,
            .alive = true,
            .next_free = null,
        });
        return FontId.init(index, 1) catch unreachable;
    }

    fn resolveFontSlot(self: *TextService, id: FontId) ?*FontSlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.fonts.items.len) return null;

        const slot = &self.fonts.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn findEntry(self: *const TextService, key: TextCacheKey) ?TextTextureId {
        for (self.entries.items, 0..) |slot, index| {
            if (!slot.alive) continue;
            if (textCacheKeyEql(slot.key.?, key)) {
                return TextTextureId.init(@intCast(index), slot.generation) catch unreachable;
            }
        }
        return null;
    }

    fn createEntry(self: *TextService, key: TextCacheKey, rendered: RenderedText) !TextTextureId {
        if (self.first_free_entry_slot) |index| {
            const slot = &self.entries.items[@intCast(index)];
            const generation = slot.generation;
            self.first_free_entry_slot = slot.next_free;
            slot.* = .{
                .key = key,
                .texture = rendered.texture,
                .width = rendered.width,
                .height = rendered.height,
                .retain_count = 1,
                .generation = generation,
                .alive = true,
                .next_free = null,
            };
            return TextTextureId.init(index, generation) catch unreachable;
        }

        if (self.entries.items.len >= std.math.maxInt(u32)) return error.TooManyTextTextures;
        const index: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{
            .key = key,
            .texture = rendered.texture,
            .width = rendered.width,
            .height = rendered.height,
            .retain_count = 1,
            .generation = 1,
            .alive = true,
            .next_free = null,
        });
        return TextTextureId.init(index, 1) catch unreachable;
    }

    fn resolveEntrySlot(self: *TextService, id: TextTextureId) ?*TextEntrySlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.entries.items.len) return null;

        const slot = &self.entries.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn releaseEntryWithContext(self: *TextService, backend_context: *anyopaque, id: TextTextureId) void {
        const slot = self.resolveEntrySlot(id) orelse return;
        if (slot.retain_count > 1) {
            slot.retain_count -= 1;
            return;
        }

        self.backend.destroy_texture(backend_context, slot.texture);
        self.allocator.free(slot.key.?.text);
        self.retireEntrySlot(id.index, slot);
    }

    fn retireEntrySlot(self: *TextService, index: u32, slot: *TextEntrySlot) void {
        std.debug.assert(slot.alive);
        slot.key = null;
        slot.texture = TextureId.invalid;
        slot.width = 0;
        slot.height = 0;
        slot.retain_count = 0;
        slot.generation = nextGeneration(slot.generation);
        slot.alive = false;
        slot.next_free = self.first_free_entry_slot;
        self.first_free_entry_slot = index;
    }

    fn createLease(self: *TextService, id: TextTextureId, texture: TextureId, width: u32, height: u32) !TextLeaseHandle {
        if (self.first_free_lease_slot) |index| {
            const slot = &self.lease_slots.items[@intCast(index)];
            const generation = slot.generation;
            self.first_free_lease_slot = slot.next_free;
            slot.* = .{
                .entry = id,
                .texture = texture,
                .width = width,
                .height = height,
                .generation = generation,
                .alive = true,
                .next_free = null,
            };
            return TextLeaseHandle.init(index, generation) catch unreachable;
        }

        if (self.lease_slots.items.len >= std.math.maxInt(u32)) return error.TooManyTextLeases;
        const index: u32 = @intCast(self.lease_slots.items.len);
        try self.lease_slots.append(self.allocator, .{
            .entry = id,
            .texture = texture,
            .width = width,
            .height = height,
            .generation = 1,
            .alive = true,
            .next_free = null,
        });
        return TextLeaseHandle.init(index, 1) catch unreachable;
    }

    fn releaseLeaseWithContext(self: *TextService, backend_context: *anyopaque, handle: TextLeaseHandle) void {
        const slot = self.resolveLeaseSlot(handle) orelse return;
        const entry = slot.entry;
        self.retireLeaseSlot(handle.index, slot);
        self.releaseEntryWithContext(backend_context, entry);
    }

    fn resolveLeaseSlot(self: *TextService, handle: TextLeaseHandle) ?*TextLeaseSlot {
        if (!handle.isValid()) return null;
        const index: usize = @intCast(handle.index);
        if (index >= self.lease_slots.items.len) return null;

        const slot = &self.lease_slots.items[index];
        if (!slot.alive) return null;
        if (!handle.matches(handle.index, slot.generation)) return null;
        return slot;
    }

    fn resolveLeaseSlotConst(self: *const TextService, handle: TextLeaseHandle) ?*const TextLeaseSlot {
        if (!handle.isValid()) return null;
        const index: usize = @intCast(handle.index);
        if (index >= self.lease_slots.items.len) return null;

        const slot = &self.lease_slots.items[index];
        if (!slot.alive) return null;
        if (!handle.matches(handle.index, slot.generation)) return null;
        return slot;
    }

    fn retireLeaseSlot(self: *TextService, index: u32, slot: *TextLeaseSlot) void {
        std.debug.assert(slot.alive);
        slot.entry = TextTextureId.invalid;
        slot.texture = TextureId.invalid;
        slot.width = 0;
        slot.height = 0;
        slot.generation = nextGeneration(slot.generation);
        slot.alive = false;
        slot.next_free = self.first_free_lease_slot;
        self.first_free_lease_slot = index;
    }
};

pub const TextLeaseHandle = struct {
    index: u32,
    generation: u32,

    pub const invalid = TextLeaseHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !TextLeaseHandle {
        if (index == std.math.maxInt(u32)) return error.InvalidTextLeaseIndex;
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: TextLeaseHandle) bool {
        return self.generation != 0 and self.index != std.math.maxInt(u32);
    }

    pub fn matches(self: TextLeaseHandle, index: u32, generation: u32) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

const FontSlot = struct {
    font: ?*c.TTF_Font = null,
    desc: ?FontDesc = null,
    generation: u32 = 1,
    alive: bool = false,
    next_free: ?u32 = null,
};

const TextCacheKey = struct {
    text: []const u8,
    font: FontId,
    color: ColorKey,
    max_width: u32,
    wrap: bool,
    alignment: TextAlign,

    fn fromRequest(request: TextRequest) TextCacheKey {
        return .{
            .text = request.text,
            .font = request.style.font,
            .color = ColorKey.fromColor(request.style.color),
            .max_width = request.layout.max_width orelse 0,
            .wrap = request.layout.wrap,
            .alignment = request.layout.alignment,
        };
    }
};

const TextEntrySlot = struct {
    key: ?TextCacheKey = null,
    texture: TextureId = TextureId.invalid,
    width: u32 = 0,
    height: u32 = 0,
    retain_count: u32 = 0,
    generation: u32 = 1,
    alive: bool = false,
    next_free: ?u32 = null,
};

const TextLeaseSlot = struct {
    entry: TextTextureId = TextTextureId.invalid,
    texture: TextureId = TextureId.invalid,
    width: u32 = 0,
    height: u32 = 0,
    generation: u32 = 1,
    alive: bool = false,
    next_free: ?u32 = null,
};

const ColorKey = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn fromColor(color: config.Color) ColorKey {
        return .{
            .r = colorByte(color.r),
            .g = colorByte(color.g),
            .b = colorByte(color.b),
            .a = colorByte(color.a),
        };
    }

    fn toSdl(self: ColorKey) c.SDL_Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

const TextBackend = struct {
    render_text: *const fn (*anyopaque, *c.TTF_Font, TextRequest) anyerror!RenderedText,
    destroy_texture: *const fn (*anyopaque, TextureId) void,
    close_font: *const fn (*c.TTF_Font) void,
};

fn rendererBackend() TextBackend {
    return .{
        .render_text = rendererRenderText,
        .destroy_texture = rendererDestroyTexture,
        .close_font = closeSdlFont,
    };
}

fn closeSdlFont(font: *c.TTF_Font) void {
    c.TTF_CloseFont(font);
}

fn rendererRenderText(context: *anyopaque, font: *c.TTF_Font, request: TextRequest) !RenderedText {
    const renderer: *Renderer = @ptrCast(@alignCast(context));
    const color = ColorKey.fromColor(request.style.color).toSdl();
    c.TTF_SetFontWrapAlignment(font, sdlAlignment(request.layout.alignment));

    const surface = if (request.layout.wrap)
        c.TTF_RenderText_Blended_Wrapped(font, request.text.ptr, request.text.len, color, @intCast(request.layout.max_width.?))
    else
        c.TTF_RenderText_Blended(font, request.text.ptr, request.text.len, color) orelse {
            log.err("TTF text render failed: {s}", .{c.SDL_GetError()});
            return error.SdlError;
        };
    defer c.SDL_DestroySurface(surface);

    const texture = try renderer.createTextureFromSurface(surface);
    errdefer renderer.destroyTexture(texture);
    const desc = renderer.textureDesc(texture) orelse return error.InvalidTexture;
    return .{
        .texture = texture,
        .width = desc.width,
        .height = desc.height,
    };
}

fn rendererDestroyTexture(context: *anyopaque, texture: TextureId) void {
    const renderer: *Renderer = @ptrCast(@alignCast(context));
    renderer.destroyTexture(texture);
}

fn sdlAlignment(alignment: TextAlign) c.TTF_HorizontalAlignment {
    return switch (alignment) {
        .left => c.TTF_HORIZONTAL_ALIGN_LEFT,
        .center => c.TTF_HORIZONTAL_ALIGN_CENTER,
        .right => c.TTF_HORIZONTAL_ALIGN_RIGHT,
    };
}

fn validateColor(color: config.Color) !void {
    try validateColorComponent(color.r);
    try validateColorComponent(color.g);
    try validateColorComponent(color.b);
    try validateColorComponent(color.a);
}

fn validateColorComponent(value: f32) !void {
    if (value != value or value < 0 or value > 1) return error.InvalidTextColor;
}

fn colorByte(value: f32) u8 {
    if (value <= 0) return 0;
    if (value >= 1) return 255;
    return @intFromFloat(@round(value * 255));
}

fn fontDescEql(lhs: FontDesc, rhs: FontDesc) bool {
    return lhs.point_size == rhs.point_size and std.mem.eql(u8, lhs.asset_path, rhs.asset_path);
}

fn textCacheKeyEql(lhs: TextCacheKey, rhs: TextCacheKey) bool {
    return lhs.font.matches(rhs.font.index, rhs.font.generation) and
        lhs.color == rhs.color and
        lhs.max_width == rhs.max_width and
        lhs.wrap == rhs.wrap and
        lhs.alignment == rhs.alignment and
        std.mem.eql(u8, lhs.text, rhs.text);
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

const FakeBackend = struct {
    next_texture_index: u32 = 0,
    render_count: u32 = 0,
    destroy_count: u32 = 0,

    fn backend() TextBackend {
        return .{
            .render_text = renderText,
            .destroy_texture = destroyTexture,
            .close_font = closeFont,
        };
    }

    fn renderText(context: *anyopaque, font: *c.TTF_Font, request: TextRequest) !RenderedText {
        _ = font;
        const self: *FakeBackend = @ptrCast(@alignCast(context));
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

fn initFakeTextService(allocator: std.mem.Allocator, fake: *FakeBackend) !TextService {
    var service = TextService.initWithBackend(
        allocator,
        AssetStore.init(allocator, std.testing.io, "assets"),
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

test "font descriptors require asset-backed relative paths and positive size" {
    try defaultFontDesc(18).validate();
    try std.testing.expectError(error.InvalidAssetPath, (FontDesc{ .asset_path = "../ui.ttf", .point_size = 18 }).validate());
    try std.testing.expectError(error.InvalidFontSize, (FontDesc{ .asset_path = "fonts/ui.ttf", .point_size = 0 }).validate());
    try std.testing.expectError(error.InvalidFontSize, (FontDesc{ .asset_path = "fonts/ui.ttf", .point_size = std.math.nan(f32) }).validate());
}

test "text styles require valid font ids and normalized color" {
    try std.testing.expectError(error.InvalidFont, (TextStyle{ .font = FontId.invalid }).validate());

    const font = try FontId.init(1, 1);
    try (TextStyle{ .font = font }).validate();
    try std.testing.expectError(error.InvalidTextColor, (TextStyle{
        .font = font,
        .color = .{ .r = 2, .g = 1, .b = 1, .a = 1 },
    }).validate());
}

test "text layout options reject zero or missing wrap width" {
    try (TextLayoutOptions{ .max_width = null }).validate();
    try (TextLayoutOptions{ .max_width = 240, .wrap = true }).validate();
    try std.testing.expectError(error.InvalidTextWidth, (TextLayoutOptions{ .max_width = 0 }).validate());
    try std.testing.expectError(error.InvalidTextWidth, (TextLayoutOptions{ .wrap = true }).validate());
}

test "color conversion normalizes float channels to SDL bytes" {
    try std.testing.expectEqual(ColorKey{ .r = 255, .g = 128, .b = 0, .a = 64 }, ColorKey.fromColor(.{
        .r = 1,
        .g = 0.5,
        .b = 0,
        .a = 0.25,
    }));
}

test "cache keys include text font color layout and alignment" {
    const font = try FontId.init(2, 3);
    const base = TextCacheKey.fromRequest(.{
        .text = "FPS 60",
        .style = .{ .font = font, .color = .{ .r = 1, .g = 1, .b = 0, .a = 1 } },
        .layout = .{},
    });
    const same = TextCacheKey.fromRequest(.{
        .text = "FPS 60",
        .style = .{ .font = font, .color = .{ .r = 1, .g = 1, .b = 0, .a = 1 } },
        .layout = .{},
    });
    const different_text = TextCacheKey.fromRequest(.{
        .text = "FPS 61",
        .style = .{ .font = font, .color = .{ .r = 1, .g = 1, .b = 0, .a = 1 } },
        .layout = .{},
    });
    const different_layout = TextCacheKey.fromRequest(.{
        .text = "FPS 60",
        .style = .{ .font = font, .color = .{ .r = 1, .g = 1, .b = 0, .a = 1 } },
        .layout = .{ .max_width = 64, .wrap = true, .alignment = .center },
    });

    try std.testing.expect(textCacheKeyEql(base, same));
    try std.testing.expect(!textCacheKeyEql(base, different_text));
    try std.testing.expect(!textCacheKeyEql(base, different_layout));
}

test "duplicate text acquires reuse cached texture until final release" {
    var fake = FakeBackend{};
    var service = try initFakeTextService(std.testing.allocator, &fake);
    defer service.deinitWithContext(&fake);

    const request = TextRequest{
        .text = "Menu",
        .style = .{ .font = service.defaultFont() },
    };

    var first = try service.acquireTextWithContext(&fake, request);
    var second = try service.acquireTextWithContext(&fake, request);

    try std.testing.expect(first.texture.matches(second.texture.index, second.texture.generation));
    try std.testing.expectEqual(@as(u32, 1), fake.render_count);
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);

    first.release();
    try std.testing.expectEqual(@as(u32, 0), fake.destroy_count);
    second.release();
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}

test "cached text acquire rejects retain count overflow before creating a lease" {
    var fake = FakeBackend{};
    var service = try initFakeTextService(std.testing.allocator, &fake);
    defer service.deinitWithContext(&fake);

    const request = TextRequest{
        .text = "Menu",
        .style = .{ .font = service.defaultFont() },
    };

    var first = try service.acquireTextWithContext(&fake, request);
    defer first.release();

    const key = TextCacheKey.fromRequest(request);
    const entry_id = service.findEntry(key).?;
    service.resolveEntrySlot(entry_id).?.retain_count = std.math.maxInt(u32);

    try std.testing.expectError(error.TooManyTextLeases, service.acquireTextWithContext(&fake, request));
}

test "text lease release is idempotent and rejects stale copied leases" {
    var fake = FakeBackend{};
    var service = try initFakeTextService(std.testing.allocator, &fake);
    defer service.deinitWithContext(&fake);

    var lease = try service.acquireTextWithContext(&fake, .{
        .text = "Paused",
        .style = .{ .font = service.defaultFont() },
    });
    var stale_copy = lease;

    lease.release();
    lease.release();
    stale_copy.release();

    try std.testing.expectEqual(@as(u32, 1), fake.destroy_count);
}
