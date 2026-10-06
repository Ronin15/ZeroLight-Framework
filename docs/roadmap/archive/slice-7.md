## Slice 7: Preallocated Thread System And Parallel Render Prep

Goal: add a deterministic, pre-spawned worker system that lets each engine
system use all active workers for CPU work, then finish before the next system
or render phase starts.

Current foundation:

- `Engine` owns app coordination and state-stack update/render flow.
- `main.zig` owns the outer loop and calls `Engine` phase methods; `Engine`
  delegates state callbacks through `StateStack` policy dispatch.
- `TimeLoop` already enforces fixed-step gameplay updates.
- Renderer command submission is currently serial and owns SDL_GPU command
  buffers, swapchain acquisition, vertex upload, and submit.
- Current sprite and rectangle drawing flows through `SpriteBatch`, with stable
  sprite IDs resolved by `RuntimeAssets` before draw submission.
- Zig 0.16 provides `std.Thread.spawn`, atomics, and `std.Io` blocking
  primitives; this checkout does not rely on a std thread-pool abstraction.

Architecture notes:

- This is a synchronous frame-batch system, not a general async job scheduler.
  It is for systems that need CPU work completed before the frame can continue.
- There is one active batch at a time. A batch exposes an atomic range queue:
  participants claim the next `ParallelRange` with an atomic cursor.
- Worker threads park when idle. Do not add spin-wait configuration unless
  measurement proves condition-variable wake latency is the bottleneck.
- `max_worker_threads` counts only pre-spawned worker threads. The
  main/render thread may also process ranges, so the default `cpu_count - 1`
  worker threads uses all normal CPU participants without oversubscription.
- Long-lived async work such as asset streaming or file IO should use a
  separate service later instead of sharing this frame-bounded barrier path.

Thread-system design:

- [x] Add `src/app/thread_system.zig` with `ThreadSystem`,
      `ThreadSystemConfig`, `WorkerId`, `ParallelRange`, `BatchStats`, and a
      deterministic `parallelFor` API.
- [x] Own `ThreadSystem` from `Engine`; initialize it after SDL/app config is
      known and deinitialize it before allocator teardown.
- [x] Pre-spawn up to `max_worker_threads` worker threads at init with
      `std.Thread.spawn`.
      Never create or destroy OS threads during gameplay frames.
- [x] Default worker thread count to one fewer than
      `std.Thread.getCpuCount()` when possible, reserving the main/render thread
      as an additional batch participant; allow config override for worker
      thread count, stack size, and items per claimed range
      (`items_per_range`).
- [x] Use preallocated worker records, one synchronous batch descriptor, and an
      atomic range cursor. No frame-batch submission may allocate after
      initialization.
- [x] Use atomics for hot range claiming and range stats; use `std.Io.Mutex` and
      `std.Io.Condition` only for batch publication, worker parking, completion,
      and shutdown paths where blocking is expected.
- [x] Let the main thread participate in submitted batches while waiting so it
      does useful work instead of only acting as a coordinator.
- [x] Dynamically scale active workers only at batch boundaries based on prior
      batch cost, item count, main-thread wait time, and worker utilization.
      Static item-count floors do not gate production worker participation;
      timing and structural range feasibility decide whether work stays inline.
- [x] Stop accepting work during shutdown, wake parked workers, join every
      pre-spawned thread, and assert that no frame batch is still outstanding.

Engine/system integration:

- [x] Add an update/render-prep context that exposes `thread_system` to states
      or future systems without moving timing policy out of `main.zig`.
- [x] Preserve the runtime flow where `main.zig` calls `Engine` phase methods
      and `Engine` invokes eligible state callbacks through `StateStack`.
- [x] Keep systems ordered: each system may use the whole worker set, but all
      of its jobs must complete before the next system starts.
- [x] Allow worker jobs to read immutable snapshots and write only disjoint
      output ranges.
- [x] Add explicit per-worker scratch slot indexing keyed by `WorkerId` before
      systems need temporary output buffers.
- [x] Keep `StateTransitions`, state-stack mutation, SDL events, SDL window
      calls, and renderer ownership on the main thread.
- [x] Record batch stats in a lightweight struct that debug overlay or logs can
      consume later without adding hot-path string formatting.

Parallel render-prep design:

- [x] Keep SDL_GPU command-buffer acquisition, swapchain acquisition, GPU
      upload, render-pass encoding, and submit on the main/render thread for
      the first implementation.
- [x] Split CPU render prep into explicit phases: producers own intentional
      transient ordering, then `SpriteBatch` consumes the ordered stream for
      texture validation, sprite-to-vertex expansion, and draw-group
      construction. The renderer does not keep compatibility fallback sorting
      that hides producer-order bugs.
- [x] Keep the render prep tuner and stats owned by `SpriteBatch`/`Renderer`
      instead of relying on the generic `ThreadSystem` fallback tuner.
- [x] Snapshot texture/resource metadata needed by workers before dispatch so
      worker jobs never observe renderer arrays while they are being mutated.
- [x] Merge worker outputs on the main thread in command-stream order, then
      upload the final vertex buffer and submit one GPU command buffer.
- [x] Preserve the inline path and let the adaptive tuner choose it for work
      that does not benefit from worker dispatch.
- [x] Add a non-interactive `render-prep` benchmark group that reports draw
      commands, valid sprites, skipped invalid resources, vertex count, draw
      groups, worker use, range size, and adaptive tuning state.
      Interpret `thread-fixed-*` rows as forced scheduler/range controls and
      `thread-adaptive-*` rows as the production-style measured scheduling
      signal; cheap sprite/rect prep should stay inline until the adaptive
      tuner proves worker participation wins.
- [x] Defer threaded SDL_GPU command buffers until profiling proves main-thread
      command encoding is the bottleneck. If added later, command buffers must
      be acquired, used, and submitted on the same worker thread; swapchain
      acquisition must remain on the window thread.

Acceptance checks:

- [x] `parallelFor` covers every item exactly once and never writes outside the
      requested range.
- [x] Batch execution performs no allocations after init/reserve; enforce this
      with a failing allocator in tests.
- [x] System barriers are deterministic: later systems always see completed
      output from earlier systems.
- [x] Shutdown wakes and joins parked workers without leaking or deadlocking.
- [x] Worker idle policy parks on a condition variable; no spin loop or unused
      spin configuration remains in the config.
- [x] Serial and parallel render prep produce identical vertex order, draw
      group order, render ordering, and invalid-texture skipping for the same
      command input.
- [x] Existing visible rendering remains swapchain/vsync paced, hidden/minimized
      fallback pacing remains unchanged, and visible no-swapchain results block
      gameplay before the next update.
- [x] `zig build test`, `zig build check`, and `zig build verify` pass before
      the slice is considered complete.

Slice 7 is complete for the current sprite/rect renderer path. It has a
pre-spawned app-owned `ThreadSystem`, explicit update/render contexts,
synchronous `parallelFor`, adaptive per-batch worker-thread participation,
per-worker scratch slot indexing, and render-owned parallel CPU sprite prep.
State-owned render prep owns draw-record ordering by `RenderOrder`, including
world z, stack-aware UI depth, effects, and debug records. `SpriteBatch`
consumes only an already ordered stream, snapshots texture metadata on the main
thread, expands prepared sprites into disjoint vertex spans through the thread
system, builds draw groups deterministically on the main thread, and leaves
SDL_GPU command-buffer work on the render thread. Future tile rendering, UI widgets,
material registries, lighting/fire effects, or threaded GPU command buffers
remain separate slices that must preserve this queue-first ordering contract
unless they replace it with an explicitly measured render-owned ordering phase.

