## Slice 53A: Scalable GPU Text Labels

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Render-layer foundation for Slice 53B. No dependency
on any open slice; independent of the AI / simulation / world-render tracks.
The original text-and-UI slice is split: **53A** (text) lands first, **53B** (widgets, menus, HUD)
builds on it.

Goal: replace surface-rendered, color-keyed text textures for UI text with
SDL_ttf's GPU text engine behind a render-owned, fixed-capacity
`TextLabelSystem`. Text rasterizes at the live logical-to-drawable
presentation scale so it stays crisp at any window size and on HiDPI, color is
a per-draw tint (focus/selection changes re-render nothing), unchanged labels
draw allocation-free every frame from Zig-owned cached glyph quads (no SDL_ttf
call and no indirect call per draw), and dynamic text (counters, values) updates
without creating or destroying renderer textures. `LoadingState` is the first
consumer; debug overlays stay on the old path (Slice 67B).

### Current foundation

- `src/render/text.zig:188-210` — `TextService` owns `TTF_Init`/`TTF_Quit`,
  generational `FontId` slots, default font `fonts/NotoSansMono-Regular.ttf`
  at 18pt (`:27-28`).
- `src/render/text.zig:372-404`, `:659-705` — prepare path:
  `TTF_RenderText_Blended` → `SDL_Surface` → RGBA convert →
  `Renderer.createTextureFromPixels`. `TextCacheKey` (`:588-606`) includes the
  color, so every color change creates a new GPU texture (e.g.
  `src/game/settings_menu_state.zig:219-241` re-prepares every row when the
  selection moves). Cache lookup is a linear scan (`:462-470`) kept for app
  lifetime; `docs/rendering-assets-shaders.md:499-502` already records that
  this does not scale to high-cardinality text.
- `src/render/text.zig:311-317`, `:641-653` — `TextService.initWithBackend` +
  `TextBackend` fn-pointer table: the accepted type-erased backend boundary used
  for headless tests (`.claude/rules/zig-style.md`).
- `src/render/renderer.zig:432` `submitOrderedSprite`, `:439-453`
  `reserveSpriteCommands` (grow-only high-water), `:459`
  `submitOrderedRectInSpace`, `:562-569` `drawablePixelScale` (drawable/window
  ratio — not the logical→drawable scale), `:1501-1508` `TextureSlot`
  (`internal` flag only), `:1214-1221` `retireTextureSlot` always calls
  `SDL_ReleaseGPUTexture`.
- `src/render/sprite_batch.zig:32-43` `Rect`/`CoordinateSpace`, `:51-104`
  `UiDepth`/`UiStackOrder`/`RenderOrder.uiInStack`, `:106-115` `Sprite`. There
  is no scissor or clip support anywhere in the batch.
- `src/render/gpu/device.zig:55-67` — one nearest/clamp sampler for all draws.
- `src/app/resolution.zig:88-98` — pure `computeViewport` (per-axis scale +
  integer offset).
- Installed SDL3_ttf is 3.2.2: `TTF_CreateGPUTextEngineWithProperties`
  (`TTF_PROP_GPU_TEXT_ENGINE_ATLAS_TEXTURE_SIZE`), `TTF_GetGPUTextDrawData`
  (`TTF_GPUAtlasDrawSequence { atlas_texture, xy, uv, num_vertices, indices,
  image_type, next }`, +Y up), `TTF_SetTextEngine`, `TTF_SetFontSize(float)`,
  `TTF_SetTextWrapWidth`. Atlas pages are `B8G8R8A8_UNORM`, append-only, freed
  only by `TTF_DestroyGPUTextEngine`; `TTF_IMAGE_ALPHA` glyphs have white color
  channels, so the existing sprite shader (texture × tint) colors them.
- Debug-only text: `src/render/fps_counter.zig` and
  `src/game/ai_debug_overlay.zig` use `PreparedText` in drawable space.

### Architecture notes

