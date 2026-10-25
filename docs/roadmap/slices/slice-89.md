## Slice 89: Thread-System Batch Follow-Ups And The World Gate Under The Rules

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 88](slice-88.md) (branch order: runs after the core-branch review work) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started; re-checked at 750ce0a (2026-10-24).** Owner 2026-10-23: a slice for the world-gate and
batch-tuner follow-ups, to complete after the core-branch review work.

Goal: the batch tuner settles near the best fixed batch shape at the sizes
that thread, the dispatch posts its wakes without delaying main's own ranges,
and the world gate's per-row terrain reads are measured on a play-shaped
fixture and grouped by chunk only if they cost there.

### Current foundation

- Batch tuner: `src/app/thread_system.zig`. The nudge steps 1.1x (`:151`),
  compares a step against `nudge_stepped_band` (`:150`, about 3.4%), holds
  inside the 5% band (`:147`), and takes its first step down (`:158`); the
  multiplier clamps at 0.25-4.0 (`:152`, `:159`). A fresh `full_pool` tuner's
  first selection is 2 batches per participant (`:173`). Policy:
  `docs/architecture.md` § Thread System.
- Dispatch posts each active worker's wake in turn on main
  (`thread_system.zig:1207-1210`); main starts its own ranges after the loop
  (`:1223`). A tree wake was measured slower and is not pursued (slice 50
  § Measured and not pursued, owner 2026-10-15).
- `threaded_batch_ns` is 60_000 (`thread_system.zig:122`), set from the measured
  dispatch floor in `58ff9e1`; it stays (`49620d9`).
- World gate: `world_gate.zig` `gateRange` (`:248`) walks movement rows in
  store order; plane entry gathers per slice 88's plane-entry item.
- Already routed (not repeated here): slice 35's row-order and tuned-versus-fixed
  items ([35](slice-35.md)), slice 50's open tuner items ([50](slice-50.md)),
  slice 88's plane-entry gather item ([88](slice-88.md)). Related, not merged:
  slice 50's first-shape (`:188`), movement (`:193`), and cold-seed (`:197`)
  items.
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

- [ ] The tuner reaches the best batch shape it can dispatch. Failure: a step is
      compared against a 3.4% band (`thread_system.zig:150`) and the nudge steps
      first toward fewer batches (`:158`); the 1x to 4x gain is gradual (RF
      `world-gate` 65,536: 24 batches 121-131 us, 96 batches 112-114 us), so no
      single 1.1x step clears the band and the tuner settles below the pool.
      Measured (Debug, 750ce0a baseline, one run): `world-gate` tuned 65,536
      uniform 2.25 ms at x=0.54 against small-range 1.41 ms, 16,384 829 against
      413 us, interleaved 65,536 2.29 against 1.29 ms; tuned below 1x the pool
      and over 25% behind a fixed control in more cases: `particles` 4,096
      +59% (x=0.54), 10,000 +47%; `ai` 1,024 +48%, 4,096 +35%;
      `ai-cell-ordered` 10,000 +40%; `collision-stacked` 1000016 +29%;
      `collision-static-heavy` 4,096 +37%; `pathfinding` 512 +34%;
      `pathfinding-group-field-detour` 256 +33%; `pathfinding-query` 4,096 +71%;
      `pathfinding-negative-steady` 1,024 +51%; `pathfinding-negative-burst`
      12,288 +70%; `plane-traversal` 4,096 +61%, 16,384 +98%;
      `plane-traversal-falls` 16,384 +90%; `perception` 1,024 +37% (x=0.25);
      `perception-scattered-dense-index` 10,000 +36%; `steering` 1,024 +28%;
      `steering-corridor` 4,096 +32%. The Debug best `world-gate` control is
      2,049 batches, past the clamp, so Debug cannot say whether 4x would match
      (the bench-controls item). That one cause covers them is a hypothesis; a
      cold first batch seeding the nudge EMA (`:608-611`) is another, untested.
      Candidate: the first comparison tests 1x against the 4x clamp in one jump,
      then nudges locally from the winner. Pass: the cause measured at the world
      gate first; `world-gate` 65,536 ReleaseFast tuned within spread of the
      best fixed shape, the 4x control included; tuner tests for the changed
      first comparison; the once-per-tuner-change whole-suite Debug run gives
      each slower tuned case a verdict (`.claude/rules/tests-benchmarks.md`),
      light stages that stepped down first (`movement`, `particles`; the
      down-first comment `:153-157`) included; ReleaseFast at the sizes where
      each touched stage threads (`.claude/rules/build-validation.md`). Related:
      slice 35 "Tuned versus fixed controls" (`slice-35.md:80`), slice 50
      cold-seed (`slice-50.md:197`).
