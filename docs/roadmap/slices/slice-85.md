## Slice 85: Steering On The Shared Neighbor Index

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 84](../archive/slice-84.md), [Slice 86](slice-86.md) (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Routed by the 64G combined review (area D M1, M4,
L10) and the movement intent measurement.

Goal: steering queries 84's shared index instead of building and sorting a
private grid; an entity create or destroy invalidates only what it changed in
steering's caches; steering's movement intents reach movement in an order that
keeps the apply local.

### Current foundation

- Private grid, whole in `src/game/systems/steering/agent_grid.zig`:
  `buildAgentGrid` (`:35`), banded build (`:62`), `sortCellEntries` (`:263`).
  It sorts the positions the spatial index already sorted.
- Grid state outside `agent_grid.zig` that goes with it (`steering/system.zig`):
  - the grid buffers' `deinit` (`:198`, `:203-205`) and reserve (`:507-509`,
    `:512`; `band_rows` at `:519-520` is shared with `select_resolve`);
  - the grid tuners (`:190-191`), stats (`:127-129`, `:135`), and step timer
    (`:317-319`);
  - `spatial_cell_size` in the `agents` stage (`:395-397`), `largestReach`
    (`:730`), and `AgentsTally.largest_reach` (`:584`);
  - test expectations at `system.zig:1256-1263` and `:1391-1420`, and
    `steering/test_support.zig:21`.
- `changeInvalidatesSteeringMovementIndexCache` (`system.zig:747`) drops the
  whole movement-index cache on any `entity_created`.
- `accumulateAgentAvoidanceBounded` (`steering/avoidance.zig:360`) is scalar
  over up to 64 candidates per agent and states no SIMD verdict; the sibling
  obstacle push is SIMD.
- Steering writes the movement intents (`avoidance.zig:216`) that
  `apply_ai_movement_intents` applies.
- 84's shared index (`docs/architecture.md`, `SpatialIndexSystem`): a query
  reads one level and a faction set within a world radius, skips `self`
  without a check, and visits in lane groups (`NeighborLanes`) through a
  per-key `NeighborBlock`; `capLanes` caps a visitor. It indexes any
  `IndexPopulation`. Its scan order at its own cell size replaces the grid's
  `(cell_y, cell_x, row)` at `largest_reach` cells, so avoidance's sample
  order changes (stated under Tests). AI emits navigation intents in the
  think set's cell-major order, so steering's agents arrive grouped by cell
  and can share blocks. The per-neighbor radius and a lane `lengthDirection`
  are 85's.
- Measured:
  - `production-step` tuned `--details` (Debug, `5d5a089`): `steering_grid`
    0.59 ms at spread P 16,384; steering 0.84 ms on main of a 9.8 ms step.
  - `movement-apply-intents` vs `movement-apply-intents-sorted`, 16,384
    intents, serial, ReleaseFast (`639f55d`): 61.5 vs 38.5 µs, with no false
    sharing between ranges.

### Architecture notes

- Neighbor queries use the shared index (`.claude/rules/simulation.md`);
  steering's private grid is not an allowed exception.
- A create costs work in what it changed (`.claude/rules/engine-design.md`
  § Cost model).
- Each hot loop carries a SIMD verdict (`.claude/rules/memory-performance.md`
  § SIMD).
- Serial == threaded bitwise (`.claude/rules/threading.md`).

### Checklist

- [ ] Steering reads 84's index; its grid and sort are deleted. Failure
      scenario: two sorts of the same positions every step. The grid has no
      level key: entries hold only cell and row index (`agent_grid.zig:247`),
      sorted by `(cell_y, cell_x, row)` (`:263`, `:339`), and
      `accumulateAgentAvoidanceBounded` counts each entry against
      `max_agent_candidate_checks` (64, `avoidance.zig:44`) at `:395`, before
      its level gate at `:400`, then reads 5 snapshot columns per candidate
      through the row index (contiguity audit H1, code audit H2;
      `.claude/rules/memory-performance.md` § Data-oriented design,
      `.claude/rules/simulation.md` § Controllers and processors). Failure
      scenario (derived): a shaft of L levels with k agents per cell at the
      same xy; checks per agent grow with L up to the 64 cap, and with L·k >
      64 the cap is spent on other-level rows, so a same-level neighbor gives
      no avoidance push. Measured: `steering_grid` 0.59 ms above. Pass: one
      sort per step in the `production-step` census; `steering` within spread
      or faster; a levels axis on the `steering` bench with avoidance samples
      and checks per agent flat in L. The grid's false "nearly sorted"
      comment (`agent_grid.zig:266`; keys are rebuilt in slot order every
      build) goes with it.
- [ ] A create or destroy invalidates only the cache entries it affects
      (`system.zig:747`). Failure scenario (derived): a spawn burst makes every
      steering row re-resolve its movement index that step, nanoseconds per
      row, threaded. Pass: a test that unrelated rows keep their cached
      index; a spawn-churn `steering` case flat in population for a fixed
      churn.
