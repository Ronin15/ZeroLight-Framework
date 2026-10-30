# ZeroLight Framework

## Project Snapshot

A 2D game framework on **Zig 0.17** and **SDL3 / SDL_GPU** with a fixed-step
**60Hz** data-oriented simulation: engine core for a fully simulated,
multi-world colony simulator (target and the demo's role:
`.grok/rules/engine-design.md` § Target scale).

## Rules And Docs

- **Rules** live only in `.grok/rules/`, one topic per file
  (`engine-design.md`). Every rule loads every session. Cite a loaded rule
  and do not open it again.
- Agent definitions, docs, plans, and reports cite rule files by name
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
`.grok/agents/` specialists (`spawn_subagent`, `subagent_type` = its name); the
spawn prompt is the child's whole task. Trivial work (a local fix in 1-2 files,
no design question) may be done inline. The main session coordinates.
Specialists own the design and the code. It keeps each unit on the agreed
goal and order. Its check is that the result still matches that goal: the
slice pass and the named plan. It does not design the change or walk the
module. It calls out a needed direction change to the owner and reports.
Before it starts or continues a unit, it reads `.grok/reports/handoffs.md`.
That file names the next unit, the specialist, and the sources. When a unit
finishes, or a review routes the next one, the main session rewrites the file.

- **Design** prompt: the files, the declarations to read, the cost-model
  questions, and the plan path. The specialist checks those lines. A
  hypothesis in the prompt is labelled one. When the owner already exists,
  the first line says so and names the line ranges to read. The prompt
  states the slice pass. An open how is the specialist's decision. The
  prompt does not choose it or tour the module.
- **Implement** prompt: the design plan's path and only its overrides. It
  names the test helper a new test calls, the `-Dtest-filter` words shared
  by that test and the existing tests of the same behavior, and the bench
  groups when a bench runs. The words are not the module and not a phrase
  unique to the new test. The implementer executes that plan and reads
  `tools/bench_ab.py --list` for that group's items and cases. A stated fix
  with no plan is the prompt. Every validation step and bench size it names
  exercises the changed code.
- **Review** prompt: the files and the report path. It does not name the
  plan or the landing.
- Agents cite a loaded rule by name. They do not open it again and do not
  restate it. A repeated constraint belongs in `.grok/rules/`.
- **Design** (`zig-design-specialist`) only when a design is open or the
  structure fails the cost model, right before implementation. A known fix or
  a call already made goes straight to `zig-specialist`.
- **Review** (`zig-review-specialist`) once per landing, before commit,
  spawned the same turn the code is ready. A large diff is two review
  agents, spawned together. Each prompt names its own files. The split is
  files that do not share a write. The main session merges the two reports
  into one finding list. That is one review, not a second round. Fixes fold
  into that commit. A
  finding with a stated local fix goes to `zig-specialist`, an open choice to
  design. A High structural data-layout finding in new code is fixed in its
  landing. Any finding not fixed becomes a checklist item in its owning slice
  (`file:line`, failure scenario, pass condition).
- **Debug** (`zig-debug-specialist`) for failures. Its prompt is the failing
  command and the first error block. **Docs** (`docs-specialist`) write a
  slice's docs commit once its programming is done, from the code as landed;
  the prompt names those sources and the slices. Each landing's doc changes
  are notes in its commit message.
- Never generic skills or agents (`/code-review`, `/simplify`, generic
  Explore/Plan) for Zig work here.
- **Decision criteria**: uniformity, scalability, best practice, efficiency,
  speed; never what today's code happens to produce or less work. Make calls
  without asking and report them; a departure from a rule's letter follows
  `engine-design.md`'s first paragraph. The owner decides
  scope added or dropped, product/gameplay behavior, rule edits, a new tuner
  architecture or stage pattern, and anything that doesn't make sense. A
  settle, merge, or remove an owning slice already names is in scope. No
  model/effort overrides unless the owner asks.
- Read-only agents for independent pieces run together; let each finish
  before using it. Implementation agents run one at a time in the main tree,
  one commit-sized unit each; new work goes to a fresh agent. One commit per
  logical change, review fixes folded in; no per-finding commits, worktrees,
  or merge commits; never known-broken or unfinished code. A completed slice
  unit is committed once its review fixes are in, so the next unit stays
  separate. A workflow edit is its own commit, separate from a slice unit.
The owner pushes.
- Agents work from live code and the sources the prompt names, never memory or
  chat summaries; they report what is outside their role and the main session
  routes it.
- Reports are terse and drop no findings; perf reports and explanations of
  results follow `tests-benchmarks.md` § Benchmarks.
- Long jobs run in the foreground (in chunks under the tool's 10-minute
  limit) or as a background command awaiting its notification; never a shell
  wait or poll loop.

## Commands

Zig 0.17.0 minimum. `zig` on `PATH` is the current binary. `zig build test`
with its `-Dtest-filter`, and `zig build bench` or `tools/bench_ab.py` with
its group, run that binary. Do not search `.zig-cache` or `zig-out` for a
test or bench executable. `zig build -h` lists the steps and the `-D` options; stop
at System Integration Options. `tools/bench_ab.py --help` lists that script's
flags and the bench flags it forwards, and runs nothing. `tools/bench_ab.py
--list` lists each group's items and cases. Do not open `build.zig`,
`tools/bench_ab.py`, or `src/benchmarks/` to find a flag or a group. Open a
DW section only when a rule names it.
Validation cadence and modes: `build-validation.md`.

## Grok Tooling (`.grok/`)

- Agent names stay stable. Spawn them with `subagent_type` set to that name.
- Plans, reviews, and landing reports go in `.grok/reports/` (gitignored).
  Design writes the plan, review writes the report, and `zig-specialist`
  writes `<topic>-landing.md`, each to the path the prompt names.
- `tools/bench_ab.py` is the before/after bench (DW § Benchmarks; modes:
  `build-validation.md`; verdicts: `tests-benchmarks.md`). Never revert
  implemented work without the owner.
- `.grok/hooks/zig-fmt.sh` runs `zig fmt` on each `.zig`/`.zon` file a
  `search_replace` or `write` just edited (`.grok/hooks/zig-fmt.json`; needs
  `jq`); it does not replace validation.
