## Slice 88: DataSystem, Step Contracts, Pipeline, And Core Kernels Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 87](slice-87.md)'s collect items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Owner 2026-10-16: every system on the core branch
gets a whole-subsystem pass against the cost model and the rules. This slice
covers the shared layers no other core slice owns. It runs after 87's
collect items and before the inert-row items and 75's tier mechanics, both
of which build on the storage it settles.

Goal: the persistent storage, the per-step stream contracts, the pipeline
scheduler, and the shared math and SIMD kernels every processor runs on pass
the cost model at target scale; each finding is fixed here or becomes an item
in its owning slice.

### Current foundation

- `DataSystem`: `src/game/data_system.zig` and `src/game/data_system/`
  (`system.zig` 2,890 lines, `structural.zig`, `types.zig`, and the
  component stores `movement`, `agents`, `collision`, `destructible`,
  `visual`, `faction_level`, `affect`, `memory`, `perception`). The AI stores
  (`affect`, `memory`, `perception`) are reviewed with their systems on the
  AI branch; every other store is reviewed here.
- Step contracts: `src/game/simulation.zig` (events, intents, frame streams,
  deferred structure), `src/game/faction.zig`.
- Scheduler: `src/game/simulation_pipeline.zig`: `stageContract`,
  `stage_order`, `update`, the population growth seam. 84 checks the
  contract and dispatch it touches; this slice covers the rest.
- Kernels: `src/core/simd.zig`, `src/core/math.zig`, `src/core/rng.zig`;
  logging in `src/core/logging.zig`.
- Measured (`production-step`, Debug, `5d5a089`): the main thread carries
  75–88% of the step in every config; `untimed` is 3–31% of the step (75
  adds its timers).
- Already owned elsewhere: inert rows paying every per-step pass (86, 75,
  87); the commit-seam order in the demo state (74).

### Checklist

- [ ] Every agent keeps a spread stagger phase. Landed in `5c4babb`: the
      overwrite is fixed; `stagger_phase` defaults to `keep_stagger_phase`
      (`src/game/simulation_scope.zig:15`, `:157`), so
      `setSimulationMetadata` without a phase keeps the append-assigned phase
      (tests `a simulation metadata write keeps the row's stagger phase and
      level unless it names them` and `a simulation metadata write takes the
      level from the entity's world level row`,
      `src/game/data_system/system.zig:1357`, `:1385`). Still open, the
      assignment: the append stripes `stagger_phase = dense_index %
      cognition_stagger_n` (`data_system/movement.zig:76`, n = 4,
      `src/game/simulation_scope.zig:12`), which aliases with any spawn order
      whose period shares a factor with n. The `production-step` spread
      fixture places agents round-robin over levels (`level = agent %
      fields.levels`, `src/benchmarks/production_step.zig:229`), so with 8
      levels every agent on one level gets the same phase. Measured (Debug,
      `production-step --items 1024008002048`, spread, 2,048 agents, 2,053
      rows, serial, 3 iterations, tree at `0bcaa2f`,
      `benchmark_outputs/ab-20261017-135307/tree_production-step_serial-direct_1.txt`):
      cognition-tier rows 137, `scope_ai_stage_entities=1`,
      `scope_stagger_skips=119`: the observer level's cognition lands on one
      step in four. Failure scenario: a spawner with a period such as a
      squad, a wave, or a per-level round-robin puts a whole group's
      cognition on one phase, giving the per-step spike the stagger exists to
      remove, and the `production-step` think counts that 75 and 88 cite
      describe that step. Pass: phases spread within each group that thinks
      together (level, cell), whatever the spawn order; a test with a
      spawn order whose period shares a factor with
      `cognition_stagger_n` that would fail with the index stripe
      (`.grok/rules/tests-benchmarks.md` § Tests); serial == threaded; the
      `production-step` bench samples whole stagger cycles (a sample of
      fewer steps than one cycle, such as 3 iterations < 4, depends on which
      steps it lands on) and reports per-step ai/steering max (or spread)
      and thinking per step (`--details` prints only per-stage means today,
      so a per-step spike cannot be read), so "max falls, mean unchanged" is
      checkable. Phase is the think set's one membership test
      (`cognitionJob`, `src/game/systems/simulation_scope.zig:858`, over the
      phase the index stores, `src/game/systems/spatial_index.zig:394`), so
      spreading the phases changes membership only; per-entity phases stay
      (`src/game/simulation_scope.zig:153-158`).
      Neighbor-block sharing per step then falls to agents per cell ÷
      `cognition_stagger_n` (derived: about 2.3 per key at the `ai` density,
      whose benches think every agent; `production-step`'s census reports the
      real figure).
