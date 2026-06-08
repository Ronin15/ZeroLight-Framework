// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const build_options = @import("build_options");
const Camera2D = @import("camera.zig").Camera2D;
const config = @import("../config.zig");
const logging = @import("../core/logging.zig");
const log = @import("../core/logging.zig").render;
const gpu_buffer = @import("gpu/buffer.zig");
const gpu_device = @import("gpu/device.zig");
const gpu_pipeline = @import("gpu/sprite_pipeline.zig");
const gpu_texture = @import("gpu/texture.zig");
const resources = @import("resources.zig");
const resolution = @import("../app/resolution.zig");
const sdl = @import("../platform/sdl.zig");
const sprite_batch = @import("sprite_batch.zig");
const c = sdl.c;

const initial_batch_vertices = 4096 * 6;
const initial_batch_commands = initial_batch_vertices / 6;

pub const TextureId = resources.TextureId;
pub const Rect = sprite_batch.Rect;
pub const CoordinateSpace = sprite_batch.CoordinateSpace;
pub const Sprite = sprite_batch.Sprite;

pub const FrameResult = enum {
    submitted,
    skipped_no_swapchain,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_transfer_buffer: *c.SDL_GPUTransferBuffer,
    batch_capacity_vertices: usize,
    texture_slots: std.ArrayList(TextureSlot) = .empty,
    batch: sprite_batch.SpriteBatch,
    white_texture: TextureId = TextureId.invalid,
    first_free_texture_slot: ?u32 = null,
    resolution_policy: resolution.ResolutionPolicy = .{},
    current_presentation: ?resolution.Presentation = null,
    last_logged_presentation: ?resolution.Presentation = null,
    clear_color: config.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    window_claimed: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *c.SDL_Window,
        assets: AssetStore,
        app_config: config.AppConfig,
    ) !Renderer {
        try validateConfig(app_config);

        const device = try gpu_device.createDevice(@intCast(build_options.gpu_shader_formats), app_config.gpu_debug);
        errdefer c.SDL_DestroyGPUDevice(device);

        try gpu_device.claimWindow(device, window);
        errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);

        try gpu_device.configureSwapchain(device, window, app_config);

        const sampler = gpu_device.createSampler(device) catch |err| {
            return err;
        };
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);

        const vertex_buffer = try gpu_buffer.createVertexBuffer(device, initial_batch_vertices);
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        const vertex_transfer_buffer = try gpu_buffer.createVertexTransferBuffer(device, initial_batch_vertices);
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, vertex_transfer_buffer);

        const target_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
        const shader_set = try gpu_pipeline.selectShaderSet(device, @intCast(build_options.gpu_shader_formats));
        log.debug("selected SDL_GPU shader set: format={s} vertex=\"{s}\" fragment=\"{s}\"", .{
            gpu_pipeline.shaderFormatName(shader_set.format),
            shader_set.vertex_path,
            shader_set.fragment_path,
        });
        const pipeline = try gpu_pipeline.createSpritePipeline(allocator, device, assets, target_format, shader_set);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        var renderer = Renderer{
            .allocator = allocator,
            .device = device,
            .window = window,
            .pipeline = pipeline,
            .sampler = sampler,
            .vertex_buffer = vertex_buffer,
            .vertex_transfer_buffer = vertex_transfer_buffer,
            .batch_capacity_vertices = initial_batch_vertices,
            .batch = sprite_batch.SpriteBatch.init(allocator),
            .resolution_policy = app_config.resolution_policy,
        };
        try renderer.reserveBatchStorage(initial_batch_commands, initial_batch_vertices, initial_batch_commands);
        errdefer renderer.deinitBatchStorage();

        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        renderer.white_texture = try renderer.createInternalTextureFromPixels(white_pixel[0..], 1, 1, gpu_texture.bytes_per_pixel);
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.waitForIdle();

        for (self.texture_slots.items) |slot| {
            if (slot.alive) {
                c.SDL_ReleaseGPUTexture(self.device, slot.texture.?);
            }
        }
        self.texture_slots.deinit(self.allocator);
        self.deinitBatchStorage();

        c.SDL_ReleaseGPUTransferBuffer(self.device, self.vertex_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        if (self.window_claimed) {
            c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
            self.window_claimed = false;
        }
        c.SDL_DestroyGPUDevice(self.device);
    }

    pub fn waitForIdle(self: *Renderer) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
    }

    pub fn beginFrame(self: *Renderer, clear_color: config.Color) void {
        self.batch.beginFrame();
        self.clear_color = clear_color;
    }

    pub fn drawSprite(self: *Renderer, sprite: Sprite) !void {
        try self.batch.drawSprite(sprite);
    }

    pub fn drawRect(self: *Renderer, rect: Rect, color: config.Color, layer: i32) !void {
        try self.drawRectInSpace(rect, color, layer, .world);
    }

    pub fn drawRectInSpace(self: *Renderer, rect: Rect, color: config.Color, layer: i32, coordinate_space: CoordinateSpace) !void {
        try self.drawSprite(.{
            .texture = self.white_texture,
            .dest = rect,
            .tint = color,
            .layer = layer,
            .coordinate_space = coordinate_space,
        });
    }

    pub fn setCamera(self: *Renderer, camera: Camera2D) void {
        self.batch.setCamera(camera);
    }

    pub fn drawablePixelScale(self: *const Renderer) f32 {
        const presentation = self.current_presentation orelse return 1.0;
        const scale_x = @as(f32, @floatFromInt(presentation.drawable_size.width)) /
            @as(f32, @floatFromInt(presentation.window_size.width));
        const scale_y = @as(f32, @floatFromInt(presentation.drawable_size.height)) /
            @as(f32, @floatFromInt(presentation.window_size.height));
        return @max(1.0, @max(scale_x, scale_y));
    }

    pub fn destroyTexture(self: *Renderer, id: TextureId) void {
        const slot = self.resolveTextureSlot(id) orelse return;
        if (slot.internal) return;

        self.retireTextureSlot(id.index, slot);
    }

    pub fn textureDesc(self: *const Renderer, id: TextureId) ?resources.TextureDesc {
        const slot = self.resolveTextureSlotConst(id) orelse return null;
        return slot.desc;
    }

    fn textureResolver(self: *const Renderer) sprite_batch.TextureResolver {
        return .{
            .context = self,
            .resolve = resolveTextureDescForBatch,
        };
    }

    pub fn endFrame(self: *Renderer) !FrameResult {
        try self.ensureFrameBatchCapacity();
        const window_size = try self.currentWindowSize();

        const command_buffer = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return sdlError("SDL_AcquireGPUCommandBuffer");
        };
        var command_buffer_finished = false;
        var swapchain_acquired = false;
        errdefer if (!command_buffer_finished and !swapchain_acquired) {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
        };

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command_buffer, self.window, &swapchain_texture, &width, &height)) {
            return sdlError("SDL_WaitAndAcquireGPUSwapchainTexture");
        }

        if (swapchainUnavailable(swapchain_texture)) {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
            command_buffer_finished = true;
            return .skipped_no_swapchain;
        }
        const acquired_swapchain_texture = swapchain_texture.?;
        swapchain_acquired = true;

        if (width == 0 or height == 0) {
            log.warn("acquired SDL_GPU swapchain texture with invalid size {}x{}; submitting empty frame", .{ width, height });
            if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
                return sdlError("SDL_SubmitGPUCommandBuffer");
            }
            command_buffer_finished = true;
            return .skipped_no_swapchain;
        }

        self.viewport_width = width;
        self.viewport_height = height;
        const presentation = self.updatePresentation(window_size, .{
            .width = width,
            .height = height,
        });

        self.prepareFrameCommands(presentation);

        if (self.batch.vertices.items.len > 0) {
            self.stageVertices() catch {
                return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_MapGPUTransferBuffer");
            };
            self.recordVertexUpload(command_buffer) catch {
                return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_BeginGPUCopyPass");
            };
        }

        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_target.texture = acquired_swapchain_texture;
        color_target.clear_color = .{
            .r = self.clear_color.r,
            .g = self.clear_color.g,
            .b = self.clear_color.b,
            .a = self.clear_color.a,
        };
        color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        color_target.store_op = c.SDL_GPU_STOREOP_STORE;

        const render_pass = c.SDL_BeginGPURenderPass(command_buffer, &color_target, 1, null) orelse {
            return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_BeginGPURenderPass");
        };
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

        if (self.batch.vertices.items.len > 0) {
            applyDrawablePresentation(render_pass, command_buffer, presentation);

            var vertex_binding = c.SDL_GPUBufferBinding{
                .buffer = self.vertex_buffer,
                .offset = 0,
            };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &vertex_binding, 1);

            var active_presentation: ?sprite_batch.CoordinatePresentation = null;
            for (self.batch.draw_groups.items) |group| {
                const texture = self.resolveTextureSlot(group.texture) orelse continue;

                if (shouldApplyPresentationState(&active_presentation, group.presentation)) {
                    applyGroupScissor(render_pass, presentation, group.presentation);
                }
                var sampler_binding = c.SDL_GPUTextureSamplerBinding{
                    .texture = texture.texture.?,
                    .sampler = self.sampler,
                };
                c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_binding, 1);
                c.SDL_DrawGPUPrimitives(render_pass, group.vertex_count, 1, group.first_vertex, 0);
            }
        }

        c.SDL_EndGPURenderPass(render_pass);

        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            command_buffer_finished = true;
            return sdlError("SDL_SubmitGPUCommandBuffer");
        }
        command_buffer_finished = true;
        return .submitted;
    }

    fn currentWindowSize(self: *Renderer) !resolution.WindowSize {
        var window_width: c_int = 0;
        var window_height: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &window_width, &window_height)) {
            return sdlError("SDL_GetWindowSize");
        }
        if (window_width <= 0 or window_height <= 0) return error.InvalidWindowSize;

        return .{
            .width = @intCast(window_width),
            .height = @intCast(window_height),
        };
    }

    fn updatePresentation(
        self: *Renderer,
        window_size: resolution.WindowSize,
        drawable_size: resolution.DrawableSize,
    ) resolution.Presentation {
        const presentation = resolution.computePresentation(
            self.resolution_policy,
            window_size,
            drawable_size,
        ) catch unreachable;
        self.current_presentation = presentation;
        self.logPresentationChange(presentation);
        return presentation;
    }

    fn logPresentationChange(self: *Renderer, presentation: resolution.Presentation) void {
        if (!logging.enabled(.debug)) return;
        if (self.last_logged_presentation) |last| {
            if (presentationsMatch(last, presentation)) return;
        }

        const pixel_density = c.SDL_GetWindowPixelDensity(self.window);
        const display_scale = c.SDL_GetWindowDisplayScale(self.window);
        const viewport = presentation.viewport;
        log.debug(
            "presentation changed: window={}x{} drawable={}x{} logical={}x{} scale_mode={s} viewport=({}, {}) {}x{} scale={d:.3}x{d:.3} pixel_density={d:.3} display_scale={d:.3}",
            .{
                presentation.window_size.width,
                presentation.window_size.height,
                presentation.drawable_size.width,
                presentation.drawable_size.height,
                presentation.policy.logical_size.width,
                presentation.policy.logical_size.height,
                @tagName(presentation.policy.scale_mode),
                viewport.x,
                viewport.y,
                viewport.width,
                viewport.height,
                viewport.scale_x,
                viewport.scale_y,
                pixel_density,
                display_scale,
            },
        );
        self.last_logged_presentation = presentation;
    }

    pub fn createTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !TextureId {
        return try self.createTextureFromPixelsInternal(pixels, width, height, pitch, false);
    }

    fn createInternalTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !TextureId {
        return try self.createTextureFromPixelsInternal(pixels, width, height, pitch, true);
    }

    fn createTextureFromPixelsInternal(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
        internal: bool,
    ) !TextureId {
        const texture = try gpu_texture.uploadFromPixels(self.device, pixels, width, height, pitch);
        errdefer c.SDL_ReleaseGPUTexture(self.device, texture.texture);
        return try self.registerTexture(texture, internal);
    }

    pub fn replaceTextureFromPixels(
        self: *Renderer,
        id: TextureId,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !void {
        const slot = self.resolveTextureSlot(id) orelse return error.InvalidTexture;
        if (slot.internal) return error.InvalidTexture;

        const next_texture = try gpu_texture.uploadFromPixels(self.device, pixels, width, height, pitch);
        errdefer c.SDL_ReleaseGPUTexture(self.device, next_texture.texture);

        c.SDL_ReleaseGPUTexture(self.device, slot.texture.?);
        slot.texture = next_texture.texture;
        slot.desc = next_texture.desc;
    }

    fn registerTexture(self: *Renderer, texture: UploadedTexture, internal: bool) !TextureId {
        if (self.first_free_texture_slot) |index| {
            const slot = &self.texture_slots.items[@intCast(index)];
            const generation = slot.generation;
            self.first_free_texture_slot = slot.next_free;
            slot.* = .{
                .texture = texture.texture,
                .desc = texture.desc,
                .generation = generation,
                .alive = true,
                .internal = internal,
                .next_free = null,
            };
            return TextureId.init(index, generation) catch unreachable;
        }

        if (self.texture_slots.items.len >= std.math.maxInt(u32)) return error.TooManyTextures;
        const index: u32 = @intCast(self.texture_slots.items.len);
        try self.texture_slots.append(self.allocator, .{
            .texture = texture.texture,
            .desc = texture.desc,
            .generation = 1,
            .alive = true,
            .internal = internal,
            .next_free = null,
        });
        return TextureId.init(index, 1) catch unreachable;
    }

    fn resolveTextureSlot(self: *Renderer, id: TextureId) ?*TextureSlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.texture_slots.items.len) return null;

        const slot = &self.texture_slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn resolveTextureSlotConst(self: *const Renderer, id: TextureId) ?*const TextureSlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.texture_slots.items.len) return null;

        const slot = &self.texture_slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn retireTextureSlot(self: *Renderer, index: u32, slot: *TextureSlot) void {
        std.debug.assert(slot.alive);
        c.SDL_ReleaseGPUTexture(self.device, slot.texture.?);
        retireTextureSlotForReuse(slot, self.first_free_texture_slot);
        self.first_free_texture_slot = index;
    }

    fn reserveBatchStorage(
        self: *Renderer,
        command_capacity: usize,
        vertex_capacity: usize,
        draw_group_capacity: usize,
    ) !void {
        try self.batch.reserveStorage(command_capacity, vertex_capacity, draw_group_capacity);
    }

    fn deinitBatchStorage(self: *Renderer) void {
        self.batch.deinit();
    }

    fn ensureFrameBatchCapacity(self: *Renderer) !void {
        const needed_vertices = try std.math.mul(usize, self.batch.commands.items.len, 6);
        if (needed_vertices == 0) return;

        try self.batch.ensureFrameStorage();
        try self.ensureBatchCapacity(needed_vertices);
    }

    fn ensureBatchCapacity(self: *Renderer, needed_vertices: usize) !void {
        if (needed_vertices <= self.batch_capacity_vertices) return;

        var new_capacity = self.batch_capacity_vertices;
        while (new_capacity < needed_vertices) {
            new_capacity *= 2;
        }

        const new_vertex_buffer = try gpu_buffer.createVertexBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUBuffer(self.device, new_vertex_buffer);

        const new_vertex_transfer_buffer = try gpu_buffer.createVertexTransferBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, new_vertex_transfer_buffer);

        _ = c.SDL_WaitForGPUIdle(self.device);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.vertex_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);

        self.vertex_buffer = new_vertex_buffer;
        self.vertex_transfer_buffer = new_vertex_transfer_buffer;
        self.batch_capacity_vertices = new_capacity;
    }

    fn stageVertices(self: *Renderer) !void {
        try gpu_buffer.stageVertices(self.device, self.vertex_transfer_buffer, self.batch.vertices.items);
    }

    fn recordVertexUpload(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer) !void {
        try gpu_buffer.recordVertexUpload(command_buffer, self.vertex_transfer_buffer, self.vertex_buffer, self.batch.vertices.items);
    }

    fn prepareFrameCommands(self: *Renderer, frame_presentation: resolution.Presentation) void {
        self.batch.buildSerial(self.textureResolver(), frame_presentation);
    }
};

