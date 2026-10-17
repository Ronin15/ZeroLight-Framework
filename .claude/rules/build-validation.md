# Build, Validation, Release

Commands and options: `docs/development-workflow.md`.

- Validation cadence:
  - while iterating: `zig build check`;
  - per commit: `check` + `idiom-lint` + only the tests of the code it
    touches (`zig build test -Dtest-filter=<module>`, under
    `-Dsanitize-thread=true` when it is threaded code), nothing more;
  - before a slice's or branch's final commit: the full `zig build test`
    (inside `zig build verify`), and under TSan when the slice touched
    threaded code;
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
  ReleaseFast run of the group that asks it
  (`tools/bench_ab.py --optimize ReleaseFast`): ReleaseFast base against
  ReleaseFast tree.
  - It answers only that question and is never a baseline or a gate.
  - Modes compare only with themselves: Debug against Debug, ReleaseFast
    against ReleaseFast.
  - It never excuses a Debug finding: a slower Debug case gets its verdict
    per `tests-benchmarks.md`, never waved off because ReleaseFast is faster.
    Debug at a size stands in for release at larger sizes.
  - The fix never reverts a SIMD-shaped loop to scalar
    (`memory-performance.md` § SIMD and core math).
- Before a ReleaseFast release candidate, a multi-hour ReleaseSafe soak across
  realistic to extreme entity counts and spawn/despawn churn must pass;
  ReleaseFast corrupts memory silently where ReleaseSafe reports.
- ReleaseSafe soaks are diagnostics, not an every-edit step
  (`tests-benchmarks.md`).
- Never hand-edit `zig-out/` or `.zig-cache/`. Never commit generated binaries
  or local machine paths.
- When adding `build.zig.zon` dependencies, keep hashes accurate and review the
  fingerprint (it is project identity).
