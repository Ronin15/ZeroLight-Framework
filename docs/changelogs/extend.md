# Extend Changelog

Branch: `extend`

Range: `main..extend`

Base: `e6bec53` (`Merge pull request #4 from Ronin15/emerge`)

Tip: `f0bf703` (`docs, skills, and steering guidance updated for current state of the project`)

## Summary

`extend` builds on the gameplay-systems foundation with the first AI intent
processor, a main-menu/settings flow, and the startup runtime asset catalog. It
adds stable sprite/audio IDs for hot paths, keeps menu and audio interaction
inside existing state and app-service boundaries, and tightens benchmark,
architecture, and guidance docs around the current AI, asset, and renderer
contracts.

## Highlights

- Added Slice 14 AI intent processing with `AiAgent` component data,
  deterministic `MovementIntent` output through `SimulationFrame`, and serial,
  fixed-worker, and adaptive benchmark coverage.
- Reworked AI separation around a transient spatial grid with bounded neighbor
  sampling, independent separation/intent adaptive tuning, and explicit future
  guidance for staged scalable perception, pathfinding, and rule processors.
- Added Slice 16 main-menu and settings states using the existing state stack,
  named UI actions, text service, logical renderer drawing, and fixed-step audio
  command buffer for live gain changes.
- Made the main menu the default startup state and launched gameplay through
  state transitions instead of booting directly into `GameDemoState`.
- Added Slice 17 startup runtime asset catalog with stable `SpriteAssetId` and
  `AudioAssetId` values, manifest-declared demo assets, sprite preload through
  `AssetCache`, and audio preload through `AudioService`.
- Changed gameplay/render/audio paths to resolve stable asset IDs through
  `RuntimeAssets` instead of doing string path lookup or carrying live renderer
  or mixer handles through `DataSystem`.
- Preserved primitive sprite fallback for unavailable declared sprites and
  tightened missing-asset behavior so missing content is recorded without
  aborting startup while fatal preload errors roll back retained resources.
- Updated benchmarks and workflow guidance for AI workloads, multi-stage
  adaptive tuning, and the collision broadphase/narrowphase reporting contract.
- Refreshed README, AGENTS.md, architecture, state/input, rendering/assets,
  workflow, roadmap, and repo-local skill guidance to match the current repo
  identity and durable ownership boundaries.

## Commit List

- `2fe1d72` implemented slice 14 -- needs review and AI needs threaded re-vamp
- `e10ec8f` implemented slice 16 main menu and settings states and basic ui structureing
- `5fad1ca` pause can only be entered during gameplay
- `b0de1d6` branch review changes
- `a0f011e` collision refactor and multple thread system tuners
- `cb36961` thread system algo cleanup
- `1d52e3f` more thread system tunning
- `8f219c7` final thread system tunning tweak and doc bench update for dual tunners
- `68244d3` thread system and collision system review fixes. Strong 50k dense perf at mean 3.77ms
- `9ffeb95` roadmap 17 slice updated content loading
- `fd6e5f2` slice 17 implemented and texture release segfault fixed
- `6daf484` text service cleanup
- `dbbf550` text service clean up
- `5d28483` review fixes
- `a206b2d` docs update
- `db9b7b8` fixed a unit test failure as expected, for missing sprites
- `f0bf703` docs, skills, and steering guidance updated for current state of the project
