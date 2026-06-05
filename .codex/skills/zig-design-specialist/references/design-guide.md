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

## Processor Contracts

- Systems are mostly stateless processors over `DataSystem` slices plus explicit
  runtime services such as `ThreadSystem`.
- Define each processor's reads, writes, output buffers, and order relative to
  other processors. Later processors must see completed output from earlier
  processors.
- Keep structural entity/component changes out of worker ranges. Use a deferred
  main-thread command boundary when a processor needs to request creation,
  removal, state transitions, asset loading, save/load, or renderer ownership
  changes.
- Keep a serial path for small batches, tests, unsupported thread targets, and
  deterministic comparison.
- If a processor emits events or intents, define whether they are persistent
  state, transient per-frame data, or deferred commands, and where they merge.

## Hardware And Hot Paths

- Hot data should be scalar SoA columns with explicit alignment before SIMD or
  threaded processing depends on that layout.
- Worker ranges should write disjoint rows and avoid sharing writable cache
  lines in hot SoA columns. Use 64-byte padding only for concurrently written
  thread-shared records where false sharing is a real risk.
- Move allocation, string lookup, hash-map lookup, descriptor validation,
  resource creation, and formatted logging out of per-frame, per-event,
  per-draw, and fixed-step processor loops unless measured and bounded.
- Use enums, bitsets, dense indices, direct slices, ring buffers, stable handles,
  and generational IDs for runtime dispatch and lookup.
- Treat thread-system thresholds as heuristics until representative workloads
  prove them. Designs should say what metrics or tests would reveal bad
  scheduling choices.

## Emergent Gameplay Design

- Prefer composable data and ordered processors over object-specific behavior
  copies. Player-specific facades can exist, but enemies, hazards, pickups, and
  world objects should normally be plain entities processed by systems.
- Collision and spatial-query designs should produce deterministic contact or
  query results before gameplay response processors consume them.
- AI, pathfinding, and rule systems should usually emit movement intents,
  steering outputs, target choices, or deferred commands rather than mutating
  unrelated stores directly.
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
