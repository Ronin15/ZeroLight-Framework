# Expand2 Changelog

Branch: `expand2`

Range: `main..expand2`

Base: `73e8ae9` (`updated changelog`)

Tip: `53e5b6c` (`expand2 review and fixes applied`)

## Summary

`expand2` turns the post-`world` framework into a harder, wider engine slice:
the persistent `DataSystem` component store splits into an owned subpackage,
a shared per-frame `SpatialIndexSystem` replaces per-system grid construction
for AI separation, NPCs gain their own Z-level column and can autonomously
traverse ramps/holes independent of the player's floor, entities gain a
faction/stance model, AI wander noise moves onto a deterministic per-entity
RNG facility, and the GPU tilemap path from `world` gets two rounds of
hardening (draw-order correctness, then vertical-window scaling toward
~120-level worlds). The branch closes with a full review pass: a multi-agent
review of the entire `main..expand2` diff surfaced 26 confirmed defects and
gaps, all fixed and re-verified in a single closing commit (`53e5b6c`) —
real bugs (a dangling self-pointer, a missed component-sync path, a
zero-input panic, a silently-discarded sprite override, an unproven event
capacity budget), a dead pathfinding signal removed outright, an unscoped
per-step traversal pass tightened to skip dormant entities, and a batch of
missing `FailingAllocator` proofs and test-hygiene violations closed to match
this project's coding standards.

The branch keeps the durable direction from prior branches: persistent
gameplay facts stay in `DataSystem`, per-step communication stays in typed
`SimulationFrame` streams, SDL/GPU/audio resources stay behind app/render/asset
services, and hot processors continue to work over dense SoA slices with
deterministic merge points — extended here with a shared spatial index and a
counter-based RNG as new reusable primitives other systems can build on.

## Highlights

- Split `src/game/data_system.zig` (3,694 lines) into an owned subpackage,
  `src/game/data_system/` (`system.zig`, `types.zig`, `movement.zig`,
  `collision.zig`, `structural.zig`, `visual.zig`, `agents.zig`,
  `faction_level.zig`), fronted by a thin re-export facade.
- Added `src/game/systems/spatial_index.zig` (Slice 28): a shared per-frame
  spatial grid built once and consumed by AI separation, with serial and
  threaded build paths and its own benchmark group.
- Landed Slice 25E: NPCs get a per-entity `world_level` column, path
  cross-level, and traverse ramps/holes autonomously through
  `DigController.applyEntityPlaneTraversal`/`simulation_pipeline
  .applyNpcPlaneTraversal`, independent of the player's floor.
- Added `src/game/faction.zig` (Slice 26): a `Faction` enum, `Stance` enum,
  and a const-evaluated relationship matrix queried by `stance(a, b)` with no
  hashing or allocation on hot paths.
- Added `src/core/rng.zig` (Slice 27): a stateless, splittable, counter-based
  RNG keyed by `(seed, entity_index, step, salt)`, giving AI wander noise
  thread-count/order-independent determinism; migrating onto it fixed a real
  bug (wander direction never resampled) and a follow-up quantized `step`
  into epochs to avoid per-tick jitter.
- Landed Slice 23A (GPU tilemap draw-order/upload-cycle/tile-edit-batching
  fixes) and Slice 23B (`DenseLayerRenderWindow`, replacing a hard 16-layer
  cap so the dense tilemap path scales toward ~120 vertical levels).
- Reworked `src/game/render_prep.zig` (860 lines) with a sparse/dynamic
  depth-interleaved submission path (`submitLayeredWorld`) and threaded a
  new `src/benchmarks/render_game_prep.zig` production-scale render-prep
  benchmark (replacing the older `render_prep.zig` benchmark).
- Threaded the initial nav-graph build (`nav_graph.zig`/`nav_grid.zig`)
  across worker threads for multi-level worlds, with a fast memset path for
  uniform-fill dense layers and a serial/threaded parity test.
- Expanded `src/game/systems/ai.zig` (705 lines) and `steering.zig` (146
  lines) for faction-aware perception, the shared spatial-index gather, and
  RNG-backed wander behavior.
- Reduced the default procedural world footprint from 512×512 to 256×256 to
  save memory, and moved demo-state perf logging, nav sizing, and atlas
  validation into their owning modules.
- Closed the branch with a full review-and-fix pass (`53e5b6c`): see
  "Review Fixes" below.

## Data System Split

