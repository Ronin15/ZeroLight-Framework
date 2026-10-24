---
paths:
  - "src/render/**"
  - "src/platform/**"
  - "src/game/render_prep.zig"
  - "src/game/*_state.zig"
  - "src/game/menu_view.zig"
  - "src/game/ai_debug_overlay.zig"
  - "src/game/render_depth.zig"
  - "src/game/world/system.zig"
  - "src/game/world/render.zig"
  - "src/game/world/edit.zig"
  - "src/game/world/worldgen.zig"
  - "src/game/world/gpu_tiles.zig"
  - "src/game/world/terrain.zig"
  - "assets/shaders/**"
  - "build.zig"
---

# Rendering And Shaders

How the renderer works: `docs/rendering-assets-shaders.md`.

## Boundaries

- Game code describes draws by intent (material tags, render order), never by
  GPU handles, pipeline pointers, or shader formats (SDL_GPU ownership:
  `engine-design.md` § Ownership boundaries).
- Shader paths come from the `shader_paths` helpers, never literal strings;
  descriptors carry counts and intent only. Adding a material or shader
  follows the rendering doc's checklist.
- Presentation state (visibility window, draw records, GPU residency, debug
  UI) lives on the render side, never in `DataSystem`, and simulation never
  reads it. States gate debug drawing on the render context and own no toggle.
- The main view renders only the camera-focused world; a secondary view (a
  mini camera) may show the same world or another. A world in no view
  simulates with no render state or render work.
- Workers never read live renderer resources: snapshot what they need before
  dispatch, and build GPU-facing groups on the main thread.

## Ordering and visibility

- Draws reach the GPU in nondecreasing render order (world depth, then UI,
  then debug). A producer that can interleave depths owns an explicit ordering
  phase; the batcher consumes an ordered stream and never sorts.
- Draw count scales with real interleave points, never window depth or world
  size: dense levels composite back to front, and a sparse tile gets its own
  interleave point.
- Visibility is the camera's chunk window plus bounds only; simulation tiers
  never gate drawing.
- The camera transform is applied on the GPU; a pan uploads only chunks
  entering the window, never vertices or resident chunks.

## Frame and uploads

- CPU prep runs before swapchain acquisition; the acquired interval only sets
  presentation uniforms, uploads, encodes, and submits. The swapchain texture
  is never held across CPU work.
- A buffer fully re-staged every frame may cycle; a retained, partially
  written buffer never does.
- The CPU copy is the source of truth: a change uploads once per sync, and all
  uploads flush in one batched copy pass per frame. Uploads are validated
  (size, format, bounds) before staging.
- Visible rendering is swapchain-paced; non-rendering frames use the fallback
  delay and pause policy, and a failed acquire skips the frame
  deterministically.

## Shaders

- Storage-buffer layouts never need 16-bit storage extensions.
- A CPU struct mirrored by a shader uniform keeps one field order and std140
  layout.
- Bindings follow the SDL_GPU sets: 0 vertex resources, 1 vertex UBO, 2
  fragment resources, 3 fragment UBO. For MSL, the first storage-buffer
  binding equals that stage's UBO count, vertex buffer bindings stay below 14,
  and samplers are combined; a layout that cannot meet this needs explicit
  MSL remapping.
- Every `shader_programs` stage sets `msl_entry_signature`; when its
  resources change, recheck the bindings and copy the signature from the
  generated `.msl`.

## Text

- UI states store text intent and non-owning prepared views, and draw them
  each frame without re-checking the cache.
- High-cardinality dynamic text needs eviction, explicit release, or an atlas
  policy before it ships. System font probing is not part of the runtime path.
