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
- Before a ReleaseFast release candidate, a multi-hour ReleaseSafe soak across
  realistic to extreme entity counts and spawn/despawn churn must pass;
  ReleaseFast corrupts memory silently where ReleaseSafe reports.
- ReleaseSafe soaks are diagnostics, not an every-edit step
  (`tests-benchmarks.md`).
- Never hand-edit `zig-out/` or `.zig-cache/`. Never commit generated binaries
  or local machine paths.
- When adding `build.zig.zon` dependencies, keep hashes accurate and review the
  fingerprint (it is project identity).
