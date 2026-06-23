# World And Assets Changelog

Branch: `world_and_assets`

Range: `main..world_and_assets`

Base: `c219a26` (`grok skill updates`)

Tip: `fee2671` (`project review fixes more hardening and stablizing`)

## Summary

`world_and_assets` turns the post-`extend` framework into an atlas-backed world
and render-prep slice. The branch adds filename-driven atlas packing and lint
tooling, runtime JSON metadata loaders for world tiles and sprite sheets, stable
atlas handles in the startup manifest, gameplay-facing asset references and
world depth bands, a queue-first render-prep path, typed simulation intent
streams and domain events, pathfinding hardening budgets, and Debug runtime perf
logging with SDL window-event attribution. Later stabilization passes tightened
state-transition dispatch, render-queue capacity behavior, asset-root
validation, DataSystem ingress validation, GPU upload sizing, and atlas-lint
dependency boundaries.

The branch keeps the durable direction from `extend`: persistent gameplay facts
stay in `DataSystem`, per-step communication stays in typed `SimulationFrame`
streams, SDL/GPU/audio resources stay behind app/render/asset services, and hot
processors continue to work over dense SoA slices with deterministic merge
points.

## Highlights

- Added a filename-driven atlas asset pipeline under `tools/` with order
  manifests for world tiles, characters, and items, Python pack/export/lint
  helpers, and generated runtime atlases under `assets/sprites/`.
- Added `docs/atlas-asset-workflow.md` and wired `zig build verify` to run
  `tools/lint_assets_if_changed.py` so registered runtime atlases and source
  sprite consistency are checked during verification.
- Added `atlas_meta_common.zig`, `world_tileset_meta.zig`, and
  `sprite_atlas_meta.zig` so gameplay resolves tiles and sprites by name through
  load-time hash indexes and JSON sidecars instead of hardcoded grid slots.
- Extended `manifest.zig` and `RuntimeAssets` with `.world_tileset`,
  `.grim_characters`, and `.grim_items`, including metadata path/kind validation
  and startup preload of atlas metadata beside sprite textures.
- Extended `DataSystem` with `AssetReference`, `PrimitiveVisual` depth bands,
  `position_z`, and structural commands for asset/visual updates so render prep
  can resolve stable sprite IDs without storing renderer handles in gameplay
  storage.
- Added `render_depth.zig`, `render_prep.zig`, and `render_queue.zig` so states
  emit transient draw records through `RenderQueue`, world z combines entity
  `position_z` with depth bands, and `Renderer`/`SpriteBatch` consume an
  already ordered stream.
- Completed Slice 7 parallel CPU render prep for the current sprite/rect path,
  including render-prep benchmarks, deterministic serial/parallel parity checks,
  and removal of renderer fallback sorting that hid producer-order bugs.
- Added `SimulationIntent` as a typed movement-intent stream in
  `SimulationFrame`, keeping high-volume intent traffic on specialized streams
  instead of collapsing it into generic event payloads.
- Landed Slice 20 navigation hardening and Slice 21 typed simulation events,
  including structural lifecycle signals, navigation invalidation from static
  obstacle changes, event capacity/stats, and deterministic range-owned merge
  behavior.
- Hardened `PathfindingSystem` with true-A* fixtures, per-step fallback solve
  budgets, deterministic pending retention, and benchmark visibility for
  deferred and executed fallback work.
- Added `runtime_perf_log.zig` for Debug perf metrics, including fixed-step
  processor counters, render-prep stats, and SDL presentation/window event
  attribution for resize, fullscreen, display, focus, visibility, and move
  events.
- Hardened event dispatch so queued state transitions remain deferred until an
  event batch finishes, preventing stack mutation while SDL events are still
  being routed.
- Hardened render-queue growth after structural entity changes by reserving
  capacity from the current primitive-visual rows before render enqueue and
  covering large visual growth without hot render-path allocation.
- Added validation for relative, traversal-safe asset roots, movement-body and
  primitive-visual ingress, and structural-command prevalidation so bad payloads
  fail before mutating existing rows.
- Hardened SDL_GPU upload helpers with checked `u32` byte/pitch conversions and
  copy-pass cleanup on upload failures.
- Reworked atlas lint to derive runtime atlas checks from `manifest.zig`, read
  PNG dimensions directly for the registered runtime sidecars, and require
  Pillow only when source-asset comparison needs the packer.
- Added `docs/coding-standards.md`, slimmed `AGENTS.md` back to routing and
  guardrails, and refreshed repo-local skills so future work uses canonical
  docs for style, performance, comments, tests, and generated-output rules.
