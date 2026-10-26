## Slice 89: Thread-System Batch Follow-Ups And The World Gate Under The Rules

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: the core-branch review work (`f4c4844`); runs first in the core branch, ahead of 86, 85, 35's tile gate, 87, and 88 · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: programming landed (`f3ee24c`, `6b7138e`, `8bfdbfc`, `bc336f4`); five items stay open
as recorded data (owner 2026-10-25: recorded, not chased); the wake-posting item moved to
[slice 90](slice-90.md).** Owner 2026-10-23: a slice for the
world-gate and batch-tuner follow-ups. Ordered first in the core branch (owner delegated to the
criteria 2026-10-24): its tuner fixes change how every later slice's tuned cases are judged
(`.claude/rules/tests-benchmarks.md` § Benchmarks). The `750ce0a` baseline predates its tuner
change; the one whole-suite Debug run after it is `.claude/reports/bench-suite-6b7138e.txt`
(later tuner changes ran targeted groups; verdicts in `.claude/reports/slice89-verdicts.md`).

Goal: the batch tuner settles near the best fixed batch shape at the sizes
that thread, the dispatch posts its wakes without delaying main's own ranges,
and the world gate's per-row terrain reads are measured on a play-shaped
fixture and grouped by chunk only if they cost there.

### Current foundation

- Batch tuner: `src/app/thread_system.zig`. The nudge steps 1.1x (`:156`),
  compares a step against `nudge_stepped_band` (`:155`, about 3.4%), holds
  inside the 5% band (`:152`), and takes its first local step down (`:163`); the
  multiplier clamps at 0.25-4.0 (`:157`, `:172`). The first comparison trials the
  clamp top (`startClampTrial`, `:771`) and the EMA seeds from a median of 3
  (`:170`). A fresh `full_pool` tuner's first selection is 2 batches per
  participant (`:189`, `:361`). Policy: `docs/architecture.md` § Thread System.
- Dispatch flips the active workers' wake bits and wakes once per wake word
  (slice 90, `07b9c9a`; `thread_system.zig:1513`); it was a per-worker semaphore
  post when measured below. A tree wake was measured slower and is not pursued
  (slice 50 § Measured and not pursued, owner 2026-10-15).
- The gate (`threaded_batch_ns`) was 60_000, set from the measured dispatch floor in
  `58ff9e1`; slice 90 (`776c1ec`) calibrates it at startup. Numbers below are at 60_000.
- World gate: `systems/world_gate.zig` `gateRange` (`:250`) walks movement rows in
  store order; plane entry gathers per slice 88's plane-entry item. The bench's
  `scattered` / `scattered-sorted` pair (`benchmarks/world_gate.zig`) holds the
  same gated rows in random store order against `(level, chunk)` order.
- Measured (`production-step` 1024-side, 8 levels, ReleaseFast
  `-Dcpu=x86_64_v2`, one run each, this host): 4,096 population serial 318.8 us,
  tuned 329.4 us, 0.5 threaded dispatches per step (collision 121 us, steering
  78 us, and world gate 38 us run inline under the 60 us gate); 16,384 serial
  1.30 ms, tuned 658.2 us, 9 threaded dispatches per step at 26-50 us each.
- Fixed controls: every group with fixed cases also runs `thread-clamp-range`
  (`batches_per_participant = max_batch_multiplier`, `docs/development-workflow.md`
  § Benchmarks).
- Already routed (not repeated here): slice 35's row-order item moved here
  (the world-gate item below), slice 50's other open tuner items ([50](slice-50.md)),
  slice 88's plane-entry gather item ([88](slice-88.md)). Merged here (owner
  2026-10-24): slice 35's tuned-versus-fixed item, and slice 50's first-shape,
  movement, and cold-seed items.
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
  - Process-to-process drift (24 batches 115-187 us) tracks scheduler packing
    on CCD1 (hypothesis, untested).

### Checklist

- [x] The tuner reaches the best batch shape it can dispatch (`6b7138e`). RF
      `world-gate` 65,536 tuned at the clamp shape, 167.5 -> 162.7 us (3 reps);
      the whole-suite Debug run (`.claude/reports/bench-suite-6b7138e.txt`) cut
      tuned cases over 25% behind the best control from 40 to 24, the rest Debug
      overhead or recorded in the open items below
      (`.claude/reports/slice89-verdicts.md` § A).
- [x] Bench controls cover the clamp (`f3ee24c`): `thread-clamp-range` in every
      group with fixed controls, counted in the best control.
- [x] A judged jump covers its count band and re-tunes on evidence (`8bfdbfc`).
      Debug `pathfinding-link-fold` 8192 tuned 322.4 -> 275.7 us; uniform
      configs 24-25 of 30 jumps off the entry's count, 0 re-predicted.
- [x] Movement's tuned case is stable across runs: tuned at or ahead of the best
      control in 6 of 6 runs at 4,096 and 10,000 (verdicts § B); settles on
      14-23 workers.
- [x] Steering's tuned cases match their best control: every case at or within
      noise of it in the Debug suite.
- [x] `perception-crowd` tuned at the clamp matches its control (verdicts § B).
- [x] Inline-under-gate Debug gaps: all 11 cases are Debug overhead in
      ReleaseFast (verdicts § C).
- [x] Tuned collision cases match their best control: within noise or tuned
      faster in the Debug suite; `world-create-statics` 2,048 is Debug
      allocator overhead on per-participant reserves (ReleaseFast tuned 588.9
      against serial 648.6 us, `.claude/reports/slice89-statics-landing.md`).
