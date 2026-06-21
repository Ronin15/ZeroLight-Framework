# Simulation Tiers And Pipeline

This document describes how world-scale simulation should scale without
rewriting the existing processor stack. It is the design source of truth for
extracting `SimulationPipeline`, adding `SimulationScope`, and applying
simulation tiers on top of Slice 12's `SimulationFrame` contracts.

Related docs:

- [architecture.md](architecture.md) for current frame flow and processor boundaries.
- [framework-implementation-slices.md](framework-implementation-slices.md) for
  Slice 22 implementation tracking.

## Goal

Support thousands of entities across one world or multiple worlds while keeping
typical fixed steps far below the 60 Hz budget. Processors stay fast; policy
decides **which entities run which stages each step**.

Benchmarks at 50k scale are a **throughput ceiling**, not a per-frame target.
Normal gameplay should scope work to active regions and tiers so most steps only
touch hundreds or low thousands of entities. If a rare spike does process a
large active set, release benchmarks show the processor stack can absorb it.

## Design Principle

Use **one ordered pipeline** and **scoped inputs**, not separate sim loops or a
global scheduler.

| Concept | Answers |
|---------|---------|
| **Simulation tier** | What fidelity does this entity get when it is active? |
| **Simulation scope** | Which entities are active this fixed step? |
| **Simulation pipeline** | In what order do stages run, and what are the budgets? |
| **Processors** | Hot SoA work over slices gathered from scope |

Tiers filter membership. The pipeline owns stage order. Processors remain mostly
stateless and do not know about worlds, chunks, or cameras.

## Ownership

- `StateStack` still owns state lifetimes, policies, and dispatch.
- A gameplay state owns persistent `DataSystem`, processor instances, and one
  state-owned `SimulationPipeline` per simulation instance.
- `SimulationPipeline` owns phase order, per-step budgets, domain-controller
  composition, and calling processors with scoped views.
- `SimulationScope` is pipeline-owned transient data rebuilt every fixed step.
- `DataSystem` stores persistent facts, including cold tier/chunk metadata.
- `SimulationFrame` stores per-step typed streams and deferred structural
  commands.
- `Engine` does not become a world scheduler.

Planned source layout:

- `src/game/simulation_pipeline.zig` — `SimulationPipeline`, stage order, budgets.
- `src/game/simulation_scope.zig` — `SimulationTier`, `SimulationScope`, `ActiveRegion`.
- `src/game/simulation.zig` — unchanged role for `SimulationFrame`, phases, streams.
- `src/game/systems/*.zig` — processors; add scoped gather entry points where needed.

## Simulation Tiers

Tiers are persistent membership levels. They describe capability, not whether
an entity is loaded or visible.

```text
dormant     -> entity exists; excluded from scope unless a wake rule applies
kinematic   -> movement integration only
locomotion  -> movement + collision detect/response
cognition   -> locomotion + AI + steering + path requests
```

### Cold metadata

Store tier and world/chunk identity on cold `EntitySlot` metadata or an
equivalent compact enum column. Do **not** put tier or chunk ids in hot movement
SoA columns unless profiling proves otherwise.

Optional stagger data can live on the slot too, such as `stagger_bucket =
entity.index % k`, so expensive cognition can spread across steps without a
second pipeline.

### Stage requirements

The pipeline keeps today's processor order. Tiers only shrink stage inputs.

| Stage | Minimum tier | Notes |
|-------|--------------|-------|
| Scope build | — | active world/chunks, wake rules, stagger gates |
| Main-thread player input | — | always runs |
| AI | cognition | optional stagger |
| Steering | cognition | consumes navigation intents and path status |
| Pathfinding | cognition | global per-step budget |
| Apply movement intents | cognition | main-thread sparse velocity writes |
| Movement integration | kinematic | |
| Bounds clamp | kinematic | player special-case stays explicit |
| Collision detect | locomotion | |
| Collision response | locomotion | |
| Particles / domain reactions | policy | usually near-player only |
| Structural commit | — | end of step |

Processors should not reorder this contract. Controllers and events may request
tier changes, but mutation commits at the existing deferred structural boundary.

## Simulation Scope

`SimulationScope` is built once per fixed step on the main thread before
processor dispatch.

Inputs:

- `ActiveRegion` — current world, active chunks, and optional halo chunks for
  cross-boundary collision or cognition.
- persistent tier/chunk metadata from `DataSystem`
- `step_index` for stagger and low-cadence tiers

Outputs:

- per-tier entity gather lists or dense index subsets used by scoped gather paths
- optional stats: counts per tier, stagger skips, wake promotions

Scope rules:

1. Entity must be alive and in an active chunk/world (or halo rule) to enter scope.
2. Entity tier must meet the stage minimum.
3. Cognition may also require stagger gate pass: `(step_index + stagger_bucket) % period == 0`.
4. Distant entities may run at reduced cadence by entering scope only every N steps
   while staying at a lower tier between runs.

