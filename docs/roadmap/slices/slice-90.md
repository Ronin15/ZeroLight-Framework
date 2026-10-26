## Slice 90: ThreadSystem Wake Protocol And Startup Calibration

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 89](slice-89.md) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: programming landed (`07b9c9a` wake words, `776c1ec` startup calibration); two
items open: the 4,096 production-step tuners that stay unsettled, and the owner's macOS and
Windows runs.** Owner 2026-10-25: slice 89 commits as is; the wake protocol and startup
calibration are this separate slice, and slice 50's hold on startup calibration is reversed
(the `ThreadSystem` is stable). Plan: `.claude/reports/thread-calibration-plan.md`.

Goal: a dispatch wakes only its active workers at lower cost, and every
hardware-timing constant (the gate and the participant-overhead prior) derives at startup from
the detected machine's measured floor, not from one host's numbers.

### Current foundation

- Dispatch flips the active workers' bits in the wake words and wakes once per word
  (`src/app/thread_system.zig:1513`, `WakeWordOps.post` `:1684`); main starts its own
  ranges after it (`:1515-1525`). Each worker owns one bit of a cache-line `WakeWord`
  (`:1620`; `wake_block_width` `:1613`, 32 per word on Linux, one elsewhere; `WorkerRecord`
  `:1822`). Before `07b9c9a` main posted a per-worker semaphore in turn, 26.0 us at the
  full pool (below).
- `ThreadSystem.init` calibrates once (`calibrate` `:1240`, `medianDispatchNs` `:1250`,
  called `:1221`); `ThreadCalibration.fromFloors` (`:240`) derives the gate, the
  participant-overhead prior, and its sample floor. Tuners read them through
  `AdaptiveWorkRequest.calibration` (`gateNs` `:899`, `gateNsFor` `:905`; prior `:928`;
  sample floor `:974`); `AdaptiveWorkTunerConfig.threaded_batch_ns` (`:129`) is an
  override. The 60_000 gate (twice the Debug full-pool floor, `58ff9e1`), the 1,000
  prior, and the 100 sample floor are deleted.
- Landed data (ReleaseFast `-Dcpu=x86_64_v2`, this host, 23 workers):
  - Wake words (`07b9c9a`, `thread-dispatch`, 3 interleaved reps, warmup 5 / iterations 30,
    base `ff2a161`): `thread-fixed-auto` 16,384 (23 active) 26.0 -> 16.3 us; 1,024 (15
    active) 19.0 -> 14.3 us; `thread-fixed-1` 1,024 7.2 -> 6.9 us (within spread).
  - Calibration (`776c1ec`, init debug line): 1.21 ms at startup in Debug and ReleaseFast
    (one run each); ReleaseFast floors F_W 16.5-18.7 us, F1 4.8-6.0 us, per-worker 0.49-0.63
    us, gate 32.9-37.4 us, prior the per-worker cost (4 runs); Debug gate 37.6-49.1 us
    (3 runs). The gate is 2 x F_W in every run.
  - `production-step` (3 interleaved reps, tuned, warmup 360 / iterations 300; L1 base
    `07b9c9a`, pre-L1 base `ff2a161`): 4,096 280.8 -> 234.6 us vs L1 (faster), 283.6 ->
    234.6 us vs pre-L1 (within spread); 16,384 653.7 -> 578.1 us vs L1, 646.5 -> 578.1 us
    vs pre-L1 (within spread; the 16,384 base is unsettled in 3 of 3 reps). `world-gate`
    65,536 tuned 127.9 -> 127.8 us vs L1, 150.0 -> 127.8 us vs pre-L1 (within spread).
- Measured wake diagnostics (scratch versions, ReleaseFast `-Dcpu=x86_64_v2`, this host;
  `.claude/reports/slice89-wake-diag.md`):
  - A broadcast wake cut the full-pool dispatch floor 26.9 -> 17.2 us
    (`thread-fixed-auto` 16,384, 3 runs, beyond spread).
  - At 15 active workers no gain: the broadcast wakes all 23.
  - `production-step` within spread (7 runs: -5.0 us at 4,096, -8.2 us at 16,384).
  - The scratch version has a 32-bit counter-wrap hazard.
  - A main-runs-first variant: no floor gain, and it breaks the contract that a range may
    wait on another participant.
- Measured (`production-step` 1024-side, 8 levels, one run each): 4,096 population serial
  318.8 us, tuned 329.4 us, 0.5 threaded dispatches per step (collision 121 us, steering
  78 us, world gate 38 us run inline under the 60 us gate); 16,384 serial 1.30 ms, tuned
  658.2 us, 9 threaded dispatches per step at 26-50 us each.
- Not pursued (slice 50 § Measured and not pursued): tree wake (slower at every worker
  count), spin-then-park, a calibration cache file.

### Constraints

- Threading and the wake protocol: `.claude/rules/threading.md`; a `ThreadSystem` change
  merges only after a clean ThreadSanitizer run (§ Verification and diagnostics).
- Thresholds derive from the cost of the operation they gate, never world size
  (`.claude/rules/budgets-capacities.md`); a change to one states its benefit against
  hot-path cost and determinism.
- Serial == threaded results (`.claude/rules/tests-benchmarks.md`); calibration reads
  only timing and never changes simulation results.
- No calibration cache file (slice 50, owner 2026-10-15): the engine measures at run time.
- Cost model before code (`.claude/rules/engine-design.md` § Cost model); validation modes
  and targeted groups: `.claude/rules/build-validation.md`.

### Checklist

