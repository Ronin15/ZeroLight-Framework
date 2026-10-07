# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project Snapshot

ZeroLight-Framework is a 2D game framework built on **Zig 0.17** and
**SDL3 / SDL_GPU**. It runs a thin executable timing layer over a fixed-step
**60Hz** simulation, a state stack with policy-driven input routing, and
atlas-backed runtime assets addressed by stable IDs. Gameplay is data-oriented:
dense **SoA** stores for entities and world data (`DataSystem`, `WorldSystem`),
with a state-owned `SimulationPipeline`, scoped simulation tiers, and
multithreaded/SIMD processors for movement, AI, steering, collision,
pathfinding, and particles.

The game built on it is dig/build with cave-ins and explosions: dense,
multi-chunk terrain change in one step is normal gameplay. Test
destruction-shaped workloads (explosion region in one step, repeated dig/fill).

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
- `docs/framework-implementation-slices.md` — roadmap **index** (ground rules,
  agent workflow, open slice table, priorities, suggested order). Each open
  slice/sub-slice is one file in `docs/roadmap/slices/slice-<id>.md`; shared
  contracts and the authoritative cross-slice tables (replay/settings/save/
  checksum versions, stage order, component tags) are in
  `docs/roadmap/tracks/` (`voidlight-port.md`, `emergent-ai.md`,
  `gameplay-direction.md`); measured pressure points are in
  `docs/roadmap/scaling-gaps.md`. To work a slice, read the index, that one
  slice file, and only the track/contract files it links. Settled slices
  (0–8, 9–17, 18–25E, 26–32, 34, 36, 37, 39–41, 45, 47, 48) are one file each
  in `docs/roadmap/archive/`, indexed by
  `docs/framework-implementation-slices-archive.md`.
- `docs/changelogs/` — per-branch feature changelog summaries (latest:
  `docs/changelogs/ai_update3.md`).
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
- **Budgets, capacities, and thresholds are three different things.**
  - **Per-step / per-query work budgets** (search node caps, solves per step,
    links/spawns folded per step, and similar) **are fixed counts — never
    derived from or scaled to world size, map size, cell count, portal count,
    or any other measured "current scale."** Frame time is constant whatever
    map is loaded; a budget that scales with the world makes big maps slower
    per frame and makes behavior map-dependent. Use counts, not milliseconds
    (time budgets are nondeterministic). This is a load-bearing, explicitly
    tested invariant (grep `independent of` / `regardless of world size` —
    e.g. the pathfinder's abstract A* node budget and `nav_graph.zig`'s
    incremental-dig chunk-patch tests). When a fixed budget is chronically
    insufficient, fix it with graceful degradation (deterministic deferral /
    a bounded retry ladder) or an algorithmic change — never a bigger number
    picked for one map.
  - **Data-structure capacities are right-sized per world instance**, never
    one fixed size for every world. Two kinds:
    - *World-extent data* (tiles, per-chunk nav, chunk tables, per-level
      data): sized exactly from the loaded world at init/load and never grown
      — dig/build changes contents, not extent.
    - *Runtime-growing data* (population, items, particles, nodes, spawned
      structures, runtime links): start at the world/content-derived size plus
      headroom, then **grow only at a designated cold point** — the
      main-thread structural-commit seam, outside threaded stages —
      geometrically and ahead of need (e.g. at a fill threshold), or use
      paged/chunked storage that adds pages without moving data where a large
      realloc would spike a frame.
    Between growth points hot paths stay allocation-free (the
    `FailingAllocator` rule still applies and proves exactly that). Capacity
    must never change behavior: no iteration order, deferral, or result may
    depend on how much is reserved. Fixed caps only for index/format widths
    (e.g. `u16`/`u32` indices, save/replay layouts) proven unreachable for the
    loaded world extent; they fail loudly at load, never at a
    gameplay-reachable point. No dig, build, cave-in, or explosion may be
    refused for capacity. Exception: cosmetic effect pools that no simulation
    reads may be fixed-capacity with deterministic overflow drop.
  - **Heuristic thresholds** (e.g. "build a group flow field above N agents")
    derive from the cost of the operation they gate (its own bounded region or
    input), never from the whole world's size.
  - **Never change a constant just to satisfy this rule.** Default is keep.
    Changing an existing budget/capacity/threshold needs a stated, concrete
    performance or efficiency benefit (memory saved, an artificial limit
    removed, fewer allocations or cache misses, simpler code) weighed against
    its cost and risk (hot-path cost, layout/format churn, proof/test churn,
    determinism).
- Threaded writes into a shared buffer must be partitioned (disjoint
  per-worker/per-range slots) and reserved before dispatch, never after or
  during. Allocators are explicit fields set at `init`, never a global reached
  for mid-function. See `docs/coding-standards.md` for the full
  allocator-discipline rules.
- Work that scales with population, terrain change, or world size ships serial
  and threaded paths from its first implementation (`docs/coding-standards.md`
  Performance).
