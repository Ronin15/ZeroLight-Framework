/* Copyright (c) 2026 Hammer Forged Games
 * All rights reserved.
 * Licensed under the MIT License - see LICENSE file for details
*/

#version 450

layout(location = 0) in vec2 in_world_pos;

layout(location = 0) out vec4 out_color;

// Fragment resource set: sampler at binding 0, tile-data storage buffer at
// binding 1 (a direct copy of the world's row-major dense_tile_ids).
layout(set = 2, binding = 0) uniform sampler2D atlas_texture;
layout(set = 2, binding = 1) readonly buffer TileData {
    uint tile_ids[];
} tiles;

layout(set = 3, binding = 0) uniform TilemapUniform {
    // grid:  x=tile_size, y=grid_width, z=grid_height, w=invalid_tile_id
    vec4 grid;
    // atlas: x=columns, y=atlas_width_px, z=atlas_height_px, w=atlas_tile_px
    vec4 atlas;
} tm;

void main() {
    float tile_size = tm.grid.x;
    int grid_w = int(tm.grid.y);
    int grid_h = int(tm.grid.z);
    uint invalid_id = uint(tm.grid.w);

    vec2 cell_f = floor(in_world_pos / tile_size);
    int cx = int(cell_f.x);
    int cy = int(cell_f.y);
    if (cx < 0 || cy < 0 || cx >= grid_w || cy >= grid_h) {
        discard;
    }

    uint tile_id = tiles.tile_ids[cy * grid_w + cx];
    if (tile_id == invalid_id) {
        // Empty cell: see-through to whatever layer drew below.
        discard;
    }

    int columns = int(tm.atlas.x);
    float atlas_w = tm.atlas.y;
    float atlas_h = tm.atlas.z;
    float atlas_tile = tm.atlas.w;

    int col = int(tile_id) % columns;
    int row = int(tile_id) / columns;

    // In-tile offset from fract() keeps atlas sampling inside one tile cell,
    // so floating-point camera offsets never bleed across tile boundaries.
    vec2 in_tile = fract(in_world_pos / tile_size);
    vec2 atlas_px =
        vec2(float(col) * atlas_tile, float(row) * atlas_tile) + in_tile * atlas_tile;
    vec2 atlas_uv = atlas_px / vec2(atlas_w, atlas_h);

    out_color = texture(atlas_texture, atlas_uv);
}