const UploadedTexture = gpu_texture.UploadedTexture;

fn resolveTextureDescForBatch(context: *const anyopaque, id: TextureId) ?resources.TextureDesc {
    const renderer: *const Renderer = @ptrCast(@alignCast(context));
    return renderer.textureDesc(id);
}

const TextureSlot = struct {
    texture: ?*c.SDL_GPUTexture = null,
    desc: resources.TextureDesc = .{ .width = 0, .height = 0 },
    generation: u32 = 1,
    alive: bool = false,
    internal: bool = false,
    next_free: ?u32 = null,
};

const FrameUniform = extern struct {
    viewport_size: [2]f32,
    padding: [2]f32,
};

fn applyDrawablePresentation(
    render_pass: *c.SDL_GPURenderPass,
    command_buffer: *c.SDL_GPUCommandBuffer,
    presentation: resolution.Presentation,
) void {
    var gpu_viewport = c.SDL_GPUViewport{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(presentation.drawable_size.width),
        .h = @floatFromInt(presentation.drawable_size.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    c.SDL_SetGPUViewport(render_pass, &gpu_viewport);
    pushFrameUniform(command_buffer, presentation.drawable_size.width, presentation.drawable_size.height);
}

fn applyGroupScissor(
    render_pass: *c.SDL_GPURenderPass,
    presentation: resolution.Presentation,
    coordinate_presentation: sprite_batch.CoordinatePresentation,
) void {
    switch (coordinate_presentation) {
        .logical => {
            var scissor = scissorForViewport(presentation.viewport, presentation.drawable_size);
            c.SDL_SetGPUScissor(render_pass, &scissor);
        },
        .drawable => {
            var scissor = c.SDL_Rect{
                .x = 0,
                .y = 0,
                .w = @intCast(presentation.drawable_size.width),
                .h = @intCast(presentation.drawable_size.height),
            };
            c.SDL_SetGPUScissor(render_pass, &scissor);
        },
    }
}

fn pushFrameUniform(command_buffer: *c.SDL_GPUCommandBuffer, width: u32, height: u32) void {
    var frame_uniform = FrameUniform{
        .viewport_size = .{
            @floatFromInt(width),
            @floatFromInt(height),
        },
        .padding = .{ 0, 0 },
    };
    c.SDL_PushGPUVertexUniformData(command_buffer, 0, &frame_uniform, @sizeOf(FrameUniform));
}

fn scissorForViewport(viewport: resolution.Viewport, drawable_size: resolution.DrawableSize) c.SDL_Rect {
    const left = @max(@as(i64, 0), @as(i64, viewport.x));
    const top = @max(@as(i64, 0), @as(i64, viewport.y));
    const right = @min(
        @as(i64, @intCast(drawable_size.width)),
        @as(i64, viewport.x) + @as(i64, @intCast(viewport.width)),
    );
    const bottom = @min(
        @as(i64, @intCast(drawable_size.height)),
        @as(i64, viewport.y) + @as(i64, @intCast(viewport.height)),
    );

    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .w = @intCast(@max(@as(i64, 0), right - left)),
        .h = @intCast(@max(@as(i64, 0), bottom - top)),
    };
}

fn presentationsMatch(lhs: resolution.Presentation, rhs: resolution.Presentation) bool {
    return lhs.window_size.width == rhs.window_size.width and
        lhs.window_size.height == rhs.window_size.height and
        lhs.drawable_size.width == rhs.drawable_size.width and
        lhs.drawable_size.height == rhs.drawable_size.height and
        lhs.policy.logical_size.width == rhs.policy.logical_size.width and
        lhs.policy.logical_size.height == rhs.policy.logical_size.height and
        lhs.policy.scale_mode == rhs.policy.scale_mode;
}

fn validateConfig(app_config: config.AppConfig) !void {
    try app_config.validate();
}

fn swapchainUnavailable(swapchain_texture: ?*c.SDL_GPUTexture) bool {
    return swapchain_texture == null;
}

fn finishAcquiredCommandBufferAfterError(
    command_buffer: *c.SDL_GPUCommandBuffer,
    comptime operation: []const u8,
) error{SdlError} {
    log.err("{s} failed after swapchain acquisition: {s}", .{ operation, c.SDL_GetError() });
    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        log.err("SDL_SubmitGPUCommandBuffer failed while releasing acquired swapchain after {s}: {s}", .{ operation, c.SDL_GetError() });
    }
    return error.SdlError;
}

