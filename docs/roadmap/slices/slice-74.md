## Slice 74: World Instances

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md), [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 75](slice-75.md) · Track: standalone (engine core; [Target Model](../../architecture.md#target-model))

**Status: not started.**

Goal: world instances (persistent worlds, temporary dungeons) are created,
stepped, and destroyed in play. Each world owns all its storage (chunked
terrain and nav, entities, pipeline state, per-step scratch) and releases it
on destroy; every existing world steps each fixed step whether or not the
observer is in it; entities (NPCs, and a player when present) move between
worlds; nothing is shared, capped, or sized across worlds
(`.grok/rules/budgets-capacities.md`, `docs/architecture.md` § Target
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
  `WorldLevelOverflow`) and keeps one append-only `level_links` list indexed per
  endpoint chunk (64G); nav builds an added level from its own chunks and keeps
  connectivity and the one-way closure exact per batch (64G). No path destroys a
  level: a level build's replace is the only release.
- Render: each world has its own renderer-owned GPU tile store under a
  generational id the world claims every frame it renders
  (`Renderer.claimTileStore`); `endFrame` retires a store nobody claimed, so a
  destroyed or replaced world's store is released at the first frame its world
  does not render, with no game-side release call.
- No load-time check refuses a world: 64G deleted the nav memory gate, band
  lists grow, the GPU store keeps only the render window, and ids that grow in
  play fail only as `OutOfMemory` at their growth seam.
- The commit seam's order lives in the demo state:
  `commitStructuralAndReact` (`src/game/game_demo_state.zig:675`) orders the
  structural commit, population sync, collider sync, and nav and steering
  reactions.
- Measured, `world-create` tuned (Debug, `5d5a089`):
  - 10.3 / 44.9 / 141.7 ms at 256² / 1024² / 2048² × 8 levels, of which the
    nav phase is 7.5 / 35.3 / 117.5 ms; 10.3 / 16.1 / 34.7 ms at 8 / 32 / 128
    levels of 256². Time and bytes are at most linear in level area × levels,
    and 0 bytes stay live after destroy.
  - The nav phase (`SimulationPipeline.init`: static colliders, nav build, and
    each processor's init) holds about 12.4 MB at 256² × 8 and about 18.9 MB at
    2048² × 8; cause not identified.
  - The nav build barely gains from workers: 117.5 ms tuned against
    127.9 ms serial at 2048² × 8, while the surface paint goes 182.7 →
    18.1 ms. Its batches are not exposed (`nav_reaction.zig:113` discards the
    rebuild result), so its main share is unmeasured.

### Architecture notes

- Owner direction (2026-10-08): worlds are created and destroyed in play and
  own their storage; everything in every world keeps advancing
  (`.grok/rules/engine-design.md` § Target scale).
- The world set and its stepping live in gameplay (`src/game/`), never in
  `main.zig` or `Engine` conditionals; `SimulationPipeline.update` stays each
  world's only fixed-step scheduler (`.grok/rules/engine-design.md`
  § Ownership boundaries, `.grok/rules/simulation.md`).
- Creating a world costs its own content; destroying it releases what it
  held; a step costs the sum of each world's work, never world count ×
  extent. No global or cross-world tables or caps
  (`.grok/rules/budgets-capacities.md`).
- Independent worlds step through the thread system with a serial path and a
  fixed merge order; no result depends on worker count or the order worlds
  finish (`.grok/rules/threading.md`, `.grok/rules/simulation.md`
  § Determinism). Under 50's reentrancy decision a batch nested in a job runs
  inline, so the design pass chooses where parallelism lives (across worlds,
  within each world, or both) with a cost model for each.
- A world created in play is deterministic from the session seed and the
  step that created it (49's seed domains and `StepIndex`).
- Create and destroy are structural: applied at a seam between steps,
  all-or-fail; OOM leaves every world intact for retry.
- Destroying a world never hands renderer, audio, or GPU services to
  gameplay teardown; its GPU resources are released per world through the
  render boundary (`.grok/rules/engine-design.md` § Ownership boundaries).
- Presentation (render prep, audio, camera) follows the viewed world; worlds
  without a viewer run simulation only.
- Creating a world in play is never refused for capacity; 64G retired the
  level-sized load gates (dense GPU budget, nav memory), and no platform check
  refuses a world (`.grok/rules/budgets-capacities.md`).
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
      bound to the viewed world; a mini view may show another world
      (`.grok/rules/render.md`); worlds in no view step without
      presentation at 75's lowest band.
- [ ] Entities (NPCs, and a player when present) move between worlds at a
      between-step seam.
- [ ] Per-world GPU resource release through the render boundary, replacing
      the renderer-wide release.
- [ ] Level destroy in play (moved from 64G): a level's terrain, nav, and
      render storage released, flat across depth and linear in its own
      chunks.
- [ ] Level destroy keeps reachability exact at its own cost: the level's
      connectivity nodes, components, terminals, and closure blocks go with it,
      and the connections its links carried are removed at the reachability
      maintenance cost (`.grok/rules/budgets-capacities.md`), never a
      world-wide rebuild.
- [ ] The commit-seam order moves out of the demo state into the per-world
      step, so every world (and any second gameplay state) runs the same
      order. Failure scenario (derived): a stepper that reorders the seam's
      calls desyncs the collider or nav sync. The pipeline test fixture
      `commitAndSyncLikeDemo` (`pipeline_test_support.zig:535-553`) copies
      the seam step by step, so a reorder of the demo seam leaves every
      growth, OOM, and nav-seam pipeline test passing on the old order. The
      steering fixture `commitStaticsForTest`
      (`steering/test_support.zig:95-107`) is a second copy (collider
      reserve, commit, capture, sync), so the multi-level and static-move
      avoidance tests and the steering cache-invalidate test
      (`avoidance.zig:546`, `:680`; `system.zig:879`) also pass on the old
      order (code audit M3;
      `.grok/rules/tests-benchmarks.md` § Tests). Both fixtures call the
      moved seam once it exists.
- [ ] A world's create-time memory follows its content. Failure scenario:
      every small dungeon pays the nav phase's ~12.4 MB floor (measured
      above; cause not identified, so the first step is finding it). Pass:
      `world-create` nav-phase bytes follow what exists (group doc).
- [ ] The create-time nav build reports its batches and threads its
      per-chunk work. Failure scenario: a world created in play spends most of
      its nav build on one thread (measured above). Pass: `world-create`
      shows the nav phase's main share as the ordered merge only; serial ==
      threaded.
- [ ] `production-step` spawns through production functions (code audit L4).
      Failure: `spawnPopulation`
      (`src/benchmarks/production_step.zig:220-280`) repeats
      `spawnDemoMover`'s post-create steps (`snapZ` and the metadata write,
      `:264-269`; `game_demo_state.zig:1008-1014`) and commits through
      `DataSystem.applyStructuralCommands` outside the commit seam (`:258`),
      syncing only the population seam (`:279`)
      (`.grok/rules/tests-benchmarks.md` § Tests). Failure scenario: a
      change to the spawn defaults or the seam order drifts the census with no
      failure. Pass: the bench sets no post-create field itself; it calls the
      production function that does, and commits through the moved seam.
- [ ] Per-world state classified for 49/64B; included in 46's v1.
- [ ] Tests: create, step, and destroy leak nothing; an entity moved
      between worlds keeps its identity as designed; one world's step is
      unchanged by other worlds existing; a world the observer is not in
      advances; serial equals threaded across worlds; OOM during create leaves the set intact and the retry
      succeeds; destroy releases only that world's GPU resources.
- [ ] Bench `world-instances`: create, destroy, and step cost at three or
      more world counts and sizes; level destroy at three depths.
- [ ] Docs: `docs/architecture.md` world set, ownership, step order;
      `docs/simulation-tiers-and-pipeline.md` stepping several worlds.

### Acceptance checks

- [ ] `world-instances` matches the cost model: create and destroy follow the
      world's own content, and one world's step cost is flat in world count
      (`.grok/rules/tests-benchmarks.md`).
- [ ] Manual (display, Debug): a second world created in play steps beside
      the first while only one is viewed, then is destroyed and its memory
      returns.
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
