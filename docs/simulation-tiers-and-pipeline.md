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

`simulation.zig` owns state-local transient fixed-step data. The state-owned
`SimulationPipeline` owns fixed-step processor orchestration and reusable
systems. Persistent gameplay facts stay in `DataSystem`; app, render, audio,
SDL, allocator, and thread service ownership stay outside simulation payloads.

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
calls `beginStep()`, runs main-thread input writes, delegates ordered processor
dispatch to its state-owned `SimulationPipeline`, and applies deferred
structural commands at the explicit commit point.

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

The concrete processor order is pipeline-owned for one gameplay state instance.
`GameDemoState` currently keeps main-thread input, particles, structural
commit/domain reactions, and render-prep reservation at the state boundary; it
passes the borrowed audio command buffer through the pipeline-owned
`AudioController` rather than holding audio policy itself.
`SimulationPipeline` opens each step with the backbone **scope pass** (stagger
advance and the tier/halo/stagger gathers that select which entities enter each
stage; chunk columns are derived in-pass by the movement processor, not a separate
recompute), builds the shared **spatial index** (`SpatialIndexSystem`, Slice 28)
from that same cognition-scoped population for AI separation queries, runs the
**perception stage** (`PerceptionSystem`, Slice 29) over the cognition-scoped
`AiPerception` subset against that same spatial index (range/FOV/line-of-sight,
writing sensed state to `PerceptionStore`), then owns
AI navigation-intent production, steering/path status, pathfinding, sparse
movement-intent application, movement, bounds clamp, player-vs-world-tile
gating, collision detection, and collision response — AI, movement, and
collision run scope-gated through a `scope_dense_indices` option. Collision
broadphase keeps its own sweep-and-prune structure rather than consuming the
spatial index (see `docs/architecture.md`). It closes with the
**simulation-LOD tier policy**, which assigns each entity a
cognition/locomotion/kinematic/dormant tier by cube distance and emits
deferred `set_simulation_tier` commands at the commit seam. See
`docs/architecture.md` for scope/tier ownership and the gating rules per stage.

The player-vs-tile gate runs right after the bounds clamp and before entity
collision, so every downstream stage and the camera see the gated position. It
stops the player from moving into movement-blocking tiles on their current plane
(the mining mechanic: underground dirt is solid until dug) by resolving X then Y
against the pre-move position, which yields wall-sliding. It is a no-op on
level 0 (the surface is fully walkable there).

NPCs carry a `world_level` component in `DataSystem` (Slice 25E). After movement
and collision settle, `applyNpcPlaneTraversal` mirrors the player ramp/fall
cell-entry policy and commits level changes on the main thread. Off-surface NPCs
are gated by `gateNpcEntitiesToWalkableTiles` against solid tiles on their current
plane before entity collision runs; both NPC stages skip dormant-tier entities,
since movement never moves them. Steering and pathfinding read each entity's
`world_level` for `start_level`; level transitions at link crossings are
committed by `applyNpcPlaneTraversal` against physical-cell world geometry, not
by a path-view field (a `PathView.next_cell_level` field was tried and removed
as an unused duplicate — see `docs/framework-implementation-slices.md` Slice 25E).

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
contacts, movement intents, navigation intents, path requests, render-prep
commands, or structural commands into generic events just for uniformity.

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
- `world_tile_changed`
- `world_obstacle_changed`
- `nav_region_invalidated`

Current event stages are:

- `structural_commit`
- `domain_reaction`

Events carry stable IDs, enum tags, and small value payloads only. They must not
carry pointers, app/render/audio handles, asset paths, allocators, loaded
resources, or service references.

World tile and obstacle events carry compact level/cell regions plus old/new
tile and obstacle flags. They wake explicit reaction points such as pathfinding
or future world-collision refreshes; they are not immediate callbacks from
`WorldSystem`.

`appendRequired` fails if the configured event capacity cannot hold the event.
`appendDiagnostic` drops on capacity failure and increments dropped stats. Use
required events for data needed to keep downstream state correct; use
diagnostic events only for optional observability.

Events are for low-volume notable changes and transitions, not high-volume
per-frame per-entity data. Dense per-step results — for example AI separation,
or future perception, memory, and affect state — belong in component columns or
transient range streams; only state transitions (such as acquiring or losing a
target, or a drive crossing a threshold) become events. This keeps the event
stream bounded and the per-frame data path allocation-free. New signal payloads
must still follow the scalar-only rule above and emit through the per-range
writers so merge order stays deterministic.

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

`GameDemoState` owns app/state boundaries around `SimulationFrame` and
`SimulationPipeline`. It:

- starts each fixed step with `beginStep()`;
- writes player input and audio commands at the main-thread boundary;
- delegates reusable fixed-step systems and stage order to `SimulationPipeline`;
- consumes structural/domain/world events to rebuild navigation when static
  obstacle-affecting changes require it;
- applies structural commands at the fixed-step commit boundary;
- reserves renderer command capacity after structural commits and before render
  submission.

Render prep is outside `simulation.zig`. Persistent render intent stays in
`DataSystem`; render code resolves stable asset IDs through `RuntimeAssets` and
submits ordered renderer commands from explicit world/entity z-layer passes.

## Non-Goals

`simulation.zig` does not own:

- persistent gameplay facts or ECS component storage;
- SDL, GPU, renderer, audio, input, or app service handles;
- a global scheduler or app-wide entity manager;
- string-topic dispatch, callback chains, or pointer-bearing event payloads;
- renderer draw queues or prepared sprite records;
- pathfinding queues, caches, or solver scratch;
- long-lived domain controller state.

Those belong to their owning state, `DataSystem`, `SimulationPipeline`,
systems/processors, app services, render services, or future concrete
pipeline-owned controller modules.

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