- `src/game/data_system.zig` shrank from a 3,694-line monolith to a thin
  facade re-exporting the subpackage in `src/game/data_system/`.
- `system.zig` (2,212 lines) owns the entity slot table, structural-command
  preflight/commit seam, and cross-component sync helpers.
- `types.zig`, `movement.zig`, `collision.zig`, `visual.zig`,
  `faction_level.zig`, and `agents.zig` each own one dense
  `std.MultiArrayList` component store and its accessors, matching this
  project's SoA-storage conventions.
- `structural.zig` owns `StructuralCapacityProjection`/structural-command
  reservation sizing, kept symmetric across every component kind added since
  `world` (including the new `world_level`/`faction` columns).

## Spatial Index, AI, Steering, And RNG (Slices 26-28)

- `SpatialIndexSystem` builds one shared uniform grid per frame
  (`SpatialCellRange`/`SpatialEntry` rows) with a SIMD-vectorized
  `assignCellsDense` cell-assignment pass (4-lane, scalar tail) and serial
  and threaded build entry points that are proven to agree.
- AI separation (`ai.zig`) queries this shared index instead of building its
  own; the population/skip-predicate contract between `ai.zig`'s own gather
  and the spatial index's gather is documented and unit-tested, with a
  cheap runtime assert added in the closing review pass (Debug/ReleaseSafe
  only, per this project's `assumeCapacity`/ReleaseFast model).
- Collision broadphase deliberately stayed on its own tuned sweep-and-prune
  rather than moving onto the shared grid, to avoid regressing an existing
  incremental-sort optimization.
- `src/game/faction.zig` adds a `Faction` enum and `Stance` enum with a
  const-evaluated 4×4 relationship matrix, giving perception and behavior a
  cheap `stance(a, b)` prerequisite query.
- `src/core/rng.zig` adds a stateless, splittable RNG (`mix64` avalanche
  mixer, `uniformF32`, `boundedU32`, `unitVec2`) keyed by
  `(seed, entity_index, step, salt)`, with parity/decorrelation/distribution
  tests. Wander behavior in `steering.zig` moved onto it, fixing a real bug
  (direction previously never resampled) before a follow-up quantized the
  `step` key into epochs (default 300 steps) so resampling doesn't jitter
  every tick.

## Pathfinding And NPC Z-Traversal (Slice 25E)

- The initial nav-graph build (`nav_graph.zig`, `nav_grid.zig`) now threads
  per-level world-obstacle masking and component construction across worker
  threads for multi-level worlds via a new `navLevelMaskJob`, with
  `align(64)` padding on threaded scratch buffers to avoid false sharing and
  a fast memset path when a dense layer is a uniform fill tile.
  A serial/threaded parity test proves identical initial graphs.
- NPCs gained a per-entity `world_level` column and path/traverse
  cross-level independent of the player's floor, landing the bulk of Slice
  25E's autonomous-Z-traversal contract.
- `PathView` grew a `next_cell_level` field intended to let steering
  anticipate a level transition before physical arrival — this was found in
  the closing review to have zero production consumers (the real transition
  mechanism runs entirely through `DigController.applyEntityPlaneTraversal`
  against physical world geometry) and was removed as dead code; see
  "Review Fixes."

## GPU Tilemap Rendering (Slices 23A/23B)

- Slice 23A fixed three correctness bugs in the retained GPU tilemap path
  from `world`: draw-list sorting that assumed pre-sorted static groups
  (flipping underground planes), `cycle=true` on tile-storage uploads
  (ping-ponging GPU buffers and flipping tiles on dig), and pre-acquire tile
  edits silently dropped on skipped frames. Fixed with a stable draw-list
  sort, `cycle=false` tile storage, and edits batched into the post-acquire
  copy pass.
- Slice 23B replaced the hard 16-dense-layer submission cap with a
  `DenseLayerRenderWindow` that submits only the layers near the player
  (default 6 below), so the dense tilemap path scales toward ~120 vertical
  levels without submitting every layer at/below the active level.
- `src/render/gpu/buffer.zig` and `texture.zig` picked up matching GPU
  resource-lifetime tightening alongside these fixes.

## Render Prep, Sprite Batching, And Renderer

- `render_prep.zig` gained `submitLayeredWorld`, interleaving world sparse
  decoration and the dynamic entity/particle depth-bucketed stream in
  ascending world-z order (sparse wins on a depth tie).
- `sprite_batch.zig` replaced a debug-only overflow assert with a real,
  fail-loud `error.SpriteCommandOverflow` return so a reserved-capacity
  overrun degrades safely in every build mode, not just Debug.
- `renderer.zig` added `kOverlayCommandHeadroom`, a second post-render
  reservation top-up so the debug overlay's own sprite commands stay inside
  the same grow-only `command_high_water` budget as gameplay/stacked-UI
  commands.
- `src/benchmarks/render_game_prep.zig` (846 lines) replaced the older
  `render_prep.zig` benchmark with a production-scale fixture and dense-8/
  16/32 surface and deep bench groups.

## World, Simulation Pipeline, And Digging

- `world_system.zig` (583 lines) gained the dense-layer render window
  plumbing, catalog-cached sprite source rects (precomputed at build time
  instead of looked up from tileset metadata at runtime), and the default
  procedural footprint dropped from 512×512 to 256×256 tiles to save memory.
- `simulation_pipeline.zig` (281 lines) and `dig_controller.zig` gained the
  NPC plane-traversal/gating stages driving Slice 25E's autonomous
  Z-traversal.
- Demo-state perf logging, nav-grid sizing, and atlas validation moved out
  of `game_demo_state.zig` into their owning modules, continuing the
  ownership-discriminator pattern from `world`.

## Game States, Assets, And Runtime Preload

- `game_demo_state.zig` (1,211 lines) split its demo spawn logic into
  compact and non-compact branches (`worldUsesCompactDemoSpawn`) so small
  test worlds and large gameplay worlds get differently-scaled spawn
  layouts through the same component-wiring path.
- `runtime_assets.zig` (220 lines) and `cache.zig` (215 lines) reworked
  startup sprite preload into a batched, transactional path
  (`preloadSpritesBatch`/`insertStartupTexturesBatch`) replacing per-sprite
  cache acquisition, with rollback on a failed batch insert.
- `atlas_meta_common.zig` gained shared JSON-asset-loading helpers reused by
  world tileset and sprite atlas metadata loading.

## Core, Benchmarks, Testing, And Tooling

- `src/core/simd.zig` and the benchmark suite (`ai.zig`, `nav_update.zig`,
  `scope.zig`, `spatial_index.zig` (new), `render_game_prep.zig` (new),
  `runner.zig`, `suite.zig`) grew to cover the new spatial-index, RNG, and
  faction-aware AI paths.
- `.codex/skills/` and `AGENTS.md` were removed in favor of `.claude/agents/`
  and `CLAUDE.md`, continuing the tooling consolidation started on `world`.

## Documentation

- `docs/framework-implementation-slices.md` (777 lines) records Slices
  23A, 23B, 25E, 26, 27, and 28 as landed, with 25E carrying an explicit
  superseding note about the `next_cell_level` removal.
- `docs/architecture.md`, `docs/rendering-assets-shaders.md`,
  `docs/simulation-tiers-and-pipeline.md`, and `docs/coding-standards.md`
  were updated to describe the data-system subpackage split, the dense
  render window, NPC Z-traversal, and (in the closing review pass) a
  clarified, concretely-bounded rule for when a test may call a
  production world-build entry point with a minimal config.

## Review Fixes

The branch closes with `53e5b6c`, a single commit landing every finding from
a full multi-agent review of the entire `main..expand2` diff (26 confirmed,
3 plausible-and-real, all fixed and reverified with `zig build verify`):

- **Real bugs**: a dangling self-pointer in `WorldSystem.adoptTilesetMeta`
  (cached across a by-value struct move); `setMovementBody` not syncing a
  pre-existing `world_level` onto a newly-appended scope row (mirroring the
  `has_primitive_visual` sync that already existed); a zero-input panic in
  `autoSizedMaxNavMemoryBytes` (`std.math.ceilPowerOfTwo` asserts before it
  can return `error.Overflow`); `preloadSpritesBatch` silently re-deriving a
  sprite's `source_rect` from the canonical manifest instead of the
  caller-supplied override; and a real event-stream capacity gap (the
  shared per-step `range_count` reservation was sized independently of the
  event-capacity budget it was meant to cover).
- **Dead code removed**: `PathView.next_cell_level` and its stitched-cache
  helpers, found to have zero production consumers, deleted along with
  their dedicated tests; `docs/framework-implementation-slices.md`'s Slice
  25E section annotated to explain the removal instead of left claiming a
  landed contract against deleted code.
- **Perf fix**: `gateNpcEntitiesToWalkableTiles`/`applyNpcPlaneTraversal`
  now skip dormant-tier entities (provably zero-behavior-change for active
  tiers, since movement itself never touches a dormant entity's position),
  closing an unscoped per-step pass that every sibling stage already gated.
- **Coding-standards gaps closed**: added the `FailingAllocator` regression
  proofs this project's standards mandate for every
  reserve/`assumeCapacity` pairing (`render_prep.zig`'s
  `collectDynamicRecords`, a two-stage sprite-command reserve in
  `renderer.zig` backed by both an empirical proof and a `comptime` guard,
  `sprite_batch.zig`'s overflow path, and a SIMD-vs-scalar parity test for
  `spatial_index.zig`'s vectorized cell assignment); eliminated the last
  production-scale procedural world builds from `zig build test`
  (`loading_state.zig`, `game_demo_state.zig`) by threading an explicit
  `WorldBuildConfig` through the real code path instead of hand-waving a
  fixture; restored non-compact spawn-path test coverage that had silently
  narrowed to the compact branch only; and a small cleanup sweep (hand-rolled
  lerp replaced with `math.lerpVec2`, a duplicated read-file primitive
  consolidated into `AssetStore.readAlloc`, stale doc/comment drift fixed,
  a dead parameter and a dead import removed).
- Every fix was independently re-reviewed by a second review pass, which
  itself caught and closed two further gaps: a `FailingAllocator` test that
  didn't block `resize_fail_index` (missing a Linux `mremap` growth path)
  and a regression test that read through a pointer without asserting its
  identity, silently passing against the pre-fix buggy behavior too.

## Follow-Up Work Left Explicit

`expand2` lands substantial data-layout, spatial-index, faction/RNG, and
NPC-traversal foundation work, but several follow-ups remain visible in the
roadmap and this branch's own review notes:

- Slice 23A/23B are landed and runtime-validated on `expand2` but not yet
  merged into `world`; the optional linear `mergeDrawList` micro-opt named
  in both slices remains open.
- `spawnTestSquaresCompact`'s own `tunnel_tile` parameter is now unused
  (exposed, not introduced, by this branch's `spawnDemoMover` cleanup) —
  left untouched as out of scope for the closing review pass; worth a
  follow-up pass if `game_demo_state.zig`'s demo-spawn helpers get revisited.
- `docs/coding-standards.md`'s "minimal `WorldBuildConfig`" test-entry-point
  rule now has a concrete ceiling (≤16×16 tiles, ≤1 underground level,
  matching `worldUsesCompactDemoSpawn`'s own threshold) but is otherwise
  unenforced by tooling; a lint/CI check would close the remaining gap
  between "documented" and "guaranteed."
- `renderer.zig`'s two-stage sprite-command reserve is provably
  allocation-free only because `kStackedStateUiHeadroom >= 2 *
  kOverlayCommandHeadroom` today (backed by a `comptime` assert) — either
  constant shrinking without the other adjusting would silently reopen a
  render-hot-path allocation, caught only by the `comptime` guard and its
  paired `FailingAllocator` test, not by an independent design invariant.
- Dormant-entity movement fast-path behavior (carried forward from `world`)
  and dig/pathfinding ramp-churn tuning remain open per prior branches'
  follow-up notes.

## Commit List

- `7216bf4` render efficientcy re-work
- `315b9ee` more render tuning
- `d7cea0a` render bug fixed
- `b9bd3f4` docs: roadmap 23A/23B scaling notes and tilemap cycle policy
- `09567a7` test run fixes
- `2999c84` 23b implemented
- `1fa2606` updates and reviews for 23b
- `72d130b` digging bugs
- `ebb08c0` dig bug fixed
- `928d976` review fixes
- `adbd594` sice 26 completed and reviewd
- `ef859db` archived codex files
- `32cb88a` zig allocator true up
- `8847d15` round 2 memeory contracts and allocation true up. Hardening run time
- `b547118` Fix render-game-prep deep bench crash: entities weren't placed on
  the player's world level
- `9db551f` Data System split refactor
- `76287f9` updated roadmap accuracy.
- `a74a5d7` Slice 27 implemented and reviewed
- `819ebc0` steering waggle fix
- `13091b9` slice 28 completed and reviewed
- `1c066c1` changed the default world layout from 512 to 256 to save some
  memory
- `d8cd656` Move demo-state perf logging, nav sizing, and atlas validation to
  owning modules
- `53e5b6c` expand2 review and fixes applied
