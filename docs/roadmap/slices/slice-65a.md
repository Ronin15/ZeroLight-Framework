## Slice 65A: Thread-Shared Layout Consolidation And Background-Lane OS Priority

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 50](slice-50.md), [Slice 51](slice-51.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** The quantum-consolidation item touches no 50/51
code and may land first as its own commit.

Goal: the thread-shared record quantum has one owner and every padded slot
type is checked against it at comptime; worker wake records, per-range event
stats, and range-stream cursors each sit on their own line; the lane thread
lowers its own OS priority on Linux, Windows, and Darwin so fork-join workers
win any core they share with a lane job; the pool size stays a fixed function
of CPU count with no core reserved for the lane; no dispatch regression.

### Current foundation

- Six private `thread_shared_record_alignment = 64` constants (`collision.zig`,
  `spatial_index.zig`, `simulation_scope.zig`, `perception.zig`,
  `pathfinding/nav_graph.zig`, `pathfinding/scratch.zig`) and four private
  `paddingForCacheLine` helpers (collision, spatial index, scope,
  perception).
- Padded slot types: `GatherTallySlot`, `RowCountTally`,
  `BroadphaseRangeSlot`, `ContactCountTally`, `PerceptionRangeStatsSlot`,
  `ChunkPatchScratch` / `ChunkRemaskScratch` (nav storage 64G replaces), and
  `SearchScratch`; some already carry comptime size asserts.
- `WorkerRecord` (`thread_system.zig`, `{ id, shared, wake, thread }`) is
  56 B with alignment 8 on x86_64-linux (Zig 0.17 probe) and allocated as one
  slice, so records straddle lines and main's post to one worker contends
  with its neighbor's wake.
- `SimulationEvents.range_stats` (`simulation.zig`) is one unpadded record per
  range; `RangeOutputStream`'s per-range counts and write offsets are dense
  `usize` arrays. Every production event producer writes from the main thread
  today, so this is latent; Slice 56 plans a threaded range-stream emit.
- `resolveWorkerThreadCount` returns `cpu_count - 1` when unset (VoidLight's
  rule too).
- Zig 0.17 std: Linux `setpriority` only by raw syscall, Darwin
  `pthread_set_qos_class_self_np`, no Windows `SetThreadPriority` binding.
  SDL3's low priority is nice 19 with a D-Bus RealtimeKit fallback on Linux,
  `pthread_setschedparam` (leaving QoS) on Apple.
- Slice 72 E7/E8 (pathfinding solve slots and pool stripes) use this slice's
  helper once it lands.

### Architecture notes

- The quantum is 64 B, not `std.atomic.cache_line`, because slot arrays
  multiply; `src/app/thread_system.zig` owns it with a padding helper and a
  comptime layout gate that every padded slot type calls, and an
  `idiom-lint` rule rejects private copies (`.claude/rules/threading.md`).
- `WorkerRecord` is padded unconditionally: two threads write `wake` every
  batch. The bench is a non-regression gate, not the decision.
- Lane priority is a platform helper (`src/platform/`; app imports it, game
  never does), not SDL's call. Defaults: Linux nice 10, Windows
  `BELOW_NORMAL`, Darwin QoS `UTILITY`. `SCHED_IDLE` and Windows background
  mode are rejected (unbounded due-step waits; lowered I/O hurts saves). The
  lane calls it once at thread entry after 64A's FP assertion; failure warns
  once and is never fatal; the result is diagnostics only.
- Pool rule: `cpu_count − 1` whatever the lane does; a rule that follows
  measured interference would make worker count a function of timing
  (`.claude/rules/simulation.md` § Determinism).
- VoidLight: keep its `hardware_concurrency − 1` pool; do not port its
  user-space task priority queues, which cannot stop a long task holding a
  core.

### Checklist

- [ ] Shared quantum, padding helper, and layout gate in `thread_system.zig`;
      every padded slot site imports them and gates its types; private copies
      deleted.
- [ ] `idiom-lint` rule rejecting a private quantum or helper outside the
      owner.
- [ ] `WorkerRecord` padded to exactly one line, comptime-asserted, with a
      test that records sit one line apart and a batch still covers every
      item.
- [ ] `src/platform/thread_priority.zig` lowering the calling thread per OS;
      a readback test shows other threads unchanged (skips on sandboxed
      builders).
- [ ] Lane wiring: config to keep inherited priority, the call at lane entry,
      the result in lane stats, one log line.
- [ ] `resolveWorkerThreadCount` documents the fixed rule; `Engine.init`
      passes the threading config unmodified.
- [ ] `SimulationEvents` per-range stats padded, with a multi-worker parity
      test.
- [ ] `RangeOutputStream` per-range cursors padded, with a multi-worker
      parity test and the reserve-then-write `FailingAllocator` proof.
- [ ] Bench `background-lane-inherit` beside 51's `background-lane`; both
      report the lane's priority result.
- [ ] Docs: `docs/architecture.md` Thread System (quantum owner, worker
      padding, pool rule) and Background Lane (priority per OS);
      `docs/development-workflow.md` bench group.
- [ ] Add the thread-shared record rule (owner constant, layout gate, lint) to
      `.claude/rules/threading.md` when this lands.

### Acceptance checks

- [ ] `zig build check` passes with gates at every site; the quantum is
      declared only in `src/app/thread_system.zig` (grep).
- [ ] `zig build test` and `zig build test -Dsanitize-thread=true` pass with
      zero reports; priority tests pass on Linux, Windows, and macOS (52C
      runners once landed, else the local OS, recorded).
- [ ] `thread-dispatch` and `movement` (small range) show no regression
      beyond run-to-run spread in ReleaseFast.
- [ ] Priority gate in ReleaseFast: the lowered `background-lane` mean is
      within 10% of `movement` at the same items. A failing OS steps down a
      fixed, terminating priority ladder; the last rung closes the gate as a
      recorded deviation. The pool rule never changes.
- [ ] TSan bench runs of `thread-dispatch` and `background-lane` are clean.
- [ ] `zig build verify` passes.
