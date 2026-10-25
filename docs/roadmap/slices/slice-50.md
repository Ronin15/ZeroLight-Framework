## Slice 50: Thread System Hardening

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: landed on `core_systems` (`e56e37b`..`987b342`); TSan and `verify` pass.**
Open before the archive move: the ReleaseFast `zig build test` (once, at the
branch commit) and the owner's Windows run (Acceptance). Mac runs and
compiles (owner). Opened the
core-systems branch (owner 2026-10-12). Prerequisite for 51 (the lane thread
relies on the foreign-thread rule, naming, and TSan workflow). 52C adds a TSan
job.

Goal: `ThreadSystem` stays memory-safe in shipped ReleaseFast builds when a
job calls `parallelFor` re-entrantly or a non-owner thread calls it; the
per-range claim counter stops false-sharing with the batch descriptor; worker
threads carry readable names in profilers; unit tests and benches run under
ThreadSanitizer through a documented `-Dsanitize-thread` workflow; dispatch
cost does not regress. Every scalable processor, across levels and world
instances, dispatches through this pool, so its safety is engine-wide.

### Current foundation

- `ThreadSystem` (`src/app/thread_system.zig`) is a fork-join pool with
  pre-spawned workers; `parallelFor` forwards to `parallelForWithOptions`;
  `JobFn` returns `void`, so jobs cannot propagate errors. There are about 39
  production call sites.
- Reentrancy is guarded only by `std.debug.assert`s that ReleaseFast strips. A
  nested threaded call from inside a job would overwrite the shared batch
  while workers read it, and a nested call on a worker mutates the stage or
  shared tuner concurrently (`selectBatchProfile`, `record`). The inline path
  never touches the shared batch but still touches the tuner.
- `Batch` packs the read-mostly descriptor with the hot `next_range` claim
  atomic and two per-range telemetry atomics (`main_thread_ranges`,
  `worker_thread_ranges`), so every claim invalidates the line every
  participant reads.
- Workers (`WorkerRecord`, `workerMain`, `workerLoop`) are unnamed; the loop
  tolerates a wake with no batch. `BatchStats` has a size test, and
  allocation-free submission tests exist.
- One 64-byte `thread_shared_record_alignment` and one `paddingForCacheLine`
  live in `thread_system.zig`, imported by every system; the private copies are
  gone (64G `819d8d8`). The comptime layout gate is still Slice 65A's.
- Zig 0.17: `std.Build.Module.CreateOptions.sanitize_thread` exists and the
  toolchain bundles libtsan; the x86_64-Linux Debug self-hosted backend does
  not instrument. `std.Thread.setName` names any thread on Linux/Windows but
  only the calling thread on Darwin; Linux names are at most 15 bytes.

### Architecture notes

