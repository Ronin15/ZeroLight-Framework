// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! GPU-driven tilemap pipeline. A single world-space quad per dense layer is
//! drawn with the camera vertex uniform (set 1); the fragment shader reads the
//! layer's tile ids from a storage buffer (set 2, binding 1) and samples the
//! atlas (set 2, binding 0), with grid/atlas constants in a fragment UBO
//! (set 3). Mirrors `sprite_pipeline.zig` but adds the storage buffer + UBO.

const std = @import("std");
const AssetStore = @import("../../assets/assets.zig").AssetStore;
const sprite_batch = @import("../sprite_batch.zig");
const sprite_pipeline = @import("sprite_pipeline.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

pub const ShaderSet = sprite_pipeline.ShaderSet;

pub const TilemapMaterial = struct {
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
    fragment_storage_buffers: u32,
    fragment_uniform_buffers: u32,
    vertex_uniform_buffers: u32,
};

pub const tilemap_material = TilemapMaterial{
    .name = "tilemap",
    .spirv_vertex_path = "shaders/tilemap.vert.spv",
    .spirv_fragment_path = "shaders/tilemap.frag.spv",
    .spirv_entrypoint = "main",
    .dxil_vertex_path = "shaders/tilemap.vert.dxil",
    .dxil_fragment_path = "shaders/tilemap.frag.dxil",
    .dxil_entrypoint = "main",
    .msl_vertex_path = "shaders/tilemap.vert.msl",
    .msl_fragment_path = "shaders/tilemap.frag.msl",
    .msl_entrypoint = "main0",
    .fragment_samplers = 1,
    .fragment_storage_buffers = 1,
    .fragment_uniform_buffers = 1,
    .vertex_uniform_buffers = 1,
};

/// Tilemap shader paths for the format already chosen by the sprite pipeline's
/// `selectShaderSet`, so both pipelines load the same backend's bytecode.
pub fn shaderSetForFormat(format: c.SDL_GPUShaderFormat) ShaderSet {
    if (format == c.SDL_GPU_SHADERFORMAT_MSL) return .{
        .format = format,
        .vertex_path = tilemap_material.msl_vertex_path,
        .fragment_path = tilemap_material.msl_fragment_path,
        .entrypoint = tilemap_material.msl_entrypoint,
    };
    if (format == c.SDL_GPU_SHADERFORMAT_DXIL) return .{
        .format = format,
        .vertex_path = tilemap_material.dxil_vertex_path,
        .fragment_path = tilemap_material.dxil_fragment_path,
        .entrypoint = tilemap_material.dxil_entrypoint,
    };
    return .{
        .format = format,
        .vertex_path = tilemap_material.spirv_vertex_path,
        .fragment_path = tilemap_material.spirv_fragment_path,
        .entrypoint = tilemap_material.spirv_entrypoint,
    };
}

pub fn createTilemapPipeline(
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    assets: AssetStore,
    target_format: c.SDL_GPUTextureFormat,
    shader_set: ShaderSet,
) !*c.SDL_GPUGraphicsPipeline {
    const vertex_shader = try sprite_pipeline.createShader(
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
        tilemap_material.vertex_uniform_buffers,
    );
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);

    const fragment_shader = try sprite_pipeline.createShader(
        allocator,
        device,
        assets,
        shader_set.fragment_path,
        shader_set.format,
        shader_set.entrypoint,
        c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        tilemap_material.fragment_samplers,
        0,
        tilemap_material.fragment_storage_buffers,
        tilemap_material.fragment_uniform_buffers,
    );
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);

    // The layer quad uses the shared sprite Vertex layout; only position is
    // consumed, but matching the layout keeps one vertex-buffer path.
    var vertex_buffer = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(sprite_batch.Vertex),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };
    var vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = @offsetOf(sprite_batch.Vertex, "position"),
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = @offsetOf(sprite_batch.Vertex, "uv"),
        },
        .{
            .location = 2,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
            .offset = @offsetOf(sprite_batch.Vertex, "color"),
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
        return sdl.sdlError("SDL_CreateGPUGraphicsPipeline");
    };
}
