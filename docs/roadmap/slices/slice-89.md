## Slice 89: Thread-System Batch Follow-Ups And The World Gate Under The Rules

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 88](slice-88.md) (branch order: runs after the core-branch review work) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Owner 2026-10-23: a slice for the world-gate and
batch-tuner follow-ups, to complete after the core-branch review work.

Goal: the batch tuner settles near the best fixed batch shape at the sizes
that thread, the dispatch posts its wakes without delaying main's own ranges,
the tuner gate follows the wake cost, and the world gate's per-row terrain
reads are measured on a play-shaped fixture and grouped by chunk only if they
cost there.

### Current foundation

- Batch tuner: `src/app/thread_system.zig`. The nudge steps 1.1x, holds
  inside a 5% band, and takes its first step down (`:147`, `:151`, `:158`);
  the multiplier clamps at 4.0 (`:159`). Policy: `docs/architecture.md`
  § Thread System.
- Dispatch posts each active worker's wake in turn on main
  (`thread_system.zig:1139-1142`); main starts its own ranges after the loop
  (`:1148`).
- `threaded_batch_ns` is 60_000 (`thread_system.zig:122`), set from the measured
  dispatch floor in `58ff9e1`; it stays.
- World gate: `world_gate.zig` `gateRange` (`:248`) walks movement rows in
  store order; plane entry gathers per slice 88's plane-entry item.
- Already routed (not repeated here): slice 35's row-order and tuned-versus-fixed
  items ([35](slice-35.md)), slice 50's open tuner items ([50](slice-50.md)),
  slice 88's plane-entry gather item ([88](slice-88.md)).
- Measured (`world-gate` uniform, 65,536 rows, ReleaseFast
  `-Dcpu=x86_64_v2`, copies of `83ef090` with timing instrumentation, host
  7900X3D; `.claude/reports/world-gate-rf-debug.md`):
  - Per-row cost is even across row regions (14.8-15.4 ns/row, one CCD) and
    varies with CPU placement: 12.0 serial on CCD1; 25-30 with the SMT
    sibling busy. SMT adds nothing (6 cores 169 us; with siblings 175-179 us).
  - Main posts the 23 wakes at 1.0-1.2 us each, 22-27 us in all.
  - A straggler on a slower or shared CPU sets the join at one range per
    participant: 24 batches 121-131 us; 96 batches 112-114 us; 187-1,024
    batches no further gain.
  - The nudge cannot see the 24 to 96 gain step by step; it settles at
    x 0.75-0.92.
  - The bench's fixed controls sit at 257 / 1,025 / 2,049 batches; none near
    4x the pool.
  - Process-to-process drift (24 batches 115-187 us) tracks scheduler packing
    on CCD1 (hypothesis, untested).

### Checklist

- [ ] The first nudge comparison tests the whole range. Failure: the nudge
      climbs in 1.1x steps inside a 5% band (`thread_system.zig:147`,
      `:151`), and the 1x to 4x gain is gradual, so no single step clears the
      band and the tuner walks down. Failure scenario: a threaded stage
      settles below the best shape and runs slower than a fixed control. Pass:
      a threaded tuner's first comparison tests 1x against the 4x clamp in one
      jump, then nudges locally from the winner; `world-gate` 65,536
      ReleaseFast tuned within spread of the best fixed shape; no bench group
      slower (ReleaseFast at threading sizes,
      `.claude/rules/build-validation.md`).
- [ ] Bench controls cover the clamp. Failure: the fixed controls sit at 257 /
      1,025 / 2,049 batches, none near 4x the pool, so "best control" misses
      the shape the tuner can reach. Pass: a fixed case near 4x the pool.
- [ ] Wake posting does not delay main's ranges. Failure: main posts all
      wakes before its first range (`thread_system.zig:1139-1148`), so the
      last worker starts 20-27 us after publish and main idles that long.
      Pass: main runs its ranges without waiting for every post, or woken
      workers wake the next; dispatch start skew measured down in ReleaseFast;
      serial == threaded.
