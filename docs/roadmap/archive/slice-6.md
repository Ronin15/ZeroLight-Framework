## Slice 6: Renderer Composition

Goal: split renderer responsibilities so sprites, UI, shapes, tilemaps, and
future effects do not all require editing one monolithic renderer path.

Implemented foundation:

- `Renderer` owns frame coordination, public draw APIs, texture IDs, swapchain
  acquisition, render-pass encoding, and command submission.
- Explicit render-prep phases own transient ordering across world, UI, effect,
  and debug producers.
- `SpriteBatch` owns strict ordered-stream validation, vertex expansion, and
  draw-group construction.
- `src/render/gpu/` owns SDL_GPU device/window setup helpers, pipeline creation,
  upload buffers, and texture upload helpers.
- Build now has a shader-program table for the existing sprite shader pair.

Architecture notes:

- Prefer landing Slice 3 resource IDs before physically splitting
  `renderer.zig`, so texture ownership does not migrate across several files at
  the same time as the handle model changes.
- The first split uses `src/render/gpu/` for SDL_GPU device/window setup,
  shader/pipeline creation, buffers, and texture upload, with ordered-stream
  validation and vertex expansion in `sprite_batch.zig`.
- Keep `Renderer` as the game-facing facade and frame coordinator; the split
  should hide GPU details behind narrower render-owned modules, not expose more
  SDL_GPU surface area to game states.

Checklist:

- [x] Keep `Renderer` as the device/frame coordinator.
- [x] Move sprite batching internals behind a `SpriteBatch` or equivalent module.
- [x] If `renderer.zig` remains too broad after resource IDs land, split GPU
      setup, pipeline, buffer, and texture helpers under `src/render/gpu/`.
- [x] Introduce static material/pipeline records for the current sprite pipeline.
- [x] Keep draw record ordering stable by `RenderOrder` and submission order.
- [x] Preserve explicit `Renderer.submitOrdered*` calls for already ordered
      renderer-owned paths and route unordered producers through explicit
      render-prep ordering.
- [x] Add tests for batch grouping, invalid texture skipping, and ordering.
- [x] Re-run `gpu-smoke` when display access is available.

Acceptance checks:

- [x] Existing demo output is unchanged.
- [x] New batcher owns sprite-specific vertex construction.
- [x] Renderer frame lifecycle still handles `.submitted` and
      `.skipped_no_swapchain` correctly.
- [x] Adding a second batcher later would not require rewriting device setup.

