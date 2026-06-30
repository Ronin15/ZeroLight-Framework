# World Changelog

Branch: `world`

Range: `main..world`

Base: `c132a5e` (`Merge pull request #6 from Ronin15/world_and_assets`)

Tip: `0d25c04` (`full linux compile debug fix.`)

## Summary

`world` turns the post-`world_and_assets` framework into a runnable multi-level
world with atlas-backed tilemap rendering, a split and threaded pathfinding
package, scoped simulation tiers, and a state-owned `SimulationPipeline`. The
branch lands Slice 23 (world/tile rendering and `WorldSystem`), Slice 22
(`SimulationPipeline` extraction and tier/scope scaffolding), Slice 24 (real
scoped gathers, stagger, and cube LOD tier policy), and the Slice 25 navigation
redesign (per-level nav grids, nav graph, corridor caches, threaded solver, and
event-driven incremental rebuilds). It adds `LoadingState`, `DigController`, and
`AudioController` so `GameDemoState` stops owning orchestration, world
construction, and domain side effects. Rendering moves to a dense tilemap GPU
pipeline plus an AoS vertex layout in `SpriteBatch`; `render_queue.zig` is
removed. Dense gameplay stores migrate to `std.MultiArrayList`, benchmarks gain
`nav-update` and `scope` groups, docs split settled slices into an archive, and
a Linux Debug LLVM/DWARF workaround closes a bool-vector compile crash introduced
by SIMD visibility work.

The branch keeps the durable direction from prior branches: persistent gameplay
facts stay in `DataSystem`, per-step communication stays in typed
`SimulationFrame` streams, SDL/GPU/audio resources stay behind app/render/asset
services, and hot processors continue to work over dense SoA slices with
deterministic merge points.

## Highlights

- Added `src/game/world_system.zig` as `GameDemoState`-owned SoA world storage
  with dense/sparse tile columns, per-level bands, chunk coordinates,
  visibility windows, procedural chunk generation through `ThreadSystem`, and
  nav-blocker integration for pathfinding rebuilds.
- Added `LoadingState` so menu activation constructs gameplay from
  `Engine`-owned `RuntimeAssets` instead of booting `GameDemoState` directly
  from the main menu.
- Landed Slice 23 atlas-backed world rendering: dense floor tilemaps and sparse
  decoration through ordered render prep, camera-follow visible-chunk culling,
  and a 512×512 procedural runtime segment as the first large-world foundation.
- Added tilemap GPU shaders (`assets/shaders/tilemap.vert/frag.glsl`),
  `tilemap_pipeline.zig`, and renderer wiring so each dense layer submits one
  retained world-space tilemap quad with tile ids read from a storage buffer.
- Extracted `SimulationPipeline` (`simulation_pipeline.zig`) as the demo state's
  fixed-step owner for movement, collision, AI, steering, pathfinding, and
  scope orchestration while `GameDemoState` keeps input, audio, particles,
  structural-commit reactions, and render enqueue.
- Landed Slice 24 scoped simulation through `SimulationScopeSystem`
  (`simulation_scope.zig`): tier/chunk/stagger dense columns on movement rows,
  scoped gathers for movement/collision/AI, cube LOD tier policy from the camera
  visible region, deferred `set_simulation_tier` commands, and debug scope stats.
- Split monolithic `pathfinding.zig` into `src/game/systems/pathfinding/` with
  `system.zig`, `nav_graph.zig`, `nav_grid.zig`, `solve.zig`, `caches.zig`,
  `group_field.zig`, `nav_memory.zig`, `scratch.zig`, `types.zig`, and a thin
  facade re-export.
- Completed the Slice 25 navigation redesign: per-level nav grids, abstract nav
  graph, corridor/result caches, group fields, memory budgets, threaded solver
  batches, incremental nav rebuilds from world/dig edits, and z-aware level
  links for multi-floor worlds.
- Added `DigController` and moved digging, ramp traversal, and obstacle edits out
  of `GameDemoState`; dig changes now feed pathfinding invalidation and world
  tile updates through the controller seam.
- Added `AudioController` so gameplay audio reactions leave the demo state and
  route through a pipeline-owned controller with the existing `AudioService`
  contract.
- Reworked rendering around an AoS GPU vertex layout, removed `render_queue.zig`,
  tightened `sprite_batch.zig` and `renderer.zig`, and added GPU review fixes for
  buffer/device/pipeline paths.
