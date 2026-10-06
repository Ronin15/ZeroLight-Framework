## Slice 51: Background Job Lane With Deterministic Step Handoff

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 64A](slice-64a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **49**: the replay format,
`SimulationChecksum`, `GameDemoState.replaySession`/`simulationChecksum`, and
the `onPause`/`onResume` resync semantics. Depends on **50**: the foreign-thread
rule, self-naming, and `-Dsanitize-thread`. **64A** lands first in the merged
order (the lane thread calls its FP-environment assertion). Later consumers:
**46** (save write, load, slot scan; app-layer, through `isDone`), wired in its
own slice; **65B** (deferred nav rebuild) and **65C** (streaming worldgen).

Goal: a low-priority background lane, separate from fork-join `parallelFor`. It
runs coarse jobs off the main thread and hands each result back on a **fixed
simulation step chosen at submit time**. The simulation outcome never depends on
how fast a job ran. The first production consumer is live replay capture: Slice
49's chunked format streamed to disk.

Consumer decision:
- **Wired here: live replay capture.** It exists as soon as 49 lands. Its input
  (a sealed chunk) is naturally immutable and its output (file bytes) is owned.
  It exercises the full production path end to end: an Engine-owned lane,
  `UpdateContext` access, due-step completion, steal-or-wait, deterministic
  refusal, and state-deinit drain. The capture test proves it by verifying the
  captured file.
- **Later: save/load (46)** is an app-layer consumer. No step-keyed,
  simulation-affecting consumer is scheduled here. Slice 65B (deferred nav
  rebuild, the first step-keyed simulation consumer) and Slice 65C (streaming
  worldgen) are the planned heavy consumers.
- **Worldgen (58) is not a step-keyed consumer.** 58 generates at load time
  only, with `parallelForWithOptions` on the main thread in `LoadingState`. A
  lane thread calling `parallelFor` panics (Slice 50), so if 58 ever moves
  generation off the main thread (to keep a loading animation responsive), the
  lane job calls a serial generator path and hands back a cold `GeneratedWorld`
  value observed with `isDone`, not at `submit + k`. Slice 65C owns streaming
  worldgen on the lane.
- **Slice 65B: deferred nav rebuild.** Nav large patch and full relabel move
  to the lane in Slice 65B (front/back double buffer, fence, swap at
  `submit + 30`).

### Current foundation (do not rebuild)

- Archive Slice 7 says: "Long-lived async work such as asset streaming or file
  IO should use a separate service later instead of sharing this frame-bounded
  barrier path." This slice is that service.
- `ThreadSystem` is fork-join only. Its `std.Thread.spawn` (`thread_system.zig:747`)
  is the only thread spawn in `src/`.
- `Engine` creates the pool at `engine.zig:130`. Its deinit order is
  transitions → states → `thread_system` (`:175-181`), with the comment "Tear
  states ... down before the thread system so a state that drains or awaits
  worker work in its deinit still has a live pool".
- `UpdateContext` (`state.zig:62-73`) is how app services reach states.
  `GameDemoState.deinit` (`game_demo_state.zig:494-503`) has no context.
- `GameDemoState.update` (`:512-564`) runs its phases in a fixed order:
  `beginStep` → `main_thread_inputs` → `pipeline.update` → particles and camera
  → `merge_outputs` (structural commit and post-commit reactions) →
  `finished`.
- `assets.validateRelativePath` (`assets/assets.zig:77`) is the
  traversal-safe relative-path validator.
- `LoadingState.loadGameDemo(context)` (`loading_state.zig:186`) is where the
  gameplay state is built with access to `UpdateContext`.
- From Slice 49: the chunked replay format, `ReplayInputFrame`,
  `replay_max_frames_per_chunk = 4096`,
  `replay_checkpoint_interval_steps = 60`, `decode`, `verify`, and the
  determinism stepper adapter.
- From Slice 50: participant roles. The lane thread is a foreign thread, so
  `parallelFor` from a background job panics. Also self-naming and TSan.

### Architecture notes

**Placement**

- `src/app/background_lane.zig` (new): `BackgroundLane`. App-owned thread plus
  job slots. It knows nothing about simulation steps.
- `src/game/background_handoff.zig` (new): the step-keyed helper. Gameplay owns
  the step clock.
- `src/game/replay_capture.zig` (new): the `ReplayCapture` consumer, owned by
  `GameDemoState`.
- `Engine` owns `background_lane: BackgroundLane`, created right after
  `ThreadSystem`. Deinit order becomes transitions → states → Engine-owned
  app-layer tickets completed (Slice 46's save/load tickets) →
  `background_lane` → `replay_capture_dir` close → `thread_system` → the
  existing rest.
- **Moved-value safety (heap-allocated shared state).** `Engine.init` returns
  `!Engine` by value (`engine.zig:67`), and `main.zig` copies it, so nothing
  the lane thread touches may live inline in `BackgroundLane`. This follows
  `ThreadSystem`, which heap-allocates `shared: *Shared`
  (`thread_system.zig:712`, `:718-720`) so workers never hold `*ThreadSystem`
  (and `docs/architecture.md` forbids Engine-owned services from pointing at
  sibling fields):
  - `BackgroundLane` is a small movable handle:
    `{ allocator, shared: *LaneShared, thread: ?std.Thread, owner_thread_id }`.
  - `LaneShared` holds `io`, the slots, the `std.Io.Mutex`, `done_cond`, the
    `work` semaphore, `accepting_work`, the `sequence` counter, and the stats.
    `init` creates it with `allocator.create` and registers
    `errdefer allocator.destroy(shared)` before spawning the thread.
  - The lane thread receives only `*LaneShared`.
  - `deinit` stops accepting work, posts `work`, joins the thread, and then
    destroys `shared`.
- `UpdateContext` additions:
  - `background_lane: ?*BackgroundLane = null`. It is optional so existing tests
    that build an `UpdateContext` compile unchanged; `Engine.update` always
    passes its lane.
  - `replay_capture: ?ReplayCaptureTarget = null`, where `ReplayCaptureTarget`
    is defined in `state.zig` as
    `struct { io: std.Io, dir: std.Io.Dir, chunk_frames: u32 }`.
- No new `StageId`. Handoff happens at the gameplay-state boundary in the
  main-thread input phase, like input capture.

**Thread policy decision: one dedicated lane thread, not taken from the pool**

- **Jobs never run on pool workers.** `parallelFor` uses every pool worker plus
  the main thread for each batch, and worker N always runs range N-1 itself
  (`thread_system.zig:931-934`). A long job sitting on a pool worker would hold
  that reserved range, and the whole batch would stall each step until the job
  finished.
- **The lane thread is not subtracted from the pool**, which stays at
  `cpu_count - 1`. The lane is parked on a semaphore nearly all the time.
  Permanently removing a fork-join participant would cost every step to serve a
  rarely busy lane. While a job runs, the machine is oversubscribed by one
  thread. The `background-lane` bench measures fork-join interference; Slice
  65A's fixed pool rule (`cpu_count − 1`, reserve-a-core decided against)
  settles the policy.
- **No OS priority lowering in this slice.** Zig std has no portable
  thread-priority API; Slice 65A adds the per-OS platform helper
  (`lowerCurrentThreadPriority`).
- **Config**: `AppConfig.background_lane: BackgroundLaneConfig = .{}` in
  `src/config.zig`, with
  `BackgroundLaneConfig = struct { thread_enabled: bool = true, stack_size: usize = std.Thread.SpawnConfig.default_stack_size }`.
  The thread is forced off when `builtin.single_threaded`. With no thread, every
  job runs inline on the main thread at its due step. Results are identical; this
  is the serial fallback for tests and single-thread targets.
- **The lane thread** names itself `"zl-bg-lane"` on its first wake, the same
  mechanism as Slice 50. It never receives a `ThreadSystem`.

**Job representation and slots**

```zig
pub const background_lane_slot_capacity: usize = 32;
pub const BackgroundJobFn = *const fn (context: *anyopaque) void;
pub const BackgroundJob = struct { run: BackgroundJobFn, context: *anyopaque };
pub const BackgroundTicket = struct { slot: u8, generation: u32 };
pub const BackgroundSubmitError = error{ BackgroundLaneFull, BackgroundLaneShuttingDown };
pub const BackgroundTicketError = error{StaleBackgroundTicket};
pub const BackgroundCancelResult = enum { cancelled, completed };
pub const BackgroundLaneStats = struct {
    submitted: u64 = 0, completed_on_lane: u64 = 0, completed_inline: u64 = 0,
    waited_for_lane: u64 = 0, cancelled: u64 = 0, refused_full: u64 = 0, dropped_on_shutdown: u64 = 0,
};
const LaneShared = struct { // heap-allocated in init; the only state the lane thread sees
    io: std.Io,
    mutex: std.Io.Mutex,
    done_cond: std.Io.Condition,
    work: std.Io.Semaphore,
    accepting_work: bool,
    sequence: u64,
    slots: [background_lane_slot_capacity]Slot,
    stats: BackgroundLaneStats,
};
pub const BackgroundLane = struct {
    allocator: std.mem.Allocator,
    shared: *LaneShared,
    thread: ?std.Thread,
    owner_thread_id: std.Thread.Id,
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: BackgroundLaneConfig) !BackgroundLane;
    pub fn deinit(self: *BackgroundLane) void;
    pub fn submit(self: *BackgroundLane, job: BackgroundJob) BackgroundSubmitError!BackgroundTicket;
    pub fn complete(self: *BackgroundLane, ticket: BackgroundTicket) BackgroundTicketError!void;
    pub fn cancel(self: *BackgroundLane, ticket: BackgroundTicket) BackgroundTicketError!BackgroundCancelResult;
    pub fn isDone(self: *const BackgroundLane, ticket: BackgroundTicket) BackgroundTicketError!bool; // app-layer only
    pub fn stats(self: *const BackgroundLane) BackgroundLaneStats;
};
```

- **No allocation per submit.** A job is a function pointer plus a context.
  `LaneShared` holds a fixed `slots: [background_lane_slot_capacity]Slot`. Each
  slot is about 40 B (`job`, `state`, `generation: u32`, `sequence: u64`),
  roughly 1.3 KB in total. The only allocation is `LaneShared` itself, at
  `init`.
- **Why `background_lane_slot_capacity = 32`**:
  - One lane thread executes jobs serially. Thirty-two or more outstanding jobs
    means work arrives faster than it drains, and due jobs are already being
    completed inline, so more slots buy nothing.
  - Occupancy fits one `u32` mask, and the free-slot pick is `@ctz`, lowest
    index first.
- **Slot state machine.** Every transition happens under one `std.Io.Mutex`.
  Jobs run outside it.
  - `free → queued → (running_lane | running_main) → done → free`, plus
    `queued → cancelled → free`.
  - `generation` is bumped on free. Tickets carry it, so stale tickets are
    detected.
  - `sequence` is a monotonic submit counter. The lane picks the lowest-sequence
    `queued` slot, so execution is FIFO.
- **Lane thread loop** (over `*LaneShared` only):
  1. Wait on the `work` semaphore.
  2. Lock. Check the shutdown flag. Pick the oldest `queued` slot; if none
     exists, unlock and go back to step 1. Never assert that one exists: a
     main-thread steal (`complete` on a `queued` slot) or a `cancel` leaves an
     unconsumed `work` post, so empty wakes are normal. Otherwise mark the slot
     `running_lane` and unlock.
  3. Run `job.run(job.context)`.
  4. Lock. Mark the slot `done`, broadcast `done_cond`, and unlock.
- **Why a mutex, not lock-free.** Jobs are coarse (tens of µs and up), and there
  are at most a few submissions per second. A mutex over a 32-slot scan is
  simpler, obviously correct under TSan, and never on a per-entity path.
- **Only the main thread frees slots**, in `complete` or `cancel`. Lane
  completion never frees one. Slot occupancy, `BackgroundLaneFull` refusal, and
  ticket validity are therefore pure functions of the submit/complete/cancel
  call sequence, which is itself deterministic.
- **`submit`, `complete`, `cancel`, and `isDone` are owner-thread-only.**
  `init` stores `std.Thread.getCurrentId()`, and a `std.debug.assert` checks
  it.
- **`complete(ticket)`** acts on the slot's state, then frees the slot and
  returns once the job's outputs are visible:
  - `queued`: claim it as `running_main` and run it inline on the main thread
    (steal), marking it `done`;
  - `running_lane`: wait on `done_cond` until it is `done`;
  - `done`: nothing more to do.

  The mutex acquire happens after the job's release, so the outputs are
  visible on return.
- **`cancel(ticket)`**:
  - `queued` becomes `cancelled`, is freed, and never runs.
  - `running`: wait for it, then free it and return `.completed`.
  - `done`: free it and return `.completed`.
- **`isDone(ticket)`** locks, validates the ticket, and returns `true` when
  `complete(ticket)` would not wait on the lane thread: the slot is `done`, or
  the lane has no thread (where `complete` runs the job inline). It never runs
  a job and never frees a slot. A stale ticket returns
  `StaleBackgroundTicket`.
- **Polling rules (the contract other slices reference).**
  - **Simulation consumers never poll.** They observe a job only through
    `complete` at its due step via `background_handoff`, which is what makes
    outcomes timing-independent.
  - `isDone` exists only for **app-layer** consumers whose result never enters
    a running simulation: Slice 46 save-write status, load staging in
    `LoadingState`, slot scan, and any cold load-time value handoff (for
    example off-main-thread worldgen).
  - Review rejects `isDone` in `src/game/simulation*`, pipeline, or controller
    code, and in any per-step path of a gameplay state.
  - `stats()` is diagnostics only, for the perf log, and is documented as "must
    not feed simulation".

**Deterministic step handoff (`src/game/background_handoff.zig`)**

```zig
pub const min_background_handoff_latency_steps: u32 = 1;
pub const max_background_handoff_latency_steps: u32 = 120;
pub const PendingBackgroundJob = struct { ticket: BackgroundTicket, due_step: StepIndex };
pub fn submitWithHandoff(lane: *BackgroundLane, job: BackgroundJob, submit_step: StepIndex, latency_steps: u32)
    (BackgroundSubmitError || error{InvalidHandoffLatency})!PendingBackgroundJob;
pub fn isDue(pending: PendingBackgroundJob, executing_step: StepIndex) bool; // executing_step >= due_step
```

- **Contract.**
  - A consumer submits from a deterministic simulation point at step `s`, with
    a fixed per-consumer latency `k`. `k` is a named constant, never derived
    from measured time or world size.
  - The consumer completes and applies the result at the start of step `s + k`,
    in the main-thread input phase before `pipeline.update`. Due jobs are
    handled in ascending (`due_step`, submit order).
  - If the job is unfinished at that point, `complete` steals it (not started)
    or waits for it (running). The main thread blocks rather than skipping or
    deferring. The result applied, and the step it lands on, are identical
    whether the lane is fast, slow, or absent.
- **Bounds on `k`.** At least 1: a same-step result is just a synchronous call.
  At most 120 steps (2 s): longer work should be split into pieces, and the bound
  also limits how long a slot stays pinned.
- **Job inputs and outputs.**
  - A job reads only data it owns: an immutable snapshot copied at submit. It
    writes only its own output buffers.
  - The main thread does not touch a job's context between submit and complete.
  - Jobs never receive a `ThreadSystem`, renderer, SDL handle, or
    `DataSystem`/`WorldSystem` pointer. A job never calls `parallelFor`; the
    lane thread is a foreign thread to every `ThreadSystem` and panics there
    (Slice 50). Data-parallel work on the lane uses a serial code path.
  - **Frozen borrow (Slice 65B amendment).** A job may also read a structure
    it does not own when its consumer freezes it from submit until
    `complete`/`cancel` returns; see Slice 65B's "Slice 51 contract
    amendment" for the full clause.
- **Refusal.** `BackgroundLaneFull` is deterministic. The prescribed fallback is
  to run the job inline immediately and still apply it at `s + k`, so only the
  cost moves.
- **Pause.** Due steps do not advance while paused. Jobs may finish in the
  meantime, but nothing is applied until the step runs. App-layer work that
  must progress while paused (Slice 46 saves from the pause menu) therefore
  uses `submit` / `isDone` / `complete` directly, never `background_handoff`.
- **Lifetime.**
  - Every consumer completes or cancels its tickets in its own `deinit`. States
    deinit before the lane. Engine-owned app-layer tickets (Slice 46 save/load)
    are completed in `Engine.deinit` **before** `background_lane.deinit`, so
    quitting during a save finishes the atomic write instead of dropping it.
  - Lane `deinit` with outstanding slots is an owner bug. It stops accepting
    work, waits for the running job, and never runs queued jobs, because their
    contexts may already be freed. It counts them in `dropped_on_shutdown`,
    emits one `log.warn`, and joins the thread.

**First consumer: live replay capture (`src/game/replay_capture.zig`)**

- **Config and plumbing.**
  - `AppConfig.replay_capture_directory: ?[]const u8 = null`, where null means
    disabled. The build option `-Dreplay-capture-dir=<relative dir>` feeds it
    via `main.zig`.
  - `Engine.validateConfig` runs `assets.validateRelativePath` on it.
  - On a cold path during `Engine.init`, Engine creates and opens the directory
    relative to the process working directory (the same convention as
    `asset_root`). It holds the handle as `replay_capture_dir: ?std.Io.Dir` and
    closes it after the states deinit. A failure logs `warn` and disables
    capture; it never fails startup.
  - `Engine.update` passes `.replay_capture = .{ .io, .dir, .chunk_frames =
    replay_capture_default_chunk_frames }`.
  - `LoadingState.loadGameDemo` forwards `context.background_lane` and
    `context.replay_capture` to `initProceduralWithRuntimeAssets`.
  - `initWithWorld` gains `capture: ?ReplayCaptureInit` (lane pointer plus
    target). When both are present, `GameDemoState` owns
    `replay_capture: ?ReplayCapture`. It stores the lane pointer for `deinit`,
    which is safe because the lane outlives every state.
- **Constants, with values and reasons**:
  - `replay_capture_default_chunk_frames: u32 = 4096`, equal to
    `replay_max_frames_per_chunk`: one flush about every 68 s, 32 KiB of frames
    each.
  - `replay_capture_min_chunk_frames: u32 = 64`. Chunk size is runtime
    configurable: smaller chunks mean more flushes but less data lost on a
    crash. It is validated to `64..=4096`.
  - `replay_capture_flush_latency_steps: u32 = 30`: 0.5 s for a sequential write
    of at most 34 KiB, generous for SSD or HDD.
  - Comptime assert: `replay_capture_flush_latency_steps <
    replay_capture_min_chunk_frames`. A chunk takes at least 64 steps to fill,
    so at most one flush is ever in flight. The other chunk is always retired
    before reuse, and file write order is preserved.
- **Buffers.** All are reserved at init, and capture is allocation-free per step
  afterwards. There are two `ReplayCaptureChunk`s, each holding:
  - `frames: [replay_max_frames_per_chunk]ReplayInputFrame`, using the first
    `chunk_frames` entries;
  - `checkpoints: [replay_max_checkpoints_per_chunk]ReplayCheckpoint`;
  - `bytes: [replay_chunk_max_bytes]u8`, the comptime maximum encoded chunk
    size;
  - `flush: ReplayFlushJob`, defined as
    `struct { file: std.Io.File, io: std.Io, bytes: []const u8, err: ?anyerror }`.
    The job writes `err` **only on failure** and never clears it; the main
    thread resets it to `null` when it recycles the chunk after `serviceDue`.

  They are allocated once on the heap, about 2 × 66 KiB.
- **Length stop.** Capture stops recording at `replay_max_total_frames` (Slice
  49's decode bound), so a long session never produces a file `decode` rejects
  with `ReplayTooLarge`. On the step that reaches the bound, capture seals the
  active chunk, writes it and the end record, closes the file, logs one
  `logging.game.info`, and disables itself. The simulation is unaffected. The
  rule is the pure `shouldStopCapture(total_frames, limit) bool`, called with
  `replay_max_total_frames` in production and unit-tested directly with small
  limits (no production test hook).
- **File.**
  - Opened at init on the main thread (cold) as
    `replay-{seed_root:0>16x}-{unix_seconds}.zlrp`, with exclusive create.
  - The wall clock appears only in the file name, never in the simulation.
  - The header (48 bytes at v1, 80 from Slice 64C), written by `replay.zig`'s
    shared header encoder, is written synchronously, using
    `GameDemoState.replaySession()` and `simulationChecksum()`.
  - If the open fails, log `warn` and run without capture.
  - If `replaySession()` cannot cast the `StepIndex` step to the replay v1
    `u32` range (Slice 49 refusal), log one `logging.game.warn`; capture
    stays disabled for the session.
- **Per-step flow in `GameDemoState.update`, with capture enabled**:
  1. Right after `beginStep`, compute
     `executing = scope.currentStep() + 1` and call
     `capture.serviceDue(executing)`. It completes a due flush (steal or wait)
     and recycles its chunk. A stored `err` becomes one `logging.game.warn` and
     disables capture; the simulation is unaffected.
  2. Build `ReplayInputFrame.fromInputState(context.input,
     self.resync_pending)`, then clear `resync_pending`. That is a new
     `GameDemoState` field, set by `onPause` and `onResume`.
  3. The existing update runs unchanged.
  4. After `phase = .finished`:
     - call `capture.recordStep(frame)`;
     - if `checkpointDue(step)`, call
       `capture.recordCheckpoint(step, self.simulationChecksum())`;
     - if `shouldStopCapture` holds, run the length stop above and skip the
       rest;
     - if the active chunk is full, encode it into its `bytes` on the main
       thread (at most 34 KiB) and call `submitWithHandoff(lane, flush_job,
       step, replay_capture_flush_latency_steps)`;
     - on `BackgroundLaneFull`, write inline immediately (the deterministic
       refusal path);
     - switch to the other chunk.
  5. In `deinit`, `capture.finish()` completes any pending flush, encodes and
     writes the partial chunk and the end record synchronously (state teardown
     is a cold boundary), and closes the file.
- Checkpoint cost is Slice 49's `simulation-checksum` number, once per 60
  steps, and only when capture is opted in.

**Diagnostics**

- Lane: one `log.debug` each at init and deinit (thread on or off, capacity);
  one `log.warn` for shutdown drops.
- Perf metrics in `runtime_perf_log`, comptime-gated: `background_jobs_submitted`,
  `background_jobs_completed_inline`, `background_jobs_waited`,
  `background_jobs_refused`. `GameDemoState` records them from `lane.stats()`
  deltas.
- Capture: `logging.game.info` with the file name at start; `warn` on any
  failure.

### Checklist

- [ ] `src/app/background_lane.zig`: heap-allocated `LaneShared`, slots, state
  machine, lane thread, and the stats, `complete`, `cancel`, `isDone`, and
  `deinit` behavior described above. Tests use test-local job contexts; a
  "gate" job spins on an atomic `release` flag:
  - `test "lane survives being returned by value"`: a helper inits a threaded
    lane and returns it by value; the caller then submits and completes a job
    and deinits. (Guards the moved-`Engine` case.)
  - `test "isDone reports completion without freeing the slot"`: on a threaded
    lane, `isDone` is `false` while a gate job holds the lane, `true` after
    release, and the slot stays occupied until `complete`. On a lane without a
    thread, `isDone` is `true` immediately and the job runs only at
    `complete`. A stale ticket returns `StaleBackgroundTicket`.
  - `test "lane refuses the 33rd outstanding job even after every job
    finished"`: on a threaded lane, submit 32 trivial jobs and spin until
    `stats().completed_on_lane == 32`. The 33rd submit returns
    `BackgroundLaneFull`. After one `complete`, a submit succeeds.
  - `test "cancel prevents a queued job from running"`: a gate job holds the
    lane. Cancel the queued job, release the gate, then submit and complete one
    more trivial job (the lane absorbs the empty wake the cancel left), and
    deinit. The cancelled job's run counter is 0.
  - `test "main-thread steal leaves the lane healthy"`: a gate job holds the
    lane; `complete` steals a queued job (`completed_inline == 1`). Release the
    gate, then submit and complete another job on the lane. The empty wake left
    by the steal is absorbed and nothing asserts.
  - `test "lane deinit never runs jobs whose owner leaked them"`: one running
    gate job plus one leaked queued job. Release the gate and deinit. The queued
    job's run counter is 0 and `dropped_on_shutdown == 1`.
  - `test "completing a running job waits for its outputs"`: a gate job is
    started; release it and `complete`. The output is visible.
  - `test "stale tickets are rejected"`: completing twice fails, and so does
    completing after the slot is reused.
  - `test "lane without a thread runs jobs inline at completion"`.
  - `test "lane submit, complete, and cancel are allocation-free after init"`:
    a `FailingAllocator` proof.
  - `test "lane thread names itself zl-bg-lane"`: Linux only, skipped
    elsewhere.
- [ ] `src/game/background_handoff.zig`. Tests:
  - `test "handoff rejects latency outside 1..=120"`.
  - `test "isDue holds only at or after the due step"`.
  - `test "results apply on the due step regardless of lane speed"`. Run the
    same scripted submit/apply sequence over 20 steps on three lanes:
    - no thread;
    - a threaded fast lane, where the test spins on `completed_on_lane` so jobs
      finish early;
    - a threaded slow lane, where a gate job submitted first holds the lane, so
      the measured job is still queued at its due step and gets stolen.

    The applied traces `[(due_step, output)]` must be equal across all three.
    The slow lane reports `completed_inline == 1`, and the fast lane never
    applies before the due step.
- [ ] Engine wiring:
  - `AppConfig.background_lane` and `AppConfig.replay_capture_directory`;
  - the `-Dreplay-capture-dir` build option;
  - `validateConfig` path check;
  - Engine-owned lane and capture directory, in the new deinit order;
  - `UpdateContext.background_lane` and `.replay_capture`;
  - `LoadingState` forwarding.
  - Compile coverage: `zig build check`.
- [ ] `src/game/replay_capture.zig` plus `GameDemoState` wiring
  (`resync_pending` — renamed `pause_boundary_pending` by Slice 64A —,
  `serviceDue`, record/checkpoint/seal, `finish` in
  `deinit`). Tests in `game_demo_state.zig`, reusing Slice 49's
  `initDemoForDeterminismTest` and stepper adapter:
  - `test "live replay capture streams through the background lane and
    verifies"`. Use `std.testing.tmpDir`, a threaded lane, and
    `chunk_frames = 64`. Run 300 steps of the Slice 49 script with a
    pause/resume at step 150, then deinit. Decode the file and verify it on a
    fresh demo: expect `.matched{ .steps = 300 }`. Lane stats show at least 4
    submitted flushes.
  - `test "replay capture writes inline when the lane is full"`. Fill the lane
    with 32 test-owned gate jobs, force a seal, and confirm the chunk was
    written inline (`refused_full == 1`). Then release every gate flag first,
    and only then cancel the gates (`cancel` on a running gate waits for it,
    so cancelling an unreleased gate would deadlock). The file still decodes
    and verifies.
  - `test "replay capture is allocation-free per step after init"`: a
    `FailingAllocator` proof over `serviceDue`, `recordStep`,
    `recordCheckpoint`, and seal+submit.
  - `test "replay capture write failure disables capture without changing the
    simulation"`. On a threaded lane, after the seal, spin on
    `stats().completed_on_lane` until the flush job has finished (so its
    failure-only write of `err` cannot race the injection), then set the
    pending chunk's `flush.err = error.NoSpaceLeft`, then step to the due step.
    Capture becomes disabled after `serviceDue`, one warn is logged, and the
    120-step checksum trace equals a run without capture.
  - `test "capture stop rule"`: `shouldStopCapture` is false below the limit
    and true at it, for small limits.
- [ ] (added by Slice 64) The capture header is written by `replay.zig`'s shared header
      encoder from `GameDemoState.replaySession()`, so 64C's header
      extension needs no capture change. Text edit in 51: "The 48-byte
      header is written synchronously" → "The header (48 bytes at v1, 80
      from Slice 64C), written by `replay.zig`'s shared header encoder, is
      written synchronously". `resync_pending` is renamed
      `pause_boundary_pending` (64A). The capture never sets flags bits 1–7
      for a save (a save is invisible to the session; 64B B5); the only
      later flag is Slice 69F's bit1 `normalized_before_step`, written from
      its region-swap `normalize_pending` latch.
- [ ] (added by Slice 64) The background-lane thread entry calls
      `fp_env.assertDefault("background lane")` (64A A4 call site 3) before
      its first `work` wait, beside Slice 65A's `lowerCurrentThreadPriority`
      when that has landed. Test: the existing lane round-trip test passes
      under `zig build test -Doptimize=ReleaseSafe` (assertion live, no
      trip).
- [ ] (65B) Job-input rule: add the frozen-borrow clause (Slice 65B "Slice 51 contract amendment") to `docs/architecture.md` Background Lane and the `background_handoff.zig` doc comment.
- [ ] Bench `src/benchmarks/background_lane.zig`, group `background-lane`,
  registered in `runner.zig`:
  - Each measured iteration runs the movement-shaped fork-join batch
    (`MovementSystem.update` over `items` bodies, `default_cases`) while the
    lane executes a CPU-bound job: a fixed N passes of Wyhash over a 1 MiB
    owned buffer, with N a named constant sized so the job stays running for
    the whole batch at the gate's item count.
  - Only `MovementSystem.update` is timed. The job is submitted before the
    timed region, and its `complete` wait runs after it, untimed, so the mean
    measures fork-join interference, not the job's length.
  - `--details` reports the lane job's own duration (and whether it outlasted
    the batch), so the fixture can be checked.
  - It also reports the lane round-trip cost (submit plus complete of an empty
    job) in ns.
- [ ] Docs:
  - `docs/architecture.md`: new "## Background Lane" after Thread System
    (ownership, heap-allocated `LaneShared`, thread policy, handoff contract,
    polling rules and app-layer `isDone`, job rules including no
    `parallelFor`, shutdown and Engine-owned tickets); the Cross-Cutting rule
    naming the lane as the owner for long-lived async work.
  - `docs/simulation-tiers-and-pipeline.md` Determinism Contract: the handoff
    rule.
  - `docs/development-workflow.md`: `-Dreplay-capture-dir`, where files land,
    and `background-lane` added to the Thread Sanitizer group list.

### Acceptance checks

- [ ] Every Checklist test passes under `zig build test`, and also under
  `zig build test -Dsanitize-thread=true` with zero reports.
- [ ] Outcome invariance: the three-lane handoff test passes, and the live
  capture round trip verifies `.matched`.
- [ ] `FailingAllocator` proofs pass for the lane and for capture per-step
  paths.
- [ ] The by-value lane test passes, and no field the lane thread touches lives
  inline in `BackgroundLane` (review check).
- [ ] No `isDone` call exists in `src/game/simulation*`, pipeline, controller,
  or per-step gameplay code (grep in the PR).
- [ ] Bench gate. Run, in one session:
  - `zig build -Doptimize=ReleaseFast bench -- --group background-lane --items
    50000 --case thread-adaptive-tuned-range`;
  - `zig build -Doptimize=ReleaseFast bench -- --group movement --items 50000
    --case thread-adaptive-tuned-range`.

  First confirm from `--details` that the lane job outlasted the timed batch;
  otherwise raise its fixed pass count and rerun. The `background-lane` mean
  (movement batch only, completion untimed) must be within 10% of the
  `movement` mean. Slice 65A's lowered-priority gate supersedes this
  comparison. Record both numbers and the lane job duration in Status.
- [ ] `zig build bench -Dsanitize-thread=true -- --profile quick --group
  background-lane` is clean.
- [ ] `zig build verify` passes. Docs updated as listed.

### VoidLight reference

- **Port**:
  - Keep long-running work separate from frame-bounded work: VoidLight's
    general task pool versus `WorkerBudget` batches becomes the ZeroLight lane
    versus `parallelFor`.
  - Commit worker results on the main thread and filter stale ones:
    `src/managers/PathfinderManager.cpp:214-252` (`commitCompletedPaths`)
    applies completions on the main thread and drops stale ones by request
    token (`:236-239`). ZeroLight's generation-checked tickets serve the same
    purpose.
- **Do not port**:
  - **Applying results whenever they finish.** `commitCompletedPaths` applies
    whatever completed by the current frame. `rebuildGrid`
    (`PathfinderManager.cpp:646`) publishes a new grid when its detached job
    finishes (`m_gridRebuildFutures`, `PathfinderManager.hpp:458`). Either way,
    the frame a result lands on depends on worker speed. ZeroLight applies at
    `submit_step + k` and blocks if the job is late.
  - **Unbounded, allocating queues.** `include/core/ThreadSystem.hpp:105-119`
    pushes a `std::function` plus a `std::string` into per-priority
    `std::deque`s ("deque handles capacity automatically").
    `DEFAULT_QUEUE_CAPACITY = 4096` (`:740`) is not a bound. ZeroLight uses 32
    fixed slots, a function pointer plus a context, and deterministic refusal.
  - **Five priority levels with timestamp ordering.** See `:37-43` and the
    `PrioritizedTask` enqueue time at `:46-69`. ZeroLight has one lane, FIFO by
    submit sequence; fork-join is its high-priority path.
  - **`std::future` results.** `enqueueWithResult` (`:577-590`) allocates per
    task, and readiness polling invites timing-dependent branching. ZeroLight
    gives simulation consumers no readiness query; only app-layer consumers,
    whose results never enter a running simulation, may call `isDone`.
  - **Shutdown that sleeps and cancels silently.** `clean()` (`:756-790`)
    sleeps 10 ms and 50 ms, and `enqueueTask` logs "Ignoring task after
    shutdown" (`:887-895`). In ZeroLight, owners complete or cancel their jobs in
    `deinit`. Lane `deinit` counts leaked jobs, warns, and never runs a job
    whose owner is gone.
  - **A singleton.** `ThreadSystem::Instance()` is a singleton; ZeroLight's lane
    is Engine-owned and passed through `UpdateContext`.
  - **Parallel manager init on futures.** `src/core/GameEngine.cpp:452-470` is
    not ported. ZeroLight's load-time world and nav builds already use
    `parallelFor`, and loading is not step-deterministic territory.

