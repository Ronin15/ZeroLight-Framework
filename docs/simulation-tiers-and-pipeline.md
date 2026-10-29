# Simulation Frame Contracts

This document describes the implemented fixed-step simulation support in
`src/game/simulation.zig`. It is a current-code contract for
`SimulationFrame`, typed transient streams, structural command publication, and
domain events. Rules: `.grok/rules/simulation.md` and
`.grok/rules/threading.md`. Roadmap status is in the roadmap (index
`docs/framework-implementation-slices.md`; the planned merged `stage_order` is
Table T4 in `docs/roadmap/tracks/voidlight-port.md`).

Related docs:

- [architecture.md](architecture.md) for durable frame flow, ownership, and
  future pipeline/tier direction.
- [framework-implementation-slices.md](framework-implementation-slices.md) (roadmap
  index) and the per-slice files under [roadmap/slices/](roadmap/slices/) for
  roadmap status and acceptance checklists; cross-slice stage order,
  save, and checksum version tables are in
  [roadmap/tracks/voidlight-port.md](roadmap/tracks/voidlight-port.md).

## Module Role

`simulation.zig` owns state-local transient fixed-step data. The state-owned
`SimulationPipeline` owns fixed-step processor orchestration and reusable
systems. Persistent gameplay facts live in `DataSystem`; app, render, audio,
SDL, allocator, and thread services are never part of simulation payloads.

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

`SimulationFrame` is transient. Stream contents are
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
`SimulationPipeline` runs its `stage_order` (`docs/architecture.md` holds
scope/tier ownership and the gating rules per stage). "On workers" below means
a threaded pass under its own tuner, which may keep it inline below its gate:

1. `dig_world_edit`: the dig's world edit and the step's stimuli (deferred
   impacts promoted, the dig, at most one player footstep).
2. `scope_advance_and_ai_gather`: the **scope pass** advances the stagger clock
   and gathers the unstaggered cognition halo on workers. Chunk columns come
   later, from `chunk_derive`.
3. `spatial_index_build`: the shared **spatial index** of the halo at the
   previous step's positions and levels (carried); bucket, sort, and link run
   on workers (`docs/architecture.md`).
4. `ai_cognition_order`: the **think set**, the indexed rows on this step's
   stagger phase plus `always_active` (every row with no cognition region), in
   the index's cell-major order, compacted on workers over cell-major
   positions. Rows sharing a cell are adjacent in every later think-set stage;
   results never depend on that order.
   A row's stagger phase is set at movement-body append
   (`dense_index % cognition_stagger_n`); `setSimulationMetadata` keeps it,
   and takes the level from the `world_level` row, unless the write names
   them (`simulation_scope.zig` `EntitySimulationMetadata`).
5. `perception_update` (`PerceptionSystem`): think-set observers against the
   index (range, FOV, line of sight), writing sensed state to `PerceptionStore`;
   the gather and the compute run on workers. Carries positions and levels.
6. `ai_memory_update` (`AiMemorySystem`): over the think set's rows carrying
   `AiPerception` and `AiMemory`, in ascending memory-row order for any think
   order. Workers translate think rows to memory and perception rows; main
   marks each member in a hierarchical row bitmap; workers order the members
   over the touched row words; workers decay; main refreshes from this step's
   perception events; workers track still-visible targets, reading each row's
   carried perception row. A row demoted out of the halo is not gathered, so
   its memory freezes and resumes cleanly on resync.
7. `affect_update` (`AffectSystem`): appraises this step's perception and
   memory state (each optional per row) and the agent's `ai_behavior` (carried)
   into four drives decayed toward per-entity baselines. Its gather runs on
   main ([Slice 88](roadmap/slices/slice-88.md)); the compute runs on workers.
8. `ai_decide` (`AiSystem`): gather, separation and cohere, and intent emission,
   each on workers. Carries positions, levels, and interest markers.
9. `path_goal_resolve` → `steering_update` → `pathfinding_update` →
   `apply_ai_movement_intents` → `movement_integrate`: the step's goal table,
   steering and path status (the shared index; carried positions and level),
   frame-delayed pathfinding, movement intents in movement-row order, and
   movement.
10. The late-stage pose order below, then `chunk_derive` → `action_react` →
    `tier_policy`. The **simulation-LOD tier policy** assigns each entity a
    cognition/locomotion/kinematic/dormant tier by cube distance and emits
    deferred `set_simulation_tier` commands at the commit seam (the Target
    Model keeps `dormant` for inert things only).

Collision broadphase keeps its own sweep-and-prune structure rather than
consuming the spatial index (see `docs/architecture.md`).

