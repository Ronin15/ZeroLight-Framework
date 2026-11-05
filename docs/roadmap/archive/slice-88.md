## Slice 88: DataSystem, Step Contracts, Pipeline, And Core Kernels Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 87](../slices/slice-87.md)'s collect items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: landed.** Landed: u32 row caps as `OutOfMemory`, one `hotStoreCapacity`, the `production-step` world leak, the stagger-phase overwrite, the slimmed runtime-log `BatchStage`, the projection map (`744974f`), generation wrap (`d301d85`), stagger-world release (`8766dde`), `validateAiAgent` bounds (`961c9b7`), the step-contract audit, the intent and path-request reserves, the pipeline audit, the think-row retie, the subset-store reserves, and the kernels audit, the facing tail, the index-key tail, the sprite sin/cos lanes, the run-bounds scan, the saturating ceil, the contact clamp, the frame-log gate, the stagger spread, and the hot-pass layout, and plane entry, and the affect gather, and memory visibility, and the neighbor index and per-AI scratch, and the AI-memory bench fixture, and the scope-cognition benches. Docs landed. `zig build verify` passed (2125 tests). The `production-step` comparison is accepted. `gpu-smoke` was not run. Owner 2026-10-16: every system on the core branch
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
  (`system.zig` 3,162 lines, `structural.zig`, `types.zig`, and the
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
- Already owned elsewhere: inert rows paying every per-step pass (75 for
  movement, tiers, and collision; 87 for render collect; collision's share
  moved from 86); the commit-seam order in the demo state (74).

### Checklist

- [x] Every agent keeps a spread stagger phase. `append`
      (`movement.zig:252`) stores `dense_index % cognition_stagger_n`
      with `stagger_settled = false`. `commitStagger` (`:443`)
      overwrites that from `nextStaggerResidue` (`:469`): the first AI
      arrival in a `(level, cell)` takes that level's origin, and each
      later arrival takes that cell's next residue. `cognitionJob`
      (`systems/simulation_scope.zig:1975`) filters the index copy of
      that phase. The spread test (`system.zig:1965`) expects `0..n-1`
      where the stripe would alias. Item `1024008001024` printed
      `thinking_step=24-24` on `serial-direct` and
      `thread-adaptive-tuned-range`
      (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/tests-benchmarks.md` § Benchmarks). Assignment is
      derived. The balance is measured. Not the hot-pass layout item.
- [x] The AI store stays in think-key order. `mergeThinkSet`
      (`simulation_scope.zig:1047`) replaces `compactCognition`. One
      live run is copied (`copyThinkRun`, `:1599`) with no cell-prefix
      load. Two or more live runs compare cell prefixes
      (`thinkCellPrefix`, `:1614`); the next head depends on the last
      compare, so that merge stays scalar. `packThinkSpan` rewrites
      the think list to `0 .. think_len`. Movement, collision,
      faction, world level, and drawable runs are not phase-ordered.
      `scope-cognition` `1004096`, both inline: base 14.0 us, tree
      5.2 us, `indexed=4096 thinking=1024`
      (`.grok/rules/memory-performance.md` § Data-oriented design,
      § SIMD and core math). `ai-cell-ordered` and
      `perception-cell-ordered` are gone. `ai-memory-shuffled` and
      `ai-affect-shuffled` stay.
- [x] Plane entry gathers by movement row from the bounds columns.
      `gatherRange` (`plane_entry.zig:339`) walks movement rows and the
      mirrored collision-bounds columns in one masked kernel
      (`laneCellEntries`, `:295`), tail included. `playerCellEntry`
      (`dig_controller.zig:654`) reads `collisionBoundsConst` (`:661`);
      the center is `(position + offset) + size * 0.5` (`:662`), and a
      player without a body or without bounds is not an entry. Commit
      stays movement-row order, the player first among moves
      (`.grok/rules/memory-performance.md` § Data-oriented design,
      § SIMD and core math, `.grok/rules/simulation.md` § Controllers
      and processors, `.grok/rules/threading.md` § What runs where).
      Derived, no bench.
- [x] Affect's gather leaves main. `gatherAffectData`
      (`systems/affect.zig:259`) dispatches `gatherAffectJob` (`:376`)
      over the think rows. Each range writes its window; `kept` is a
      running skip, so the job stays scalar. `compactRowWindows`
      (`thread_system.zig:2136`) merges in range order. The serial path
      is that job inline (`shapeBatch`, `:2467`). The pipeline step
      (`simulation_pipeline.zig:3567`) is serial == threaded, and after
      `reserve` a failing affect allocator allocates nothing
      (`.grok/rules/threading.md` § What runs where,
      § Writes, capacity, and determinism,
      `.grok/rules/memory-performance.md` § Data-oriented design,
      § SIMD and core math). Derived, no bench.
- [x] AI memory's visibility pass reads perception in row order.
      `thinkPackJob` (`simulation_scope.zig:1854`) writes paired perception
      and memory rows, then that range's one-component rows.
      `compactPairedPrefix` (`:1486`), from `installThinkSpan` (`:721`),
      puts the paired run at `0 .. paired - 1` in both stores.
      `refreshVisibleTargets` (`ai_memory.zig:654`) streams both at that
      index (`i`, or `rows[k]`). `translateJob` (`:422`) asserts the
      indices match. The ring scan stays scalar. A gapped set uses the
      memory row for both
      (`.grok/rules/memory-performance.md` § Data-oriented design,
      § SIMD and core math). Measured on the tuned case and
      `serial-direct` of `ai-memory`, `ai-memory-shuffled`,
      `ai-memory-perception-shuffled`, and `ai-memory-sparse`.
- [x] `DataSystem` and its non-AI stores against the cost model and the
      rules: row layout and growth seams, the structural applier's per-commit
      cost, handle and generation churn, and per-step walks a store forces on
      its consumers. Each finding is an item below. Row layout, component-row
      growth, and per-step consumer walks were clean.
- [x] A structural commit can still allocate a drawable run after mutation
      has started (`applyStructuralCommandsPrepared`, `structural.zig:362`;
      reserved setters `setMovementBodyReserved` `system.zig:575`,
      `setPrimitiveVisualReserved` `system.zig:714`, `setWorldLevelReserved`
      `system.zig:926`; a create applies them in `applyTemplateComponents`,
      `structural.zig:929`). Failure: an out-of-memory error on a later
      create or level change leaves earlier commands applied and does not
      retry. Pass: a reserve that fails before mutation leaves every prior
      entity, mask, scope level, and drawable run as they were; a commit
      that gets past that reserve allocates nothing while it applies. The
      proof is two visual creates, and one `set_world_level` that changes
      level (`.grok/rules/budgets-capacities.md`,
      `.grok/rules/simulation.md` § Events and streams).
- [x] Neighbor drawable reservations are a shared count on the run.
      Each row records the holds (`neighbor_below` / `neighbor_above`,
      `movement.zig:94-95`; `owned_extra` of `reserved_extra`,
      `movement.zig:194-195`). `placeDrawable` (`movement.zig:747`) holds
      level±1; `unlinkDrawable` (`movement.zig:742`) releases them, and
      destroy unlinks the row (`system.zig:1162`). A chunk or level change
      drops holds that are no longer adjacent (`relinkReservedDrawable`,
      `movement.zig:851`); `retargetDrawable` (`movement.zig:875`) spends
      only a slot this row holds (`takeOwnedNeighbor`, `movement.zig:1084`).
      A new row is level 0, chunk (0, 0) (`movement.zig:244-246`).
      `reserveDrawableDestination` (`movement.zig:785`) rolls back only the
      run that call created. Derive rolls back that pass's destinations
      (`simulation_scope.zig:313`, `:1026`) and leaves standing holds. The
      structural preflight rollback is unchanged (`unreserveDrawableSlots`,
      `movement.zig:839`). Pass: an empty neighbor run's memory follows the
      rows that reserved it and is gone after those rows are destroyed or
      leave that chunk; one row cannot consume another's reservation; a
      failed reserve leaves every other row's standing reservation as it
      was. Proof: `system.zig:2208`, `system.zig:2229`, `movement.zig:1412`
      (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/budgets-capacities.md`).
- [x] The structural projection map is sized to projecting commands, and a
      zero count does not walk retained slots (preflight clear and ensure,
      `structural.zig:613`, `structural.zig:623`; `set_simulation_tier`
      inserts nothing, `structural.zig:687`; the step clears the same map,
      `simulation.zig:731`). Failure scenario (derived): one population-sized
      tier wave, which inserts nothing, leaves every later step, including
      a step with no commands, walking that capacity on the main thread.
      Pass: a step with no projecting commands does not allocate and does
      not walk a retained capacity; a step that projects K entities costs
      O(K), and the following empty step does not walk that capacity
      (`.grok/rules/engine-design.md` § Cost model).
- [x] A slot whose generation would wrap is not reused
      (`retiredSlotGeneration`, `types.zig:182`; destroy stores it,
      `system.zig:233`; `createEntity` unlinks a `maxInt(u32)` head,
      `system.zig:178`; a later free node unlinks in preflight,
      `structural.zig:626`). Failure scenario (derived): after
      `2^32 - 1` reuses of one slot, a stale id resolves to the new
      occupant (`resolveSlotConst`, `system.zig:1147`). Pass: a slot whose
      generation would wrap is not reused, the failure is `OutOfMemory`,
      and an id from the previous cycle does not resolve
      (`.grok/rules/budgets-capacities.md`).
- [x] Releasing one stagger world destroys only that world's holders
      (`releaseStaggerWorld`, `system.zig:341`; holder list
      `movement.zig:220`; the allow-record reserve is `system.zig:344`,
      before the first destroy). Failure: dropping one dungeon walks every
      row in every world, and a failed reserve leaves that world's rows and
      maps in place with no error to the caller. Pass: releasing world W
      destroys only W's holders and touches no other world's rows; a forced
      out-of-memory error before the first destroy leaves W's rows and maps
      unchanged, and the caller receives `OutOfMemory`
      (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/budgets-capacities.md`).
- [x] `validateAiAgent` bounds `last_score`, `commitment_remaining`, and
      `sticky_bonus` the way the gains are (`agents.zig:37-41`;
      `max_ai_commitment_max_steps`, `types.zig:666`). Failure: a create
      template with a non-finite score, a remaining commitment above
      `max_ai_commitment_max_steps`, or an unbounded sticky bonus is stored
      and read on later steps. Pass: those three are bounded the way the
      gains are, and a payload outside that is `InvalidAiAgent`
      (`.grok/rules/zig-style.md` § Errors and resources).
- [x] A store's `u32` row cap fails as `OutOfMemory` at its growth seam
      (`.grok/rules/budgets-capacities.md`; `fce97cd`). No `TooMany*` member
      remains in `src/game/data_system/` or `dig_controller.zig`; cap tests at
      `structural.zig:772-774`.
- [x] Step contracts (`simulation.zig`): per-step stream capacity and reserve
      against population and per-world load, event caps that simulation reads,
      `finishWrite` cost. Event caps, `finishWrite`, and the other reserves
      follow the rows or fixed ceilings that write them (derived, no bench).
      The one miss is the item below.
- [x] Navigation, movement, and path-request reserves follow the rows that
      write them, not `population()` (`reserveFrame`,
      `simulation_pipeline.zig:1061-1064`; `PopulationRowCounts.population`,
      `data_system/types.zig:161`). Navigation intents are one per AI think
      row (`ai.zig:470`). Movement intents and path requests are one per
      selected steering row (`steering/avoidance.zig:61`). Failure: bodies or
      bounds above the AI and steering rows size all three streams to that
      larger count. Pass: `navigation_intents` follow AI rows, and `intents`
      and `path_requests` follow steering rows, summed over worlds; a reserve
      where bodies or bounds exceed those rows does not grow the three
      streams (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/budgets-capacities.md`). Derived, no bench. Not the
      neighbor-index item.
- [x] Commands past the `.structural_commit` share defer to a later step
      (`reserveDeferredStructural`, `simulation.zig:870`;
      `commitStructuralAndReact`, `simulation_pipeline.zig:1366`; the nav
      cut is `appliedPrefixMayEmitNav`, `simulation_pipeline.zig:1446`).
      Failure scenario (derived, no bench): a kill burst, collapse, or
      explosion over the share stops the step. Pass: an over-share burst
      defers and the step succeeds, identical serial and threaded
      (`.grok/rules/budgets-capacities.md`).
- [x] Pipeline scheduler: per-step work in `update` and the growth seam
      outside the stages, and any per-item work on main between stages.
      `update` and the steady seam do not walk rows (derived, no bench).
      The two misses are the items below.
- [x] Think-order and think-pack retie every AI row on the main thread
      (`orderThinkPhases`, `simulation_pipeline.zig:1715` and
      `simulation_scope.zig:416`, dispatches `think_order_retie_tuner` at
      `:500`; `packThinkSpan`, `simulation_pipeline.zig:1750` and
      `simulation_scope.zig:506`; optional rounds are
      `dispatchOptionalRetie`, `:818`). Inverse writes are
      `retieAiIndices` (`data_system/system.zig:1411`) for the rows whose
      dense index changed, on workers. `publishRunBounds` (`:664`) publishes
      the run prefixes with nine searches of the sorted think keys. Pass:
      that maintenance costs the rows whose index changed and is not
      per-item work on the main thread. Serial
      and threaded results stay identical (`.grok/rules/threading.md`
      § What runs where, `.grok/rules/engine-design.md` § Cost model).
      Derived, no bench. Retie writes are not bucketed by destination: a
      destination sort is a worse order, and no later loop streams the
      slot table. Not a rule edit. Not the hot-pass layout item.
- [x] `publishRunBounds` does not walk every AI row on main
      (`simulation_scope.zig:664`). Nine `std.sort.lowerBound` probes of
      the sorted think keys (`thinkRunEdge`, `:1576`) publish the run
      prefixes. `gatherAiPopulations` still begins at `haloCount()`.
      Place and sort did not gain a per-row edge store
      (`.grok/rules/threading.md` § What runs where,
      `.grok/rules/engine-design.md` § Cost model). Derived, no bench.
      Not the hot-pass layout item.
- [x] The growth seam sizes the scope AI lists, the steering scratch, and
      the goal table to every body. Scope AI lists follow AI rows
      (`reserveAiRows`, `simulation_scope.zig:256`; seam
      `simulation_pipeline.zig:1297`). Steering agent scratch follows
      steering rows and intent scratch follows navigation intents
      (`reserveRows`, `steering/system.zig:227`; seam `:1305`). The goal
      table follows navigation intents (`reserveGoals`, seam `:1298`).
      Pack scratch follows the max of AI, perception, memory, and affect
      (`packScratchRows`, `data_system/types.zig:165`; `reservePackRows`,
      `simulation_scope.zig:277`; `pack_scratch_capacity`, seam `:1307`),
      and that ensure does not pull the AI lists up with it. A body or
      bounds increase that does not raise those counts does not grow
      them. Collision indices, tier commands, chunk-change windows,
      plane-entry windows, and the plane scratch stay on the body cap
      (`scope.reserve`, seam `:1290`) (`.grok/rules/engine-design.md`
      § Cost model, `.grok/rules/budgets-capacities.md`,
      `.grok/rules/memory-performance.md` § Hot paths). Derived, no
      bench. Not the neighbor-index item.
- [x] Core kernels (`simd.zig`, `math.zig`, `rng.zig`; and `logging.zig`
      against `.grok/rules/zig-style.md` § Logging, which no other pass
      covers; docs audit L5): primitive coverage
      for the reworked hot loops of 84–87, scalar/SIMD parity tests, and any
      hand-rolled primitive left in a system. The reworked loops that already
      use one lane kernel pass (derived, no bench). The six misses are the
      items below.
- [x] Perception facing's tail is the lane kernel (`computeFacingRange`,
      `perception.zig:669`). Each batch loads and stores with
      `loadFloat4Lanes` and `storeFloat4Lanes`. A 1–3 row remainder is that
      kernel, and inactive lanes are not stored. `computeFacingScalar`
      (`:561`) is the finite reference only. A non-finite tail row keeps
      its previous facing. Serial and threaded facing match. The threaded
      fixture is two ranges and one worker: main runs the last 3-row batch
      (`.grok/rules/memory-performance.md` § SIMD and core math). Derived,
      no bench.
