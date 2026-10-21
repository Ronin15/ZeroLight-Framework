# AGENTS.md

## Project Snapshot

A 2D game framework on **Zig 0.17** and **SDL3 / SDL_GPU** with a fixed-step
**60Hz** data-oriented simulation: engine core for a fully simulated,
multi-world colony simulator (target and the demo's role:
`.grok/rules/engine-design.md` § Target scale).

## Rules And Docs

- **Rules** live only in `.grok/rules/`, one topic per file
  (`engine-design.md`). Every rule file loads every session.
- Docs, briefs, plans, and reports cite rule files by name and never restate
  them; a plan cites the rule each decision meets, a review the rule each
  standards finding breaks.
- `docs/architecture.md`: source layout, ownership, frame flow, Target Model.
- `docs/development-workflow.md` (DW): commands, build options, diagnostics,
  benches, packaging.
- Area docs: `setup.md`, `state-stack-and-input.md`,
  `rendering-assets-shaders.md`, `simulation-tiers-and-pipeline.md`,
  `atlas-asset-workflow.md`.
- Roadmap: `docs/framework-implementation-slices.md` (index, ground rules,
  suggested order); open slices one per file in `docs/roadmap/slices/`, shared
  tables in `docs/roadmap/tracks/`, settled slices in `docs/roadmap/archive/`.
  Slices hold intent and data (goal, current foundation, constraints,
  checklist, acceptance), never rules or designs.
- `docs/changelogs/` (one per branch), `docs/reviews/`.

## Module Ownership

Add code under the owning module: boundaries in `engine-design.md`
§ Ownership boundaries, detail in `docs/architecture.md` § Source Layout.

## Agent Pipeline

Non-trivial Zig design, implementation, review, and debugging goes through the
`.grok/agents/` specialists. Spawn one with `spawn_subagent` and
`subagent_type` set to its name. The child does not see this session, so the
brief file is the whole task. Trivial means a local fix in 1–2 files with no
design question; the main session may do that inline. The main session
orchestrates, verifies every agent claim against live code, and reports.

- A non-trivial brief names the files in scope, the declarations to read,
  and the change's cost-model questions (what its work and memory grow
  with). Write it to `.grok/reports/<topic>-brief.md`. The spawn prompt
  cites that path and does not paste the brief.
- `zig-design-specialist` runs only when a design is open or the existing
  structure fails the cost model, and plans right before implementation,
  against the live code. Local fixes and calls a plan or review triage already
  made (a move, a dedupe, a fix with a known cause) go straight to
  `zig-specialist` with that call in the brief.
- `zig-review-specialist` reviews each slice, or each landing of a
  multi-commit slice, once, before commit; fixes fold into that commit. When
  an implementation landing's code is ready, the main session spawns that
  review in the same turn, before it reports the unit done. The implementer
  cannot spawn it, and "recommend review" is not a stop. Read-only reviews
  of separate landings may run together. Every real finding is reported and
  checked against live code and `docs/architecture.md`; one with a stated
  local fix goes to `zig-specialist`, one whose fix is an open choice to
  design. A finding not fixed in its landing becomes a checklist item in the
  owning slice with its `file:line`, failure scenario, and pass condition,
  never only a memory note.
- `zig-debug-specialist` for failures.
- `docs-specialist` writes the doc changes for a slice's docs commit and
  routes findings into roadmap slices; it edits docs only, and the main
  session commits.
- Never use generic skills or agents (`/code-review`, `/simplify`, generic
  Explore/Plan) for Zig work in this repo.
- Terse reports and docs, never by dropping findings. Make engineering calls
  without asking, on best practice, scale, performance, and efficiency, never
  on what today's code happens to produce or by doing less work, and report
  them. A call may depart from a rule only where the rule's letter would cost
  best practice, scale, or performance, never to ease work; it is reported
  with its reasoning as a decision made, and a departure that would recur
  becomes a proposed rule edit. Only scope added or dropped, product/gameplay
  behavior, rule edits, a major redesign, a `ThreadSystem`/tuner redesign, and
  anything that doesn't make sense go to the owner. No model/effort overrides
  unless the owner asks.
- When work splits into independent read-only pieces, spawn those agents
  together in the same turn and wait for all of them. Implementation agents
  stay sequential in the main tree. Let every read-only agent finish before
  using its result. One commit per logical
  change with review fixes folded in; no per-finding commits, worktrees, or
  merge commits. Never commit known-broken or unfinished code; the owner
  pushes.
- Docs wait until a slice's programming is done: each landing's doc changes
  are notes in its commit message, and the slice's docs commit
  (`docs-specialist`) writes them once from the code as landed (checklist
  check-offs, durable docs, tables).
- Agents work from live code and the sources the brief names (plans and
  reports in `.grok/reports/`, commit bodies), never from memory or chat
  summaries. They cannot spawn agents: each reports what is outside its role
  and recommends handoffs; the main session routes them.
- An explanation of a failure or bench result is a hypothesis until a
  measurement tests it; say which, and never write an untested one into a
  bench's pass condition or a comment. Run long jobs (bench sweeps, seed
  loops) in the foreground or poll for a done marker, never `tail -f` with a
  timeout.

## Commands

Zig 0.17.0 minimum. `zig build -l` lists the steps;
`zig build bench -- --group <name>` targets one bench group. Details: DW.
Validation cadence and modes: `build-validation.md`.

## Grok Tooling (`.grok/`)

- Agent names stay stable: `.claude/workflows/` calls them by name (`agentType`).
- Plans, reviews, unit briefs, and landing reports go in `.grok/reports/`
  (gitignored). Design and review agents write theirs; the main session
  writes `<topic>-brief.md`; `zig-specialist` writes `<topic>-landing.md`
  unless the brief names another path. A spawn prompt cites the file.
- `tools/bench_ab.py` is the before/after bench; `zig-specialist` runs it
  when the change can move a hot path (DW § Benchmarks). A hot-path
  replacement keeps its SIMD shape; slower cases get their verdict per
  `tests-benchmarks.md`, and ReleaseFast only breaks a SIMD-vs-scalar tie
  (`build-validation.md`). Never revert implemented work without the owner.
- `hooks/zig-fmt.sh` runs `zig fmt` on each `.zig`/`.zon` file a
  `search_replace` or `write` just edited (needs `jq`); it does not replace
  validation.
