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
stage; chunk columns are derived later in a dedicated `chunk_derive` stage from
each body's final settled position — not in-pass during movement), builds the
shared **spatial index** (`SpatialIndexSystem`, Slice 28) from that same
cognition-scoped population for AI separation queries, runs the
**perception stage** (`PerceptionSystem`, Slice 29) over the cognition-scoped
`AiPerception` subset against that same spatial index (range/FOV/line-of-sight,
writing sensed state to `PerceptionStore`), then the **memory stage**
(`AiMemorySystem`, Slice 30) over the cognition-scoped `AiPerception`+`AiMemory`
subset (decaying staleness/familiarity/ring contacts and refreshing from this
step's perception-acquisition events; decay is itself scope-gated through the
same cognition-scope dense-index list, so an entity demoted out of the
cognition halo simply stops being gathered — its memory row freezes rather
than decaying, and resumes cleanly on resync, with no separate freeze
mechanism needed), then the **affect stage**
(`AffectSystem`, Slice 31) over the cognition-scoped `AiAffect` subset
(appraising this step's just-written perception/memory state, both
independently optional per row, plus each agent's own `AiAgent.behavior`, into
four drives — fear, curiosity, aggression, fatigue — decayed toward per-entity
baselines), then owns AI navigation-intent production, steering/path status,
pathfinding, sparse movement-intent application, movement, collision detection,
collision response, bounds clamp + world-tile gating, and plane traversal — AI,
movement, and collision run scope-gated through a `scope_dense_indices` option.
Collision broadphase keeps its own sweep-and-prune structure rather than
consuming the spatial index (see `docs/architecture.md`). It closes with
`chunk_derive` then the **simulation-LOD tier policy**, which assigns each
entity a cognition/locomotion/kinematic/dormant tier by cube distance and emits
deferred `set_simulation_tier` commands at the commit seam. See
`docs/architecture.md` for scope/tier ownership and the gating rules per stage.

Late-stage pose order (after movement integrate):

1. `collision_scope_gather` → `collision_detect` → `collision_respond`
2. `bounds_and_tile_gate` (world bounds clamp + solid-tile gate)
3. `plane_traversal` (ramp follow / one-level fall; batches landing-cell tile
   events into one `finishWrite`)
4. `chunk_derive` → `tier_policy`

The tile gate runs **after** collision response so a contact push into solid
underground dirt is re-gated before plane traversal and chunk derive observe the
pose. Dig still runs first in the step so this step's carves are walkable for
movement and the gate. The gate resolves X then Y against the pre-move position
(wall-sliding) and is a no-op on level 0 (surface is fully walkable there).

NPCs carry a `world_level` component in `DataSystem` (Slice 25E). After movement,
collision, and the tile gate settle, plane traversal mirrors the player
ramp/fall cell-entry policy for NPCs and commits level changes on the main
thread. Off-surface entities are gated by `gateNpcEntitiesToWalkableTiles`
against solid tiles on their current plane; NPC gate and plane-traversal both
skip dormant-tier entities, since movement never moves them. Steering and
pathfinding read each entity's `world_level` for `start_level`; level transitions
at link crossings are committed by plane traversal against physical-cell world
geometry, not by a path-view field (a `PathView.next_cell_level` field was tried
and removed as an unused duplicate — see archive Slice 25E in
`docs/framework-implementation-slices-archive.md`).

## Stage Ordering Contract

`SimulationPipeline` (`src/game/simulation_pipeline.zig`) checks its own stage
order at comptime so a future reorder or inserted stage that reads a resource
before it is written fails the build instead of silently corrupting behavior.

- `PipelineResource` is the coarse set of per-step resources stages read or
  write (navigation intents, movement intents, path requests, contacts,
  movement body state, and similar). Some tags bundle several SoA columns one
  system owns together rather than tracking every field.
- `StageId` names each concrete stage in `update()`.
- `stageContract(stage)` declares each stage's reads and writes over
  `PipelineResource`.
- `stage_order` is the concrete order `update()` runs stages in.
- A `comptime` block walks `stage_order`, accumulating the resources written
  so far, and fails the build (`@compileError`) if any stage's declared reads
  are not a subset of what an earlier stage already wrote.
- A stage's `stageContract` lists **every** live resource it touches, including
  this-step values an earlier stage authored: `bounds_and_tile_gate`,
  `plane_traversal`, and `perception_update` all read the dig-authored
  `world_tiles`, and `plane_traversal` also writes `movement_positions` via the
  fall snap. An under-declared read or write leaves a real dependency invisible
  to the comptime check, so a reorder compiles clean.
