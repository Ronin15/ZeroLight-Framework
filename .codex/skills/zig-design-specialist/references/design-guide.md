# Zig Systems Design Guide

Use this reference for DOD-oriented gameplay and engine-system designs in this
repo. Keep the final design compact, but make the decisions below explicit.

## Frame And State Flow

- Preserve the runtime flow: `main.zig` owns the outer loop, calls `Engine`
  phase methods, and does not call gameplay state methods directly.
- `Engine` owns app coordination for events, pause/frame policy, update/render
  contexts, renderer/resources, debug overlay, transitions, and thread-system
  access.
- `StateStack` owns state lifetimes, state policies, transition application, and
  policy dispatch to the eligible state or states.
- A normal gameplay state is usually the only update target, but modal and
  overlay policies can let lower states receive events, updates, or rendering.
- New designs should keep gameplay behavior in states or processors, not in
  `main.zig` or broad `Engine` conditionals.
- Rendering designs should treat `RenderQueue` as the transient ordering phase
  for records from world, effects, UI, and debug producers. `Renderer` and
  `SpriteBatch` consume already ordered commands; do not design fallback sorting
  inside the renderer to hide producer-order bugs.

## Simulation Pipeline And Controllers

Use this hierarchy when a design spans multiple gameplay systems:

- `StateStack` dispatches states and owns state lifetimes.
- A gameplay state owns its `DataSystem`, `SimulationFrame`, and optional
  `SimulationPipeline` instance.
- `SimulationPipeline` owns the ordered fixed-step stages for that gameplay
  state and composes any light domain controllers.
- Domain controllers orchestrate feature policy: phase order, budgets, queues,
  cooldowns, priority/conflict rules, and handoff between processors.
- Systems/processors do hot or reusable data work over typed `DataSystem` SoA
  slices and emit deterministic `SimulationFrame` outputs or deferred commands.

Introduce a `SimulationPipeline` when several gameplay states or simulation
instances need the same ordered processor flow, or when a single state update is
becoming mostly orchestration. Keep the pipeline state-owned; do not promote it
into a global ECS scheduler, reflection system, dynamic dependency graph, or
app-level service.

Controllers may own small feature-local queues, budgets, cooldowns, transient
scratch, and arbitration rules. They should not become hidden per-entity stores,
own renderer/audio/SDL handles, hide random choices, or replace SoA processors
for hot loops. Persistent gameplay/domain facts live in `DataSystem` or
state-owned domain storage; per-step outputs live in `SimulationFrame`.

## Data Ownership

- `DataSystem` owns persistent gameplay data for the owning gameplay state:
  entity IDs, generations, component masks, and dense typed SoA stores.
- Component masks are membership/query data. They are not a substitute for
  direct slice iteration in hot processors and should not create dynamic joins.
- State-owned transient systems, such as particles, can own fixed-capacity SoA
  pools when the data is visual effect state rather than persistent world state.
- Keep SDL handles, GPU handles, live renderer texture IDs, text leases, asset
  loading state, input frame state, thread-system state, events, and scratch
  buffers outside persistent `DataSystem` storage.
- Save/load designs should stream persistent gameplay data and stable asset
  references, not app services, renderer resources, thread objects, or frame
  commands.
- Runtime gameplay and render-prep data should carry stable asset IDs such as
  `SpriteAssetId` and `AudioAssetId`; path validation, PNG decode, GPU upload,
  audio load/predecode, and string lookup belong in asset/app services.
- Transient render queues may carry renderer-facing handles after `RuntimeAssets`
  resolution, but persistent gameplay storage should keep stable asset IDs and
  enum render-depth intent instead of live renderer handles or raw layer numbers.

## Processor Contracts

- Systems are mostly stateless processors over `DataSystem` slices plus explicit
  runtime services such as `ThreadSystem`.
- Define each processor's reads, writes, output buffers, and order relative to
  other processors. Later processors must see completed output from earlier
  processors.
- For threaded processors that produce high-volume events, intents, contacts, or
  deferred structural commands, define stable input order, range ownership,
  merge order, allocation policy, and structural apply point. Prefer typed
  range-owned output buffers with count/prefix/write collection over global
  per-command append or callback-style event buses.
- Keep structural entity/component changes out of worker ranges. Use a deferred
  main-thread command boundary when a processor needs to request creation,
  removal, state transitions, asset loading, save/load, or renderer ownership
  changes.
- Keep a serial path for small batches, tests, unsupported thread targets, and
  deterministic comparison.
- If a processor emits events or intents, define whether they are persistent
  state, transient per-frame data, or deferred commands, and where they merge.
- If a gameplay/render-prep processor emits draw records, define the final
  `RenderOrder`, queue ownership, allocation/reserve policy, and whether records
  are sorted, bucketed, or emitted in already ordered spans before `Renderer`
  submission.

## Hardware And Hot Paths

- Hot data should be scalar SoA columns with explicit alignment before SIMD or
  threaded processing depends on that layout.
- Worker ranges should write disjoint rows and avoid sharing writable cache
  lines in hot SoA columns. Use 64-byte padding only for concurrently written
  thread-shared records where false sharing is a real risk.
- Deterministic output order should come from stable input or range order, not
  worker timing or worker IDs. When output volume can be large, collect counts
  per range, prefix offsets, write contiguous typed output, then merge by range
  index before any batch commit.
- Move allocation, string lookup, hash-map lookup, descriptor validation,
  resource creation, and formatted logging out of per-frame, per-event,
  per-draw, and fixed-step processor loops unless measured and bounded.
- Use enums, bitsets, dense indices, direct slices, ring buffers, stable handles,
  and generational IDs for runtime dispatch and lookup.
- Treat thread-system thresholds as heuristics until representative workloads
  prove them. Designs should say what metrics or tests would reveal bad
  scheduling choices.
- For SDL_GPU rendering, keep CPU prep and worker expansion outside the acquired
  swapchain interval where possible. Designs should keep swapchain acquisition,
  upload, render-pass encoding, and submit tightly scoped on the render thread.

## Emergent Gameplay Design

- Prefer composable data and ordered processors over object-specific behavior
  copies. Player-specific facades can exist, but enemies, hazards, pickups, and
  world objects should normally be plain entities processed by systems.
- Collision and spatial-query designs should produce deterministic contact or
  query results before gameplay response processors consume them.
- AI, pathfinding, and rule systems should usually emit movement intents,
  steering outputs, target choices, or deferred commands rather than mutating
  unrelated stores directly.
- AI/perception, pathfinding, and rule processing should be designed as bounded
  stages with explicit inputs, outputs, timing visibility, tuning policy, and
  deterministic merge points. Pick the spatial, perception, or graph structure
  that fits the workload instead of copying today's processor shape.
- Deterministic randomness, if needed, should be explicit state or an explicit
  service passed through the processor boundary. Do not hide random choices in
  hot processors.
- Emergent behavior still needs bounded contracts: define priority, conflict
  resolution, ordering, and what happens when several systems request
  incompatible outcomes.

## Roadmap Slice Shape

For roadmap updates, use compact sections:

- Goal
- Current foundation
- Architecture notes
- Checklist
- Acceptance checks

Do not rewrite completed slices to tell history. Preserve completed work, add
the next finishable feature slices, and keep open work honest. A slice is only
complete when runtime behavior, diagnostics, docs, tests, and acceptance checks
are integrated.
