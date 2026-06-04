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
const math = @import("../core/math.zig");
const resources = @import("resources.zig");
const resolution = @import("../app/resolution.zig");
const sdl = @import("../platform/sdl.zig");
const c = sdl.c;

const max_shader_bytes = 1024 * 1024;
const initial_batch_vertices = 4096 * 6;
const initial_batch_commands = initial_batch_vertices / 6;
const bytes_per_pixel = 4;

pub const TextureId = resources.TextureId;

pub const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const CoordinateSpace = enum {
    world,
    logical,
    drawable,
};

pub const Sprite = struct {
    texture: TextureId,
    source: ?Rect = null,
    dest: Rect,
    tint: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    origin: math.Vec2 = .{},
    rotation: f32 = 0,
    layer: i32 = 0,
    coordinate_space: CoordinateSpace = .world,
};

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
    commands: std.ArrayList(SpriteCommand) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    draw_groups: std.ArrayList(DrawGroup) = .empty,
    white_texture: TextureId = TextureId.invalid,
    first_free_texture_slot: ?u32 = null,
    camera: Camera2D = .{},
    resolution_policy: resolution.ResolutionPolicy = .{},
    current_presentation: ?resolution.Presentation = null,
    last_logged_presentation: ?resolution.Presentation = null,
    clear_color: config.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    command_sequence: u64 = 0,
    window_claimed: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *c.SDL_Window,
        assets: AssetStore,
        app_config: config.AppConfig,
    ) !Renderer {
        try validateConfig(app_config);

        const device = c.SDL_CreateGPUDevice(@intCast(build_options.gpu_shader_formats), app_config.gpu_debug, null) orelse {
            return sdlError("SDL_CreateGPUDevice");
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        if (c.SDL_GetGPUDeviceDriver(device)) |driver| {
            log.debug("SDL_GPU driver: {s}", .{driver});
        } else {
            log.debug("SDL_GPU driver: unknown", .{});
        }

        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            return sdlError("SDL_ClaimWindowForGPUDevice");
        }
        errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);

        const selected_present_mode = selectPresentMode(device, window, app_config.present_mode);

        if (!c.SDL_SetGPUAllowedFramesInFlight(device, app_config.frames_in_flight)) {
            return sdlError("SDL_SetGPUAllowedFramesInFlight");
        }

        if (!c.SDL_SetGPUSwapchainParameters(
            device,
            window,
            c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
            selected_present_mode,
        )) {
            return sdlError("SDL_SetGPUSwapchainParameters");
        }

        const sampler = createSampler(device) catch |err| {
            return err;
        };
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);

        const vertex_buffer = try createVertexBuffer(device, initial_batch_vertices);
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        const vertex_transfer_buffer = try createVertexTransferBuffer(device, initial_batch_vertices);
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, vertex_transfer_buffer);

        const target_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
        const shader_set = try selectShaderSet(device);
        log.debug("selected SDL_GPU shader set: format={s} vertex=\"{s}\" fragment=\"{s}\"", .{
            shaderFormatName(shader_set.format),
            shader_set.vertex_path,
            shader_set.fragment_path,
        });
        const pipeline = try createSpritePipeline(allocator, device, assets, target_format, shader_set);
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
            .resolution_policy = app_config.resolution_policy,
        };
        try renderer.reserveBatchStorage(initial_batch_commands, initial_batch_vertices, initial_batch_commands);
        errdefer renderer.deinitBatchStorage();

        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        renderer.white_texture = try renderer.createInternalTextureFromPixels(white_pixel[0..], 1, 1, bytes_per_pixel);
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
        self.commands.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.command_sequence = 0;
        self.clear_color = clear_color;
    }

    pub fn drawSprite(self: *Renderer, sprite: Sprite) !void {
        try self.commands.append(self.allocator, .{
            .sprite = sprite,
            .sequence = self.command_sequence,
        });
        self.command_sequence += 1;
    }

    pub fn drawRect(self: *Renderer, rect: Rect, color: config.Color, layer: i32) !void {
        try self.drawSprite(.{
            .texture = self.white_texture,
            .dest = rect,
            .tint = color,
            .layer = layer,
        });
    }

    pub fn setCamera(self: *Renderer, camera: Camera2D) void {
        self.camera = camera;
    }

    pub fn drawablePixelScale(self: *const Renderer) f32 {
        const presentation = self.current_presentation orelse return 1.0;
        const scale_x = @as(f32, @floatFromInt(presentation.drawable_size.width)) /
            @as(f32, @floatFromInt(presentation.window_size.width));
        const scale_y = @as(f32, @floatFromInt(presentation.drawable_size.height)) /
            @as(f32, @floatFromInt(presentation.window_size.height));
        return @max(1.0, @max(scale_x, scale_y));
    }

    pub fn createTextureFromPng(self: *Renderer, assets: AssetStore, relative_path: []const u8) !TextureId {
        const path = assets.resolveReadablePath(relative_path) catch |err| {
            log.err("failed to resolve PNG texture asset \"{s}\": {}", .{ relative_path, err });
            return err;
        };
        defer self.allocator.free(path);

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const loaded = c.SDL_LoadPNG(path_z.ptr) orelse {
            log.err("SDL_LoadPNG failed for texture \"{s}\": {s}", .{ relative_path, c.SDL_GetError() });
            return error.SdlError;
        };
        defer c.SDL_DestroySurface(loaded);

        return try self.createTextureFromSurface(loaded);
    }

    pub fn createTextureFromSurface(self: *Renderer, surface: *c.SDL_Surface) !TextureId {
        const converted = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse {
            return sdlError("SDL_ConvertSurface");
        };
        defer c.SDL_DestroySurface(converted);

        if (!c.SDL_LockSurface(converted)) {
            return sdlError("SDL_LockSurface");
        }
        defer c.SDL_UnlockSurface(converted);

        const pixels_ptr: [*]const u8 = @ptrCast(converted.*.pixels.?);
        const pitch: usize = @intCast(converted.*.pitch);
        const byte_len = pitch * @as(usize, @intCast(converted.*.h));
        return try self.createTextureFromPixels(
            pixels_ptr[0..byte_len],
            @intCast(converted.*.w),
            @intCast(converted.*.h),
            pitch,
        );
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

        if (self.vertices.items.len > 0) {
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

        if (self.vertices.items.len > 0) {
            applyDrawablePresentation(render_pass, command_buffer, presentation);

            var vertex_binding = c.SDL_GPUBufferBinding{
                .buffer = self.vertex_buffer,
                .offset = 0,
            };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &vertex_binding, 1);

            var active_presentation: ?CoordinatePresentation = null;
            for (self.draw_groups.items) |group| {
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
        const texture = try self.uploadTextureFromPixels(pixels, width, height, pitch);
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

        const next_texture = try self.uploadTextureFromPixels(pixels, width, height, pitch);
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

    fn uploadTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !UploadedTexture {
        try validateTexturePixels(pixels, width, height, pitch);
        const desc = resources.TextureDesc{
            .width = width,
            .height = height,
        };
        try desc.validate();

        var texture_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        texture_info.type = c.SDL_GPU_TEXTURETYPE_2D;
        texture_info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        texture_info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        texture_info.width = width;
        texture_info.height = height;
        texture_info.layer_count_or_depth = 1;
        texture_info.num_levels = 1;
        texture_info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;

        const texture = c.SDL_CreateGPUTexture(self.device, &texture_info) orelse {
            return sdlError("SDL_CreateGPUTexture");
        };
        errdefer c.SDL_ReleaseGPUTexture(self.device, texture);

        var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transfer_info.size = @intCast(pixels.len);
        const transfer = c.SDL_CreateGPUTransferBuffer(self.device, &transfer_info) orelse {
            return sdlError("SDL_CreateGPUTransferBuffer");
        };
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);

        const mapped = c.SDL_MapGPUTransferBuffer(self.device, transfer, false) orelse {
            return sdlError("SDL_MapGPUTransferBuffer");
        };
        const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..pixels.len];
        @memcpy(mapped_bytes, pixels);
        c.SDL_UnmapGPUTransferBuffer(self.device, transfer);

        const command_buffer = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return sdlError("SDL_AcquireGPUCommandBuffer");
        };
        var command_submitted = false;
        errdefer if (!command_submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
            return sdlError("SDL_BeginGPUCopyPass");
        };
        var source = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer,
            .offset = 0,
            .pixels_per_row = @intCast(pitch / bytes_per_pixel),
            .rows_per_layer = height,
        };
        var destination = c.SDL_GPUTextureRegion{
            .texture = texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1,
        };
        c.SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
        c.SDL_EndGPUCopyPass(copy_pass);

        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            return sdlError("SDL_SubmitGPUCommandBuffer");
        }
        command_submitted = true;

        return .{
            .texture = texture,
            .desc = desc,
        };
    }

    fn reserveBatchStorage(
        self: *Renderer,
        command_capacity: usize,
        vertex_capacity: usize,
        draw_group_capacity: usize,
    ) !void {
        errdefer self.deinitBatchStorage();
        try self.commands.ensureTotalCapacity(self.allocator, command_capacity);
        try self.vertices.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.draw_groups.ensureTotalCapacity(self.allocator, draw_group_capacity);
    }

    fn deinitBatchStorage(self: *Renderer) void {
        self.commands.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.draw_groups.deinit(self.allocator);
        self.commands = .empty;
        self.vertices = .empty;
        self.draw_groups = .empty;
    }

    fn ensureFrameBatchCapacity(self: *Renderer) !void {
        const needed_vertices = try std.math.mul(usize, self.commands.items.len, 6);
        if (needed_vertices == 0) return;

        try self.vertices.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.draw_groups.ensureTotalCapacity(self.allocator, self.commands.items.len);
        try self.ensureBatchCapacity(needed_vertices);
    }

    fn ensureBatchCapacity(self: *Renderer, needed_vertices: usize) !void {
        if (needed_vertices <= self.batch_capacity_vertices) return;

        var new_capacity = self.batch_capacity_vertices;
        while (new_capacity < needed_vertices) {
            new_capacity *= 2;
        }

        const new_vertex_buffer = try createVertexBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUBuffer(self.device, new_vertex_buffer);

        const new_vertex_transfer_buffer = try createVertexTransferBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, new_vertex_transfer_buffer);

        _ = c.SDL_WaitForGPUIdle(self.device);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.vertex_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);

        self.vertex_buffer = new_vertex_buffer;
        self.vertex_transfer_buffer = new_vertex_transfer_buffer;
        self.batch_capacity_vertices = new_capacity;
    }

    fn stageVertices(self: *Renderer) !void {
        const bytes = std.mem.sliceAsBytes(self.vertices.items);
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.vertex_transfer_buffer, true) orelse {
            return error.SdlError;
        };
        const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..bytes.len];
        @memcpy(mapped_bytes, bytes);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.vertex_transfer_buffer);
    }

    fn recordVertexUpload(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer) !void {
        const bytes = std.mem.sliceAsBytes(self.vertices.items);
        const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
            return error.SdlError;
        };
        var source = c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = self.vertex_transfer_buffer,
            .offset = 0,
        };
        var destination = c.SDL_GPUBufferRegion{
            .buffer = self.vertex_buffer,
            .offset = 0,
            .size = @intCast(bytes.len),
        };
        c.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, true);
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    fn prepareFrameCommands(self: *Renderer, frame_presentation: resolution.Presentation) void {
        self.buildBatchSerial(frame_presentation);
    }

    fn buildBatchSerial(self: *Renderer, frame_presentation: resolution.Presentation) void {
        std.mem.sort(SpriteCommand, self.commands.items, {}, spriteCommandLessThan);
        std.debug.assert(self.vertices.capacity >= self.commands.items.len * 6);
        std.debug.assert(self.draw_groups.capacity >= self.commands.items.len);

        var active_texture: ?TextureId = null;
        var active_presentation: CoordinatePresentation = .logical;
        var active_first_vertex: u32 = 0;
        var active_vertex_count: u32 = 0;

        for (self.commands.items) |command| {
            const first_vertex: u32 = @intCast(self.vertices.items.len);
            if (!self.appendSpriteVertices(command.sprite, frame_presentation)) continue;
            const group_presentation = presentationForCoordinateSpace(command.sprite.coordinate_space);

            if (active_texture == null or !textureIdsEqual(active_texture.?, command.sprite.texture) or active_presentation != group_presentation) {
                if (active_texture) |texture| {
                    self.draw_groups.appendAssumeCapacity(.{
                        .texture = texture,
                        .presentation = active_presentation,
                        .first_vertex = active_first_vertex,
                        .vertex_count = active_vertex_count,
                    });
                }
                active_texture = command.sprite.texture;
                active_presentation = group_presentation;
                active_first_vertex = first_vertex;
                active_vertex_count = 6;
            } else {
                active_vertex_count += 6;
            }
        }

        if (active_texture) |texture| {
            self.draw_groups.appendAssumeCapacity(.{
                .texture = texture,
                .presentation = active_presentation,
                .first_vertex = active_first_vertex,
                .vertex_count = active_vertex_count,
            });
        }
    }

    fn appendSpriteVertices(self: *Renderer, sprite: Sprite, presentation: resolution.Presentation) bool {
        const texture = self.resolveTextureSlot(sprite.texture) orelse return false;

        const source = sprite.source orelse Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(texture.desc.width),
            .h = @floatFromInt(texture.desc.height),
        };

        const tex_u0 = source.x / @as(f32, @floatFromInt(texture.desc.width));
        const tex_v0 = source.y / @as(f32, @floatFromInt(texture.desc.height));
        const tex_u1 = (source.x + source.w) / @as(f32, @floatFromInt(texture.desc.width));
        const tex_v1 = (source.y + source.h) / @as(f32, @floatFromInt(texture.desc.height));

        const local = [_]math.Vec2{
            .{ .x = -sprite.origin.x, .y = -sprite.origin.y },
            .{ .x = sprite.dest.w - sprite.origin.x, .y = -sprite.origin.y },
            .{ .x = -sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
            .{ .x = sprite.dest.w - sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
        };
        const uv = [_][2]f32{
            .{ tex_u0, tex_v0 },
            .{ tex_u1, tex_v0 },
            .{ tex_u0, tex_v1 },
            .{ tex_u1, tex_v1 },
        };
        const indices = [_]usize{ 0, 1, 2, 1, 3, 2 };

        const rotation_cos = @cos(sprite.rotation);
        const rotation_sin = @sin(sprite.rotation);

        var positions: [4]math.Vec2 = undefined;
        for (local, 0..) |point, index| {
            const rotated = math.Vec2{
                .x = point.x * rotation_cos - point.y * rotation_sin,
                .y = point.x * rotation_sin + point.y * rotation_cos,
            };
            const world = math.Vec2{
                .x = sprite.dest.x + sprite.origin.x + rotated.x,
                .y = sprite.dest.y + sprite.origin.y + rotated.y,
            };
            const screen = switch (sprite.coordinate_space) {
                .world => self.camera.worldToScreen(world),
                .logical, .drawable => world,
            };
            positions[index] = switch (sprite.coordinate_space) {
                .world, .logical => logicalToDrawable(screen, presentation),
                .drawable => screen,
            };
        }

        for (indices) |index| {
            const position = positions[index];
            self.vertices.appendAssumeCapacity(.{
                .position = .{ position.x, position.y },
                .uv = uv[index],
                .color = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
            });
        }
        return true;
    }
};

