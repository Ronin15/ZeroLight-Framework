## Slice 65C: Streaming Worldgen On The Background Lane

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 53B](slice-53b.md), [Slice 51](slice-51.md); in-play path after [Slice 74](slice-74.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: generating a world never stalls a step or a frame. Generation runs on
the lane in chunk batches and completed chunks commit on the main thread
under a fixed per-step budget, so a bigger world takes more steps, never a
longer step. At load, `LoadingState` shows progress and the window stays
responsive; in play, a world 74 creates is generated the same way and adopted
on a step that is a pure function of the step sequence. The world is
bit-identical to 58's threaded and serial paths whatever the lane timing;
with no lane thread, 58's threaded path runs unchanged.

### Current foundation

- `LoadingState` (`src/game/loading_state.zig`) latches one drawn frame,
  then `loadGameDemo` builds the whole `GameDemoState` (world, spawns,
  pipeline, nav) synchronously inside one `update`; the screen is static text
  and no events pump during the build.
- Slice 58's generator (not landed) plans the world and raises its refusals
  on the main thread, runs one pure job per `(level, chunk)` writing disjoint
  outputs through `parallelForWithOptions`, commits in canonical order, then
  selects spawns and validates. Jobs read only immutable inputs.
- `WorldSystem.addSparseTile` touches only sparse storage and the
  render-index dirty flag.
- A lane job reaching any `ThreadSystem` panics (50); 51's readiness query
  is allowed for load staging.
- No world is created in play today (74).

### Architecture notes

- Generation stays in 58's generator: its entry point splits into plan,
  per-job generate, per-job commit, and finish, and both load paths share one
  adoption step.
- Each chunk job is a pure function of its index and commit order is
  ascending job index, so batch size, lane speed, refusal, and timing never
  change the world (`.claude/rules/simulation.md` § Determinism).
- The per-step commit budget is a fixed count, never derived from world size
  (`.claude/rules/budgets-capacities.md`).
- Lane jobs read only immutable inputs owned by the stream (the spec and its
  arena move into heap-shared stream state; nothing points into
  `LoadingState` or stack memory) and write only their own outputs. The world
  under construction is not live: no simulation, render, or nav reads it
  until adoption (51's frozen borrow).
- At load the stream is an app-layer readiness consumer that never steals or
  blocks the loading frame. In play it uses 51's step handoff, never a
  readiness query.
- Adoption (spawns, pipeline init, the new world's nav build) is one
  main-thread update at load; in play its cost follows the new world's own
  chunks (64G), never other worlds'.
- Cancel (state teardown or world destroy) waits at most for the running
  batch, then frees everything.
- Provides: 74 creates worlds in play without a long step.
- VoidLight: keep data-authored generation behind a loading screen; do not
  port progress callbacks from generation internals, visit-order-dependent
  RNG streams, or parallel init on futures.

### Checklist

- [ ] 58 entry-point split (plan, per-job generate, per-job commit, finish)
      and a shared adoption step; 58's golden tests unchanged; split job
      ranges equal one full range.
- [ ] Generation stream (`src/game/worldgen/`): batch submit, retire,
      budgeted commit, finish, cancel, config validation.
- [ ] `LoadingState` generating phase on the lane when it has a thread,
      progress through 53B's primitive, cancel on teardown, generate timing.
- [ ] In-play generation for 74 with step-keyed batch handoff.
- [ ] Tests: golden hash on every lane speed and equal to 58's serial and
      threaded paths; commit budget and in-flight bound respected; retry
      after a full lane; cancel mid-stream leaks nothing; the stream owns the
      spec after begin and frees it on failure; invalid configs refused; the
      lane batch body is allocation-free; loading-state streaming and
      fallback paths; in-play adoption step identical across lane speeds.
- [ ] Bench `worldgen-stream` at three world sizes: total time, mean and max
      per-step main-thread time, step count.
- [ ] Docs: `docs/architecture.md` worldgen (two paths, concurrency
      contract, commit budget); `docs/state-stack-and-input.md` loading
      phases; `docs/development-workflow.md` bench group.

### Acceptance checks

- [ ] `zig build test` passes, `-Dsanitize-thread=true` reports zero races,
      and golden parity holds under `zig build test --release=fast`.
- [ ] `worldgen-stream` max per-step main-thread time is flat across world
      sizes; adoption and total time recorded in the landing commit.
- [ ] Manual (Debug): the progress bar animates and the window stays
      responsive (move, quit) through generation of a large world.
- [ ] Review grep: no `ThreadSystem` or `WorldSystem` reachable from a lane
      batch context; readiness queries only in the stream and
      `LoadingState`.
- [ ] `zig build verify` passes.
