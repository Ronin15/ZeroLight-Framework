## Slice 66E: Authoritative Perf Runner

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52C](slice-52c.md) (gated on the first RC tag) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first release-candidate tag of a game.**
Until then, 52C's hosted-runner numbers (trend data) and manual reference runs
suffice. After **52C** (`frame-battle`, `bench_run.py --optimize/--cpu-baseline`).

Goal: one self-hosted runner on fixed reference hardware, in a verified
reference state, runs a fixed bench set in ReleaseFast/`ship`. It compares the
result against a committed baseline with fixed regression thresholds, and
fails on regression. Release tags must pass it before Steam `staging` is
promoted to `default`.

### Current foundation (do not rebuild)

- `src/benchmarks/suite.zig`:
  - `Options` (`:38-47`) and `parseOptions` (`:411`).
  - `RunStats.mean_ns/min_ns/max_ns/iterations` (`:170-200`).
  - Human-readable tables only, via `std.debug.print` (`printGroupReport`,
    `:618`).
  - Filtering a non-baseline `--case` auto-adds `serial-direct` (`:603-605`).
- `tools/bench_run.py` saves header-stamped runs to `benchmark_outputs/`
  (gitignored). 52C adds `--optimize` and `--cpu-baseline`.
- Group item counts:
  - `movement`, `collision`, `perception`, and `render-game-prep` use
    `eventScaleCounts` (quick `{1024, 4096, 10000}`, `suite.zig:26`);
  - `steering` quick is `{128, 512, 1024}`;
  - `pathfinding-hard-fallback-budget` quick is `{16, 64, 128}`;
  - `frame-battle` (52C) is fixed at 2048.
- Reference machine (52A/52C): AMD Ryzen 9 7900X3D, 12 cores / 24 threads, two
  CCDs.
  - CCD0 = CPUs `0-5,12-17`, with a 96 MiB L3 (3D V-Cache:
    `/sys/devices/system/cpu/cpu0/cache/index3/size` = `98304K`).
  - CCD1 = `6-11,18-23`, with a 32 MiB L3.
  - The cpufreq driver is `amd-pstate-epp`. The dev default is the
    `powersave` governor with `/sys/devices/system/cpu/cpufreq/boost` = 1.
- The repo is public (`Ronin15/ZeroLight-Framework`). Fork PR workflows can
  edit workflow files.

### Architecture notes

**Owners:**
- `src/benchmarks/suite.zig`: the `--records` output.
- `tools/perf_gate.py`: stdlib Python.
- `perf/baselines/zl-perf-ref.txt`: committed.
- `.github/workflows/perf.yml`.
- `docs/development-workflow.md`.

There is no production `src/` change. All numbers come from `zig build bench`
(CLAUDE.md), driven through `bench_run.py`.

**Machine-readable records (`suite.zig`):**
- New `Options.records: bool = false`, set by `--records` (also listed in
  `printUsage`).
- When set, `printGroupReport` is followed by one line per case result, in
  case order:

  ```text
  bench_record v1 group=<name> items=<n> case=<case> status=measured|skipped iterations=<n> mean_ns=<u64> min_ns=<u64> max_ns=<u64>
  ```

- Formatting is a pure `formatRecordLine(writer, group_name, result)` over
  `std.Io.Writer`. Tests sit in `suite.zig`'s own test block, against
  hand-built `CaseResult` stubs (allowed by CLAUDE.md for suite utilities):
  - a measured line golden;
  - a skipped line golden;
  - `parseOptions(&.{"--records"})` sets the flag.

**Gate set (fixed; `tools/perf_gate.py` `GATE`)**

Every row runs with `--case thread-adaptive-tuned-range --records`, so each
row yields `serial-direct` and `thread-adaptive-tuned-range`.