const UploadedTexture = struct {
    texture: *c.SDL_GPUTexture,
    desc: resources.TextureDesc,
};

const TextureSlot = struct {
    texture: ?*c.SDL_GPUTexture = null,
    desc: resources.TextureDesc = .{ .width = 0, .height = 0 },
    generation: u32 = 1,
    alive: bool = false,
    internal: bool = false,
    next_free: ?u32 = null,
};

const SpriteCommand = struct {
    sprite: Sprite,
    sequence: u64,
};

const DrawGroup = struct {
    texture: TextureId,
    presentation: CoordinatePresentation,
    first_vertex: u32,
    vertex_count: u32,
};

const CoordinatePresentation = enum {
    logical,
    drawable,
};

const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

const FrameUniform = extern struct {
    viewport_size: [2]f32,
    padding: [2]f32,
};

const ShaderSet = struct {
    format: c.SDL_GPUShaderFormat,
    vertex_path: []const u8,
    fragment_path: []const u8,
    entrypoint: [:0]const u8,
};

fn createSampler(device: *c.SDL_GPUDevice) !*c.SDL_GPUSampler {
    var sampler_info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    sampler_info.min_filter = c.SDL_GPU_FILTER_NEAREST;
    sampler_info.mag_filter = c.SDL_GPU_FILTER_NEAREST;
    sampler_info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    sampler_info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sampler_info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sampler_info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;

    return c.SDL_CreateGPUSampler(device, &sampler_info) orelse {
        return sdlError("SDL_CreateGPUSampler");
    };
}

