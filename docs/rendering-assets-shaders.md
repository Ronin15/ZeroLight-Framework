# Rendering, Assets, And Shaders

The app uses SDL_GPU directly and does not call Vulkan or Metal APIs itself.
SDL chooses the backend from the formats and drivers available at runtime.

## Shader Build

Shader sources live in `assets/shaders/*.glsl`.

- On Linux, `glslc` emits installed SPIR-V files under `zig-out/bin/assets/shaders/*.spv`.
- On macOS, `glslc` emits temporary SPIR-V and `spirv-cross` converts it to installed MSL files under `zig-out/bin/assets/shaders/*.msl`.
- On Windows, `glslc` emits temporary SPIR-V, `spirv-cross` converts it to HLSL
  shader model 6.0, and `dxc` emits installed DXIL files under
  `zig-out/bin/assets/shaders/*.dxil`.

The renderer tells SDL which shader formats the build produced and passes a null
driver name so SDL chooses the backend. Sprite material and pipeline creation
live under `src/render/gpu/` and load the shader files matching
`SDL_GetGPUShaderFormats()`.
Runtime shader selection prefers MSL, then DXIL, then SPIR-V when multiple
formats are available. A comptime assertion in `build.zig` verifies that every
supported target's format is accepted by the runtime selector; adding a new OS
target without wiring its format will fail at build-compile time.

Shader bytecode paths are derived from the program name and stage by
`src/render/gpu/shader_paths.zig` so that runtime paths are provably consistent
with the build's output stems. Material descriptors use these helpers instead of
hardcoded path strings.

## Adding a New Material

To add a new GPU material (shader + pipeline):

1. Create GLSL sources in `assets/shaders/{name}.vert.glsl` and
   `assets/shaders/{name}.frag.glsl`.
2. Add an entry to the `shader_programs` array in `build.zig` (name + source
   paths). The build will compile and check the output files automatically.
3. Add the new variant to the `Material` enum in
   `src/render/sprite_batch.zig`.
4. Create `src/render/gpu/{name}_pipeline.zig` with a material descriptor
   struct that uses `shader_paths.vertex("{name}", "spv")` etc. for paths and
   `sprite_pipeline.selectShaderSet` (or `shaderSetForFormat`) for format
   selection. Use `tilemap_pipeline.zig` as the reference when the material
   needs storage buffers or a different vertex layout. List resource counts
   (sampler, storage buffer, uniform buffer counts) — no SDL_GPU handles or
   game-state references cross this boundary.
5. Add a `*c.SDL_GPUGraphicsPipeline` field to `Renderer` in
   `src/render/renderer.zig`.
6. Call `create{Name}Pipeline()` in `Renderer.init()`.
7. Add a bind case to the `switch (group.material)` in `Renderer.endFrame()`.

Rule: game-facing draw calls reference `Material` enum tags only. No SDL_GPU
handles, pipeline pointers, or shader format strings cross the renderer boundary
into game code.

## Sprite Rendering

Sprites and colored rectangles flow through explicit ordered render-prep phases.
Game states and helpers submit draw records in nondecreasing `RenderOrder`:
world z first, then UI, then debug. Multiple producers (entities, particles,
sparse tiles, UI, debug) each own a phase or pass that preserves that order
before records reach `Renderer`/`SpriteBatch`. `SpriteBatch` remains a strict
ordered-stream consumer: it streams the per-frame **dynamic** vertex data and
submits by texture and coordinate-presentation groups. Vertices are stored
**SoA**: three per-attribute columns (`position`, `uv`, `color`) emitted into
three GPU vertex buffers, not one interleaved struct. Texture ownership is
tracked with generational `TextureId` values so stale or destroyed IDs are
rejected deterministically during batch prep.

The renderer owns a second, **static** set of vertex buffers for retained world
geometry — now a small, bounded number of composite dense tilemap quads rather
than one per dense layer (see GPU-Driven Tilemap). Each frame it
builds one order-merged draw list from the dynamic draw groups plus the static spans,
stable-sorted by `RenderOrder` (static appended first, so world/dense geometry draws
under sparse/dynamic at equal order). Per source it binds that source's three
per-attribute buffers (position/uv/color at slots 0/1/2; both pipelines declare three
vertex buffers) and the **sprite** or **tilemap** pipeline per `DrawGroup.material`.
The static buffers re-upload only on a structural change, so a still or panning frame
issues no dense vertex work.