- [ ] World gate and plane entry under the data rules
      (`.claude/rules/memory-performance.md` § Data-oriented design,
      `.claude/rules/engine-design.md` § Target scale: the chunk is the unit).
      Measure first on a play-shaped fixture: rows scattered across chunks and
      levels, not the ordered uniform grid. Pass: the per-row terrain lookups
      (`world_gate.zig:248`, `:317`) are reported as a cost or not there; only
      if they cost, rows group by `(level, chunk)`, serial == threaded. Links
      slice 35's row-order item and slice 88's plane-entry item.
- [ ] A fresh one-off build set's first pick fits the build. Failure: every
      nav build starts the level build set fresh on the one-off config
      (`Tuners.startNavBuild`, `pathfinding/system.zig:296`), so its first
      selection starts from the full pool whatever the build's size.
      Measured: `nav-level-add` 1024008 ReleaseFast tuned 186.6 us
      (180.8-192.6) on the persistent set (`19fe22a`) against 201.7 us
      (196.3-211.6) fresh, main 122 to 104 us; remask, patch, and gather
      each 23w/48r [3/3]. Debug tuned against serial: 256008 +13%, replace
      10256008 +16%. That the 48-range first pick causes it is a hypothesis.
      Candidate: the reset keeps each stage's learned per-item cost and drops
      only its profile, so the first pick is predicted from items x cost.
      Pass: measure the cause first; `nav-level-add` 1024008 ReleaseFast tuned
      within spread of the persistent-set base; serial == threaded.
- [ ] A judged jump shape covers what it proves. Failure: the jump judgment
      (`AdaptiveWorkTuner.judgeJump`, `thread_system.zig:419`) is keyed by the
      exact (learned, requested) count pair (`:344-346`), so a jump to 65
      items after a judged one to 64 discards the judgment and re-predicts
      from the in-band model, the cause the judgment fixes; link-fold and the
      collision spike repeat identical counts. That play rarely repeats exact
      counts is a hypothesis. Pass: measure jump-count repetition on a
      play-shaped workload first; if it does not repeat, a judged entry covers
      its count band and a bench variant varies the jump count within the band.
- [ ] A judged jump re-tunes on evidence (`.claude/rules/threading.md`
      § Building a stage). Failure: once judged (`thread_system.zig:423`), a
      jump ignores its later records while the counts repeat, so one judged
      inline at 25 us stays inline at 200 us. Pass: a sustained shift in the
      judged shape's own records reopens the judgment, without re-probing on
      noise at the gate; tuner tests for both.
- [ ] Movement's tuned case settles on stable worker counts. Measured:
      `movement` 4096 Debug tuned settles anywhere from 6 to 21 workers across
      runs (spread 12-38%), on `95b9fcd` and after; cause unmeasured.
      Pass: the tuned case's settled shape and time within spread across runs.
- [ ] An inline tuned case matches serial. Measured: `pathfinding-link-fold`
      1016032768 ReleaseFast, every stage inline in the tuned case, tuned
      13-16% slower than `serial-direct`, on `95b9fcd` and after; cause
      unmeasured. Also: once a link-fold run has done five or more batches,
      every case, serial included, has one timed fold at about 440-500 us
      (Debug), which a 3-iteration mean carries. Pass: tuned within spread of
      serial where it runs inline; the slow fold attributed and fixed or
      reported.
- [ ] A whole-group Debug smoke run of every bench group under the batch tuner
      (dispatch and settle checks pass or fail), since only 13 groups ran
      after `83ef090`.

### Acceptance checks

- [ ] Every item is landed or is routed with its `file:line` and failure
      scenario.
- [ ] Touched groups within run-to-run spread, ReleaseFast for thread-policy
      changes.
- [ ] `zig build verify` passes.
