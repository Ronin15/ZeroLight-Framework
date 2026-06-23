/* Copyright (c) 2026 Hammer Forged Games
 * All rights reserved.
 * Licensed under the MIT License - see LICENSE file for details
*/

#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

layout(set = 1, binding = 0) uniform FrameUniform {
    vec4 drawable_size;
    vec4 position_transform;
} u;

void main() {
    vec2 drawable_position =
        in_position * u.position_transform.xy + u.position_transform.zw;
    vec2 ndc = vec2(
        (drawable_position.x / u.drawable_size.x) * 2.0 - 1.0,
        1.0 - (drawable_position.y / u.drawable_size.y) * 2.0
    );
    gl_Position = vec4(ndc, 0.0, 1.0);
    out_uv = in_uv;
    out_color = in_color;
}
