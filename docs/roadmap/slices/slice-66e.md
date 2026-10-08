## Slice 66E: Authoritative Perf Runner

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52C](slice-52c.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first release-candidate tag of a
game.** Until then 52C's hosted-runner numbers (trend data) and manual
reference runs suffice.

Goal: one self-hosted runner on fixed reference hardware, in a verified
reference state, runs a fixed set of scaling bench groups in
ReleaseFast/`ship` and compares them against a committed baseline. It fails
when a row moves beyond its measured run-to-run spread or when a group's
growth shape departs from its cost model (flat for a local change, linear
where linear is right), never on an absolute frame-time verdict. Release
tags pass it before Steam `staging` is promoted to `default`.

### Current foundation

- `src/benchmarks/suite.zig`: `Options` / `parseOptions`, per-case
  `RunStats` (mean/min/max/iterations), human-readable tables only
  (`printGroupReport`); filtering a non-baseline case auto-adds
  `serial-direct`.
- `tools/bench_run.py` saves header-stamped runs to `benchmark_outputs/`
  (gitignored); 52C adds optimize and CPU-baseline options.
- Size profiles: `eventScaleCounts` quick is `{1024, 4096, 10000}`;
  `steering` and the pathfinding fallback group use their own smaller
  ladders; 52C's `frame-battle` runs one fixed size.
- Reference machine: AMD Ryzen 9 7900X3D, 12 cores / 24 threads, two CCDs
  (CCD0 `0-5,12-17` with the 96 MiB V-Cache L3; CCD1 `6-11,18-23` with
  32 MiB); `amd-pstate-epp`, dev default `powersave` with boost on.
- The repository is public, and fork PR workflows can edit workflow files.

### Architecture notes

- Every number comes from `zig build bench`; sizes are sample points on a
  curve, never targets, capacities, or acceptance thresholds; a regression
  is a change beyond the run-to-run spread measured by 3 interleaved reps
  and medians (`.claude/rules/tests-benchmarks.md`).
- Each gated group runs at least three sizes far enough apart to show its
  shape, so a cost that starts growing with world size, depth, or world
  count fails even when one size looks fine. The gate set covers the
  scaling groups that exist at landing, including 64G's `chunk-scale` and
  the world-instance and far-simulation groups (74, 75) when present, plus
  the multi-worker cases (`.claude/rules/threading.md`).
- Tolerances come from the recorded spread and are never widened to absorb
  a regression; a row too noisy to gate after the bounded repetition
  ladder is removed from the gate with its noise recorded and stays as
  trend data.
- Runs are pinned to one CCD, and preflight refuses a runner not in the
  reference state (governor, boost, load, no competing processes, matching
  host and cpuset); a baseline from a different host, cpuset, worker count,
  CPU baseline, or Zig version is incomparable, never compared.
- The baseline is committed and changes only through a reviewed PR; the
  workflow has no write path to it and triggers only on dispatch and `v*`
  tags (an offline runner never turns automatic triggers red).
- Runner security: fork-workflow approval required, a dedicated
  unprivileged runner user, repository-scoped registration, no secrets.
- No production `src/` change; machine-readable records are a bench-suite
  utility tested in `suite.zig`.
- VoidLight keeps "current" run copies with no thresholds and gates only a
  SIMD speedup ratio; port the comparable-run idea as the committed
  baseline, not ratio gates.

### Checklist

- [ ] Machine-readable per-case record lines from the bench suite behind a
      flag, with golden tests in `suite.zig`; documented in
      `docs/development-workflow.md` and `tools/README.md`.
- [ ] `tools/perf_gate.py` (preflight, run, compare against spread and
      shape, promote, self-test in `tools-selftest`) covering a pass, a
      beyond-spread regression, a shape change, a header mismatch, and
      median selection.
- [ ] Runner registration, unprivileged user, fork-approval setting, and
      the host reference-state unit; host facts recorded in the docs.
- [ ] `perf.yml` (dispatch and `v*` tags only).
- [ ] First baseline: noise runs on one commit, spread recorded per row,
      then promoted and committed.
- [ ] Docs: `docs/development-workflow.md` Authoritative Perf Runner (gate
      set, spread and shape policy, pinning, preflight, security,
      promotion), the "trend data vs authoritative" distinction, the
      Release Checklist line.
- [ ] Add the perf-gate spread/shape and baseline-promotion rule to
      `.claude/rules/build-validation.md` when this lands.

### Acceptance checks

- [ ] Two dispatch runs on an unchanged commit pass against a baseline
      promoted from a third; each row's delta stays within its recorded
      spread.
- [ ] The self-test covers the regression, shape-change, and
      incomparable-baseline exits.
- [ ] With boost on, preflight fails "runner not in reference state".
- [ ] A `v*` test tag runs the gate on the self-hosted runner and uploads
      its raw runs.
- [ ] `zig build verify` passes; docs updated.
