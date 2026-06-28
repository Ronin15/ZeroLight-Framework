# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project Snapshot

ZeroLight-Framework is a 2D game framework built on **Zig 0.16** and
**SDL3 / SDL_GPU**. It runs a thin executable timing layer over a fixed-step
**60Hz** simulation, a state stack with policy-driven input routing, and
atlas-backed runtime assets addressed by stable IDs. Gameplay is data-oriented:
dense **SoA** stores for entities and world data, with multithreaded and
SIMD-aware processors for movement, AI, steering, collision, and particles.

## Source Of Truth (`docs/`)

Read the doc that owns the area before editing — these are canonical, not notes.

- `docs/architecture.md` — source layout, ownership boundaries, frame flow.
- `docs/coding-standards.md` — Zig style, performance, comments, tests.
- `docs/development-workflow.md` — build options, commands, shaders, packaging.
- `docs/setup.md` — toolchain and SDL3 dependency setup per platform.
- `docs/state-stack-and-input.md` — state contracts, transitions, input routing.
- `docs/rendering-assets-shaders.md` — SDL_GPU rendering, resources, shaders.
- `docs/simulation-tiers-and-pipeline.md` — fixed-step simulation contracts.
- `docs/atlas-asset-workflow.md` — atlas packing, JSON sidecars, art swaps.
- `docs/framework-implementation-slices.md` — live roadmap (Slice 8 hardening,
  frontier slices 18+, priorities, suggested order); settled slices 0–7 and
  9–17 are in `docs/framework-implementation-slices-archive.md`.
- `docs/changelogs/` — per-phase feature changelog summaries.
- `docs/reviews/` — module deep-dive reviews (e.g. pathfinder).

## Module Ownership (`src/`)

Add new code under the module that owns the concern. Do not move ownership
boundaries just to make a local change easier.

- `src/main.zig` — thin entry/timing: builds `AppConfig`, inits `Engine`, runs
  the fixed-step loop. Keep it thin.
- `src/config.zig` — shared `AppConfig`, presentation options, clear color, and
  thread-system defaults consumed by build options and runtime startup.
- `src/app/` — app coordination: `engine.zig`, `state.zig` (state stack),
  `input.zig` + `input_router.zig`, `time_loop.zig` (60Hz), `frame_pacer.zig`,
  `pause_controller.zig`, `audio.zig`, `thread_system.zig`, `resolution.zig`,
  `runtime_perf_log.zig`.
- `src/render/` — SDL_GPU rendering: `renderer.zig` is the game-facing facade;
  also `camera.zig`, `resources.zig`, `sprite_batch.zig`, `text.zig`, debug
  overlay. Do **not** import `src/render/gpu/*` outside the render/platform
  boundary.
- `src/assets/` — runtime asset catalog, safe path resolution, image decode,
  cache, `manifest.zig` (stable sprite/audio IDs), atlas metadata.
- `src/game/` — gameplay: states/menus, `world_system.zig`, `data_system.zig`,
  `simulation*.zig` (pipeline, scope), `player.zig`, pipeline-owned controllers
  `dig_controller.zig`/`audio_controller.zig`, `render_prep.zig`/`render_depth.zig`,
  and `systems/` (movement, ai, steering, collision, collision_response, particle,
  and the `pathfinding/` subpackage fronted by `pathfinding.zig`). The
  `PathfindingSystem` owns nav-invalidation classification and the post-commit nav
  reaction; the state only invokes it via the pipeline.
- `src/core/` — shared math, SIMD, logging. `src/platform/` — SDL imports and
  GPU smoke probe. `src/benchmarks/` — CPU gameplay/render-prep benchmarks.

## Working Rules

- Read the live owning files before editing. Do not rely on stale roadmap memory
  or prior chat summaries for exact implementation details.
- Follow `docs/coding-standards.md`: `zig fmt`, lowerCamelCase functions/vars,
  PascalCase types, direct declaration imports, explicit error sets.
- Treat performance as correctness on hot/frame-adjacent paths. Hot paths must
  be **allocation-free after init/reserve/warmup**. Avoid per-frame string
  lookups, hash-map dispatch, broad dynamic dispatch, formatted logging, and
  resource churn unless the cost is measured, bounded, and isolated.
- Keep runtime asset paths relative and traversal-safe. Persist gameplay data by
  stable asset IDs (e.g. `SpriteAssetId`, `AudioAssetId`), not string paths,
  live renderer/SDL handles, or prepared draw records.
- Production contracts expose runtime concepts only. Do **not** add test-only
  enum tags, union payloads, marker fields, fake stages, or fixture hooks to
  production APIs. Tests use private helpers, local fixtures, mocks, or real
  payloads.
- Treat implementation slices as full features: runtime behavior, docs, tests,
  and acceptance checks all integrated before marking complete.
- Never edit generated output: `zig-out/` and `.zig-cache/`.

## Build & Validation Commands

Run `zig build verify` before considering a slice or broad change complete.

```sh
zig build            # build and install app, runtime assets, and shaders
zig build run        # build, install, and run the app
zig build dev        # shaders + assets + run (edit/run loop)
zig build check      # compile coverage (game, gpu-smoke, bench) — no install
zig build test       # run Zig unit tests
zig build bench      # CPU gameplay and render-prep benchmarks
zig build verify     # full gate: check + test + shader compile + atlas lint
zig build fmt        # format build.zig, build.zig.zon, and src/
zig build shaders    # compile GLSL sources to platform GPU shaders
zig build gpu-smoke  # display-gated renderer pipeline smoke (needs a display)
zig build package    # install selected-mode binaries and runtime assets
zig build assets-lint # lint runtime atlases and source sprite consistency
zig build fetch-sdl  # fetch pinned Windows SDL packages into Zig's package cache
```

Default optimize mode is `Debug`. Use `--release=safe|fast|small` only for
release candidates. Minimum toolchain is **Zig 0.16.0**.

## Claude Code Working Practices

- Run `zig build fmt` after edits and `zig build verify` before finishing.
- Prefer `zig build check` for fast compile feedback while iterating; reserve
  `zig build gpu-smoke` for actual display/GPU validation.
- Reuse existing utilities and patterns before adding new code — search the
  owning module first.
- Keep changes scoped to the requested slice. Do not reformat or refactor
  unrelated code.
