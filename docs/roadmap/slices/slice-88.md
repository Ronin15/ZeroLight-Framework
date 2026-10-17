## Slice 88: DataSystem, Step Contracts, Pipeline, And Core Kernels Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 87](slice-87.md) (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Owner 2026-10-16: every system on the core branch
gets a whole-subsystem pass against the cost model and the rules. This slice
covers the shared layers no other core slice owns. It runs after 87 and
before the inert-row items and 75's tier mechanics, both of which build on
the storage it settles.

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

- [ ] Owner decision needed: DataSystem row-order redesign of the persistent
      layout (contiguity audit H5; a major redesign, `CLAUDE.md` § Agent
      Pipeline). Failure: every component store appends and swap-removes
      (`data_system/movement.zig:168`, `agents.zig:159`,
      `faction_level.zig:61`, `:122`), so no store is ordered by the keys
      tiered passes filter on. Tier, stagger phase, chunk, and level sit in
      the movement scope columns; faction and `world_level` are separate
      stores (`faction_level.zig:17`, `:22`); every join resolves through the
      entity slot table (`data_system/system.zig:445-455`, `:756-760`).
      `stagger_phase = index % cognition_stagger_n` at append
      (`data_system/movement.zig:76`) makes each step's think set every
      fourth row. Consumers: `gatherAiData` (`systems/ai.zig:509`),
      `gatherPerceptionData` (`perception.zig:415`),
      `compactCognitionFromHalo` (`simulation_scope.zig:418`),
      `collisionGatherJob` and `aiGatherJob` (`:772`, `:801`), collision
      `gatherBodies` (`collision.zig:455`), the `world_gate` walks
      (`world_gate.zig:41`, `:119`), and render collect (87)
      (`.claude/rules/memory-performance.md` § Dense SoA storage). Failure
      scenario (derived): with P cognition agents, each step's P/4 think set
      touches every cache line of each AI and movement column it reads and
      uses a quarter of each, plus random slot-table, faction, and
      `world_level` probes per row; swap-remove churn scrambles phase and
      chunk order further, and the scope index lists inherit the scatter.
      Pass, once the owner decides: the design states the row order, how
      the structural applier and determinism depend on it, and its
      coordination with 75 (tier and cadence), 73 (think interval), 68A
      (gathers off main), 86 (collision gather), and 35 (`world_gate`); the
      hot consumers read contiguous runs.
- [ ] `DataSystem` and its non-AI stores against the cost model and the
      rules: row layout and growth seams, the structural applier's per-commit
      cost, handle and generation churn, and per-step walks a store forces on
      its consumers. Each finding becomes an item here.
- [ ] Step contracts (`simulation.zig`): per-step stream capacity and reserve
      against population and per-world load, event caps that simulation
      reads, `finishWrite` cost. Each finding becomes an item here. This item
      owns the structural-share deferral (docs audit M7): commands past the
      `.structural_commit` share defer deterministically to a later step at
      the commit seam, one deferral every producer uses (56, 57, 61, 62, 76,
      and 77 point here; `.claude/rules/budgets-capacities.md`). Failure
      scenario (derived, no bench): a commit past the share fails the whole
      step (`simulation.zig:491`, raised through `game_demo_state.zig:689`),
      so a kill burst, collapse, or explosion over the share stops the step.
      Pass: a contract test where an over-share burst defers and the step
      succeeds, identical serial and threaded.
- [ ] Pipeline scheduler: per-step work in `update` and the growth seam
      outside the stages, and any per-item work on main between stages.
      Each finding becomes an item here.
- [ ] Core kernels (`simd.zig`, `math.zig`, `rng.zig`, and `logging.zig`,
      which no other pass covers; docs audit L5): primitive coverage
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
      others) recorded from the pipeline. Failure scenario: the 60 s log
      mixes stages no change path names with the drivers, hiding the one a
      regression moves. Pass: every logged stage is a design-named cost
      driver and the rest are bench-only (`--details`), with
      `production-step`'s census keeping its per-stage attribution.
- [ ] `production-step` leaks the world on OOM (code audit L3). Failure:
      `world` has no errdefer across `allocator.create(GameDemoState)`
      (`src/benchmarks/production_step.zig:384-390`). Failure scenario: a
      bench OOM or leak sweep reports the fixture's leak. Pass: the state is
      created first, or a guarded errdefer covers `world` until
      `initWithWorld` takes ownership.
- [ ] `production-step`'s tuned case checks that its tuners settled (code
      audit L5). Failure: it warms a fixed `adaptiveSettleIterationLimit`
      steps (`production_step.zig:430-432`) and reports no per-stage settle
      state. Failure scenario: the measured window includes probes or
      retunes, skewing the main share that 84, 86, and 88 gate on. Pass: the
      case reports each stage's settle state, or settles by walking the
      pipeline's tuners.
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
