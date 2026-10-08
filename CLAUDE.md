# CLAUDE.md

## Project Snapshot

A 2D game framework on **Zig 0.17** and **SDL3 / SDL_GPU**: a fixed-step
**60Hz** simulation, a state stack with policy-driven input routing, and
atlas-backed assets addressed by stable IDs. Gameplay is data-oriented: dense
**SoA** stores (`DataSystem`, `WorldSystem`), a state-owned
`SimulationPipeline`, scoped simulation tiers, and multithreaded/SIMD
processors. The game built on it is dig/build with cave-ins and explosions.
This is engine core for a large multi-world simulation; the demo is a test
harness (`.claude/rules/engine-design.md`).

## Rules And Docs

- **Rules** live only in `.claude/rules/`, one topic per file. Files without
  `paths:` load every session; the rest load when matching files are touched.
  Docs describe how things work and cite rule files; they never restate them.
- `docs/architecture.md`: source layout, ownership, frame flow, Target Model.
- `docs/development-workflow.md` (DW): commands, build options, diagnostics,
  benches, packaging.
- Area docs: `setup.md`, `state-stack-and-input.md`,
  `rendering-assets-shaders.md`, `simulation-tiers-and-pipeline.md`,
  `atlas-asset-workflow.md`.
- Roadmap: `docs/framework-implementation-slices.md` (index, ground rules,
  suggested order); one file per open slice in `docs/roadmap/slices/`; shared
  tables in `docs/roadmap/tracks/`; settled slices in `docs/roadmap/archive/`.
  Slices hold goals, specs, checklists, and acceptance only, never rules.
- `docs/changelogs/` (one per branch), `docs/reviews/`.

## Module Ownership

Add code under the owning module; detail in `docs/architecture.md` § Source
Layout.

- `src/main.zig`: entry and fixed-step loop, thin. `src/config.zig`:
  `AppConfig` and defaults.
- `src/app/`: engine, state stack, input and routing, gamepad, time loop,
  frame pacing, pause, audio, thread system, resolution, runtime perf log.
- `src/render/`: SDL_GPU rendering behind the `renderer.zig` facade.
- `src/assets/`: asset catalog, safe paths, image decode, cache,
  `manifest.zig` stable IDs.
- `src/game/`: states and menus, `WorldSystem`, `data_system/`,
  `SimulationPipeline`, controllers (dig, destructible, audio), render prep,
  and `systems/` processors (movement, AI, affect, perception, steering,
  collision, particles, `pathfinding/`).
- `src/core/`: math, SIMD, RNG, logging. `src/platform/`: SDL wrappers, GPU
  smoke. `src/benchmarks/`: benchmarks.

## Agent Pipeline

Non-trivial Zig design, implementation, review, and debugging goes through the
`.claude/agents/` specialists. Trivial means a local fix in 1–2 files with no
design question; the main session may do that inline. The main session
orchestrates, verifies every agent claim against live code, and reports.

- Every non-trivial brief carries the cost model
  (`.claude/rules/engine-design.md`) and names the files in scope, so the agent
  reads the matching rule files.
- `zig-design-specialist` when a design is open or the existing structure fails
  the cost model; local fixes go straight to `zig-specialist`.
- `zig-review-specialist` once per batch. Every real finding is reported and
  checked against live code; structural findings go to design, local ones to
  `zig-specialist`; lows are fixed in the batch or become a checklist item in
  the owning slice.
- A second fix to the same subsystem in a slice, or a second review round,
  stops the work: the next step is design, not another patch.
- `zig-debug-specialist` for failures.
- Never use generic skills or agents (`/code-review`, `/simplify`, generic
  Explore/Plan) for Zig work in this repo.
- Terse reports and docs, never by dropping findings. Make reasonable
  engineering calls without asking. No model/effort overrides unless the owner
  asks.
- Implementation agents run sequentially in the main tree; parallelize only
  read-only work. One commit per logical change with review fixes folded in;
  no per-finding commits, worktrees, or merge commits.

## Commands

Zig 0.17.0 minimum; default mode `Debug`. Details and options: DW. Validation
cadence: `.claude/rules/build-validation.md`.

```sh
zig build            # build and install app, assets, shaders
zig build run        # build, install, run
zig build dev        # shaders + assets + run
zig build check      # compile coverage (game, gpu-smoke, bench), no install
zig build test       # unit tests
zig build bench      # CPU benchmarks (target a group: -- --group <name>)
zig build verify     # full gate: check + test + shaders + atlas + idiom lint
zig build fmt        # format build files and src/
zig build shaders    # compile GLSL to platform shaders
zig build gpu-smoke  # renderer smoke (needs a display)
zig build package    # install selected-mode binaries and assets
zig build assets-lint # lint runtime atlases vs source sprites
zig build idiom-lint # lint naming, stdlib currency, unsafe catch unreachable
zig build fetch-sdl  # fetch and validate pinned Windows SDL packages
```

## Claude Code Tooling (`.claude/`)

- `rules/`: every technical rule (see Rules And Docs).
- `agents/`: the four specialists, `opus` at `high` effort. Workflows call them
  by name (`agentType`), so names stay stable.
- `workflows/`: `/pathfinder-review`, `/architecture-assessment`,
  `/zig-best-practices-review`, `/zig-deep-correctness-review-pass`; reports
  only, no edits.
- `hooks/zig-fmt.sh`: runs `zig fmt` on each edited `.zig`/`.zon` file (needs
  `jq`); it does not replace validation.
- `settings.json`: shared permission allowlist, `Edit` denied under `zig-out/`
  and `.zig-cache/`, and the hook. Personal overrides: gitignored
  `settings.local.json`.
