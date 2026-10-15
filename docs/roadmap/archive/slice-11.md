## Slice 11: SIMD-Aware Data Processor Systems

Goal: add high-performance systems that process `DataSystem` slices with the
thread system and SIMD helpers while preserving deterministic fixed-step update
behavior.

Current foundation:

- `ThreadSystem.parallelFor` runs synchronous range batches and returns only
  after all selected workers finish.
- `ThreadSystem.parallelForWithOptions` can align ranges to hot-column cache
  boundaries and cap selected worker threads for a specific processor.
- `UpdateContext` passes `thread_system` into states.
- `DataSystem` provides persistent 64-byte-aligned movement SoA slices for
  systems to process.
- `src/core/simd.zig` provides portable vector helpers.
- `MovementSystem` integrates explicit movement-body SoA slices through a serial
  path or `ThreadSystem.parallelForWithOptions`.
- `ParticleSystem` owns a state-local fixed-capacity transient SoA pool and
  updates particle rows through a serial path or
  `ThreadSystem.parallelForWithOptions`.
- `GameDemoState` spawns a few colored moving square entities so the processor has
  visible non-player runtime coverage.
- `GameDemoState` emits and renders transient particle rectangles through its state
  update/render functions.

Performance notes:

- Hot processors should iterate SoA columns directly, not per-entity AoS structs
  or dynamically joined component records.
- `ThreadSystem` integration is required for this slice. Keep a serial path for
  tests, explicit fallback behavior, and deterministic comparisons, but the
  processor API and tests must prove that systems can split `DataSystem` slices through
  `ThreadSystem.parallelFor`.
- Treat adaptive work tuning as a measured batch-profile policy, not a separate
  worker-count heuristic. The tuner starts inline, probes threaded profiles only
  when measured batch time justifies it, then searches aligned range sizes
  around the best measured threaded profile before settling. Benchmark output
  should keep reporting worker count, range size, main-thread wait time, and
  worker utilization so regressions are visible.
- Treat cache-line behavior as part of the processor contract. SoA columns used
  by SIMD processors should have an explicit alignment policy before relying on
  wider loads or target-specific vector behavior.
- Padding to 64-byte cache lines should be applied deliberately to thread-shared
  records, worker scratch, counters, queues, and other concurrently written
  coordination data where false sharing is a real risk.
- Do not pad the cold entity slot metadata by default. Entity slots hold
  generation, component masks, free-list state, and dense store indices; they
  should stay out of hot movement/render processor loops unless profiling proves
  otherwise.
- Worker ranges should be chosen so two workers do not write the same cache line
  of a hot SoA column during normal fixed-step processing.

System shape:

- `MovementSystem` reads and writes explicit movement-body SoA slices, keeps a
  simple serial path for tests and deterministic comparisons, and uses
  timing-adaptive threaded SIMD ranges for eligible batches.
- `MovementSystem` must not create, destroy, add, or remove entities/components
  inside worker ranges. Structural changes from future processors should flow
  through the state-owned simulation frame and `DataSystem` batch commit path.
- `ParticleSystem` is a state-owned transient effect system rather than a
  `DataSystem` entity processor. It keeps emission and expired row swap-removal
  on the main thread, while worker ranges only mutate assigned particle rows.
- These implementations prove the threaded/SIMD system contract before
  broadening into AI, collision, pathfinding, or render-prep processors.

Checklist:

- [x] Define ECS systems as data processors that accept typed `DataSystem`
      slices/views, `ThreadSystem`, and fixed-step delta time; document
      `ParticleSystem` as the state-owned transient effect exception.
- [x] Add a movement processor that splits dense SoA slices through
      `parallelFor`.
- [x] Add particle processors that split dense SoA slices through `parallelFor`.
- [x] Wire `MovementSystem` through `ThreadSystem.parallelFor` with a serial path
      for deterministic tests and explicit comparisons.
- [x] Use SIMD inside each worker range and scalar-tail code for remainder
      elements.
- [x] Add an explicit alignment strategy for hot SoA columns before introducing
      wider or target-specific vector loads.
- [x] Audit thread-shared processor data for false sharing and add 64-byte
      padding only where concurrent writes justify it.
- [x] Ensure worker jobs write only to assigned disjoint ranges.
- [x] Ensure worker ranges avoid sharing writable cache lines in hot SoA columns.
- [x] Keep state transitions, entity creation/removal, SDL calls, GPU calls,
      asset loading, and save/load streaming on the main thread.
- [x] Keep particle expired-row removal on the main thread after the worker
      batch completes. Future systems that produce per-worker output buffers
      will need an explicit deterministic merge step.
- [x] Keep normal 60Hz update paths allocation-free after initialization.

Acceptance checks:

- [x] Scalar and SIMD movement results match for representative data sets.
- [x] Serial and threaded processor results match for the same initial
      `DataSystem`.
- [x] The movement processor has test coverage for the serial path and the
      `ThreadSystem.parallelFor` path.
- [x] Worker jobs do not write outside their assigned `ParallelRange`.
- [x] Hot SoA columns used by SIMD processors have documented alignment behavior.
- [x] Thread-shared processor records that are concurrently written are either
      disjoint by design or padded/aligned to avoid false sharing.
- [x] Update processors perform no allocations during steady-state simulation.
- [x] Fixed-step update order remains deterministic: later systems always see
      completed output from earlier systems.

Movement and particle passes landed: the demo maps player input to movement
velocity, exposes a movement-body slice to `MovementSystem`, applies player-only
bounds clamping, emits a small particle trail, updates particles, and renders
transient particle rectangles. A few colored moving squares remain as non-player
movement processor coverage. Simulation contracts, collision, and the first AI
intent processor are covered by Slices 12-14. Pathfinding and broader rule
processing remain future systems that should build on the same typed-output
contracts.

