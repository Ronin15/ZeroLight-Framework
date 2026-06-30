// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared SoA sprite/tilemap graphics-pipeline vertex layout and alpha blend state.

const std = @import("std");
const sprite_batch = @import("../sprite_batch.zig");
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

pub const SoaSpriteVertexPipelineLayout = struct {
    vertex_buffers: [3]c.SDL_GPUVertexBufferDescription,
    vertex_attributes: [3]c.SDL_GPUVertexAttribute,
    color_target: c.SDL_GPUColorTargetDescription,

    pub fn init(target_format: c.SDL_GPUTextureFormat) SoaSpriteVertexPipelineLayout {
        var layout: SoaSpriteVertexPipelineLayout = undefined;
        layout.vertex_buffers = .{
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
        layout.vertex_attributes = .{
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
        layout.color_target = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        layout.color_target.format = target_format;
        layout.color_target.blend_state.enable_blend = true;
        layout.color_target.blend_state.src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
        layout.color_target.blend_state.dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        layout.color_target.blend_state.color_blend_op = c.SDL_GPU_BLENDOP_ADD;
        layout.color_target.blend_state.src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE;
        layout.color_target.blend_state.dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        layout.color_target.blend_state.alpha_blend_op = c.SDL_GPU_BLENDOP_ADD;
        return layout;
    }

    pub fn fillCreateInfo(
        self: *const SoaSpriteVertexPipelineLayout,
        pipeline_info: *c.SDL_GPUGraphicsPipelineCreateInfo,
        vertex_shader: *c.SDL_GPUShader,
        fragment_shader: *c.SDL_GPUShader,
    ) void {
        pipeline_info.* = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        pipeline_info.vertex_shader = vertex_shader;
        pipeline_info.fragment_shader = fragment_shader;
        pipeline_info.vertex_input_state.vertex_buffer_descriptions = &self.vertex_buffers;
        pipeline_info.vertex_input_state.num_vertex_buffers = self.vertex_buffers.len;
        pipeline_info.vertex_input_state.vertex_attributes = &self.vertex_attributes;
        pipeline_info.vertex_input_state.num_vertex_attributes = self.vertex_attributes.len;
        pipeline_info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        pipeline_info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        pipeline_info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        pipeline_info.rasterizer_state.front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
        pipeline_info.multisample_state.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        pipeline_info.target_info.color_target_descriptions = &self.color_target;
        pipeline_info.target_info.num_color_targets = 1;
    }
};