- Migrated dense gameplay stores to `std.MultiArrayList` across `DataSystem`,
  `WorldSystem`, particles, collision gather buffers, and related hot paths.
- Expanded `src/core/simd.zig` and `src/core/math.zig` with reusable gather,
  normalize, sin/cos, and tail helpers; added scalar-to-SIMD visibility and
  tier-policy paths with a Linux Debug LLVM/DWARF-safe visibility rewrite.
- Added benchmarks `nav_update.zig` and `scope.zig`, repointed pathfinding
  benches to production-scale cases, and added `tools/bench_run.py` for scripted
  benchmark runs.
- Split completed roadmap slices into
  `docs/framework-implementation-slices-archive.md` and refreshed architecture,
  simulation-tier, rendering, and review docs under `docs/reviews/`.
- Replaced `.grok/skills/` with `.claude/agents/`, added `CLAUDE.md`, and
  updated agent workflow guidance.
- Forced LLVM/LLD on native Linux GNU Debug builds via `build.zig` and fixed a
  Debug-only LLVM abort from `@Vector(4, bool)` mask stores in chunk visibility.

## World System And Tilemap Rendering

Slice 23 is the branch's largest gameplay-facing addition.

- `WorldSystem` owns persistent world SoA columns: tile ids, atlas source rects,
  level z metadata, dense layer bands, sparse decoration rows, chunk x/y, and
  `chunk_visible`.
- Runtime loading builds a procedural 512×512 segment with `ThreadSystem`
  chunk batches instead of a separate worker pool.
- Camera-follow world bounds drive `setVisibleChunksForWorldRect`, cached
  visible-sparse counts, and later scoped-simulation `ActiveRegion` inputs.
- Dense layers render as one GPU tilemap quad per layer; sparse tiles still use
  the sprite path through render prep.
- World blocking tiles fold into nav-grid rebuilds alongside static entity
  obstacles.
- `LoadingState` validates `.world_tileset` metadata/texture availability before
  constructing `GameDemoState`.

The render path changed materially in later commits:

- `render_queue.zig` was removed; render prep now feeds `Renderer`/`SpriteBatch`
  directly with explicit ordering.
- `sprite_batch.zig` rotates quad corners through SIMD helpers and writes an AoS
  vertex layout for GPU submission.
- `renderer.zig` gained tilemap draw submission, retained layer quads, and
  tighter resource ownership around world rendering.

## Simulation Pipeline And Scoped Tiers

Slice 22 and Slice 24 move fixed-step orchestration out of the demo state.

- `SimulationPipeline` owns reusable systems and the concrete demo processor
  order: scope prep, AI, steering, pathfinding, movement, collision, and
  collision response.
- `simulation_scope.zig` at the game level holds tier constants, `ActiveRegion`,
  and `tierForChunkDistance`; `SimulationScopeSystem` in
  `src/game/systems/simulation_scope.zig` owns the per-step scope work.
- Scope metadata lives in dense columns beside movement rows (`tier`,
  `chunk_x/y`, `level`, `stagger_phase`, `always_active`).
- Movement and collision gate on tier only; AI gates on cognition tier, camera
  halo chunks, and stagger phase; steering stays transitively scoped through AI
  intents.
- Cube LOD tier policy demotes entities by chebyshev chunk distance with a
  per-level penalty so off-level rows read as far even when x/y are near.
- Tier changes emit deferred `set_simulation_tier` structural commands and
  commit only at the state seam.
- `runtime_perf_log.zig` reports per-tier/per-stage scope stats for Debug
  diagnosis.

Known limitation carried forward: the contiguous SIMD movement fast path only
fires when zero entities are dormant; a steady-state LOD world with any dormant
entities falls back to indexed gather/scatter for the whole movement population.

## Pathfinding Redesign

The branch replaces the single-file pathfinder with a full subpackage and lands
most of Slice 25.

- Public API remains `src/game/systems/pathfinding.zig` as a re-export facade.
- `nav_grid.zig` owns per-level blocked masks and world-to-cell mapping.
- `nav_graph.zig` owns abstract graph construction, incremental patch/remask
  rebuilds, and threaded chunk updates.
- `solve.zig` owns A*, stitched corridors, fallback routing, and hard-path
  budget behavior carried forward from Slice 20.
- `caches.zig`, `group_field.zig`, and `nav_memory.zig` own corridor/result
  caches, group-key tables, and memory-budget gates.
- `system.zig` coordinates requests, solver threading, invalidation from world
  and dig edits, and `SimulationFrame` path-result streams.
