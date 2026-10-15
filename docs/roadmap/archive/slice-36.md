## Slice 36: Single-Pass Dense-Layer Depth Compositing

Status: All 4 steps landed. One combined GPU tile-data buffer replaces the
former per-layer buffer array (`WorldSystem.dense_tile_data_buffer`), and
`submitStaticDenseGeometry` now partitions the in-window dense layer set into a
small, bounded number of composite draws cut at this frame's interleave depths
(`partitionDenseCompositeBuckets`/`buildWindowLayers`; a topmost-first
`Renderer.TilemapWindowLayers` per draw), instead of one draw per submitted
layer. `tilemap.frag.glsl` composites the window per-pixel, stopping at the
first opaque cell. `render_prep.staticGeometryCapacity` now reserves static
geometry from `WorldSystem.maxDenseSubmitDrawCount()` (flat, composite-draw-count
bound) instead of the old per-layer bound, and the `render-game-prep` bench
fixture/assertions were rewritten to match (`merged_tilemap_group_count` stays
flat at 1 across the surface/deep cases; the earlier 8/16/32 tilemap-group-count
axis was collapsed since it never varied the fixture's built content post-step-3).
`game_demo_state.zig`'s procedural render window default is re-widened to the full authored 31-level
underground stack (`procedural_render_window_levels_below = procedural_underground_count`),
the payoff this slice unlocks.

Goal: replace the Slice 23B per-layer full-screen tilemap draw (one draw call +
one full-viewport fragment-shader pass per **submitted** dense layer) with a
single fullscreen pass whose fragment shader walks the level stack itself, so
GPU cost scales with screen pixels once per frame, not screen pixels ×
submitted-layer count.

Problem (current envelope):

- Each in-window dense layer draws as one world-space quad clipped to the
  viewport (GPU-Driven Tilemap, `docs/rendering-assets-shaders.md`). The
  fragment shader (`assets/shaders/tilemap.frag.glsl`) reads a storage buffer,
  and `discard`s on out-of-bounds or an empty (`invalid_tile_id`) cell so the
  layer below shows through.
- `discard` disables early-fragment-test culling, so every covered pixel of
  every submitted layer runs the full shader even when it immediately
  discards. With a render window of N layers, steady-state cost is
  `N × viewport_pixels` fragment invocations per frame regardless of how many
  layers are actually opaque at any given pixel — fill-rate cost with no
  matching visual payoff, since a pixel's visible tile comes from at most one
  layer.
- This slice's mitigation, landing alongside it: `game_demo_state.zig`'s
  procedural render window default was cut from `levels_below = 31` (submits
  all 32 authored levels, the `k_max_dense_submit_stack_cap` ceiling, every
  frame) to `levels_below = 6` (Slice 23B's recommended 4-8 range). That is a
  submit-count mitigation, not a fill-rate fix — it still pays
  `7 × viewport_pixels` per frame and still discards through most of that.
- Digging can open a stacked shaft visible through more than one hole at a
  time, so the window can't just be a fixed 1-2 layers without a correctness
  regression (a deep shaft would go dark past the window edge).

Current foundation (landed, do not rebuild):

- `DenseLayerRenderWindow` / `collectDenseSubmitLayers` /
  `submitStaticDenseGeometry` (Slice 23B) already collect and order the
  in-window layer set correctly; this slice changes how that set reaches the
  GPU, not which layers are in it.
- Per-layer GPU tile-data storage buffers were replaced, not left unaffected:
  `uploadDenseLayerBuffers` is now `uploadDenseTileDataBuffer`, building one
  combined `WorldSystem.dense_tile_data_buffer` from the whole flat
  `dense_tile_ids` array instead of one buffer object per dense layer.
  Compositing reads that single buffer at each layer's `denseLayerOffset`.
- `tilemap.frag.glsl` already has the per-pixel cell lookup and atlas sample;
  this slice's shader work extends that lookup to iterate levels instead of
  running once per bound layer.

Architecture notes:

- **Landed:** one combined GPU storage buffer (`WorldSystem.dense_tile_ids`
  concatenated whole, `denseLayerOffset(layer_index) = layer_index *
  cellCount()`), not per-level bindings — sidesteps SDL_GPU per-stage
  storage-binding limits and the Metal storage-slot-shift quirk entirely, since
  every tilemap draw binds exactly one storage buffer regardless of window
  depth.
- **Landed:** the fragment shader loops a per-draw, topmost-first window of
  element offsets into that buffer (`TilemapUniform.layer_meta`/`layer_offsets`,
  a `uvec4[8]` matching a flat `[32]u32` byte-for-byte under std140), stopping
  at the first non-`invalid_tile_id` cell — most pixels resolve in 1-2
  iterations (the visible floor), not N.
- **Landed:** `submitStaticDenseGeometry` computes the composite-draw window
  split on the CPU (`partitionDenseCompositeBuckets`) rather than pushing a
  full per-level index array to the GPU every frame: it cuts the in-window
  layer list at every depth something else needs to render sandwiched between
  two dense layers this frame (`render_prep.collectDenseInterleaveDepths` —
  the active level's own actor depth, this frame's distinct dynamic depths,
  and every registered sparse-tile depth at any in-window level, not only the
  active one). In the shipped default config this always resolves to exactly 1
  draw; `Renderer.k_max_dense_composite_draws = 32` is the defensive cap.
- This is a render-cost change only — no dig/nav/simulation contract changes,
  and `WorldSystem`'s CPU-side tile data remains the source of truth.
- `DrawGroup.material = .tilemap` is one draw per composite-draw bucket per
  frame (data-dependent, capped at 32), not one per submitted dense layer.

Checklist:

- [x] Decided combined-buffer layout (not multi-binding) against the SDL_GPU
      per-stage storage-buffer binding limit and the Metal storage-slot-shift
      quirk; documented beside `tilemap.frag.glsl` and in
      `docs/rendering-assets-shaders.md`'s GPU-Driven Tilemap section.
- [x] Extended the tilemap fragment shader to loop a per-draw window of levels
      per-pixel (topmost first) and stop at the first opaque cell, replacing
      the one-`discard`-per-layer-per-draw model.
- [x] Updated `Renderer`/`WorldSystem` GPU-side wiring to submit the
      composited window as a small bounded number of draw calls (data-dependent
      per frame, capped at `Renderer.k_max_dense_composite_draws`) instead of
      one per submitted dense layer; `collectDenseSubmitLayers`'s CPU-side
      layer collection contract is unchanged.
- [x] Re-widen `game_demo_state.zig`'s procedural render window back toward
      the full vertical stack now that steady-state draw count no longer
      scales with submitted-layer count (Step 4).
- [x] Shrink `render_prep.staticGeometryCapacity`'s reservation from
      `maxDenseSubmitLayerCount()` to `WorldSystem.maxDenseSubmitDrawCount()`,
      and rewrite the `render-game-prep` bench fixture/assertions so the
      tilemap portion of `merged_group_count` is asserted flat across the
      surface/deep cases (Step 3; the earlier 8/16/32 tilemap-group-count axis
      was collapsed since it never varied the fixture's built content) — no GPU
      timestamp-query infrastructure exists in this repo, so this bench proves
      draw/bind count stops scaling with window depth; it cannot produce a
      fill-rate number.

Acceptance checks:

- [x] Visual/behavioral parity with the current per-layer draw, proven by
      `partitionDenseCompositeBuckets`/`buildWindowLayers`/`applyWindowLayers`
      unit tests (single-bucket common case, ceiling-style split, a synthetic
      split at a deeper non-active level, the composite-draw-cap overflow
      case) plus a `render_prep.zig` end-to-end test proving a sparse tile at a
      deeper in-window level produces a second composite draw group in the
      merged list, and `zig build gpu-smoke` (multi-layer composite window
      renders without an SDL_GPU validation error).
- [x] Digging a multi-level shaft still reveals the correct plane through
      every stacked hole: closed generally via interleave-depth partitioning,
      not an `active_level`-only special case — the synthetic non-active-level
      unit test above is the proof this generalizes to sparse content at any
      in-window level, present or future.
- [x] Measured draw/bind count stays flat as submitted-layer count grows from 1
      to the `k_max_dense_submit_stack_cap` ceiling, at a fixed viewport size:
      `zig build bench -- --group render-game-prep` asserts
      `merged_tilemap_group_count == 1` across the surface/deep cases.
      This proves draw/bind **count** no longer scales with window depth, the
      CPU-measurable proxy this repo can produce — there is no GPU
      timestamp-query infrastructure here to measure actual fragment-shader
      fill-rate cost directly, so that number itself is not measured, only
      `zig build gpu-smoke`'s qualitative visual check that compositing still
      renders correctly.
- [x] `zig build verify` passes.