fn createVertexBuffer(device: *c.SDL_GPUDevice, vertex_capacity: usize) !*c.SDL_GPUBuffer {
    var buffer_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    buffer_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    buffer_info.size = @intCast(vertex_capacity * @sizeOf(Vertex));
    return c.SDL_CreateGPUBuffer(device, &buffer_info) orelse {
        return sdlError("SDL_CreateGPUBuffer");
    };
}

fn createVertexTransferBuffer(device: *c.SDL_GPUDevice, vertex_capacity: usize) !*c.SDL_GPUTransferBuffer {
    var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transfer_info.size = @intCast(vertex_capacity * @sizeOf(Vertex));
    return c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        return sdlError("SDL_CreateGPUTransferBuffer");
    };
}

fn validateTexturePixels(pixels: []const u8, width: u32, height: u32, pitch: usize) !void {
    if (width == 0 or height == 0) return error.InvalidTexturePixels;
    if (pitch % bytes_per_pixel != 0) return error.InvalidTexturePixels;

    const min_pitch = std.math.mul(usize, @intCast(width), bytes_per_pixel) catch return error.InvalidTexturePixels;
    if (pitch < min_pitch) return error.InvalidTexturePixels;

    const required_len = std.math.mul(usize, pitch, @intCast(height)) catch return error.InvalidTexturePixels;
    if (pixels.len < required_len) return error.InvalidTexturePixels;
}

