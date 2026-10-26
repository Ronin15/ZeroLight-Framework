---
paths:
  - "src/game/**/*.zig"
  - "src/benchmarks/**/*.zig"
  - "src/core/**/*.zig"
  - "src/app/**/*.zig"
---

# Simulation, Events, Persistent Data

How the pipeline works: `docs/simulation-tiers-and-pipeline.md`,
`docs/architecture.md`.

## One scheduler, declared dependencies

- `SimulationPipeline` is the only fixed-step scheduler; never add a second or
  promote it to a global ECS scheduler or app service. It iterates a fixed
  stage order: no reflection, dynamic dependency graphs, or callback
  registries.
- Every stage declares what it reads, writes, and carries in, and the build
  rejects an order where a stage reads what no earlier stage wrote. A carried
  input is one no earlier stage writes (pre-step input, world authoring, or
  next-step state); anything an earlier stage writes is a read.
- A new or reordered stage declares all of it in one change, at the position
  its real dependencies require; resource tags stay coarse, never one-off.
- An ordering dependency the declarations cannot express gets a test beside
  the pipeline where the wrong order changes the result. Order bugs are fixed
  in the declarations, never by weakening the check.
- Each kind of event is its own resource; one never satisfies another.
  Structural events are commit-seam payloads outside the stage graph.
- A derived column has exactly one writer, a derive stage that runs after
  every writer of its source.

## Controllers and processors

- New behavior is a pipeline-owned controller or SoA processor, never growth
  in a state's or the pipeline's update.
- Controllers own phase order, budgets, and handoff, and emit frame outputs or
  deferred commands through typed `DataSystem` views; they never hold
  per-entity stores or handles, and never replace processors.
- A system changes only state it owns; toward anything else it emits intents
  or deferred commands, and competing requests have a defined priority.
- RNG is explicit state passed through the processor boundary, never hidden or
  thread-local.
- Gameplay objects are plain entities processed by systems. Each concern has
  its own data (collision bounds are never inferred from visuals).
- A static body changes position, bounds, or level only through structural
  commands; consumers of static data rely on it.
- Neighbor queries share the one `SpatialIndexSystem`, never a private grid;
  collision's sweep-and-prune is the one exception.
- Each purpose has one intent stream: locomotion flows from navigation
  intents through steering to movement intents, everything else is an action
  intent; never dual-write or overload a stream.
- A service's policy lives in its controller (audio in `AudioController`);
  cognition never reads output command buffers.
- World surfaces live in `WorldSystem`; the pipeline owns no tile storage,
  atlas metadata, or camera policy.

## Scope and tiers

- Simulation fidelity derives only from the fixed-step simulation view, never
  the render window. Tiers set fidelity, never whether an entity advances
  (`engine-design.md` § Target scale). Render visibility controls drawing
  only, and a scope pin never bypasses it.
- A test that must exclude distance effects puts every agent in the nearest
  band (a full-extent view or always-active rows).

## Determinism

- Same seed, initial state, and per-step input give bit-identical persistent
  state for any worker count, range size, tuner decision, render cadence, or
  wall-clock timing. No wall-clock value, worker ID, batch or tuner state, or
  render state feeds simulation state.
- A partition-dependent result is fixed in its owning module, with a
  serial-vs-threaded parity test there.

## Events and streams

- Events are low-volume state transitions; high-volume per-step data lives in
  component columns or frame streams.
- Event payloads are scalar (IDs, enums, coordinates, small values), never
  pointers, slices, handles, paths, allocators, or services.
- Events are phase outputs, never callbacks, string topics, or pub/sub. A
  consumer that emits more events names the next phase or defers to the next
  step; no recursive redispatch.
- Every event producer declares its maximum per step, and capacity is reserved
  before the step. Failing to append a required (correctness) event is a bug;
  a diagnostic event may drop with a count.
- Frame streams live for one step; a stream writer writes exactly the count it
  declared.
- Structural and event capacity is preflighted before queuing; commits are
  all-or-fail and publish events only after success. `DataSystem` is the only
  structural-command applier, and post-commit reactions touch disjoint state
  in any order.

## Persistent data

- `DataSystem` owns persistent gameplay data. Services (app, render, platform,
  input, threads, events), asset-loading state, and per-step scratch are never
  persistent fields; processors borrow slices plus runtime services.
- A new per-entity concept follows the one component-store pattern
  (`docs/architecture.md` § Gameplay Data), never a side store; component
  tags append in landing order.
- Persistent and render-prep data store stable IDs and enum intent, never
  paths, GPU or texture handles, leases, prepared records, or renderer-owned
  resources; stable IDs convert at the render-prep boundary.
- A version number (format, schema, checksum tag) bumps relative to its live
  value (live + 1) in the change that needs it.

## AI and affect

- AI decisions stay the expandable path: utility scores plus sticky
  selection and goal resolution, never exclusive FSMs or behavior trees.
- Emotion drives behavior through a weight table over an append-only drive
  enum; a new feeling adds a drive, its columns, one appraisal path, and one
  table row, never a parallel emotion system or a hard-coded branch.
- Drives are independent continuous `[0,1]` columns; discrete states derive
  from thresholds with hysteresis, and only threshold crossings become events.
- Missing perception, memory, or affect contributes zero signal and never
  excludes an agent.
- Goals are per-agent and multi-source, never broadcast.