| Group | Extra args | Threshold |
| --- | --- | --- |
| `frame-battle` | `--iterations 600` (2048 fixed) | 5% |
| `movement` | `--items 10000 --iterations 200` | 10% |
| `steering` | `--items 1024 --iterations 200` | 10% |
| `collision` | `--items 10000 --iterations 200` | 10% |
| `perception` | `--items 10000 --iterations 200` | 10% |
| `render-game-prep` | `--items 10000 --iterations 200` | 10% |
| `pathfinding-hard-fallback-budget` | `--items 128 --iterations 200` | 10% |

**Constants:**
- `perf_repetitions = 3` separate processes per row; the row value is the
  median of the three `mean_ns`.
- `regression_threshold_frame = 0.05`.
- `regression_threshold_system = 0.10`.
- `regression_abs_floor_ns = 2_000`. A delta under 2 µs never fails, which
  keeps µs-scale rows out of noise.
- `improvement_notice = 0.10`. An improvement of 10% or more prints "consider
  promoting the baseline" and never fails.

These are fixed numbers, and the thresholds are never raised. The noise
ladder has exactly two rungs and a terminal outcome:
1. `perf_repetitions = 3` (default).
2. If any row's noise exceeds half its threshold, `perf_repetitions = 5` for
   every row, then re-run the noise check.
3. If a row still exceeds half its threshold at 5, that row is removed from
   `GATE`. Its measured noise and the reason are recorded in the docs'
   gate table, and it keeps running as 52C hosted-runner trend data. The
   remaining rows gate releases and the slice closes.

**Runs:** `ReleaseFast`, `-Dcpu-baseline=ship` (`x86_64_v2`, the shipped ISA).

**Pinning:** every bench process runs under `taskset -c "$ZL_PERF_CPUSET"`.
On the reference host the cpuset is `0-5,12-17` (the V-Cache CCD), so
cross-CCD scheduling noise never enters a number. Zig's
`std.Thread.getCpuCount` honors the affinity mask, so the bench header's
`worker_threads_available` records the pinned count. A warm, unpinned `zig
build check -Doptimize=ReleaseFast -Dcpu-baseline=ship` runs first, so the
pinned runs only execute the cached bench binary.

**`tools/perf_gate.py` subcommands:**
- `preflight` (Linux). Every check failing fails the job with "runner not in
  reference state":
  - the governor is `performance` on every CPU in the cpuset;
  - boost is off: `/sys/devices/system/cpu/cpufreq/boost` = 0, or for
    `intel_pstate`, `no_turbo` = 1;
  - the 1-minute loadavg is below 1.0;
  - no other `benchmarks`/`zig` processes are running;
  - `host_id` (first 12 hex of `sha256(/etc/machine-id)`; the raw id is never
    stored) and the cpuset equal the baseline header's.
- `run --out <dir>`: the warm build, then `perf_repetitions` ×
  `GATE` pinned runs through `bench_run.py --optimize ReleaseFast
  --cpu-baseline ship --keep 200 -- <args>`. Writes `summary.txt`
  (median-of-3 records plus header).
- `compare --baseline <file> --candidate <summary>`:
  - It refuses, with exit code 2 ("baseline incomparable"), on any header
    mismatch: `host_id`, `cpu_model`, cpuset, `worker_threads_available`,
    `cpu_baseline`, `zig` version.
  - Otherwise it prints a table (row, baseline, candidate, delta%, verdict).
  - It exits 1 on any regression and 0 otherwise.
- `promote --from <summary> --to perf/baselines/zl-perf-ref.txt`: copies the
  file and adds the commit, date, and kernel to the header. A human commits it
  in a PR whose description justifies the change. CI never writes the
  baseline.
- `--self-test`: synthetic summaries covering a pass, a 12% regression on a
  system row, a 6% regression on `frame-battle`, a sub-floor delta, a header
  mismatch (exit 2), and median selection. Appended to `tools-selftest`.

**Baseline file `perf/baselines/zl-perf-ref.txt`:**
- `# key value` header lines: `host_id`, `cpu_model`, `kernel`, `cpuset`,
  `governor`, `boost`, `worker_threads_available`, `zig`, `cpu_baseline`,
  `commit`, `date`.
- Then `bench_record` lines.
- One file per runner label. It is committed, so every perf change is
  reviewable in git history.

