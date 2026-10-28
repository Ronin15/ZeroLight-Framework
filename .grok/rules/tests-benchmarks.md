# Tests And Benchmarks

## Test and production code

The standard Zig layout; every change, plan, and review follows it.

1. Production code holds only what production runs: no entry point,
   parameter, branch, field, stage, hook, path, or work that only tests or
   benches use, and no separate serial entry (the serial path:
   `threading.md` § What runs where). The one sanctioned seam is
   `ThreadSystem`'s fixed-shape dispatch options (`adaptive = false`,
   `items_per_range`, `batches_per_participant`, `max_worker_threads`),
   which tests and benches set to force a shape; production code never sets
   them to anything but a forward of its stage's controls, and
   `tools/lint_idioms.py` fails the build when it does.
2. Tests are `test` blocks in the owning file, named by behavior. A helper
   only that file's tests use is a private file-scope function in that file.
3. A module's `*test_support.zig` holds only what tests in other files or
   benches need (benches are a separate root and see nothing private),
   including byte bounds production does not use, built from `@sizeOf`.
4. Diagnostic counters sit behind the comptime perf-log switch
   (`zig-style.md` § Logging); the bench build always enables it. Benches
   read counters; tests never do and never skip, so every test is a logic
   test that runs in every build mode.

`tools/lint_idioms.py` enforces what it can; the rest is a review finding.

## Tests

- Tests prove logic and stay fast: each drives one behavior or branch with a
  few crafted inputs. Stability, convergence, and work-bound proofs (seed
  sweeps, long or repeated workloads, settle and probe bounds, soaks) and
  every perf check are bench pass-shape asserts, never tests.
- Prefer focused window-free contract tests; display/GPU checks belong in
  `gpu-smoke`.
- A correctness fix ships with a test that would fail without it, and a perf
  or work-bound fix with its bench pass-shape assert, judged from the code,
  never by revert-and-rerun runs. Never drop a proof test or
  `FailingAllocator` proof to save time; a work-bound proof moves to its
  bench group, never away.
- A threaded stage has a bench dispatch check proving it ran on workers, not
  inline.
- Terrain contract tests cover a multi-chunk one-step change and repeated
  dig/fill. An incremental path (nav patch, terrain or link change) gets an
  incremental == full-rebuild parity test.
- Use the smallest `WorldSystem`/`DataSystem` fixture that exercises the
  behavior (a `1x1` world still has one real chunk); multi-chunk tests shrink
  the chunk size rather than grow the world. Full procedural world-building
  paths run only when under test, at most 16x16 tiles and 1 underground level;
  a growth or scale test may build a larger populated world, or more levels,
  directly.
- Tests assert behavior through production's observable results, driving the
  production functions with private helpers, fixtures, mocks, or real
  payloads. A work bound is proven by a bench pass-shape assert that reads
  the counters (§ Test and production code, 4).
