# Big-feature design

Read this when the prompt is a new owner or a big feature.

## Grounding

- Start from the files, declarations, and cost-model questions the prompt
  names. Read the `docs/architecture.md` heading that covers them, through
  the next heading of the same level. Read
  `docs/simulation-tiers-and-pipeline.md` when the change touches frame
  streams, events, or structural commands, through the next heading. For a
  slice, the slice file's goal and architecture notes are the fixed inputs.
  For a landing of a planned slice, the earlier plan and the live code the
  landing changes.
- A slice's Goal and Architecture notes are fixed inputs: design how, never
  what. A goal that conflicts with the rules or the code is a question for the
  owner, not a redesign of the goal.
- Extend the subsystem `docs/architecture.md` names as the owner of the work
  before adding a new owner or module, and start from the engine's proven
  patterns (the stage pattern, chunk-owned work, existing kernels and
  dispatch shapes), cited by `file:line`.
- A kept part the change relies on is checked against the rules that part
  touches. A kept part that breaks one is a defect the design fixes
  (`engine-design.md`).

## Method

Use this path when the change adds a stored result, a hot loop, a pass, or
a budget. Read the prompt's files first. Write the plan once the chosen
design is decided. A step with nothing new is one line citing where it is
settled. Each step's answer is the input to the next. Cite the rule for
the step.

1. **The work.** Goal, scope, call flow, and the cost-model table
   (`engine-design.md` § Cost model). One chosen design. One line per
   rejected alternative. A part that fails the cost model is replaced.
2. **Results.** Where each result is stored and who shares it.
3. **The data.** What each hot loop reads and writes, in its read order
   (`memory-performance.md` § Data-oriented design). A changed order lists
   every consumer.
4. **The loops.** One row per loop the change adds or whose cost, placement,
   or access order changes. Otherwise one line. Columns: `file:line`; what
   it scales with; workers or main, and the stage pattern it copies or why
   it stays serial; SIMD shape (the `simd.zig` pattern, or scalar with the
   reason) and the common call's length; parity; the old loop and the
   counter that would show a new scan; the bench group (`--grid` for a
   scaling group).
5. **The passes.** Reads, writes, and `stage_order` (`simulation.md`). Each
   new threaded pass states what `threading.md` § Building a stage and
   § Writes ask: item unit, dispatches, work against the gate, tuner,
   output capacity, main-thread merge.
6. **Budgets.** `budgets-capacities.md`: class, sizing, growth, degradation.
7. **Proof.** `tests-benchmarks.md`. The exact commands, looked up once
   from the test names in the files you read and from
   one `tools/bench_ab.py --list` piped to that group's lines: each `zig build test -Dtest-filter=… --summary all`, with filter words shared by the new test and the existing tests of that behavior,
   the ThreadSanitizer command when the change is threaded, and each
   `tools/bench_ab.py` line with its group, case, and `--items`. "No bench"
   when none runs. The implementer runs those lines.
8. **Pre-implementation check.** The live lines the plan cites
   (`engine-design.md` § Cost model, last bullet).
9. **Zig standard library and handoff.** `zig-style.md` for each new
   container and for math, SIMD, sort, RNG, logging, and neighbor queries,
   or why the Zig standard library or that shared code cannot serve. Files,
   doc notes, and the steps. Each step names the
   function, its `file:line`, and the change. The implementer executes this plan.

## Checks

Check the finished plan against the loaded rules for the steps it cites.
A failure goes back to the step it came from and is fixed there. Owner
questions are `AGENTS.md` § Decision criteria. A rule that blocks the
design the cost model says is right gets a proposed edit
(`engine-design.md`).

The plan states every invariant. The design and its steps stay in the plan.
Follow-ups are proposed checklist items for an owning slice, or a proposed
new slice for the owner (roadmap index § Standard slice section shape). An
item you cannot plan fully is an open question. Cite an existing
**Deferred By Owner** entry.