- [x] A whole-group Debug smoke run of every bench group under the batch tuner
      (dispatch and settle checks pass or fail). Answered by the 750ce0a
      whole-suite Debug run (`.claude/reports/bench-baseline-750ce0a.txt`):
      every group ran, every assert held.
- [ ] A fresh one-off's first pick fits its work. Failure: a small-level nav
      build is a one-off of about 80 us: RF `nav-level-add` 256008 tuned 85.9
      against serial 16.1 us (23/23 workers; Debug 256-side configs +92 to +138
      us over fixed-2). A fresh `full_pool` tuner picks the whole pool at 2
      batches per participant (`thread_system.zig:361`, `Tuners.startNavBuild`,
      `pathfinding/system.zig:298`); the per-item seed from the first threaded
      batch is duration x participants (`thread_system.zig:899-900`, about 24x
      high) and is never corrected, because main runs no range in that shape and
      its work cannot seed it
      (`.claude/reports/slice89-fresh-pick-landing.md`,
      `slice89-seed-landing.md`). The 1024008 RF sub-pass holds (tuned 138.8 us
      at the clamp). Recorded, not chased (owner 2026-10-25); a fix needs a
      cost-model change. Pass: Debug 256-side configs within spread of their
      best control; the world-create surface phase within spread of `4998400`
      in Debug or reported as Debug overhead with the ReleaseFast confirmation;
      serial == threaded. Merged: slice 50's first-shape item.
- [x] Wake posting does not delay main's ranges: moved to [slice 90](slice-90.md)
      (owner 2026-10-25, with startup calibration). Measured: main posts 23 wakes
      in 22-27 us (RF, `.claude/reports/world-gate-rf-debug.md`); a broadcast
      wake cut the full-pool dispatch floor 26.9 -> 17.2 us in a scratch version
      (`.claude/reports/slice89-wake-diag.md`). Data and pass conditions are in
      slice 90.
- [ ] World gate access order under the data rules
      (`.claude/rules/memory-performance.md` § Data-oriented design,
      `.claude/rules/engine-design.md` § Target scale: the chunk is the unit).
      Measured (`bc336f4`, scattered minus scattered-sorted; Debug 3 reps):
      serial +0.40 / +0.52 / +1.84 ms at 4,096 / 16,384 / 65,536 (beyond
      spread), tuned +10 / +37 / +430 us (within spread or at its edge);
      ReleaseFast 1 run at 65,536: serial 1.52 against 1.05 ms, tuned 235
      against 175 us at different settled shapes (not judged). Cause untested
      (level-view re-resolve per lane, `systems/world_gate.zig:237`, or mispredicted
      early returns; the terrain bits fit L1/L2 here); rows are not grouped by
      `(level, chunk)`. A per-row terrain read at the row's position is an
      exempt point lookup (owner 2026-10-24). Next measure: a variant with
      terrain larger than L2, 3 ReleaseFast reps (the access-order exception,
      `.claude/rules/build-validation.md`). Pass: the lookups reported as a
      cost or not there; only if they cost, rows group by `(level, chunk)`,
      serial == threaded. Links slice 35's row-order item and slice 88's
      plane-entry item.
- [ ] `pathfinding-drain` 2048 and `pathfinding-elastic-ramp` tuned cases.
      Measured (`.claude/reports/slice89-drain-landing.md`): drain RF within
      spread; Debug +0.30 ms from the nudge stepping on Debug drift (+-25-40%
      against the 3.4% band); elastic-ramp tuned beats every control, its
      scaling limited by main's serial part, two wakes and joins, and the solve
      tuner at the 0.25 lower clamp. Both need a band or clamp change that moves
      every tuner; recorded, not chased. Pass: each tuned case within spread of
      its best control, or the band or clamp change measured across the
      targeted groups.
- [ ] Every tuned case settles or its tuner merges or is removed. Measured
      (Debug suite, `6b7138e`): 21 `settled=no` cases, 15 of them
      `production-step`; not rerun at four times the default pre-measure. Pass:
      each rerun at four times the default pre-measure
      (`.claude/rules/tests-benchmarks.md`); a tuner still unsettled is merged
      or removed (`.claude/rules/threading.md` § Building a stage), or, for a
      bench-only revert instance, the fixture fixed.
- [ ] An inline tuned case matches serial. `pathfinding-link-fold` 1016032768
      ReleaseFast was tuned 13-16% slower than `serial-direct` (every stage
      inline, cause unmeasured) before the jump changes; not rerun in
      ReleaseFast. Debug suite (`6b7138e`): +11 us. Also: once a link-fold run
      has done five or more batches, every case, serial included, has one timed
      fold at about 440-500 us (Debug), which a 3-iteration mean carries. Pass:
      tuned within spread of serial where it runs inline (ReleaseFast); the slow
      fold attributed and fixed or reported.

### Acceptance checks

- [ ] Every item is landed or is routed with its `file:line` and failure
      scenario.
- [x] Touched groups within run-to-run spread, ReleaseFast for thread-policy
      changes; the targeted groups a tuner or `ThreadSystem` change can move;
      ThreadSanitizer clean for a `ThreadSystem` change.
- [x] `zig build verify` passes (and the full `zig build test -Dsanitize-thread=true`, at `bc336f4`).
