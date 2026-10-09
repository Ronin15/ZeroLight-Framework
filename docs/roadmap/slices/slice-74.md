## Slice 74: World Instances

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md), [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 75](slice-75.md) · Track: standalone (engine core; [Target Model](../../architecture.md#target-model))

**Status: not started.**

Goal: world instances (persistent worlds, temporary dungeons) are created,
stepped, and destroyed in play. Each world owns all its storage (chunked
terrain and nav, entities, pipeline state, per-step scratch) and releases it
on destroy; every existing world steps each fixed step whether or not the
observer is in it; entities (NPCs, and a player when present) move between
worlds; nothing is shared, capped, or sized across worlds
(`.claude/rules/budgets-capacities.md`, `docs/architecture.md` § Target
Model).

### Current foundation

One world per gameplay state; nothing models a set of worlds.

- `GameDemoState` (`src/game/game_demo_state.zig`) owns exactly one
  `world: WorldSystem`, `data: DataSystem`, `pipeline: SimulationPipeline`,
  `simulation_frame`, `player`, `particles`, `scene_prep`, and camera pair;
  `LoadingState.loadGameDemo` builds it synchronously before play.
- `Engine.update` → `StateStack.update` → `GameDemoState.update` steps that
  one world per fixed step; the `ThreadSystem` is Engine-owned and reaches it
  through `UpdateContext`.
- `SimulationPipeline` already holds every per-world processor and
  controller (pathfinding, scope, spatial index, perception, AI, dig,
  destructible, audio controller) with its own tuners;
  `SimulationPipelineUpdateContext` borrows one `data`, `world`, `player`,
  and `frame`.
- Single-world assumptions: `simViewRegion` anchors scope at
  `context.player.current_level` and `GameDemoState.simViewRect()` is the one
  camera; the dig controller, footsteps, perception's player candidate, and
  audio key off the one `player.entity`; the step counter
  (`SimulationScopeSystem.currentStep`) lives in each pipeline.
- No world identity exists in `src/`; `EntityId` is a slot + generation
  inside one `DataSystem`.
- `WorldSystem` adds levels at runtime (`addLevel`, `u16` index,
  `WorldLevelOverflow`) and keeps one world-wide `level_links` list (64G moves
  links into their chunks).
- Render: each world has its own renderer-owned GPU tile store, released by
  id (`Renderer.releaseTileStore`); nothing in game code releases it, so a
  world's store lives until `Renderer.deinit`.
- Load-time checks that refuse: `NavMemoryBudget.check` (`NavWorldTooLarge`
  at `max_nav_memory_bytes`). `DenseLayerWindowExceeded` still refuses
  world creation past `k_max_dense_submit_stack_cap` or
  `max_dense_bands_per_level`, and `addDenseLayer` past
  `max_dense_bands_per_level` or `world_terrain.max_level_bands` (64G owns the
  fix).

### Architecture notes

- Owner direction (2026-10-08): worlds are created and destroyed in play and
  own their storage; everything in every world keeps advancing
  (`.claude/rules/engine-design.md` § Target scale).
- The world set and its stepping live in gameplay (`src/game/`), never in
  `main.zig` or `Engine` conditionals; `SimulationPipeline.update` stays each
  world's only fixed-step scheduler (`.claude/rules/engine-design.md`
  § Ownership boundaries, `.claude/rules/simulation.md`).
- Creating a world costs its own content; destroying it releases what it
  held; a step costs the sum of each world's work, never world count ×
  extent. No global or cross-world tables or caps
  (`.claude/rules/budgets-capacities.md`).
- Independent worlds step through the thread system with a serial path and a
  fixed merge order; no result depends on worker count or the order worlds
  finish (`.claude/rules/threading.md`, `.claude/rules/simulation.md`
  § Determinism). Under 50's reentrancy decision a batch nested in a job runs
  inline, so the design pass chooses where parallelism lives (across worlds,
  within each world, or both) with a cost model for each.
- A world created in play is deterministic from the session seed and the
  step that created it (49's seed domains and `StepIndex`).
- Create and destroy are structural: applied at a seam between steps,
  all-or-fail; OOM leaves every world intact for retry.
- Destroying a world never hands renderer, audio, or GPU services to
  gameplay teardown; its GPU resources are released per world through the
  render boundary (`.claude/rules/engine-design.md` § Ownership boundaries).
- Presentation (render prep, audio, camera) follows the viewed world; worlds
  without a viewer run simulation only.
- Creating a world in play is never refused for capacity; 64G retires the
  level-sized load gates (dense GPU budget, nav memory), and no platform check
  refuses a world (`.claude/rules/budgets-capacities.md`).
- Owner decision (2026-10-08): entities (NPCs, and a player when present)
  move between worlds; what identity crosses is decided at the design pass.
- Needs from 64G: terrain, nav, and links owned per chunk, so a world is
  created and destroyed by its chunks. Needs from 49: session seed and
  `StepIndex`. Needs from 50: safe nested dispatch. Needs from 75: fidelity
  bands from the observer, whose lowest band 74 applies to every world the
  observer is not in.
- Provides: 65C generates worlds in play; 46 and 64B save and hash every
  world.

### Checklist

- [ ] World identity and a gameplay-owned world set; each world owns its
      `WorldSystem`, `DataSystem`, pipeline, and frame.
- [ ] Create and destroy at a between-step seam, all-or-fail, releasing all
      of the world's storage.
- [ ] Every world steps each fixed step, threaded across worlds with a
      serial path and a fixed merge order.
- [ ] The observer (camera focus, or a player when present) and presentation
      bound to the viewed world; other worlds step without presentation at
      75's lowest band.
- [ ] Entities (NPCs, and a player when present) move between worlds at a
      between-step seam.
- [ ] Per-world GPU resource release through the render boundary, replacing
      the renderer-wide release.
- [ ] Per-world state classified for 49/64B; included in 46's v1.
- [ ] Tests: create, step, and destroy leak nothing; an entity moved
      between worlds keeps its identity as designed; one world's step is
      unchanged by other worlds existing; a world the observer is not in
      advances; serial equals threaded across worlds; OOM during create leaves the set intact and the retry
      succeeds; destroy releases only that world's GPU resources.
- [ ] Bench `world-instances`: create, destroy, and step cost at three or
      more world counts and sizes.
- [ ] Docs: `docs/architecture.md` world set, ownership, step order;
      `docs/simulation-tiers-and-pipeline.md` stepping several worlds.

### Acceptance checks

- [ ] `world-instances` matches the cost model: create and destroy follow the
      world's own content, and one world's step cost is flat in world count
      (`.claude/rules/tests-benchmarks.md`).
- [ ] Manual (display, Debug): a second world created in play steps beside
      the first while only one is viewed, then is destroyed and its memory
      returns.
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