- [x] Index key fill's tail is the lane kernel (`fillSlots`,
      `spatial_index.zig:1371`). A 1–3 slot remainder is that kernel once.
      Inactive lanes are not resolved and not stored. Keys stay
      bit-identical to `keyForPosition` (`:1307`). The fill does not call
      it. `chooseSplitters` (`:1664`) still does, once per fixed sample.
      Slot resolve inside a group stays scalar
      (`.grok/rules/memory-performance.md` § SIMD and core math). Derived,
      no bench.
- [x] Sprite lanes use a core sin/cos lane primitive (`sinCosFloat4`,
      `simd.zig:837`; `writeSpriteLanes`, `sprite_batch.zig:789`). One
      call per group, tail included. Finite lanes match `math.sinCos`
      (`math.zig:162`). Inactive lanes are not stored. `writeSpriteQuad`
      stays the one-angle scalar call. The 6-vertex store is unchanged
      (`.grok/rules/memory-performance.md` § SIMD and core math). Derived,
      no bench.
- [x] The saturating ceil is `ceilToI32` (`math.zig:43`), `lossyCast`
      of `@ceil`, the same saturation contract as `floorToI32`.
      `cellScanRadius` is gone. `blockKey` (`spatial_index.zig:553`) and
      `gatherRow` (`perception.zig:524`) each call it once on the
      quotient. A query ceils once, before its candidate loop. A kept
      gather row ceils once. No dense column of radii, so no lane form
      (`.grok/rules/memory-performance.md` § SIMD and core math).
      Derived, no bench.