fn presentationForCoordinateSpace(coordinate_space: CoordinateSpace) CoordinatePresentation {
    return switch (coordinate_space) {
        .world, .logical => .logical,
        .drawable => .drawable,
    };
}

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
    coordinate_presentation: CoordinatePresentation,
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

fn logicalToDrawable(point: math.Vec2, presentation: resolution.Presentation) math.Vec2 {
    const viewport = presentation.viewport;
    return .{
        .x = @as(f32, @floatFromInt(viewport.x)) + point.x * viewport.scale_x,
        .y = @as(f32, @floatFromInt(viewport.y)) + point.y * viewport.scale_y,
    };
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

test "texture pixel validation rejects invalid dimensions pitch and length" {
    const valid_pixels = [_]u8{255} ** 16;

    try std.testing.expectError(error.InvalidTexturePixels, validateTexturePixels(valid_pixels[0..], 0, 1, 4));
    try std.testing.expectError(error.InvalidTexturePixels, validateTexturePixels(valid_pixels[0..], 1, 0, 4));
    try std.testing.expectError(error.InvalidTexturePixels, validateTexturePixels(valid_pixels[0..], 2, 2, 7));
    try std.testing.expectError(error.InvalidTexturePixels, validateTexturePixels(valid_pixels[0..], 2, 2, 4));
    try std.testing.expectError(error.InvalidTexturePixels, validateTexturePixels(valid_pixels[0..15], 2, 2, 8));
}

test "texture pixel validation accepts tightly packed and padded rows" {
    const tight_pixels = [_]u8{255} ** 16;
    const padded_pixels = [_]u8{255} ** 24;

    try validateTexturePixels(tight_pixels[0..], 2, 2, 8);
    try validateTexturePixels(padded_pixels[0..], 2, 2, 12);
}

fn createSpritePipeline(
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    assets: AssetStore,
    target_format: c.SDL_GPUTextureFormat,
    shader_set: ShaderSet,
) !*c.SDL_GPUGraphicsPipeline {
    const vertex_shader = try createShader(
        allocator,
        device,
        assets,
        shader_set.vertex_path,
        shader_set.format,
        shader_set.entrypoint,
        c.SDL_GPU_SHADERSTAGE_VERTEX,
        0,
        0,
        0,
        1,
    );
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);

    const fragment_shader = try createShader(
        allocator,
        device,
        assets,
        shader_set.fragment_path,
        shader_set.format,
        shader_set.entrypoint,
        c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        1,
        0,
        0,
        0,
    );
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);

    var vertex_buffer = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(Vertex),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };
    var vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = @offsetOf(Vertex, "position"),
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = @offsetOf(Vertex, "uv"),
        },
        .{
            .location = 2,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    var color_target = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
    color_target.format = target_format;
    color_target.blend_state.enable_blend = true;
    color_target.blend_state.src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
    color_target.blend_state.dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    color_target.blend_state.color_blend_op = c.SDL_GPU_BLENDOP_ADD;
    color_target.blend_state.src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE;
    color_target.blend_state.dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    color_target.blend_state.alpha_blend_op = c.SDL_GPU_BLENDOP_ADD;

    var pipeline_info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
    pipeline_info.vertex_shader = vertex_shader;
    pipeline_info.fragment_shader = fragment_shader;
    pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffer;
    pipeline_info.vertex_input_state.num_vertex_buffers = 1;
    pipeline_info.vertex_input_state.vertex_attributes = &vertex_attributes;
    pipeline_info.vertex_input_state.num_vertex_attributes = vertex_attributes.len;
    pipeline_info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pipeline_info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
    pipeline_info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
    pipeline_info.rasterizer_state.front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
    pipeline_info.multisample_state.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
    pipeline_info.target_info.color_target_descriptions = &color_target;
    pipeline_info.target_info.num_color_targets = 1;

    return c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_info) orelse {
        return sdlError("SDL_CreateGPUGraphicsPipeline");
    };
}