- Decision, reentrancy by caller: a thread already participating in a batch of
  this system (one of its workers, or its owner running its own ranges) runs
  the nested batch forced inline on its own `WorkerId`, in every build mode,
  never touching a tuner. A thread that neither owns nor serves this system
  (including a participant of a different `ThreadSystem`, whose scratch slot
  can exceed this system's) panics in every build mode, because no safe
  execution exists for it. Forced inline keeps the range set and indices, so
  output stays deterministic (`.claude/rules/threading.md`).
- Consequence: Slice 51's lane thread is a foreign thread, so lane jobs run
  serial code paths, never `parallelFor`.
- Forced inline is visible: a per-batch stat, a per-system counter, and one
  warn-level log per system lifetime, kept in shipped builds (a recovered
  composition mistake, never on a correct hot path).
- The claim counter stops sharing a line with the descriptor and completion
  data; the only shared RMW left in the claim loop is the claim itself.
  `WorkerRecord` padding is 65A's.
- Workers name themselves (Darwin's only supported form); the main thread is
  never renamed (on Linux that renames the process).
- `-Dsanitize-thread` instruments the unit-test and bench artifacts only (SDL
  and GPU driver threads are uninstrumented), forces the LLVM backend, fails
  loudly on unsupported targets, and halts on the first report. It ships no
  suppressions for framework code; any future suppression covers only
  uninstrumented third-party code with a cited root cause. TSan runs are
  required before merging changes to `thread_system.zig`, the lane, or any
  threaded range write; they are not part of `verify`. First step: probe the
  toolchain.
- VoidLight: port isolating hot counters on their own lines, self-naming
  workers, and a documented TSan build; do not port its suppressions for its
  own managers or futures that let a worker block on pool work.

### Checklist

- [x] Participant detection, owner thread ID, forced-inline path,
      foreign-thread panic, and forced-inline telemetry (`4e62442`). Tests:
      nested batch from a worker job and from the owner's own range run
      inline and cover every item once on the caller's `WorkerId`; a
      selected profile's range shape is kept; the tuner is untouched; forced
      inline is allocation-free. The panic cases are documented and covered in
      review (not exercisable in-process).
- [x] Claim-line isolation with comptime layout asserts; tests for the
      layout and exact per-participant range counts under heavy claiming
      (`a66d87c`).
- [x] Self-naming workers; a Linux test that every woken worker carries its
      name (`4e62442`).
- [x] `-Dsanitize-thread` option, backend forcing, unsupported-target failure,
      and `TSAN_OPTIONS` on run steps; toolchain probe (`4ae3d60`).
- [x] `thread-dispatch` bench group (trivial per-item job over an item ladder)
      registered (`e56e37b`); before/after captures in each landing commit.
      Bench controls scale from each group's partition (`ce877e5`, `2af2b8a`).
- [x] Lock-free batch publication and completion (owner scope add,
      2026-10-15): per-worker generation, a countdown including main
      (`b42ef15`), with wake tests at every worker count (`7946511`).
- [x] Tuner gate 250 → 60 µs, derived from the measured dispatch floor, with
      the stored-overhead demotion bound and per-half bench tuner sets
      (`58ff9e1`); a winning one-worker first probe climbs up (`65434f7`).
      The tuner policy since changed to the batch tuner (`83ef090`:
      upper-bound demotion, no worker-count climb;
      `docs/architecture.md` § Thread System).
- [x] Docs: `docs/architecture.md` Thread System (reentrancy and ownership,
      forced inline, foreign-thread panic, worker names);
      `docs/development-workflow.md` "Thread Sanitizer" and the bench group
      (the Slice 50 docs commit).
- [x] Rule additions to `.claude/rules/threading.md`: singleton cache-line
      padding (`a66d87c`); nesting and foreign-thread behavior and the TSan
      suppression policy (the Slice 50 docs commit).

### Acceptance checks

- [ ] `zig build test` passes, and once with `-Doptimize=ReleaseFast`
      (forced inline identical with asserts stripped). Debug passes in
      `verify` at the slice tip; ReleaseFast runs once at the branch commit.
- [x] `zig build test -Dsanitize-thread=true` reports zero races on x86_64
      Linux, and the threaded quick bench groups run clean under it; any
      narrowing from the probe is recorded with the exact error. Full suite
      at the slice tip: no race reports (1,768/1,769; the one failure was a
      timing-dependent AI test that assumed demo-scale batches stay under the
      gate, which TSan's slowdown broke; fixed to pin its gate, and it passes
      under TSan). Detection proven in-tree: weakening the per-worker
      generation release/acquire to monotonic makes the thread_system tests
      report a data race in `workerLoop`. `thread-dispatch`/`movement` clean
      through `b42ef15`. No narrowing on x86_64 Linux; other targets:
      `docs/development-workflow.md` § Thread Sanitizer.
- [x] Comptime layout asserts hold; the claim loop's only atomic RMW is the
      claim (`a66d87c`).
- [x] `thread-dispatch` and `movement --case thread-small-range` show no
      regression beyond run-to-run spread on adjacent commits in ReleaseFast
      (`.claude/rules/tests-benchmarks.md`). `thread-dispatch` ReleaseFast,
      3 reps: `a66d87c` nothing slower (262,144 fixed-2 −19.5%, fixed-auto
      −16.5%); `b42ef15` at 16,384 fixed-auto within spread. `movement
      --case thread-small-range` ReleaseFast, 3 reps, `5673672` vs the slice
      tip: 1,024 −3.5%, 4,096 −25.0%, 10,000 −17.3%, all within spread.
- [x] `zig build verify` passes at the slice tip (27/27 steps, 1,769/1,769 tests).
- [x] Owner run on Mac: the code runs and compiles (owner).
- [ ] Owner run on Windows: `zig build test` plus the `thread-dispatch` bench.

### Open items from the batch tuner and diagnostics landings

- [x] No stage control exists only for tests and benches
      (`.claude/rules/tests-benchmarks.md` § Test and production code 1).
      Superseded by `19fe22a`: `ThreadSystem`'s fixed-shape options are the one
      sanctioned test and bench seam, and production code may only forward its
      stage's controls. The steering band stages forward
      `SteeringConfig.band_items_per_range` (`steering/system.zig:94`),
      null in production. Original failure text kept below.
      Failure: production passes `.{}` to `WorldGateSystem.apply`
      (`simulation_pipeline.zig:1896`), so `WorldGateConfig.items_per_range` and
      `.max_worker_threads` (`world_gate.zig:36`) are set only by tests and
      benches; the same holds for `MovementConfig` (`movement.zig:20`), chunk
      derive, and the per-stage worker caps (`StageControls.max_worker_threads`,
      `thread_system.zig`), each to be audited. Pass: fixed shapes come from
      bench fixed-shape controls over `StageControls`, no production config
      field is written by tests or benches alone, and the tuner-pin sites are
      unchanged in behavior.
- [x] The idiom lint flags a production literal `items_per_range` or
      `max_worker_threads` passed to `Dispatch` outside tests and benches
      (`tools/lint_idioms.py`). Rule 13 (`166075c`): 13.1 range and worker
      fields, 13.2 `adaptive`, 13.3 a dispatch no tuner records; production is
      hit-free with no exemptions.
- [ ] The 14 `pipeline_*` runtime-log timers are cost-driver stages or move
      to the bench-only channel. Failure: `runtime_perf_log.zig:170-183`
      (`pipeline_spatial_index` through `pipeline_chunk_derive`) time whole
      stage calls, which `.claude/rules/threading.md` § Verification and
      diagnostics reserves to bench output. Pass: the runtime log records only
      cost-driver stages; the census reads the rest through `BenchTiming`.
- [ ] Dig-path batches are tagged in the `production-step` census once a dig
      case exists. Failure: the terrain edit plan and write dispatches
      (`world/edit.zig:79-85`) and the nav mark dispatch
      (`pathfinding/nav_reaction.zig:360-376`) carry no bench batch tag, so a
      dig step's threading is invisible to the census. Pass: a dig case in
      `production-step` whose census lists those batches with `ran=` and
      `threaded=`.
- [ ] Remaining diagnostic counters that tests read sit behind the perf
      switch (`.claude/rules/tests-benchmarks.md` § Test and production code 4).
      Failure: tests read `NavUpdateStats.dirty_chunks`, `.chunks_patched`,
      `.records_patched` (`pathfinding/types.zig:311-321`), the
      `PathfindingStats` `*_ns` fields (`:286-304`), and `NavGraph` pool grows.
      Pass: those reads are bench checks or observable-result asserts.
      `incremental_rebuilds` and `levels_built` stay live (`nav_reaction.zig:340`
      emits `nav_region_invalidated` from them).
- Moved to slice 89 (owner 2026-10-24): rarely-run passes' first shape (its
  fresh one-off item), the `movement` 4,096 case (its movement item), and the
  cold-seed hypothesis (its tuner item).

### Measured and not pursued

Owner-ruled 2026-10-15; none is an open item.

- Tree wake (main posts the root, woken workers post children): slower at
  every worker count up to 23, since a tree level costs a wake round trip
  (about 3.5–4 µs) against about 0.9 µs per flat post saved (`7946511`).
- Spin-within-step-then-park, and a core low-power wait module (MWAITX,
  UMWAIT, WFE): within spread at the release shape, about double the worker
  CPU growing with population, main 9–41% slower from a waiting SMT sibling;
  pure park keeps race-to-idle (`13a2a67`).
- Startup calibration of wake and post costs (a derived gate, a calibrated
  predictor floor, a range count from claim cost): stopped before landing to
  keep the branch stable; the 60 µs derived default stays, and each host's
  threading decisions are measured against the commit margin.
- A per-machine calibration cache file: no saved file; the engine measures
  at run time or uses a good default.
