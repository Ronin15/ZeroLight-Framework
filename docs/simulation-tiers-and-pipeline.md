# Simulation Frame Contracts

This document describes the implemented fixed-step simulation support in
`src/game/simulation.zig`. It is a current-code contract for
`SimulationFrame`, typed transient streams, structural command publication, and
domain events. Future pipeline/tier roadmap status belongs in
`docs/framework-implementation-slices.md`; durable ownership guidance belongs in
`docs/architecture.md`.

Related docs:

- [architecture.md](architecture.md) for durable frame flow, ownership, and
  future pipeline/tier direction.
- [framework-implementation-slices.md](framework-implementation-slices.md) for
  roadmap status and acceptance checklists.

## Module Role

`simulation.zig` owns state-local transient fixed-step data. Persistent gameplay
facts stay in `DataSystem`; app, render, audio, SDL, allocator, and thread
service ownership stay outside simulation payloads.

The module currently provides:

- `SimulationFrame` as the per-step owner of transient processor outputs.
- `SimulationPhase` for coarse fixed-step phase tracking.
- `RangeOutputStream(T)` for deterministic count/prefix/write output streams.
- Specialized streams for navigation intents, movement intents, path requests,
  collision contacts, collision triggers, and structural commands.
- `SimulationEvents` for lower-volume domain/system change signals.
- Structural command commit helpers that publish structural change events after
  `DataSystem` successfully applies commands.

## Fixed-Step Ownership

A gameplay state owns one `SimulationFrame` for its fixed-step update. The state
calls `beginStep()`, runs the ordered processors it owns, merges outputs, and
applies deferred structural commands at the explicit commit point.

`SimulationFrame` is transient. Callers should expect stream contents to be
valid only for the current fixed step after the producing stage has finished
and before the next `beginStep()`.

`SimulationPhase` is intentionally coarse:

- `idle`
- `begin_step`
- `main_thread_inputs`
- `processors`
- `merge_outputs`
- `commit_structural`
- `finished`

The concrete processor order is state-owned. `GameDemoState` currently uses
main-thread input, AI navigation-intent production, steering/path status,
pathfinding, sparse movement-intent application, movement, bounds clamp,
collision detection, collision response, particles/domain reactions, structural
commit, and post-commit render-queue reservation.

## Range Output Streams

`RangeOutputStream(T)` is the deterministic high-volume output pattern used by
threaded and serial processors:

1. Prepare or append range counts.
2. Count how many records each stable range will write.
3. Prefix counts into deterministic offsets.
4. Write records through range-owned writers.
5. Finish writes and consume `mergedItems()`.

Output order comes from range index and per-range write order, not worker
timing or worker IDs. Producers must finish all writes for a stream before any
later system consumes it.

Writers assert that the producer writes exactly the count it declared. This is
part of the contract: count and write phases must stay consistent.

## Frame Streams

`SimulationFrame` owns these streams:

- `events`: lower-volume typed domain/system signals.
- `navigation_intents`: high-level AI navigation goals.
- `intents`: movement intents and future simulation intents.
- `path_requests`: frame-delayed pathfinding requests.
- `contacts`: collision contacts for same-step response.
- `collision_triggers`: collision trigger records.
- `structural_commands`: deferred entity/component changes.

High-volume data should stay in its specialized stream. Do not collapse
contacts, movement intents, navigation intents, path requests, render-queue
records, or structural commands into generic events just for uniformity.

Use `reserveStreams`, `reservePathRequests`, and
`reserveNavigationIntents` during state/system initialization or warmup so
steady fixed-step producers do not allocate unexpectedly.

## Simulation Events

`SimulationEvents` is for lower-volume signals that describe important changes
or wake later domain reactions. It is not a global pub/sub bus and not
persistent state.

Current event payloads are:

- `entity_created`
- `entity_destroyed`
- `component_changed`
- `nav_region_invalidated`

Current event stages are:

- `structural_commit`
- `domain_reaction`

Events carry stable IDs, enum tags, and small value payloads only. They must not
carry pointers, app/render/audio handles, asset paths, allocators, loaded
resources, or service references.

`appendRequired` fails if the configured event capacity cannot hold the event.
`appendDiagnostic` drops on capacity failure and increments dropped stats. Use
required events for data needed to keep downstream state correct; use
diagnostic events only for optional observability.

## Structural Commands

Structural mutation is deferred. Worker ranges and hot processors write
`StructuralCommand` records into `SimulationFrame.structural_commands`; the
gameplay state commits them through `SimulationFrame.applyStructuralCommands`
or `applyStructuralCommandsWithExtraEvents`.

Commit behavior:

- `SimulationFrame` sets phase to `commit_structural`.
- `DataSystem` validates and applies the merged command batch.
- Structural changes are captured as plain `StructuralChange` records.
- Only after the commit succeeds does `SimulationFrame` publish typed
  structural events.
- Extra required event capacity can be preflighted before side effects that
  need domain-reaction events in the same step.

This keeps partial structural mutations from leaking when validation or event
capacity fails.

## Current Integration

`GameDemoState` owns the current concrete orchestration around
`SimulationFrame`. It:

- starts each fixed step with `beginStep()`;
- writes player input and audio commands at the main-thread boundary;
- lets AI, steering, pathfinding, movement, collision, and response systems use
  typed streams;
- consumes structural/domain events to rebuild navigation when static
  obstacle-affecting changes require it;
- applies structural commands at the fixed-step commit boundary;
- reserves render-queue capacity after structural commits and before render
  enqueue.

Render prep is outside `simulation.zig`. Persistent render intent stays in
`DataSystem`; render code resolves stable asset IDs through `RuntimeAssets` and
emits transient draw records through `RenderQueue`.

## Non-Goals

`simulation.zig` does not own:

- persistent gameplay facts or ECS component storage;
- SDL, GPU, renderer, audio, input, or app service handles;
- a global scheduler or app-wide entity manager;
- string-topic dispatch, callback chains, or pointer-bearing event payloads;
- renderer draw queues or prepared sprite records;
- pathfinding queues, caches, or solver scratch;
- long-lived domain controller state.

Those belong to their owning state, `DataSystem`, systems/processors, app
services, render services, or future pipeline/controller modules.

## Test Expectations

Tests for this module should prove the stream contracts directly:

- range streams merge in stable range order;
- range writers must write the declared count;
- appended ranges preserve existing merged data;
- event stats are deterministic by type and stage;
- capacity overflow distinguishes required events from diagnostic drops;
- structural command commits publish events only after successful `DataSystem`
  mutation;
- no test-only payload tags or fake stages are added to production contracts.