fn createShader(
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    assets: AssetStore,
    path: []const u8,
    format: c.SDL_GPUShaderFormat,
    entrypoint: [:0]const u8,
    stage: c.SDL_GPUShaderStage,
    samplers: u32,
    storage_textures: u32,
    storage_buffers: u32,
    uniform_buffers: u32,
) !*c.SDL_GPUShader {
    const code = assets.readAlloc(path, max_shader_bytes) catch |err| {
        log.err("failed to read shader asset \"{s}\": {}", .{ path, err });
        return err;
    };
    defer allocator.free(code);

    var shader_info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    shader_info.code_size = code.len;
    shader_info.code = code.ptr;
    shader_info.entrypoint = entrypoint.ptr;
    shader_info.format = format;
    shader_info.stage = stage;
    shader_info.num_samplers = samplers;
    shader_info.num_storage_textures = storage_textures;
    shader_info.num_storage_buffers = storage_buffers;
    shader_info.num_uniform_buffers = uniform_buffers;

    return c.SDL_CreateGPUShader(device, &shader_info) orelse {
        return sdlError("SDL_CreateGPUShader");
    };
}

fn presentMode(mode: config.PresentMode) c.SDL_GPUPresentMode {
    return switch (mode) {
        .vsync => c.SDL_GPU_PRESENTMODE_VSYNC,
        .immediate => c.SDL_GPU_PRESENTMODE_IMMEDIATE,
        .mailbox => c.SDL_GPU_PRESENTMODE_MAILBOX,
    };
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

fn shouldApplyPresentationState(active_presentation: *?CoordinatePresentation, next_presentation: CoordinatePresentation) bool {
    if (active_presentation.* == next_presentation) return false;
    active_presentation.* = next_presentation;
    return true;
}

fn selectPresentMode(
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    requested_mode: config.PresentMode,
) c.SDL_GPUPresentMode {
    const requested_sdl_mode = presentMode(requested_mode);
    if (requested_mode == .vsync or c.SDL_WindowSupportsGPUPresentMode(device, window, requested_sdl_mode)) {
        return requested_sdl_mode;
    }

    log.warn("requested SDL_GPU present mode is unsupported; falling back to vsync", .{});
    return c.SDL_GPU_PRESENTMODE_VSYNC;
}

fn selectShaderSet(device: *c.SDL_GPUDevice) error{UnsupportedShaderFormat}!ShaderSet {
    const device_formats = c.SDL_GetGPUShaderFormats(device);
    const app_formats: c.SDL_GPUShaderFormat = @intCast(build_options.gpu_shader_formats);
    return selectShaderSetFromFormats(device_formats, app_formats) catch |err| {
        log.err(
            "SDL_GPU selected device supports shader formats 0x{x}, but app provides 0x{x}",
            .{ device_formats, app_formats },
        );
        return err;
    };
}

fn selectShaderSetFromFormats(
    device_formats: c.SDL_GPUShaderFormat,
    app_formats: c.SDL_GPUShaderFormat,
) error{UnsupportedShaderFormat}!ShaderSet {
    const usable_formats = device_formats & app_formats;

    if ((usable_formats & c.SDL_GPU_SHADERFORMAT_MSL) != 0) {
        return .{
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
            .vertex_path = "shaders/sprite.vert.msl",
            .fragment_path = "shaders/sprite.frag.msl",
            .entrypoint = "main0",
        };
    }

    if ((usable_formats & c.SDL_GPU_SHADERFORMAT_SPIRV) != 0) {
        return .{
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
            .vertex_path = "shaders/sprite.vert.spv",
            .fragment_path = "shaders/sprite.frag.spv",
            .entrypoint = "main",
        };
    }

    return error.UnsupportedShaderFormat;
}

fn shaderFormatName(format: c.SDL_GPUShaderFormat) []const u8 {
    if (format == c.SDL_GPU_SHADERFORMAT_MSL) return "MSL";
    if (format == c.SDL_GPU_SHADERFORMAT_SPIRV) return "SPIR-V";
    return "unknown";
}

fn spriteCommandLessThan(_: void, lhs: SpriteCommand, rhs: SpriteCommand) bool {
    if (lhs.sprite.layer != rhs.sprite.layer) return lhs.sprite.layer < rhs.sprite.layer;
    return lhs.sequence < rhs.sequence;
}

fn textureIdsEqual(lhs: TextureId, rhs: TextureId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
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

fn initBatchTestRenderer(allocator: std.mem.Allocator) !Renderer {
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .sampler = undefined,
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
        .batch_capacity_vertices = 0,
    };
    errdefer renderer.deinitBatchStorage();
    errdefer renderer.texture_slots.deinit(allocator);

    try renderer.texture_slots.append(allocator, testTextureSlot(@ptrFromInt(1), 8, 8, 1, false));
    return renderer;
}

fn deinitBatchTestRenderer(renderer: *Renderer, allocator: std.mem.Allocator) void {
    renderer.texture_slots.deinit(allocator);
    renderer.deinitBatchStorage();
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

fn batchTestPresentation() !resolution.Presentation {
    return resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 1280, .height = 720 },
    );
}

