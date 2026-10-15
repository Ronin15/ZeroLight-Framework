## Slice 53A: Scalable GPU Text Labels

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Render-layer foundation for Slice 53B.

Goal: UI text moves from surface-rendered, color-keyed textures to SDL_ttf's
GPU text engine behind a render-owned label pool. Text is crisp at any window
size and on HiDPI, color is a per-draw tint (focus changes re-render
nothing), unchanged labels draw every frame with no allocation and no
SDL_ttf call, and dynamic text updates without creating or destroying
renderer textures. `LoadingState` is the first consumer; debug overlays move
in Slice 67B.

### Current foundation

- `src/render/text.zig` `TextService` owns `TTF_Init`/`TTF_Quit` and
  generational `FontId`s (default `fonts/NotoSansMono-Regular.ttf`, 18 pt).
  `PreparedText` renders through `TTF_RenderText_Blended` → surface → RGBA →
  `Renderer.createTextureFromPixels`. `TextCacheKey` includes the color, so
  every color change makes a new GPU texture (the settings menu re-prepares
  every row when selection moves); the cache is a linear scan kept for app
  lifetime. `docs/rendering-assets-shaders.md` already records that this
  does not scale to high-cardinality text.
- `TextService.initWithBackend` + `TextBackend` is the accepted cold-path
  fn-pointer seam for headless tests (`.claude/rules/zig-style.md`).
- `src/render/renderer.zig`: `submitOrderedSprite`, grow-only
  `reserveSpriteCommands`, `drawablePixelScale` (drawable/window ratio, not
  the logical→drawable scale); every texture slot is released through
  `SDL_ReleaseGPUTexture` (no borrowed slots). `sprite_batch.zig` has no
  per-sprite clip; `gpu/device.zig` has one nearest/clamp sampler.
- `src/app/resolution.zig` `computeViewport` is pure (per-axis scale plus
  integer offset).
- Pinned SDL3_ttf 3.2.2 provides the GPU text engine and draw data: atlas
  pages are `B8G8R8A8_UNORM`, append-only, freed only with the engine; alpha
  glyphs have white color channels, so the sprite shader's texture × tint
  colors them; vertex Y is negated, UVs are top-down.
- `PreparedText` consumers: the four menus/screens in `src/game/`, plus
  debug-only `fps_counter.zig` and `ai_debug_overlay.zig`.

### Architecture notes

- Label storage, SDL_ttf, and atlas textures stay render-owned; game code
  holds only label ids, font roles, and draw requests, and never sees an SDL
  handle (`.claude/rules/render.md`, `.claude/rules/engine-design.md`).
- No service keeps a pointer to a sibling (Engine is returned by value);
  label calls take the renderer explicitly (`.claude/rules/engine-design.md`).
- The label pool and glyph cache are presentation-only fixed pools with
  deterministic overflow handling (`.claude/rules/budgets-capacities.md`);
  no simulation reads them. A stale id draws nothing and never resolves to
  another label.
- State teardown receives no text service, so labels nobody draws are
  reclaimed by the label system; owners re-create from retained intent
  (`.claude/rules/render.md` § Text).
- Warmed draws allocate nothing and make no SDL_ttf or backend call;
  create/set-text/rebuild are cold and bounded by content changes
  (`.claude/rules/memory-performance.md`).
- Text rasterizes at the exact committed presentation scale so glyph texels
  map 1:1 under the existing nearest sampler; a live resize settles before
  rebuilding. Atlas memory stays bounded to the current glyph set; the page
  cap is never raised to fit one font or locale.
- Main thread only (SDL_ttf thread affinity); `SpriteBatch` already threads
  vertex expansion.
- Provides: labels, font roles, a layout epoch, and CPU clipping that 53B
  builds on; 67B's drawable-space and telemetry extensions.
- VoidLight reference: `FontManager.cpp:405-538` (GPU engine, one text per
  label, set-string-on-change); not its string-keyed map, singletons, or
  per-kind text pipelines.

### Checklist

- [ ] Borrowed (non-owned) texture slots, a BGRA format, a logical
      presentation-scale accessor, and clipped submit facades in the
      renderer; CPU-only renderer tests.
- [ ] CPU sprite clipping with edge, proportional-source, and null-source
      tests.
- [ ] `TextLabelSystem`: generational pool, cached glyph quads, page
      registry with cap, idle and exhaustion reclaim, raster settle and
      rebuild, fake-backend seam; tests for capacity, staleness, no-op
      set-text, reclaim timing, page-cap rebuild, and zero backend calls on
      warmed draws.
- [ ] Pure glyph conversion and emission tests: orientation, whole-pixel
      edges at a non-round scale, alpha vs color tint, malformed sequences,
      over-long text.
- [ ] Raster settle tests: commit after the stable window at the exact
      scale, jitter resets, clamps, UI-scale change commits next frame.
- [ ] `FailingAllocator` proofs: warmed draws, create/set/destroy cycles,
      reclaim sweep.
- [ ] `TextService` owns labels (init after fonts, torn down first);
      `Engine` initializes them and calls the per-frame begin before state
      render (Slice 54 wires the real UI scale).
- [ ] `LoadingState` migrated to labels; its render tests use the fake
      backend.
- [ ] `gpu-smoke` draws a real label and a clipped label.
- [ ] Bench group `ui-glyph-emit` (warmed cached glyphs → sprite commands)
      at three label counts far enough apart to show the linear shape.
- [ ] Docs: `docs/rendering-assets-shaders.md` Text Rendering;
      `docs/architecture.md` source layout and text ownership;
      `src/tests.zig` registration.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `zig build gpu-smoke` submits a frame with a label and a clipped
      label; the label is upright, not mirrored.
- [ ] `zig build bench -- --group ui-glyph-emit` shows cost linear in glyph
      count.
- [ ] Manual: loading text is crisp at the default window, a fractional fit
      window, and HiDPI; drag-resize rebuilds once after settling.
- [ ] Review: nothing in `src/game/` imports SDL_ttf or `render/gpu/*`;
      warmed label draws allocate nothing and call no backend.