- Digging, ramps, and open-floor edits trigger nav invalidation and rebuild
  refinement across many tuning passes.
- `docs/reviews/pathfinder-review.md` records the module review; findings M1–M11
  and most low-priority items were fixed with `zig build verify` gates.

Benchmarks now treat navigation as a first-class stress surface:

- `src/benchmarks/nav_update.zig` measures incremental nav rebuild throughput.
- `src/benchmarks/pathfinding.zig` was repointed to production-scale fixture
  sizes and threaded solver cases.
- `src/benchmarks/scope.zig` covers scoped gather and tier-policy behavior.

## Controllers And State Refactor

`GameDemoState` shrank as domain work moved to owner modules.

- `DigController` owns dig input, tile edits, ramp traversal, and the gameplay
  reactions that used to live inline in the demo state.
- `AudioController` owns gameplay audio command emission from simulation events.
- `GameDemoState` now constructs/owns `WorldSystem`, `SimulationPipeline`, and
  the controllers while keeping app/state boundaries for input, pause, render
  enqueue, and structural-commit reactions.
- Multiple review passes removed duplicated math, tightened standards, and moved
  pathfinding buffer ownership out of the demo state.

## Data Layout And SIMD

- Dense stores migrated to `std.MultiArrayList` in `DataSystem`, `WorldSystem`,
  particles, collision gather/scratch buffers, and related modules.
- `src/core/simd.zig` gained gather/scatter, normalize-or-zero, sin/cos,
  reciprocal-sqrt, tail helpers, and lane utilities reused by collision,
  movement, scope, and sprite batch code.
- `world_system.zig` vectorized chunk visibility with an i32 `@select` chain to
  avoid LLVM Debug DWARF failures from `@Vector(4, bool)` mask `&` and lane
  stores on native Linux GNU builds that force LLVM.

## Build, Tooling, And Platform

- `build.zig` forces `use_llvm` and `use_lld` on native Linux GNU targets for
  Debug reliability and registers tilemap shader compilation beside the existing
  sprite shader path.
- `tools/bench_run.py` supports scripted benchmark invocation; `tools/README.md`
  documents tooling usage.
- `.grok/skills/` was removed; `.claude/agents/` and workflow scripts replaced
  repo-local Grok guidance.
- GPU review docs were added under `docs/reviews/` for device/buffer/pipeline/
  texture paths.

## Documentation

Project documentation was updated to describe the branch's current behavior:

- `docs/framework-implementation-slices-archive.md` archives settled slices 0–7
  and 9–17; the live roadmap now focuses on frontier slices 8+.
- `docs/framework-implementation-slices.md` records landed status for Slices 22,
  23, 24, and 25 with acceptance themes and known limitations.
- `docs/architecture.md` reflects `WorldSystem`, `SimulationPipeline`,
  controllers, tilemap rendering, and scoped simulation ownership.
- `docs/simulation-tiers-and-pipeline.md` documents the implemented scope/tier
  contracts and `SimulationScopeSystem` behavior.
- `docs/rendering-assets-shaders.md` covers tilemap shaders, dense layer quads,
  and the queue-free render path.
- `docs/reviews/pathfinder-review.md`, GPU review summaries, and MAL review notes
  capture module deep dives from branch review passes.
- `CLAUDE.md`, `AGENTS.md`, and `.claude/agents/` were refreshed to point at
  canonical docs instead of duplicating guidance.

## Follow-Up Work Left Explicit

`world` lands substantial world, navigation, and scoped-simulation foundation
work, but several follow-ups remain visible in the roadmap and review notes:

- Slice 8 still has residual shader/material registry hardening tracked in the
  live roadmap.
- Slice 23A GPU tilemap render hardening (depth order, `cycle=false` tile
  storage, batched copy pass) is implemented on `expand2` and should merge
  before raising world depth count.
- Slice 23B multi-depth dense-layer render scaling (~120 levels, vertical
  submit window) is planned before large underground world build.
- Slice 25E NPC autonomous z-traversal remains a separate acceptance-checked
  slice before multi-floor emergent scenarios depend on it (entity level/cull;
  separate from 23B floor render window).
- Dormant-entity movement fast-path behavior should be revisited so indexed
  gather/scatter is not triggered by a single far-away dormant body.
- Dig/pathfinding interaction around ramps and rebuild churn was tuned heavily
  but may still need gameplay refinement beyond current correctness gates.
