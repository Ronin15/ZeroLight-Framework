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
multi-chunk terrain change in one step is normal gameplay, not an edge case.

## Source Of Truth (`docs/`)

Read the doc that owns the area before editing — these are canonical, not notes.

- `docs/architecture.md` — source layout, ownership boundaries, frame flow.
- `docs/coding-standards.md` — every technical rule: style, performance,
  budgets/capacities, threading, stage order, logging, comments, tests, benches.
- `docs/development-workflow.md` — commands, build modes, validation cadence,
  shaders, packaging.
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

Summaries only; the linked section is the rule. CS = `docs/coding-standards.md`,
DW = `docs/development-workflow.md`, IDX = the roadmap index.

- Read the live owning files before editing; never rely on stale roadmap memory
  or chat summaries for exact implementation details.
- Reuse existing utilities (search the owning module first); keep changes scoped
  to the requested slice; do not reformat or refactor unrelated code.
- Style and readability: plain form first, explicit error sets — CS § Zig Style;
  terse comments — CS § Comments.
- Hot paths are allocation-free after warmup, with a `FailingAllocator` proof
  for every reserve (ReleaseFast ships) — CS § Performance, § Allocator
  discipline.
- Work budgets are fixed counts; capacities are right-sized per world and grow
  only at the commit seam; no gameplay-reachable refusal; default keep —
  CS § Budgets, Capacities, And Thresholds.
- Threaded writes are partitioned and reserved before dispatch; scaling work
  ships serial + threaded paths — CS § Threading.
- New pipeline stages declare their contract — CS § Simulation Pipeline Stage
  Ordering.
- Assets: relative traversal-safe paths, stable IDs in persistent data —
  CS § Assets And Persistent Data.
- Tests: small fixtures, no test-only production hooks — CS § Tests. Perf
  numbers only from targeted `zig build bench` runs — CS § Benchmarks.
- Never edit generated output (`zig-out/`, `.zig-cache/`) — CS § Generated
  Output And Configuration.
- Slices are full features; no backlog dumping; Deferred By Owner is
  owner-only — IDX § Ground Rules.
- Validate per DW § Validation Cadence (`check` + `test` + `idiom-lint` per
  commit, `verify` per batch or slice). Packaged builds ship `ReleaseFast` —
  DW § Release Modes for the ReleaseSafe soak gate.
- `README.md` is an overview: what the project is, one-line feature bullets,
  requirements, quick start, commands, layout, doc links. How things work goes
  in `docs/`.

## Commands

Minimum toolchain is **Zig 0.17.0**; default optimize mode is `Debug`. Details
and flags: `docs/development-workflow.md`.

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

## Agent Pipeline

All non-trivial Zig design, implementation, review, and debugging goes through
the `.claude/agents/` specialists. The main session orchestrates, verifies agent
claims against the live code, and reports; it does not implement non-trivial
changes inline.

- `zig-design-specialist` only when the design is genuinely ambiguous; clear
  fixes go straight to `zig-specialist` with a tight brief.
- `zig-review-specialist` once per batch. Findings go back to `zig-specialist`;
  at most one review-of-fixes round; lows go straight into slice checklists.
  Adversarially verify only High/Critical findings.
- `zig-debug-specialist` for build/test/runtime failures.
- Do not substitute or add generic skills or agents (`/code-review`,
  `/simplify`, generic Explore/Plan) for this repo's Zig work, not even
  alongside these agents.
- Every brief starts with a standing-requirements check: growth model
  (CS § Budgets), destruction scale and bench weighting (CS § Benchmarks),
  serial + threaded paths (CS § Threading), readable code and terse comments
  (CS § Zig Style, § Comments).
- Keep it lean: cap agent report length, keep docs and comments terse, make
  reasonable engineering decisions without asking the owner to approve obvious
  next steps. When fixes on one area keep spawning review rounds, stop and
  question the design. Do not set model/effort overrides unless the owner asks.
- Implementation agents run sequentially in the main tree with linear commits:
  no `isolation: worktree`, no merge commits. Parallelize only read-only work.

## Claude Code Tooling (`.claude/`)

- `agents/` — `zig-design-specialist` (read-only design plans), `zig-specialist`
  (implementation), `zig-debug-specialist` (build/test/runtime failures),
  `zig-review-specialist` (read-only review). Workflows reference these names
  via `agentType`; keep them stable. All run `opus`; design at `xhigh`
  effort, review/implementation/debug at `high` (review fans out across many
  workflow agents).
- `workflows/` — multi-agent passes, invoked as `/pathfinder-review`,
  `/architecture-assessment`, `/zig-best-practices-review`,
  `/zig-deep-correctness-review-pass`. Each produces a report; none edits code.
- `hooks/zig-fmt.sh` — `PostToolUse` hook that runs `zig fmt` on each
  `.zig`/`.zon` file after Edit/Write. It does not replace validation.
- `settings.json` — shared permissions (routine `zig build` steps and read-only
  `git` commands allowed, edits to `zig-out/` and `.zig-cache/` denied) and the
  `zig fmt` hook. Personal overrides go in the gitignored `settings.local.json`.
