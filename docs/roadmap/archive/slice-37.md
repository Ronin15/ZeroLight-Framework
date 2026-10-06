## Slice 37: Dense Render-Window Fixed Cap And Shader/Host Sync Hardening

**Status: complete (archived).** One fixed dense-submit cap (32), a
test-enforced shader/host layer-offset binding, and a fixed GPU-byte budget the
demo actually assigns. Worlds that do not fit are refused; no cap was raised and
no window is sized from level or band count.

Goal: keep one fixed dense-submit cap, close the shader/host layer-offset
drift, and point the demo at a fixed GPU-byte budget. A world whose submit
window or byte estimate does not fit is refused.

### Contract

- `world_system.k_max_dense_submit_stack_cap = 32` bounds
  `DenseLayerRenderWindow.maxSubmitLayers()`. `Renderer.k_max_tilemap_window_layers`
  and `Renderer.k_max_dense_composite_draws` stay comptime-tied to it
  (`world_system.zig`). `validateDenseRenderBudget` returns
  `DenseLayerWindowExceeded` past the cap.
- `sprite_batch.k_max_tilemap_window_layers` owns the window-layer count and
  sizes `TilemapParams.layer_offsets`; `Renderer` re-exports it. A comptime
  assert keeps it a multiple of 4 (uvec4 packing).
- `tilemap.frag.glsl`'s `uvec4 layer_offsets[8]` is held to
  `k_max_tilemap_window_layers / 4` by the `sprite_batch.zig` test
  "tilemap.frag.glsl layer_offsets matches k_max_tilemap_window_layers", which
  embeds the shader through build.zig's `tilemap_frag_glsl` anonymous import on
  the unit-test module. The test expects exactly one single-line
  `uvec4 layer_offsets[N];` with a decimal `N`; the GLSL comment names the test.
- `world_system.k_max_dense_tile_gpu_bytes` (64 MiB) is a literal. The demo's
  `default_world_build_config.max_dense_tile_gpu_bytes` assigns it; nothing
  computes it from `estimateDenseTileGpuBytes`, level count, or cell count.
  `validateDenseRenderBudget` returns `DenseTileGpuBudgetExceeded` when the
  estimate exceeds it.

### Checklist

- [x] Keep `k_max_dense_submit_stack_cap` (`world_system.zig`),
      `Renderer.k_max_tilemap_window_layers`, and
      `Renderer.k_max_dense_composite_draws` at 32, still comptime-tied.
      `validateDenseRenderBudget` refuses a window over that cap with
      `DenseLayerWindowExceeded` (new boundary test: exactly the cap passes,
      one level past it is refused).
- [x] Move `k_max_tilemap_window_layers` and `TilemapParams.layer_offsets`'s
      array-size ownership into `sprite_batch.zig`; `Renderer` re-exports it.
      Array length stays 32 `u32` slots.
- [x] Keep `assets/shaders/tilemap.frag.glsl`'s `uvec4 layer_offsets[8]`
      matched to `k_max_tilemap_window_layers / 4`; shaders recompile under
      `zig build shaders` (comment-only shader change).
- [x] Add the embedded-shader headless test asserting the GLSL
      `layer_offsets[N]` literal matches `k_max_tilemap_window_layers / 4`;
      the test is named in both the Zig doc comment and the GLSL comment.
- [x] Add literal `k_max_dense_tile_gpu_bytes` in `world_system.zig`; the demo
      assigns it and `procedural_max_dense_tile_gpu_bytes` is deleted.
- [x] Correct the stale `Renderer.k_max_dense_composite_draws = 8` references
      in `docs/rendering-assets-shaders.md` and the archive Slice 36 section
      to the current cap (32).

### Acceptance checks

- [x] `zig build verify`: check, all 1126 tests, shader compile, runtime atlas
      validation, and idiom-lint pass with the cap at 32 and the GLSL
      `layer_offsets[8]` declaration matched to it. The source-sprite
      consistency lint (`pack_atlas.py --lint`) needs Pillow in the build's
      `python3`; this slice changes no atlas or source sprite.
- [x] The GLSL-sync test fails when the shader literal changes alone
      (spot-checked with `layer_offsets[9]`: "expected 8, found 9", then
      reverted). Changing the Zig constant alone fails the build first at
      `world_system.zig`'s comptime tie to `k_max_dense_submit_stack_cap`.
- [x] `partitionDenseCompositeBuckets`'s worst-case test passes at the cap of 32.
- [x] `validateDenseRenderBudget`'s GPU-byte-budget test still passes. The demo
      assigns `k_max_dense_tile_gpu_bytes`, whose definition does not call
      `estimateDenseTileGpuBytes` or multiply by level or cell count.