- [ ] Bench controls cover the clamp. Failure: the fixed cases
      (`benchmarks/suite.zig:163-200`) run 64-item ranges and their half and 4x
      (`:141-147`): 1,025 / 2,049 / 257 batches at `world-gate` 65,536, none at
      the tuner's reachable top, 4 x the pool's participants
      (`thread_system.zig:159`), so "best control" can be a shape the tuner
      cannot dispatch. Pass: a default fixed case at the clamp's batch count in
      every group, reported like the other controls; lands before the nudge
      item.
- [ ] Wake posting does not delay main's ranges. Failure: main posts every
      active worker's wake before its first range (`thread_system.zig:1207-1210`,
      ranges at `:1223`); at 1.0-1.2 us per post (RF, 23 workers) main's own
      first range and the last worker start 22-27 us after publish, about a
      fifth of a 112 us `world-gate` batch. A tree wake was measured slower and
      is not pursued (slice 50 § Measured and not pursued, `7946511`). Scope:
      owner question whether interleaved posting or a broadcast wake (a
      `ThreadSystem` wake-protocol change) is in scope, or the item drops if
      the skew is gone after the nudge item. Measure after the nudge item:
      shapes at 4x the pool give late starters fewer ranges (hypothesis). Pass:
      a dispatch start-skew counter in `thread-dispatch` `--details` (behind the
      perf switch); skew measured down in ReleaseFast at 1,024 and 16,384 items
      fixed-auto and at `world-gate` 65,536; serial == threaded; ThreadSanitizer
      clean (`.claude/rules/threading.md` § Verification); the whole-suite Debug
      run (a `ThreadSystem` change).
- [ ] World gate and plane entry under the data rules
      (`.claude/rules/memory-performance.md` § Data-oriented design,
      `.claude/rules/engine-design.md` § Target scale: the chunk is the unit).
      Measured (Debug serial, 750ce0a): 294 ns per row `uniform`, 276 ns per row
      and 553 ns per gated row `interleaved` at 65,536: skipped rows cost what
      gated rows do. Both shapes place rows on a store-ordered grid
      (`benchmarks/world_gate.zig:144-189`), so neither shows scattered terrain
      reads. Measure first on a play-shaped fixture: a `world-gate` shape whose
      rows scatter across chunks and at least two levels in random store order,
      at the existing three sizes. Pass: the per-row terrain lookups
      (`world_gate.zig:248`, `:317`) reported as a cost or not there, ordered
      against the same rows chunk-sorted (Debug, plus one ReleaseFast run: Debug
      dilutes cache cost with per-row overhead); only if they cost, rows group
      by `(level, chunk)`, serial == threaded. Owner questions: whether a per-row
      terrain read at the row's position is an exempt point lookup under the
      data rule, and whether `build-validation.md`'s ReleaseFast exceptions
      cover an access order's cache cost. Links slice 35's row-order item and
      slice 88's plane-entry item.
