---
paths:
  - "src/game/**/*.zig"
  - "src/benchmarks/**/*.zig"
  - "src/core/**/*.zig"
  - "src/app/**/*.zig"
---

# Simulation, Events, Persistent Data

## Pipeline and stage ordering

- `SimulationPipeline.update()` is the only fixed-step scheduler; never add a
  second or promote it to a global ECS scheduler or app service. It only
  iterates `stage_order`; no reflection, dynamic dependency graphs, or callback
  registries.
- New features are pipeline-owned controllers or SoA processors; never grow
  `GameDemoState.update` or `SimulationPipeline.update`.
- Stage order is comptime-enforced in `simulation_pipeline.zig`:
  `stageContract()` declares reads, writes, and carried inputs; `stage_order`
  permutes `StageId`; reading an unwritten resource fails the build.
- `carried` is a value no earlier stage writes (pre-`update` input, world
  authoring, or next-step state from a later stage), disjoint from reads and
  writes; anything an earlier stage writes is a read.
- A new or reordered stage adds, in one change, its `PipelineResource` tags
  (coarse, not one-off), `stage_order` position where its real dependencies
  require, `stageContract()` arm, and `runStage` arm.
- An ordering dependency not expressible as a resource gets a causal-effect
  test, co-located in `simulation_pipeline.zig`, where the wrong order
  observably changes the result. Fix ordering bugs in the contract, never by
  weakening the check.
- Event tags are distinct: `world_events` does not satisfy `perception_events`,
  `affect_events`, or `structural_events`; `structural_events` are commit-seam
  payloads outside the stage graph.
- Entity chunk columns are written only by `chunk_derive`, after every position
  writer.

## Controllers and processors

- Controllers own phase order, budgets, and handoff; they emit frame outputs or
  deferred commands through typed `DataSystem` views. They never hold
  per-entity stores, handles, or hidden RNG, and never replace SoA processors.
- AI, pathfinding, and rules emit intents or deferred commands, never mutating
  unrelated stores; incompatible requests have a defined priority.
- RNG is explicit state passed through the processor boundary, never hidden or
  thread-local.
- Enemies, hazards, pickups, and world objects are plain entities processed by
  systems. Collision bounds are dedicated data, never inferred from visuals.
- Neighbor queries use the shared `SpatialIndexSystem`, never a private grid
  (collision sweep-and-prune is the exception).
- Locomotion flows `navigation_intents` → steering → `intents`; non-locomotion
  uses `action_intents`; never dual-write or overload `NavigationIntent`.
- Audio policy lives in `AudioController`; cognition never reads
  `AudioCommandBuffer`.
- World surfaces live in `WorldSystem`; the pipeline owns no tile storage,
  atlas metadata, or camera policy.

## Scope and tiers

- Simulation scope (participation, tiers, bands) derives only from the
  fixed-step `sim_view` through `simViewRegion`; simulation never reads the
  render window (`visibleChunkRegion()`).
- Tiers are capability-based and control processor participation only; render
  visibility controls draw construction only; a scope pin never bypasses render
  visibility.
- Tests needing every agent active use a full-extent rect or `always_active`.

## Determinism

- Same seed, initial state, and per-step input give bit-identical persistent
  state for any worker count, range size, tuner decision, render cadence, or
  wall-clock timing.
- No wall-clock value, worker ID, `BatchStats`/tuner state, or render state
  feeds simulation state.
- No `@setFloatMode(.optimized)` or `@mulAdd` in `src/`.
- A partition-dependent result is fixed in its owning module with a
  serial-vs-threaded parity test there.

## Events and streams

- Events are low-volume state transitions only; high-volume per-step data lives
  in component columns or frame streams.
- Event payloads are scalar: IDs, enums, coordinates, small values; never
  pointers, slices, handles, asset paths, allocators, or services.
- Events are phase outputs, never callbacks, string topics, or pub/sub. A
  consumer that emits more events names the next phase or defers to the next
  step; no recursive redispatch.
- Every `EventProducerId` declares `maxEventsPerStep`; capacity is reserved
  before the step. Required events protect correctness and a required-append
  failure is a bug; diagnostic events may drop with a count.
- Frame streams are valid only within the current step; `RangeOutputStream`
  writers write exactly the declared count.
- Preflight structural and event capacity before queuing; commits are
  all-or-fail and publish events only after success. `DataSystem` is the only
  structural-command applier. Post-commit reactions touch disjoint state and
  stay order-independent.

## Persistent data

- `DataSystem` owns persistent gameplay data (entity IDs, generations, masks,
  dense typed SoA stores). App, render, SDL/GPU, input-frame, thread, and event
  services, asset-loading state, and per-step scratch are never persistent
  `DataSystem` fields; processors borrow slices plus runtime services.
- A new per-entity concept follows the component-store pattern in
  `data_system/` (`Component` tag, mask, `EntityTemplate` field,
  `StructuralCommand` variant, capacity need, SoA store, const slice, slot
  index, validated set/get/slice helpers). Component tags append in landing
  order.
- Persistent gameplay and render-prep data store stable IDs (`SpriteAssetId`,
  `AudioAssetId`) and render depth as enum intent, never string paths,
  `TextureId`, leases, prepared sprite records, audio handles, or
  renderer-owned resources. Stable IDs convert to texture IDs at the
  render-prep boundary.
- A version number (format, schema, checksum tag) bumps relative to its live
  value (live + 1) in the change that needs it.

## AI and affect

- `scoreBehaviors` / `selectSticky` / `resolveGoal` stay the expandable path:
  utility scores plus sticky selection, never exclusive FSMs or behavior trees.
- Emotion drives behavior through a table over `AiAffectDrive`; a new feeling
  appends an `AiAffectDrive` tag (append-only), its columns, one appraisal path,
  and one weight-table row; never a parallel emotion system or a hard-coded
  drive branch.
- Drives are independent continuous `[0,1]` columns; discrete states derive
  from thresholds with hysteresis; only threshold crossings become events.
- Missing perception, memory, or affect contributes zero signal and never
  excludes an agent.
- Goals are per-agent and multi-source, never broadcast.
- Authoring is data resolved at load into enums and gain tables; hot paths
  never parse JSON or hash behavior names.