- **Owner.** New `src/render/text_labels.zig` with `TextLabelSystem`, held as
  field `labels` on `TextService` so SDL_ttf stays single-owner:
  `TextService.deinit` tears labels down first (`renderer.waitForIdle`, destroy
  every `TTF_Text`, `TTF_DestroyGPUTextEngine`, unregister atlas pages), then
  closes fonts and calls `TTF_Quit`. Game code touches only `TextLabelId`,
  `UiFontRole`, `LabelDraw`, and `RenderContext.text_service.labels`. No SDL
  handle crosses into `src/game/`.
- **Init.** `TextService.initLabels(renderer: *Renderer, fonts: UiFontTable,
  initial_raster_scale: f32) !void`, called by `Engine.init` right after
  `TextService.init`. Every label API takes `renderer` explicitly and nothing
  stores `*Renderer`, because `Engine` is returned by value
  (`docs/architecture.md:263-264`). `Engine` computes `initial_raster_scale`
  from `SDL_GetWindowSizeInPixels` + the resolution policy through the pure
  `resolution.computeViewport`, so the first frames do not trigger a rebuild.
  The engine is created with `TTF_PROP_GPU_TEXT_ENGINE_DEVICE =
  renderer.device` (render-layer read) and
  `ATLAS_TEXTURE_SIZE = k_text_atlas_size = 1024`.
