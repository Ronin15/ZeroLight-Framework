# ZeroLight-Framework

Agent instructions for this repository. ZeroLight-Framework is a 2D game
framework built on **Zig 0.16** and **SDL3 / SDL_GPU**. It runs a thin
executable timing layer over a fixed-step **60Hz** simulation, a state stack
with policy-driven input routing, and atlas-backed runtime assets addressed by
stable IDs. Gameplay is data-oriented: dense **SoA** stores for entities and
world data (`DataSystem`, `WorldSystem`), with a state-owned
`SimulationPipeline`, scoped simulation tiers, and multithreaded/SIMD processors
for movement, AI, steering, collision, pathfinding, and particles.

Do not duplicate full repo documentation here. Read the canonical docs below
for details and update those docs when architecture, workflow, or roadmap
content changes.

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
- `docs/framework-implementation-slices.md` — live frontier roadmap (open slices,
  priorities, Scaling Gaps, suggested order); settled slices (0–8, 9–17,
  18–25E, 26–31, 34, 36) are in
  `docs/framework-implementation-slices-archive.md`.
- `docs/changelogs/` — per-branch feature changelog summaries (latest:
  `docs/changelogs/world.md`).
- `docs/reviews/` — module deep-dive reviews (pathfinder, GPU, and similar).

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
- `src/game/` — gameplay: states/menus, `world_system.zig`, the `data_system/`
  subpackage fronted by `data_system.zig`, `simulation*.zig` (pipeline, scope),
  `player.zig`, pipeline-owned controllers
  `dig_controller.zig`/`audio_controller.zig`, `render_prep.zig`/`render_depth.zig`,
  and `systems/` (movement, ai, steering, collision, collision_response, particle,
  perception, and the `pathfinding/` subpackage fronted by `pathfinding.zig`).
  The `PathfindingSystem` owns nav-invalidation classification and the
  post-commit nav reaction; the state only invokes it via the pipeline.
- `src/core/` — shared math, SIMD, logging. `src/platform/` — SDL imports and
  GPU smoke probe. `src/benchmarks/` — CPU gameplay, pathfinding, nav-update,
  scope, perception, and render-prep benchmarks.

## Working Rules

- Read the live owning files before editing. Do not rely on stale roadmap memory
  or prior chat summaries for exact implementation details.
- Follow `docs/coding-standards.md`: `zig fmt`, camelCase functions, snake_case
  variables/fields, PascalCase types, direct declaration imports, explicit error
  sets.
- Treat performance as correctness on hot/frame-adjacent paths. Hot paths must
  be **allocation-free after init/reserve/warmup**, and every such claim needs
  a `std.testing.FailingAllocator` proof test, not just a comment — this
  project ships **ReleaseFast**, which strips the assert backing
  `assumeCapacity`, so an unproven reserve is a silent-corruption risk, not a
  missed optimization. Avoid per-frame string lookups, hash-map dispatch,
  broad dynamic dispatch, formatted logging, and resource churn unless the
  cost is measured, bounded, and isolated.
