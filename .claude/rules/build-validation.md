---
paths:
  - "src/**"
  - "build.zig"
  - "build.zig.zon"
  - "tools/**"
  - "assets/shaders/**"
---

# Build, Validation, Release

Commands and options: `docs/development-workflow.md`.

- Validation cadence:
  - while iterating: `zig build check`;
  - per commit: `check` + `idiom-lint` + only the tests of the code it
    touches (`zig build test -Dtest-filter=<module>`, under
    `-Dsanitize-thread=true` when it is threaded code), nothing more;
  - before a slice's or branch's final commit: the full `zig build test`
    (inside `zig build verify`), under TSan too when the slice touched
    threaded code;
  - after shader source or shader wiring changes: `zig build shaders`;
  - `gpu-smoke` only when display/GPU validation is relevant and a display
    exists; otherwise report it as not run;
  - once at the branch commit before merge:
    `zig build test -Doptimize=ReleaseFast`.
- A command that runs on every edit or every commit has to finish quickly.
  The full test suite, the ReleaseFast test, ThreadSanitizer, soaks, and
  bench sweeps are branch-commit checks, not every-edit steps. While
  iterating, `zig build check` (it runs the idiom lint) and, when test
  bodies changed, `zig build test-compile` are the quick checks. They
  type-check. They do not produce a pass.
- Report validation that could not run; never claim it passed. A display,
  GPU, or sandbox failure is reported separately from a code failure.
- Default mode is `Debug`: every test and bench while working, before/after
  comparisons included, runs in Debug. ReleaseFast is for the branch commit,
  release candidates, and shipping builds; packaged builds ship `ReleaseFast`.
- Exception: a question Debug cannot answer by construction gets one
  targeted ReleaseFast run of the group that asks it
  (`tools/bench_ab.py --optimize ReleaseFast`), ReleaseFast base against
  ReleaseFast tree: false sharing between worker ranges, an inlining gain, a
  SIMD-vs-scalar tie, or a SIMD-shaped loop slower in Debug than the code it
  replaces. That run shows the SIMD gain Debug hides; the SIMD shape stays
  (`memory-performance.md` § SIMD and core math). It answers only that
  question and is never a baseline or a gate. Modes compare only with
  themselves (Debug against Debug, ReleaseFast against ReleaseFast). Any
  other slower Debug case gets its verdict per `tests-benchmarks.md`; Debug
  at a size stands in for release at larger sizes.
- A cost that exists only in Debug (safety checks, allocator fills of
  reserved or freed memory, lane-by-lane vector lowering) is never tuned or
  redesigned. A Debug slowdown suspected to be one gets the same targeted
  ReleaseFast run to confirm it, then is reported as Debug overhead.
- ReleaseSafe is for soaks, which are diagnostics, not an every-edit step.
  Before a ReleaseFast release candidate, a multi-hour ReleaseSafe soak across
  realistic to extreme entity counts and spawn/despawn churn must pass;
  ReleaseFast corrupts memory silently where ReleaseSafe reports.
- Never hand-edit `zig-out/` or `.zig-cache/`. Never commit generated binaries
  or local machine paths.
- When adding `build.zig.zon` dependencies, keep hashes accurate and review the
  fingerprint (it is project identity).
