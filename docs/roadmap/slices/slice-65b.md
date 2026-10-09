## Slice 65B: Deferred Nav Rebuild On The Background Lane

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 51](slice-51.md), [Slice 65A](slice-65a.md), [Slice 64G](slice-64g.md), [Slice 49](slice-49.md), [Slice 64B](slice-64b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Re-scoped by 64G: confirm the need and shape
against 64G's `chunk-scale` dense-change numbers before the design pass.

Goal: a dense one-step terrain change (cave-in, explosion) never puts the
rebuild of all its dirty nav chunks on the critical path of the step that
commits it. A batch past a fixed dirty-chunk threshold is rebuilt off the
step and published as one unit at a fixed later step `s + k`, whatever the
lane's speed, and the published graph equals what the synchronous chunked
apply produces for the same batch.

### Current foundation

The nav storage below is per level today; 64G replaces it.

- `PathfindingSystem.reactToPostCommitNavEvents`
  (`src/game/systems/pathfinding/system.zig`) marks events into grow-only
  dirty buffers, applies them synchronously (`applyBufferedNavUpdates`), and
  emits at most one `nav_region_invalidated`. It runs at the commit seam
  (`merge_outputs`), outside `stage_order`, from
  `GameDemoState.applyStructuralCommandsAndPostCommitEvents` through
  `SimulationPipeline`.
- `PathfindingSystem.graph` is read every step by `pathfinding_update`
  workers and steering, and written only by the full build and the
  post-commit apply. Movement and collision read the world, never the graph.
- After an apply, cached paths are evicted by changed spans, cleared for a
  whole-level change, or invalidated by a version bump.
- A batch touching more than `nav_full_relabel_level_threshold` (8) levels
  relabels every level; 64G retires relabel, fallback rebuilds, and
  per-level storage and makes the per-step apply all-or-nothing and threaded
  over dirty chunks.
- `expectGraphsEquivalent` (`nav_graph.zig`) is today's equivalence oracle;
  64G keeps incremental == full rebuild.
- The production allocator (`std.process.Init.gpa`) is thread-safe.

### Architecture notes

- `PathfindingSystem` owns it end to end (`.claude/rules/pathfinding.md`);
  the state and pipeline only invoke it. No new `StageId`.
- Needs from 64G: chunk-owned nav with an all-or-nothing per-step apply over
  dirty chunks, so a deferred job copies and swaps only the dirty chunks,
  never a whole graph. Memory follows the in-flight batch.
- The classification threshold and latency `k` are fixed constants, never
  derived from map size (`.claude/rules/budgets-capacities.md`).
- From submit to publish the affected chunks are frozen: readers see the
  pre-batch graph; marks and new links arriving in the window are held
  (grown, never dropped) and applied at the publish step's seam; at most one
  deferred batch per world is in flight.
- Publish step and result are identical with no lane, a thread-less lane,
  or a fast, slow, or full lane (51's handoff; `.claude/rules/simulation.md`
  § Determinism). An OOM in the job leaves the front intact and re-marks the
  batch.
- The job reads only its plan and the frozen chunks (51's frozen borrow) and
  reaches no `ThreadSystem`, `DataSystem`, or `WorldSystem`; per-chunk work
  that reads the world runs threaded at the commit seam before submit.
- Cache invalidation after publish equals the synchronous path's for the same
  batch (one shared reaction).
- Deferred state is derived (64B `normalized`): never hashed or saved;
  normalize abandons an in-flight job; a save never waits on or disturbs it;
  the loaded session equals the continuing session normalized at the save
  step.
- Open: the lane is one serial thread, while nav threading must scale with
  the number of updates (`.claude/rules/pathfinding.md`). The design pass
  decides between the lane and a pool rebuild spread across steps, against
  64G's measured dense-change cost.
- VoidLight: port building off-thread and publishing whole; do not port
  rebuilding from the live world, publishing when a future completes,
  proportional cache eviction, or world-scaled worker budgets.

### Checklist

- [ ] Re-scope against landed 64G: confirm the need from `chunk-scale`
      dense-change numbers; fix the threshold and latency.
- [ ] Synchronous-versus-deferred classification by a fixed dirty-chunk
      threshold.
- [ ] Deferred plan prepared at the commit seam (threaded per chunk), a job
      rebuilding copies of the dirty chunks, publish at `s + k`, a fence
      holding marks and new links, abandon on rebuild, normalize, and
      teardown.
- [ ] Pipeline and state wiring: publish serviced in the main-thread input
      phase after replay capture; the nav event at the publish step's seam
      (still at most one per step).
- [ ] 64B's normalize abandons the deferred job; 46's mid-job round-trip
      trace test passes when 46 lands.
- [ ] Tests: deferred equals synchronous at the due step (incremental,
      multi-level dense change, a ramp added before and during the job);
      queries unchanged until the due step; window marks held and applied; a
      heavy batch in the window becomes the next job; a full lane runs inline
      and still publishes at the due step; OOM re-marks; abandon on rebuild,
      teardown, and normalize; serial equals threaded prepare;
      `FailingAllocator` proofs for submit, job, publish, and window-held
      marks, armed right after load; checksum traces equal across four lane
      shapes.
- [ ] Bench `nav-update-deferred`: main-thread cost of the deferred path
      against the synchronous chunked apply at three or more dirty-chunk
      counts, plus the job's own duration.
- [ ] Docs: `docs/architecture.md` Pathfinding (classification, fence,
      publish point); `docs/simulation-tiers-and-pipeline.md` nav window
      semantics; `docs/development-workflow.md` bench and TSan groups.

### Acceptance checks

- [ ] `zig build test` passes; under `-Dsanitize-thread=true` the lane-speed,
      abandon, and threaded-lane cases report zero races.
- [ ] Equivalence tests and four-lane checksum traces are equal.
- [ ] `FailingAllocator` proofs pass armed right after load.
- [ ] `nav-update-deferred`: from the threshold up, the deferred main-thread
      cost is below the synchronous apply and grows with the plan, not the
      rebuild; the job finishes inside the `k` window at every sample point.
- [ ] Review: every nav-mutating entry point routes through the fence;
      nothing reachable from the job takes `ThreadSystem`, `DataSystem`, or
      `WorldSystem`; no readiness query in `src/game/systems/pathfinding/`.
- [ ] `zig build verify` passes.
