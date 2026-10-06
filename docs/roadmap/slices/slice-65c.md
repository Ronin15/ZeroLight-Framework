## Slice 65C: Streaming Worldgen On The Background Lane

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 53B](slice-53b.md), [Slice 65B](slice-65b.md), [Slice 51](slice-51.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on:
- **58**: `worldgen/generate.zig`, `GeneratedWorld`, `WorldGenSpec`, the
  golden-hash fixture, and the `worldgen` bench;
- **51**: lane, `isDone`;
- **65B**: the frozen-borrow clause in Slice 51's job rules;
- **53B**: the migrated loading screen and its `progress` HUD primitive.

It stays load-time only (Slice 58's decision). No simulation step runs
during generation, so this is an app-layer `isDone` consumer, never
step-keyed.

Goal:
- When the Engine lane has a thread, `LoadingState` generates the procedural
  world on the lane in fixed-size chunk batches.
- It commits completed chunks on the main thread at a fixed per-step budget
  and animates a progress bar through generation and commit. The final
  adoption step (`finish` + `GameDemoState.initFromGeneratedWorld`: spawns,
  pipeline init, and the full nav build) runs in one `LoadingState.update`,
  so the last drawn frame before gameplay holds for that step's duration;
  its time is recorded in Status beside the stream gate.
- The finished world is bit-identical (Slice 58 golden hash) to the threaded
  main-thread path and the serial path, regardless of lane timing.
- With no lane thread, Slice 58's threaded main-thread path runs unchanged.

### Current foundation (do not rebuild)

- **`LoadingState` today** (`loading_state.zig:100-126`, `:186-214`):
  - It latches `rendered_once` after one drawn frame, then calls
    `loadGameDemo` once.
  - That builds the entire `GameDemoState` (world generation, spawns,
    pipeline, nav) synchronously inside one `update`.
  - The screen is static text ("Building world", `:225`) and the window
    pumps no events during the build.
- **Slice 58's generator** (roadmap Slice 58 "Generation"):
  1. Main-thread setup: levels and layers, plus striped per-job output
     reservation sized from `level_count × chunk_count`.
  2. One pure job per `(level, chunk)` that writes disjoint dense cells and
     its own stripe, dispatched with `parallelForWithOptions`.
  3. A main-thread commit in level → chunk → slot order.
  4. Spawn and node selection.
  5. Player spawn.
  6. `rebuildChunks` / validate.

  Generate-time refusals (`WorldGenStratumMissing`,
  `WorldGenChunkFeatureMisaligned`) are raised in step 1, and
  `WorldGenNoWalkableSpawn` in step 5.
- **Slice 58 "Worldgen off the main thread"** already guarantees that jobs
  read only immutable inputs (validated spec, resolved IDs, dimensions,
  seed, caps), write only the under-construction world's buffers, and touch
  no `RuntimeAssets`, renderer, or SDL.
- **Slice 50:** a lane job reaching any `ThreadSystem` panics, including one
  with 0 workers, because the owner check runs first.
- **Slice 51 polling rules:** `isDone` is allowed for load staging in
  `LoadingState` and cold load-time value handoff.
- **`WorldSystem.addSparseTile`** (`world_system.zig:1699-1739`) touches only
  `sparse_tiles`, the sparse level and chunk indices, and
  `render_index_dirty`, never dense-layer storage.
- **The test fixture rule** (`docs/coding-standards.md:414-427`): procedural
  entry points are at most 16×16 with 1 underground level.

### Architecture notes

**Slice 58 entry-point split (this slice lands it; `generate.zig` keeps its owner)**

- `pub fn plan(allocator, world: *WorldSystem, spec: *const WorldGenSpec, config: WorldBuildConfig) !GenerationPlan`
  is Slice 58 step 1 plus all refusals that can be raised before generation.
  `GenerationPlan` owns the stripes, the `ChunkGenContext`, and per-layer
  accumulators. `plan` dereferences `spec` only during the call; it never
  stores the pointer (see `ChunkGenContext` and "Spec ownership" below).
- `pub const ChunkGenContext = struct { ... }`:
  - Immutable inputs: by-value copies (resolved IDs, field seeds,
    dimensions, `chunk_size_tiles`, caps) and slices whose backing memory
    is owned by the same owner as the `WorldGenSpec` (the stream's
    `StreamShared` arena on the lane path; the caller's spec on the
    synchronous path), plus per-layer `[]TileId` dense slices captured at
    `plan` (no `*WorldSystem`). It holds no pointer to the spec struct
    itself, to `LoadingState`, or to any stack memory.
  - Stripe slices: `features`, `nodes`, `spawn_candidates`, `summaries`,
    indexed by job index.
- `pub fn generateJobRange(ctx: *const ChunkGenContext, first_job: usize, end_job: usize) void`
  is the one job body. Job index is `level * chunk_count + chunk`. Slice 58's
  `parallelForWithOptions` path calls it per range. The lane calls it per
  batch. Infallible and allocation-free.
- `pub fn commitJob(plan: *GenerationPlan, world: *WorldSystem, job_index: usize) !void`
  is Slice 58 step 3 for one job: `addSparseTile` per feature in slot order,
  `chunk_biomes[chunk] = center_biome` for surface jobs, and the per-layer
  AND accumulation of `all_blocking` / `none_blocking`. It asserts the
  layer's dense base pointer still equals the plan's captured one.
- `pub fn finish(plan: *GenerationPlan, world: *WorldSystem, allocator) !GeneratedWorld`:
  per-layer `uniform_blocking` / `uniform_fill_tile` from the accumulators,
  then Slice 58 steps 4–6.
- `WorldSystem.initProceduralFromSpec` = `plan` → `parallelForWithOptions(generateJobRange)`
  → `commitJob` for `0..total` → `finish`. This is Slice 58's behavior,
  unchanged.
- `GameDemoState.initProceduralWithRuntimeAssets` becomes
  `initProceduralFromSpec` + the new
  `GameDemoState.initFromGeneratedWorld(allocator, runtime_assets, asset_store, generated: GeneratedWorld, thread_system, width, height, capture)`.
  That is Slice 58's spawn, node, and player adoption, plus Slice 51's
  capture init, moved verbatim. Both load paths share adoption.

**`WorldGenStream` (`src/game/worldgen/stream.zig`, new; owned by `LoadingState`)**

```zig
pub const WorldGenStreamConfig = struct {
    /// (level, chunk) jobs per lane job. Fixed default; bounds cancel latency
    /// (one lane job ~ 64 x per-chunk cost) and lane-slot use.
    chunk_jobs_per_lane_job: u32 = 64,
    /// Outstanding lane jobs. <= background_lane_slot_capacity / 4 so the
    /// stream never starves other lane consumers of slots.
    max_lane_jobs_in_flight: u8 = 8,
    /// (level, chunk) jobs committed on the main thread per LoadingState update.
    commit_chunk_jobs_per_step: u32 = 512,
};
pub const worldgen_stream_max_lane_jobs_in_flight: u8 = 8; // array bound
comptime {
    std.debug.assert(worldgen_stream_max_lane_jobs_in_flight <= background_lane_slot_capacity / 4);
}
pub const StreamProgress = struct { committed_jobs: usize, total_jobs: usize, ready: bool };
pub const WorldGenStream = struct {
    allocator: std.mem.Allocator,
    lane: *BackgroundLane,
    shared: *StreamShared, // heap: plan, world under construction, batch contexts
    config: WorldGenStreamConfig,
    total_jobs: usize,
    next_submit: usize = 0,
    ready_end: usize = 0,   // jobs [0, ready_end) belong to completed lane jobs
    next_commit: usize = 0,
    in_flight: [worldgen_stream_max_lane_jobs_in_flight]InFlightBatch, // FIFO ring
    in_flight_head: u8 = 0,
    in_flight_len: u8 = 0,
    /// Takes ownership of `spec` and of `spec_arena` (the arena that owns every
    /// slice inside `spec`), moving both into `StreamShared` before any other
    /// fallible step; on error they are freed before returning.
    pub fn begin(allocator, lane: *BackgroundLane, spec: WorldGenSpec, spec_arena: std.heap.ArenaAllocator, config: WorldBuildConfig, stream_config: WorldGenStreamConfig) !WorldGenStream;
    pub fn step(self: *WorldGenStream) !StreamProgress;
    pub fn finish(self: *WorldGenStream) !GeneratedWorld; // requires progress.ready
    pub fn cancel(self: *WorldGenStream) void;
};
const InFlightBatch = struct { ticket: BackgroundTicket, end_job: usize };
const LaneBatchContext = struct { gen: *const ChunkGenContext, first_job: usize, end_job: usize };
```

- **Config validation.** `begin` returns `error.InvalidWorldGenStreamConfig`
  unless:
  - `chunk_jobs_per_lane_job >= 1`;
  - `1 <= max_lane_jobs_in_flight <= worldgen_stream_max_lane_jobs_in_flight`;
  - `commit_chunk_jobs_per_step >= 1`;
  - `max_lane_jobs_in_flight * chunk_jobs_per_lane_job >= commit_chunk_jobs_per_step`,
    so in-flight work can feed a full commit step.

  The defaults satisfy all four (8 × 64 = 512). `LoadingState` uses the
  defaults. Tests pass small real configs, for example `{1, 2, 3}` on the
  golden fixture's 8 jobs, to exercise multi-batch ordering.
- **Heap and moved-value safety.** `StreamShared` is `allocator.create`d in
  `begin`. It holds the `WorldGenSpec` (by value) and its `spec_arena`, the
  `GenerationPlan`, the `WorldSystem` (created by `plan`), and
  `batch_contexts: [worldgen_stream_max_lane_jobs_in_flight]LaneBatchContext`.
  Lane jobs see only `*LaneBatchContext` → `*const ChunkGenContext`, both
  inside `StreamShared`, so moving `LoadingState` or the stream value is
  safe.
- **Spec ownership (no use-after-free across threads).** The spec is the
  one input that would otherwise live in the caller: `LoadingState` loads it
  into a local plus an arena during one `update`, but lane jobs read it for
  many steps on the lane thread. So `begin` takes the spec by value together
  with the arena that owns its slices. Its **first statement** is
  `errdefer spec_arena.deinit();` (the caller holds no cleanup handle
  once it has passed them); `StreamShared` is then created and the spec and
  arena are moved into it, after which a `moved_into_shared = true` flag
  disarms that `errdefer` and `StreamShared`'s own `errdefer` frees them on
  any later failure, so exactly one path frees them. `plan` is called with
  `&shared.spec`, and `ChunkGenContext` copies scalars by value and takes
  slices only from `shared.spec`'s arena. `cancel` and `finish` free the
  spec arena (and `StreamShared`) only after every in-flight ticket has
  retired (`complete` or `cancel` returned). `LoadingState` never keeps a
  pointer into the spec after `begin` returns.
- **`step()`**, on the main thread, once per `LoadingState.update`:
  1. **Retire.** While `in_flight_len > 0` and
     `lane.isDone(oldest.ticket)` is true:
     - call `lane.complete(oldest.ticket)`; it never waits here, because
       `isDone` is true;
     - set `ready_end = oldest.end_job`;
     - pop the ring head.

     Retirement is FIFO in submit order and stops at the first job that is
     not done. It never steals and never blocks the loading frame.
  2. **Commit.** `commitJob` for job indices
     `next_commit .. min(ready_end, next_commit + commit_chunk_jobs_per_step)`,
     in ascending order.
  3. **Submit.** While `in_flight_len < max_lane_jobs_in_flight` and
     `next_submit < total_jobs`:
     - fill the ring slot's `LaneBatchContext` with
       `[next_submit, min(+chunk_jobs_per_lane_job, total))`;
     - call `lane.submit(.{ .run = runLaneBatch, .context = ctx })`.

     `BackgroundLaneFull` stops submitting for this step; the next step
     retries. It is app-layer, and the result is unaffected.
  4. Return `ready = next_commit == total_jobs`.
- **`runLaneBatch`** calls `generateJobRange(ctx.gen, ctx.first_job, ctx.end_job)`.
  - Serial: no `ThreadSystem` is reachable. `ChunkGenContext` has no such
    field, which is the Slice 50 rule enforced structurally.
  - Allocation-free.
- **Concurrency contract** (frozen-borrow clause, 65B):
  - During streaming, lane jobs write only dense cells of their own jobs and
    their own stripe entries. They read only the plan's immutable inputs,
    which no thread writes after `begin`.
  - The main thread writes only sparse storage and `render_index_dirty`
    (via `addSparseTile`), `chunk_biomes` entries, the plan accumulators,
    and stream bookkeeping. It reads stripes only of retired jobs:
    `complete` acquires the lane mutex after the job's release, so outputs
    are visible.
  - No `addDenseLayer` call happens after `plan`, so captured dense slices
    stay valid. `commitJob`'s pointer assert guards this.
  - The world is not live. No simulation, renderer, or nav reads it until
    `finish` returns, and `finish` runs only when every lane job has
    retired.
- **Determinism:**
  - Dense cells and stripes are a pure function of the job index, since each
    job is a pure function with disjoint outputs.
  - The commit order is ascending job index.
  - `finish` runs once, after all jobs are committed.

  So the final `WorldSystem`, `GeneratedWorld`, and golden hash are
  identical to Slice 58's threaded and serial paths, whatever the lane
  speed, refusal, or batch size.
- **Fixed budgets.** `commit_chunk_jobs_per_step = 512` bounds main-thread
  work per `LoadingState` update. Commit costs a few `addSparseTile` calls
  plus one stripe read per job. The budget never scales with world size. A
  bigger world takes more steps, never a longer step.
  - The production 256×256×32 world is 8,192 jobs, so commit is at least 16
    steps (about 0.27 s).
  - `finish` runs in a single step. It is O(candidates log candidates +
    chunks) and bounded by the fixed spawn caps and `spawn_candidates_per_chunk`.
- **Cancel** (`LoadingState.deinit`, or quit during load). For every
  in-flight ticket in FIFO order, `lane.cancel(ticket)`: queued becomes
  cancelled, running is waited for, at most one lane job of about 64 chunks.
  Then free the plan, the world, the spec and its arena, and `StreamShared`,
  in that order. `finish` likewise frees the spec arena only after all jobs
  have retired (it requires `ready`, which implies an empty ring). Slice
  51's lifetime rule holds: the state deinits before the lane.

**`LoadingState` flow**

- `LoadingPhase` becomes `{ pending, generating, complete, failed }`.
- `.pending`, after `rendered_once`, decides the path:
  - If `context.background_lane` is non-null, `lane.hasThread()`, and the
    target uses Slice 58's spec generator, the state:
    1. loads `WorldGenSpec` (cold, through `context.asset_store`) into a
       fresh `std.heap.ArenaAllocator` that owns every slice of the spec;
    2. calls `WorldGenStream.begin(self.allocator, lane, spec, spec_arena,
       self.world_build_config, .{})`, transferring both (it keeps no copy
       and no pointer);
    3. sets `phase = .generating`.

    A plan refusal moves to `.failed`, using the existing warn-once.
  - Otherwise it calls the existing synchronous `loadGameDemo`
    (`initProceduralWithRuntimeAssets`, the threaded main-thread path).
- `.generating` calls `stream.step()` each update. When `ready`:
  - `finish()`;
  - `GameDemoState.initFromGeneratedWorld(...)` in this same update. Spawn
    adoption, pipeline init, and the nav build stay a main-thread step that
    uses `context.thread_system`, timed by `loading_build`. The progress bar
    shows 100% during it and the frame holds until it returns (a decided,
    single-step freeze: adoption touches the live pipeline and nav, which
    cannot be split across lane jobs under the frozen-borrow rule).
  - `replaceOwnedGameplay`;
  - `phase = .complete`.

  `finish` or adoption errors go to `.failed`.
- `render` draws Slice 53B's `progress` HUD primitive at
  `committed_jobs / total_jobs` under the status label. It never re-prepares
  text per frame. The label changes only on phase changes, as today.
- `BackgroundLane` gains `pub fn hasThread(self: *const BackgroundLane) bool`
  (`thread != null`). It is used only for this app-layer path choice and is
  never read in `src/game/simulation*`, the pipeline, or controllers.
- `perf.recordTiming(.loading_build, ...)` keeps timing the adoption step.
  The new `.loading_generate` timing covers `begin` → `ready` (wall time,
  app-layer, comptime-gated).

**Diagnostics**

- `logging.game.info` once at `begin`: "worldgen streaming on lane:
  {total} jobs, {per_job}/lane job, commit {budget}/step".
- `logging.game.info` once at `finish`: the Slice 58 info line plus the
  streamed step count.
- `warn` on plan or finish refusal (existing path).
- No per-step logging.

### Checklist

- [ ] Slice 58 entry-point split:
  - `plan`, `ChunkGenContext`, `generateJobRange`, `commitJob`, `finish`;
  - `initProceduralFromSpec` recomposed from them;
  - `GameDemoState.initFromGeneratedWorld` extracted.

  Slice 58's golden, thread-count, cap, and `uniform_blocking` tests stay
  green unchanged. New test
  `test "generateJobRange over split ranges equals one full range"`: the
  golden fixture's jobs in `{0..3, 3..8}` against `{0..8}`, with an
  identical golden hash.
- [ ] `src/game/worldgen/stream.zig`: config validation, `StreamShared`,
  `step`/retire/commit/submit, `runLaneBatch`, `finish`, `cancel`. Tests on
  Slice 58's inline golden fixture (16×16, chunk 8, 1 underground level, 8
  jobs), with stream config `{ .chunk_jobs_per_lane_job = 1, .max_lane_jobs_in_flight = 2, .commit_chunk_jobs_per_step = 3 }`:
  - `test "streamed worldgen matches the golden hash on every lane speed"`:
    - Run on a thread-less lane, a threaded fast lane, and a threaded slow
      lane. The slow lane has a gate job submitted first and released after
      5 `step()` calls that make no progress.
    - Each run's hash equals the pinned golden values for all three Slice 58
      seeds, and equals `initProceduralFromSpec` with
      `max_worker_threads = 0` and with 2 workers.
    - The recorded commit order is `0..8` in every run.
  - `test "stream commits at most the configured jobs per step"`.
  - `test "stream never submits more than max_lane_jobs_in_flight"`.
  - `test "stream retries submission after BackgroundLaneFull"`: 32 gate
    jobs; release before cancel.
  - `test "cancel mid-stream leaks nothing and leaves the lane healthy"`:
    threaded lane; afterwards submit and complete one trivial job;
    `std.testing.allocator` leak check (covers the moved spec arena).
  - `test "stream owns the spec after begin"`: a test-local helper builds
    the spec in its own arena, calls `begin`, and returns only the stream
    (its spec local and arena handle go out of scope without being freed);
    the test then runs the stream to `ready` on a threaded lane and calls
    `finish`. The golden hash matches, `std.testing.allocator` reports no
    leak (so the stream freed the moved arena), and the case is clean under
    `-Dsanitize-thread=true`.
  - `test "begin frees the spec when it fails"`: the `chunk_size_tiles = 6`
    plan refusal returns the error and `std.testing.allocator` reports no
    leak of the moved spec arena.
  - `test "invalid stream configs are refused"`: one case per rule.
  - `test "lane batch body is allocation-free"`: `FailingAllocator` on the
    plan's and world's allocator after `begin`, calling `runLaneBatch`
    directly. That is a private function, tested in the same file.
  - `test "plan refusals surface from begin without submitting"`: the
    `chunk_size_tiles = 6` misalignment.
- [ ] `BackgroundLane.hasThread`. Test: `test "hasThread reflects thread_enabled"`.
- [ ] `LoadingState`: the `.generating` phase, path selection, the progress
  primitive, cancel in `deinit`, and `.loading_generate` timing. Tests in
  `loading_state.zig`, using the existing 8×8 test config and headless
  renderer helper (`:242-247`, `:249`):
  - `test "loading state streams worldgen when the lane has a thread"`:
    threaded lane; step updates until `.complete`; the queued gameplay
    transition exists, and its world hash equals the synchronous path on
    the same config.
  - `test "loading state uses the synchronous path without a lane thread"`.
  - `test "loading state deinit during generation cancels cleanly"`.
- [ ] Bench: new group `worldgen-stream` in `src/benchmarks/worldgen.zig`
  (Slice 58's file), registered in `runner.zig`.
  - It uses Slice 58's `defaultItemCounts` size table (64/4, 128/8, 256/32).
  - Each iteration streams a full world on a real threaded lane.
  - It reports total wall time, mean and max per-`step()` main-thread time
    (hand-timed inside the bench, which is allowed in `src/benchmarks/`),
    and the step count.
  - The bench's own `std.debug.assert` checks the stream hash against the
    threaded `initProceduralFromSpec` hash.
- [ ] Roadmap cross-edits (same change):
  - Slice 58 Status line ("Generation stays on the main thread …") and its
    "Worldgen off the main thread" paragraph now say: "Slice 65C streams
    generation on the lane when it has a thread; the threaded main-thread
    path remains the no-thread fallback and the `initProceduralFromSpec`
    contract."
  - Slice 51 "Consumer decision" Worldgen bullet now names Slice 65C.
- [ ] Docs:
  - `docs/architecture.md`, worldgen ownership: the two load paths, the
    stream concurrency contract, and the fixed commit budget.
  - `docs/state-stack-and-input.md`, LoadingState: the phases and progress.
  - `docs/development-workflow.md`: the `worldgen-stream` group.

### Acceptance checks

- [ ] `zig build test` passes. `zig build test -Dsanitize-thread=true`
  reports zero races for the threaded stream, cancel, and LoadingState tests.
- [ ] Golden parity: streamed equals threaded equals serial for all three
  pinned seeds, on every lane speed. This also passes under
  `zig build test --release=fast`.
- [ ] The `FailingAllocator` proof for the lane batch body passes.
- [ ] Bench gate in ReleaseFast:
  `zig build -Doptimize=ReleaseFast bench -- --group worldgen-stream --details`.
  - At 256/32 (production), the max per-`step()` main-thread time is ≤ 4 ms,
    a quarter of a 16.67 ms step.
  - If it is not, halve the `commit_chunk_jobs_per_step` default (512 →
    256 → 128 → 64, never below 64) until it holds, and record the value.
    **Final outcome:** if 64 still exceeds 4 ms, the default stays 64, the
    measured max per-step time at every rung is recorded in Status as an
    accepted deviation, and the check closes. The per-step bound is then
    the fixed 64-job commit, which is still independent of world size.
    (Adjusting the default also keeps the config-validation rule
    `max_lane_jobs_in_flight * chunk_jobs_per_lane_job >=
    commit_chunk_jobs_per_step` satisfied, since 8 × 64 ≥ every rung.)
  - Record the adoption step (`finish` + `initFromGeneratedWorld`, timed by
    `loading_build`) at 256/32 in Status beside the stream gate. It is a
    single main-thread update by design (below) and has no ≤ 4 ms gate.
  - Record total stream time against Slice 58's `worldgen` `thread-fixed-auto`
    time at the same size in Status. The stream trades throughput for a
    responsive loading frame by design, so there is no ratio gate.
- [ ] Manual (Debug, `zig build run`): the loading progress bar animates and
  the window stays responsive (it can be moved, and quit works) through
  generation of the default 256×256×32 world. Record this in Status.
- [ ] Review grep: no `ThreadSystem` or `*WorldSystem` field is reachable
  from `LaneBatchContext`/`ChunkGenContext`; no `ChunkGenContext` field
  points at `LoadingState`, a `*WorldGenSpec`, or stack memory (only
  by-value copies and slices owned by `StreamShared`'s spec arena); and
  `isDone` appears only in `stream.zig` / `loading_state.zig`.
- [ ] `zig build verify` passes. Docs updated as listed.

### VoidLight reference

- **Port:**
  - Data-authored generation behind a loading screen, VoidLight
    `WorldGenerator` behind its loading state. ZeroLight keeps Slice 58's
    data model and adds the responsive load.
- **Do not port:**
  - Progress callbacks fired from generation internals, which Slice 58
    already rejects. Progress here is the main thread's own commit counter.
  - Generation-scoped RNG streams whose output depends on visit order
    (`WorldGenerator.cpp:335-341`). Every chunk job is a pure function of
    its index, so batch boundaries and lane timing cannot change the world.
  - Parallel manager init on futures (`src/core/GameEngine.cpp:452-470`).
    One lane, FIFO batches, canonical commit.

