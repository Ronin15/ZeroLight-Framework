## Slice 50: Thread System Hardening

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Independent. Prerequisite for **51**: the lane thread
relies on this slice's foreign-thread rule, thread naming, and TSan workflow. It
edits `src/app/thread_system.zig` alongside **49**'s one-field change. It also
edits `build.zig` `createSdlModule` and the option set, as does **52A**;
whichever lands second rebases. Once 50 lands, 52C may add a Linux
`-Dsanitize-thread=true` test job.

Goal:
- `ThreadSystem` stays memory-safe in the shipped ReleaseFast build when a job
  calls `parallelFor` re-entrantly, or when a non-owner thread calls it.
- The per-range claim counter stops false-sharing with the batch descriptor.
- Worker threads carry readable names in profilers.
- A `-Dsanitize-thread` build runs the unit tests and benchmarks under
  ThreadSanitizer, with a documented workflow.
- Dispatch cost does not regress.

### Current foundation (do not rebuild)

- **Fork-join pool.**
  - `ThreadSystem` is defined at `thread_system.zig:707-714`. Workers are
    pre-spawned at `:744-755`.
  - `parallelFor` (`:791`) forwards to `parallelForWithOptions` (`:843`).
  - `JobFn = *const fn (*anyopaque, ParallelRange, WorkerId) void` (`:705`), so
    jobs cannot return errors.
  - 39 production call sites outside `thread_system.zig` and the benches.
- **Reentrancy is guarded only in debug builds.**
  - The only checks are `std.debug.assert(self.shared.accepting_work)` and
    `std.debug.assert(self.shared.batch.pending_workers == 0)` (`:904-905`).
    ReleaseFast strips both.
  - A nested threaded call from inside a job would overwrite `shared.batch`
    (`:909-921`) while workers still read it.
  - A nested call on a worker thread also mutates the stage tuner or the shared
    tuner concurrently, through `selectBatchProfile` (`:820-827`) and `record`
    (`:951-953`).
  - The inline path (`:890-900`) never touches `shared`, but it still touches
    the tuner.
- **Batch layout.** `Batch` (`:1066-1080`) packs the read-mostly descriptor
  (`item_count`, `items_per_range`, `range_count`, `context`, `job_fn`) together
  with the hot `next_range` atomic, which each claim `fetchAdd`s (`:1028`). It
  also holds two telemetry atomics that are incremented **per range**:
  `main_thread_ranges` and `worker_thread_ranges` (`:1032-1036`,
  `:1049-1053`). Every claim invalidates the line every participant reads in
  `rangeForIndex` (`:1031`).
- **Workers.** `WorkerRecord` (`:1059-1064`), `workerMain` (`:1082`), and
  `workerLoop` (`:971-1004`). The loop already tolerates a wake with no new
  batch (`:981-984`). No thread names are set.
- **Telemetry and allocation tests.** `BatchStats` (`:30-46`) has a size test of
  ≤ 88 bytes (`:1315-1320`). Allocation-free submission tests exist at `:2270`
  and `:2292`.