fn prepareBatchTestFrame(renderer: *Renderer, allocator: std.mem.Allocator, presentation: resolution.Presentation) !void {
    try renderer.vertices.ensureTotalCapacity(allocator, renderer.commands.items.len * 6);
    try renderer.draw_groups.ensureTotalCapacity(allocator, renderer.commands.items.len);
    renderer.prepareFrameCommands(presentation);
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

test "batch builder skips invalid stale and destroyed texture ids" {
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
    };
    defer renderer.texture_slots.deinit(allocator);
    defer renderer.commands.deinit(allocator);
    defer renderer.vertices.deinit(allocator);
    defer renderer.draw_groups.deinit(allocator);

    try renderer.texture_slots.append(allocator, testTextureSlot(@ptrFromInt(1), 1, 1, 1, false));
    try renderer.texture_slots.append(allocator, .{
        .texture = null,
        .desc = .{ .width = 0, .height = 0 },
        .generation = 2,
        .alive = false,
    });
    try renderer.texture_slots.append(allocator, testTextureSlot(@ptrFromInt(3), 1, 1, 4, false));

    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = testTextureId(42, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 0,
    });
    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = testTextureId(1, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 1,
    });
    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = testTextureId(2, 3),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 2,
    });
    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = testTextureId(0, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 3,
    });

    try prepareBatchTestFrame(&renderer, allocator, try batchTestPresentation());

    try std.testing.expectEqual(@as(usize, 6), renderer.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), renderer.draw_groups.items.len);
    try std.testing.expectEqual(@as(u32, 0), renderer.draw_groups.items[0].texture.index);
    try std.testing.expectEqual(CoordinatePresentation.logical, renderer.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), renderer.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), renderer.draw_groups.items[0].vertex_count);
}

