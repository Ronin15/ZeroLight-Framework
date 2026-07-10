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
    // layer_meta: x=this draw's composited layer count (topmost-first), y/z/w unused
    ivec4 layer_meta;
    // layer_offsets: element offsets into the combined tile-data buffer, one per
    // composited layer (layer_meta.x of them valid), topmost layer first. Packed
    // 4-per-uvec4 so this matches a flat Zig [32]u32 byte-for-byte under std140
    // (uvec4 array elements have no interior padding).
    uvec4 layer_offsets[8];
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

    uint cell_index = uint(cy * grid_w + cx);
    int layer_count = tm.layer_meta.x;
    uint tile_id = invalid_id;
    int resolved_depth = 0;
    // Dynamically-uniform loop: every fragment in this draw shares layer_count,
    // so this is an ordinary bounded loop, no toolchain risk. Stops at the first
    // opaque hit walking topmost-first, so a hole in a shallower layer falls
    // through to whichever composited layer beneath it is actually opaque.
    for (int i = 0; i < layer_count; i++) {
        uint layer_offset = tm.layer_offsets[i / 4][i % 4];
        uint candidate = tiles.tile_ids[layer_offset + cell_index];
        if (candidate != invalid_id) {
            tile_id = candidate;
            resolved_depth = i;
            break;
        }
    }
    if (tile_id == invalid_id) {
        // Every composited layer is empty at this cell: see-through to whatever
        // draws below (another composite draw, or the clear color).
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

    // Soft contact-shadow on the rim of the surface tile where it overhangs a
    // hole (a neighboring cell whose topmost layer is empty) — reads as a cast
    // shadow, not a colored highlight. Only applies to the world's true topmost
    // tile: `resolved_depth == 0` alone means "topmost within this draw's own
    // composited window", which is NOT the same thing when the CPU split the
    // dense stack into more than one composite draw this frame (host-side
    // `partitionDenseCompositeBuckets`/`collectDenseInterleaveDepths`) — a
    // deeper draw's own resolved_depth 0 can be a tile only visible because a
    // shallower draw is a hole here, i.e. exactly the "tile visible through the
    // hole is left alone" case, not the surface case. `layer_meta.y` is set by
    // the host only for the one composite draw holding the frame's actual
    // shallowest submitted layer (`Renderer.TilemapWindowLayers.is_shallowest_bucket`),
    // so gating on both keeps this stable regardless of how the CPU happened to
    // bucket the draws this frame. Deliberately not screen-space-derivative-based
    // (fwidth on a value that is constant per-cell and jumps hard at cell edges
    // depends on where that edge falls relative to the GPU's 2x2 derivative
    // quads, which shifts with camera pan — it fired inconsistently). Reading
    // the neighbor cells' actual tile data directly is deterministic regardless
    // of camera position.
    if (resolved_depth == 0 && layer_count > 0 && tm.layer_meta.y != 0) {
        uint top_layer_offset = tm.layer_offsets[0][0];
        const float rim_margin = 0.28;
        // Subtractive, not multiplicative: this tileset's floor/cave tiles sit at
        // ~0.09-0.19 luminance (measured from world_tileset.png), so scaling by a
        // percentage shrinks to an imperceptible absolute change on the darkest
        // ones. A fixed subtract-and-clamp crushes the darkest tiles toward black
        // at the rim (still a real, visible shadow) while giving lighter tiles a
        // clearly visible dip too.
        const float rim_shadow_amount = 0.09;
        float rim = 0.0;

        if (in_tile.x < rim_margin && cx > 0) {
            uint left_index = uint(cy * grid_w + (cx - 1));
            if (tiles.tile_ids[top_layer_offset + left_index] == invalid_id) {
                rim = max(rim, 1.0 - in_tile.x / rim_margin);
            }
        }
        if (in_tile.x > 1.0 - rim_margin && cx + 1 < grid_w) {
            uint right_index = uint(cy * grid_w + (cx + 1));
            if (tiles.tile_ids[top_layer_offset + right_index] == invalid_id) {
                rim = max(rim, 1.0 - (1.0 - in_tile.x) / rim_margin);
            }
        }
        if (in_tile.y < rim_margin && cy > 0) {
            uint up_index = uint((cy - 1) * grid_w + cx);
            if (tiles.tile_ids[top_layer_offset + up_index] == invalid_id) {
                rim = max(rim, 1.0 - in_tile.y / rim_margin);
            }
        }
        if (in_tile.y > 1.0 - rim_margin && cy + 1 < grid_h) {
            uint down_index = uint((cy + 1) * grid_w + cx);
            if (tiles.tile_ids[top_layer_offset + down_index] == invalid_id) {
                rim = max(rim, 1.0 - (1.0 - in_tile.y) / rim_margin);
            }
        }

        out_color.rgb = max(out_color.rgb - rim_shadow_amount * rim, 0.0);
    }
}