`Renderer` remains the game-facing facade. `src/render/sprite_batch.zig` owns
sprite command storage, ordered-stream validation, vertex expansion, and draw
group construction so later UI, tilemap, or effect batchers can be added without
rewriting SDL_GPU device setup. Producers that can interleave depths own an
explicit ordering phase before commands reach the renderer.

Use `Renderer.submitOrderedSprite` for textured quads emitted by ordered
render-prep phases:

```zig
if (context.runtime_assets.sprite(.demo_tile)) |sprite| {
    try context.renderer.submitOrderedSprite(.{
        .texture = sprite.texture,
        .source = sprite.source_rect,
        .dest = .{ .x = 100, .y = 120, .w = 32, .h = 32 },
        .tint = .{ .r = 0.9, .g = 0.2, .b = 0.2, .a = 1.0 },
        .order = RenderOrder.world(render_depth.worldZ(.actor)),
    });
}
```

`TextureId` values are stable while the texture is alive. Destroying a texture
retires its slot and advances the generation before the slot can be reused, so
old IDs do not accidentally bind a later texture. The built-in white texture is
renderer-internal and backs rectangle draw records.

Use `Renderer.submitOrderedRectInSpace` for game-state debug or simple
primitive rendering from an ordered render-prep phase. Rectangles go through the
same sprite batch via a built-in white texture:

```zig
try context.renderer.submitOrderedRectInSpace(.{
    .x = 40,
    .y = 40,
    .w = 64,
    .h = 64,
}, .{ .r = 0.9, .g = 0.2, .b = 0.2, .a = 1.0 }, RenderOrder.world(render_depth.worldZ(.actor)), .world);
```

Direct `Renderer.submitOrderedSprite` and `submitOrderedRectInSpace` calls are
for paths that already submit in nondecreasing `RenderOrder`, such as world
z-layer passes, simple smoke tests, or stack-aware UI helpers.

For atlas-backed actors, keep entity data on stable `SpriteAssetId` values plus
numeric atlas entry IDs. Authoring names stay in source assets and metadata;
runtime render prep resolves entry IDs through `RuntimeAssets` metadata to
source rectangles. Tilemap batching follows the same stable-ID model rather than
creating one texture per tile, storing atlas names in hot gameplay data, or
persisting live renderer handles/source rectangles in `DataSystem`.

Large sprite, tile, or particle scenes should reserve or surface render-prep and
sprite-batch capacity before relying on allocation-free render frames. The
warmed path avoids per-frame allocation only inside the currently reserved
ordered-command, prepared-command, vertex, and draw-group capacity.

## GPU-Driven Tilemap

Dense world tiles are not emitted as per-tile vertices. Every dense layer's tile ids
are concatenated into one flat array (`WorldSystem.dense_tile_ids`) and uploaded
once, in one pass, to a single combined GPU **storage buffer**
(`GRAPHICS_STORAGE_READ`, one `u32` per cell, row-major — via
`WorldSystem.uploadDenseTileDataBuffer` / `Renderer.createTileDataBuffer`).

The world draws its dense render window as a small, bounded number of **composite**
draws, not one draw per dense layer. `WorldSystem.submitStaticDenseGeometry` takes
`GameplayScene.player_level` as `active_level`, collects the in-window dense layers
back-to-front (`collectDenseSubmitLayers`, unchanged contract), then cuts that
depth-ascending list into composite-draw buckets at every **interleave depth** —
a depth something else needs to render strictly between two dense layers this
frame (`partitionDenseCompositeBuckets`). Interleave depths come from three
sources, gathered by `render_prep.collectDenseInterleaveDepths` before the submit
call: `active_level`'s own actor depth (always included — this is what makes the
common case, no sandwiched content, behave exactly like a single draw), every
distinct dynamic entity/particle depth this frame, and every depth a sparse tile
is registered at **anywhere in the world**, not just `active_level` — closing what
would otherwise be a real gap: a whole-layer composite draw has no per-cell cull,
so a sparse tile (an ore vein, a pickup seen through a dug shaft) at *any*
in-window level must still get its own sandwich point the moment one exists, not
just the active level's. Depths are filtered to the dense window's own depth span
(`WorldSystem.denseWindowDepthSpan`) before partitioning, since anything outside it
cannot cut a boundary.