- **Font roles.** `pub const UiFontRole = enum(u8) { body, heading, title,
  mono }`, `pub const UiFontTable = [4]text.FontDesc` (logical point sizes),
  `pub const default_ui_font_table` = NotoSansMono-Regular at body 18 /
  heading 22 / title 32 / mono 16 (body matches today's 18pt default). The
  label system opens its own four `TTF_Font` objects, separate from the
  `PreparedText` fonts, because raster changes call `TTF_SetFontSize` on them.
  Slice 53B's theme supplies the table; until then Engine passes the default.
- **Label pool.** `k_max_text_labels: u16 = 512`;
  `TextLabelId { index: u16, generation: u32 }` with `.invalid`. The
  generation is `u32` so idle reclaim plus re-create cannot wrap it into a
  stale id that resolves to a new label within any realistic session (a `u16`
  could wrap after 65,536 reuses of one slot). Slots are allocated once at
  init (`allocator.alloc(LabelSlot, k_max_text_labels)`) and use a free list.
  This is a generational slot map, the named exception to the
  `std.MultiArrayList` default (`.claude/rules/memory-performance.md`). Each
  `LabelSlot` holds: `text: ?*anyopaque` (backend `TTF_Text`), `role`,
  `generation`, `alive`, `next_free`, `content_hash: u64` (Wyhash),
  `wrap_width_logical: u16`, `size_px: [2]u16`, `quad_count: u16`,
  `last_drawn_frame: u32`. Text length cap: `k_max_label_text_bytes = 256`.
- **Glyph quad cache.** One fixed slab, allocated at init:
  `k_max_text_labels × k_max_label_quads` `CachedGlyphQuad`s, where
  `k_max_label_quads = k_max_label_text_bytes = 256` (a glyph consumes at
  least one UTF-8 byte; HarfBuzz is off in the 52A SDL_ttf build). Slot `i`
  owns the fixed run `[i × 256, (i + 1) × 256)`, so there is no allocator,
  free list, or fragmentation.
  - `CachedGlyphQuad = extern struct { dest_px: [4]i16, src_px: [4]u16,
    page: u8, kind: GlyphImage }`: `dest_px` is the glyph's x/y/w/h in whole
    drawable pixels relative to the label origin (Y already flipped),
    `src_px` the atlas source rect, `page` an index into the page registry.
    About 20 bytes, so the slab is about 2.5 MiB, sized only by the two fixed
    caps.
  - Realize (cold) fills the run; `draw` walks only the run. A label whose
    conversion would exceed 256 quads keeps the first 256 and warns once per
    label generation (unreachable for capped text; never a silent overrun).
- **API.** `TextLabelError = error{ TextLabelCapacityExceeded,
  StaleTextLabel, InvalidText, SdlError }`.
  - `create(renderer, role, text, wrap_width: ?u16) TextLabelError!TextLabelId`
  - `setText(renderer, id, text) TextLabelError!void` — no-op when the Wyhash
    matches; otherwise `TTF_SetTextString` + eager realize.
  - `destroy(id) void` (optional explicit release), `isAlive(id) bool`,
    `logicalSize(id) ?[2]f32`, `layoutEpoch() u32`.
  - `draw(renderer, id, LabelDraw{ x, y, color, order, clip: ?Rect = null })
    !bool` — logical space, top-left origin; returns `false` and draws nothing
    for a stale id; propagates `Renderer.submitOrderedSprite`'s errors. It
    reads only the slot's cached quad run and the page registry: no
    `LabelBackend` call, no SDL_ttf call, and no sequence-list walk.
  - `beginFrame(renderer, ui_scale_percent: u16) void` — advances the frame
    counter, runs raster settle and rebuild, runs the reclaim sweep.
    `ui_scale_percent` is applied unclamped; 54's `UiScale` enum is the only
    range limit (Slice 67B's atlas probe passes values up to 1800).
- **Eager realize (cold).** `create`, `setText`, and rebuild call
  `TTF_GetGPUTextDrawData` immediately, which forces layout and glyph upload.
  They walk the sequences, register any atlas page they have not seen through
  `renderer.registerBorrowedTexture` (page lookup is a pointer compare over
  ≤ `k_max_text_atlas_pages`), convert every glyph into the slot's cached
  quad run, and cache `size_px` from `TTF_GetTextSize`. The cached quads stay
  valid until the label's next realize: atlas pages are append-only and are
  freed only with the engine, and every engine rebuild re-realizes every live
  label. `draw` therefore never registers, converts, or allocates.
- **Backend seam (cold paths only).** `LabelBackend` fn-pointer table
  (production = SDL_ttf; tests = a local fake), following the `TextBackend`
  precedent. It is called only from `create`, `setText`, `destroy`, realize,
  and rebuild, which are the cold setup/service paths that
  `.claude/rules/zig-style.md` accepts for fn-pointer tables; it is never
  called per frame. The production adapter copies the
  `TTF_GPUAtlasDrawSequence` linked list into a stack array
  `[k_max_sequences_per_label = 16]GlyphSequenceView { atlas: *anyopaque,
  xy: []const [2]f32, uv: []const [2]f32, image: GlyphImage }` for the
  converter. No allocation is involved. `TextLabelSystem.initWithBackend`
  mirrors `TextService.initWithBackend`.
- **Glyph conversion (realize time).** Pure `glyphQuad`/`convertGlyphQuads`
  write `CachedGlyphQuad`s:
  - Require `num_vertices % 4 == 0`; otherwise skip the sequence and bump a
    Debug counter.
  - **Orientation (pinned).** SDL_ttf 3.2.2 negates only the vertex Y
    (`src/SDL_gpu_textengine.c:693-704` emits `-miny`/`-maxy` from integer
    glyph dst rects). Its uv are top-down atlas coordinates (`:276-286`:
    `minv = glyph->rect.y / atlas_size` on the top vertices), which is
    SDL_GPU's texture convention and the sprite batch's source-rect
    convention. So `dest_px` = min/max `xy` with Y negated back, and
    `src_px` = min/max `uv × k_text_atlas_size` used as is, with no uv flip.
    A fake-backend test with a known uv rect and the gpu-smoke label (upright,
    not mirrored) pin this.
  - SDL_ttf's glyph positions are whole raster pixels, so `dest_px` is stored
    as integers with no rounding error.
  - Tint kind: `TTF_IMAGE_ALPHA` → draw color; `TTF_IMAGE_COLOR` → white with
    `color.a`; `TTF_IMAGE_SDF` is never produced because SDF is not enabled.
    It is skipped.
- **Draw-time emission.** With `s` = the committed raster scale (below) and
  the viewport's integer offset, `draw` snaps only the label origin to the
  drawable grid, `origin_px = round(x * s)`, and emits each cached quad as one
  `.logical` sprite with `dest = (origin_px + dest_px) / s`. Because `s` is
  exactly the presentation's logical→drawable scale, every glyph edge lands
  on a whole drawable pixel and glyph texels map 1:1 under the existing
  nearest sampler. No sampler or pipeline change is needed. Rejected
  alternative: a linear text sampler, which would add sampler state to
  `DrawGroup` and a batch key.
- **Raster scale.** The presentation scale is
  `p = clamp(min(viewport.scale_x, viewport.scale_y), 0.25, 8.0)`, read
  through a new facade `Renderer.logicalPresentationScale()` (last
  presentation; 1.0 before the first one).
  - **Exact commit.** The committed raster scale `s` is the exact `p` of the
    committed presentation. `TTF_SetFontSize` (role pt × ui_scale × `s`) and
    the draw-time origin snap both use that exact `s`, never a rounded value.
    This is what keeps nearest sampling 1:1: a glyph rasterized at a rounded
    scale but displayed at the true scale would be resampled by
    `s_true / s_round`, dropping or duplicating texel columns.
  - **Settle, using rounding only for stability.** A rebuild is pending
    whenever the current exact `p` differs from the committed `s`. It commits
    after `k_text_raster_settle_frames = 12` consecutive frames whose
    1/64-rounded `p` is unchanged, using the exact `p` of the latest frame.
    The 1/64 rounding exists only for that stability comparison, so a live
    drag-resize does not thrash. A `ui_scale` change (user action) commits on
    the next frame.
  - Outside the clamp range text is scaled and documented as not
    pixel-exact.
  - **Rebuild steps:** `waitForIdle` → `TTF_SetFontSize` per role → create a
    new engine → `TTF_SetTextEngine` for every live label → re-apply wrap
    widths in px → destroy the old engine → unregister old pages → eager
    realize all labels → `layout_epoch += 1`.
  - Atlas memory stays bounded to the current glyph set: old-size glyphs die
    with the old engine.
  - In `stretch` scale mode the scale is non-uniform; the min axis is used and
    text is documented as not pixel-exact.
- **Atlas page cap.** `k_max_text_atlas_pages = 8` (worst case 8 × 1024² × 4 B
  = 32 MiB).
  - If realize meets a 9th page: warn once, schedule a rebuild for the next
    frame (drops orphaned glyph slots).
  - If the live glyph set still needs more than 8 pages after that rebuild,
    glyphs on unregistered pages are not drawn, with one warn per epoch.
  - Never raise the cap to fit one font or locale.
- **Service-free teardown via idle reclaim.** `docs/architecture.md:270-276`
  forbids passing text services into state `deinit`, so labels behave as a
  generational cache:
  - `draw` stamps `last_drawn_frame`.
  - `beginFrame` sweeps `k_label_reclaim_sweep_per_frame = 32` slots
    round-robin and destroys labels not drawn for
    `k_label_idle_reclaim_frames = 600` frames.
  - Owners check `isAlive` when they prepare (O(1)) and recreate from their
    retained text intent.
  - When `create` finds the pool full, it does one cold pass over 512 slots and
    reclaims the label with the oldest `last_drawn_frame` that was not drawn
    this frame. If there is none, it returns `TextLabelCapacityExceeded`; the
    widget draws no text and the system warns once.
- **Borrowed textures** (`renderer.zig`):
  - `TextureSlot` gains `borrowed: bool`.
  - New `registerBorrowedTexture(gpu: *c.SDL_GPUTexture, desc) !TextureId`
    and `unregisterBorrowedTexture(id)`. Unregister retires the slot without
    releasing the texture.
  - `retireTextureSlot` and `deinit` skip `SDL_ReleaseGPUTexture` for borrowed
    slots, because SDL_ttf owns those textures.
  - `resources.TextureFormat` gains `.bgra8_unorm`.
  - This is documented as a render-internal API for `text_labels.zig` only.
- **Clipping.** Pure `clipSprite(sprite: Sprite, clip: Rect) ?Sprite` in
  `sprite_batch.zig`:
  - Axis-aligned only; `rotation == 0` is asserted.
  - The source rect is scaled proportionally; a null source means only `dest`
    is clipped. Fully clipped sprites return null.
  - Facades `Renderer.submitOrderedSpriteClipped(sprite, clip)` and
    `submitOrderedRectClipped(rect, color, order, space, clip)` wrap it.
  - Clipping happens on the CPU, so `DrawGroup`, the pipelines, and batch
    grouping are unchanged. Rejected: a per-group scissor, which would add a
    new group key and render-pass state.
- **Allocation policy.**
  - `draw` and a non-rebuilding `beginFrame` perform zero Zig allocations and
    make no SDL_ttf or backend calls; `draw` reads Zig-owned cached quads
    only.
  - `create`, `setText`, and rebuild are cold. SDL_ttf allocates inside its
    own heap for layout, and for each newly seen glyph it creates a transfer
    buffer and submits a command buffer.
  - Owner: `TextLabelSystem`, bounded by the number of labels whose content
    changed. Callers must not call `setText` unconditionally every frame; the
    Wyhash check makes repeated calls no-ops anyway.
  - Glyph quads count against the caller's sprite reservation (Slice 53B
    computes the bounds). The quad slab is fixed at init and never grows.
- **Threading.** Main thread only: SDL_ttf requires calls on the thread that
  created the text. Conversion runs serially at realize time and draw-time
  emission is a linear walk (a few thousand quads at most); `SpriteBatch`
  already threads vertex expansion.
- **Scope.** `LoadingState` (`src/game/loading_state.zig:128-155, :216-220`)
  migrates to direct labels in this slice. `fps_counter.zig` and
  `ai_debug_overlay.zig` stay on `PreparedText` in this slice; debug overlays
  move in Slice 67B.
- **Diagnostics** (`render` scope):
  - `info` on engine create (atlas size, initial scale).
  - `debug` on rebuild (old→new scale, live labels, pages).
  - `warn` once on page-cap or pool exhaustion.
  - Comptime-gated `runtime_perf_log` counters `text_label_draws` and
    `text_glyph_quads` (Debug/ReleaseSafe only).

### Checklist

- [ ] `renderer.zig`: add borrowed slots (register/unregister; skip release in
      retire and deinit), `.bgra8_unorm`, `logicalPresentationScale()`, and the
      clipped submit facades. Tests on a CPU-only renderer (the
      `renderer.zig:2280` fixture pattern):
      - borrowed retire never dereferences `device`
      - the scale accessor returns 1.0 by default and the right value after a
        presentation
- [ ] `sprite_batch.zig` `clipSprite`, with tests: fully inside, fully
      outside, partial on each edge, proportional source scaling, null source.
- [ ] `text_labels.zig`: pool (`u32` generation), fixed glyph-quad slab,
      `create`/`setText`/`destroy`/`isAlive`/`logicalSize`/`draw`/`beginFrame`/
      `layoutEpoch`, `LabelBackend` + `initWithBackend` (cold paths only),
      page registry + cap, idle and exhaustion reclaim, raster settle +
      rebuild. Tests use a fake backend:
      - capacity error
      - generation bump makes an old id stale
      - stale draw returns false
      - Wyhash no-op `setText`
      - idle reclaim only after 600 undrawn frames
      - exhaustion reclaims the oldest undrawn label
      - page cap schedules a rebuild
      - `draw` makes zero backend calls (the fake counts calls; warmed draws
        leave the count unchanged)
      - realize refreshes the cached run after `setText` and after a rebuild
- [ ] Pure glyph-conversion and emission tests:
      - Y-flip of `xy` only
      - known uv rect → `src_px` with no flip (e.g. uv (0.25, 0.5)–(0.5, 0.75)
        → px (256, 512, 256, 256) at a 1024 atlas)
      - origin snapping at `s` = 1.0 / 1.5 / 2.0
      - at `s = 1.503` (not a multiple of 1/64), the emitted quad's width in
        drawable px equals the glyph's px width and both edges are whole
        drawable pixels
      - ALPHA vs COLOR tint
      - `num_vertices % 4 != 0` skipped
      - more than 256 quads truncates with the warn path
- [ ] Raster settle tests:
      - commit on the 12th stable frame, with the exact (unrounded) `p`
      - jitter in the 1/64-rounded value resets the count
      - a sub-1/64 change of `p` after a commit still commits (exactly) after
        12 stable frames
      - clamps at 0.25 / 8.0
      - a `ui_scale` change commits the next frame
- [ ] `FailingAllocator` proofs:
      - (a) warmed `draw` of 32 labels into a reserved CPU-only renderer
      - (b) `create`/`setText`/`destroy` cycles after init allocate zero Zig
        bytes
      - (c) `beginFrame` reclaim sweep
- [ ] `TextService`: `labels` field, `initLabels`, `beginFrame` pass-through,
      deinit ordering. `Engine`: call `initLabels` after `TextService.init`
      with `default_ui_font_table` + initial scale; call
      `text_service.beginFrame(&renderer, 100)` in `renderFrame` before
      `states.render`. Slice 54 wires the real `ui_scale`.
- [ ] Migrate `LoadingState` to labels (title role + body role, `isAlive`
      re-create). Its render tests (`loading_state.zig:505-571`) use a
      `TextService` whose labels run on a local fake backend.
- [ ] `src/platform/gpu_smoke_impl.zig`: create a `TextLabelSystem` on the
      real device, create a label, and draw it (plus one clipped label) into a
      submitted frame.
- [ ] Bench group `ui-glyph-emit` (one group per workload, `suite.zig`
      convention; serial `serial-direct` case only): 2,048 warmed cached glyph
      quads across labels → sprite commands through `draw`, which is the
      per-frame path.
- [ ] Docs:
      - `docs/rendering-assets-shaders.md` Text Rendering: labels vs
        `PreparedText`, raster scale, settle, reclaim, page cap, clipping
      - `docs/architecture.md`: source layout and the generated-text ownership
        paragraph
      - `src/tests.zig` registers `render/text_labels.zig`

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `zig build gpu-smoke` submits a frame containing a GPU-engine label and a
      clipped label; a manual look at the smoke frame shows the label upright
      and not mirrored (pins the uv orientation).
- [ ] `zig build bench -- --group ui-glyph-emit` runs; the baseline is
      recorded in Status.
- [ ] Manual check: loading-screen text is crisp at 1280×720, in a ~1.5× fit
      window, and on a HiDPI display. Drag-resizing does not stutter (one
      rebuild after the size settles), and text is crisp again after the
      settle.
- [ ] Review check: nothing in `src/game/` imports SDL_ttf types or
      `render/gpu/*`; label draws allocate nothing once warm and make no
      backend or SDL_ttf call.

### VoidLight reference

- **Port:**
  - `src/managers/FontManager.cpp:405-430` — create the GPU text engine on the
    GPU device (`TTF_SetGPUTextEngineWinding` is irrelevant here because ZL
    converts glyphs to quads).
  - `:446-520` — one `TTF_Text` per label, `TTF_SetTextString` only when the
    string changes, `TTF_GetTextSize`, text origin at (0,0) with the caller
    translating.
  - `:529-538` — `TTF_GetGPUTextDrawData`.
  - `src/managers/UIManager.cpp:2875-2880` — round text origins to whole
    pixels.
  - `:2885-2920` — COLOR glyphs get a white tint and keep alpha.
- **Do not port:**
  - the string-keyed `m_gpuTextEntries` map (use generational `TextLabelId`)
  - the `FontManager::Instance()`/`GPUDevice::Instance()` singletons
  - separate Alpha/Color/SDF UI text pipelines (ZL reuses the sprite pipeline;
    SDF is not enabled)
  - index-buffer triangle emission (ZL feeds quads into the ordered sprite
    batch)
  - VL's per-resize font reload without a settle window

