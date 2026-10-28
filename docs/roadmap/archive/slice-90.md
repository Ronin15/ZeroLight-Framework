## Slice 90: ThreadSystem Wake Protocol And Startup Calibration

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 89](../slices/slice-89.md) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: landed (`07b9c9a` wake words, `776c1ec` startup calibration, `1e00a05` the
hold; macOS record `375c7c3`).** `zig build verify` passed at `776c1ec`. The hold's
test is `zig build test -Dtest-filter=thread_system` (160). Owner 2026-10-28: a
different gate from one process start to the next is accepted startup spread, and
Windows was not run and is not a close condition. Owner 2026-10-25: slice 89 commits
as is; the wake protocol and startup calibration are this slice, and slice 50's hold
on startup calibration is reversed (the `ThreadSystem` is stable).

Goal: a dispatch wakes only its active workers at lower cost, and every
hardware-timing constant (the gate and the participant-overhead prior) derives at startup from
the detected machine's measured floor, not from one host's numbers.

### Current foundation

- Dispatch flips the active workers' bits in the wake words and wakes once per word
  (`src/app/thread_system.zig:1566`, `WakeWordOps.post` `:1737`); main starts its own
  ranges after it (`:1568-1578`). Each worker owns one bit of a cache-line `WakeWord`
  (`:1673`; `wake_block_width` `:1666`, 32 per word on Linux, one elsewhere; `WorkerRecord`
  `:1875`). Before `07b9c9a` main posted a per-worker semaphore in turn, 26.0 us at the
  full pool (below).
- `ThreadSystem.init` calibrates once (`calibrate` `:1293`, `medianDispatchNs` `:1303`,
  called `:1274`); `ThreadCalibration.fromFloors` (`:240`) derives the gate, the
  participant-overhead prior, and its sample floor. Tuners read them through
  `AdaptiveWorkRequest.calibration` (`gateNs` `:944`, `gateNsFor` `:950`; prior `:973`;
  sample floor `:1019`); `AdaptiveWorkTunerConfig.threaded_batch_ns` (`:129`) is an
  override. The 60_000 gate (twice the Debug full-pool floor, `58ff9e1`), the 1,000
  prior, and the 100 sample floor are deleted.
- Held-side window landed `1e00a05` (`finishSettledWindow` `:619`,
  `winnerChangeAbsorbed` `:691`; `docs/architecture.md` § Thread System). The
  `production-step` 4,096 run in that landing stays not judged.
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
- macOS owner run (2026-10-26, Apple M3 Pro, 11 CPUs, 10 workers, ReleaseFast
  `-Dcpu=apple_m1`, head `1ac549a`; the portable wake, one futex word per worker).
  `thread-fixed-auto`, 3 interleaved reps, warmup 5 / iterations 30, 10/10 workers:
  - After L1 (`07b9c9a`) vs pre-L1 (`ff2a161`): 1,024 24.0 -> 22.8 us (within
    spread; the base spread is 55.7%, one rep at 13.6 us); 16,384 29.8 -> 33.8 us
    (+13.4%, within spread).
  - After L2 vs pre-L1: 1,024 23.1 -> 21.0 us (within spread); 16,384 32.9 ->
    32.6 us (within spread). The full-pool floor is within spread of pre-L1.
  - Calibration, 4 ReleaseFast inits: full-pool floor 20.3-26.3 us, one worker
    3.5-7.0 us, per-worker wake 1.83-2.47 us, gate 40.6-52.5 us (2 x the
    full-pool floor in every run), prior the per-worker wake, startup 1.02-1.27 ms.
  - `production-step` 16,384, one run, default warmup (`settled=no`): pre tuned
    639 us, serial 1.01 ms (33/34, `directions_tuner`); after L1 636 us, serial
    1.03 ms (31/34, `grid_sort_tuner`, `world_gate.tuner`, `plane_entry.tuner`);
    after L2 646 us, serial 1.02 ms (33/34, `steering.adaptive_tuner`).
  - After L2 at 4x pre-measure (warmup 360 / iterations 300, one run): tuned
    616 us, serial 1.00 ms, main 238 us (38%). 35/36 tuners settled, including
    `steering.adaptive_tuner`. `plane_entry.tuner` stayed unsettled: serial
    63 us, threaded 37 us, against the 40.6-52.5 us gate. Stages under the gate
    stayed inline (movement 7 us, pathfinding, scope gathers, spatial index
    41 us). Collision, steering, and the world gate ran on workers every
    measured call (serial 355 / 282 / 117 us). The case stays `settled=no`.
  - `zig build test -Dsanitize-thread=true` exited 0.
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

