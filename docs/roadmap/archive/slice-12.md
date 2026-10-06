## Slice 12: Simulation Contracts And Deferred Structural Changes

Goal: define deterministic, efficient simulation phase contracts before broad
gameplay systems start creating entities, emitting events, or requesting
structural changes from worker jobs.

Implemented foundation:

- `main.zig` -> `Engine` -> `StateStack` is the existing runtime dispatch path
  for events, fixed updates, and rendering.
- `StateTransitions` already queues state-stack changes until dispatch is safe.
- `DataSystem` owns persistent state-local gameplay data and excludes transient
  services.
- `ThreadSystem` runs synchronous range batches that complete before the next
  system consumes their output.
- `ParallelRange.index` gives inline and threaded jobs stable range-order
  identity independent of worker scheduling.
- `SimulationFrame` is state-owned transient per-step data with typed event,
  intent, and deferred structural command streams.
- `RangeOutputStream(T)` implements count/prefix/write output collection and
  deterministic range-index merge.
- `DataSystem.applyStructuralCommands` applies deferred entity/component changes
  at explicit main-thread commit points.
- `SimulationFrame.applyStructuralCommandsWithExtraEvents` commits deferred
  structural commands through `DataSystem`'s single planning path: event-stream
  capacity stays with `SimulationFrame`, while `DataSystem` validates commands
  and reserves persistent component storage capacity before mutation.
- `GameDemoState` owns a `SimulationFrame`, clears it each fixed step, runs
  processor phases, and applies deferred structural commands before the step
  finishes.
- `MovementSystem` now consumes explicit movement-body slices rather than broad
  structural `DataSystem` access.

Architecture notes:

- Structural entity/component changes, state transitions, SDL/GPU calls, asset
  loading, save/load streaming, and renderer ownership must remain behind an
  explicit main-thread or deferred boundary.
- Determinism, performance, and efficiency are one contract: output order must
  come from stable input/range order, not worker timing or worker IDs; high-volume
  outputs must use typed range-owned buffers instead of global per-command append,
  callback chains, or hot-path hash maps; warmed paths must avoid allocation.
- Threaded output collection should use a count/prefix/write pipeline:
  count outputs per range, prefix offsets on the main thread, write contiguous
  output by range, merge by range index, then consume the typed batch.
- Structural mutation remains behind `DataSystem` batch commit boundaries.
  Event and intent streams use the same typed range-output model, but remain
  transient simulation data rather than persistent `DataSystem` state.
- Designs should make fixed-step processor order, input order, output owner,
  merge order, allocation policy, conflict resolution, and structural apply
  points explicit before adding systems that can interact emergently.

Checklist:

- [x] Define the fixed-step simulation phase order for gameplay processors,
      transient events, deferred structural commands, and save/load hooks.
- [x] Add stable `ParallelRange.index` support so output order can be tied to
      deterministic range order rather than worker scheduling.
- [x] Add a state-owned simulation frame with typed event, intent, and deferred
      structural command streams.
- [x] Add range-owned output collection for high-volume streams using
      count/prefix/write and deterministic range-index merge.
- [x] Add `DataSystem` batch commit boundaries for deferred structural changes;
      do not expose per-command structural mutation as the simulation output API.
- [x] Refactor `MovementSystem` so the processor path receives typed slices
      rather than broad structural `DataSystem` access.
- [x] Add tests that worker-produced outputs merge in stable order.
- [x] Refactor typed processor APIs so hot processor paths avoid broad
      structural `DataSystem` access.
- [x] Document what belongs in persistent `DataSystem` state versus transient
      per-frame simulation data.

Acceptance checks:

- [x] Deferred entity/component changes apply only after the producing processor
      completes.
- [x] Replaying the same initial data and inputs produces the same event,
      command, and processor output order, independent of worker timing.
- [x] High-volume output paths use preallocated typed arrays, slices, range-owned
      buffers, and deterministic batch commit instead of global per-command
      atomics, broad event buses, or hot-path hash-map dispatch.
- [x] Save/load boundaries exclude transient frame events, scratch buffers,
      renderer resources, app services, and thread-system state.