- Not every real ordering dependency is expressible as a `PipelineResource`
  read/write — two stages can depend on call order while sharing no tracked
  resource, and a transient stream with no `PipelineResource` tag at all (e.g.
  the `WorldStimulus` values producers write into `frame.stimuli` and
  `perception_update` reads the same step) carries a producer→consumer
  dependency the comptime check cannot see. Every such untagged same-step
  dependency is pinned by a causal-effect test co-located in
  `simulation_pipeline.zig`: each sets up a scenario where the wrong order
  produces an observably different result and asserts the correct one. See
  "pipeline commits the dig stage's world edit before the tile gate reads
  walkability in the same step", "pipeline commits the dig stage's stimulus
  before perception reads it in the same step", "pipeline emits player footstep
  stimulus before perception in the same step", "pipeline promotes deferred
  impacts before perception on the following step", "pipeline commits the dig
  stage's world edit before plane traversal reads it in the same step",
  "pipeline runs ai_memory after perception and before ai, feeding memory into
  AI's cold-seek retarget", and "pipeline runs affect after perception and
  ai_memory, before ai" for the pattern.

Checklist for adding or reordering a stage:

1. Add the `PipelineResource` tag(s) it reads/writes, if none of the existing
   tags already cover them.
2. Insert its `StageId` into `stage_order` at the position its real
   dependencies require.
3. Add its `stageContract()` arm.
4. Add the real call in `update()` at the position `stage_order` requires. If
   the dependency isn't expressible via `PipelineResource`, add a
   causal-effect test proving the real call order.
5. `zig build check` fails at comptime if a `PipelineResource` dependency is
   missing; a causal-effect test fails if the stages run out of order for a
   dependency the comptime check can't see.

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
- `stimuli`: transient per-step positional sensory bus AI hearing can sense,
  read by `PerceptionSystem`. Cleared every `beginStep` and never promoted to
  an event, since a stimulus carries no stable entity identity to transition
  against. **Producer phase (before `perception_update`):** the pipeline
  promotes deferred impacts from the prior step, then `DigController.process`
  may append `.dig`, then the pipeline may append at most one `.footstep`
  when the player's movement body carries non-trivial velocity. **Deferred
  producer:** player-involving collision contacts enqueue `.impact` into a
  pipeline-owned fixed buffer after `collision_respond`; they are promoted
  onto the live bus at the start of the *next* step so perception never reads
  same-step impacts. Capacities are fixed constants (`stimulus_live_capacity`,
  `stimulus_deferred_capacity`, `stimulus_max_impacts_per_step` in
  `simulation.zig`); overflow drops newest optional/live entries
  deterministically. Callers warm `stimuli` to `stimulus_live_capacity` during
  state init (demo/pipeline), not scene-scale-derived counts.

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
- `entity_perceived` / `entity_lost` (Slice 29 perception acquire/lose transitions)
- `affect_threshold_crossed` (Slice 31 drive rising/falling-edge transitions)

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

Entity-driven obstacle events (`component_changed` on `movement_body`/
`collision_bounds`/`collision_response`, and `entity_destroyed`) also carry an
optional `ObstacleWorldRect` — the changed entity's world-space collision AABB,
before and/or after the change, when it was/is a static navigation obstacle.
Pathfinding resolves that rect to a nav-cell span (`markNavObstacleRectDirty`)
and patches only the affected chunks, the same incremental mechanism tile edits
already use, instead of invalidating the whole level. A null rect (component
data insufficient to derive one) falls back to a whole-level nav dirty mark.

`appendRequired` fails if the configured event capacity cannot hold the event.
`appendDiagnostic` drops on capacity failure and increments dropped stats. Use
required events for data needed to keep downstream state correct; use
diagnostic events only for optional observability.

Events are for low-volume notable changes and transitions, not high-volume
per-frame per-entity data. Dense per-step results — for example AI separation,
or perception/memory/affect state — belong in component columns or transient
range streams; only state transitions (such as acquiring or losing a target,
or a drive crossing a threshold) become events. This keeps the event stream
bounded and the per-frame data path allocation-free. New signal payloads must
still follow the scalar-only rule above and emit through the per-range writers
so merge order stays deterministic.

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

## Post-Commit Reactions

After structural commit and event publication, `GameDemoState` calls two
independent `SimulationPipeline` reactions against the same committed event
stream:

- `reactToPostCommitNavEvents` delegates to `PathfindingSystem`, interpreting
  nav-invalidating committed events (`world_tile_changed`,
  `world_obstacle_changed`, entity-driven obstacle changes) into dirty nav
  cells, applying the incremental nav-graph patch, and emitting
  `nav_region_invalidated`.
- `reactToPostCommitPerceptionEvents` delegates to `PerceptionSystem`,
  recording localized dirty rects from the same `world_tile_changed`/
  `world_obstacle_changed` events to incrementally patch its per-level
  LOS-blocked bitmap cache. It emits no event of its own.

Both reactions are side effects on fully disjoint state, so call order
between them does not matter.

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