- Write the plain, readable form first (`docs/coding-standards.md` Zig Style);
  keep comments terse.
- Keep runtime asset paths relative and traversal-safe. Persist gameplay data by
  stable asset IDs (e.g. `SpriteAssetId`, `AudioAssetId`), not string paths,
  live renderer/SDL handles, or prepared draw records.
- Production contracts expose runtime concepts only. Do **not** add test-only
  enum tags, union payloads, marker fields, fake stages, or fixture hooks to
  production APIs. Tests use private helpers, local fixtures, mocks, or real
  payloads.
- Treat implementation slices as full features: runtime behavior, docs, tests,
  and acceptance checks all integrated before marking complete.
- **No backlog dumping.** Design and review work never parks discovered
  follow-ups as bare Scaling Gaps/backlog lines. Each one becomes a Checklist
  item in its owning slice or a decision-complete new slice (Status may be
  "gated on <trigger>"). Scaling Gaps holds only measured pressure points
  awaiting a benchmark. When briefing agents, never ask them to "propose
  Scaling Gaps lines". Exception: work the owner explicitly defers goes in
  the roadmap index's **Deferred By Owner** list with its trigger; agents
  never add entries there on their own.
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

## Build & Validation Commands

Run `zig build verify` before considering a slice or broad change complete.
In a multi-commit batch, run `check` + `test` + `idiom-lint` per commit and the
full `verify` once at the end.

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
zig build fetch-sdl  # fetch pinned Windows SDL packages into zig-pkg/ and validate them
```

Default optimize mode is `Debug`. Use `--release=safe|fast|small` only for
release candidates. **Packaged builds ship `ReleaseFast`** — see
`docs/development-workflow.md` for the required pre-release ReleaseSafe
soak-test gate this implies. Minimum toolchain is **Zig 0.17.0**.

## Claude Code Working Practices

- A `PostToolUse` hook (`.claude/hooks/zig-fmt.sh`) runs `zig fmt` on each
  `.zig`/`.zon` file after Edit/Write; still run `zig build verify` before
  finishing.
- Prefer `zig build check` for fast compile feedback while iterating; reserve
  `zig build gpu-smoke` for actual display/GPU validation.
- Reuse existing utilities and patterns before adding new code — search the
  owning module first.
- Keep changes scoped to the requested slice. Do not reformat or refactor
  unrelated code.
- Always run a targeted benchmark with `zig build bench -- --group <name>`
  (optionally `--case`/`--items`) unless explicitly told to run the full suite.
  Do not run the whole `zig build bench` and filter its output.
- Benches at target scale ship with the first implementation. Large-scale
  benches are stress tests, not frame targets: weight a result by how often
  that workload really occurs at that count.
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
  fixture. If a correctness property belongs to production code, test it in
  the owning production module with a small hand-built fixture; if it's
  benchmark-fixture-specific (e.g. does this fixture shape still assert
  correctly), rely on the module's own internal `std.debug.assert` firing
  during an actual `zig build bench` run instead of wrapping it in a test. If
  a perf question needs answering and no benchmark case covers it yet, add or
  extend one under `src/benchmarks/` and run it via `zig build bench`.
- Implementation agents run sequentially in the main tree with linear commits;
  no `isolation: worktree` or merge commits. Parallelize only read-only work.

## Claude Code Tooling (`.claude/`)

- `agents/` — `zig-design-specialist` (read-only design plans), `zig-specialist`
  (implementation), `zig-debug-specialist` (build/test/runtime failures),
  `zig-review-specialist` (read-only review). Workflows reference these names
  via `agentType`; keep them stable. All run `opus`; design at `xhigh`
  effort, review/implementation/debug at `high` (review fans out across many
  workflow agents).
  **Required, not optional:** all non-trivial Zig design, implementation,
  review, and debugging goes through these agents —
  `zig-design-specialist` plans only when the design is ambiguous (clear fixes
  go straight to `zig-specialist`); `zig-review-specialist` reviews once per
  batch (findings go back to `zig-specialist`; at most one review-of-fixes
  round; adversarially verify only High/Critical findings);
  `zig-debug-specialist` for build/test/runtime failures. Do not implement
  non-trivial changes inline, and do not substitute or add generic skills or
  agents (`/code-review`, `/simplify`, generic Explore/Plan) for this repo's
  Zig work — not even alongside these agents. The main session orchestrates,
  verifies agent claims against the live code, and reports.
- `workflows/` — multi-agent passes, invoked as `/pathfinder-review`,
  `/architecture-assessment`, `/zig-best-practices-review`,
  `/zig-deep-correctness-review-pass`. Each produces a report; none edits code.
- `settings.json` — shared permissions (routine `zig build` steps and
  read-only `git` commands allowed, edits to `zig-out/` and `.zig-cache/` denied) and the `zig fmt`
  hook. Personal overrides go in the gitignored `settings.local.json`.