Processors receive already-filtered gathers:

```text
// today
collision.update(data, contacts, thread_system, config)

// scoped
collision.updateScoped(data, &scope.locomotion, contacts, thread_system, config)
```

The scoped path should share the same hot loop and merge rules as the full gather.

## Simulation Pipeline

`SimulationPipeline` moves the ordered sequence currently inlined in
`GameDemoState.update` into a reusable state-owned helper.

Responsibilities:

- drive `SimulationPhase` on `SimulationFrame`
- build `SimulationScope`
- run gated stages in deterministic order
- enforce per-step budgets (path requests, cognition count, stream capacities)
- compose lightweight domain controllers between stages when needed
- apply main-thread intent writes and structural commits

Non-responsibilities:

- global cross-state scheduling
- dynamic dependency graphs or string-topic dispatch
- renderer, audio device, or GPU resource ownership
- storing persistent gameplay facts outside `DataSystem`

Target call shape:

```text
GameDemoState.update(ctx)
  -> pipeline.runStep(&data, .{ .thread_system, .delta_seconds, .active_region, ... })
```

`GameDemoState` keeps domain setup, render, pause sync, and audio reactions until
those move behind controllers or simulation events.

## Multi-World And Chunk Policy

World-scale simulation is mostly a **scope** problem.

- **Other worlds/maps:** entities may exist in storage but stay out of
  `SimulationScope` until that world/instance is active.
- **Same world, distant chunks:** entities remain loaded at `dormant` or
  `kinematic`, or run on a reduced cadence.
- **Near camera / active chunks:** entities promote to `locomotion` or
  `cognition` as gameplay requires.
- **Chunk halos:** include neighbor chunks in scope for cross-boundary collision
  and limited cognition handoff.

Partitioned navigation grids, portal edges between chunks, and pathfinding
budgets remain separate concerns, but scope decides which agents may request
paths this step.

## Tier Transitions

Tier changes are policy, not processor side effects.

Allowed sources:

1. **Spatial policy** — entered or left active chunk halo.
2. **Domain controllers** — combat, spawning, sleep, encounter state.
3. **Simulation/domain events** (Slice 21) — `ChunkEntered`, `WakeRequested`,
   `NavRegionInvalidated`, and similar typed signals.

Apply tier changes through deferred structural commands or an explicit
main-thread commit at the end of the step. Processors must not mutate tier
metadata mid-range.

## Benchmarks And Budget Posture

CPU benchmarks prove processor throughput at stress scale. They do not imply
that every fixed step should run every stage on 50k entities.

Interpretation:

- **Typical frame:** active scope in hundreds to low thousands; sub‑ms to a few
  ms of CPU sim is the expected operating point.
- **Stress ceiling:** isolated processor sums at 50k remain useful regression
  guards and spike-absorption proof.
- **Pathfinding:** keep hard-path and cache behavior bounded (Slice 20) even when
  cognition scope is small.
- **Rendering:** culling and render prep remain outside this document; GPU cost
  may dominate before CPU sim does.

## Relationship To Other Slices

| Slice | Relationship |
|-------|----------------|
| 12 | `SimulationFrame`, streams, deferred structural commits remain the per-step contract. |
| 20 | Pathfinding budgets and fixed-capacity cache contracts protect cognition-heavy scopes. |
| 21 | Typed events/controllers promote, demote, or wake entities; pipeline owns reaction order. |
| 7 | Parallel render prep and visibility culling complement scoped simulation. |

Suggested implementation order:

1. Extract `SimulationPipeline` with today's full active set (all entities treated as `cognition`).
2. Add `SimulationScope` that initially includes every alive entity.
3. Add cold tier/chunk metadata and filtered scoped gathers.
4. Add stagger, reduced cadence, and multi-world `ActiveRegion` rules.
5. Wire Slice 21 events and controllers into tier transitions.

## Explicit Non-Goals

- No app-wide entity manager or global simulation scheduler.
- No pub/sub bus, callback chains, or pointer-bearing event payloads.
- No per-entity behavior copies in the pipeline; hot work stays in processors.
- No requirement that all loaded entities receive cognition every step.
- No preemptive processor rewrites solely for scale; scope and orchestration come first.

## Acceptance Themes

Slice 22 is complete when the following are integrated with tests and docs:

- `GameDemoState` delegates fixed-step processor order to `SimulationPipeline`.
- Scoped and unscoped processor paths produce identical results for the same entity set.
- Tier and chunk filtering changes which entities enter each stage without changing stage order.
- Tier changes commit only through the deferred structural boundary.
- Benchmarks or debug stats can report scope counts by tier and stage.
- Typical scoped runs remain allocation-free on the hot path after reserve/warmup.