- Tests never time anything and never call `src/benchmarks/` (except the
  shared harness's tests of its own pure utilities); bench-fixture
  correctness relies on internal asserts firing during a real bench run.
- Tests and benches drive production sequences, resets, and rules through
  the production functions; never re-implement an order, a field-by-field
  reset, or a rule they check, since a copy passes when production drifts.

## Benchmarks

- All performance claims and OOM/leak sweeps come from `zig build bench`; the
  ReleaseSafe runtime perf dump is diagnostic trend data for locating a
  regression, never a perf claim or gate.
- Benches measure how an algorithm scales, never a target count. Bench sizes
  are sample points on a curve, never capacities, budgets, acceptance
  thresholds, or frame-time verdicts; never pick a size or cap because a bench
  count fit, and never report "fast enough at N". A perf question with no
  covering case gets a new case under `src/benchmarks/`.
- Bench only changes that can move a hot path, targeted to the groups the
  change touches (`--group <name> --items N`): one right-sized config per
  group, plus `--grid` only for a scaling bench's sizes. Never the full suite
  or a whole-suite smoke unless the owner asks; a change to the tuner or
  `ThreadSystem` runs the targeted groups whose tuned cases it can move,
  named in its brief.
- A landing's before/after runs once, after its code is done: the base
  commit against the tree in Debug (ReleaseFast only per `build-validation.md`), one run per
  side (`tools/bench_ab.py`). A case more than 10% slower is rerun alone with
  3 reps; a review fix reruns only the cases it touches. When the change
  alters a bench's fixture or input order, the base code also runs on the new
  fixture; the like-for-like gap is the code's.
- A threaded stage's bench reports its main-thread share, and main's time per
  item stays flat across sizes; its serial case is the production function
  run inline (`threading.md`). The stage is judged on its
  `thread-adaptive-tuned-range` case (the production tuner) against its base;
  the other cases are controls (run with `--all-cases` when the verdict needs
  them), and the tuned case matches or beats the best of them within spread. The tuned case's report says which path is
  production at a size: where it runs inline, the serial path is production
  and is judged like the tuned case; where it threads, `serial-direct` is a
  control, judged only for a worse growth order or added per-item work (a new
  scan or indirection), never for a constant gap. A tuned case whose tuners
  did not settle before measurement (`settled=no`) is rerun with more warmup,
  never judged; one still unsettled at four times the default pre-measure (warmup plus the
  settle limit) is a
  tuner that never settles (`threading.md` § Building a stage). Exception: a one-off stage whose production tuner starts
  fresh each run (a world, level, or store rebuild) is measured fresh, prints
  `fresh`, and is judged.
- A perf report gives both sides' times per case, each with its entity count,
  both sides built at the same CPU. An explanation of a bench result or
  failure is a hypothesis until a measurement tests it; say which, and never
  write an untested one into a pass condition or a comment.
- Each slower case gets one verdict: noise (within spread after 3 reps),
  planned cost (work the design or a SIMD shape adds, named and reported), a
  control's gap (a path that is not production at that size; reported), or a
  regression (material overhead or a worse growth order on the production
  path), which is what gets optimized. A constant is material when it moves
  the stage's total beyond the run-to-run spread at the bench's sizes. A
  regression gets one attribution, one fix, and one re-measure of that case;
  if still slower, it is reported and becomes a checklist item in its owning
  slice.
- Scaling benches ship with the first implementation; terrain features bench
  destruction-shaped workloads (a one-step explosion region, repeated
  dig/fill).
- Benches read production defaults, constants, layouts, and byte bounds
  (§ Test and production code, 3), never copies; a memory estimate is checked
  whole against live bytes.
- A bench runs the production function on the shape that function hits in
  play. A fixture that never reaches that shape is not a measure of the
  path and is changed or removed. Code is tuned for the production step at
  target scale, never toward a bench path production does not take; a bench
  that diverges from production is fixed before its numbers are read.
- Each group's doc states what it measures and its pass shape, and its
  asserts check that shape; exception: a branch's measuring landing states
  each finding's pass shape in the group doc and asserts only fixture
  invariants, and the shape assert lands with the fix. A config the bench
  cannot run fails, never skips. A variant, column, or assert that measures a
  removed design goes with it.
- Shared harness pieces live once (`docs/development-workflow.md`
  § Benchmarks); a group declares its label and formatter in its definition,
  never through a switch on its name.
- A scaling bench runs at least three sizes far enough apart to show the
  growth shape, each right-sized: large enough that the shape is clear and the
  threaded case runs the changed stage, no larger. A sweep varies one axis
  with the others fixed, never a cross product, and the fixture's world stays
  fixed unless world size is the axis. It passes when the shape matches the
  cost model's order (flat for a local change, linear where linear is right).
  A cost that grows with world size on a local change is a design defect
  regardless of the absolute number, except reachability maintenance, whose
  benches pass when each change's cost follows its own bound in
  `budgets-capacities.md`.
