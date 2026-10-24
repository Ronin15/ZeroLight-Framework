# ZeroLight Framework

## Project Snapshot

A 2D game framework on **Zig 0.17** and **SDL3 / SDL_GPU** with a fixed-step
**60Hz** data-oriented simulation: engine core for a fully simulated,
multi-world colony simulator (target and the demo's role:
`.claude/rules/engine-design.md` § Target scale).

## Rules And Docs

- **Rules** live only in `.claude/rules/`, one topic per file
  (`engine-design.md`). `engine-design.md` loads every session; each other
  rule loads when a file its `paths:` frontmatter names is Read, so Read a
  file you only grepped before relying on its rules.
- Agent definitions, docs, briefs, plans, and reports cite rule files by name
  and never restate them; a plan cites the rule each decision meets, a review
  the rule each standards finding breaks.
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
`.claude/agents/` specialists (Agent tool, `subagent_type` = its name); the
brief file is the child's whole task. Trivial work (a local fix in 1-2 files,
no design question) may be done inline. The main session coordinates and is
the second set of eyes on every unit: it keeps the work on the agreed goal and
order, verifies agent claims against live code and the rules, calls out a
needed direction change to the owner, answers rule questions with the
decision criteria, and reports.

- **Briefs** go to `.claude/reports/<topic>-brief.md`; the spawn prompt cites
  the path. A brief names the files in scope, the declarations to read, and
  the cost-model questions. It cites a plan and lists only its overrides;
  every fact in it is checked against live code or a cited source, and a
  hypothesis is labelled one; every validation step and bench size it names
  exercises the changed code. A review brief names the diff, its sources,
  and what to check, never anyone's conclusions.
- **Design** (`zig-design-specialist`) only when a design is open or the
  structure fails the cost model, right before implementation. A known fix or
  a call already made goes straight to `zig-specialist`.
- **Review** (`zig-review-specialist`) once per landing, before commit,
  spawned the same turn the code is ready; fixes fold into that commit. A
  finding with a stated local fix goes to `zig-specialist`, an open choice to
  design. A High structural data-layout finding in new code is fixed in its
  landing. Any finding not fixed becomes a checklist item in its owning slice
  (`file:line`, failure scenario, pass condition).
- **Debug** (`zig-debug-specialist`) for failures. **Docs**
  (`docs-specialist`) write a slice's docs commit once its programming is
  done, from the code as landed; each landing's doc changes are notes in its
  commit message.
- Never generic skills or agents (`/code-review`, `/simplify`, generic
  Explore/Plan) for Zig work here.
- **Decision criteria**: uniformity, scalability, best practice, efficiency,
  speed; never what today's code happens to produce or less work. Make calls
  without asking and report them. A departure from a rule's letter is allowed
  only where the letter costs a criterion, never to ease work; it is reported,
  and one that would recur becomes a proposed rule edit. The owner decides
  scope added or dropped, product/gameplay behavior, rule edits, a major or
  `ThreadSystem`/tuner redesign, and anything that doesn't make sense. No
  model/effort overrides unless the owner asks.
- Read-only agents for independent pieces run together; let each finish
  before using it. Implementation agents run one at a time in the main tree,
  one commit-sized unit each; new work goes to a fresh agent. One commit per
  logical change, review fixes folded in; no per-finding commits, worktrees,
  or merge commits; never known-broken or unfinished code; the owner pushes.
- Agents work from live code and the sources the brief names, never memory or
  chat summaries; they report what is outside their role and the main session
  routes it.
- Reports are terse and drop no findings; a perf report gives both sides'
  times per case with entity counts, both sides built at the same CPU. An
  explanation of a failure or bench result is a hypothesis until a
  measurement tests it; say which, and never write an untested one into a
  pass condition or a comment.
- Long jobs run in the foreground (in chunks under the tool's 10-minute
  limit) or as a background command awaiting its notification; never a shell
  wait or poll loop.

## Commands

Zig 0.17.0 minimum. `zig build -l` lists the steps;
`zig build bench -- --group <name>` targets one bench group. Details: DW.
Validation cadence and modes: `build-validation.md`.

## Claude Code Tooling (`.claude/`)

- Agent names stay stable: `.claude/workflows/` calls them by name (`agentType`).
- Plans, reviews, unit briefs, and landing reports go in `.claude/reports/`
  (gitignored). Design and review agents write theirs; the main session
  writes `<topic>-brief.md`; `zig-specialist` writes `<topic>-landing.md`
  unless the brief names another path. A spawn prompt cites the file.
- `tools/bench_ab.py` is the before/after bench (DW § Benchmarks; modes:
  `build-validation.md`; verdicts: `tests-benchmarks.md`). Never revert
  implemented work without the owner.
- `hooks/zig-fmt.sh` runs `zig fmt` on each `.zig`/`.zon` file an `Edit` or
  `Write` just edited (`settings.json`; needs `jq`); it does not replace
  validation.
