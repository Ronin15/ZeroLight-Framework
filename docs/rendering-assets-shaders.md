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
   selection. List resource counts (sampler, storage buffer, uniform buffer
   counts) — no SDL_GPU handles or game-state references cross this boundary.
5. Add a `*c.SDL_GPUGraphicsPipeline` field to `Renderer` in
   `src/render/renderer.zig`.
6. Call `create{Name}Pipeline()` in `Renderer.init()`.
7. Add a bind case to the `switch (group.material)` in `Renderer.endFrame()`.

Rule: game-facing draw calls reference `Material` enum tags only. No SDL_GPU
handles, pipeline pointers, or shader format strings cross the renderer boundary
into game code.

## Sprite Rendering

Sprites and colored rectangles flow through an explicit render-prep queue when
multiple producers can interleave world, effect, UI, or debug records. The queue
sorts transient draw records by `RenderOrder`: world z first, then UI, then
debug. `SpriteBatch` remains a strict ordered-stream consumer: it streams the
per-frame **dynamic** vertex buffer (entities, particles, UI, sparse tiles) and
submits by texture and coordinate-presentation groups. Texture ownership is
tracked with generational `TextureId` values so stale or destroyed IDs are
rejected deterministically during batch prep.

The renderer owns a second, **static** vertex buffer for retained world geometry —
now just one quad per dense layer (see GPU-Driven Tilemap). Each frame it builds one
order-merged draw list from the dynamic draw groups plus the static spans,
stable-sorted by `RenderOrder` (static appended first, so world/dense geometry draws
under sparse/dynamic at equal order). It binds the dynamic or static vertex buffer
per source and the **sprite** or **tilemap** pipeline per `DrawGroup.material`. The
static buffer re-uploads only on a structural change, so a still or panning frame
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

Dense world tiles are not emitted as per-tile vertices. Each dense layer's tile ids
are uploaded once to a GPU **storage buffer** (`GRAPHICS_STORAGE_READ`, one `u32`
per cell, row-major — a direct copy of `WorldSystem.dense_tile_ids` via
`Renderer.createTileDataBuffer`). The world draws **one world-space quad per dense
layer** through the retained static vertex buffer (`Renderer.beginStaticGeometry` /
`appendStaticTilemapSpan`) at `denseLayerOrder(layer)`, tagged
`DrawGroup.material = .tilemap`. The tilemap fragment shader maps each screen pixel
to a world cell, reads the tile id from the storage buffer, derives the atlas cell
from the tight grid (`col = id % columns`, `row = id / columns`; that layout is
enforced for every tile at meta load by `validateGridEntry`), and samples the
atlas. Cost scales with the **screen**, not the world: ~0.5 MB/layer of tile data
and a handful of draw calls regardless of world size.

The camera lives in the vertex shader (Sprite Rendering's `position_transform`), so
a **pan uploads nothing** — the full-world quads are unchanged. The quads re-submit
only on a structural change (`dense_quads_dirty`: a new dense layer or chunk
rebuild), never per frame or per pan.

A **dig/build** (`setDenseTile`) writes the CPU tile field — the source of truth for
collision and gameplay — and queues a single-cell GPU edit. `flushDenseTileEdits`
applies all of a frame's queued edits in one batched copy pass
(`Renderer.uploadTileDataEdits`) at the render boundary: a dig is one storage-buffer
element write, no full re-upload and no vertex work.

Two pipelines share the ordered draw list. The renderer binds the **sprite** or
**tilemap** pipeline on a `DrawGroup.material` change; tilemap groups additionally
bind the layer storage buffer (rebound per group, covering a Metal storage-slot
shift) and a small grid/atlas fragment uniform. Only sprite groups coalesce — each
tilemap group binds its own buffer. Multi-z is native: deeper levels are dense
layers at a lower `RenderOrder`, and the order-merged draw list interleaves them
with dynamic entities, so an actor in a dug pit renders between the floor below and
walls above. `WorldSystem.submitStaticDenseGeometry` takes the player's active level and skips
the floors above it (re-submitting only when the plane changes), so descending
reveals the plane the player stands on instead of leaving it buried under the
surface.

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
as one GPU-driven tilemap quad per layer (see GPU-Driven Tilemap) while sparse
tiles, entities, and particles stream through the ordered dynamic batch — the
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