- Updated demo rendering so player trail particles draw behind the player
  sprite, world entities enqueue through render prep, and gameplay docs record
  the current processor order, atlas workflow, and Slice 22 pipeline planning.
- Performed multiple review passes across render, simulation, assets, threading,
  comments/import cleanup, and durable guidance updates in `AGENTS.md` and
  project skills.

## Atlas Asset Pipeline

The branch introduces a full art-to-runtime workflow for world tiles, character
sprites, and item sprites.

- `source_assets/` holds artist-facing loose PNGs organized by category.
- `tools/atlas_orders/` declares pack order, animation wiring, and autotile
  metadata for each sheet.
- `tools/pack_atlas.py`, `export_source_sprites.py`, `gen_atlas_orders.py`,
  `generate_world_tileset.py`, `generate_grim_sprites.py`, and shared helpers
  build runtime PNG/JSON pairs under `assets/sprites/`.
- `tools/lint_assets_if_changed.py` validates registered runtime atlases and
  source consistency when assets change.

Gameplay identity is filename-driven within each atlas: PNG stems become lookup
names, categories come from source subfolders, and stable `SpriteAssetId` handles
in `manifest.zig` identify the sheet. World tiles enforce a 32×32 grid contract;
character and item frame sizes are declared per atlas in the order manifest.

## Runtime Asset Metadata

Runtime loading now treats atlas JSON as first-class data:

- `world_tileset_meta.zig` exposes tile lookup by name/id, source rectangles,
  animation tables, and walkability/blocking properties from
  `world_tileset.json`.
- `sprite_atlas_meta.zig` exposes character/item sprite lookup by name/id and
  source rectangles from `grim_characters.json` and `grim_items.json`.
- `atlas_meta_common.zig` centralizes shared parsing, layout validation, and hash
  index construction.
- `RuntimeAssets` preloads metadata during startup and exposes typed accessors
  for world tileset and sprite-atlas metadata slots.

Missing IDs or names return null instead of guessing grid positions. Manifest
validation rejects atlas path or `sprite_asset_id` mismatches at load time.

## Render Prep And World Depth

Render submission now follows a queue-first contract:

- Game states build transient `RenderQueue` records during render.
- `render_prep.zig` resolves `AssetReference` sprites through `RuntimeAssets`,
  falls back to primitive rects when a declared sprite is unavailable, and
  computes `RenderOrder` from `position_z` plus `WorldDepth` bands.
- `render_depth.zig` defines ordered bands for floor, obstacle, actor, effect,
  and marker content with saturating z offsets.
- `SpriteBatch` and `Renderer` consume only the ordered queue stream; parallel
  CPU prep snapshots texture metadata, expands vertices through `ThreadSystem`,
  and merges worker output deterministically on the main thread.

The demo now renders mixed world-z entities through this path, with player trail
particles sorted behind the player sprite via depth-band ordering.

## Simulation Contracts

### Typed Intent Streams

`SimulationFrame` now carries a dedicated `SimulationIntent` stream as a typed
union over `MovementIntent`. Steering and other producers can emit final movement
intents through the same range-owned count/prefix/write pattern used by
navigation intents, path requests, contacts, and structural commands.

### Domain Events And Navigation Hardening

Slice 21 adds lower-volume typed domain signals inside `SimulationFrame`,
including structural lifecycle/component change events and
`NavRegionInvalidated` when static obstacle-affecting structural changes require
a pathfinding grid rebuild. Events use deterministic range-owned writes,
explicit per-step capacity, stats, and dropped diagnostic counts.

Slice 20 hardens rare true-A* fallback work with per-step solve budgets,
deterministic pending retention for overflow, fixed-capacity cache coverage, and
benchmark rows that separate fast-path throughput from executed, deferred, and
remaining fallback work.

## Runtime Diagnostics

`runtime_perf_log.zig` adds opt-in Debug perf logging on a fixed interval. It
records fixed-step processor counts, render-prep and sprite-batch stats, and SDL
presentation/window event counters so resize, fullscreen, display, focus,
visibility, and move churn can be correlated with frame/update/render timing.

## Stabilization And Hardening

The post-draft stabilization pass closed several correctness and maintenance
gaps that were found after the original changelog was written.

- `Engine.processEvents` now applies queued state transitions only after the SDL
  event polling batch completes, and `StateStack` has coverage proving that
  modal pushes queued during event handling do not change the active stack until
  `applyTransitions`.
- `GameDemoState` now reserves `RenderQueue` capacity immediately after
  structural commits and before render submission. Rendering iterates the
  current `DataSystem` primitive-visual rows, special-cases the player marker
  explicitly, and keeps particles as their own transient render producer.
