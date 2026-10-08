## Slice 50: Thread System Hardening

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Prerequisite for 51 (the lane thread relies on the
foreign-thread rule, naming, and TSan workflow). Rebases with 49 on
`thread_system.zig` and with 52A on `build.zig`; once landed, 52C adds a TSan
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
- Six private copies of a 64-byte `thread_shared_record_alignment` exist
  across systems (Slice 65A consolidates them).
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

- [ ] Participant detection, owner thread ID, forced-inline path, foreign-thread
      panic, and forced-inline telemetry. Tests: nested batch from a worker
      job and from the owner's own range run inline and cover every item once
      on the caller's `WorkerId`; a selected profile's range shape is kept;
      the tuner is untouched; forced inline is allocation-free. The panic
      cases are documented and covered in review (not exercisable in-process).
- [ ] Claim-line isolation with comptime layout asserts; tests for the
      layout and exact per-participant range counts under heavy claiming.
- [ ] Self-naming workers; a Linux test that every woken worker carries its
      name.
- [ ] `-Dsanitize-thread` option, backend forcing, unsupported-target failure,
      and `TSAN_OPTIONS` on run steps; toolchain probe.
- [ ] `thread-dispatch` bench group (trivial per-item job over an item ladder)
      registered; before/after captures in the landing commit.
- [ ] Docs: `docs/architecture.md` Thread System (reentrancy and ownership,
      forced inline, foreign-thread panic, worker names);
      `docs/development-workflow.md` "Thread Sanitizer" and the bench group.
- [ ] Rule additions to `.claude/rules/threading.md` when this lands:
      nesting and foreign-thread behavior, singleton cache-line padding, TSan
      suppression policy.

### Acceptance checks

- [ ] `zig build test` passes, and once with `-Doptimize=ReleaseFast`
      (forced inline identical with asserts stripped).
- [ ] `zig build test -Dsanitize-thread=true` reports zero races on x86_64
      Linux, and the threaded quick bench groups run clean under it; any
      narrowing from the probe is recorded with the exact error.
- [ ] Comptime layout asserts hold; the claim loop's only atomic RMW is the
      claim.
- [ ] `thread-dispatch` and `movement --case thread-small-range` show no
      regression beyond run-to-run spread on adjacent commits in ReleaseFast
      (`.claude/rules/tests-benchmarks.md`).
- [ ] `zig build verify` passes.