**Workflow `perf.yml`:**
- Triggers: `workflow_dispatch` and `push: tags: ['v*']` only. Never
  `pull_request` or `pull_request_target`, and no push-to-`main` trigger.
  GitHub fails a job that waits more than 24 h for an offline runner, so
  automatic triggers would turn "the reference box is off" into red runs.
- `runs-on: [self-hosted, linux, x64, zl-perf-ref]`.
- `concurrency: { group: perf-reference, cancel-in-progress: false }`.
- `timeout-minutes: 90`.
- `permissions: contents: read`. No secrets.
- Steps:
  1. checkout;
  2. `perf_gate.py preflight`;
  3. `run`;
  4. `compare`;
  5. upload `perf-${{ github.run_id }}` (raw runs plus summary, 90 days,
     `if: always()`).
- A tag run must be green before Steam `staging` is promoted (Release
  Checklist).

**Runner host security (public repo):**
- Repository setting: "Require approval for all outside collaborators" on fork
  PR workflows, so a fork cannot add a job targeting `zl-perf-ref` without
  review.
- The runner service runs as a dedicated unprivileged user `zlperf` with no
  sudo and no read access to the developer's home.
- Its work directory is wiped by `actions/checkout`'s clean.
- The runner is registered to this repository only.

**Host reference state:**
- A root `oneshot` unit, `zl-perf-prep.service` (text in the docs), sets the
  `performance` governor (`cpupower frequency-set -g performance`) and
  `boost=0`.
- The unit is enabled together with the runner service when the host serves
  as the reference runner, and disabled for normal development. Preflight
  enforces the state.
- `ZL_PERF_CPUSET` is set in the runner's `.env`.

### Checklist

- [ ] `--records` + `formatRecordLine` in `suite.zig`, with tests; document
      it in `docs/development-workflow.md` Benchmarks and `tools/README.md`.
- [ ] `tools/perf_gate.py` (`preflight`, `run`, `compare`, `promote`,
      `--self-test` in `tools-selftest`).
- [ ] Register the runner (`zl-perf-ref` label, `zlperf` user, repository
      fork-approval setting) and install `zl-perf-prep.service`. Record the
      host facts in the docs.
- [ ] `perf.yml`.
- [ ] First baseline: two dispatch runs on the same commit (noise check
      below), then `promote` and commit `perf/baselines/zl-perf-ref.txt`.
- [ ] Docs: `docs/development-workflow.md` "Authoritative Perf Runner" (gate
      table, constants, pinning rationale, preflight, security, promotion
      policy, the "trend data vs authoritative" distinction replacing 52C's
      sentence), the Release Checklist line, and the frame-battle row in the
      roadmap control table sourced from this runner.

### Acceptance checks

- [ ] Noise: two dispatch runs on an unchanged commit both pass against a
      baseline promoted from a third run. Every row's |delta| is under half
      its threshold (frame-battle < 2.5%, others < 5%), and the maximum
      deltas are recorded in the docs. If any row exceeds half its threshold,
      apply the noise ladder above (5 repetitions, then removal of the row
      from `GATE` with its recorded noise). The thresholds are never
      raised.
- [ ] `perf_gate.py --self-test` covers the 12% / 6% regression exits and the
      header-mismatch exit 2.
- [ ] With `boost=1`, preflight fails with "runner not in reference state".
- [ ] A `v*` test tag triggers `perf.yml` on the self-hosted runner and
      uploads `perf-<run_id>`.
- [ ] `zig build verify` passes; the docs are updated.

### VoidLight reference

- VoidLight's `tests/test_scripts/run_*_benchmark.sh` copy each run to a
  "current" file "for regression comparison" but apply no thresholds. Only
  `run_simd_benchmark.sh:50` checks a fixed 2.0× minimum speedup. It has no
  CI and no fixed-hardware runner.
- **Port** the keep-a-comparable-run idea, as the committed baseline.
- **Do not port** speedup-ratio gates. Ratios hide absolute regressions in
  both rows.