- [ ] The agent avoidance accumulate is vectorized (moved from 35; docs audit
      M9). Failure: `accumulateAgentAvoidanceBounded` (`avoidance.zig:360`),
      which this slice rewrites onto 84's index, runs its per-neighbor float
      math scalar with no verdict at the site; the rewritten loop is a
      gather-bound per-agent loop, so it ships SIMD
      (`.claude/rules/memory-performance.md` § Data-oriented design, § SIMD
      and core math). Failure scenario: avoidance's per-neighbor math stays
      scalar at population scale. Pass: the accumulate runs through `simd.zig`
      over the index's lane groups, ending in their masked last batch,
      bit-identical to its scalar form; scalar/SIMD and
      serial/threaded parity tests; any scratch it reserves has a
      `FailingAllocator` proof over the real multi-worker `ThreadSystem`
      (`.claude/rules/memory-performance.md` § Allocator discipline).
- [ ] Movement intents reach the apply in movement-row order. Failure
      scenario: `frame.intents` is written in steering's selected order
      (`avoidance.zig:216`), so the apply resolves each intent's movement row
      (`movement.zig:133`) and writes the rows scattered (contiguity audit M3;
      `.claude/rules/memory-performance.md` § Data-oriented design,
      `.claude/rules/threading.md`). Measured gain above (ReleaseFast only;
      Debug numbers come first, `.claude/rules/build-validation.md`). Pass:
      the apply walks its intents in row order with no per-intent row lookup;
      `movement-apply-intents` within spread of `-sorted`, with the ordering
      cost counted in steering.
- [ ] `steering_update` declares its carried inputs (84's audit). Failure:
      steering reads the previous step's positions and levels
      (`steering/system.zig:350`) before `apply_ai_movement_intents` writes
      positions, but its arm (`simulation_pipeline.zig:236`) declares no
      `carried` (`.claude/rules/simulation.md` § Pipeline and stage
      ordering). Failure scenario: moved after a position or level writer, it
      still compiles and reads this step's poses against the previous step's
      index. Pass: the arm carries `movement_positions` and `world_level`
      (and reads `spatial_index` once steering queries it), so the reorder
      fails the comptime check.
- [ ] No per-step width error (84's L1 review). Failure: the step returns
      `error.Overflow` past `max_step_items` (`steering/system.zig:298-299`)
      behind an assert, a distinct per-step error where the bound is a format
      width (`.claude/rules/budgets-capacities.md`). Failure scenario: a
      caller that handles growth failures as `OutOfMemory` meets a different
      error from the hot path. Pass: the width is proven where rows grow
      (the population seam or `reserve`, as `OutOfMemory`) and the step keeps
      only the assert.
- [ ] `select_claim` dispatches items that track its work (84's audit).
      Failure: its items are bands (`steering/selection.zig:77`, `:89`), at
      most a fixed band count of `BandPartition` at scale, whatever the
      intents behind them (`.claude/rules/threading.md`: never a fixed
      partition count whose work varies behind it). Failure scenario: at
      large populations the tuner samples a fixed band count while each
      band's intents grow. Pass: the stage's items are units whose count
      tracks its intents; `steering --details` shows the stage's shape
      following intent count.
- [ ] The whole subsystem checked against the cost model and the rules
      (owner 2026-10-16), not only the items above: every file in
      `src/game/systems/steering/` (selection, directions, avoidance, the
      movement-intent write), `systems/movement.zig`, `systems/particle.zig`,
      and the `data_system/movement.zig` and `data_system/agents.zig` stores.
      Each finding becomes an item here.
- [ ] `buildAgentGridDirect` (`steering/agent_grid.zig:38-59`) is a separate
      no-worker entry from `buildAgentGrid` (`.claude/rules/tests-benchmarks.md`
      § Test and production code, point 1). If this slice keeps the grid it is
      deleted; the grid itself goes with the first item. Deleting it makes the
      one-band fast path (`steering/avoidance.zig:389`) dead, and
      `src/benchmarks/steering.zig:262` (`largestGridBand`) counts bands from
      the one-band form; both move to the banded form. Deleting it adds a
      constant band search per avoidance cell lookup. Pass: that cost checked
      by `steering` at three sizes, inline and threaded, same mode.
- [ ] A no-worker serial branch in steering selection
      (`steering/selection.zig:52`, the `orelse` of `withWorkers` calling
      `resolveAndClaim` once;
      `.claude/rules/tests-benchmarks.md` § Test and production code, point
      1). Pass: removed after a cost check that the stage run inline does no
      worse (`steering`, same mode).
- [ ] Tests: steering output on today's fixtures unchanged, or changed only by
      a stated order; serial == threaded; allocation-free warmed step.
- [ ] Docs: `docs/architecture.md` steering;
      `docs/simulation-tiers-and-pipeline.md` stage list.

### Acceptance checks

- [ ] `steering` at three sizes shows no regression beyond run-to-run spread;
      `production-step` steering main time no higher than at `5d5a089`.
- [ ] `zig build verify` passes.