- Atlas tooling, richer material registries, lighting/effects, and threaded GPU
  command-buffer work remain separate frontier slices.
- `collision.zig` still uses `@Vector(4, bool)` mask `&` and lane branches; if
  Linux Debug LLVM regressions reappear, those sites may need the same int-mask
  pattern as chunk visibility.

## Commit List

- `3d44fd8` world_update
- `9b4eaa6` basic world gen, loading state, using art assets updated
- `3e2c4d9` world heading in the right shape. MAY DISCARD
- `aaa1a6b` reduced player speed
- `b63ba99` removed grok dir
- `819befa` claude tooling
- `795203e` updated tooling documentation
- `521785a` project review changes
- `b9d359a` world rendering efficiency gains are massive from this fix.
- `febbf01` fixed pathfinding for current state
- `f54cd75` roadmap update
- `21b8a26` 25a
- `c9fa7dd` 25b and c
- `1aacef8` pathfinder re-work but needs performance tunning
- `a52e381` pathfinder optimizations
- `e1197e5` more pathfinding optimization needed around auto scaling.
- `4b605d9` more optimizations
- `182196c` final pathfinding fix for now.
- `2d1359d` docs update with new slices
- `a723821` updated collisions hand rolled gather 4 into SIMD.zig and added some math fucntions to math.zig so they can be resused
- `c8c9835` updated review guidance around math and simd enforement and useage
- `c172d82` review fixes
- `8f9b8cd` final reivew cleanup and hardening
- `22ce18d` fixed perf regressions and kept net good changes
- `a0b371e` pahse 1 render clean up
- `5cb07cc` phase 2 render re-work
- `6481045` world cache work - phase 3
- `0aed9fa` pahse 4 completed render and world cache re-writes
- `04ab679` pathfinding steering fix to measure progress to waypoint instead of end goal
- `846b729` pahse 1 of another renderer world tile fix
- `d18a8e2` phase 2 after AB review
- `b4133fc` claude agent logging guidance updated
- `07a119e` phase c done
- `d736049` tilemape re-work complete
- `026c38d` renderer optimization
- `dc051f7` full project review cleanup and fixes
- `71391c9` big review and standars fixes
- `c53ac75` fixed failing test and fixed more duplicated math
- `f1dd9c1` dig contoller base implemented
- `437b257` open digging working kind of. need more tweaking
- `257c462` dig down ramp up working ok, needs more refinement.
- `cfdacc0` dig pathfinding rebuild still needs work
- `6342b25` perf ok for pathfinder
- `1b1dbb9` pathfinder split
- `e418f68` pathfinder test re-alignment
- `d3a15f3` refining nav rebuilds
- `3e7c2f5` more optimizations
- `6a1305c` updated nav bench for realy prod scaling cases
- `ddf8fe9` fixing pathfidner items that landed in the game state and buffer correctness
- `16093a8` pathfinder solver threading implementation
- `adcbaa5` more thread tuning
- `823d92c` bench and nav threaded tuning and corectness fixed
- `b0570b1` review changes hardening, and trueing up
- `89186b8` bench mark re-purpose and fixing
- `3666850` hardening and correctness fixes
- `646b937` performance fixes
- `cd63a6c` bench updates
- `d4a92ba` ramp crash fix in here
- `09adc09` pathfinder tunning
- `4a307b9` more fixes
- `f55e44b` all fixes but the last M8 M9 structural fixes
- `b0ded0f` m8 m9 changes L7
- `d77e87b` docs, guidance, and claude.md clean up
- `efa3780` retructiing items out of game demo state to thier respective owners
- `507cb5a` move dig logic to dig controller out of the game state
- `b7589b0` more cleanup
- `dec6d73` architecture assement completed, to keep project online, ready for next slice implementations.
- `c795ee6` the rest of slice 8 implemented and reivewed
- `28184a2` marked slice 8 done
- `bb6c0c1` scoped simulation tiers
- `7e2c60a` simd helpers for scalar work
- `e8a7195` AoS GPU render layout re-write
- `ed53572` sprite batch clean up
- `ac0d8bd` docs update for sim tiers
- `20331eb` sim tier review fixes
- `6fb8e6b` Zig MultiArrayList refactor
- `34d5672` MAL refactors to clean up code
- `258dc44` Address MAL review findings
- `277728e` review summary
- `9bd0fb0` gpu review fixes
- `c68856a` linux compile crash fix LLVM -0Debug DWARF bug
- `0d25c04` full linux compile debug fix.