- [x] Wake protocol: a dispatch wakes only its active workers at a lower floor than the
      per-worker posting loop, with no counter-wrap hazard and every range still free to
      wait on another participant. Pass: `thread-fixed-auto` 16,384 full-pool floor below
      26.9 us in ReleaseFast beyond spread; no loss at 15 active workers; wake tests at
      every worker count and spurious-wake tests (`thread_system.zig` wake tests) pass.
      Landed `07b9c9a`: 26.0 -> 16.3 us at 16,384, 19.0 -> 14.3 us at 1,024 (15 active
      workers), `thread-fixed-1` within spread; wake-word-boundary, spurious-wake, and
      init-allocation-failure tests; TSan clean.
- [x] Startup calibration: the engine measures the full-pool dispatch floor of the
      detected machine at startup, bounded in time, deterministic in its effect on results.
      Pass: measured floor reported in the diagnostics; startup cost reported. Landed
      `776c1ec`: 8 + 31 dispatches at one worker and at the full pool, 1.21 ms at 23
      workers; the init debug line reports both floors, `worker_wake_ns`, the gate, the
      prior, and `calibration_ns`.
- [ ] The gate (`threaded_batch_ns`) derives from the measured floor by `58ff9e1`'s rule
      (gate = 2 x full-pool floor) under the new protocol. Pass: the 60_000 constant
      is removed or only a fallback; tuned cases of the targeted groups within spread of
      their best control. Constant deleted (`776c1ec`); gate 32.9-37.4 us (ReleaseFast, 4
      runs); `production-step` and `world-gate` tuned within spread or faster against both
      bases (data above). Open: the tuned cases were not compared with their best control
      after `776c1ec`, and the 4,096 settling item below leaves tuned cases unjudged.
- [ ] The participant-overhead prior derives from the same measurement. Pass: first-pick
      and settle behavior in `thread-dispatch`, `movement`, and `production-step` not worse
      beyond spread. Prior is the per-worker cost, 0.49-0.63 us (ReleaseFast); `production-
      step` and `world-gate` no slower; `movement` and `thread-dispatch` tuned cases were not
      re-run after L2 (not measured), and settling at 4,096 is worse (item below).
- [ ] Validation: `zig build verify`; the full `zig build test -Dsanitize-thread=true`;
      ReleaseFast targeted groups a `ThreadSystem` change can move (`thread-dispatch`,
      `world-gate`, `movement`, `production-step`), serial == threaded. Full suite 2014/2014
      in Debug and under TSan (no reports), `check` and `test-compile` clean, x86_64-windows
      check passes; `thread-dispatch`, `world-gate`, `production-step` benched (data above).
      `zig build verify` passes at `776c1ec`. `movement` (ReleaseFast, 3 interleaved reps, warmup 5 /
      iterations 30, base `ff2a161` vs `92050ff`): 262,144 tuned 93.8 us inline -> 40.0 us threaded
      23/23 (faster; beats every control, clamp 77.7 us; matched the fastest control 3/3 vs 2/3);
      10,000 tuned inline 3.7 -> 3.5 us, matching serial (work under the gate).
- [x] Docs: `docs/architecture.md` § Thread System describes the protocol and calibration
      as landed. `docs/development-workflow.md` names neither (no change needed there).
- [ ] Tuners unsettled at `production-step` 4,096: at 4x pre-measure (warmup 360), after
      `776c1ec` `state.pipeline.world_gate.tuner`, `steering.grid_bucket_tuner`, and
      `steering.adaptive_tuner` stay unsettled in 2 of 3 runs (all 36 tuners settled at
      `07b9c9a`); 16,384 leaves 1-4 unsettled before and after (collision, steering, scope,
      pathfinding stages; pre-existing). Hypothesis, untested: the stages sit at the lower
      gate, where the settled-window rules flap. Failure scenario: the tuned case is not
      judged (`.claude/rules/tests-benchmarks.md`) and the stage re-probes forever
      (`.claude/rules/threading.md` § Building a stage). Pass: they settle, or are merged or
      removed per `threading.md`.
- [ ] Owner runs on macOS and Windows (owner 2026-10-25: the engine targets Linux, macOS,
      and Windows; owner tests this week). Those builds use the portable per-worker wake
      (one futex word per worker), not the Linux bitset wake, so their gain is unmeasured.
      Run on each machine, ReleaseFast, at the L1 base and after L1 and L2:
      `zig build test -Dsanitize-thread=true` where TSan is supported, else `zig build test`;
      `tools/bench_ab.py --optimize ReleaseFast --reps 3 --group thread-dispatch -- --items 1024`
      and `--items 16384` (`thread-fixed-auto`: the dispatch floor);
      `zig build bench -Doptimize=ReleaseFast -- --group production-step --items 1024008016384`
      (tuned step time); the calibrated gate and prior from the init line
      (`-Dlog-level=debug`: `dispatch_floor_ns`, `one_worker_floor_ns`, `worker_wake_ns`,
      `gate_ns`, `participant_overhead_ns`, `calibration_ns`). Linux reference (7900X3D, 23 workers, ReleaseFast): full-pool
      floor 26.0-26.9 us before L1, 16.3 us after; production-step 16,384 tuned 646.5-658.2
      us before, 578.1 us after; calibrated gate 32.9-37.4 us. Data: § Current foundation
      above and commits `07b9c9a`, `776c1ec`.
      Pass: floor not worse than before L1 beyond spread, tests pass, and the
      calibrated gate reported per machine.

### Acceptance checks

- [ ] Every checklist item is landed or routed with its `file:line` and failure scenario
      (two open above).
- [x] Touched groups within run-to-run spread or faster, ReleaseFast (`thread-dispatch`,
      `production-step`, `world-gate`; data above).
- [x] ThreadSanitizer clean (full suite 2014/2014, no reports); `zig build verify` passes at `776c1ec`.
