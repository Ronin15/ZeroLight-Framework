## Slice 52C: CI Workflows And Release Performance Baseline

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52A](slice-52a.md), [Slice 49](slice-49.md), [Slice 50](slice-50.md) (TSan job), [Slice 52B](slice-52b.md) (tag job) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** The verify, gpu-smoke, shader, and soak workflows need
52A; the `frame-battle` digest needs 49's checksum; the TSan job needs 50; the
tag packaging job needs 52B.

Goal: every push to `main` and every PR runs the full gate on Linux x86_64,
Windows x86_64 (native and cross from Linux), and macOS arm64; a display-gated
gpu-smoke runs under Xvfb with Mesa lavapipe; tags produce downloadable per-OS
packages with symbols; a ReleaseSafe soak and release bench run archives its
outputs. `frame-battle` measures how the full fixed step plus CPU render prep
scales with population and world size, and proves serial == threaded and
`compat` == `ship` state digests at every size.

### Current foundation

- `.github/` holds only `CODEOWNERS` and `FUNDING.yml`; no workflows exist
  (VoidLight has none either).
- `zig build verify` runs check, test, shaders, and the lints; the Python
  lints run as `python3`, which GitHub's Windows images do not reliably
  provide.
- The Zig 0.17 changelog's Windows residual is open: no real Windows host has
  run `test` / `bench` / `run` / `gpu-smoke` with the PATH prepend.
- `gpu-smoke` needs a display.
- Benches: groups register in `src/benchmarks/runner.zig`; the suite accepts
  `--group`, `--case`, `--items`, `--profile`, `--iterations`, `--details`;
  outputs are gitignored. `tools/bench_run.py` always runs Debug and calls
  `os.uname()`, which Windows lacks.
- No bench drives the full fixed step; groups are per system, and
  `render-game-prep` covers CPU render prep on synthetic fixtures. The only
  full-frame reference is manual ReleaseSafe perf-log dumps at one demo
  population, which reproduce across neither machines nor commits.
- `GameDemoState` builds headless: `update(UpdateContext)` runs input, the
  pipeline, audio queueing, particles, camera, and the structural commit;
  `RuntimeAssets` can be seeded with metadata only; a serial `ThreadSystem` is
  `.{ .max_worker_threads = 0 }`.

### Architecture notes

- Owner direction: benches measure scaling shape, never a target count; the
  demo's population and world size are never bench sizes or thresholds
  (`.claude/rules/engine-design.md` § Target scale,
  `.claude/rules/tests-benchmarks.md`).
- `frame-battle` runs at least three points each along population and world
  extent (level size, depth), building its fixture directly rather than from
  the demo config, with a fixed settle step count (never scaled) so every case
  runs identical steps. Once [Slice 74](slice-74.md) and
  [Slice 75](slice-75.md) land, world count and far-simulated population join
  the ladder in their own changes. Sim and render-prep halves are timed
  separately; cases are serial and production threaded.
- Digest: `state_digest` is 49's `simulationChecksum()` (covering every world
  instance) plus 64B's NaN count, taken after the timed loop; the bench defines
  no hash. The checksum is same-binary, so digests compare only within one CI
  job, never as archived references. A mismatch fails the job and is fixed at
  its cause (**zig-debug-specialist**), never by relaxing exact equality.
- Bench-fixture correctness relies on internal asserts in real runs; no test
  calls the bench (`.claude/rules/tests-benchmarks.md`).
- Workflows: `ci.yml` (Linux, Linux TSan, Linux gpu-smoke, Windows, macOS),
  `shader-artifacts.yml` (regenerate on Windows with pinned Vulkan SDK and a
  hash-checked DXC, then require no diff), `release.yml` (sniper-container
  Linux at the glibc 2.31 floor, Windows cross, macOS 11 floor, symbols
  artifacts, tag-only publish), `soak-bench.yml` (manual first; weekly cron
  only after a recorded duration). Gates never use `continue-on-error`; a job
  that cannot run is deleted with the reason recorded, never left red.
- gpu-smoke (decision): Linux Xvfb + lavapipe with validation layers,
  blocking; not on hosted macOS or Windows (no dependable device). Real-GPU
  smoke stays a manual pre-release gate.
- Soak fails only on test, assert, safety panic, digest mismatch, or nonzero
  NaN count, never on timing; hosted-runner numbers are trend data, and
  authoritative release numbers come from the reference machine. The soak's
  full `--profile stress` sweep is the one full-suite run this slice names.
- Pinning: Zig from zon in one step; GitHub-owned actions by major tag;
  third-party actions and container images by full SHA or digest.
- Owners: `.github/workflows/`, a `-Dpython` build option routing every Python
  step, `tools/bench_run.py`, and `src/benchmarks/frame.zig`; no production
  API change.
- VoidLight: no CI to port; its manual ReleaseSafe soak model becomes this
  reproducible soak, which supplements DW's multi-hour soak gate; do not port
  its section-GC, mold, or ccache plumbing.

### Checklist

- [ ] `-Dpython=<exe>` with a host-dependent default, used by every Python
      build step.
- [ ] `tools/bench_run.py` `--optimize` and `--cpu-baseline` recorded in the
      header, `platform.node()`; `tools/README.md`.
- [ ] `frame-battle` bench (`src/benchmarks/frame.zig`): direct-built fixture
      ladder over population and world extent, fixed settle, split sim and
      render-prep timers, serial and threaded cases, `state_digest`, and
      internal asserts; registered.
- [ ] (added by Slice 64) `state_nan_values` beside `state_digest`; the soak
      fails on any nonzero value.
- [ ] `ci.yml` jobs as above, including the `x86_64_v2` header grep, the
      package refusals, the Windows cross steps, and the TSan race gate on
      Slice 50's threaded groups.
- [ ] `shader-artifacts.yml` with pinned tools and failure-upload of
      regenerated artifacts.
- [ ] `release.yml` with per-OS packages, `symbols-windows`, every upload
      failing on no files, and tag-only publish.
- [ ] (added by Slice 66) macOS release job uploads its `package-symbols` dir
      as `symbols-macos` (66A later renames both per OS and arch).
- [ ] `soak-bench.yml`: ReleaseSafe tests and long `frame-battle` run, stress
      sweep, serial-vs-threaded and `compat`-vs-`ship` digest checks at every
      ladder point, ReleaseFast baseline, artifact upload; cron after a
      recorded duration.
- [ ] Docs: DW "Continuous Integration" (what gates, artifacts, shader
      regeneration, trend-data caveat, lavapipe scope); close the 0.17
      changelog's Windows `test`/`bench` residual (`run` and `gpu-smoke` stay
      manual).
- [ ] Add the determinism-mismatch handling rule to
      `.claude/rules/simulation.md` when this lands.

### Acceptance checks

- [ ] `ci.yml` is green on a PR across all five jobs.
- [ ] A `.glsl` edit without regeneration fails `verify` and
      `shader-artifacts`; committing CI's artifacts turns both green.
- [ ] A test tag publishes three archives plus `symbols-windows` and
      `symbols-macos`; each extracts to the 52B layout; the sniper-built Linux
      binary runs on the reference Arch host (manual, display).
- [ ] A manual `soak-bench` run completes and uploads its outputs; its duration
      sets the timeout before the cron is enabled.
- [ ] `frame-battle` digests are equal serial vs threaded and `compat` vs
      `ship` at every ladder point; its scaling shape across the ladder is
      recorded on the reference machine in ReleaseFast and ReleaseSafe, and the
      `compat`/`ship` A/B completes 52A's baseline evidence.
- [ ] `zig build verify` passes; docs updated.
