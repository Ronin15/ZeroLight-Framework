---
paths:
  - "src/**/*.zig"
  - "tools/bench_run.py"
  - "tools/bench_ab.py"
---

# Tests And Benchmarks

## Tests

- Tests are `test` blocks beside their code, named by behavior.
- Prefer focused window-free contract tests; display/GPU checks belong in
  `gpu-smoke`.
- A fix ships with a test that would fail without it, judged from the code,
  never by revert-and-rerun runs. Never drop a proof test or
  `FailingAllocator` proof to save time.
- A threaded stage has a test proving it ran on workers, not inline.
- Terrain contract tests cover a multi-chunk one-step change and repeated
  dig/fill.
- An incremental path (nav patch, terrain or link change) gets an
  incremental == full-rebuild parity test.
- Use the smallest `WorldSystem`/`DataSystem` fixture that exercises the
  behavior (a `1x1` world still has one real chunk); multi-chunk tests shrink
  `chunk_size_tiles` rather than grow the world.
- Full world-building paths (`initProcedural*`) run only when under test, at
  most 16x16 tiles and 1 underground level. A growth or scale test may use a
  larger populated world, or more levels, built directly.
- Production APIs carry no test-only tags, payloads, fields, stages, hooks,
  shortcuts, or paths; tests use private helpers, fixtures, mocks, or real
  payloads.
- Tests never time anything and never call `src/benchmarks/` (except the
  shared harness files' tests of their own pure utilities, `suite.zig` and
  `nav_size.zig`); bench-fixture correctness relies on internal asserts firing
  during a real bench run.
- Tests and benches drive production sequences, resets, and rules through
  the production functions; never re-implement an order, a field-by-field
  reset, or a rule they check, since a copy passes when production drifts.

## Benchmarks

- All performance claims and OOM/leak sweeps come from `zig build bench`. The
  ReleaseSafe runtime perf dump is diagnostic trend data for locating a
  regression, never a perf claim or gate.
- Benches measure how an algorithm scales, never a target count. Bench sizes
  are sample points on a curve, never capacities, budgets, acceptance
  thresholds, or frame-time verdicts; never pick a size or cap because a bench
  count fit, and never report "fast enough at N".
- A perf question with no covering case gets a new case under
  `src/benchmarks/`.
- Run benches targeted to the code being tested or changed
  (`--group <name> --items N`), never the full suite; full sweeps only when
  the owner or a slice asks.
- Bench only changes that can move a hot path, once: one right-sized config
  per group the change touches, plus each scaling bench's sizes. A threaded
  stage's bench reports its main-thread share, and main's time per item stays
  flat across sizes. Compare before/after on adjacent commits in Debug (ReleaseFast only
  per `build-validation.md`) with one run per side (`tools/bench_ab.py`); a
  case more than 10% slower is rerun alone with 3 reps. When the change
  alters a bench's fixture or input order, the base code also runs on the
  new fixture; the like-for-like gap is the code's. A constant is material
  when it moves the stage's total beyond the run-to-run spread at the
  bench's sizes. A threaded stage is judged on its
  `thread-adaptive-tuned-range` case (the production tuner) against its base;
  the other cases are controls, and the tuned case matches or beats the best
  of them within spread. The tuned case's report says which path is
  production at a size: where it runs inline, the serial path is production
  and is judged like the tuned case; where it threads, `serial-direct` is a
  control, judged only for a worse growth order or added per-item work (a new
  scan or indirection), never for a constant gap.
- A landing's before/after runs once, after its code is done; a review fix
  reruns only the cases it touches. Each slower
  case gets one verdict: noise (within spread after 3 reps), planned cost
  (work the design or a SIMD shape adds, named and reported), a control's
  gap (a path that is not production at that size; reported), or a
  regression (material overhead or a worse growth order on the path that is
  production), which is what gets optimized. A regression
  gets one attribution, one fix, and one re-measure of that case; if it is
  still slower, it is reported and becomes a checklist item in its owning
  slice.
- Scaling benches ship with the first implementation; terrain features bench
  destruction-shaped workloads (a one-step explosion region, repeated
  dig/fill).
- Benches read production defaults, constants, layouts, and byte bounds
  (pure `@sizeOf`-based bounds beside each structure); never copy them. A
  memory estimate is checked whole against live bytes.
- Each group's doc states what it measures and its pass shape, and its
  asserts check that shape. Exception: a branch's measuring landing states
  each finding's pass shape in the group doc and asserts only fixture
  invariants; the shape assert lands with the fix. A config the bench cannot
  run fails, never skips.
  A variant, column, or assert that measures a removed design goes with it.
- Shared harness pieces live once (`suite.zig`: item codes, labels, stage
  shapes, reporting; `fixtures.zig`: worlds, bodies, threads, tuners;
  `nav_size.zig`: the nav memory estimate). A group
  declares its label and formatter in its definition, never through a switch
  on its name.
- A scaling bench runs at least three sizes far enough apart to show the growth
  shape, each right-sized: large enough that the shape is clear and the
  threaded case runs the changed stage, no larger (oversized runs slow the dev
  cycle and show nothing more). A sweep varies one axis with the others
  fixed, never a cross product, and the fixture's world stays fixed unless
  world size is the axis. It passes when the shape matches the cost
  model's order (flat for a local change, linear where linear is right). A
  cost that grows with world size on a local change is a design defect
  regardless of the absolute number, except reachability maintenance
  (`budgets-capacities.md`), whose benches pass when each removal's cost
  follows its own smaller side or detour reach and never another change or
  the level around it; and each one-way change's closure cost follows its own
  one-way system and affected rows, never another system's.
