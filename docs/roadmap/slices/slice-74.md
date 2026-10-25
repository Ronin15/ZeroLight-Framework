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
- The commit seam's order lives in
  `SimulationPipeline.commitStructuralAndReact`
  (`src/game/simulation_pipeline.zig:1358`: collider reserve, structural
  commit, collider capture, population sync, collider sync, nav reaction,
  steering reaction); `GameDemoState` calls it from
  `applyStructuralCommandsAndPostCommitEvents`
  (`game_demo_state.zig:633-634`).
- Measured at HEAD (`8eaa19a`), `world-create` (Debug, `zig build bench --
  --group world-create --details`, warmup 5, 30 iterations, one run; tuned
  case `settled=fresh`):
  - Total tuned 7.19 / 30.83 / 98.36 ms at 256² / 1024² / 2048² × 8 levels
    (serial 11.56 / 89.33 / 341.36 ms), of which the nav phase is 4.27 / 21.34
    / 70.34 ms; 13.13 / 36.26 ms at 32 / 128 levels of 256². Time and bytes are
    at most linear in level area × levels, and 0 bytes stay live after destroy.
  - Nav-phase live bytes (`live_kb` nav less stack; the nav phase is
    `SimulationPipeline.init`: static colliders, nav build, and each
    processor's init): 5,529 KB at 256² × 8, 7,408 KB at 1024² × 8, 13,015 KB
    at 2048² × 8, 5,718 KB at 256² × 32, 6,476 KB at 256² × 128; cause of the
    floor not identified.
  - The nav build gains less than the paint: nav phase 70.34 ms tuned against
    121.12 ms serial at 2048² × 8, with `nav_main` 61.56 ms (88% of the
    phase), while the surface paint goes 214.83 → 21.85 ms. The bench reports
    `nav_main` and asserts the nav build's remask ran on workers
    (`world_create.zig:17-31`); `nav_reaction.zig:116` keeps the rebuild
    result only as `perf.last_nav_build` under the perf switch.

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
- Creating a world in play is never refused for capacity; 64G retired the
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
- [ ] Per-step passes batch across world instances: one dispatch per pass
      over every world's rows, not one per world, so a small world's pass
      shares a batch set with the others. Gated on multi-world stepping in the
      pipeline (none exists today). Failure scenario: per-world dispatches
      each pay the tuner's gate and wake floor, so many small worlds thread
      little or not at all. Pass: a bench at three or more world counts with
      dispatches per pass flat in worlds, results independent of world count
      per dispatch and of worker count (`.claude/rules/threading.md`).
- [ ] The observer (camera focus, or a player when present) and presentation
      bound to the viewed world; a mini view may show another world
      (`.claude/rules/render.md`); worlds in no view step without
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
      maintenance cost (`.claude/rules/budgets-capacities.md`), never a
      world-wide rebuild.
- [ ] The commit-seam order moves out of the demo state into the per-world
      step, so every world (and any second gameplay state) runs the same
      order. Failure scenario (derived): a stepper that reorders the seam's
      calls desyncs the collider or nav sync. The pipeline test fixture
      `commitAndSyncLikeDemo` (`src/game/simulation_pipeline.zig:3136-3151`) copies
      the seam step by step, so a reorder of the demo seam leaves every
      growth, OOM, and nav-seam pipeline test passing on the old order. The
      steering fixture `commitStaticsForTest`
      (`steering/test_support.zig:102-116`) is a second copy (collider
      reserve, commit, capture, sync), so the multi-level and static-move
      avoidance tests and the steering cache-invalidate test
      (`avoidance.zig:546`, `:680`; `system.zig:879`) also pass on the old
      order (code audit M3;
      `.claude/rules/tests-benchmarks.md` § Tests). Both fixtures call the
      moved seam once it exists.
- [ ] A world's create-time memory follows its content. Failure scenario:
      every small dungeon pays the nav phase's ~5.5 MB floor at 256² × 8
      (measured above; 6.5 MB at 256² × 128, 13.0 MB at 2048² × 8; cause not
      identified, so the first step is finding it). Pass:
      `world-create` nav-phase bytes follow what exists (group doc).
- [ ] The create-time nav build threads its per-chunk work. Reporting landed
      (`perf.last_nav_build`, bench `nav_main`, the remask-on-workers assert).
      Failure scenario: a world created in play spends most of its nav build
      on main: `nav_main` is 61.56 of 70.34 ms nav at 2048² × 8 (measured
      above). Pass: `world-create` shows the nav phase's main share as the
      ordered merge only; serial == threaded.
- [ ] `production-step` spawns through production functions (code audit L4).
      Partly landed (`0843bdb`): `spawnPopulation`
      (`src/benchmarks/production_step.zig:339-420`) places each mover through
      `placeSpawnedMover` (`game_demo_state.zig:955`), which `spawnDemoMover`
      (`:879`) shares. Failure: it commits through
      `DataSystem.applyStructuralCommands` outside the commit seam (`:377`),
      syncing only the population seam (`:398`), and the `stacked` shape
      writes `always_active` and `stagger_phase` itself (`:386-387`)
      (`.claude/rules/tests-benchmarks.md` § Tests). Failure scenario: a
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
      (`.claude/rules/tests-benchmarks.md`).
- [ ] Manual (display, Debug): a second world created in play steps beside
      the first while only one is viewed, then is destroyed and its memory
      returns.
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
