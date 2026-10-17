# CLAUDE.md

## Project Snapshot

A 2D game framework on **Zig 0.17** and **SDL3 / SDL_GPU**: a fixed-step
**60Hz** simulation, a state stack with policy-driven input routing, and
atlas-backed assets addressed by stable IDs. Gameplay is data-oriented: dense
**SoA** stores (`DataSystem`, `WorldSystem`), a state-owned
`SimulationPipeline`, scoped simulation tiers, and multithreaded/SIMD
processors. The game built on it is a colony simulator (dig/build with
cave-ins and explosions); a player entity is optional. This is engine core for
a fully simulated, multi-world game: everything that exists keeps advancing,
with fidelity falling off with distance from the observer; the demo is a test
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
  Slices hold intent and data (goal, current foundation, constraints,
  checklist, acceptance), never rules or designs.
- `docs/changelogs/` (one per branch), `docs/reviews/`.

## Module Ownership

Add code under the owning module: boundaries in
`.claude/rules/engine-design.md` § Ownership boundaries, detail in
`docs/architecture.md` § Source Layout.

## Agent Pipeline

Non-trivial Zig design, implementation, review, and debugging goes through the
`.claude/agents/` specialists. Trivial means a local fix in 1–2 files with no
design question; the main session may do that inline. The main session
orchestrates, verifies every agent claim against live code, and reports.

- Every non-trivial brief carries the cost model
  (`.claude/rules/engine-design.md`) and names the files in scope, so the agent
  reads the matching rule files.
- `zig-design-specialist` runs only when a design is open or the existing
  structure fails the cost model, and writes that plan right before its
  implementation and against the live code. Local fixes, and work whose
  call a plan or review triage already made (a move, a dedupe, a fix with a
  known cause), go straight to `zig-specialist` with that call in the brief.
- `zig-review-specialist` reviews each slice, or each landing of a
  multi-commit slice, before it is committed; fixes fold into that commit.
  Every real finding is reported and checked against live code and
  `docs/architecture.md`; a finding with a stated local fix goes to
  `zig-specialist`, one whose fix is an open choice to design. A finding
  not fixed in its landing becomes a checklist item in the owning slice
  with its `file:line` and failure scenario, never only a memory note.
- `zig-debug-specialist` for failures.
- Never use generic skills or agents (`/code-review`, `/simplify`, generic
  Explore/Plan) for Zig work in this repo.
- Terse reports and docs, never by dropping findings. Make engineering calls
  without asking, on best practice, scale, performance, and efficiency, never
  on what today's code happens to produce and never by doing less work, and
  report them. Rules guide; a call made on those criteria may depart from a
  rule, and is reported with its reasoning as a decision made; a departure
  that would recur becomes a proposed rule edit. Only scope added
  or dropped, product/gameplay behavior, rule edits, a major redesign, a
  `ThreadSystem`/tuner redesign, and anything that doesn't make sense go to the
  owner. No model/effort overrides unless the owner asks.
- Implementation agents run sequentially in the main tree; parallelize only
  read-only work, and let read-only agents finish rather than stopping them
  midway. One commit per logical change with review fixes folded in; no
  per-finding commits, worktrees, or merge commits. Never commit known-broken
  or unfinished code; the owner pushes.
- Docs wait until a slice's programming is done: each landing's doc changes
  are notes in its commit message, and the slice's docs commit writes them
  once from the code as landed (checklist check-offs, durable docs, tables).

## Commands

Zig 0.17.0 minimum; default mode `Debug`. `zig build -l` lists the steps;
`zig build bench -- --group <name>` targets one bench group. Details and
options: DW. Validation cadence: `.claude/rules/build-validation.md`.

## Claude Code Tooling (`.claude/`)

- Agent names stay stable: the `workflows/` call them by name (`agentType`).
- Design and review agents write their plans and reports to
  `.claude/reports/` (gitignored); briefs cite the file instead of pasting it.
- `tools/bench_ab.py` is the before/after bench (targeted groups, base ref vs
  tree, one Debug run per side, 3 reps only to confirm a slower case; each
  side's runs cached by its build inputs).
- `hooks/zig-fmt.sh` runs `zig fmt` on each edited `.zig`/`.zon` file (needs
  `jq`); it does not replace validation.