- [ ] A fresh one-off's first pick fits its work. Failure: a fresh `full_pool`
      tuner's first selection is the whole pool at 2 batches per participant
      (`thread_system.zig:173`) whatever the work: every nav build resets the
      level build set (`Tuners.startNavBuild`, `pathfinding/system.zig:298`) and
      the world paint runs on a fresh tuner (`worldgen.zig:220`, 47 aligned
      ranges where it ran 16,384 one-chunk ranges). Measured: `nav-level-add`
      1024008 ReleaseFast tuned 186.6 us (180.8-192.6) on the persistent set
      (`19fe22a`) against 201.7 us (196.3-211.6) fresh, main 122 to 104 us,
      remask, patch, and gather each 23w/48r [3/3]; Debug 750ce0a, 256-side
      configs tuned 26-59% over `thread-fixed-2` (256008 417.6 against 287.7 us,
      10256008 514.4 against 324.3 us), 1,024 and 2,048 sides tuned best;
      world-create 2,048 surface phase 19.16 to 21.81 ms (`4998400` to
      `faa3200`, Debug), 20.75 ms at 750ce0a. That the first pick causes either
      is a hypothesis. Candidate: the reset keeps each stage's learned per-item
      cost and drops only its profile, so the first pick is predicted from
      items x cost. Pass: measure the cause first; Debug `nav-level-add` at every
      256-side config tuned (fresh) within spread of its best control; the
      surface phase within spread of `4998400` in Debug, or reported as Debug
      overhead with the ReleaseFast confirmation; `nav-level-add` 1024008
      ReleaseFast tuned within spread of the persistent-set base; serial ==
      threaded. Related: slice 50 first-shape (`slice-50.md:188`).
- [ ] A judged jump covers its count band and re-tunes on evidence. Failure: the
      judgment (`AdaptiveWorkTuner.judgeJump`, `thread_system.zig:420`) is keyed
      by the exact (learned, requested) count pair (`:344-345`), finer than what
      it proves (`.claude/rules/engine-design.md` § Cost model), so a jump to 65
      items after a judged one to 64 re-predicts from the in-band model, the
      cause the judgment fixes; and once judged (`:424`) it ignores its later
      records while the counts repeat, so one judged inline at 25 us stays
      inline at 200 us (`.claude/rules/threading.md` § Building a stage).
      Link-fold and the collision spike repeat identical counts, so no bench
      shows either. Pass: a judged entry covers its count band; a sustained
      shift in the judged shape's own records reopens it, without re-probing on
      noise at the gate; tuner tests for each; a bench variant varies the jump
      count within the band.
- [ ] Movement's tuned case is stable across runs. Measured (Debug): `movement`
      4,096 tuned settles anywhere from 6 to 21 workers across runs (spread
      12-38%), on `95b9fcd` and after; 750ce0a: 30.57 us at 7 workers against
      small-range 28.87 us, 10,000 54.93 against large-range 48.41 us; cause
      unmeasured. Pass: three runs of 3 reps at 4,096 and 10,000: tuned time
      within spread of the best control in each
      (`.claude/rules/tests-benchmarks.md`); the settled shape is reported, not
      judged. Related: slice 50 (`slice-50.md:193`).
- [ ] An inline tuned case matches serial. Measured: `pathfinding-link-fold`
      1016032768 ReleaseFast, every stage inline in the tuned case, tuned
      13-16% slower than `serial-direct`, on `95b9fcd` and after; cause
      unmeasured. Also: once a link-fold run has done five or more batches,
      every case, serial included, has one timed fold at about 440-500 us
      (Debug), which a 3-iteration mean carries. Debug cannot answer: at that
      size the tuned case threads in Debug (750ce0a, 15/23). Pass: tuned within
      spread of serial where it runs inline (ReleaseFast); the slow fold
      attributed and fixed or reported.
- [ ] Tuned collision cases match their best control. Measured (Debug, 750ce0a,
      one run): `collision-static-dense-change` 4,096 tuned 953.9 against
      fixed-auto 922.2 us; `collision-static-triggers` 1,024 dormant 560.7
      against 538.0 us, non-dormant 575.9 against 542.6 us (headline stage
      inline in every case); `world-create-statics` 2,048 tuned 25.82 ms against
      serial 15.08 ms, main 24.52 ms (94%), 8,192 +6%, 32,768 tuned faster.
      Before `de8d308`: dense-change 5.40 against 4.69 ms, static-triggers
      dormant 597.7 against 513.4 us. Pass: 3 reps of the first two within
      spread or attributed to a stage and fixed or reported;
      `world-create-statics` 2,048 (fresh, judged) within spread of serial or
      its main-thread share attributed and fixed or reported.
