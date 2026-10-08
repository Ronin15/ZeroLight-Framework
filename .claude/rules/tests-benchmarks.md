---
paths:
  - "src/**/*.zig"
  - "tools/bench_run.py"
---

# Tests And Benchmarks

## Tests

- Tests are `test` blocks beside their code, named by behavior.
- Prefer focused window-free contract tests; display/GPU checks belong in
  `gpu-smoke`.
- A fix ships with a test that fails with the fix reverted. Never drop a proof
  test or `FailingAllocator` proof to save time.
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
- Run targeted groups (`zig build bench -- --group <name>`), never the full
  suite filtered; full sweeps only when the owner or a slice asks.
- Bench only changes that can move a hot path. Compare before/after on adjacent
  commits in ReleaseFast with 3 interleaved reps and medians; a regression is a
  change beyond the run-to-run spread.
- Scaling benches ship with the first implementation; terrain features bench
  destruction-shaped workloads (a one-step explosion region, repeated
  dig/fill).
- A scaling bench runs at least three sizes far enough apart to show the growth
  shape and passes when the shape matches the cost model's order (flat for a
  local change, linear where linear is right). A cost that grows with world
  size on a local change is a design defect regardless of the absolute number.
