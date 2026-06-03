// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const build_options = @import("build_options");
const Camera2D = @import("camera.zig").Camera2D;
const config = @import("../config.zig");
const math = @import("../core/math.zig");
const sdl = @import("../platform/sdl.zig");
const c = sdl.c;

const max_shader_bytes = 1024 * 1024;
const initial_batch_vertices = 4096 * 6;
const bytes_per_pixel = 4;

pub const TextureHandle = struct {
    index: usize,
};

pub const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Sprite = struct {
    texture: TextureHandle,
    source: ?Rect = null,
    dest: Rect,
    tint: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    origin: math.Vec2 = .{},
    rotation: f32 = 0,
    layer: i32 = 0,
    screen_space: bool = false,
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
    textures: std.ArrayList(TextureResource) = .empty,
    commands: std.ArrayList(SpriteCommand) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    draw_groups: std.ArrayList(DrawGroup) = .empty,
    white_texture: TextureHandle = .{ .index = 0 },
    camera: Camera2D = .{},
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
        validateConfig(app_config) catch |err| {
            std.log.err(
                "frames_in_flight must be between 1 and 3, got {}",
                .{app_config.frames_in_flight},
            );
            return err;
        };

        const device = c.SDL_CreateGPUDevice(@intCast(build_options.gpu_shader_formats), app_config.gpu_debug, null) orelse {
            return sdlError("SDL_CreateGPUDevice");
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        if (c.SDL_GetGPUDeviceDriver(device)) |driver| {
            std.log.info("SDL_GPU driver: {s}", .{driver});
        } else {
            std.log.info("SDL_GPU driver: unknown", .{});
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
        };

        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        renderer.white_texture = try renderer.createTextureFromPixels(white_pixel[0..], 1, 1, bytes_per_pixel);
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.waitForIdle();

        for (self.textures.items) |texture| {
            if (texture.alive) {
                c.SDL_ReleaseGPUTexture(self.device, texture.texture);
            }
        }
        self.textures.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.draw_groups.deinit(self.allocator);

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

    pub fn createTextureFromPng(self: *Renderer, assets: AssetStore, relative_path: []const u8) !TextureHandle {
        const path = try assets.resolveReadablePath(relative_path);
        defer self.allocator.free(path);

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const loaded = c.SDL_LoadPNG(path_z.ptr) orelse {
            return sdlError("SDL_LoadPNG");
        };
        defer c.SDL_DestroySurface(loaded);

        return try self.createTextureFromSurface(loaded);
    }

    pub fn createTextureFromSurface(self: *Renderer, surface: *c.SDL_Surface) !TextureHandle {
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

    pub fn destroyTexture(self: *Renderer, handle: TextureHandle) void {
        if (handle.index >= self.textures.items.len) return;
        if (handle.index == self.white_texture.index) return;

        const texture = &self.textures.items[handle.index];
        if (texture.alive) {
            c.SDL_ReleaseGPUTexture(self.device, texture.texture);
            texture.alive = false;
        }
    }

    pub fn endFrame(self: *Renderer) !FrameResult {
        try self.buildBatch();
        if (self.vertices.items.len > 0) {
            try self.ensureBatchCapacity(self.vertices.items.len);
        }

        const command_buffer = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return sdlError("SDL_AcquireGPUCommandBuffer");
        };
        var command_submitted = false;
        errdefer if (!command_submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
        };

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command_buffer, self.window, &swapchain_texture, &width, &height)) {
            return sdlError("SDL_WaitAndAcquireGPUSwapchainTexture");
        }

        const acquired_swapchain_texture = swapchain_texture orelse {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
            command_submitted = true;
            return .skipped_no_swapchain;
        };

        self.viewport_width = width;
        self.viewport_height = height;

        if (self.vertices.items.len > 0) {
            try self.uploadVertices(command_buffer);
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
            return sdlError("SDL_BeginGPURenderPass");
        };
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

        if (self.vertices.items.len > 0) {
            var frame_uniform = FrameUniform{
                .viewport_size = .{
                    @floatFromInt(self.viewport_width),
                    @floatFromInt(self.viewport_height),
                },
                .padding = .{ 0, 0 },
            };
            c.SDL_PushGPUVertexUniformData(command_buffer, 0, &frame_uniform, @sizeOf(FrameUniform));

            var vertex_binding = c.SDL_GPUBufferBinding{
                .buffer = self.vertex_buffer,
                .offset = 0,
            };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &vertex_binding, 1);

            for (self.draw_groups.items) |group| {
                const texture = self.textures.items[group.texture.index];
                if (!texture.alive) continue;

                var sampler_binding = c.SDL_GPUTextureSamplerBinding{
                    .texture = texture.texture,
                    .sampler = self.sampler,
                };
                c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_binding, 1);
                c.SDL_DrawGPUPrimitives(render_pass, group.vertex_count, 1, group.first_vertex, 0);
            }
        }

        c.SDL_EndGPURenderPass(render_pass);

        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            return sdlError("SDL_SubmitGPUCommandBuffer");
        }
        command_submitted = true;
        return .submitted;
    }

    pub fn createTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !TextureHandle {
        const texture = try self.uploadTextureFromPixels(pixels, width, height, pitch);
        errdefer c.SDL_ReleaseGPUTexture(self.device, texture.texture);

        const handle = TextureHandle{ .index = self.textures.items.len };
        try self.textures.append(self.allocator, texture);
        return handle;
    }

    pub fn replaceTextureFromPixels(
        self: *Renderer,
        handle: TextureHandle,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !void {
        if (handle.index >= self.textures.items.len or handle.index == self.white_texture.index) {
            return error.InvalidTexture;
        }

        const next_texture = try self.uploadTextureFromPixels(pixels, width, height, pitch);
        errdefer c.SDL_ReleaseGPUTexture(self.device, next_texture.texture);

        const texture = &self.textures.items[handle.index];
        if (texture.alive) {
            c.SDL_ReleaseGPUTexture(self.device, texture.texture);
        }
        texture.* = next_texture;
    }

    fn uploadTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !TextureResource {
        try validateTexturePixels(pixels, width, height, pitch);

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
        _ = c.SDL_WaitForGPUIdle(self.device);

        return .{
            .texture = texture,
            .width = width,
            .height = height,
        };
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

    fn uploadVertices(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer) !void {
        const bytes = std.mem.sliceAsBytes(self.vertices.items);
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.vertex_transfer_buffer, true) orelse {
            return sdlError("SDL_MapGPUTransferBuffer");
        };
        const mapped_bytes = @as([*]u8, @ptrCast(mapped))[0..bytes.len];
        @memcpy(mapped_bytes, bytes);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.vertex_transfer_buffer);

        const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse {
            return sdlError("SDL_BeginGPUCopyPass");
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

    fn buildBatch(self: *Renderer) !void {
        std.mem.sort(SpriteCommand, self.commands.items, {}, spriteCommandLessThan);

        var active_texture: ?TextureHandle = null;
        var active_first_vertex: u32 = 0;
        var active_vertex_count: u32 = 0;

        for (self.commands.items) |command| {
            const first_vertex: u32 = @intCast(self.vertices.items.len);
            if (!try self.appendSpriteVertices(command.sprite)) continue;

            if (active_texture == null or active_texture.?.index != command.sprite.texture.index) {
                if (active_texture) |texture| {
                    try self.draw_groups.append(self.allocator, .{
                        .texture = texture,
                        .first_vertex = active_first_vertex,
                        .vertex_count = active_vertex_count,
                    });
                }
                active_texture = command.sprite.texture;
                active_first_vertex = first_vertex;
                active_vertex_count = 6;
            } else {
                active_vertex_count += 6;
            }
        }

        if (active_texture) |texture| {
            try self.draw_groups.append(self.allocator, .{
                .texture = texture,
                .first_vertex = active_first_vertex,
                .vertex_count = active_vertex_count,
            });
        }
    }

    fn appendSpriteVertices(self: *Renderer, sprite: Sprite) !bool {
        if (sprite.texture.index >= self.textures.items.len) return false;
        const texture = self.textures.items[sprite.texture.index];
        if (!texture.alive) return false;

        const source = sprite.source orelse Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(texture.width),
            .h = @floatFromInt(texture.height),
        };

        const tex_u0 = source.x / @as(f32, @floatFromInt(texture.width));
        const tex_v0 = source.y / @as(f32, @floatFromInt(texture.height));
        const tex_u1 = (source.x + source.w) / @as(f32, @floatFromInt(texture.width));
        const tex_v1 = (source.y + source.h) / @as(f32, @floatFromInt(texture.height));

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
        for (indices) |index| {
            const point = local[index];
            const rotated = math.Vec2{
                .x = point.x * rotation_cos - point.y * rotation_sin,
                .y = point.x * rotation_sin + point.y * rotation_cos,
            };
            const world = math.Vec2{
                .x = sprite.dest.x + sprite.origin.x + rotated.x,
                .y = sprite.dest.y + sprite.origin.y + rotated.y,
            };
            const screen = if (sprite.screen_space) world else self.camera.worldToScreen(world);
            try self.vertices.append(self.allocator, .{
                .position = .{ screen.x, screen.y },
                .uv = uv[index],
                .color = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
            });
        }
        return true;
    }
};

