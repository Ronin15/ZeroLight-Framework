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
const sprite_pipeline = @import("sprite_pipeline.zig");
const pipeline_common = @import("pipeline_common.zig");
const shader_paths = @import("shader_paths.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

test "tilemap shader paths match derived names for each format" {
    try std.testing.expectEqualStrings(shader_paths.vertex("tilemap", "spv"), tilemap_material.spirv_vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("tilemap", "spv"), tilemap_material.spirv_fragment_path);
    try std.testing.expectEqualStrings(shader_paths.vertex("tilemap", "msl"), tilemap_material.msl_vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("tilemap", "msl"), tilemap_material.msl_fragment_path);
    try std.testing.expectEqualStrings(shader_paths.vertex("tilemap", "dxil"), tilemap_material.dxil_vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("tilemap", "dxil"), tilemap_material.dxil_fragment_path);
}

test "tilemap material shader resource counts match shader binding layout" {
    try std.testing.expectEqual(@as(u32, 1), tilemap_material.fragment_samplers);
    try std.testing.expectEqual(@as(u32, 1), tilemap_material.fragment_storage_buffers);
    try std.testing.expectEqual(@as(u32, 1), tilemap_material.fragment_uniform_buffers);
    try std.testing.expectEqual(@as(u32, 1), tilemap_material.vertex_uniform_buffers);
}

test "tilemap shaderSetForFormat selects correct paths per format" {
    const msl = shaderSetForFormat(c.SDL_GPU_SHADERFORMAT_MSL);
    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_MSL, msl.format);
    try std.testing.expectEqualStrings(shader_paths.vertex("tilemap", "msl"), msl.vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("tilemap", "msl"), msl.fragment_path);
    try std.testing.expectEqualStrings("main0", msl.entrypoint);

    const dxil = shaderSetForFormat(c.SDL_GPU_SHADERFORMAT_DXIL);
    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_DXIL, dxil.format);
    try std.testing.expectEqualStrings(shader_paths.vertex("tilemap", "dxil"), dxil.vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("tilemap", "dxil"), dxil.fragment_path);
    try std.testing.expectEqualStrings("main", dxil.entrypoint);

    const spv = shaderSetForFormat(c.SDL_GPU_SHADERFORMAT_SPIRV);
    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_SPIRV, spv.format);
    try std.testing.expectEqualStrings(shader_paths.vertex("tilemap", "spv"), spv.vertex_path);
    try std.testing.expectEqualStrings(shader_paths.fragment("tilemap", "spv"), spv.fragment_path);
    try std.testing.expectEqualStrings("main", spv.entrypoint);
}

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
    .spirv_vertex_path = shader_paths.vertex("tilemap", "spv"),
    .spirv_fragment_path = shader_paths.fragment("tilemap", "spv"),
    .spirv_entrypoint = "main",
    .dxil_vertex_path = shader_paths.vertex("tilemap", "dxil"),
    .dxil_fragment_path = shader_paths.fragment("tilemap", "dxil"),
    .dxil_entrypoint = "main",
    .msl_vertex_path = shader_paths.vertex("tilemap", "msl"),
    .msl_fragment_path = shader_paths.fragment("tilemap", "msl"),
    .msl_entrypoint = "main0",
    .fragment_samplers = 1,
    .fragment_storage_buffers = 1,
    .fragment_uniform_buffers = 1,
    .vertex_uniform_buffers = 1,
};

fn materialShaderPaths(material: TilemapMaterial) sprite_pipeline.MaterialShaderPaths {
    return .{
        .spirv_vertex_path = material.spirv_vertex_path,
        .spirv_fragment_path = material.spirv_fragment_path,
        .spirv_entrypoint = material.spirv_entrypoint,
        .dxil_vertex_path = material.dxil_vertex_path,
        .dxil_fragment_path = material.dxil_fragment_path,
        .dxil_entrypoint = material.dxil_entrypoint,
        .msl_vertex_path = material.msl_vertex_path,
        .msl_fragment_path = material.msl_fragment_path,
        .msl_entrypoint = material.msl_entrypoint,
    };
}

/// Tilemap shader paths for the format already chosen by the sprite pipeline's
/// `selectShaderSet`, so both pipelines load the same backend's bytecode.
pub fn shaderSetForFormat(format: c.SDL_GPUShaderFormat) ShaderSet {
    return sprite_pipeline.shaderSetFromFormat(format, materialShaderPaths(tilemap_material));
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

    const layout = pipeline_common.SoaSpriteVertexPipelineLayout.init(target_format);
    var pipeline_info: c.SDL_GPUGraphicsPipelineCreateInfo = undefined;
    layout.fillCreateInfo(&pipeline_info, vertex_shader, fragment_shader);

    return c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_info) orelse {
        return sdl.sdlError("SDL_CreateGPUGraphicsPipeline");
    };
}
