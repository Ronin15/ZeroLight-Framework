## Slice 47: Un-Stagger The Shared Sensing Substrate

**Status: complete (archived).** Live perception defect: stagger-filtered
`ai_indices` were fed to both thinking and sensing, so cognition NPCs could
not perceive one another. Highest-priority AI-track correctness item; landed
before Slice 48.

Goal: build the shared spatial index and perception candidate set over the full
cognition-halo population, using cognition stagger only to choose which agents
*think* this step — so two observers on different stagger phases can sense each
other, and a timid `.ally` can see the hostile it is meant to flee.

### What landed

- `gatherAiPopulations` / `Serial`: one threaded halo gather (tier + region, no
  stagger) plus a main-thread compact into the think set. Null `cognition_region`
  keeps both lists identical (no stagger).
- `spatial_index.build` and perception **candidates** consume `ai_halo_indices`.
  Perception observers, memory, affect, and AI decide consume
  `ai_cognition_indices`.
- `AiSystem` copies perception's `candidates` + `spatial_self_index` mapping;
  cohere/separation no longer assume index-row == AI-row. Player fold-in stays
  hostile-only. Per-query caps unchanged.
- `PipelineResource`: `ai_halo_indices` + rename `ai_scope_indices` →
  `ai_cognition_indices`. No Slice 48 `carried` / SensoryBus / `runStage`.

### Checklist

- [x] `spatial_index.build` and perception's candidate gather run over the
      unstaggered cognition-halo population.
- [x] Cognition stagger applies only to the observer/decider (thinking) set.
- [x] `ai.zig` gains a candidates side table + `spatial_self_index` mapping so
      cohere neighbor queries no longer assume index-row == AI-row.
- [x] Test with a non-null `cognition_region` and two observers on different
      stagger phases asserting mutual perception.
- [x] Verify a timid `.ally` perceives a hostile once its cohort is not filtered.

### Acceptance checks

- [x] Two cognition observers on distinct stagger phases perceive each other in
      the same step (candidate presence this step; observers stay staggered).
- [x] Serial==threaded and scalar==SIMD parity hold; think budget stays ~N/4.
- [x] No AI/perception bench regression at battle scale; `zig build verify` passes.