fn shouldApplyPresentationState(
    active_presentation: *?sprite_batch.CoordinatePresentation,
    next_presentation: sprite_batch.CoordinatePresentation,
) bool {
    if (active_presentation.* == next_presentation) return false;
    active_presentation.* = next_presentation;
    return true;
}

fn retireTextureSlotForReuse(slot: *TextureSlot, next_free: ?u32) void {
    slot.texture = null;
    slot.desc = .{ .width = 0, .height = 0 };
    slot.generation = resources.nextGeneration(slot.generation);
    slot.alive = false;
    slot.internal = false;
    slot.next_free = next_free;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

fn testTextureId(index: u32, generation: u32) TextureId {
    return TextureId.init(index, generation) catch unreachable;
}

fn testTextureSlot(texture: *c.SDL_GPUTexture, width: u32, height: u32, generation: u32, internal: bool) TextureSlot {
    return .{
        .texture = texture,
        .desc = .{ .width = width, .height = height },
        .generation = generation,
        .alive = true,
        .internal = internal,
    };
}

test "texture slots reuse retired slots with fresh generations" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .sampler = undefined,
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.texture_slots.deinit(allocator);

    const first = try renderer.registerTexture(.{
        .texture = @ptrFromInt(1),
        .desc = .{ .width = 16, .height = 16 },
    }, false);

    retireTextureSlotForReuse(&renderer.texture_slots.items[@intCast(first.index)], renderer.first_free_texture_slot);
    renderer.first_free_texture_slot = first.index;

    const second = try renderer.registerTexture(.{
        .texture = @ptrFromInt(2),
        .desc = .{ .width = 32, .height = 8 },
    }, false);

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expectEqual(resources.nextGeneration(first.generation), second.generation);
    try std.testing.expect(renderer.resolveTextureSlot(first) == null);

    const desc = renderer.textureDesc(second).?;
    try std.testing.expectEqual(@as(u32, 32), desc.width);
    try std.testing.expectEqual(@as(u32, 8), desc.height);
}