const TextureResource = struct {
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
    alive: bool = true,
};

const SpriteCommand = struct {
    sprite: Sprite,
    sequence: u64,
};

const DrawGroup = struct {
    texture: TextureHandle,
    first_vertex: u32,
    vertex_count: u32,
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
    const code = try assets.readAlloc(path, max_shader_bytes);
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
    if (app_config.frames_in_flight < 1 or app_config.frames_in_flight > 3) {
        return error.InvalidConfig;
    }
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

    std.log.warn("requested SDL_GPU present mode is unsupported; falling back to vsync", .{});
    return c.SDL_GPU_PRESENTMODE_VSYNC;
}

fn selectShaderSet(device: *c.SDL_GPUDevice) error{UnsupportedShaderFormat}!ShaderSet {
    const device_formats = c.SDL_GetGPUShaderFormats(device);
    const app_formats: c.SDL_GPUShaderFormat = @intCast(build_options.gpu_shader_formats);
    return selectShaderSetFromFormats(device_formats, app_formats) catch |err| {
        std.log.err(
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

fn spriteCommandLessThan(_: void, lhs: SpriteCommand, rhs: SpriteCommand) bool {
    if (lhs.sprite.layer != rhs.sprite.layer) return lhs.sprite.layer < rhs.sprite.layer;
    return lhs.sequence < rhs.sequence;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

test "batch builder skips invalid and destroyed texture handles" {
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
    defer renderer.textures.deinit(allocator);
    defer renderer.commands.deinit(allocator);
    defer renderer.vertices.deinit(allocator);
    defer renderer.draw_groups.deinit(allocator);

    try renderer.textures.append(allocator, .{
        .texture = @ptrFromInt(1),
        .width = 1,
        .height = 1,
    });
    try renderer.textures.append(allocator, .{
        .texture = @ptrFromInt(2),
        .width = 1,
        .height = 1,
        .alive = false,
    });

    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = .{ .index = 42 },
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 0,
    });
    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = .{ .index = 1 },
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 1,
    });
    try renderer.commands.append(allocator, .{
        .sprite = .{
            .texture = .{ .index = 0 },
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
        .sequence = 2,
    });

    try renderer.buildBatch();

    try std.testing.expectEqual(@as(usize, 6), renderer.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), renderer.draw_groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), renderer.draw_groups.items[0].texture.index);
    try std.testing.expectEqual(@as(u32, 0), renderer.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), renderer.draw_groups.items[0].vertex_count);
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
            .texture = .{ .index = 10 },
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .layer = 0,
        },
        .sequence = 0,
    };
    const second = SpriteCommand{
        .sprite = .{
            .texture = .{ .index = 3 },
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
