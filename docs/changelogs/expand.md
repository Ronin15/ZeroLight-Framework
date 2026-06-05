# Expand Changelog

Branch: `Expand`

Range: `main..Expand`

Base: `c14d25a` (`Merge pull request #2 from Ronin15/reshape`)

Tip: `945ed46` (`overall architecture update`)

## Summary

`Expand` builds on the reshaped app/render/game split and turns it into a
working engine slice: named input routing, pause and visibility handling,
logical-resolution presentation, pre-spawned worker coordination, deterministic
gameplay data storage, SIMD-aware movement and particle processing, asset and
texture resource management, asset-backed text rendering, and a split render
pipeline with sprite batching and GPU helpers.

## Highlights

- Added input routing and state-policy wiring so raw SDL events feed named
  actions, held gameplay input, and one-frame app/debug commands separately.
  Modal and opaque states now block held gameplay input cleanly, and the pause
  path releases held movement instead of synthesizing it on resume.
- Added logical-resolution and viewport policy so the renderer computes fit,
  integer-fit, stretch, and overscan presentation from drawable size and window
  size. World and logical draws are transformed through the presentation while
  overlay drawing can stay in drawable pixels.
- Added a pre-spawned `ThreadSystem` that runs synchronous parallel batches,
  reuses parked workers across frames, lets the main thread participate while
  waiting, and exposes deterministic range splitting for CPU processors.
- Added `src/game/data_system.zig` as the persistent gameplay storage
  foundation, with entity IDs, component membership masks, dense SoA columns,
  stale-ID rejection, and explicit state-local ownership.
- Added `src/core/simd.zig` plus SIMD-aware movement and particle processors
  that operate directly on SoA slices with scalar tails, serial fallback paths,
  and threaded range execution for larger batches.
- Added `src/render/resources.zig`, `src/render/sprite_batch.zig`, and GPU
  helper modules so renderer resources use generational texture IDs, sprite
  batching stays allocation-free after warmup, and texture upload/validation
  stays under render ownership.
- Added `src/render/text.zig` and bundled `assets/fonts/NotoSansMono-Regular.ttf`
  so runtime text rendering uses asset-backed fonts, cached text textures, and a
  centralized SDL3_ttf lifecycle instead of probing system fonts.
- Added `src/assets/cache.zig` so installed PNGs can be loaded once and reused
  through stable renderer resource IDs, with traversal-safe asset path
  validation left in `AssetStore`.
- Reworked `src/render/renderer.zig` into a smaller facade around sprite
  commands, resource lookup, presentation, and frame submission while keeping
  the GPU path SDL_GPU-first.
- Tightened platform logging, SDL wrapper behavior, and GPU smoke wiring while
  keeping the runtime behavior visible through `src/core/logging.zig` scopes.
- Expanded compile/test coverage through `src/tests.zig`, `src/root.zig`, and
  the module tests covering input routing, resolution math, resource IDs,
  asset cache behavior, SIMD helpers, movement, particles, and render prep.
- Expanded the architecture, state/input, rendering, workflow, setup, and
  implementation-slice docs so the branch records the runtime rules that were
  actually implemented.

## Commit List

- `81c9e7b` scaffolding for expansion
- `027bb2b` added roadmap for features.
- `b7706f6` linux debug build work around. For now.
- `a0a9c81` updated roadmap slice for threading system
- `f023b2d` first pass thread system core
- `cf48138` thread system pass v1
- `ff28fe2` doc update and refined main readme
- `74bb89c` doc readme update
- `eee9e7a` reshape change log
- `cc4606a` roadmap update
- `b9d5da1` review fixes
- `d206bb0` readme feature update
- `dcc6db1` first pass at logging and updated slices to be full implementations
- `8795fff` updated project for implemented logging
- `009d02d` added some logging
- `b53e903` sdl window flags translation and subsystems logging
- `23ba87c` logging review fixes
- `ae513f5` input routing implemented
- `8a3b4e4` renamed background workers to worker threads to make more sense
- `e97e34b` scale and resolutuion handling and some text resizing when screen
  changes ha been implemented
- `eb660de` render fix
- `5ee2021` render review fix
- `e4fa0b5` renderer sepration after stable
- `4f9bdb6` updated to 3 frames in flight
- `6ddbecd` slice 3 complete
- `4b712be` slice 4 complete
- `440aa06` slice 5 completed
- `fed855c` slice 6 complete
- `9da870d` slice 9 implemented
- `a04a4ef` Data Storage system implemented.
- `6c6cd5a` udpated roadmap
- `695888e` slice 11 prep done
- `f86be25` movement system added and fully intergrated with Data system and
  Simd!
- `0e45e89` particle system implemented, simd helpers added to simd.zig
- `8bb4892` rename of demo state to game demo state
- `5e17199` update architecture doc
- `945ed46` overall architecture update