**Sim-view rule (Slice 49).** Every scope band (cognition halo, tier policy,
and later coast/spawn bands) derives from the fixed-step
`SimulationPipelineUpdateContext.sim_view` rect: the scope pass uses
`WorldSystem.cognitionRegionForWorldRect(sim_view, sim_view_overscan_chunks,
cognition_halo_chunks)` and the tier policy (and any later scope-band reader)
uses the pipeline's `simViewRegion(context)`. `GameDemoState.simViewRect()` is
the only sim-view source (`camera_current`, the camera computed at the end of
the previous step). No simulation path reads `WorldSystem.visibleChunkRegion()`
— that window is set by `render` from the interpolated camera for draw culling
only. `sim_view` is required (a non-optional `Rect`), so no caller can silently
skip scope gating. Only a world with no chunks yields no region, which keeps the
full-active fallback (no halo, no stagger filter, no tier changes); pipeline tests
pass a full-world-extent rect, and a test whose subject is the whole population
thinking in one step on a chunked world marks it `always_active`.

Late-stage pose order (after movement integrate):

1. `collision_scope_gather` → `collision_detect` → `collision_respond`
2. `bounds_and_tile_gate` (world bounds clamp + solid-tile gate)
3. `plane_traversal` (ramp follow / one-level fall): `PlaneEntrySystem` gathers
   and classifies the step's NPC cell entries on workers into windows reserved at
   init and at the population seam (a shortfall grows on main before dispatch,
   counted in `plane_entry_windows_grown`); the reserve decides every traversal in
   commit order, O(1) per entry, and reserves the carves' write scratch (a carve
   count past the declared reservation is counted in `dig_plane_scratch_grown`);
   the carves write as one batched `applyDenseCellWrites` (all or nothing, on the
   world's terrain-edit tuners under `DigController.carve_controls`), their
   landing-cell tile events published as one event range and recorded for nav
4. `chunk_derive` → `action_react` → `tier_policy`

The tile gate runs **after** collision response so a contact push into solid
underground dirt is re-gated before plane traversal and chunk derive observe the
pose. Dig still runs first in the step so this step's carves are walkable for
movement and the gate. The gate resolves X then Y against the pre-move position
(wall-sliding) and is a no-op on level 0 (surface is fully walkable there).

NPCs carry a `world_level` component in `DataSystem` (Slice 25E). After movement,
collision, and the tile gate settle, plane traversal applies the player's
ramp/fall cell-entry policy (one shared `planeTarget`) to NPCs and commits level
changes on the main thread. Off-surface entities are gated by `gateNpcEntitiesToWalkableTiles`
against solid tiles on their current plane; NPC gate and plane-traversal both
skip dormant-tier entities, since movement never moves them. Steering and
pathfinding read each entity's `world_level` for `start_level`; level transitions
at link crossings are committed by plane traversal against physical-cell world
geometry, not by a path-view field (a `PathView.next_cell_level` field was tried
and removed as an unused duplicate — see archive
[Slice 25E](roadmap/archive/slice-25e.md)).

## Stage Ordering Contract

`SimulationPipeline` (`src/game/simulation_pipeline.zig`) checks its own stage
order at comptime so a future reorder or inserted stage that reads a resource
before it is written fails the build instead of silently corrupting behavior.

- `PipelineResource` is the coarse set of per-step resources stages read or
  write (navigation intents, movement intents, path requests, contacts,
  movement body state, and similar). Some tags bundle several SoA columns one
  system owns together rather than tracking every field.
- `StageId` names each concrete stage in `update()`.
- `stageContract(stage)` declares each stage's reads, writes, and carried
  inputs over `PipelineResource`.
- `stage_order` is a permutation of `StageId`: every tag once, in the order
  `update()` runs.
- A `comptime` block walks `stage_order`, accumulating the resources written
  so far, and fails the build (`@compileError`) if any stage's declared reads
  are not a subset of what an earlier stage already wrote.
- `carried` lists inputs no earlier stage writes. It is disjoint from that
  stage's reads and writes. Allowed sources are `external_resources`
  (`action_intents` from input capture, `interest_markers` from world
  authoring, `structural_events` from the post-step commit) or a later stage's
  write consumed as previous-step state (`affect_update` carries `ai_behavior`,
  which `ai_decide` writes later in the same step; `spatial_index_build`,
  `perception_update`, `ai_decide`, and `steering_update` carry the previous
  step's `movement_positions` and `world_level`, so a reorder past a position
  or level writer fails the build). A carried resource that an
  earlier stage writes is a compile error; declare it as a read.
- Event payloads are four tags. `perception_events` (`entity_perceived`,
  `entity_lost`) is written by `perception_update` and read by
  `ai_memory_update`. `affect_events` is `affect_threshold_crossed`.
  `world_events` covers tile, obstacle, nav, and `destructible_destroyed`
  payloads. `structural_events` covers `entity_created`, `entity_destroyed`,
  and `component_changed`. A stage-0 write of `world_events` does not satisfy
  a later read of a different event tag. The `SimulationEvents` stream is
  still one buffer; the tags are the ordering contract.
- `stimuli` is written by `dig_world_edit` (promote, dig append, footstep) and
  read by `perception_update`. `interest_markers` is carried by `ai_decide`.
- A stage's `stageContract` lists **every** live resource it touches, including
  this-step values an earlier stage authored: `bounds_and_tile_gate`,
  `plane_traversal`, and `perception_update` all read the dig-authored
  `world_tiles`, and `plane_traversal` also writes `movement_positions` via the
  fall snap. An under-declared read or write leaves a real dependency invisible
  to the comptime check, so a reorder compiles clean.
- Ordering the resource tags cannot see is pinned by a causal-effect test
  co-located in `simulation_pipeline.zig`: each sets up a scenario where the
  wrong order produces an observably different result and asserts the correct
  one. See
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
3. Add its `stageContract()` arm, including `carried` when the input is
   external or previous-step state.
4. Add the stage method `runStage` dispatches to. `update()` is an `inline for`
   over `stage_order` and does not call systems itself. If the dependency
   isn't expressible via `PipelineResource`, add a causal-effect test proving
   the real call order.
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
timing or worker IDs. Producers finish all writes for a stream before any
later system consumes it, and writers assert that the producer writes exactly
the count it declared.

## Frame Streams

`SimulationFrame` owns these streams:

- `events`: lower-volume typed domain/system signals.
- `navigation_intents`: high-level AI navigation goals (locomotion handoff to
  steering/pathfinding — not attack/interact/use).
- `action_intents`: non-locomotion gameplay requests (`ActionIntent`: entity,
  kind, optional target/cell scalars, priority, cooldown key). Producers append
  only to this stream (never dual-write into `intents`). **Producer phase:**
  main-thread input capture (`captureActionIntent` rising edges today; latch
  advances only on successful append so soft-drops retry while held). Future
  AI arbitration may emit multi-range writes when in-range attack/interact is
  added in a later slice. **Consumer phase:** explicit domain reaction after
  merge (`action_react` in `stage_order`). **Slice 45 consumer:** pipeline-owned
  `DestructibleController` reads merged intents, resolves interact/attack
  against `Component.destructible` entities (target ID or cell-center collision
  AABB; lowest entity index/generation on ties), accumulates same-step multi-hit
  damage in a fixed scratch of size `action_intent_live_capacity`, and queues
  deferred `StructuralCommand`s (`destroy_entity` / `set_destructible`) plus a
  scalar `destructible_destroyed` domain event (entity still alive at emit;
  commit still emits `entity_destroyed` for nav local re-mask). Ignores
  `.use`/`.signal`. Structural + event capacity is preflighted before queuing
  (dig pattern). `tier_policy` may append more `structural_commands` afterward
  via `RangeOutputStream` multi-producer append — action_react does not own the
  stream exclusively. Action intents are **carried** into `action_react`:
  wall-clock appends happen in `main_thread_inputs` via `captureActionIntent`
  before `update`, and no stage writes the stream. Capacity is the fixed
  constant `action_intent_live_capacity` in `simulation.zig` (64), not
  map-scaled. Callers warm with
  `reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity)`
  (one range slot per sequential append, same shape as stimuli). Optional
  producers use `tryAppendActionIntent` so a full bus drops cleanly.
- `intents`: movement intents (`SimulationIntent.movement` only). Non-locomotion
  producers use `action_intents` instead.
- `path_requests`: frame-delayed pathfinding requests.
- `contacts`: collision contacts for same-step response.
- `collision_triggers`: collision trigger records.
- `structural_commands`: deferred entity/component changes.
- `stimuli`: transient per-step positional sensory bus AI hearing can sense,
  read by `PerceptionSystem`. Cleared every `beginStep` and never promoted to
  an event, since a stimulus carries no stable entity identity to transition
  against. **Producer phase (before `perception_update`):** `SensoryBus`
  promotes deferred impacts, `DigController.commitWorldEdit` emits a required
  `.dig` (a full live bus returns `StimulusCapacityExceeded` and leaves the
  tile unchanged), then `SensoryBus.appendFootstep` may emit one optional
  `.footstep`. **Deferred producer:** `SensoryBus.enqueuePlayerImpacts` after
  `collision_respond` reads the response's observer contacts (the contacts naming
  the player, merged in range order) and writes `.impact` into the bus's fixed
  deferred buffer;
  promote runs on the next step's `dig_world_edit`, so perception never reads
  same-step impacts. **Sticky one-shots:** `advanceSticky` after perception
  captures live `.dig` and `.impact` for `cognition_stagger_n - 1` further
  steps (hearing scratch is live bus plus still-lingering sticky). Footsteps
  are live-only. Live writes go through `SensoryBus.emit`. Required fails;
  optional increments the drop counter and returns false. `writeLiveStimulus`
  is the unchecked frame append under that cap. Sticky and deferred overflow
  is a counted drop, not a bigger buffer. Capacities are fixed constants
  (`stimulus_live_capacity`, `stimulus_sticky_capacity`,
  `stimulus_deferred_capacity`, `stimulus_max_impacts_per_step` in
  `simulation.zig`). Callers warm `stimuli` to `stimulus_live_capacity` during
  state init (demo/pipeline), not scene-scale-derived counts.