- `AppConfig.validate` rejects empty, absolute, `.` and `..` asset roots; GPU
  smoke now uses the build-option asset root and validates the config before
  creating SDL resources.
- `DataSystem` validates `MovementBody` and `PrimitiveVisual` payloads on public
  setters and structural-command batches, including finite positions,
  velocities, sizes, colors, marker settings, and non-negative speeds or marker
  dimensions.
- `src/render/gpu/buffer.zig` and `src/render/gpu/texture.zig` reject upload
  sizes that overflow SDL's `u32` fields and close active copy passes on error
  paths.
- `tools/lint_assets_if_changed.py` no longer depends on a hardcoded atlas
  registry or Pillow for ordinary runtime atlas validation; it derives runtime
  atlas specs from `manifest.zig` and reads PNG headers directly.
- `build.zig` now carries the selected log level into the benchmark executable
  instead of forcing benchmark builds to `warn`.

These changes are deliberately framed as hardening, not new feature scope: they
preserve the branch behavior while making ownership, validation, and failure
paths stricter.

## Documentation

Project documentation was updated to describe the branch's current behavior:

- `docs/atlas-asset-workflow.md` documents the filename-driven atlas pipeline,
  directory layout, identity contract, and art swap workflow.
- `docs/architecture.md` reflects queue-first render prep, world depth ordering,
  atlas metadata resolution, simulation intent streams, and Slice 22 pipeline
  planning.
- `docs/rendering-assets-shaders.md` reflects atlas-backed runtime assets,
  metadata loaders, and render-queue submission.
- `docs/development-workflow.md` documents atlas lint in `zig build verify` and
  the `render-prep` benchmark group.
- `docs/framework-implementation-slices.md` records completed Slices 7, 20, and
  21, confirms Slice 8 acceptance checks, and splits the next work into Slice 22
  pipeline/tier-scope scaffolding, Slice 23 atlas-backed world rendering, and
  Slice 24 scoped simulation tiers.
- `docs/simulation-tiers-and-pipeline.md` now documents the implemented
  `SimulationFrame` stream/event/structural-command contracts, while durable
  tier and pipeline direction lives in `docs/architecture.md` and roadmap
  sequencing lives in `docs/framework-implementation-slices.md`.
- `docs/coding-standards.md` is the canonical style, performance, comment,
  test, and generated-output standard referenced by `AGENTS.md` and repo-local
  skills.
- `AGENTS.md` and project skills were refreshed with comment/import guidance and
  durable ownership rules, then later trimmed to concise routing guidance backed
  by canonical docs.

## Follow-Up Work Left Explicit

`world_and_assets` lands substantial atlas, metadata, and render-prep
foundation work, but several follow-ups remain visible:

- Atlas tooling and generated art still need consolidation passes before the
  pipeline is treated as fully productionized.
- Slice 22 `SimulationPipeline` and scoped simulation tiers are designed but not
  yet extracted from `GameDemoState.update`. The roadmap now separates
  behavior-preserving pipeline/tier-scope scaffolding from later scoped runtime
  filtering.
- Tile rendering, richer material registries, lighting/effects, and threaded GPU
  command buffers remain separate slices that must preserve the queue-first
  ordering contract.
- SpriteBatch high-water/capacity policy, text-cache lifetime policy,
  shader/material registry guardrails, and remaining manual registry guardrails
  remain explicit hardening follow-ups.
- Navigation cache aging, incremental A* continuation, and module splitting stay
  outside the completed Slice 20 hardening scope.
- A typed simulation event layer should grow with new domain payloads only as
  concrete systems land, not through placeholder producers.

## Commit List

- `c50ae82` asset pipeline, world, items, chars and tooling all created. Needs more work to consolidate
- `2ee0d9c` pathfinder system hardened.
- `7b68a92` world and render prep changes
- `1a48fe7` updated roadmap and docs
- `ee2b8ff` simualation intent streams added. more world/systems support
- `8935a2b` review changes
- `ef61207` review fixes
- `f8b4faf` remove project guidance from zig packaging
- `2183b57` rendered the palyer trail particles behind the player sprite
- `bbd6531` runtime perf logging added!
- `c240cc1` render fixes
- `925fa86` added SDL event tracking for window changes to perf render time metrics
- `ac1bf57` full branch review changes
- `fb979a7` comments added and import cleanup
- `e535c80` added comments and comments durable rules
- `ee92092` reame and change log update
- `724a906` frame work hardening
- `2285b8b` agent workflow optimizing
- `fee2671` project review fixes more hardening and stablizing
