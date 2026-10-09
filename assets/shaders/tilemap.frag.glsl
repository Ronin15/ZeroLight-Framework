/* Copyright (c) 2026 Hammer Forged Games
 * All rights reserved.
 * Licensed under the MIT License - see LICENSE file for details
*/

#version 450

layout(location = 0) in vec2 in_world_pos;

layout(location = 0) out vec4 out_color;

// Fragment resource set: sampler at binding 0, the world's tile store at binding 1
// (renderer.zig tile store layout). The store is one directory per window layer
// slot, one word per chunk, then a block region. A directory word with bit 31 set
// is a uniform chunk whose tile is its low 16 bits; any other word indexes the
// chunk's block, which holds its tiles in local row-major order, two 16-bit ids per
// word, low half first.
layout(set = 2, binding = 0) uniform sampler2D atlas_texture;
layout(set = 2, binding = 1) readonly buffer TileData {
    uint words[];
} tiles;

layout(set = 3, binding = 0) uniform TilemapUniform {
    // grid:  x=tile_size, y=grid_width, z=grid_height, w=invalid_tile_id
    vec4 grid;
    // atlas: x=columns, y=atlas_width_px, z=atlas_height_px, w=atlas_tile_px
    vec4 atlas;
    // layer_meta: x=this draw's composited layer count (topmost-first),
    // y=shallowest-bucket flag, z=chunk shift (log2 of the chunk edge),
    // w=chunks per row
    ivec4 layer_meta;
    // layer_offsets: directory start words in the tile store (slot * chunks per
    // level), one per composited layer (layer_meta.x of them valid), topmost layer
    // first. Packed 4-per-uvec4 so this matches the flat Zig
    // [k_max_tilemap_window_layers]u32 (sprite_batch.zig) byte-for-byte under
    // std140 (uvec4 array elements have no interior padding). Its length is also
    // the store's directory slot count. The array size must equal
    // k_max_tilemap_window_layers / 4; the Zig test
    // "tilemap.frag.glsl layer_offsets matches k_max_tilemap_window_layers"
    // parses this declaration, so keep it a single-line decimal literal.
    uvec4 layer_offsets[8];
} tm;

const uint uniform_bit = 0x80000000u;

struct StoreLayout {
    uint shift;
    uint chunks_x;
    uint block_base;
    uint block_words;
};

uint tileAt(StoreLayout store, uint directory_start, uint cx, uint cy) {
    uint edge_mask = (1u << store.shift) - 1u;
    uint chunk = (cy >> store.shift) * store.chunks_x + (cx >> store.shift);
    uint word = tiles.words[directory_start + chunk];
    if ((word & uniform_bit) != 0u) {
        return word & 0xFFFFu;
    }
    uint local_cell = ((cy & edge_mask) << store.shift) | (cx & edge_mask);
    uint element = tiles.words[store.block_base + word * store.block_words + (local_cell >> 1u)];
    return (element >> ((local_cell & 1u) * 16u)) & 0xFFFFu;
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

    StoreLayout store_layout;
    store_layout.shift = uint(tm.layer_meta.z);
    store_layout.chunks_x = uint(tm.layer_meta.w);
    uint chunks_y = (uint(grid_h) + (1u << store_layout.shift) - 1u) >> store_layout.shift;
    uint directory_slots = uint(tm.layer_offsets.length()) * 4u;
    store_layout.block_base = directory_slots * store_layout.chunks_x * chunks_y;
    store_layout.block_words = max(1u, (1u << (2u * store_layout.shift)) >> 1u);
    uint ucx = uint(cx);
    uint ucy = uint(cy);

    int layer_count = tm.layer_meta.x;
    uint tile_id = invalid_id;
    int resolved_depth = 0;
    // Dynamically-uniform loop: every fragment in this draw shares layer_count,
    // so this is an ordinary bounded loop, no toolchain risk. Stops at the first
    // opaque hit walking topmost-first, so a hole in a shallower layer falls
    // through to whichever composited layer beneath it is actually opaque.
    for (int i = 0; i < layer_count; i++) {
        uint directory_start = tm.layer_offsets[i / 4][i % 4];
        uint candidate = tileAt(store_layout, directory_start, ucx, ucy);
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
        uint top_directory = tm.layer_offsets[0][0];
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
            if (tileAt(store_layout, top_directory, ucx - 1u, ucy) == invalid_id) {
                rim = max(rim, 1.0 - in_tile.x / rim_margin);
            }
        }
        if (in_tile.x > 1.0 - rim_margin && cx + 1 < grid_w) {
            if (tileAt(store_layout, top_directory, ucx + 1u, ucy) == invalid_id) {
                rim = max(rim, 1.0 - (1.0 - in_tile.x) / rim_margin);
            }
        }
        if (in_tile.y < rim_margin && cy > 0) {
            if (tileAt(store_layout, top_directory, ucx, ucy - 1u) == invalid_id) {
                rim = max(rim, 1.0 - in_tile.y / rim_margin);
            }
        }
        if (in_tile.y > 1.0 - rim_margin && cy + 1 < grid_h) {
            if (tileAt(store_layout, top_directory, ucx, ucy + 1u) == invalid_id) {
                rim = max(rim, 1.0 - (1.0 - in_tile.y) / rim_margin);
            }
        }

        out_color.rgb = max(out_color.rgb - rim_shadow_amount * rim, 0.0);
    }
}