High-volume data stays in its specialized stream: contacts, movement intents,
navigation intents, path requests, render-prep commands, and structural
commands are not events.

Use `reserveStreams`, `reservePathRequests`, `reserveNavigationIntents`, and
`reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity)`
during state/system initialization or warmup so steady fixed-step producers do
not allocate unexpectedly.

**When to use which intent channel:** `NavigationIntent` = where to go (AI →
steering). `SimulationIntent.movement` = how to move this step (steering →
movement apply). `action_intents` = what non-locomotion action to consider
(interact/attack/use/signal). `SimulationEvent` = durable transitions and
post-commit reactions (perception, affect, nav invalidation) — not per-step
action spam.

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
- `destructible_destroyed` (Slice 45 domain reaction: entity, level, cell, cause)

Current event stages are:

- `structural_commit`
- `domain_reaction`

Events carry stable IDs, enum tags, and small value payloads only
(`.grok/rules/simulation.md`).

World tile and obstacle events carry compact level/cell regions plus old/new
tile and obstacle flags. They wake explicit reaction points such as pathfinding
or future world-collision refreshes; they are not immediate callbacks from
`WorldSystem`.

Static obstacles reach nav through the static-collider sync, not events: the
commit seam captures the step's entity changes, `StaticColliderSystem.sync`
applies them from the entities' final state, and pathfinding records each
change's old and new cell spans as marks for the same step's nav reaction, which
patches only those chunks.

