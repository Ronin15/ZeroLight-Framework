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

- [ ] Every agent keeps a spread stagger phase. Failure: the append stripes
      `stagger_phase = index % cognition_stagger_n`
      (`data_system/movement.zig:76`), but every live spawn then calls
      `setSimulationMetadata` with no phase (`game_demo_state.zig:1010`,
      `src/benchmarks/production_step.zig:265`), which writes the default 0
      (`src/game/simulation_scope.zig:146`, through
      `data_system/movement.zig:144`), against the metadata's stated contract
      that the phase is stable per entity
      (`src/game/simulation_scope.zig:142-145`). Failure scenario: the whole
      halo thinks on one step in four and none on the other three, so
      cognition cost lands on every fourth step and the `production-step`
      think counts that 75 and 88 cite describe that step. Pass: agents
      spawned through the production spawn path spread across the phases; a
      test that would fail with the overwrite
      (`.claude/rules/tests-benchmarks.md` § Tests); serial == threaded.
- [ ] DataSystem hot-pass data layout (contiguity audit H5): the stores stay
      dense SoA; the stagger assignment and the cross-store reads are fixed in
      the layout (`.claude/rules/memory-performance.md` § Data-oriented
      design). Failure: every component store appends and swap-removes
      (`data_system/movement.zig:168`, `agents.zig:159`,
      `faction_level.zig:61`, `:122`), so no store is ordered by the keys
      tiered passes filter on. Tier, stagger phase, chunk, and level sit in
      the movement scope columns (the scope level is kept equal to
      `world_level`, `data_system/system.zig:944-950`); faction and
      `world_level` are separate stores (`faction_level.zig:17`, `:22`); each
      cross-store read resolves through the entity slot table
      (`data_system/system.zig:445-455`, `:756-760`). Consumers:
      `gatherAiData` (`systems/ai.zig:509`), `gatherPerceptionData`
      (`perception.zig:415`), `compactCognitionFromHalo`
      (`simulation_scope.zig:418`), `collisionGatherJob` and `aiGatherJob`
      (`:772`, `:801`), collision `gatherBodies` (`collision.zig:455`), the
      `world_gate` walks (`world_gate.zig:41`, `:119`), and render collect
      (87). Failure scenario (derived): with phases striped by row, each
      step's P/4 think set touches every cache line of each AI and movement
      column it reads and uses a quarter of each, plus a slot-table, faction,
      and `world_level` lookup per row; swap-remove churn scrambles phase and
      chunk order further, and the scope index lists inherit the scatter.
      Pass: each phase is a contiguous row run the think set reads in order;
      no consumer above reads another store per row outside a once-per-stage
      gather (`.claude/rules/memory-performance.md` § Data-oriented design); a
      structural command's apply cost stays independent of population
      (`.claude/rules/engine-design.md` § Cost model); serial == threaded and
      deterministic. Coordinates with 75 (tier and cadence), 73 (think
      interval), 68A (gathers off main), 86 (collision gather), and 35
      (`world_gate`).
- [ ] `DataSystem` and its non-AI stores against the cost model and the
      rules: row layout and growth seams, the structural applier's per-commit
      cost, handle and generation churn, and per-step walks a store forces on
      its consumers. Each finding becomes an item here.
- [ ] Step contracts (`simulation.zig`): per-step stream capacity and reserve
      against population and per-world load, event caps that simulation reads,
      `finishWrite` cost. Each finding becomes an item here.
- [ ] Commands past the `.structural_commit` share defer deterministically to
      a later step at the commit seam, one deferral every producer uses (56,
      57, 61, 62, 76, and 77 depend on it;
      `.claude/rules/budgets-capacities.md`; docs audit M7). Failure: a commit
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
      against `.claude/rules/zig-style.md` § Logging, which no other pass
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
      (`.claude/rules/engine-design.md` § Cost model,
      `.claude/rules/budgets-capacities.md`). Failure scenario (derived): a
      colony with 1M items at rest and 10k agents reserves index storage for
      1M slots. Pass: a logical AI-row capacity at the seam sizes the index
      and the per-AI scratch; a reserve test shows their bytes follow AI
      rows.
- [ ] The runtime perf log carries only change-path cost-driver stages (code
      audit L1, its log-policy remainder; `.claude/rules/threading.md`).
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
      (`.claude/rules/memory-performance.md` § Allocator discipline).
- [ ] One `hotStoreCapacity` (code audit L8). Failure: eight private copies
      wrap `std.mem.alignForwardAnyAlign` (`systems/ai.zig:81`,
      `perception.zig:106`, `affect.zig:92`, `ai_memory.zig:71`,
      `particle.zig:31`, `collision.zig:45`, `collision_response.zig:60`,
      `steering/system.zig:67`) beside the shared
      `data_system/types.zig:28` (`.claude/rules/memory-performance.md`,
      `.claude/rules/engine-design.md` § Changes and docs). Failure scenario:
      an alignment change lands in one copy, and a stage's scratch aligns
      differently from its store. Pass: every site calls the shared helper.
- [ ] Benches at the worst-case shape each finding's bound names, with the
      shape asserts landing with each fix (`.claude/rules/tests-benchmarks.md`).
- [ ] Docs: `docs/architecture.md` (DataSystem, pipeline);
      `docs/simulation-tiers-and-pipeline.md`.

### Acceptance checks

- [ ] Every finding is fixed or is an item with its `file:line` and failure
      scenario in its owning slice.
- [ ] `production-step` main share and step time no worse than at
      `5d5a089` on any config; touched groups within run-to-run spread.
- [ ] `zig build verify` passes.
