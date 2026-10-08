## Slice 65A: Thread-Shared Layout Consolidation And Background-Lane OS Priority

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 50](slice-50.md), [Slice 51](slice-51.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **50**, which adds `WorkerRecord`-based
`workerLoop`, self-naming, the `thread-dispatch` bench, and TSan. Depends on
**51**, which adds `BackgroundLane`, the `background-lane` bench, and the
lane-thread loop. The checklist item that consolidates
`thread_shared_record_alignment` touches no 50/51 code. It may land first as
its own commit.

Goal:
- The 64-byte thread-shared record rule has one owner, used by six modules.
  Every padded slot type is checked at comptime against it.
- Each worker's wake semaphore sits on its own line.
- Per-range `SimulationEvents` stats and `RangeOutputStream` cursors sit on
  their own lines (Checklist (e), (f)).
- The lane thread lowers its own OS priority on Linux, Windows, and Darwin.
  Fork-join workers then win any core they share with a running lane job.
- The worker-pool size stays a fixed function of CPU count, with no core
  reserved for the lane.
- No dispatch regression.

### Current foundation

- **Six private copies** of `const thread_shared_record_alignment: usize = 64;`
  (file-scope symbol `thread_shared_record_alignment` in each):
  - `systems/pathfinding/scratch.zig` (added by the Slice 72 Batch A review
    follow-up, which moved `SearchScratch` from `std.atomic.cache_line` to the
    64 B rule by measurement; see the slice-72 Status)
  - `systems/simulation_scope.zig`
  - `systems/spatial_index.zig`
  - `systems/pathfinding/nav_graph.zig`
  - `systems/collision.zig`
  - `systems/perception.zig`
- **Four identical private `paddingForCacheLine(comptime T)` helpers**
  (file-scope `fn paddingForCacheLine`; Slice 72 I2 deleted affect's copy, its
  constant and `AffectEventRangeSlot`): `systems/spatial_index.zig`,
  `systems/simulation_scope.zig`, `systems/collision.zig`,
  `systems/perception.zig`.
- **The padded slot types they guard**:
  - `GatherTallySlot` (`simulation_scope.zig:584-592`, already with a comptime
    size assert; runtime size test `:1552`). Slice 72 C5 replaced the old
    `IndexRangeSlot` / `CommandRangeSlot` with windows plus this tally.
  - `RowCountTally` (`spatial_index.zig:834-842`, already with a comptime size
    assert; C5 replaced `RowRangeSlot`)
  - `BroadphaseRangeSlot` / `ContactCountTally` (`collision.zig:171-195`;
    runtime tests `:1469-1470`; C5 replaced `NarrowphaseRangeSlot`)
  - `PerceptionRangeStatsSlot` (`perception.zig:329-337`; Slice 72 I1 deleted
    `PerceptionEventRangeSlot`)
  - `ChunkPatchScratch` / `ChunkRemaskScratch` (`nav_graph.zig:150-183`).
    These use a field `align(...)` and already carry comptime asserts at
    `:156-159` and `:180-183`.
  - `SearchScratch` (`pathfinding/scratch.zig`, the per-participant
    `PathfindingSystem.scratch_slots` entries): field `align(...)` on
    `generation` plus comptime `@alignOf`/`@sizeOf` asserts, like nav_graph.
- **Out of scope** (different concepts, not thread-shared records):
  - `hot_soa_column_alignment` (`data_system/types.zig:21`) and
    `hot_particle_column_alignment` (`systems/particle.zig:24`) are SIMD
    column-base alignments.
  - Slice 50's `batch_line_bytes = std.atomic.cache_line` sizes a singleton,
    not a slot array.
- **Rule text:** `.claude/rules/threading.md` ("64-byte padding only
  for concurrently written thread-shared records").
- **`WorkerRecord`** (`thread_system.zig:1059-1064`):
  - Fields: `{ id, shared, wake: std.Io.Semaphore, thread: ?std.Thread }`.
  - It is allocated as one contiguous slice (`:722`), and dispatch posts
    `workers[0..active]` in a loop (`:927-929`).
  - `std.Io.Semaphore` is `{ mutex, cond, permits }`
    (`lib/std/Io/Semaphore.zig:11-14`). Both `post` (`:62-68`) and
    `waitUncancelable` (`:52-59`) lock the semaphore's own mutex, so the
    poster (main) and the waiter (worker) both write the line.
  - Probed with Zig 0.17 on x86_64-linux, Debug and ReleaseFast: `Semaphore`
    is 24 B and `?std.Thread` is 16 B, so `WorkerRecord` is **56 B with
    alignment 8**. Records straddle lines, and main's post to worker i+1
    contends with worker i's wake on a shared line.
- **Pool size:** `resolveWorkerThreadCount` (`thread_system.zig:1092-1099`)
  returns `cpu_count - 1` when `ThreadSystemConfig.max_worker_threads` is
  null (`:48-57`). `Engine.init` creates the pool at `engine.zig:130` from
  `app_config.threading` (`config.zig:26`). VoidLight uses the same rule
  (`include/core/ThreadSystem.hpp:826-855`).
- **Slice 51 statements this slice settles:**
  - "No OS priority lowering … Scaling Gap" (roadmap Slice 51 thread policy).
  - "The lane thread is not subtracted from the pool … a fixed threshold
    decides whether to promote a reserve-a-core policy".
  - Its bench-gate clause "promote the 'reserve a pool worker for the lane'
    Scaling Gap".
  - Slice 50 says "`WorkerRecord` wake semaphores stay unpadded … a
    measure-first Scaling Gap".
- **Priority APIs in Zig 0.17 std:**
  - Linux:
    - `std.os.linux.gettid()` exists (`lib/std/os/linux.zig:2667`).
    - `std.os.linux.syscall3` is exported (`:73`).
    - There is no `setpriority` wrapper, and libc's is not declared in
      `std.c`.
  - Darwin: `std.c.pthread_set_qos_class_self_np(qos_class_t, c_int)`
    (`lib/std/c.zig:11872`, `c/darwin.zig:998`), with
    `qos_class_t.UTILITY = 0x11` (`c/darwin.zig:904-918`).
  - Windows: `std.os.windows.GetCurrentThread()` exists
    (`lib/std/os/windows.zig:3591`), but there is no `SetThreadPriority`
    binding.
- **SDL3's `SDL_SetCurrentThreadPriority(SDL_THREAD_PRIORITY_LOW)`**
  (`SDL3/SDL_thread.h:434`; source as vendored in VoidLight's
  `build/_deps/sdl3-src`):
  - Linux: `setpriority(PRIO_PROCESS, tid, 19)`. On failure it falls back to
    RealtimeKit over D-Bus (`src/core/linux/SDL_threadprio.c:301-341`).
  - Apple: `pthread_setschedparam(SCHED_OTHER, sched_get_priority_min)`
    (`src/thread/pthread/SDL_systhread.c:253-255`).
  - Windows: `THREAD_PRIORITY_LOWEST`
    (`src/thread/windows/SDL_systhread.c:174-175`).

### Architecture notes

**(a) One owner for the thread-shared record rule
(`src/app/thread_system.zig`)**

```zig
/// Size/alignment quantum for records written concurrently by different threads:
/// per-range output slots, per-participant scratch, and `WorkerRecord`. Slot
/// arrays multiply, so this stays 64, not `std.atomic.cache_line` (128 on
/// x86_64/aarch64), which sizes singleton records such as the batch lines.
pub const thread_shared_record_alignment: usize = 64;

/// Bytes of trailing padding that round `@sizeOf(T)` up to a whole number of
/// thread-shared lines. Pure comptime helper; zero when already a multiple.
pub fn threadSharedRecordPadding(comptime T: type) usize {
    const rem = @sizeOf(T) % thread_shared_record_alignment;
    return if (rem == 0) 0 else thread_shared_record_alignment - rem;
}

/// Comptime layout gate for a padded thread-shared record type: size is a
/// non-zero multiple of the quantum. Call inside a `comptime { }` block next to
/// the type so a field added to the payload fails `zig build check`, not a race.
pub fn assertThreadSharedRecord(comptime T: type) void {
    if (@sizeOf(T) == 0 or @sizeOf(T) % thread_shared_record_alignment != 0)
        @compileError(@typeName(T) ++ " is not a whole number of thread_shared_record_alignment lines");
}
```

- **Each of the six sites** replaces its private literal with a
  direct-declaration import:
  - `const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;`
    (`nav_graph.zig` uses `../../../`, and already imports `thread_system.zig`
    at `:16-20`).
  - The four `paddingForCacheLine` helpers are deleted. Call sites become
    `threadSharedRecordPadding(...)`.
- **Each site** gains one `comptime` block that calls
  `assertThreadSharedRecord` for every slot type it owns:
  - simulation_scope: `GatherTallySlot`;
  - spatial_index: `RowCountTally`;
  - collision: `BroadphaseRangeSlot`, `ContactCountTally`;
  - perception: `PerceptionRangeStatsSlot`;
  - nav_graph: `ChunkPatchScratch`, `ChunkRemaskScratch`;
  - pathfinding/scratch: `SearchScratch` (imports
    `../../../app/thread_system.zig`).

  The nav_graph types and `SearchScratch` keep their `@alignOf == thread_shared_record_alignment`
  asserts. Field-level alignment is how those two types get their line, while
  the `ArrayListAligned` lists supply alignment for the others. The existing
  runtime size/alignment tests stay.
- The `ArrayListAligned(…, .fromByteUnits(thread_shared_record_alignment))`
  aliases keep their names. They now resolve to the shared constant.
- **Lint:** `tools/lint_idioms.py` gains a `SRC_ONLY_PATTERNS` entry with an
  owner exemption set `THREAD_SHARED_RECORD_OWNER = {"src/app/thread_system.zig"}`.
  - It rejects the typed literal declaration
    `\bconst\s+thread_shared_record_alignment\s*:`.
  - It rejects a private helper definition
    `\bfn\s+(paddingForCacheLine|threadSharedRecordPadding)\b`.
  - Both report one message: "thread-shared record quantum is owned by
    src/app/thread_system.zig; import it".
  - The untyped alias import (`const thread_shared_record_alignment = @import(...)`)
    does not match.

**(b) `WorkerRecord` line padding**

- The decision is to pad unconditionally. The bench is a non-regression gate,
  not an input to the decision.
  - `wake` is written by two threads every batch: main's `post` and the
    worker's wait. That puts it under the coding standard's "concurrently
    written thread-shared record" rule.
  - Padding costs 8 B per worker. That is ≤ 504 B at 63 workers, never on a
    per-item path.

```zig
const WorkerRecord = struct {
    // align on the concurrently written field makes the whole record one
    // thread-shared line: main posts `wake`, the worker waits on it, and Slice
    // 50's self-naming reads `thread` after the wake. Neighbours never share it.
    wake: std.Io.Semaphore align(thread_shared_record_alignment) = .{},
    id: WorkerId = WorkerId.main,
    shared: *Shared = undefined,
    thread: ?std.Thread = null,

    comptime {
        std.debug.assert(@alignOf(WorkerRecord) == thread_shared_record_alignment);
        std.debug.assert(@sizeOf(WorkerRecord) == thread_shared_record_alignment);
    }
};
```

- `@sizeOf == 64` is exact: the payload is 56 B on the probed targets. If a
  future field pushes it past 64, the assert fires and the author re-decides
  (128-byte records). It is never silently two records per line.
  `allocator.alloc(WorkerRecord, n)` at `:722` honors `@alignOf`.
- No other `ThreadSystem` layout changes. Slice 50 owns `Batch`.
  `BackgroundLane` has one thread and a mutex-guarded slot table, so it has
  no per-thread array to pad.

**(c) Lane OS priority: a platform helper, not SDL**

New file `src/platform/thread_priority.zig`, owned by platform. App code
imports it; game code never does.

```zig
pub const ThreadPriorityResult = enum { lowered, unsupported, failed };
/// Linux nice value for the background lane (see reasoning below).
pub const background_thread_linux_nice: i32 = 10;
/// Lowers the CALLING thread's scheduling priority to the background policy.
/// Never raises; never touches another thread; no allocation, no logging.
pub fn lowerCurrentThreadPriority() ThreadPriorityResult;
```

| OS | Call | Value |
| --- | --- | --- |
| Linux (any libc or none) | `std.os.linux.syscall3(.setpriority, prio_process, @intCast(std.os.linux.gettid()), @bitCast(@as(isize, background_thread_linux_nice)))`, with `const prio_process: usize = 0`; success iff `std.os.linux.errno(rc) == .SUCCESS` | nice **10**. On Linux, nice is a per-thread attribute when addressed by TID. Lowering needs no privilege. |
| Windows | file-local `extern "kernel32" fn SetThreadPriority(h: std.os.windows.HANDLE, n: c_int) callconv(.winapi) std.os.windows.BOOL;` on `std.os.windows.GetCurrentThread()`; nonzero means success | `THREAD_PRIORITY_BELOW_NORMAL = -1` |
| macOS (Darwin) | `std.c.pthread_set_qos_class_self_np(.UTILITY, 0) == 0` | QoS **UTILITY** |
| other targets, or `builtin.single_threaded` | none | `.unsupported` |

- **Why not `SDL_SetCurrentThreadPriority`:**
  - On Linux, SDL's LOW is nice 19. That is CFS/EEVDF weight 15 against
    1024, about a 1.5% share of a contended core.
  - Its failure path makes a RealtimeKit D-Bus call from the job thread.
  - On Apple it calls `pthread_setschedparam`, which takes the thread out of
    QoS. On Apple Silicon, QoS is what places background work sensibly.
  - The Zig 0.17 std calls above cover all three OSes with one
    `kernel32` extern. SDL stays the app/render window and input boundary,
    not a thread-scheduling dependency of `background_lane.zig`.
- **Why nice 10:**
  - The CFS weight is 110 against 1024 for nice 0. So:
    - A waking fork-join worker reaches EEVDF eligibility against the lane
      about 9.3× sooner than against a nice-0 thread, and preempts it within
      a fraction of the 3 ms base slice.
    - The lane still keeps about 10% of a contended core, so a main-thread
      wait at a due step under external desktop load stays bounded (about
      10× the job time).
  - `SCHED_IDLE` can starve indefinitely, which would turn the main
    thread's deterministic due-step wait into an unbounded priority
    inversion; it is rejected outright. Nice 19 (weight 15, about 68× less
    than nice 0) is bounded but stretches that wait to roughly 68× the job
    time under contention, so it is not the default and is not on the
    fallback ladder either (the ladder stops at 15, weight 36). Raising
    nice back up needs `CAP_SYS_NICE`, so there is no temporary boost.
- **Why `BELOW_NORMAL`:** Windows schedules by strict priority, so one level
  below the workers' NORMAL (8 → 7) already makes every runnable worker
  preempt the lane. Going lower only adds starvation, which the balance-set
  manager would offset anyway. `THREAD_MODE_BACKGROUND_BEGIN` is rejected
  because it also lowers I/O and memory priority, and replay flushes and
  Slice 46 saves are lane I/O.
- **Why `UTILITY`:** Apple documents it as the class for long-running work
  that is not user-interactive. `BACKGROUND` is rejected because of heavy
  I/O throttling and E-core-only placement.
- **I/O effects accepted:**
  - Linux BFQ/CFQ derive best-effort I/O level 6 from nice 10. mq-deadline
    and none (NVMe) ignore it.
  - Darwin UTILITY is I/O-throttled only under contention with higher tiers.
- **Lane wiring (Slice 51's lane-thread entry, `background_lane.zig`):**
  - `BackgroundLaneConfig` gains `lower_os_priority: bool = true`.
  - The lane thread calls `lowerCurrentThreadPriority()` once, at the top
    of its entry function, immediately after Slice 64A's
    `fp_env.assertDefault("background lane")` (64 Checklist addition (k);
    whichever of 64A/65A lands second rebases), before the first `work`
    wait. Unlike
    self-naming, it needs no handle, so it does not wait for the first wake.
    Every job therefore runs at the lowered priority.
  - It records the result under the lane mutex in
    `BackgroundLaneStats.os_priority: LaneOsPriority`, where
    `LaneOsPriority = enum(u8) { pending, inherited, lowered, unsupported, failed }`.
    The value is `inherited` when the config disables lowering. Diagnostics
    only; it must not feed simulation.
  - Logging is one comptime-gated `log.debug` for `lowered` / `unsupported` /
    `inherited`. A `failed` result logs one `log.warn`: "background lane
    could not lower its OS priority; fork-join interference is not
    mitigated". It is never fatal.
  - The main thread and pool workers are never touched. Pool workers keep
    the process default.

**(d) Pool size: fixed rule, no core reservation**

- The rule is `resolveWorkerThreadCount(null) = cpu_count - 1` (`0` when
  `cpu_count <= 1`) regardless of whether the lane exists or is busy. An
  explicit `ThreadSystemConfig.max_worker_threads` is honored verbatim.
  `Engine.init` never derives the threading config from
  `AppConfig.background_lane`.
- **Why no reservation:**
  - The lane is parked nearly all the time. Its CPU-heavy consumers (65B
    deferred nav rebuild, 65C load-time worldgen, Slice 46 save encode) are
    rare or load-time.
  - Permanently removing a fork-join participant would cost every step to
    serve an idle lane. That is 25% of the pool on a 4-thread laptop.
  - With (c), the scheduler resolves contention in the workers' favor on
    every OS:
    - Linux: weight plus EEVDF wakeup preemption.
    - Windows: strict priority.
    - Darwin: QoS.
  - Between batches, which is most of a 16.67 ms step, the lane gets idle
    cores.
  - A rule that depends on lane activity or measured interference would
    make the worker count a function of timing. That is rejected.
- `thread_system.zig`'s `resolveWorkerThreadCount` doc comment states this
  rule and names Slice 65A.
- **Bench gate.** Slice 51's `background-lane` group already times
  `MovementSystem.update` while a CPU-bound lane job runs. This slice
  registers its twin group `background-lane-inherit` in `runner.zig`. It is
  the same file, with the lane built with `lower_os_priority = false`, and
  both report `os_priority` in `--details`.
  - Gate: in ReleaseFast at `--items 50000 --case thread-adaptive-tuned-range`,
    the `background-lane` (lowered) mean is within 10% of the `movement`
    mean.
  - Record all three numbers in Status.
  - If the gate fails on an OS, the pool rule does not change. That OS's
    value steps down a fixed ladder, one rung per re-run, recorded in
    Status:
    - Linux: nice 10 → 15 (`background_thread_linux_nice` becomes 15).
    - Windows: `BELOW_NORMAL` → `LOWEST` (`THREAD_PRIORITY_LOWEST = -2`).
    - Darwin: QoS `UTILITY` relative priority 0 → −15
      (`pthread_set_qos_class_self_np(.UTILITY, -15)`; −15 is
      `QOS_MIN_RELATIVE_PRIORITY`, the API's allowed floor). The readback
      test then expects relative priority −15 from
      `pthread_get_qos_class_np`.
  - **Final outcome (the ladder always terminates).** The first passing
    rung is kept. If the last rung still fails, that rung's value is kept,
    the `--details` numbers for every rung are recorded in Status as an
    accepted deviation for that OS ("lane interference above 10% at the
    lowest bounded priority"), and the gate is closed. The slice completes
    either way; the pool rule and the default rung for other OSes are
    unchanged.

### Checklist

- [ ] (a) Shared rule in `src/app/thread_system.zig`:
  `thread_shared_record_alignment`, `threadSharedRecordPadding`,
  `assertThreadSharedRecord`.
  - All six sites switch to the import, and the four helper copies are
    deleted.
  - Each site gets a comptime block with `assertThreadSharedRecord` over
    every slot type listed above.
  - The `nav_graph.zig` comment at `:135-136` ("same policy as …") now names
    the owner.
  - Tests in `thread_system.zig`:
    - `test "thread-shared padding rounds records to whole lines"`: sizes
      1, 56, 63, 64, 65, and 120, through test-local
      `struct { a: [N]u8 }` types. Padding plus size is a multiple of 64,
      and an exact multiple gets zero padding.
    - Existing `simulation_scope.zig:1554-1555` and
      `collision.zig:1348-1357` tests stay green.
- [ ] Lint rule in `tools/lint_idioms.py` with its owner exemption.
  Verification: a temporary private copy added in a scratch branch is
  flagged, which is recorded in Status. No copy remains on the branch.
- [ ] (b) `WorkerRecord` padding with comptime asserts. Test:
  `test "worker records occupy exactly one thread-shared line each"`.
  - `ThreadSystem.init` uses `max_worker_threads = 3`.
  - Expect `@intFromPtr(&workers[0]) % thread_shared_record_alignment == 0`.
  - Expect `@intFromPtr(&workers[1]) - @intFromPtr(&workers[0]) == thread_shared_record_alignment`.
  - One threaded batch still covers every item: reuse `markCoverage`
    (`:1295`).
  - Confirmed by the Slice 72 Batch A review (2026-10-06): `WorkerRecord`
    (`thread_system.zig:1059`, allocated as one slice at `:722`, held at
    `:713`) is still unpadded; this item owns it.
- [ ] (c) `src/platform/thread_priority.zig` with the per-OS table above.
  Test `test "lowering the calling thread leaves other threads unchanged"`
  spawns a `std.Thread` that calls `lowerCurrentThreadPriority()` and reads
  its own priority back through a test-local private helper:
  - Linux: raw `syscall2(.getpriority, 0, 0)` returns `20 - nice`, so expect
    `20 - background_thread_linux_nice` (`10` at the default rung). The main thread's value read before and after is unchanged. If
    `errno` is `.PERM`/`.ACCES`, meaning a seccomp/sandboxed builder, the
    test skips and names the errno.
  - Darwin: `std.c.pthread_get_qos_class_np` (already exported by std,
    `lib/std/c.zig:11871`; no local extern) on `std.c.pthread_self()`
    expects `.UTILITY` and the current rung's relative priority.
  - Windows: a file-local `extern "kernel32" fn GetThreadPriority` expects
    the current rung (`-1` at the default).
  - Other targets get `error.SkipZigTest`.
- [ ] Lane wiring: `BackgroundLaneConfig.lower_os_priority`, the call at
  lane-thread entry, `BackgroundLaneStats.os_priority`, and one log line.
  Tests in `background_lane.zig`, using test-local job contexts that read
  priority with the same private readback as above:
  - `test "lane thread runs jobs at lowered OS priority"`: a submitted job
    records its own priority, and `stats().os_priority == .lowered` on
    Linux, Darwin, and Windows.
  - `test "lane with lower_os_priority disabled inherits the owner priority"`:
    the job's value equals the main thread's, and `os_priority == .inherited`.
  - `test "lane without a thread never changes the owner's priority"`
    (`thread_enabled = false`).
- [ ] (d) `resolveWorkerThreadCount` doc comment states the fixed rule.
  Review check: `Engine.init` passes `app_config.threading` unmodified.
- [ ] (e) `SimulationEvents.range_stats` padded per range (Slice 72 Batch A
  review follow-up).
  - What: `range_stats: std.ArrayList(SimulationEventStats)`
    (`simulation.zig:265`) holds one stats record per range, and each
    `RangeWriter.write` bumps its range's record (`rangeWriter` at `:338-344`,
    `SimulationEventStats.record`). The record is 8-byte aligned and not a
    whole number of lines, so adjacent ranges share a line at every boundary.
  - Why: today every production producer writes its event ranges from the main
    thread (perception and affect derive their events from per-row state on the
    main thread after the join, Slice 72 I1/I2), so this is latent. The first producer that calls
    `events.rangeWriter` from workers false-shares on every event. No slice
    currently plans a threaded event producer, so this slice owns the fix.
  - Fix shape: a padded slot
    `SimulationEventRangeStats { stats: SimulationEventStats, _pad: [threadSharedRecordPadding(SimulationEventStats)]u8 = undefined }`
    in an `ArrayListAligned(…, .fromByteUnits(thread_shared_record_alignment))`,
    with `assertThreadSharedRecord` in a comptime block. `RangeWriter.stats`
    points at the slot's `stats`; the main-thread `finishWrite` stats rebuild
    reads `.stats`.
  - Tests: comptime assert; slot stride is a multiple of 64; a real
    multi-worker `ThreadSystem` batch writing one event range per worker gives
    the same merged events and `stats` as the serial path; the existing
    `simulation.zig` range-stats tests (`:1209-1210`) stay green.
  - Bench: `perception`, `ai-affect` (main-thread event merge) for
    non-regression in ReleaseFast.
- [ ] (f) `RangeOutputStream` per-range `counts` / `write_offsets` padded
  (Slice 72 Batch A review follow-up).
  - What: `counts` and `write_offsets` (`simulation.zig:915-917`) are dense
    `usize` arrays, eight ranges per line. A threaded count pass writes
    `counts[range]` (`addCount`), and each worker's `RangeWriter.finish`
    writes `write_offsets[range_index]` (`:1036`).
  - Why: false sharing between neighbouring ranges' workers. It is limited to
    one write per range at finish, plus the count pass, but the
    `RangeOutputStream` is the generic deterministic-emit primitive (Slice 56
    plans a threaded `RangeOutputStream(ActionCandidate)` emit), so the layout
    should be right before the first threaded user lands.
  - Fix shape: one padded per-range cursor record
    `RangeCursor { count: usize, write_offset: usize, _pad: [threadSharedRecordPadding(...)]u8 }`
    in an aligned list replacing the two arrays (or two padded slot lists).
    `offsets` stays dense (main-thread prefix output, read-only during the
    write). Prefix and merge walk the cursor list at a 64 B stride; range
    counts are small, so this is not a hot cost.
  - Tests: comptime assert; a real multi-worker `ThreadSystem` count + write
    over N ranges merges in range order identically to serial; the existing
    `simulation.zig` stream tests (`:1106-1150`) stay green; the
    reserve-then-write FailingAllocator proof allocates nothing.
  - Bench: `perception`, `ai-affect`, `scope` (ReleaseFast) for
    non-regression; once Slice 56 lands, its candidate-emit group too.
- [ ] Bench: register `background-lane-inherit` in `src/benchmarks/runner.zig`.
  Both lane groups print `os_priority` under `--details`.
- [ ] Roadmap cross-edits (same change):
  - Slice 50 "(b) Claim-line isolation" last bullet now says `WorkerRecord`
    is padded by Slice 65A.
  - Slice 51 "Thread policy decision" bullets "No OS priority lowering" and
    "a fixed threshold decides whether to promote a reserve-a-core policy"
    now point at Slice 65A's helper and fixed pool rule.
  - Slice 51 Acceptance bench-gate sentence "If it is not, promote …" now
    reads "Slice 65A's lowered-priority gate supersedes this comparison".
- [ ] Docs:
  - `docs/architecture.md` Thread System: the `thread_shared_record_alignment`
    owner, `WorkerRecord` line padding, and the fixed pool rule.
  - `docs/architecture.md` Background Lane (Slice 51 section): the OS
    priority policy per OS, and why SDL's call is not used.
  - `docs/development-workflow.md` Benchmarks: `background-lane-inherit`.
- [ ] Add the thread-shared record alignment (owner constant, `assertThreadSharedRecord`, lint) rule to `.claude/rules/threading.md` when this lands.

### Acceptance checks

- [ ] `zig build check` passes with the comptime asserts at all six sites and
  on `WorkerRecord`. `grep -rn "thread_shared_record_alignment: usize" src`
  returns only `src/app/thread_system.zig`.
- [ ] `zig build test` passes, and so does `zig build test -Dsanitize-thread=true`
  with zero reports (Slice 50 workflow). The priority tests pass on the 52C
  Linux, Windows, and macOS runners once 52C lands; until then on the local
  OS, recorded in Status.
- [ ] Padding non-regression, captured before and after on the same machine
  in ReleaseFast:
  - `zig build -Doptimize=ReleaseFast bench -- --group thread-dispatch --details`
  - `zig build -Doptimize=ReleaseFast bench -- --group movement --case thread-small-range --details`

  No case regresses by more than max(3%, reported noise). Record the
  smallest-item-count `thread-dispatch` delta (the wake-dominated end) in
  Status.
- [ ] Priority gate, in one session:
  - `zig build -Doptimize=ReleaseFast bench -- --group background-lane --items 50000 --case thread-adaptive-tuned-range --details`
  - `... --group background-lane-inherit ...`
  - `... --group movement ...`

  The lowered mean must be within 10% of `movement`. Record all three
  numbers in Status. On failure, apply the ladder in (d); its final outcome
  (accepted deviation at the last rung) also closes this check.
- [ ] `zig build bench -Dsanitize-thread=true -- --profile quick --group thread-dispatch`
  and `--group background-lane` are clean.
- [ ] `zig build verify` passes (includes `idiom-lint` with the new rule).

### VoidLight reference

- **Port:**
  - `include/core/ThreadSystem.hpp:826-855` sizes the pool at
    `hardware_concurrency - 1`, reserving the main thread only. ZeroLight
    keeps that rule and does not subtract the lane.
- **Do not port:**
  - VoidLight has no OS-level priority. Its `TaskPriority` queue levels
    (`ThreadSystem.hpp:37-43`) reorder a user-space deque, which cannot stop
    a long low-priority task from occupying a core while a frame batch
    waits. ZeroLight lowers the lane thread's OS priority instead.
  - VoidLight has no per-worker padding for its wake path. ZeroLight pads
    `WorkerRecord`.

---