- [ ] DataSystem hot-pass data layout (contiguity audit H5): the stores stay
      dense SoA; the stagger assignment and the cross-store reads are fixed in
      the layout (`.grok/rules/memory-performance.md` § Data-oriented
      design). Failure: every component store appends and swap-removes
      (`data_system/movement.zig:168`, `agents.zig:159`,
      `faction_level.zig:61`, `:122`), so no store is ordered by the keys
      tiered passes filter on. Tier, stagger phase, chunk, and level sit in
      the movement scope columns (the scope level is kept equal to
      `world_level`, `data_system/system.zig:944-950`); faction and
      `world_level` are separate stores (`faction_level.zig:17`, `:22`); each
      cross-store read resolves through the entity slot table
      (`data_system/system.zig:445-455`, `:756-760`). Consumers: the
      windowed threaded gathers `gatherAiData` (`systems/ai.zig:509`) and
      `gatherPerceptionData` (`perception.zig:373`), the think-set compaction
      `compactCognition` (`simulation_scope.zig:396`, which reads only index
      columns), `collisionGatherJob` and `aiGatherJob`
      (`:787`, `:816`), collision `gatherBodies` (`collision.zig:455`), the
      `world_gate` walks (`world_gate.zig:41`, `:119`), and render collect
      (87). Failure scenario (derived): with phases striped by row, each
      step's P/4 think set touches every cache line of each AI and movement
      column it reads and uses a quarter of each, plus a slot-table, faction,
      and `world_level` lookup per row; swap-remove churn scrambles phase and
      chunk order further, and the scope index lists inherit the scatter.
      Pass: each phase is a contiguous row run the think set reads in order;
      no consumer above reads another store per row outside a once-per-stage
      gather (`.grok/rules/memory-performance.md` § Data-oriented design); a
      structural command's apply cost stays independent of population
      (`.grok/rules/engine-design.md` § Cost model); serial == threaded and
      deterministic. Coordinates with 75 (tier and cadence), 73 (think
      interval), 68A (gathers off main), 86 (collision gather), and 35
      (`world_gate`). The think set arrives in the index's cell-major order
      (level, chunk, local cell, faction, slot; `docs/architecture.md`), so
      the order within a phase follows it, faction after the cell: no
      think-set pass filters on faction. A phase-ordered store may replace
      `compactCognition` with an O(think rows) producer of the same order;
      the consumers do not change. Once production writes ascend,
      `ai-cell-ordered` and `perception-cell-ordered` measure the same stream
      as `ai` and `perception` and go; `ai-memory-shuffled` and
      `ai-affect-shuffled` stay as the swap-remove churn shape.
- [ ] Affect's gather leaves main. Failure: `gatherScopedIndices`
      (`systems/affect.zig:259-307`) walks the think set on the main thread,
      resolving the affect, perception, and memory rows per entity and
      appending one row each, per-item work beyond an ordered merge
      (`.grok/rules/threading.md`); the AI, perception, and memory gathers
      already run on workers. Failure scenario: once 75 thinks every agent,
      main pays three slot lookups per agent in the world every step. Pass: a
      windowed threaded gather merged in range order, serial == threaded, a
      `FailingAllocator` proof on a multi-worker step, and the pipeline
      workers test (`simulation_pipeline.zig:5445-5467`) covering it.
- [ ] AI memory's visibility pass reads perception in row order. Failure:
      `refreshVisibleTargets` (`systems/ai_memory.zig:681-709`) walks members
      in ascending memory row and reads `target_visible`, `nearest_threat`,
      and `last_seen_*` at each member's perception row, which ascends only
      while the perception and memory stores share a row order
      (`.grok/rules/memory-performance.md` § Data-oriented design). Failure
      scenario (derived): swap-remove churn on either store makes every
      member's perception reads scattered, every step. Pass: the stores share
      the H5 order, so the pass reads both as forward streams; an
      `ai-memory` variant with a shuffled perception store is within spread
      of the co-ordered one.
- [ ] `DataSystem` and its non-AI stores against the cost model and the
      rules: row layout and growth seams, the structural applier's per-commit
      cost, handle and generation churn, and per-step walks a store forces on
      its consumers. Each finding becomes an item here.
- [ ] A store's `u32` row cap fails as `OutOfMemory` at its growth seam
      (`.grok/rules/budgets-capacities.md`). Failure: past `maxInt(u32)`
      rows the stores return distinct errors: `data_system/movement.zig:59`,
      `agents.zig:102`, `:220`, `collision.zig:55`, `:129`,
      `faction_level.zig:35`, `:96`, `affect.zig:79`, `destructible.zig:31`,
      `perception.zig:64`, `visual.zig:79`, `:180`, `:311`; entity slots at
      `system.zig:185`; the `validateLimits` arms at `structural.zig:84-98`
      but `:96`; and `TooManyWorldLevelRows` in `PlaneStageError`
      (`src/game/dig_controller.zig:101`). Memory already does
      (`memory.zig:87`, `structural.zig:96`). Failure scenario: a caller that
      retries `OutOfMemory` with state intact meets an unhandled
      `TooMany*Rows` at the cap. Pass: each returns `error.OutOfMemory`, the
      `TooMany*` members leave the error sets, and a cap test per store like
      memory's (`structural.zig:786`).
