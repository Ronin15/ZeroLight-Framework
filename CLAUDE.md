# CLAUDE.md

Durable repo guidance. Rules are owned by the docs below; this file summarizes
and points.

## Project Snapshot

A 2D game framework on **Zig 0.17** and **SDL3 / SDL_GPU**: a fixed-step
**60Hz** simulation, a state stack with policy-driven input routing, and
atlas-backed assets addressed by stable IDs. Gameplay is data-oriented: dense
**SoA** stores (`DataSystem`, `WorldSystem`), a state-owned
`SimulationPipeline`, scoped simulation tiers, and multithreaded/SIMD
processors.

The game built on it is dig/build with cave-ins and explosions: dense,
multi-chunk terrain change in one step is normal gameplay, not an edge case.

This is engine core for a large, growing, multi-world simulation; the demo is
a test harness, never a design input. Target scale (several worlds created and
destroyed in play, 2048² levels, deep and growing stacks, large populations)
is a floor. Every design starts from CS § Architecture Decisions and
`docs/architecture.md` § Target Model.

## Source Of Truth

Read the owning doc before editing; these are canonical.

- `docs/architecture.md`: source layout, ownership boundaries, frame flow.
- `docs/coding-standards.md` (CS): every technical rule.
- `docs/development-workflow.md` (DW): commands, build modes, validation,
  packaging.
- Area docs: `setup.md`, `state-stack-and-input.md`,
  `rendering-assets-shaders.md`, `simulation-tiers-and-pipeline.md`,
  `atlas-asset-workflow.md`.
- `docs/framework-implementation-slices.md` (IDX): roadmap index. Open slices
  are `docs/roadmap/slices/slice-<id>.md`; cross-slice contracts and tables are
  in `docs/roadmap/tracks/`; measured pressure points in
  `docs/roadmap/scaling-gaps.md`; settled slices in `docs/roadmap/archive/`
  (index: `docs/framework-implementation-slices-archive.md`).
- `docs/changelogs/`, `docs/reviews/`.

## Module Ownership

Add code under the owning module; never move ownership boundaries for a local
convenience.

- `src/main.zig`: entry and fixed-step loop; keep it thin.
  `src/config.zig`: `AppConfig` and defaults.
- `src/app/`: engine, state stack, input routing, time loop, frame pacing,
  pause, audio, thread system.
- `src/render/`: SDL_GPU rendering behind the `renderer.zig` facade.
- `src/assets/`: asset catalog, safe paths, cache, `manifest.zig` stable IDs.
- `src/game/`: states, `WorldSystem`, `DataSystem`, `SimulationPipeline`,
  controllers, render prep, and `systems/` processors.
- `src/core/`: math, SIMD, logging. `src/platform/`: SDL, GPU smoke.
  `src/benchmarks/`: benchmarks.

## Working Rules

**Code** (the cited CS section is the rule):

- Cost model before code; extend the existing partition unit, redesign over
  patching: § Architecture Decisions.
- Plain readable form, explicit error sets: § Zig Style. Terse comments:
  § Comments.
- Hot paths allocation-free after warmup; `FailingAllocator` proof for every
  reserve (ReleaseFast ships): § Performance, § Allocator Discipline.
- Storage owned by the unit of change (terrain/nav: the chunk); fixed work
  budgets; growth only at the seam; no gameplay-reachable refusal: § Budgets,
  Capacities, And Thresholds.
- Partitioned, pre-reserved threaded writes; serial + threaded paths:
  § Threading.
- Relative traversal-safe asset paths; stable IDs in persistent data: § Assets
  And Persistent Data.
- Small fixtures, no test-only production hooks: § Tests. Perf claims only
  from targeted `zig build bench`, read as scaling shape: § Benchmarks.
- Never edit `zig-out/` or `.zig-cache/`: § Generated Output And Configuration.

**Process:**

- Read the live owning files before editing; never trust stale roadmap memory
  or chat summaries for details.
- Reuse existing utilities (search the owning module first); keep changes
  scoped; never reformat or refactor unrelated code.
- Validate per DW § Validation Cadence. Packaged builds ship `ReleaseFast`; the
  ReleaseSafe soak gate is DW § Release Modes.
- Slices are full features; no backlog dumping; Deferred By Owner is
  owner-only: IDX § Ground Rules.

**Docs:**

- `README.md` is an overview: what it is, one-line feature bullets,
  requirements, quick start, commands, layout, doc links. How things work
  belongs in `docs/`.

## Agent Pipeline

All non-trivial Zig design, implementation, review, and debugging goes through
the `.claude/agents/` specialists. The main session orchestrates, verifies
agent claims against live code, and reports; it never implements non-trivial changes inline.

- Every non-trivial brief carries the cost model (CS § Architecture
  Decisions).
- `zig-design-specialist` when a design is open or the existing structure
  fails the cost model; local fixes go straight to `zig-specialist`.
- `zig-review-specialist` once per batch. The main session checks every
  finding and agent claim against live code and the cost model before acting
  on it; structural findings go to design, local ones to `zig-specialist`;
  trivial lows are fixed in the batch, others become one-line slice checklist
  items.
- A second fix to the same subsystem in a slice, or a second review round,
  stops the work: the next step is design, not another patch.
- `zig-debug-specialist` for failures.
- Never use generic skills or agents (`/code-review`, `/simplify`, generic
  Explore/Plan) for this repo's Zig work, instead of or alongside these.
- Stay lean: terse agent reports and docs (never by dropping findings), make reasonable
  engineering calls without asking approval; never reopen an owner decision.
  No model/effort overrides unless the owner asks.
- Implementation agents run sequentially in the main tree. One slice or one
  logical change is one commit, review fixes folded in; no per-finding
  commits, no `isolation: worktree`, no merge commits. Parallelize only
  read-only work.

## Commands

Zig 0.17.0 minimum; default mode `Debug`. Details: DW.

```sh
zig build            # build and install app, assets, shaders
zig build run        # build, install, run
zig build dev        # shaders + assets + run
zig build check      # compile coverage (game, gpu-smoke, bench), no install
zig build test       # unit tests
zig build bench      # CPU benchmarks
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

- `agents/`: the four specialists; workflows use their names (`agentType`),
  so keep them stable. All run `opus` at `high` effort.
- `workflows/`: `/pathfinder-review`, `/architecture-assessment`,
  `/zig-best-practices-review`, `/zig-deep-correctness-review-pass`; reports
  only, no edits.
- `hooks/zig-fmt.sh`: runs `zig fmt` on each edited `.zig`/`.zon` file; it
  does not replace validation.
- `settings.json`: shared permissions (edits to `zig-out/`/`.zig-cache/`
  denied) and the hook. Personal overrides: gitignored `settings.local.json`.