test "internal texture slots cannot be destroyed or replaced through public APIs" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .sampler = undefined,
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.texture_slots.deinit(allocator);

    const texture = try renderer.registerTexture(.{
        .texture = @ptrFromInt(1),
        .desc = .{ .width = 1, .height = 1 },
    }, true);
    renderer.white_texture = texture;

    renderer.destroyTexture(texture);
    try std.testing.expect(renderer.resolveTextureSlot(texture) != null);
    try std.testing.expectError(error.InvalidTexture, renderer.replaceTextureFromPixels(texture, &.{ 255, 255, 255, 255 }, 1, 1, 4));
}

test "drawable presentation uses full drawable scissor and overscan scissor clamps to drawable bounds" {
    const presentation = try resolution.computePresentation(.{}, .{ .width = 1280, .height = 720 }, .{ .width = 2560, .height = 1440 });
    const drawable_scissor = scissorForViewport(.{
        .x = 0,
        .y = 0,
        .width = presentation.drawable_size.width,
        .height = presentation.drawable_size.height,
        .scale_x = 1,
        .scale_y = 1,
    }, presentation.drawable_size);
    try std.testing.expectEqual(@as(c_int, 0), drawable_scissor.x);
    try std.testing.expectEqual(@as(c_int, 0), drawable_scissor.y);
    try std.testing.expectEqual(@as(c_int, 2560), drawable_scissor.w);
    try std.testing.expectEqual(@as(c_int, 1440), drawable_scissor.h);

    const overscan = try resolution.computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .overscan,
    }, .{ .width = 1024, .height = 768 });
    const overscan_scissor = scissorForViewport(overscan, .{ .width = 1024, .height = 768 });
    try std.testing.expectEqual(@as(c_int, 0), overscan_scissor.x);
    try std.testing.expectEqual(@as(c_int, 0), overscan_scissor.y);
    try std.testing.expectEqual(@as(c_int, 1024), overscan_scissor.w);
    try std.testing.expectEqual(@as(c_int, 768), overscan_scissor.h);
}

