## Slice 68A: Battle-Scale Hardening — Shared Entity Table, Action-Bus Fairness, Control Re-Baseline

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 56](slice-56.md), [Slice 75](slice-75.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Independent of Slice 35 (per-row math).

Goal: three battle-scale items, each with a fixed cost bound and a
determinism proof.

1. Perception and AI stop walking the sensed population serially on the main
   thread: main-thread work is proportional to decide rows over the whole
   population 75 indexes. The threaded spatial-index gather produces one
   per-step entity table and a self-validating map from AI row to table row;   perception and AI then walk only their own think or decide rows. The
   entity-column part landed with Slice 84 (view columns, `spatial_index.zig:224-230`,
   `entityAt` `:247`); the checklist's open items are the remaining pieces.
2. The shared action bus keeps its fixed per-step counts; Slice 56's
   rotating deferral gains a deterministic deferral-age priority, so a
   deferred actor waits a bounded number of its qualifying steps under any
   demand. Nothing grows with population.
3. A written, reproducible procedure for the ReleaseSafe battle soak
   (hands-off, seeded, repeated, a fixed row schema) that every slice adding
   a stage or changing soak population runs; diagnostic trend data only.

Out of scope: per-row SIMD math and steering avoidance (Slice 35), coasting
sensing (Slice 55 rejects it).

### Current foundation

- `SpatialIndexSystem` (`src/game/systems/spatial_index.zig`, Slice 84)
  builds the unstaggered halo's index on workers into per-chunk records keyed
  by level and faction; `view()` carries each entry's position, entity
  (`entity_index`, `entity_generation`), `population_row` (its AI row), and
  `cognition_phase`; `build` runs inline on a zero-worker `ThreadSystem` (no separate serial entry). `spatial_index_build`
  carries `movement_positions` and `world_level`.
- `PerceptionSystem.gatherPerceptionData`
  (`src/game/systems/perception.zig:362`) and `AiSystem.gatherAiData`
  (`src/game/systems/ai.zig:502`) keep no candidate tables and walk no halo:
  each walks only its think rows on workers, in windows main merges in range
  order, resolving movement, faction, and level per row through the entity
  slot table. The think set comes from the index on workers
  (`compactCognition`, `src/game/systems/simulation_scope.zig:338`).
- `DataSystem.movementVisualDenseIndices` (`src/game/data_system/system.zig`)
  is the single-resolve precedent.
- From earlier slices: 55's decide set (its `ai-idle-stagger` and `ai-idle-coast` benches do not exist yet); 75's
  whole-population spatial index; 56's emitter, per-step budget with
  rotating deferral, and `ai_actions_deferred`.
- Perf log: 60 s intervals with summed and max metrics, compiled out of
  ReleaseFast (`src/app/runtime_perf_log.zig`); the control table lives in
  Scaling Gaps (Battle-scale perf watch).

### Architecture notes

- The per-step table is rebuilt every step from the gather that already
  resolves each row on workers.
- Table columns are stage-3 snapshots: readers before `plane_traversal` may
  use the level column; later readers (56's arc query, 71A's alarm) read
  `world_level` from `DataSystem`.
- A missing table row for a decide row means the agent has no movement
  body, asserted in Debug and ReleaseSafe.
- Main-thread work drops to O(decide rows) over the post-75 population;
  worker work rises by a few column reads per row
  (`.grok/rules/threading.md`: the main thread holds only ordered merge).
- Fairness: the bus counts stay fixed per world; deferral age is a
  persistent per-agent counter written only by the emitter; selection is
  deterministic (age first, then rotation rank) and allocation-free
  (`.grok/rules/budgets-capacities.md`: a chronically short budget gets
  deterministic deferral, never a bigger number).
- The age counter is hashed and saved (Slice 49 lists, Slice 46 section,
  relative bumps); the table and map are per-step derived and excluded
  (64B).
- The soak runs realistic to extreme populations from content, never a demo
  count as a target; numbers are machine-specific trend data, never claims
  or gates (`.grok/rules/tests-benchmarks.md`,
  `.grok/rules/build-validation.md`).
- VoidLight reference: only the idea that one per-frame snapshot serves
  several consumers; not thread-local position-keyed caches,
  completion-order command application, or unbudgeted action dispatch.

### Checklist

- [ ] Bench first: `decide-consumers` group (spatial build, perception,
      decide gather, AI per step over the whole population) landed before the
      refactor for a same-session baseline.
- [ ] Single-resolve halo row lookup on `DataSystem` with unit tests.
- [ ] Spatial index emits the entity table and the AI-row map, reserved with
      the AI population and grown at the seam; view columns and the
      self-validating lookup; module doc updated. The view columns landed
      with Slice 84 (`08e4799`, `3efa1e4`, `c52a5ff`); the rest is open.
- [ ] Perception and AI drop their candidate tables and halo walks; config
      fields that described the pairing are deleted; pairing asserts added.
      Slice 84 removed the tables, the halo walks, and the dual-list config
      fields; the pairing asserts land with the table and map.
- [x] The think-set compact leaves main: `compactCognition` runs on workers
      over the index's columns and main merges the windows (Slice 84,
      `3efa1e4`); serial == threaded tests; `scope-cognition` measures main's
      share per row.
- [ ] Slice 56's arc query maps rows through the table's entity column.
- [x] Contract: `spatial_index_build` carries `world_level` (Slice 84,
      `c52a5ff`).
- [ ] Tests: view columns equal direct lookups; stale-map and swap-remove
      safety; stage-3 level snapshot; serial == threaded; existing perception,
      AI, and pipeline suites unchanged.
- [ ] `FailingAllocator` proofs: spatial build on real workers and serial;
      perception and AI after reserve.
- [ ] Action fairness: deferral-age column, age-priority selection,
      contract tag, max-streak metric.
- [ ] Persistence: Slice 49 classification, Slice 46 field, relative bumps;
      64B rows for the derived table.
- [ ] Fairness tests: starvation bound, parity with rotation at zero ages,
      serial == threaded, cooldown kept, saturation.
- [ ] Soak procedure written in this slice with the row schema; pointer
      added to `.grok/rules/tests-benchmarks.md`.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      `docs/development-workflow.md`.

### Acceptance checks

- [ ] No main-thread walk over the sensed population remains in perception
      or AI.
- [ ] Table, stale-map, swap-remove, and serial == threaded tests pass at 0,
      1, and 2 workers and two range sizes.
- [ ] `FailingAllocator` proofs pass on serial and real multi-worker paths.
- [ ] `decide-consumers` at three population sizes shows main-thread cost
      linear in decide rows and lower than the baseline; `spatial_index`,
      `perception`, `ai`, and `ai-action-select` show no regression beyond
      run-to-run spread.
- [ ] Fairness bound, parity, determinism, cooldown, and saturation tests
      pass.
- [ ] Soak procedure executed: repeated hands-off soaks agree on counts, and
      the control table is recorded with the previous one kept as history.
- [ ] `zig build verify` passes.
