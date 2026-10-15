/* Copyright (c) 2026 Hammer Forged Games
 * All rights reserved.
 * Licensed under the MIT License - see LICENSE file for details
*/

#version 450

layout(location = 0) in vec2 in_world_pos;

layout(location = 0) out vec4 out_color;

// Fragment resource set: sampler at binding 0, the world's tile store at binding 1
// (renderer.zig tile store layout). A layer's directory is side * side toroidal
// words, chunk (cx, cy) at ((cy & (side - 1)) * side + (cx & (side - 1))), then a
// link word holding the next deeper layer's directory start. A directory word with
// bit 31 set is a uniform chunk whose tile is its low 16 bits; any other word is the
// absolute element offset of the chunk's block, which holds its tiles in local
// row-major order, two 16-bit ids per word, low half first.
layout(set = 2, binding = 0) uniform sampler2D atlas_texture;
layout(set = 2, binding = 1) readonly buffer TileData {
    uint words[];
} tiles;

// Field order and std140 layout match sprite_batch.zig's TilemapParams.
layout(set = 3, binding = 0) uniform TilemapUniform {
    // grid:  x=tile_size, y=grid_width, z=grid_height, w=invalid_tile_id
    vec4 grid;
    // atlas: x=columns, y=atlas_width_px, z=atlas_height_px, w=atlas_tile_px
    vec4 atlas;
    // layer_meta: x=this draw's chained layer count, y=shallowest-bucket flag,
    // z=chunk shift (log2 of the chunk edge), w=directory side in chunks
    ivec4 layer_meta;
    // window: resident chunks, min x, min y, max-exclusive x, max-exclusive y
    uvec4 window;
    // chain: x=this draw's topmost directory start
    uvec4 chain;
} tm;

const uint uniform_bit = 0x80000000u;

bool chunkResident(uint chunk_x, uint chunk_y) {
    return chunk_x >= tm.window.x && chunk_y >= tm.window.y && chunk_x < tm.window.z && chunk_y < tm.window.w;
}

// The tile at cell (cx, cy) of the layer whose directory starts at `directory`;
// the cell's chunk must be resident.
uint tileAt(uint directory, uint cx, uint cy) {
    uint shift = uint(tm.layer_meta.z);
    uint side = uint(tm.layer_meta.w);
    uint side_mask = side - 1u;
    uint edge_mask = (1u << shift) - 1u;
    uint chunk_x = cx >> shift;
    uint chunk_y = cy >> shift;
    uint word = tiles.words[directory + (chunk_y & side_mask) * side + (chunk_x & side_mask)];
    if ((word & uniform_bit) != 0u) {
        return word & 0xFFFFu;
    }
    uint local_cell = ((cy & edge_mask) << shift) | (cx & edge_mask);
    uint element = tiles.words[word + (local_cell >> 1u)];
    return (element >> ((local_cell & 1u) * 16u)) & 0xFFFFu;
}

// Whether the neighbor cell (cx, cy) is resident and empty on the topmost layer.
bool topmostHole(uint cx, uint cy) {
    uint shift = uint(tm.layer_meta.z);
    if (!chunkResident(cx >> shift, cy >> shift)) {
        return false;
    }
    return tileAt(tm.chain.x, cx, cy) == uint(tm.grid.w);
}

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
    uint ucx = uint(cx);
    uint ucy = uint(cy);
    uint shift = uint(tm.layer_meta.z);
    if (!chunkResident(ucx >> shift, ucy >> shift)) {
        discard;
    }
    uint side = uint(tm.layer_meta.w);

    int layer_count = tm.layer_meta.x;
    uint tile_id = invalid_id;
    int resolved_depth = 0;
    // Dynamically-uniform loop: every fragment in this draw shares layer_count and
    // the chain, so this is an ordinary bounded loop. Stops at the first opaque hit
    // walking topmost-first, so a hole in a shallower layer falls through to
    // whichever chained layer beneath it is actually opaque.
    uint directory = tm.chain.x;
    for (int i = 0; i < layer_count; i++) {
        uint candidate = tileAt(directory, ucx, ucy);
        if (candidate != invalid_id) {
            tile_id = candidate;
            resolved_depth = i;
            break;
        }
        directory = tiles.words[directory + side * side];
    }
    if (tile_id == invalid_id) {
        // Every chained layer is empty at this cell: see-through to whatever draws
        // below (another composite draw, or the clear color).
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
            if (topmostHole(ucx - 1u, ucy)) {
                rim = max(rim, 1.0 - in_tile.x / rim_margin);
            }
        }
        if (in_tile.x > 1.0 - rim_margin && cx + 1 < grid_w) {
            if (topmostHole(ucx + 1u, ucy)) {
                rim = max(rim, 1.0 - (1.0 - in_tile.x) / rim_margin);
            }
        }
        if (in_tile.y < rim_margin && cy > 0) {
            if (topmostHole(ucx, ucy - 1u)) {
                rim = max(rim, 1.0 - in_tile.y / rim_margin);
            }
        }
        if (in_tile.y > 1.0 - rim_margin && cy + 1 < grid_h) {
            if (topmostHole(ucx, ucy + 1u)) {
                rim = max(rim, 1.0 - (1.0 - in_tile.y) / rim_margin);
            }
        }

        out_color.rgb = max(out_color.rgb - rim_shadow_amount * rim, 0.0);
    }
}