Each bucket becomes one retained world-space quad (`Renderer.beginStaticGeometry` /
`appendStaticTilemapSpan`) ordered at that bucket's own shallowest layer's real
`denseLayerOrder`, tagged `DrawGroup.material = .tilemap` and carrying a
`Renderer.TilemapWindowLayers` — up to `Renderer.k_max_tilemap_window_layers`
topmost-first element offsets into the combined buffer
(`WorldSystem.buildWindowLayers` reverses `collectDenseSubmitLayers`'s
deepest-first bucket slice, since the shader composites top-down). The tilemap
fragment shader maps each screen pixel to a world cell, then loops its window
topmost-first — `tile_ids[layer_offsets[i] + cell_index]` — stopping at the first
non-`invalid_tile_id` hit (or discarding if every composited layer is empty at
that pixel), derives the atlas cell from the tight grid (`col = id % columns`,
`row = id / columns`; enforced for every tile at meta load by
`validateGridEntry`), and samples the atlas. The loop's trip count
(`TilemapUniform.layer_meta.x`) is the same for every fragment in one draw
(dynamically uniform), so this is an ordinary bounded GLSL loop with no
toolchain risk. Draw count scales with how many interleave points exist this
frame (`Renderer.k_max_dense_composite_draws = 8` is the defensive cap; the
shipped default config always resolves to 1), never with window depth — cost
still scales with the **screen**, not the world: ~0.5 MB/layer of tile data and a
handful of draw calls regardless of world size or render-window depth.