- **Padding convention.** Six private copies of the file-scope constant
  `thread_shared_record_alignment: usize = 64` exist, one each in
  `systems/pathfinding/scratch.zig`, `systems/simulation_scope.zig`, `systems/spatial_index.zig`,
  `systems/pathfinding/nav_graph.zig`, `systems/collision.zig`, and
  `systems/perception.zig` (Slice 72 I2 removed affect's copy). The rule is the
  `docs/coding-standards.md` sentence "Use 64-byte padding only for concurrently
  written thread-shared records".
- **Build.**
  - The test artifact is defined at `build.zig:160-168` and the bench artifact
    at `:154-158`. Run steps are at `:225-234`. Modules are created in
    `createSdlModule` (`:323-337`).
  - Zig 0.17's `std.Build.Module.CreateOptions.sanitize_thread: ?bool` exists
    (`lib/std/Build/Module.zig:222`), and the toolchain bundles `lib/libtsan`.
  - x86_64-Linux Debug builds use the self-hosted backend by default
    (`docs/development-workflow.md:122-126`), and that backend does not perform
    TSan instrumentation.
- **Thread naming in Zig 0.17.** `std.Thread.setName(self, io, name)`
  (`lib/std/Thread.zig:52`) can name any thread on Linux and Windows, but only
  the calling thread on Darwin. `max_name_len` is 15 on Linux (`:31-44`).
  `std.Thread.getCurrentId` is a cached thread-local read on Linux, and
  `pthread_threadid_np` on Darwin.

### Architecture notes

All changes are in `src/app/thread_system.zig` unless noted. No `StageId` or
pipeline contract changes.

**(a) Release-safe reentrancy: run inline or fail loudly, never corrupt**

Decision: the policy depends on which thread calls.

- **A thread already participating in a batch of this system** (a pool worker
  of this system, or this system's owner thread while it runs its own ranges)
  gets **forced inline** execution. The whole nested batch runs on the calling
  thread, under the caller's own `WorkerId`, in every build mode.
- **A thread that neither owns this `ThreadSystem` nor works for it** gets a
  `@panic` in every build mode. That includes a participant of a *different*
  `ThreadSystem`: its `WorkerId` indexes the other system's scratch slots
  (`scratchSlotForWorker(id) = id.index`, `thread_system.zig:785-787`), which
  can exceed this system's `participantSlotCount`, so running it inline would
  be an out-of-bounds scratch write in ReleaseFast. Tests and benches build
  many `ThreadSystem`s, so this case is real.

Rejected alternatives:
- **Return an error.** That changes the infallible signature at 39 call sites.
  Void-returning `JobFn` jobs would still have nowhere to propagate it.
- **Panic on nesting.** That turns a recoverable composition mistake into a
  shipped crash. Inline execution is always a correct execution of the
  range-disjoint job contract: it is the serial fallback every processor already
  supports. Output determinism is preserved, because the range set and range
  indices are unchanged.

Foreign threads get a panic, not a fallback, because no safe execution exists
for them. The caller owns no participant scratch slot, so running inline as slot
0 would race the owner's slot-0 scratch. A loud crash beats silent memory
corruption in ReleaseFast. Slice 51's lane thread falls in this class, so a
background job that reaches `parallelFor` fails loudly. A lane job that wants
data-parallel work (for example off-main-thread worldgen, Slice 58) must call a
serial code path with no `ThreadSystem`.

- **Detection** uses no locks and happens before any tuner access:
  - `threadlocal var participant_role: ParticipantRole = .none;` where
    `const ParticipantRole = enum(u8) { none, dispatching, pool_worker };`.
  - `threadlocal var participant_worker_index: usize = 0;`.
  - `threadlocal var participant_shared: ?*const Shared = null;`, set and
    cleared together with the role. `Shared` is heap-allocated and never
    moves, so its address identifies the system.
  - Workers set `.pool_worker`, their index, and their system's `shared` once
    at the top of `workerMain`. They only ever run jobs.
  - The owner thread sets `.dispatching` (index 0, `self.shared`) around its
    own `runBatchRanges` participation (`:934`) and restores `.none` / `null`
    afterwards.
  - New field `owner_thread_id: std.Thread.Id`, captured in `init`.
  - The entry check runs at the top of `parallelForWithOptions` and of
    `selectBatchProfile`:

    ```zig
    switch (participant_role) {
        .dispatching, .pool_worker => {
            if (participant_shared != self.shared)
                @panic("ThreadSystem: parallelFor called from a participant of a different ThreadSystem");
            return self.runForcedInline(...); // caller's own WorkerId
        },
        .none => if (std.Thread.getCurrentId() != self.owner_thread_id)
            @panic("ThreadSystem: parallelFor called from a thread that does not own or serve this ThreadSystem"),
    }
    ```
- **Forced-inline range shape.** It never reads or writes a tuner, because
  tuners are not thread-safe.
  - If `options.selected_profile` is present, keep its `items_per_range`
    (aligned). Callers that pre-sized per-range buffers from
    `selectBatchProfile` then see the same `range.index` set.
  - Otherwise use `options.items_per_range orelse self.config.items_per_range`,
    aligned by `range_alignment_items`.
  - It runs through a `runInline` variant that passes the caller's
    `WorkerId{ .index = participant_worker_index }`, so per-participant scratch
    is the caller's own slot.
  - Documented rule: a processor must not nest a batch that reuses *its own*
    per-worker scratch.
- **`selectBatchProfile` while participating** returns the same fixed,
  tuner-free selection. Stage pre-sizing helpers therefore stay safe inside
  jobs.
- **The two asserts at `:904-905`** stay as `std.debug.assert`. After the role
  and owner checks, the conditions they guard are provably impossible: only the
  non-participating owner reaches dispatch.
- **Telemetry.**
  - Add `BatchStats.forced_inline: bool = false`. It fits existing padding, so
    the ≤ 88-byte size test is kept.
  - Add `forced_inline_batches: std.atomic.Value(u64)`, incremented `.monotonic`
    from any participant and read through
    `pub fn forcedInlineBatchCount(self: *const ThreadSystem) u64`.
  - The first forced-inline batch per system logs once:
    `log.warn("parallelFor re-entered inside a job; ran {} items inline on participant {}", ...)`,
    guarded by `if (comptime logging.enabled(.warn))` and a `cmpxchgStrong` on
    `forced_inline_warned: std.atomic.Value(bool)`. It stays in shipped
    builds: ReleaseFast/ReleaseSmall map the `auto` log level to `.warn`
    (`build.zig:750`). That is deliberate. Forced inline is a recovered
    composition mistake (`warn` per the logging rules), it fires at most once
    per system lifetime, and it is never on a correct program's hot path.

**(b) Claim-line isolation**

- `const batch_line_bytes = std.atomic.cache_line;` This is 128 on x86_64 and
  aarch64 (covering the x86 adjacent-line prefetch pair and 128-byte Apple
  cores) and 64 elsewhere.
  - This deliberately deviates from the repo's 64-byte per-slot convention.
    `Batch` is a singleton costing 3 lines (384 B) in total. The 64-byte rule
    governs per-worker slot arrays, where size multiplies.
  - `docs/coding-standards.md` gets one sentence noting this.
- Split `Batch` into three line-aligned parts:

```zig
const BatchDescriptor = struct { // written once at dispatch under mutex; read by every participant per claim
    id: u64 = 0, item_count: usize = 0, items_per_range: usize = 1, range_count: usize = 0,
    active_worker_thread_count: usize = 0, context: ?*anyopaque = null, job_fn: ?JobFn = null,
};
const BatchCompletion = struct { // written under mutex once per participant at completion
    pending_workers: usize = 0, main_thread_ranges: usize = 0, worker_thread_ranges: usize = 0,
};
const BatchClaim = struct { next_range: std.atomic.Value(usize) = .init(0) }; // the only per-claim RMW
const Batch = struct {
    desc: BatchDescriptor align(batch_line_bytes) = .{},
    completion: BatchCompletion align(batch_line_bytes) = .{},
    claim: BatchClaim align(batch_line_bytes) = .{},
};
comptime {
    std.debug.assert(@sizeOf(BatchDescriptor) <= batch_line_bytes);
    std.debug.assert(@sizeOf(BatchCompletion) <= batch_line_bytes);
    std.debug.assert(@sizeOf(BatchClaim) <= batch_line_bytes);
    std.debug.assert(@alignOf(Batch) == batch_line_bytes);
    std.debug.assert(@sizeOf(Batch) == 3 * batch_line_bytes);
}
```

  Each field is line-aligned and no larger than one line, so Zig's auto-layout
  reordering cannot put two parts on one line. `Shared` is heap-allocated with
  `allocator.create` (`:718`), which honors `@alignOf`.
- **Remove per-range telemetry atomics from the claim loop.**
  - `runBatchRanges` and `runBatchRangeIndex` return the number of ranges they
    ran.
  - A worker adds its count to `completion.worker_thread_ranges` under the mutex
    it already takes in `completeWorker`.
  - The main thread adds its count under the mutex it takes after the wait
    (`:937-944`).
  - `BatchStats.main_thread_ranges` and `worker_thread_ranges` keep their exact
    meaning.
  - The only shared RMW left in the claim loop is
    `claim.next_range.fetchAdd`.
- `WorkerRecord` wake semaphores stay unpadded in this slice: there is one
  post per worker per batch. Slice 65A pads `WorkerRecord` (unconditionally,
  with comptime asserts and the `thread-dispatch` non-regression gate).

**(c) Worker thread names**

- Names use the format `"zl-worker-{d}"` with `WorkerId.index`, which is 1-based
  and matches `scratchSlotForWorker`. A comptime assert checks
  `"zl-worker-".len + 5 <= 15`, the Linux limit and the tightest supported.
  Slice 51 uses `"zl-bg-lane"`.
- `workerLoop` takes `*WorkerRecord` instead of `(id, wake)`.
- Each worker names **itself** by calling `std.Thread.setName` on its own
  `worker.thread`. That is the only form Darwin supports, and it is the approach
  VoidLight uses.
  - It happens once, on the first wake that carries a live batch, after the
    `accepting_work` shutdown check and before the first range. A loop-local
    `named` bool guards it, so there is one predictable branch per wake.
  - The spawner writes `worker.thread` before `init` returns, and the worker
    reads it after a semaphore wake, so the semaphore orders the read.
  - Errors (`Unsupported`, `NameTooLong`, unexpected) are ignored after one
    comptime-gated `log.debug`.
- The main thread is not renamed. On Linux, `PR_SET_NAME` on the main thread
  renames the process `comm`.

**(d) `-Dsanitize-thread`**

- `build.zig` adds the option:
  `const sanitize_thread = b.option(bool, "sanitize-thread", "Instrument unit tests and benchmarks with ThreadSanitizer (LLVM backend)") orelse false;`
  `createSdlModule` gains a `sanitize_thread: bool` parameter that sets
  `.sanitize_thread`.
- **Targets.** It applies to `unitTestsModule` and `benchModule` only. The app
  exe and `gpu-smoke` are excluded: SDL and GPU driver threads are
  uninstrumented and produce reports that are not about framework code, and
  neither artifact exercises worker code headlessly.
- **When enabled**:
  - `unit_tests.use_llvm = true` and `bench_exe.use_llvm = true`, because the
    self-hosted backend does not instrument.
  - `use_lld = true` on Linux and null elsewhere (Zig 0.17's LLD cannot link
    Mach-O; the same rule as LTO).
  - Unsupported targets (Windows, or any arch other than x86_64/aarch64) attach
    `b.addFail("-Dsanitize-thread supports x86_64/aarch64 Linux and macOS only")`
    to the test and bench steps instead of silently ignoring the flag.
  - Run steps set `TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1` through
    `setEnvironmentVariable`, so the first report fails the step.
- **Suppressions.** None for framework code. A `tools/tsan.supp` may be added
  only for uninstrumented third-party code (SDL), with a cited root cause per
  entry, wired through `TSAN_OPTIONS=suppressions=...`.
- **First implementation step: probe the toolchain.** Build and run
  `zig build test -Dsanitize-thread=true` on x86_64 Linux with this exact Zig
  0.17. If Zig rejects a backend, linker, or target combination, record the
  exact error in this slice's Status and narrow the supported-target check to
  what works. Never drop the flag silently.
- **Documented runs**, in a new `docs/development-workflow.md` section
  "## Thread Sanitizer":
  - `zig build test -Dsanitize-thread=true`: the full suite, in Debug.
  - `zig build bench -Dsanitize-thread=true -- --profile quick --group <g>` as a
    race smoke, for these threaded groups: `movement`, `collision`, `steering`,
    `perception`, `pathfinding-hard-fallback`, `scope`, `thread-dispatch`, and
    (after Slice 51) `background-lane`. TSan timings are never performance
    numbers.
  - These runs are required before merging changes to `thread_system.zig`, to
    Slice 51's lane, or to any processor's threaded range writes.
  - They are not part of `zig build verify`: they force LLVM and run roughly
    5–15× slower.

**Bench**

- New `src/benchmarks/thread_dispatch.zig`, group `thread-dispatch`, registered
  in `runner.zig`:
  - The job is trivial per item: `out[i] = @as(u32, @truncate(i)) *% 2654435761`
    over a preallocated `u32` buffer.
  - Items: the `suite.eventScaleCounts` ladder. Cases: `default_cases`.
  - It isolates wake, claim, and join cost, which is where claim-line false
    sharing shows.
- **Gate.** Capture before and after on the same machine in ReleaseFast:
  - `zig build -Doptimize=ReleaseFast bench -- --group thread-dispatch --details`;
  - `zig build -Doptimize=ReleaseFast bench -- --group movement --case
    thread-small-range --details` (small ranges mean the most claims per item).

  No case may regress by more than the larger of 3% or the run's reported noise
  band. The expected direction is an improvement on `thread-small-range` and
  `thread-fixed-auto` at ≥ 25,000 items.

### Checklist

- [ ] (a) Participant roles, `owner_thread_id`, forced-inline path,
  `BatchStats.forced_inline`, `forcedInlineBatchCount`, and the warn-once log.
  Tests (test-local job contexts with atomic coverage counters):
  - `test "nested parallelFor from a worker job runs inline on that worker and
    covers every item once"`: outer batch is non-adaptive with 3 workers; each
    nested batch reports `forced_inline` and the nested job sees its outer
    worker's `WorkerId`.
  - `test "nested parallelFor from the owner's own range runs inline"`.
  - `test "forced inline keeps a selected profile's range shape"`: a pre-sized
    per-range buffer indexed by `range.index` stays in bounds and is fully
    covered.
  - `test "forced inline never touches the adaptive tuner"`: the tuner
    `report()` is identical before and after.
  - `test "forced inline batches are allocation-free"`: extends the
    `FailingAllocator` pattern at `:2270`.
  - The foreign-thread panic cannot be exercised in-process. That includes a
    worker job of system A calling system B's `parallelFor`, which panics
    because `participant_shared != B.shared`. Document both, and cover them in
    review.
- [ ] (b) `BatchDescriptor`, `BatchCompletion`, `BatchClaim` split with comptime
  asserts; per-participant range counts folded under the mutex. Tests:
  - `test "batch claim counter owns its cache line"`: runtime restatement of
    the layout facts.
  - `test "per-participant range telemetry is exact under heavy claiming"`:
    3 workers, 4096 items, `items_per_range = 1`, `adaptive = false`. Expect
    `main_thread_ranges + worker_thread_ranges == range_count` and exact
    coverage.
  - Existing coverage and range-index tests stay green.
- [ ] (c) Self-naming workers. Test: `test "workers name themselves after their
  first batch"`. On Linux only (`error.SkipZigTest` elsewhere), run one threaded
  batch that wakes every worker: `adaptive = false`,
  `max_worker_threads = workers.len`, and
  `item_count >= workers.len * items_per_range` (only
  `workers[0..active_worker_threads]` are woken, `thread_system.zig:925-927`).
  Then `workers[i].thread.?.getName(&buf)` must equal `"zl-worker-{i+1}"`.
- [ ] (d) `-Dsanitize-thread` option, LLVM/LLD forcing, unsupported-target
  `addFail`, and `TSAN_OPTIONS` on the run steps. Record the toolchain-probe
  result in Status.
- [ ] Bench group `thread-dispatch` registered; before/after captures attached
  to the slice Status.
- [ ] Docs:
  - `docs/architecture.md` Thread System: the reentrancy and ownership rule,
    forced-inline semantics, the foreign-thread panic, worker names.
  - `docs/coding-standards.md`: one sentence on the `std.atomic.cache_line`
    singleton exception.
  - `docs/development-workflow.md`: "## Thread Sanitizer" and the
    `thread-dispatch` group in Benchmarks.

### Acceptance checks

- [ ] `zig build test` passes. `zig build test -Doptimize=ReleaseFast` also
  passes once, which proves forced inline behaves identically with asserts
  stripped. Record it in Status.
- [ ] `zig build test -Dsanitize-thread=true` runs with zero TSan reports on
  x86_64 Linux. The `movement`, `collision`, `steering`, and `thread-dispatch`
  quick bench groups run clean under `-Dsanitize-thread=true`. If the probe
  forced narrowing, the exact error and the supported-target list are in
  Status.
- [ ] The comptime layout asserts hold. The claim loop has no telemetry atomics;
  `grep fetchAdd` in `runBatchRanges` shows only `next_range`.
- [ ] Bench gate as specified: no regression beyond max(3%, noise) on
  `thread-dispatch` or `movement --case thread-small-range`.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Port**:
  - `include/core/ThreadSystem.hpp:346-349` `struct alignas(64) AlignedAtomic`
    isolates hot counters on their own lines. ZeroLight does this for the claim
    counter and removes the per-range telemetry atomics outright.
  - `ThreadSystem.hpp:467-476`: workers name themselves from inside the thread
    (`pthread_setname_np(pthread_self(), ...)`, plus the Darwin current-thread
    form). ZeroLight uses `std.Thread.setName` on the worker's own handle, for
    the same Darwin reason.
  - VoidLight `CLAUDE.md:72-80` documents a TSan build with `TSAN_OPTIONS`.
    ZeroLight adopts a build-option equivalent.
- **Do not port**:
  - `tests/tsan_suppressions.txt` (130 lines) suppresses races in VoidLight's
    own managers (for example `race:ParticleManager::updateParticleRange`),
    justified by "hours of stable runtime". ZeroLight never suppresses its own
    code. Each report is either fixed or shown false by a concrete
    happens-before edge.
  - VoidLight exposes `enqueueTaskWithResult` futures (`ThreadSystem.hpp:577`)
    to any caller, including code already running on a pool worker, with no
    rule. Blocking on such a future from a worker occupies the worker it waits
    on. ZeroLight's forced-inline rule for participants, plus the panic for
    foreign threads, replaces that.

---

