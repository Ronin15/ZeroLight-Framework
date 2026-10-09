# Rendering, Assets, And Shaders

The app uses SDL_GPU directly and calls no Vulkan or Metal APIs itself. SDL
chooses the backend from the formats and drivers available at runtime. Rules:
`.claude/rules/render.md` and `.claude/rules/assets-audio.md`.

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

Game-facing draw calls reference `Material` enum tags only; no SDL_GPU handles,
pipeline pointers, or shader format strings cross the renderer boundary.

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

Large sprite, tile, or particle scenes reserve render-prep and sprite-batch
capacity ahead of submission. The warmed path avoids per-frame allocation only inside the currently reserved
ordered-command, prepared-command, vertex, and draw-group capacity.

`drawSprite` never refuses. A submit past the batch's physical capacity grows the
command list geometrically on the main thread. `Renderer.reserveSpriteCommands`
marks the frame reserved at its grow-only `command_high_water`; a reserved frame
whose submits exceed that reservation is counted once
(`SpriteBatch.command_overflow_grows`, perf metric `sprite_command_overflow_grows`)
and warned through `logging.render` (1st, 2nd, 4th, ... drifting frame), whether or
not the command list's rounded-up capacity absorbed the overshoot. The comparison is
against the reservation because that is the bound past which
`ensureFrameBatchCapacity` grows prepared/vertex/group storage and the GPU streams
(a possible GPU-idle stall). A short reservation formula shows up as a counter
instead of exiting the app.

## GPU-Driven Tilemap

Dense world tiles are not emitted as per-tile vertices. Each rendered world owns
one renderer-side **GPU tile store** (`Renderer.createTileStore`, a
`GRAPHICS_STORAGE_READ` storage buffer) holding only its **render window**: the
dense layers of the levels in the vertical window (`DenseLayerRenderWindow`),
each over the camera's chunk window, chunk by chunk like the CPU terrain
(`world_terrain.zig`). The world keeps only the store's handle and a mirror of
its layout (`WorldSystem.gpu_tiles`, `world_gpu_tiles.zig`).

Layout (documented at `renderer.zig`'s `tile_store_uniform_bit`, shared with
`tilemap.frag.glsl`): one `u32` buffer, two allocation classes at absolute
element offsets from one bump high water, each with a free list:

- **Directory** per resident layer: `side * side` toroidal words, chunk
  (cx, cy) at `(cy & (side - 1)) * side + (cx & (side - 1))`, then one **link
  word** holding the next deeper resident layer's directory start
  (`tile_store_no_link` for the deepest). A word with `tile_store_uniform_bit`
  set is a uniform chunk whose tile is its low 16 bits; any other word is the
  absolute offset of the chunk's block. `side` is a power of two covering any
  chunk window the camera rect can touch (`WorldSystem.render_side`: the rect's
  chunk span plus one for alignment and the overscan, clamped to the level's
  grid), so a pan keeps the layout.
- **Block** per resident mixed chunk-layer: the chunk's tiles in local
  row-major order, packed two 16-bit ids per `u32` (`packTileData`), 512 B at
  16-cell chunks. `u32` elements keep the layout free of 16-bit storage
  extensions.