- Threading and the wake protocol: `.grok/rules/threading.md`; a `ThreadSystem` change
  merges only after a clean ThreadSanitizer run (§ Verification and diagnostics).
- Thresholds derive from the cost of the operation they gate, never world size
  (`.grok/rules/budgets-capacities.md`); a change to one states its benefit against
  hot-path cost and determinism.
- Serial == threaded results (`.grok/rules/tests-benchmarks.md`); calibration reads
  only timing and never changes simulation results.
- No calibration cache file (slice 50, owner 2026-10-15): the engine measures at run time.
- Cost model before code (`.grok/rules/engine-design.md` § Cost model); validation modes
  and targeted groups: `.grok/rules/build-validation.md`.

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
- [x] The gate (`threaded_batch_ns`) derives from the measured floor by `58ff9e1`'s rule
      (gate = 2 x full-pool floor) under the new protocol. The 60_000 constant is deleted
      (`776c1ec`); the gate is 32.9-37.4 us (ReleaseFast, 4 runs, data above). The
      tuned-versus-control remainder is the accepted startup spread (owner 2026-10-28).
      The `production-step` 4,096 run stays not judged.
- [x] The participant-overhead prior derives from the same measurement (`776c1ec`): the
      per-worker cost, 0.49-0.63 us (ReleaseFast). The tuned-versus-control remainder is
      the same accepted startup spread (owner 2026-10-28). No tuner is merged or removed
      for it.
- [x] Validation: `zig build verify`; the full `zig build test -Dsanitize-thread=true`;
      ReleaseFast targeted groups a `ThreadSystem` change can move (`thread-dispatch`,
      `world-gate`, `movement`, `production-step`), serial == threaded. Full suite 2014/2014
      in Debug and under TSan (no reports), `check` and `test-compile` clean, x86_64-windows
      check passes; `thread-dispatch`, `world-gate`, `production-step` benched (data above).
      `zig build verify` passes at `776c1ec`. `movement` (ReleaseFast, 3 interleaved reps, warmup 5 /
      iterations 30, base `ff2a161` vs `92050ff`): 262,144 tuned 93.8 us inline -> 40.0 us threaded
      23/23 (faster; beats every control, clamp 77.7 us; matched the fastest control 3/3 vs 2/3);
      10,000 tuned inline 3.7 -> 3.5 us, matching serial (work under the gate).
- [x] Docs: `docs/architecture.md` § Thread System describes the protocol, calibration,
      and the held-side window as landed. `docs/development-workflow.md` names neither
      (no change needed there).
- [x] Tuners at `production-step` 4,096. After `776c1ec`, `state.pipeline.world_gate.tuner`,
      `steering.grid_bucket_tuner`, and `steering.adaptive_tuner` stayed unsettled in 2 of
      3 runs at 4x pre-measure (all 36 settled at `07b9c9a`). The hold (`1e00a05`) stops
      one crossing from flipping (`docs/architecture.md` § Thread System). A tuner that
      stays unsettled because the gate moved is the accepted startup spread (owner
      2026-10-28); tuners are not merged or removed for it. The landing's `production-step`
      4,096 run stays not judged. On macOS, `plane_entry.tuner` at 16,384 stays the
      `375c7c3` record.
- [x] macOS stays the `375c7c3` record (Current foundation): after L2 the full-pool floor
      is within spread of pre-L1, the calibrated gate is reported, and the TSan run
      exited 0. `production-step` 16,384 at 4x pre-measure stays `settled=no`
      (`plane_entry.tuner`). Windows was not run and is not a close condition (owner
      2026-10-28).

### Acceptance checks

- [x] Every checklist item is landed or closed on the owner decision of 2026-10-28
      (startup spread accepted; the `production-step` 4,096 run not judged; Windows
      not run and not a close condition).
- [x] Touched groups within run-to-run spread or faster, ReleaseFast (`thread-dispatch`,
      `production-step`, `world-gate`; data above).
- [x] ThreadSanitizer clean (full suite 2014/2014, no reports); `zig build verify` passes at `776c1ec`.