- [ ] Step contracts (`simulation.zig`): per-step stream capacity and reserve
      against population and per-world load, event caps that simulation reads,
      `finishWrite` cost. Each finding becomes an item here.
- [ ] Commands past the `.structural_commit` share defer deterministically to
      a later step at the commit seam, one deferral every producer uses (56,
      57, 61, 62, 76, and 77 depend on it;
      `.grok/rules/budgets-capacities.md`; docs audit M7). Failure: a commit
      past the share fails before mutation (`simulation.zig:491`) and the
      error fails the step (`game_demo_state.zig:689`, through `:647`).
      Failure scenario (derived, no bench): a kill burst, collapse, or
      explosion over the share stops the step. Pass: a contract test where an
      over-share burst defers and the step succeeds, identical serial and
      threaded.
- [ ] Pipeline scheduler: per-step work in `update` and the growth seam
      outside the stages, and any per-item work on main between stages.
      Each finding becomes an item here.
- [ ] Core kernels (`simd.zig`, `math.zig`, `rng.zig`; and `logging.zig`
      against `.grok/rules/zig-style.md` § Logging, which no other pass
      covers; docs audit L5): primitive coverage
      for the reworked hot loops of 84–87, scalar/SIMD parity tests, and any
      hand-rolled primitive left in a system. Each finding becomes an item
      here.
- [ ] The population seam sizes the neighbor index and the per-AI scratch by
      AI rows, never every movement body (code audit M2; the index is 84's).
      Failure: `spatial_index.reserve` takes the movement body capacity at
      init and at the growth seam (`simulation_pipeline.zig:791`, `:992`),
      which is the max of bodies, steering, AI, and bounds
      (`PopulationRowCounts.population`, `data_system/types.zig:46`); the
      index only ever holds AI halo rows, and the perception, AI, affect, and
      AI-memory scratch reserve the same (`:810-813`)
      (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/budgets-capacities.md`). Failure scenario (derived): a
      colony with 1M items at rest and 10k agents reserves index storage for
      1M slots. Pass: a logical AI-row capacity at the seam sizes the index
      and the per-AI scratch; a reserve test shows their bytes follow AI
      rows.
- [ ] The runtime perf log carries only change-path cost-driver stages (code
      audit L1, its log-policy remainder; `.grok/rules/threading.md`).
      Failure: `BatchStage` (`src/app/runtime_perf_log.zig:225-252`) carries
      non-driver stages (perception, AI, steering, movement, particles, and
      others), recorded each step (`simulation_pipeline.zig:548-633` in the 84
      tree; `particle.zig:55`). Failure scenario: the 60 s log mixes stages no
      change path names with the drivers, hiding the one a regression moves.
      Pass: every logged stage is a design-named cost driver and the rest are
      bench-only (`--details`), with `production-step`'s census keeping its
      per-stage attribution and 68A's soak row schema
      (`docs/roadmap/scaling-gaps.md:28`) reading only the kept stages.
- [ ] `production-step` leaks the world on OOM (code audit L3). Failure:
      `world` has no errdefer across `allocator.create(GameDemoState)`
      (`src/benchmarks/production_step.zig:384-390`). Failure scenario: a
      bench OOM or leak sweep reports the fixture's leak. Pass: the state is
      created first, or a guarded errdefer covers `world` until
      `initWithWorld` takes ownership
      (`.grok/rules/memory-performance.md` § Allocator discipline).
- [ ] One `hotStoreCapacity` (code audit L8). Failure: eight private copies
      wrap `std.mem.alignForwardAnyAlign` (`systems/ai.zig:81`,
      `perception.zig:106`, `affect.zig:92`, `ai_memory.zig:71`,
      `particle.zig:31`, `collision.zig:45`, `collision_response.zig:60`,
      `steering/system.zig:67`) beside the shared
      `data_system/types.zig:28` (`.grok/rules/memory-performance.md`,
      `.grok/rules/engine-design.md` § Changes and docs). Failure scenario:
      an alignment change lands in one copy, and a stage's scratch aligns
      differently from its store. Pass: every site calls the shared helper.
- [ ] Benches at the worst-case shape each finding's bound names, with the
      shape asserts landing with each fix (`.grok/rules/tests-benchmarks.md`).
- [ ] Docs: `docs/architecture.md` (DataSystem, pipeline);
      `docs/simulation-tiers-and-pipeline.md`.

### Acceptance checks

- [ ] Every finding is fixed or is an item with its `file:line` and failure
      scenario in its owning slice.
- [ ] `production-step` main share and step time no worse than at
      `5d5a089` on any config; touched groups within run-to-run spread.
- [ ] `zig build verify` passes.