`TilemapParams` (`sprite_batch.zig`, 80 B, std140, the same field order as the
shader's `TilemapUniform`) carries the grid and atlas, the chunk shift and
`side` (`layer_meta.z`/`.w`), the resident chunk window (`window`, moved by
`Renderer.setTileStoreWindow`), and per draw the layer count, shallowest flag,
and topmost directory (`layer_meta.x`/`.y`, `chain.x`, from
`Renderer.applyWindowLayers`). The shader discards pixels whose chunk is
outside the window; directory words of chunks outside it are never read. The
shader and the store layout take the window per draw; the renderer and the
mirror hold one window per store today.
`WorldSystem` owns the `@bitSizeOf(TileId) == 16` assert the packing depends on.

GPU memory is at most `L × side² × (E²/2 + 1) × 4 B` for `L` resident layers and
chunk edge `E`, independent of level size, depth, and world count (derived:
about 1 MiB for 32 layers at side 8 and 16-cell chunks). The store's only width
limit is SDL's `u32` byte size: `world_gpu_tiles.residentLayerFit` bounds the
layers whose directories and a block per window chunk fit, and the sync draws
only that many, dropping the deepest and logging once. The directory side is
capped at `tile_store_max_side` (2^14, the largest side whose one directory
fits); a chunk window wider than that is clipped to it, logged once. No world, level, layer,
or terrain change is refused (`.claude/rules/budgets-capacities.md`); the store
reports its resident bytes once per world.

The world draws its resident layers as a small number of **composite** draws,
not one per layer. `WorldSystem.submitStaticDenseGeometry` cuts the resident
layers (deepest first, `dense_render.layers`) into buckets at every
**interleave depth**: a depth something else needs to render strictly between
two dense layers this frame (`partitionDenseCompositeBuckets`). Interleave
depths come from `render_prep.collectDenseInterleaveDepths`: `active_level`'s
own actor depth (always), every distinct dynamic entity/particle depth this
frame, and every depth of the render window's sparse tiles, since a
whole-layer composite draw has no per-cell cull and a sparse tile at any
in-window level needs its own sandwich point; a sparse tile outside the window
cuts nothing. Candidates dedupe by the gap they
would cut and drop outside the resident layers' depth span
(`denseWindowDepthSpan`), so they fit one slot per gap in the world's scratch.

Each bucket becomes one retained world-space quad (`Renderer.beginStaticGeometry`
/ `appendStaticTilemapSpan`) ordered at the bucket's shallowest layer's
`denseLayerOrder`, tagged `DrawGroup.material = .tilemap`, with a
`Renderer.TilemapWindowLayers` naming its topmost directory and layer count
(`WorldSystem.buildWindowLayers`). The resident layers chain topmost-first, so
the walk from a bucket's topmost directory visits exactly its layers. The
fragment shader maps each pixel to a world cell, checks its chunk is in the
window, then walks the chain: `tileAt` reads the cell's toroidal word and, for a
mixed chunk, the cell from its block; after a miss it follows the link word. It
stops at the first non-`invalid_tile_id` hit (or discards when every chained
layer is empty), derives the atlas cell from the tight grid (`col = id %
columns`, `row = id / columns`; enforced at meta load by `validateGridEntry`),
and samples the atlas. The loop's trip count and chain are the same for every
fragment of a draw (dynamically uniform). Draw count scales with interleave
points this frame (the shipped default config resolves to 1), never window
depth or world size; the window table and static spans are reserved to one per
resident layer.

The fragment shader also applies a fixed-margin rim-darkening (contact-shadow)
pass on the surface tile's rim where it overhangs a hole: it reads neighboring
cells' top-layer tiles (only for resident chunks) from the same store and
subtracts a falloff from `out_color.rgb` near the edge. This is deliberately not
derivative-based (`fwidth`); see the in-shader comment for why.

The camera lives in the vertex shader (Sprite Rendering's `position_transform`),
so a pan never re-submits vertices: the quads are full-world and the chunk
window is a store uniform. The quads re-submit on a layer or store change
(`dense_quads_dirty`), an `active_level`/window change, or an interleave-depth
change (`.claude/rules/render.md`).

`WorldSystem.syncDenseTileStore` runs once per frame in render prep, on the
main thread before `ensureStaticGeometryCapacity`, `submitStaticDenseGeometry`,
and swapchain acquisition. It plans first (`GpuTileMirror.plan` sizes every span
and reserves every growth, the frame's dense render scratch included, changing
nothing a retry depends on), then commits and queues one upload batch
(`Renderer.queueTileStoreUploads`) recorded in the frame's one copy pass. Spans
are whole units (a directory, a word, a link, a block), so a batch
carried from a skipped frame folds into the next (`mergeTileStoreSpans`), newer
values winning. `Renderer.reserveTileStoreUploads` reserves the CPU upload lists
before it grows the store's GPU buffer, so any reserve failure (`OutOfMemory`,
`GpuBufferTooLarge`, `SdlError`) leaves the store's capacity, pending batch, and
growth source unchanged for retry.

- **Residency.** When the active level, the level window, the chunk window, the
  side, or the layer set changed: layers leaving free their directory and
  window blocks; staying layers free the blocks of chunks leaving the window and
  upload each entering chunk's word and, when mixed, its block; entering layers
  upload their directory and their mixed window chunks' blocks; a staying layer
  whose next deeper layer changed rewrites its link word. A side change (a
  viewport crossing a power of two) lays the window out anew in a new store;
  the old one is swept. A layer added in play on an in-window level enters at
  the next sync.
- **Edits.** A dig/build (`setDenseTile`, or a batched `applyDenseCellWrites`)
  writes the CPU chunk store, the source of truth, which marks each block it
  takes or changes (`BlockFill.changed`, render-only, never saved). A change on a
  resident layer also flags the layer (`render_changed`) and the world
  (`gpu_edits_pending`); edits hold no GPU-side memory, so a world nobody renders
  pays nothing for them. The next sync scans each flagged layer's chunks in the
  window and compares the CPU form with the uploaded directory word: a chunk
  that split takes a block and uploads its word and whole block, one that
  returned to a single tile frees its block and uploads its word, a uniform
  chunk at a new tile uploads its word, and a mixed chunk whose block is marked
  uploads the whole block once. Every uploaded block's mark and every resident
  flag clear at commit. A change on a chunk outside the window, or on a layer
  not resident, uploads nothing; the chunk uploads whole when it enters.
- **Cost.** Steady frame O(resident layers): the plan's per-slot scan and the
  interleave collect. Pan across a chunk boundary O(L × Wc) CPU (`Wc`
  window chunks) and O(L × e) uploads (`e` window edge in chunks), GPU memory
  flat (`chunk-scale-gpu-sync-pan`, which also varies L at 2, 8, and 32).
  Active level change O(L × Wc + the entering layer's mixed window blocks)
  (`chunk-scale-gpu-sync-level-enter`, flat across level size and depth, L at
  2, 8, and 32). One dig: an O(Wc) scan of its layer and one word or block
  upload (`chunk-scale-gpu-sync-dig`: flat across level size and depth,
  measured; linear in window chunks, derived). Never dependent on chunks or levels
  outside the window. Serial render-boundary work, O(window).

The world holds only a non-owning, generational `TileDataId` (slot index plus
generation, the `TextureId` pattern); no game teardown releases the store.
`syncDenseTileStore` claims it every frame (`Renderer.claimTileStore`), and the
first statement of `Renderer.endFrame` sweeps the stores: a live store nobody
claimed since the previous sweep is retired, its slot's generation advances so
every issued id goes stale, and SDL frees the buffer once in-flight frames
finish (no device drain). So a destroyed or replaced world's store goes at the
next `endFrame`, as does the store of a world whose state stops rendering
(`render_below = false`) or loses the camera. Retained tilemap draws naming a
stale id resolve to no store and are skipped. When a claim fails, the world
resets its mirror (no layer resident, no layout, empty allocator, capacity
kept) and the next sync re-uploads the window into a new store. Cost (derived):
O(1) claim per frame; the sweep walks the store-slot high water, O(stores) per
frame; a reset re-uploads O(L × side² + mixed window blocks).
`Renderer.deinit` releases any stores still live.

Two pipelines share the ordered draw list. The renderer binds the **sprite** or
**tilemap** pipeline on a `DrawGroup.material` change; tilemap groups
additionally bind the world's tile store (rebound per group, covering a Metal
storage-slot shift) and push the store's params with the draw's chain
(`Renderer.applyWindowLayers`, keyed by `DrawGroup.window_slot` into the side
table `appendStaticTilemapSpan` fills). Only sprite groups coalesce. Multi-z is
native: a composite draw's order is its bucket's shallowest layer, and the
order-merged draw list interleaves it with dynamic entities and sparse tiles, so
an actor in a dug pit, or a sparse tile on any in-window level, renders between
the floor below and walls above.

### Dense render window policy (Slice 23B)

The render window sets which dense layers are resident in the world's GPU tile
store and drawn each frame; the camera's chunk window sets which of their chunks
are resident. GPU memory follows the window's layers times its chunks, never
the level's area, the world's depth, or the levels outside the window.

Default `DenseLayerRenderWindow` (`world_system.zig`):

| Field | Default | Effect |
| --- | --- | --- |
| `levels_below` | `6` | Submit `active_level` through `active_level + 6` (inclusive). |
| `ceiling_when_underground` | `false` | Opt-in only: redraws the full ceiling plane and breaks player-level follow. Surface hole see-through uses `levels_below` while `active_level == 0`. |

`game_demo_state.zig`'s procedural world widens `levels_below` to the full
authored underground stack: composite bucketing keeps fragment cost off window
depth in the common case (one draw), and the chain carries any number of
layers. `collectDenseSubmitLayers` visits only the window's levels through their
band lists, sorts back-to-front, and lists them topmost-first for the chain.
Nothing caps the window's layers except the store width fit above.
`render_prep.staticGeometryCapacity` reserves one span per resident layer
(`WorldSystem.maxDenseSubmitDrawCount`), the most composite draws a frame can
cut.

**Sparse/dense boundary:** the window update (`setVisibleChunksForWorldRect`,
which also takes the active level and sets `render_side`) builds the window's
sparse list: the sparse tiles on the render window's levels, in its chunks
(through the per-chunk sparse index) and inside its tile bounds, sorted by
(depth, cell, tile id) with one range per distinct depth. It counts, reserves,
then fills, so work and memory follow the tiles in the window (O(window levels
× window chunks + V log V)), never the world's sparse count, level size, or
depth; an allocation failure leaves the previous window and list in place and
the next call retries. A still camera or sub-tile pan returns early.
`addSparseTile` is O(1) and marks the list for rebuild only when the tile lands
inside the current window; nothing is listed before a window is set. Dynamic
sparse prep reserves `reserveRenderRecords` (the list's length);
`sparseDepthRangeCount`/`sparseDepthRangeAt` give the window's sparse depths
for interleave points, and `submitVisibleSparseRange` submits one range. Draw
order never depends on a tile's storage index. Sparse overlays and dense
composite draws interleave in the merged draw list by `RenderOrder`;
per-entity depth cull (Slice 25E) is separate from this floor window.

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
row does not.

**Dense floors (separate cost model):** in-window dense layers submit as a small,
bounded number of composite tilemap quads (see GPU-Driven Tilemap), not one draw
per layer or per visible tile. GPU clips to the viewport; submit/draw count
scales with interleave points this frame, not window depth. Chunked dense submit
is a future optimization if profiling requires it.

A pre-built visible movement dense-index list (parallel to scoped simulation
gathers) is tracked under **Scaling Gaps And Hardening Frontier** in
[`docs/roadmap/scaling-gaps.md`](roadmap/scaling-gaps.md).

### Tile storage upload `cycle` policy (Slice 23A)

`cycle` is a per-buffer decision made independently on the destination
`SDL_UploadToGPUBuffer` and on the source `SDL_MapGPUTransferBuffer`, and it
follows one rule on each axis: **a buffer whose full contents are re-staged every
frame and reused across frames cycles; a retained buffer written partially does
not.** The fixed loop does not fence between frames, so any buffer touched on
frame N+1 while frame N's copy is still in flight must cycle to rotate to fresh
backing, or the new write lands on memory the in-flight copy is still reading.

- A world's GPU tile store is retained and written partially (one directory
  word or one whole block per changed chunk), so its span uploads and growth
  copies pass `cycle=false`. Cycling it would ping-pong GPU storage and flip
  visible tiles while CPU state stays correct.
- The renderer's pooled tile-upload transfer buffer is reused across frames and
  fully re-staged each frame, so its source map passes `cycle=true`, exactly like
  the vertex-stream staging in `stageVertices`. A frame whose staged values
  outgrow it replaces it pre-acquire with one at least twice its size (clamped to
  the `u32` byte width): the new transfer is created first and the old one
  released to SDL, which frees it after in-flight copies, so growth never drains
  the device. Replacements count in `Renderer.tile_upload_transfer_grows`; the
  first logs once at info. If the doubled transfer cannot be created, one retry
  creates it at exactly the frame's size.

| Resource | `cycle` on upload / map |
| --- | --- |
| Dynamic/static **vertex** streams (per-frame ring) | `true` on the last **vertex** upload in the copy pass |
| **Tile store** (per world, retained) | span upload and growth copy **always `false`** |
| Tile-upload transfer buffer, pooled (`stageTileStoreUploads`) | source map **`true`** |

Tile-store uploads are excluded from the vertex upload `cycle` counter; they are
staged pre-acquire and recorded in the post-acquire copy pass
(`recordStorageSpansInPass`, `recordStorageCopyInPass`).

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

`GameDemoState` owns `WorldSystem`, which stores tile IDs (dense layers per
chunk), atlas source-rect columns, and level z columns. World
construction requires `.world_tileset` metadata, and world render enqueue
requires the `.world_tileset` texture; missing world atlas data is an error, not
a primitive rectangle fallback. The runtime loading path builds the procedural
256x256 tile world through the Engine-owned `ThreadSystem`. Dense world tiles draw
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
project does not use `SDL3_image` (`.claude/rules/engine-design.md`).

The asset cache maps validated relative PNG paths to renderer `TextureId`
values. Loading the same path decodes PNG data through `AssetStore`, uploads
decoded RGBA8 pixels through the renderer, reuses the existing texture on later
acquires, and increments a retain count. `TextureLease` is a non-owning retained
texture token; it does not store an `AssetCache` pointer or renderer/backend
context. It still carries enough identity for the cache to reject stale,
forged, or wrong-owner releases before retiring a slot. Owners that hold leases
release them through `AssetCache.releaseTexture(renderer, &lease)` before
renderer teardown. Gameplay and render prep pass `SpriteAssetId`; cache
lookup and retain/release happen at setup, and per-frame rendering uses the
startup catalog and retained IDs directly.

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

Shader resource bindings follow SDL_GPU's layout:

- vertex sampled textures/samplers, then storage textures, then storage buffers:
  set 0
- vertex uniform buffers: set 1
- fragment sampled textures/samplers, then storage textures, then storage
  buffers: set 2 (so one sampler + one storage buffer are bindings 0 and 1,
  bound via separate `SDL_BindGPUFragmentSamplers` / `…StorageBuffers` slots)
- fragment uniform buffers: set 3

The build converts those SPIR-V bindings to MSL for macOS through `spirv-cross
--msl-decoration-binding`, so each resource's MSL index is its SPIR-V binding
rather than an order spirv-cross infers from the shader's code shape. Decoration
binding drops the descriptor set, so a stage's storage buffers and uniform
buffers share one `[[buffer]]` namespace, and SDL_GPU's Metal backend binds that
namespace as uniform buffers first, then storage buffers. For each stage that
has storage buffers (vertex: set 0 against set 1 uniform buffers; fragment:
set 2 against set 3 uniform buffers), the first storage buffer's SPIR-V binding
(the samplers and storage textures before it) must equal that stage's
uniform-buffer count. SDL binds vertex buffers at `[[buffer(14)]]` and up, so
vertex-stage buffer bindings must stay below 14.

Declare samplers as combined `sampler2D`. Separate `texture2D`/`sampler` objects
each take their own SPIR-V binding, so the texture and sampler indices diverge
and SDL's pairing of sampler `n` with texture `n` breaks.

A shader whose layout cannot meet those rules needs explicit MSL resource
remapping; the installed `spirv-cross` CLI has no resource-remap option. The
options are SDL_shadercross (SDL-aware reflection; not a current build
dependency) or a small build-time tool that drives the `spirv-cross` C API's MSL
resource-binding calls (`spvc_compiler_msl_add_resource_binding`).

Each `shader_programs` stage sets `msl_entry_signature`: the exact generated MSL
entry-point parameter list, from `main0(` through the closing `)`. spirv-cross
emits it on one line, so an added, removed, reordered, or re-indexed resource
changes it, and the build's check-file step then fails `zig build shaders`. A
comptime check in `build.zig` requires every stage to set it. This guard exists
because Metal binds a mismatched slot silently and only rejects duplicate
indices at shader creation. When a shader's resources change, confirm the new
layout follows the rules above, then copy the new signature from the generated
`.msl`.

Windows DXIL uses the HLSL generated by `spirv-cross` and compiled with
`dxc -E main -T vs_6_0` or `ps_6_0`.

## Debug Overlay

Press F2 to toggle the yellow FPS overlay. It reports render-loop cadence, not
the fixed update tick rate. The overlay uses drawable coordinates so its
SDL3_ttf texture remains independent of game scaling, and it scales font size by
the drawable-to-window pixel ratio for high-DPI displays. The overlay renders
through the asset-backed text service and bundled default font.
