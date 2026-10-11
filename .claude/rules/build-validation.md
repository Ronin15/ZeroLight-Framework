# Build, Validation, Release

Commands and options: `docs/development-workflow.md`.

- Validation cadence:
  - while iterating: `zig build check`;
  - per commit: `check` + `test` + `idiom-lint`;
  - once per batch, and before a slice or broad change is complete:
    `zig build verify`;
  - after shader source or shader wiring changes: `zig build shaders`;
  - `gpu-smoke` only when display/GPU validation is relevant and a display
    exists; otherwise report it as not run;
  - once at the branch commit before merge: `zig build test
    -Doptimize=ReleaseFast`.
- Report validation that could not run; never claim it passed. A display or
  sandbox failure is reported separately from a code failure.
- Default mode is `Debug`: every test and bench while working, before/after
  comparisons included, runs in Debug. ReleaseFast is for the branch commit,
  release candidates, and shipping builds; ReleaseSafe for soaks. Packaged
  builds ship `ReleaseFast`.
- Exception: a question Debug cannot answer by construction (false sharing
  between worker ranges, a SIMD or inlining gain) gets one targeted
  `tools/bench_ab.py --optimize ReleaseFast` run of the group that asks it,
  reported beside its Debug numbers. It answers that question only; it is
  never a baseline, gate, or reason to revert SIMD (`memory-performance.md`),
  and never dismisses a Debug finding: Debug at a size stands in for release
  at larger sizes.
- Before a ReleaseFast release candidate, a multi-hour ReleaseSafe soak across
  realistic to extreme entity counts and spawn/despawn churn must pass;
  ReleaseFast corrupts memory silently where ReleaseSafe reports.
- ReleaseSafe soaks are diagnostics, not an every-edit step
  (`tests-benchmarks.md`).
- Never hand-edit `zig-out/` or `.zig-cache/`. Never commit generated binaries
  or local machine paths.
- When adding `build.zig.zon` dependencies, keep hashes accurate and review the
  fingerprint (it is project identity).
