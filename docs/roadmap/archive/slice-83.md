## Slice 83: Core-Branch Prep — Steering And Pipeline Splits, Stage-Owned Tuners

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 50](../slices/slice-50.md) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: landed on `core_systems` (`3c42b4f`, `176ed03`, `13e88ad`);
`zig build verify` passes.** First on the core branch (owner 2026-10-16), so
the branch's later slices plan against the final layout, as
[81](../archive/slice-81.md) and [82](../archive/slice-82.md) did for it. Routed by the 64G combined review
(area D L11, and the per-system tuner item).

Goal: `steering.zig` and `simulation_pipeline.zig` are split by
responsibility with no behavior change, and every production stage dispatches
with a tuner it owns; no config field lets one tuner serve several stages, and
no stage falls back to `ThreadSystem`'s shared tuner.

### Current foundation

- Sizes at `5d5a089`: `src/game/systems/steering.zig` 4,538 lines;
  `src/game/simulation_pipeline.zig` 7,599, much of it scenario test fixtures.
  Test-support precedent: `collision_response_test_support.zig`,
  `world/test_support.zig`.
- At `5d5a089` (removed by `13e88ad`):
  - caller-settable tuner fields (only tests set them):
    `collision.zig:112-113`, `movement.zig:23`, `particle.zig:42`,
    `ai_memory.zig:83`, `affect.zig:126`, `perception.zig:182`,
    `ai.zig:310-311` (all `src/game/systems/`), and
    `src/render/sprite_batch.zig:236`;
  - null fallbacks to `ThreadSystem.adaptive_tuner`: `movement.zig:233`,
    `particle.zig:385`, `ai_memory.zig:140`, `sprite_batch.zig:529`.
- Pattern: 64G gave pathfinding and steering per-stage tuners (`2496824`).
- Measured: `production-step` (serial and tuned, every config, Debug,
  `5d5a089`) ends each run with the shared tuner untrained
  (`shared_tuner=learning/samples:0`), so no production stage reaches a
  fallback today.

### Architecture notes

- File moves only: no behavior, API, or test change beyond imports
  (81 and 82 precedent). Placement per `docs/architecture.md` § Source Layout.
- A production processor owns its tuner state (`.grok/rules/threading.md`).

### Checklist

- [x] Split `steering.zig` by responsibility (`3c42b4f`): six files in
      `src/game/systems/steering/`, the agent grid whole in `agent_grid.zig`.
- [x] Pipeline scenario fixtures moved to `pipeline_test_support.zig`, no
      further split (`176ed03`).
- [x] Stage-owned tuners at every site above and scope's `deriveChunks`,
      each with its own-tuner test (`13e88ad`).
- [x] Docs: `docs/architecture.md` § Source Layout and § Thread System (the
      Slice 83 docs commit).

### Acceptance checks

- [x] The splits change no test count or result (`3c42b4f`, `176ed03`).
- [x] Touched stage groups within run-to-run spread (Debug A/B of `13e88ad`
      against `176ed03`).
- [x] `zig build verify` passes at `13e88ad`.