- [x] Contact loudness uses `math.clamp` (`penetrationScale`,
      `contact_query.zig:30`; `math.zig:27`). A NaN penetration stays
      NaN. `+inf` is 1 and `-inf` is 0.25. The finite curve is
      unchanged. No penetration column, so no `clampFloat4`
      (`.grok/rules/memory-performance.md` § SIMD and core math).
      Derived, no bench.
- [x] Frame warns sit behind `comptime logging.enabled(.warn)`. A
      repeated 0×0 acquire returns at `noteZeroSizeSwapchain`
      (`renderer.zig:926`) before formatting. The first warn is inside
      the gate (`:931`). `endFrame` (`:983`) and
      `submitSwapchainRecoveryFrame` (`:1112`) share
      `zero_size_swapchain_warned`. The window-clip warn
      (`world/render.zig:937`), the layer-drop warn (`:967`), and the
      audio command and control warns (`audio.zig:347`, `:550`) format
      inside the same gate. Their latches stay outside it
      (`.grok/rules/zig-style.md` § Logging). Derived, no bench.
- [x] The population seam sizes the neighbor index and the per-AI scratch by
      AI rows, never every movement body (code audit M2; the index is 84's).
      `navigation_intent_capacity` (`simulation_pipeline.zig:877`) is the
      committed AI rows, then `grownPopulationCapacity` of those rows
      (`:1256`). Init reserves the index at `rows.ai_agents` (`:1006`) and
      the AI, perception, and affect scratch the same (`:1025`, `:1026`,
      `:1028`). The seam reserves that index and those three scratches at
      `navigation` (`:1299-1302`). `reserveFrame` passes that capacity
      (`:1080`); `reserve` sizes them to it (`:1092`, `:1093`, `:1095`).
      The AI-memory think side uses the same count (`ai_memory.zig:171`,
      `simulation_pipeline.zig:1094`). The memory side does not:
      `memory_scratch_capacity` (`simulation_pipeline.zig:881`) is
      `rows.ai_memories` at init (`:1049`) and `grownPopulationCapacity` of
      those rows at the seam (`:1273`, `:1308`). A bounds increase or a
      perception-only increase leaves the five scratch totals unchanged. A
      memory-only increase grows only the memory side. An AI increase grows
      the index and the AI, perception, and affect totals and leaves
      `reserved_memory_rows` unchanged
      (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/budgets-capacities.md`). Derived, no bench.
- [x] The runtime perf log carries only change-path cost-driver stages (code
      audit L1; `.grok/rules/threading.md`). Landed for `BatchStage`
      (`005cdae`): 11 change-path drivers, the rest `BenchBatchStage`
      (`src/app/runtime_perf_log.zig:217-300`). The `pipeline_*` timers are
      [slice 50](../slices/slice-50.md)'s open item.
- [x] `production-step` leaks the world on OOM (code audit L3). Landed in
      `f1d836e`: the state is created first
      (`src/benchmarks/production_step.zig:837-839`).
- [x] One `hotStoreCapacity` (code audit L8). Landed in `fce97cd`: one helper
      (`data_system/types.zig:28`); no private `alignForwardAnyAlign` copy
      remains in the systems.
- [x] Benches at the worst-case shape each finding's bound names, with the
      shape asserts landing with each fix (`.grok/rules/tests-benchmarks.md`).
      `scope-cognition` `interleaved_runs` `2001024` / `2004096` / `2010000`
      (`thread-adaptive-tuned-range`): both runs non-empty, the other phases
      empty, a phase-0 row before the last always-active row, and
      nondecreasing cell prefixes. `spread` `10000` and `dense_chunk`
      `1004096` assert `thinking + stagger_skips == indexed` and thinking <
      indexed. Every other finding stays the measured or derived sentence
      already on its item.
- [x] AI memory's scratch reserve covers the population it is reserved for.
      The production seam shortfall is closed: a memory count reserved at the
      seam does not call `growPastReserve` (`systems/ai_memory.zig:353`,
      called at `:218`). `runCaseImpl` (`src/benchmarks/ai_memory.zig:175`)
      reserves the two live counts once, after `AiMemorySystem.init`
      (`:182`) and before the first `runOnce` (`:294`, from `:195` and
      `:208`): the think-set length, or the agent length (`:185`), and the
      memory-row length (`:186`, `reserve` at `:187`). Sparse passes 256
      and `item_count`. After warmup and the timed steps,
      `reserved_think_rows` and `reserved_memory_rows` are at least those
      counts and `scratch_growth_logged` is false (`:224-226`). The
      warning stays the once-per-system growth signal
      (`systems/ai_memory.zig:359`)
      (`.grok/rules/engine-design.md` § Cost model,
      `.grok/rules/tests-benchmarks.md` § Benchmarks).
- [x] Docs: `docs/architecture.md` (DataSystem, pipeline);
      `docs/simulation-tiers-and-pipeline.md`.

### Acceptance checks

- [x] Every finding is fixed or is an item with its `file:line` and failure
      scenario in its owning slice. The checklist items are checked. Review
      findings were folded into their landings.
- [x] `production-step` main share and step time no worse than at
      `5d5a089` on any config; touched groups within run-to-run spread
      (tuned-versus-control measured after slice 89's tuner change, which gets
      its own whole-suite run; the `750ce0a` baseline predates it).
      Owner judgment 2026-11-04: the comparison is accepted. Both runs
      printed `settled=no` because 1–8 of the 41–49 tuners that recorded
      during the timed steps were outside holding at the snapshot. The names
      rotated between `benchmark_outputs/ab-20261103-072747` (code `9bf93b0`)
      and `benchmark_outputs/ab-20261104-145146` (code `e761374`, Debug,
      `x86_64_v2`, `--warmup 484`, 30 iterations, tuned case, `--fresh`).
      That census is not a tuner removal. The step times agree across the
      two runs. Main share improved on all 12 configs with a base, from
      75–88% to 36–75%. Ten of those steps are faster. Crowd 16,384 went
      from 39.86 ms to 11.91 ms, and main from 34.3 ms to 4.35 ms. Two steps
      with about 23 thinking rows are slower: spread 1,024 agents, 8 levels,
      678 us to 1.04 ms (+362 us); spread 4,096 agents, 32 levels, 993 us to
      1.32 ms (+327 us). `scope_gather` is the new top main stage there
      (272 us and 470 us). Side 2048 is +110 us, inside the 10% band, and
      its main time fell. Those two gaps stay with Slice 75. The three
      `stacked` configs have no base at `5d5a089`. Touched groups were
      judged on their own landings. The default-warmup grid is
      `benchmark_outputs/ab-20261103-072301`.
- [x] `zig build verify` passes. Debug, 2125 tests. `gpu-smoke` was not run.
