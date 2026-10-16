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
- Scheduler: `src/game/simulation_pipeline.zig` (6,328 lines after 83 L2):
  `stageContract`, `stage_order`, `update`, the population growth seam.
  84 checks the contract and dispatch it touches; this slice covers the rest.
- Kernels: `src/core/simd.zig`, `src/core/math.zig`, `src/core/rng.zig`.
- Measured (`production-step`, Debug, `5d5a089`): the main thread carries
  75–88% of the step in every config; `untimed` is 3–31% of the step (75
  adds its timers).
- Already owned elsewhere: inert rows paying every per-step pass (86, 75,
  87); structural commands past the fixed share failing the step (56, 57, 61,
  62, 76, 77); the commit-seam order in the demo state (74).

### Checklist

- [ ] `DataSystem` and its non-AI stores against the cost model and the
      rules: row layout and growth seams, the structural applier's per-commit
      cost, handle and generation churn, and per-step walks a store forces on
      its consumers. Each finding becomes an item here.
- [ ] Step contracts (`simulation.zig`): per-step stream capacity and reserve
      against population and per-world load, event caps that simulation
      reads, `finishWrite` cost. Each finding becomes an item here.
- [ ] Pipeline scheduler: per-step work in `update` and the growth seam
      outside the stages, and any per-item work on main between stages.
      Each finding becomes an item here.
- [ ] Core kernels (`simd.zig`, `math.zig`, `rng.zig`): primitive coverage
      for the reworked hot loops of 84–87, scalar/SIMD parity tests, and any
      hand-rolled primitive left in a system. Each finding becomes an item
      here.
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
