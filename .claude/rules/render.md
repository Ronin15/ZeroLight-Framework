---
paths:
  - "src/render/**"
  - "src/platform/**"
  - "src/game/render_prep.zig"
  - "src/game/render_depth.zig"
  - "assets/shaders/**"
  - "build.zig"
---

# Rendering And Shaders

How the renderer works: `docs/rendering-assets-shaders.md`.

## Boundaries

- Game-facing draws reference `Material` tags only; no SDL_GPU handles,
  pipeline pointers, or shader-format strings cross into game code.
- Material descriptors list resource counts only and build shader paths with
  `shader_paths` helpers, never literal strings. Adding a material or shader
  follows the checklist in the rendering doc.
- World render state (visibility window, draw records, GPU tile residency and
  mirror) lives in `WorldSystem`'s render path (`docs/architecture.md`); other
  presentation and debug-UI state stays in the renderer and debug-overlay
  path. None of it is in `DataSystem` or read by simulation. States gate
  debug draws on `RenderContext.debug_overlay_visible` and own no toggle.
- Workers never read live renderer resource slots: snapshot texture metadata
  before dispatch and build draw groups on the main thread.

## Ordering and visibility

- Submit through `submitOrdered*` only from render-prep phases that walk
  nondecreasing `RenderOrder` (world z, then UI, then debug). A producer that
  can interleave depths owns an explicit ordering phase; `SpriteBatch` is a
  strict ordered-stream consumer, never a sorter.
- Dense multi-level compositing is back-to-front at submit and in
  `mergeDrawList`; a sparse tile at any in-window depth gets its own interleave
  point. Draw count scales with interleave points, never window depth or world
  size.
- Render visibility is camera chunk window plus AABB only; never gate drawing
  on `SimulationTier`.
- Apply the camera in the vertex shader for `.world`; a pan alone never
  re-uploads.

## Frame and uploads

- Keep CPU sprite prep before swapchain acquisition where practical; the
  acquired interval does only presentation uniforms, upload, encode, and
  submit. Never hold the swapchain texture across CPU prep.
- A buffer fully re-staged every frame and reused cycles; a retained, partially
  written buffer never does (the tile-data buffer upload is `cycle=false`).
- The CPU tile field is the source of truth; GPU tile edits coalesce to one per
  element and flush in one batched copy pass per frame.
- Visible rendering is swapchain-paced; non-renderable frames use the fallback
  delay and pause policy. A failed swapchain acquire skips the frame
  deterministically.
- Uploads are validated (size, format, bounds) before they are staged.

## Shaders

- Storage-buffer layouts never need 16-bit storage extensions.
- Change `k_max_tilemap_window_layers` and the GLSL `layer_offsets` literal
  together.
- Bindings follow the SDL_GPU sets: 0 vertex resources, 1 vertex UBO, 2
  fragment resources, 3 fragment UBO. For MSL, the first storage-buffer binding
  equals that stage's UBO count and vertex buffer bindings stay below 14;
  samplers are combined `sampler2D`. A layout that cannot meet this needs
  explicit MSL remapping.
- Every `shader_programs` stage sets `msl_entry_signature`; when resources
  change, recheck the bindings and copy the signature from the generated
  `.msl`.

## Text

- UI states store text intent and non-owning `PreparedText` and draw prepared
  views each frame without re-checking the cache.
- High-cardinality dynamic text needs eviction, explicit release, or an atlas
  policy before it ships. System font probing is not part of the runtime path.
