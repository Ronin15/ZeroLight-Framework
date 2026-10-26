## Slice 90: ThreadSystem Wake Protocol And Startup Calibration

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 89](slice-89.md) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Owner 2026-10-25: slice 89 commits as is; the wake protocol and
startup calibration are this separate slice, and slice 50's hold on startup calibration is
reversed (the `ThreadSystem` is stable). Plan: `.claude/reports/thread-calibration-plan.md`
(pending).

Goal: a dispatch wakes only its active workers at lower cost, and every
hardware-timing constant (the gate and the participant-overhead prior) derives at startup from
the detected machine's measured floor, not from one host's numbers.

### Current foundation

- Dispatch posts each active worker's wake in turn on main
  (`src/app/thread_system.zig:1353-1356`); main starts its own ranges after the loop
  (`:1370`). Wakes are per-worker semaphores (`Worker.wake`, `:1591`).
- `threaded_batch_ns` is 60_000 (`:127`), twice the measured Debug full-pool floor
  (29.8 us at 23 workers) from `58ff9e1`.
- The participant-overhead prior is `default_participant_overhead_ns` 1,000 (`:218`),
  used in the prediction (`:863`) and floored per sample by `min_participant_overhead_ns`
  (`:219`, `:909`).
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

- [ ] Wake protocol: a dispatch wakes only its active workers at a lower floor than the
      per-worker posting loop, with no counter-wrap hazard and every range still free to
      wait on another participant. Pass: `thread-fixed-auto` 16,384 full-pool floor below
      26.9 us in ReleaseFast beyond spread; no loss at 15 active workers; wake tests at
      every worker count and stale-permit tests (`thread_system.zig` wake tests) pass.
- [ ] Startup calibration: the engine measures the full-pool dispatch floor of the
      detected machine at startup, bounded in time, deterministic in its effect on results.
      Pass: measured floor reported in the diagnostics; startup cost reported.
- [ ] The gate (`threaded_batch_ns`) derives from the measured floor by `58ff9e1`'s rule
      (gate = 2 x full-pool floor) under the new protocol. Pass: the 60_000 constant
      is removed or only a fallback; tuned cases of the targeted groups within spread of
      their best control.
- [ ] The participant-overhead prior derives from the same measurement
      (`:218`). Pass: first-pick and settle behavior in `thread-dispatch`, `movement`,
      and `production-step` not worse beyond spread.
- [ ] Validation: `zig build verify`; the full `zig build test -Dsanitize-thread=true`;
      ReleaseFast targeted groups a `ThreadSystem` change can move (`thread-dispatch`,
      `world-gate`, `movement`, `production-step`), serial == threaded.
- [ ] Docs: `docs/architecture.md` § Thread System and `docs/development-workflow.md`
      describe the protocol and calibration as landed.

### Acceptance checks

- [ ] Every checklist item is landed or routed with its `file:line` and failure scenario.
- [ ] Touched groups within run-to-run spread or faster, ReleaseFast.
- [ ] ThreadSanitizer clean; `zig build verify` passes.