- [ ] Steering's tuned cases match their best control. Measured (Debug, 750ce0a,
      settled): `steering-static-dense` 2064 5.43 against small-range 4.31 ms
      (64: +20%, 1064: +24%); `steering` 1,024 +28%; `steering-corridor` 4,096
      +32%, 16,384 +34%; `steering-cluster-outlier` 16,384 +28%. Three sit at or
      above 1x the pool (corridor 16,384, cluster-outlier 16,384, static-dense
      2064), so the nudge item's below-pool cause does not cover them. Pass:
      each case tuned within spread of its best control, or the gap attributed
      to a stage and fixed or reported. Settling: the unsettled-tuner item.
- [ ] Every tuned case settles or its tuner merges or is removed. Measured
      (Debug, 750ce0a, default warmup): `settled=no` in 28 cases:
      `production-step` all 14 configs (unsettled include `collision.fill`/
      `sort`, `steering.grid_bucket`/`grid_sort`, `pathfinding.tuners.intake`/
      `solve`, `movement.apply_intents`, `ai.separation`,
      `spatial_index.bucket`); `pathfinding-elastic-ramp` 1,000 / 4,000 / 16,000
      (intake, solve; x=0.25-0.33, at the lower clamp);
      `collision-static-heavy` 65,536 (sort, static_place, static_sort);
      `collision-static-triggers` 16,384 (fill, sort);
      `collision-response-stage` 1,024 (apply); `nav-update-scattered` 256
      (revert.conn_seed); `nav-update-static-dense-tail` 16,384
      (nav.nav_evict); `chunk-scale-nav-cave-in` 642048008 (write), 640256128
      (plan, revert_plan, revert_write); `chunk-scale-nav-enclose` 642048001
      (revert_plan, revert_write, nav_mark, revert.nav_mark);
      `steering-shuffled` 1,024 / 16,384; `steering-static-change` 10. Pass:
      each rerun at four times the default warmup
      (`.claude/rules/tests-benchmarks.md`); a tuner still unsettled is merged
      or removed (`.claude/rules/threading.md` § Building a stage), or, for a
      bench-only revert instance, the fixture fixed.
- [ ] `perception-crowd` tuned at the 4x clamp matches its control. Measured
      (Debug, 750ce0a): 1000032 tuned 787.6 us at 15w/64-item ranges, x=4.00,
      against fixed-auto 414.4 us; 1000008 +12% at x=4.00; 16 / 64 / 256 also at
      x=4.00. Cause unmeasured. Pass: tuned within spread of the best control,
      or the gap attributed to a stage and fixed or reported.
- [ ] Inline-under-gate Debug gaps confirmed in ReleaseFast. Measured (Debug,
      750ce0a): tuned inline against a threaded control: `movement` 1,024 33.6 /
      24.2 us; `movement-apply-intents` 1,024 56.2 / 22.7; `-sorted` 1,024 49.6 /
      19.0; `pathfinding-cache-open` 128 45.4 / 21.9; `pathfinding-cache-detour`
      128 44.6 / 19.7; `chunk-scale-explosion-fill` 40256008 129.2 / 91.5;
      `scope-cognition` 1,024 33.8 / 20.3 us. The gate stays (`58ff9e1`,
      `49620d9`); that Debug inflates the inline work past the threading
      break-even is a hypothesis. Pass: one targeted ReleaseFast run of those
      groups at those sizes: inline within spread of the best control, reported
      as Debug overhead (`.claude/rules/build-validation.md`); otherwise each
      case gets its verdict.
- [x] A whole-group Debug smoke run of every bench group under the batch tuner
      (dispatch and settle checks pass or fail). Answered by the 750ce0a
      whole-suite Debug run (`.claude/reports/bench-baseline-750ce0a.txt`):
      every group ran, every assert held; 28 tuned cases unsettled (the
      unsettled-tuner item).

### Acceptance checks

- [ ] Every item is landed or is routed with its `file:line` and failure
      scenario.
- [ ] Touched groups within run-to-run spread, ReleaseFast for thread-policy
      changes; one whole-suite Debug run for a tuner or `ThreadSystem` change;
      ThreadSanitizer clean for a `ThreadSystem` change.
- [ ] `zig build verify` passes.