- **Per-query/per-frame work budgets (search node caps, solve ceilings, and
  similar) must be fixed constants — never derived from or scaled to world
  size, map size, cell count, portal count, or any other measured "current
  scale."** Worlds vary in size; a budget that scales with it means
  correctness/performance silently depends on which map happens to be loaded.
  This is a load-bearing, explicitly tested invariant in several modules (grep
  for `independent of` and `regardless of world size` before touching a
  budget/capacity constant — e.g. `src/game/systems/pathfinding/`'s abstract
  A* node budget and `nav_graph.zig`'s incremental-dig chunk-patch tests). When
  a fixed budget is chronically insufficient for a hard case, the fix is
  graceful degradation (deterministic deferral / a bounded retry ladder that
  gives up cleanly) or an algorithmic change that keeps the SAME fixed budget
  sufficient — never a bigger number picked because one particular map needed
  it.
- Threaded writes into a shared buffer must be partitioned (disjoint
  per-worker/per-range slots) and reserved before dispatch, never after or
  during. Allocators are explicit fields set at `init`, never a global reached
  for mid-function. See `docs/coding-standards.md` for the full
  allocator-discipline rules.
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
- **Tests only: keep `WorldSystem`/`DataSystem` test fixtures at the smallest
  size that still exercises the behavior under test** — do not build out a
  full/large game world per test. `chunksX`/`chunksY` is `ceilDiv(width,
  chunk_size_tiles)`, so a `1x1` (or otherwise minimal) `WorldSystem` still
  yields exactly one real chunk, enough for chunk-gate/visibility tests
  without a bigger tile grid. Reserve a larger populated world for the one
  test that specifically needs structural growth/capacity behavior at scale
  (e.g. a `FailingAllocator` reserve-proof test). Fast, small fixtures keep
  `zig build test` fast as the suite grows.

## Build & Validation

Run `zig build verify` before considering a slice or broad change complete.

```sh
zig build            # build and install app, runtime assets, and shaders
zig build run        # build, install, and run the app
zig build dev        # shaders + assets + run (edit/run loop)
zig build check      # compile coverage (game, gpu-smoke, bench) — no install
zig build test       # run Zig unit tests
zig build bench      # CPU gameplay and render-prep benchmarks
zig build verify     # full gate: check + test + shaders + atlas + idiom lint
zig build fmt        # format build.zig, build.zig.zon, and src/
zig build shaders    # compile GLSL sources to platform GPU shaders
zig build gpu-smoke  # display-gated renderer pipeline smoke (needs a display)
zig build package    # install selected-mode binaries and runtime assets
zig build assets-lint # lint runtime atlases and source sprite consistency
zig build idiom-lint # lint Zig naming, stdlib currency, unsafe catch unreachable
zig build fetch-sdl  # fetch pinned Windows SDL packages into Zig's package cache
```

Default optimize mode is `Debug`. Use `--release=safe|fast|small` only for
release candidates. **Packaged builds ship `ReleaseFast`** — see
`docs/development-workflow.md` for the required pre-release ReleaseSafe
soak-test gate this implies. Minimum toolchain is **Zig 0.16.0**.

## Cursor Setup (`.cursor/`)

| Layer | Path | Role |
|-------|------|------|
| Global contract | `AGENTS.md` | Repo guardrails, docs routing, build commands |
| Workflows | `.cursor/skills/zig-workflows/SKILL.md` | When to delegate; inline vs subagent |
| Subagents | `.cursor/agents/zig-*.md` | Specialist behavior (implement, review, debug, design) |
| File rules | `.cursor/rules/*.mdc` | Auto-attach for `src/game/**` and `src/render/**` |
| Module presets | `.cursor/skills/zig-workflows/module-presets.md` | Pathfinder multi-review units |

Workflows in `zig-workflows` auto-invoke when tasks match. You can also ask directly
("use zig-review-specialist", "review my branch", "fix this test failure").

| Workflow | Subagent | When |
|----------|----------|------|
| Design | `zig-design-specialist` | Before non-trivial gameplay/ECS/pipeline work |
| Implement | `zig-specialist` | Zig implementation in owning modules |
| Debug | `zig-debug-specialist` | Build/test/shader/SDL/GPU/runtime failures |
| Review | `zig-review-specialist` | PR/diff review |
| Architecture assessment | `zig-design-specialist` | Emergent-gameplay readiness report |
| Module review | `zig-review-specialist` × N | Module-wide pass (pathfinder preset) |

## Agent Working Practices

- Run `zig build fmt` after edits and `zig build verify` before finishing.
- Prefer `zig build check` for fast compile feedback while iterating; reserve
  `zig build gpu-smoke` for actual display/GPU validation.
- Reuse existing utilities and patterns before adding new code — search the
  owning module first.
- Keep changes scoped to the requested slice. Do not reformat or refactor
  unrelated code.
- Always run a targeted benchmark with `zig build bench -- --group <name>`
  (optionally `--case`/`--items`) unless explicitly told to run the full suite.
  Do not run the whole `zig build bench` and filter its output.
- **`zig build bench` is for perf and OOM/leak-sweep checks; `zig build test`
  is for fast contract/correctness checks only.** Never measure or report
  performance/timing by hand-rolling a timer inside a `zig build test` test —
  not even temporarily, not even with `-Doptimize=ReleaseFast`. All
  performance numbers must come from `zig build bench`, which already
  provides warmup, repeated iterations, and adaptive-settle statistics
  (`src/benchmarks/suite.zig`) that a one-off timed test block does not.
  **Test code must never call into `src/benchmarks/*.zig` functions at all**
  — not just to avoid hand-timing: a benchmark file's fixture builders
  (`createFixture`, `initFixture`, etc.) and case runners build large
  synthetic fixtures meant for throughput measurement, not fast correctness
  checks, and calling them from `zig build test` makes the whole suite slow
  even without any timing code in the test itself. The one exception is
  `suite.zig`'s own tests, which cover only its pure utility logic (arg
  parsing, formatting, alignment math) against hand-built stubs, never a real
  fixture. If a correctness property belongs in production code, test it in
  the owning production module with a small hand-built fixture; if it's
  benchmark-fixture-specific (e.g. does this fixture shape still assert
  correctly), rely on the module's own internal `std.debug.assert` firing
  during an actual `zig build bench` run instead of wrapping it in a test. If
  a perf question needs answering and no benchmark case covers it yet, add or
  extend one under `src/benchmarks/` and run it via `zig build bench`.