test "batch builder groups by texture and coordinate presentation" {
    const allocator = std.testing.allocator;
    var renderer = try initBatchTestRenderer(allocator);
    defer deinitBatchTestRenderer(&renderer, allocator);

    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 4, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    try prepareBatchTestFrame(&renderer, allocator, try batchTestPresentation());

    try std.testing.expectEqual(@as(usize, 18), renderer.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 2), renderer.draw_groups.items.len);
    try std.testing.expectEqual(CoordinatePresentation.logical, renderer.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), renderer.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 12), renderer.draw_groups.items[0].vertex_count);
    try std.testing.expectEqual(CoordinatePresentation.drawable, renderer.draw_groups.items[1].presentation);
    try std.testing.expectEqual(@as(u32, 12), renderer.draw_groups.items[1].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), renderer.draw_groups.items[1].vertex_count);
}

test "world sprites apply camera while logical and drawable sprites ignore camera" {
    const allocator = std.testing.allocator;
    var renderer = try initBatchTestRenderer(allocator);
    defer deinitBatchTestRenderer(&renderer, allocator);
    renderer.camera = .{
        .position = .{ .x = 5, .y = 10 },
        .zoom = 2,
    };

    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    try prepareBatchTestFrame(&renderer, allocator, try batchTestPresentation());

    try std.testing.expectEqual(@as(f32, 30), renderer.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 40), renderer.vertices.items[0].position[1]);
    try std.testing.expectEqual(@as(f32, 20), renderer.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), renderer.vertices.items[6].position[1]);
    try std.testing.expectEqual(@as(f32, 20), renderer.vertices.items[12].position[0]);
    try std.testing.expectEqual(@as(f32, 30), renderer.vertices.items[12].position[1]);
    try std.testing.expectEqual(CoordinatePresentation.drawable, renderer.draw_groups.items[1].presentation);
}

test "batch builder orders layers before submission sequence" {
    const allocator = std.testing.allocator;
    var renderer = try initBatchTestRenderer(allocator);
    defer deinitBatchTestRenderer(&renderer, allocator);

    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 0, .w = 1, .h = 1 },
        .layer = 5,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 10, .y = 0, .w = 1, .h = 1 },
        .layer = 1,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 30, .y = 0, .w = 1, .h = 1 },
        .layer = 5,
    });

    try prepareBatchTestFrame(&renderer, allocator, try batchTestPresentation());

    try std.testing.expectEqual(@as(f32, 10), renderer.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 20), renderer.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), renderer.vertices.items[12].position[0]);
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

