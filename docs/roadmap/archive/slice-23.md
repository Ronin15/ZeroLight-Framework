## Slice 23: Atlas-Backed World Rendering Addition

Goal: add a minimal world/tile rendering foundation that uses the existing
world tileset atlas metadata and render-prep boundary. This gives scoped
simulation concrete world, chunk, and visibility data to consume later.

Current foundation:

- Runtime assets preload atlas textures and metadata for `.world_tileset`,
  `.grim_characters`, and `.grim_items`.
- `world_tileset_meta.zig` validates tile JSON and exposes tile lookup by name,
  id, category, animation, and source rect.
- Explicit render-prep phases own transient draw-record ordering and `Renderer`
  owns SDL_GPU submission.

Architecture notes:

- World/tile state lives in the state-owned `WorldSystem`, not in renderer
  resources and not inside `SimulationPipeline`.
- `GameDemoState` is constructed from Engine-owned `RuntimeAssets` through a
  loading state; world construction requires `.world_tileset` metadata and
  world rendering requires the `.world_tileset` texture.
- The runtime loading path now uses the Engine-owned `ThreadSystem` for
  deterministic procedural chunk generation; it does not create a separate
  worker pool.
- Persistent world storage is SoA: stable tile IDs, atlas source-rect columns,
  level z metadata, dense/sparse tile columns, and chunk/visibility columns.
- Gameplay viewport size is separate from world size. The first large runtime
  world is a finite 512x512 tile segment with camera-visible chunk rendering,
  intended as a foundation for later larger-map streaming.
- The first world renderer exposes enough chunk/visibility shape for the later
  scoped tier slice, but it does not enable simulation tier filtering by itself.
- Demo actors can use character atlas entries with primitive-visual rectangle
  fallback; world tiles do not have a rectangle fallback path.

Checklist:

- [x] Add a small world/tile data owner with tile IDs, world coordinates, and
      chunk/visibility metadata suitable for later `ActiveRegion` construction.
- [x] Render at least one world/tile layer from `.world_tileset` atlas metadata
      through ordered render prep.
- [x] Keep tile draw ordering explicit by `RenderOrder` and stable source rects.
- [x] Add tests for tile lookup, strict missing atlas texture behavior,
      actor primitive fallback, and deterministic queue record order.
- [x] Add tests for ThreadSystem-driven procedural chunk generation,
      camera-follow world bounds, visible chunk culling, and world-tile
      pathfinding blockers.
- [x] Update rendering/assets docs and roadmap cross-links after runtime wiring
      lands.

Acceptance checks:

- [x] Demo/world rendering uses atlas metadata instead of per-tile textures or
      runtime string lookup.
- [x] World/chunk/visibility data exists in a form the later scoped tier slice
      can consume without ownership rewrites.
- [x] Render-prep benchmarks still measure the queue-to-batch path outside the
      production render path.
- [x] `zig build test`, `zig build check`, and `zig build verify` pass.

Slice 23 adds `WorldSystem` as `GameDemoState`-owned SoA world storage and
render prep. `LoadingState` now bridges menu activation to runtime-asset-backed
gameplay construction, fixing the old direct demo-state constructor boundary.
The demo renders a dense atlas-backed floor layer plus sparse world decoration
through ordered render prep, carries level/chunk/visibility columns for future
scoped simulation, and keeps `SimulationPipeline` focused on fixed-step entity
processors. Demo actors now reference `.grim_characters` atlas entries while
retaining primitive visuals as missing-character placeholders.
The runtime loading path now builds a 512x512 procedural segment with
`ThreadSystem` chunk batches, follows the player with an interpolated sub-pixel
camera, and renders only camera-visible chunks. World blocking tiles are folded
into the pathfinding nav-grid rebuild alongside static entity obstacles.

Follow-up slices **23A** (render hardening landed on `expand2`) and **23B**
(multi-depth render scaling for ~120 levels) extend this foundation; see below.