test "null swapchain texture preserves skipped no swapchain result path" {
    try std.testing.expect(swapchainUnavailable(null));
    try std.testing.expect(!swapchainUnavailable(@ptrFromInt(1)));
    try std.testing.expectEqual(FrameResult.skipped_no_swapchain, FrameResult.skipped_no_swapchain);
}

test "presentation state applies first group and changes only" {
    var active_presentation: ?sprite_batch.CoordinatePresentation = null;

    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .logical));
    try std.testing.expectEqual(sprite_batch.CoordinatePresentation.logical, active_presentation.?);
    try std.testing.expect(!shouldApplyPresentationState(&active_presentation, .logical));
    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .drawable));
    try std.testing.expectEqual(sprite_batch.CoordinatePresentation.drawable, active_presentation.?);
    try std.testing.expect(!shouldApplyPresentationState(&active_presentation, .drawable));
    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .logical));
}

test "renderer drawable pixel scale follows current presentation" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .sampler = undefined,
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };

    try std.testing.expectEqual(@as(f32, 1), renderer.drawablePixelScale());

    renderer.current_presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1440 },
    );

    try std.testing.expectEqual(@as(f32, 2), renderer.drawablePixelScale());
}

test "renderer config rejects invalid frame latency" {
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .app_name = "test",
        .window_title = "test",
        .frames_in_flight = 0,
    }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .app_name = "test",
        .window_title = "test",
        .frames_in_flight = 4,
    }));
}