`appendRequired` fails if the configured event capacity cannot hold the event.
`appendDiagnostic` drops on capacity failure and increments dropped stats. Use
required events for data needed to keep downstream state correct; use
diagnostic events only for optional observability.

**Per-step bound (Slice 72).** `capacity_limit` is the exhaustive sum of
`maxEventsPerStep` over every `EventProducerId` (`SimulationPipeline.eventCapacitySum()`),
set by `SimulationPipeline.reserve` at state init. A new producer adds one arm. A
required-append failure means a producer exceeded its declared budget, which is a bug, not
a capacity condition. The `.structural_commit` arm is the pipeline's own share
(`pipeline_structural_event_share`: one single-event `destroy_entity`/`set_destructible`
per live action intent from the `action_react` stage) plus the caller's
`SimulationPipelineConfig.structural_headroom`, which covers only the structural commands
the caller itself queues. `structural_headroom` also sizes the structural-command
stream past one tier command per body and its range count past the pipeline's own
ranges, one range per event.

Events are for low-volume notable changes and transitions, not high-volume
per-frame per-entity data. Dense per-step results — for example AI separation,
or perception/memory/affect state — belong in component columns or transient
range streams; only state transitions (such as acquiring or losing a target,
or a drive crossing a threshold) become events. This keeps the event stream
bounded and the per-frame data path allocation-free. Emission order rules are
in `.grok/rules/threading.md`.

## Structural Commands

Structural mutation is deferred. Worker ranges and hot processors write
`StructuralCommand` records into `SimulationFrame.structural_commands`; the
gameplay state commits them through `SimulationFrame.applyStructuralCommands`
or `applyStructuralCommandsBudgeted`, which takes a `StructuralCommitBudget`
(usually `SimulationPipeline.structuralCommitBudget(extra_required_events)`). The
budgeted commit is all-or-fail: its preflight rejects, before any mutation, a
commit whose events exceed its own `.structural_commit` share or that, together
with the `extra_required_events` reserved for after it (the post-commit nav
reaction), would not fit the shared event bound.

Commit behavior:

- `SimulationFrame` sets phase to `commit_structural`.
- `DataSystem` validates and applies the merged command batch.
- Structural changes are captured as plain `StructuralChange` records.
- Only after the commit succeeds does `SimulationFrame` publish typed
  structural events.
- Extra required event capacity can be preflighted before side effects that
  need domain-reaction events in the same step.
- After publication the state calls `SimulationPipeline.syncPopulationCapacity`
  (main thread, outside `stage_order`). It is an O(1) compare of committed row
  counts against tracked logical capacities, and on growth a geometric
  (`rows + rows/2 + 16`, hot-store aligned) re-reserve of every
  population-sized pipeline capacity, frame stream, the event bound, and the
  pathfinding elastic pools. It is the only population growth point. Each frame
  stream reserves the range count its writers can produce at the tracked
  population: `navigation_intents` the `ai_decide` ranges, `intents` and
  `path_requests` steering's avoidance ranges (`steeringStreamRangeCount`), and
  `structural_commands` the tier-policy ranges, one destructible range, and one
  per `structural_headroom` event. The
  contact-dependent capacities (`frame.contacts`, `frame.collision_triggers`, the
  collision-response intents, band order, trigger pairs, observer contacts, and
  gather-range staging) are reserved in
  `SimulationPipeline.reserve`, which the seam re-runs, to the collision pair bound
  (`CollisionSystem.estimateContactCapacity`: 4 candidate pairs per body of capacity,
  the bound the collision stores use; each broadphase range slot is prepared at 4 pairs per
  item its range covers). A step past it in total grows them on the main thread
  with identical output and is counted once (`collision_pair_bound_exceeded`);
  a range past its slot grows that slot and replays the dispatch, counted in
  its set's `prepare_grows` and `replays`.

This keeps partial structural mutations from leaking when validation or event
capacity fails.

## Post-Commit Reactions

The commit seam (`SimulationPipeline.commitStructuralAndReact`, called from
`GameDemoState`) runs, in order: `reserveStaticColliders` (collider rows and
static nav marks, before the commit), the budgeted commit,
`captureStaticColliderChanges` (the step's entity changes into the collider's
persistent dirty list), `syncPopulationCapacity`, `syncStaticColliders` (run
even when the growth seam failed, so the step's static changes land and reach
nav; it records their nav marks), then the post-commit nav reaction:

- `reactToPostCommitNavEvents` delegates to `PathfindingSystem`, which applies
  every pending nav change (marks the terrain writers and the collider sync
  recorded, and the world's level, link, and content-revision gaps) as one
  transaction per step and emits one `nav_region_invalidated` when the graph
  changed. It runs only after a successful growth seam and collider sync; else
  every mark stays for the next step.

Steering has no post-commit reaction. It reads the synced collider rows on its
own step, so a static change rebuilds nothing steering-side, a growth or nav
failure still leaves it on the committed statics, and a failed collider sync
keeps it on the pre-commit rows and keeps its changes for the next step's sync.
Perception has no reaction: line of sight reads the world's chunk terrain
directly.

Nav, the static-collider splice, and the terrain edit stages take their range
controls as one `StageControls` each (`PathfindingSystem.nav_controls`,
`StaticColliderSystem.splice_controls`, `TerrainEditThreads.controls`), like every
other threaded stage; production leaves them at their defaults.

## Current Integration

`GameDemoState` owns app/state boundaries around `SimulationFrame` and
`SimulationPipeline`. It:

- starts each fixed step with `beginStep()`;
- writes player input and audio commands at the main-thread boundary;
- delegates reusable fixed-step systems and stage order to `SimulationPipeline`;
- applies structural commands at the fixed-step commit boundary and runs the
  commit seam above (collider sync, population seam, and the nav reaction);
- reserves renderer command capacity after structural commits and before render
  submission.

New behavior is a pipeline-owned controller or SoA processor reached through
`stage_order`; `GameDemoState.update` and `SimulationPipeline.update` (an
`inline for` over `stage_order`) take no per-feature logic.

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

Tests for this module prove the stream contracts directly:

- range streams merge in stable range order;
- range writers write the declared count;
- appended ranges preserve existing merged data;
- event stats are deterministic by type and stage;
- capacity overflow distinguishes required events from diagnostic drops;
- structural command commits publish events only after successful `DataSystem`
  mutation;
- no test-only payload tags or fake stages in production contracts
  (`.grok/rules/tests-benchmarks.md`).

The pipeline's threaded-profile tests pin every stage tuner through a comptime
walk of `SimulationPipeline`'s fields (`pinPipelineThreadedProfiles`): a tuner
behind a slice, many-item pointer, error union, or union fails the build, so a new
tuner cannot be missed.