The camera lives in the vertex shader (Sprite Rendering's `position_transform`), so
a **pan uploads nothing** — the full-world quads are unchanged. The quads re-submit
on a structural change (`dense_quads_dirty`), an `active_level`/window change, or
an interleave-depth-set change (a newly relevant sandwich point) — never on a pan
alone.

A **dig/build** (`setDenseTile`) writes the CPU tile field — the source of truth for
collision and gameplay — and queues a single-cell GPU edit. `flushDenseTileEdits`
applies all of a frame's queued edits in one batched copy pass
(`Renderer.uploadTileDataEdits`) at the render boundary: a dig is one storage-buffer
element write, no full re-upload and no vertex work.

Two pipelines share the ordered draw list. The renderer binds the **sprite** or
**tilemap** pipeline on a `DrawGroup.material` change; tilemap groups additionally
bind the (now shared) tile-data storage buffer (rebound per group, covering a
Metal storage-slot shift) and a small grid/atlas/composited-layer-window fragment
uniform (`Renderer.applyWindowLayers`, keyed by `DrawGroup.window_slot` into a
per-frame side table populated by `appendStaticTilemapSpan`). Only sprite groups
coalesce — every tilemap group is its own draw, distinguished by its composited
layer window rather than a distinct buffer. Multi-z is native: a composite draw's
order is its bucket's shallowest layer, and the order-merged draw list interleaves
it with dynamic entities and sparse tiles, so an actor in a dug pit — or a sparse
tile on any in-window level — renders between the floor below and walls above.

### Dense render window policy (Slice 23B)

Vertical scale is a **submit/draw** policy problem, not a per-tile vertex or
full-buffer residency problem. Every authored dense layer's cells still land in
the one combined GPU tile-data storage buffer at load
(`uploadDenseTileDataBuffer`); memory scales with total level count × cell count.
The render window bounds how many of those layers become static tilemap draw
groups each frame.

Default `DenseLayerRenderWindow` (`world_system.zig`):

| Field | Default | Effect |
| --- | --- | --- |
| `levels_below` | `6` | Submit `active_level` through `active_level + 6` (inclusive). |
| `ceiling_when_underground` | `false` | Opt-in only: redraws the full ceiling plane and breaks player-level follow. Surface hole see-through uses `levels_below` while `active_level == 0`. |

`world_system.zig`'s struct default is conservative for arbitrary callers, but
composite-draw bucketing (below) decouples fragment cost from window depth, so
`game_demo_state.zig`'s procedural world config now widens `levels_below` to
`procedural_underground_count` (the full authored 31-level underground stack) —
`1 + levels_below` exactly fills `k_max_dense_submit_stack_cap = 32`, checked by
a `comptime` assert alongside `validateDenseRenderBudget`. Widening the window
no longer costs extra fragment invocations in the common case (still 1 composite
draw); it does not change the GPU tile-data memory bound, which already sizes
for every authored layer regardless of window depth.

`collectDenseSubmitLayers` filters by `levelInWindow`, then sorts back-to-front
before append — this contract is unchanged by composite-draw bucketing.
`maxDenseSubmitLayerCount` derives the **layer** cap from the window and
`max_dense_bands_per_level`; `validateDenseRenderBudget` fails at world build if
the window exceeds `k_max_dense_submit_stack_cap` or optional
`WorldBuildConfig.max_dense_tile_gpu_bytes` — this bounds GPU tile-data memory
and the depth-ascending collection buffer, not draw count. The separate
**draw**-count cap is `WorldSystem.maxDenseSubmitDrawCount()`
(`Renderer.k_max_dense_composite_draws`): the actual bucket count is
data-dependent per frame (how many interleave points exist), so this is the
worst case. `render_prep.staticGeometryCapacity` sources its span/vertex
reservation from `maxDenseSubmitDrawCount()` (the fixed composite-draw bound),
not `maxDenseSubmitLayerCount()` — reservation stays flat regardless of window
depth, since every direct `appendStaticTilemapSpan` caller now builds one span
per bucket rather than one per layer.

**Sparse/dense boundary:** chunk visibility (`setVisibleChunksForWorldRect`)
still culls sparse tiles and sizes dynamic sparse prep (`reserveRenderRecords`);
it does not drive dense floor submit or bucketing — a sparse tile becomes an
interleave point purely by being *registered* at some depth
(`WorldSystem.sparseDepthRangeCount`/`sparseDepthRangeAt` walk every registered
depth, not only the currently visible ones), independent of camera position.
Each dense composite draw is one full-world quad regardless of camera
pan — panning uploads nothing. Sparse overlays and dense composite draws
interleave in the merged draw list by `RenderOrder`; per-entity depth cull
(Slice 25E) is separate from this floor window.

### Dynamic entity collect (Slice 24B)

`render_prep.collectDynamicRecords` walks `movementBodySliceConst()` — not the
primitive-visual entity list. Chunk columns align on `movement_index` for the
camera chunk gate; scope tier and pin metadata are not read during collect.
Drawable rows are gated by a dense `has_primitive_visual` column on the movement
store (movement-only bodies skip slot resolve). Indices for drawable rows come
from `DataSystem.renderCollectIndicesForMovement` (one slot read per chunk-pass
row that carries a primitive visual).

Gates before interpolation and `PreparedDraw` construction (in order):

1. **Chunk** — `WorldSystem.visibleChunkRegion()` (camera window; unset skips all
   rows). Uses `scope.chunk_x/y` from the movement-body scope columns — updated
   during the movement integration pass. Entities teleported via `setMovementBody`
   or rendered before the first movement tick may retain default `(0,0)` chunk
   coords until movement runs; pixel AABB is the second gate.
2. **Camera AABB** — `VisibleWorldRect.overlapsAabb` on the lerped footprint
   (camera rect + `overscan_chunks` margin). Demo runtime uses
   `world_render_overscan_chunks = 1` in `game_demo_state.zig`.

**Simulation tier is not consulted.** Slice 24 LOD (`dormant`/`kinematic`/etc.)
controls fixed-step processor participation only. Render visibility is camera
policy only — an on-screen `dormant` row still draws; an off-screen `cognition`
row does not. Do not add `allowsRender`-style predicates on `SimulationTier`.

**Dense floors (separate cost model):** in-window dense layers submit as a small,
bounded number of composite tilemap quads (see GPU-Driven Tilemap), not one draw
per layer or per visible tile. GPU clips to the viewport; submit/draw count
scales with interleave points this frame, not window depth. Chunked dense submit
is a future optimization if profiling requires it.

A pre-built visible movement dense-index list (parallel to scoped simulation
gathers) is tracked under **Scaling Gaps And Hardening Frontier** in
`docs/framework-implementation-slices.md`.

### Tile storage upload `cycle` policy (Slice 23A)

The retained combined tile-data storage buffer is **not** ring-buffered. Partial
dig uploads must never pass `cycle=true` to `SDL_UploadToGPUBuffer` or map the
tile-edit transfer buffer with `cycle=true` — doing so ping-pongs GPU storage and
flips visible tiles while CPU state stays correct.

| Resource | `cycle` on upload / map |
| --- | --- |
| Dynamic/static **vertex** streams (per-frame ring) | `true` on the last **vertex** upload in the copy pass |
| **Tile-data storage** buffer (combined, retained) | **always `false`** |
| Tile-edit transfer buffer (`stageStorageRegions`) | **`false`** |

Tile edits are excluded from the vertex upload `cycle` counter; they are batched
in the post-acquire copy pass via `recordStorageRegionsInPass`.

Digging authors two kinds of tile edit. A *hole* clears the cell to
`invalid_tile_id`, which the tilemap fragment shader discards (see-through to the
plane below) and `flagsFor` treats as non-blocking — the player falls through it. A
*carve* writes a visible walkable floor tile. The three dig actions compose these:
digging forward on the surface opens a hole (fall); digging forward underground
carves a walkable tunnel tile so the player mines horizontally through the solid
dirt; digging down opens a hole on any plane to drop one level. A fall always carves
its landing cell so the player never lands embedded in rock.

## Logical Presentation

The default logical game size is 1280x720. Windows are resizable and request
high pixel density, so SDL window coordinates and SDL_GPU drawable pixels can
differ on macOS Retina and similar displays.

The renderer does not use `SDL_Renderer` or SDL's renderer-only logical
presentation helpers. After each successful SDL_GPU swapchain acquisition it
computes presentation from the acquired drawable size and current SDL window
size. CPU prep emits world vertices in **world coordinates** and logical/drawable
vertices in their own space; the vertex shader applies the per-presentation
uniform, which for `.world` folds the camera (pan/zoom) and the acquired-size
presentation into one affine transform. Keeping the camera in the shader makes
world geometry camera-independent on the CPU, which is what lets the dense tilemap
quads be uploaded once and reused across pans (see GPU-Driven Tilemap). SDL_GPU
viewport stays in drawable space and scissor clips logical content to the
computed viewport.

Default scale mode is aspect-preserving fit. If the drawable aspect differs from
1280x720, the configured clear color shows through the letterbox or pillarbox
bars.

Integer fit keeps strict whole-number scaling. The app requests a minimum SDL
window size equal to the logical size when integer fit is configured, so normal
user resizing should not produce sub-1x cropped presentation.

Sprite coordinate spaces:

- `.world`: gameplay/world coordinates. CPU prep emits world-space vertices; the
  vertex shader applies the camera and presentation. The camera is not applied on
  the CPU.
- `.logical`: logical UI coordinates. The camera is ignored, and vertices stay
  in logical presentation coordinates.
- `.drawable`: raw swapchain pixel coordinates. The camera and logical viewport
  are ignored; this is for debug overlays that should stay pixel-exact.

## Runtime Assets

Atlas PNGs ship with JSON sidecar manifests. Loose source art packs through
`tools/pack_atlas.py`; setup code can resolve authoring names through
`world_tileset_meta.zig` and `sprite_atlas_meta.zig`, while hot gameplay and
render prep use stable numeric IDs. See
`docs/atlas-asset-workflow.md` for the pack, export, and swap workflow.

Startup sprite and audio assets are declared in `src/assets/manifest.zig`.
`Engine` owns `RuntimeAssets`, preloads every registered sprite texture through
`AssetCache`, parses atlas JSON sidecars once at init, preloads declared audio
through `AudioService`, and passes the catalog to render contexts. Atlas
lookups use `RuntimeAssets.worldTilesetMeta()` for the world tileset and
`RuntimeAssets.spriteAtlasMeta(id)` for character/item atlases. Registered
metadata sidecars are required even when optional character/item textures fall
back to primitive rendering; missing or invalid sidecars fail startup instead
of leaving partial metadata behind.

`GameDemoState` owns `WorldSystem`, which stores tile IDs, atlas source-rect
columns, level z columns, and chunk/visibility columns in SoA form. World
construction requires `.world_tileset` metadata, and world render enqueue
requires the `.world_tileset` texture; missing world atlas data is an error, not
a primitive rectangle fallback. The runtime loading path builds the procedural
512x512 tile world through the Engine-owned `ThreadSystem`. Dense world tiles draw
as a small, bounded number of GPU-driven composite tilemap quads (see
GPU-Driven Tilemap) while sparse tiles, entities, and particles stream through
the ordered dynamic batch — the
camera-visible chunk window still crops sparse-tile submission, with optional
configured overscan. The renderer's order-merged draw list interleaves all of them
by `RenderOrder`, so there is no hand-written world/entity depth merge and
`SpriteBatch` stays an ordered-stream consumer
rather than a fallback tile sorter. Demo actors
reference stable `.grim_characters` atlas-entry IDs through `DataSystem` asset
references and keep primitive visual rectangles as placeholders when character
art is unavailable. Obstacles can still use `assets/sprites/demo_tile.png` as a
reusable tintable sprite. The
default text path uses the bundled
`assets/fonts/NotoSansMono-Regular.ttf` font.

Runtime assets are installed under `zig-out/bin/<asset-root>`. The default
asset root is `assets`; change it with `-Dasset-root=content`.
`zig build run`, `zig build dev`, and `zig build gpu-smoke` run from the
installed binary directory so generated shaders and copied assets resolve
through that tree. When launching a binary directly, run it from `zig-out/bin`
or provide an asset-root layout that includes generated shader files.

The installed runtime asset tree excludes shader source files and build-only
shader formats. Package source assets separately if your game needs them.

Asset paths are relative to the configured asset root and reject empty paths,
absolute paths, `.` components, and `..` traversal.

PNG image loading uses core SDL3 `SDL_LoadPNG` support in the asset layer; this
project does not require `SDL3_image`. Do not add `SDL3_image` unless that
dependency is explicitly chosen for a feature that core SDL3 PNG loading cannot
reasonably cover.

The asset cache maps validated relative PNG paths to renderer `TextureId`
values. Loading the same path decodes PNG data through `AssetStore`, uploads
decoded RGBA8 pixels through the renderer, reuses the existing texture on later
acquires, and increments a retain count. `TextureLease` is a non-owning retained
texture token; it does not store an `AssetCache` pointer or renderer/backend
context. It still carries enough identity for the cache to reject stale,
forged, or wrong-owner releases before retiring a slot. Owners that hold leases
release them through `AssetCache.releaseTexture(renderer, &lease)` before
renderer teardown. Gameplay and render prep should store or pass
`SpriteAssetId`, not paths, `TextureId`, `TextureLease`, or prepared sprite
records. Cache lookup and retain/release are setup-time operations; per-frame
rendering should use the startup catalog and retained IDs directly.

`RuntimeAssets` owns startup sprite leases. Missing declared content marks that
asset unavailable and keeps startup moving; fatal preload errors release partial
retained sprite work before returning the error. Replacing a sprite slot or
marking it unavailable releases the previous lease first. Backend-context test
seams stay under asset tests; production code goes through the renderer-facing
cache API.

## Text Rendering

`TextService` owns SDL3_ttf initialization and shutdown, opens fonts through
`AssetStore`, and caches rendered text as renderer textures. Production
`RenderContext` values provide it for menu and UI states; unit-test contexts can
leave it null when text is not part of the contract under test. Load fonts from
`assets/fonts/...` and keep the returned `FontId`. UI states store text intent,
dirty flags, and non-owning `PreparedText` views. For common default-font labels,
call `TextService.prepareDefaultText(renderer, label, color)`. For custom fonts
or layout, call `TextService.prepareText(renderer, TextRequest.init(...))`.
Normal render frames draw the stored view with `text.drawPreparedText(...)`, so
stable labels do not re-check the cache every frame. The service keeps generated
text textures cached for app lifetime and releases them during
`TextService.deinit` after the renderer is idle.

The app-lifetime cache fits stable menu labels, debug text, and low-cardinality
UI. Chat logs, combat text, localization sweeps, or other high-cardinality
dynamic text need eviction, explicit release, or a different text-atlas policy
before they are treated as long-running workloads.

The default font is `fonts/NotoSansMono-Regular.ttf`. System font probing is not
part of the normal runtime path.

## Adding A Shader

Add GLSL source under `assets/shaders/`, then add an entry to the
`shader_programs` table in `build.zig` so the build emits the platform shader
files. Load the resulting installed shader files from the render-owned GPU
pipeline module, such as `src/render/gpu/sprite_pipeline.zig` (or
`tilemap_pipeline.zig` for the storage-buffer example), while keeping `Renderer`
as the game-facing facade.

Keep shader resource bindings aligned with SDL_GPU's layout rules:

- vertex uniform buffers: set 1
- fragment sampled textures/samplers: set 2, then fragment storage buffers in the
  same set after the samplers (so one sampler + one storage buffer are bindings 0
  and 1, bound via separate `SDL_BindGPUFragmentSamplers` / `…StorageBuffers` slots)
- fragment uniform buffers: set 3

The build converts those SPIR-V bindings to SDL-compatible MSL resource bindings
for macOS through `spirv-cross`. Windows DXIL uses the HLSL generated by
`spirv-cross` and compiled with `dxc -E main -T vs_6_0` or `ps_6_0`.

## Debug Overlay

Press F2 to toggle the yellow FPS overlay. It reports render-loop cadence, not
the fixed update tick rate. The overlay uses drawable coordinates so its
SDL3_ttf texture remains independent of game scaling, and it scales font size by
the drawable-to-window pixel ratio for high-DPI displays. The overlay renders
through the asset-backed text service and bundled default font.
