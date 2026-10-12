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
- Tests never time anything and never call `src/benchmarks/` (except
  `suite.zig`'s tests of its pure utilities); bench-fixture correctness relies
  on internal asserts firing during a real bench run.

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
- Bench only changes that can move a hot path. Compare before/after on adjacent
  commits in Debug (ReleaseFast only per `build-validation.md`) with 3
  interleaved reps and medians (`tools/bench_ab.py`); a regression is a change
  beyond the run-to-run spread. Act on one only when it shows a worse growth
  order or a material total; a nanosecond-per-item constant is reported, not
  redesigned. A constant is material when it moves the stage's total beyond
  the run-to-run spread at the bench's sizes; a few ns per item on a stage
  dominated by other work is not. A threaded stage is judged on its
  `thread-adaptive-tuned-range` case (the production tuner) against its base;
  the other cases are controls, and the tuned case matches or beats the best
  of them within spread.
- Scaling benches ship with the first implementation; terrain features bench
  destruction-shaped workloads (a one-step explosion region, repeated
  dig/fill).
- A scaling bench runs at least three sizes far enough apart to show the growth
  shape, each right-sized: large enough that the shape is clear and the
  threaded case runs the changed stage, no larger (oversized runs slow the dev
  cycle and show nothing more). It passes when the shape matches the cost
  model's order (flat for a local change, linear where linear is right). A
  cost that grows with world size on a local change is a design defect
  regardless of the absolute number, except reachability maintenance
  (`budgets-capacities.md`), whose benches pass when each removal's cost
  follows its own smaller side or detour reach and never another change or
  the level around it; and each one-way change's closure cost follows its own
  one-way system and affected rows, never another system's.
