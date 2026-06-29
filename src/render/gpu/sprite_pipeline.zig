// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("../../assets/assets.zig").AssetStore;
const log = @import("../../core/logging.zig").render;
const sprite_batch = @import("../sprite_batch.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;
const shader_paths = @import("shader_paths.zig");

const max_shader_bytes = 1024 * 1024;

pub const SpriteMaterial = struct {
    name: []const u8,
    spirv_vertex_path: []const u8,
    spirv_fragment_path: []const u8,
    spirv_entrypoint: [:0]const u8,
    dxil_vertex_path: []const u8,
    dxil_fragment_path: []const u8,
    dxil_entrypoint: [:0]const u8,
    msl_vertex_path: []const u8,
    msl_fragment_path: []const u8,
    msl_entrypoint: [:0]const u8,
    fragment_samplers: u32,
    vertex_uniform_buffers: u32,
};

pub const sprite_material = SpriteMaterial{
    .name = "sprite",
    .spirv_vertex_path = shader_paths.vertex("sprite", "spv"),
    .spirv_fragment_path = shader_paths.fragment("sprite", "spv"),
    .spirv_entrypoint = "main",
    .dxil_vertex_path = shader_paths.vertex("sprite", "dxil"),
    .dxil_fragment_path = shader_paths.fragment("sprite", "dxil"),
    .dxil_entrypoint = "main",
    .msl_vertex_path = shader_paths.vertex("sprite", "msl"),
    .msl_fragment_path = shader_paths.fragment("sprite", "msl"),
    .msl_entrypoint = "main0",
    .fragment_samplers = 1,
    .vertex_uniform_buffers = 1,
};

pub const ShaderSet = struct {
    format: c.SDL_GPUShaderFormat,
    vertex_path: []const u8,
    fragment_path: []const u8,
    entrypoint: [:0]const u8,
};

pub fn createSpritePipeline(
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
        sprite_material.vertex_uniform_buffers,
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
        sprite_material.fragment_samplers,
        0,
        0,
        0,
    );
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);

    // One vertex buffer per SoA column: Position slot 0, Uv slot 1, VertexColor
    // slot 2. Each attribute reads its own buffer at offset 0.
    var vertex_buffers = [_]c.SDL_GPUVertexBufferDescription{
        .{
            .slot = 0,
            .pitch = @sizeOf(sprite_batch.Position),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        },
        .{
            .slot = 1,
            .pitch = @sizeOf(sprite_batch.Uv),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        },
        .{
            .slot = 2,
            .pitch = @sizeOf(sprite_batch.VertexColor),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        },
    };
    var vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = 0,
        },
        .{
            .location = 1,
            .buffer_slot = 1,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = 0,
        },
        .{
            .location = 2,
            .buffer_slot = 2,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
            .offset = 0,
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
    pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffers;
    pipeline_info.vertex_input_state.num_vertex_buffers = vertex_buffers.len;
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

pub fn selectShaderSet(device: *c.SDL_GPUDevice, app_formats: c.SDL_GPUShaderFormat) error{UnsupportedShaderFormat}!ShaderSet {
    const device_formats = c.SDL_GetGPUShaderFormats(device);
    return selectShaderSetFromFormats(device_formats, app_formats) catch |err| {
        log.err(
            "SDL_GPU selected device supports shader formats 0x{x}, but app provides 0x{x}",
            .{ device_formats, app_formats },
        );
        return err;
    };
}

pub fn selectShaderSetFromFormats(
    device_formats: c.SDL_GPUShaderFormat,
    app_formats: c.SDL_GPUShaderFormat,
) error{UnsupportedShaderFormat}!ShaderSet {
    const usable_formats = device_formats & app_formats;

    if ((usable_formats & c.SDL_GPU_SHADERFORMAT_MSL) != 0) {
        return .{
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
            .vertex_path = sprite_material.msl_vertex_path,
            .fragment_path = sprite_material.msl_fragment_path,
            .entrypoint = sprite_material.msl_entrypoint,
        };
    }

    if ((usable_formats & c.SDL_GPU_SHADERFORMAT_DXIL) != 0) {
        return .{
            .format = c.SDL_GPU_SHADERFORMAT_DXIL,
            .vertex_path = sprite_material.dxil_vertex_path,
            .fragment_path = sprite_material.dxil_fragment_path,
            .entrypoint = sprite_material.dxil_entrypoint,
        };
    }

    if ((usable_formats & c.SDL_GPU_SHADERFORMAT_SPIRV) != 0) {
        return .{
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
            .vertex_path = sprite_material.spirv_vertex_path,
            .fragment_path = sprite_material.spirv_fragment_path,
            .entrypoint = sprite_material.spirv_entrypoint,
        };
    }

    return error.UnsupportedShaderFormat;
}

pub fn shaderFormatName(format: c.SDL_GPUShaderFormat) []const u8 {
    if (format == c.SDL_GPU_SHADERFORMAT_MSL) return "MSL";
    if (format == c.SDL_GPU_SHADERFORMAT_DXIL) return "DXIL";
    if (format == c.SDL_GPU_SHADERFORMAT_SPIRV) return "SPIR-V";
    return "unknown";
}

pub fn createShader(
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

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
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

test "shader set selection uses dxil before spirv when both are available" {
    const shader_set = try selectShaderSetFromFormats(
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL,
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL,
    );

    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_DXIL, shader_set.format);
    try std.testing.expectEqualStrings("shaders/sprite.vert.dxil", shader_set.vertex_path);
    try std.testing.expectEqualStrings("main", shader_set.entrypoint);
    try std.testing.expectEqualStrings("DXIL", shaderFormatName(shader_set.format));
}

test "shader set selection uses spirv when it is the matching format" {
    const shader_set = try selectShaderSetFromFormats(
        c.SDL_GPU_SHADERFORMAT_SPIRV,
        c.SDL_GPU_SHADERFORMAT_SPIRV,
    );

    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_SPIRV, shader_set.format);
    try std.testing.expectEqualStrings(shader_paths.vertex("sprite", "spv"), shader_set.vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("sprite", "spv"), shader_set.fragment_path);
    try std.testing.expectEqualStrings("main", shader_set.entrypoint);
}

test "shader set selection rejects unsupported format combinations" {
    try std.testing.expectError(
        error.UnsupportedShaderFormat,
        selectShaderSetFromFormats(c.SDL_GPU_SHADERFORMAT_SPIRV, c.SDL_GPU_SHADERFORMAT_MSL),
    );
}

test "shader set selection matches each platform's single-format build output" {
    // macOS builds emit MSL only; SDL device on macOS reports MSL only.
    const msl = try selectShaderSetFromFormats(
        c.SDL_GPU_SHADERFORMAT_MSL,
        c.SDL_GPU_SHADERFORMAT_MSL,
    );
    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_MSL, msl.format);
    try std.testing.expectEqualStrings(shader_paths.vertex("sprite", "msl"), msl.vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("sprite", "msl"), msl.fragment_path);

    // Windows builds emit DXIL only; SDL device on Windows reports DXIL only.
    const dxil = try selectShaderSetFromFormats(
        c.SDL_GPU_SHADERFORMAT_DXIL,
        c.SDL_GPU_SHADERFORMAT_DXIL,
    );
    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_DXIL, dxil.format);
    try std.testing.expectEqualStrings(shader_paths.vertex("sprite", "dxil"), dxil.vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("sprite", "dxil"), dxil.fragment_path);
}
