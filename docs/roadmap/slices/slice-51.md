## Slice 51: Background Job Lane With Deterministic Step Handoff

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 64A](slice-64a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: a low-priority background lane, separate from fork-join `parallelFor`,
runs coarse jobs off the main thread and hands each result back on a fixed
simulation step chosen at submit, so no simulation outcome depends on how fast
a job ran. The first consumer is live replay capture (Slice 49's chunked
format streamed to disk); later consumers are 46 (save/load, app-layer), 65B
(deferred nav rebuild), and 65C (streaming worldgen).

### Current foundation

- `ThreadSystem` (`src/app/thread_system.zig`) is fork-join only; its worker
  spawn is the only thread spawn in `src/`. It heap-allocates the state its
  workers share, so a moved owner stays valid.
- `Engine.init` creates the pool; `Engine.deinit` tears down transitions,
  then states, then `thread_system`, so a state's teardown still has a live
  pool.
- `UpdateContext` (`src/app/state.zig`) carries app services to states and
  has no lane; `GameDemoState.deinit` takes no context.
- `GameDemoState.update` runs `beginStep` → `main_thread_inputs` →
  `pipeline.update` → particles and camera → `merge_outputs` (structural
  commit, post-commit reactions) → `finished`.
- `LoadingState.loadGameDemo` builds gameplay with `UpdateContext` in reach;
  `assets.validateRelativePath` is the traversal-safe path validator.
- Needed and not landed: 49's chunked replay format, verifier, and
  `simulationChecksum()`; 50's foreign-thread `parallelFor` panic, thread
  self-naming, and `-Dsanitize-thread`; 64A's FP-environment assertion.

### Architecture notes

- Placement: the lane lives in `src/app/` and knows nothing of simulation
  steps; the step-keyed handoff helper and the replay-capture consumer live in
  `src/game/`. Engine owns the lane and passes it through `UpdateContext`.
  Everything the lane thread touches is heap-allocated, so a moved `Engine`
  stays valid (`.claude/rules/engine-design.md` § Ownership boundaries).
- Thread policy (decided): one dedicated lane thread, not taken from the
  pool; jobs never run on pool workers, where a long job would stall every
  fork-join batch. 65A lowers the lane's OS priority and fixes the pool rule.
- Step handoff: a simulation consumer submits at step `s` with a fixed
  per-consumer latency `k` (a bounded named constant, never from measured time
  or world size) and applies the result at the start of `s + k` in the
  main-thread input phase, stealing a queued job or waiting on a running one.
  Result and step are identical with a fast, slow, full, or absent lane
  (`.claude/rules/simulation.md` § Determinism).
- Polling: simulation consumers observe a job only at its due step. A
  readiness query exists only for app-layer consumers whose result never
  enters a running simulation (46 save status, load staging, 65C at load).
- Job inputs: a job reads only data it owns (copied at submit) or a structure
  its consumer freezes from submit until complete or cancel (the frozen
  borrow 65B and 65C use); it writes only its own outputs and reaches no
  `ThreadSystem`, renderer, SDL handle, or live `DataSystem`/`WorldSystem`.
  Work on the lane is serial; work that scales with population, terrain
  change, or world size stays on the pool (`.claude/rules/threading.md`).
- No allocation per submit. A full lane never changes a result: the consumer
  runs the job inline and still applies it at `s + k`
  (`.claude/rules/budgets-capacities.md`).
- Pause: due steps do not advance while paused; app-layer work that must
  progress while paused uses the app-layer surface, never the step handoff.
- Lifetime: each consumer completes or cancels its jobs in its own teardown;
  states deinit before the lane; Engine-owned app-layer jobs (46) complete
  before the lane deinits, so quitting mid-save finishes the write; lane
  deinit never runs a job whose owner is gone and reports leaked jobs.
- Replay capture is opt-in (config plus a build option, path-validated),
  allocation-free per step after init, stops at 49's decode bound, and writes
  its header through 49's shared encoder (64C extends it). A write failure
  disables capture and never changes the simulation. No new `StageId`.
- VoidLight: port the long-running versus frame-bounded split and main-thread
  commit with stale-result filtering; do not port apply-when-finished,
  unbounded allocating queues, priority levels, futures, or a singleton.

### Checklist

- [ ] `BackgroundLane` (`src/app/`): heap-shared slot table and state
      machine, lane thread, submit / complete / cancel, app-layer readiness,
      stats, deinit; a thread-less mode runs jobs inline at completion.
- [ ] Step-keyed handoff helper (`src/game/`) with bounded latency.
- [ ] Engine wiring: lane config, capture-directory config and build option
      with path validation, the Engine-owned lane in the deinit order above,
      `UpdateContext` fields, `LoadingState` forwarding.
- [ ] Replay capture owned by `GameDemoState`: record, checkpoint, seal and
      submit per chunk, due-step service, finish on teardown, the
      pause-boundary flag (64A's name).
- [ ] The lane thread calls 64A's FP-environment assertion at entry (beside
      65A's priority call once landed).
- [ ] Tests: a lane returned by value works; readiness never frees a slot;
      a full lane refuses and frees on complete; cancel stops a queued job; a
      main-thread steal leaves the lane healthy; deinit never runs leaked
      jobs; stale tickets are rejected; thread-less lane; handoff results
      equal across no-thread, fast, and slow lanes; the live capture round
      trip verifies `.matched`; capture writes inline on a full lane; a write
      failure leaves the checksum trace unchanged; `FailingAllocator` proofs
      for lane operations and per-step capture.
- [ ] Bench `background-lane`: a fork-join movement batch timed while a
      CPU-bound lane job runs, plus the lane round-trip cost.
- [ ] Docs: `docs/architecture.md` Background Lane (ownership, thread policy,
      handoff, polling, job inputs with the frozen borrow, shutdown);
      `docs/simulation-tiers-and-pipeline.md` handoff rule;
      `docs/development-workflow.md` capture option and TSan group.
- [ ] Add the background-lane rule (polling, step handoff, job inputs with
      the frozen borrow, refusal fallback, pause, ticket lifetime) to
      `.claude/rules/threading.md` when this lands.

### Acceptance checks

- [ ] Every test passes under `zig build test` and
      `zig build test -Dsanitize-thread=true` with zero reports.
- [ ] Outcome invariance: the three-lane handoff test passes and the capture
      round trip verifies.
- [ ] No readiness query in simulation, pipeline, controller, or per-step
      gameplay code (grep).
- [ ] `background-lane` and `movement` numbers recorded in the landing
      commit; 65A's lowered-priority gate closes the interference question.
      `zig build bench -Dsanitize-thread=true -- --profile quick --group
      background-lane` is clean.
- [ ] `zig build verify` passes.