test "world and logical vertices are submitted in drawable pixels" {
    const allocator = std.testing.allocator;
    var renderer = try initBatchTestRenderer(allocator);
    defer deinitBatchTestRenderer(&renderer, allocator);

    const presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1440 },
    );

    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    try prepareBatchTestFrame(&renderer, allocator, presentation);

    try std.testing.expectEqual(@as(f32, 40), renderer.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 60), renderer.vertices.items[0].position[1]);
    try std.testing.expectEqual(@as(f32, 40), renderer.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 60), renderer.vertices.items[6].position[1]);
    try std.testing.expectEqual(@as(f32, 20), renderer.vertices.items[12].position[0]);
    try std.testing.expectEqual(@as(f32, 30), renderer.vertices.items[12].position[1]);
}

test "world vertices include camera then letterbox viewport offset" {
    const allocator = std.testing.allocator;
    var renderer = try initBatchTestRenderer(allocator);
    defer deinitBatchTestRenderer(&renderer, allocator);
    renderer.camera = .{
        .position = .{ .x = 5, .y = 10 },
        .zoom = 2,
    };

    const presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1800, .height = 1130 },
        .{ .width = 3600, .height = 2260 },
    );

    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });

    try prepareBatchTestFrame(&renderer, allocator, presentation);

    try std.testing.expectApproxEqAbs(@as(f32, 84.375), renderer.vertices.items[0].position[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 229.5), renderer.vertices.items[0].position[1], 0.001);
}

test "null swapchain texture preserves skipped no swapchain result path" {
    try std.testing.expect(swapchainUnavailable(null));
    try std.testing.expect(!swapchainUnavailable(@ptrFromInt(1)));
    try std.testing.expectEqual(FrameResult.skipped_no_swapchain, FrameResult.skipped_no_swapchain);
}

test "presentation state applies first group and changes only" {
    var active_presentation: ?CoordinatePresentation = null;

    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .logical));
    try std.testing.expectEqual(CoordinatePresentation.logical, active_presentation.?);
    try std.testing.expect(!shouldApplyPresentationState(&active_presentation, .logical));
    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .drawable));
    try std.testing.expectEqual(CoordinatePresentation.drawable, active_presentation.?);
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
    };

    try std.testing.expectEqual(@as(f32, 1), renderer.drawablePixelScale());

    renderer.current_presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1440 },
    );

    try std.testing.expectEqual(@as(f32, 2), renderer.drawablePixelScale());
}

test "warmed sprite batch prep does not allocate" {
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
    };
    defer renderer.texture_slots.deinit(allocator);
    defer renderer.deinitBatchStorage();

    try renderer.texture_slots.append(allocator, testTextureSlot(@ptrFromInt(1), 1, 1, 1, false));
    try renderer.reserveBatchStorage(1, 6, 1);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    renderer.allocator = failing_allocator.allocator();
    defer renderer.allocator = allocator;

    renderer.beginFrame(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try renderer.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    renderer.prepareFrameCommands(try batchTestPresentation());

    try std.testing.expectEqual(@as(usize, 1), renderer.commands.items.len);
    try std.testing.expectEqual(@as(usize, 6), renderer.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), renderer.draw_groups.items.len);
}

test "shader set selection prefers metal shading language when available" {
    const shader_set = try selectShaderSetFromFormats(
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL,
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL,
    );

    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_MSL, shader_set.format);
    try std.testing.expectEqualStrings("shaders/sprite.vert.msl", shader_set.vertex_path);
    try std.testing.expectEqualStrings("main0", shader_set.entrypoint);
}

test "shader set selection uses spirv when it is the matching format" {
    const shader_set = try selectShaderSetFromFormats(
        c.SDL_GPU_SHADERFORMAT_SPIRV,
        c.SDL_GPU_SHADERFORMAT_SPIRV,
    );

    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_SPIRV, shader_set.format);
    try std.testing.expectEqualStrings("shaders/sprite.vert.spv", shader_set.vertex_path);
    try std.testing.expectEqualStrings("main", shader_set.entrypoint);
}

test "shader set selection rejects unsupported format combinations" {
    try std.testing.expectError(
        error.UnsupportedShaderFormat,
        selectShaderSetFromFormats(c.SDL_GPU_SHADERFORMAT_SPIRV, c.SDL_GPU_SHADERFORMAT_MSL),
    );
}

test "sprite sorting preserves submission order within each layer" {
    const first = SpriteCommand{
        .sprite = .{
            .texture = testTextureId(10, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .layer = 0,
        },
        .sequence = 0,
    };
    const second = SpriteCommand{
        .sprite = .{
            .texture = testTextureId(3, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .layer = 0,
        },
        .sequence = 1,
    };

    try std.testing.expect(spriteCommandLessThan({}, first, second));
    try std.testing.expect(!spriteCommandLessThan({}, second, first));
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
