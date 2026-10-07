# src/game

- `SimulationPipeline` is the only fixed-step scheduler. Every stage declares
  its contract and slots into `stage_order` (CS § Simulation Pipeline Stage
  Ordering). Adding a stage: `PipelineResource` tag(s), `StageId` in
  `stage_order`, a `stageContract()` arm, and a `runStage` arm, in one change.
- Structural changes commit at the main-thread seam; workers never mutate
  `DataSystem` structurally. `syncPopulationCapacity` (after publication,
  outside `stage_order`) is the only population growth point
  (`docs/simulation-tiers-and-pipeline.md` § Structural Commands).
- Pipeline-owned controllers orchestrate (small queues, budgets, cooldowns,
  conflict policy); they never hide per-entity stores, own renderer/audio/SDL
  handles, hide RNG, or replace hot SoA processors (`docs/architecture.md`).
- Tests use the smallest `WorldSystem`/`DataSystem` fixture that exercises the
  behavior; a `1x1` world is one real chunk (CS § Tests).
