## Slice 48: SimulationPipeline Thin-Composer Restoration

**Status: complete (archived).** Restores the thin-composer contract:
`stage_order` executes through `runStage`, sensory policy lives on `SensoryBus`,
and movement/world/event budgets live with their producers.

Goal: restore [architecture.md](../../architecture.md)'s thin-composer contract by
binding `stage_order` to execution, extracting the sensory bus into a controller,
evicting movement/world domain logic to its owning systems, and moving event and
allocation budgets to their producers — so the comptime stage graph governs what
actually runs and the composer stops owning cross-step state and policy.

### Problem

`update()` is `StepState.init`, an `inline for` over `stage_order`, and
`finish`. `runStage` is an exhaustive switch, so a reorder that breaks a
declared read fails the build. `StageContract.carried` is disjoint from reads
and writes. Event payloads are four tags (`perception_events`, `affect_events`,
`world_events`, `structural_events`); `stimuli`, `interest_markers`, and
`ai_behavior` are tagged. `SensoryBus` owns deferred impacts, sticky linger,
and the hearing scratch. `emit` is the live-bus gate: required dig fails with
`StimulusCapacityExceeded` before the tile write, optional emitters drop and
count. `writeLiveStimulus` stays the unchecked frame append because
`simulation.zig` cannot import the bus. Movement intents, the tile gate, and
plane traversal live on `MovementSystem`, `world_gate`, and `DigController`.
`maxEventsPerStep` is a fixed per-producer budget. Cognition systems reserve at
init; `Pipeline.reserve` tops up frame events without lowering a higher limit.
`world_gate` stays scalar; SIMD is a Scaling Gap, not this slice.

### Checklist

- [x] **Contract vocabulary** (declaration-only): add a `carried` field to
      `StageContract` (checked disjoint from `reads`, required to be written by
      some stage) so `.reads = .empty` regains its meaning; split `.events` into
      `perception_events`/`affect_events`/`world_events`/`structural_events` (a
      stage-0-written tag must not vacuously satisfy every downstream read); add
      `.stimuli`/`.interest_markers`/`.ai_behavior` tags and `ai_decide`'s
      missing write; add a `stage_order` permutation comptime check.
- [x] **Bind the graph**: add `StepState`, one private `stage<Name>` method per
      stage (carrying its own `StageTimer`), `runStage(comptime id)` with an
      exhaustive switch, and `inline for (stage_order) |id| try runStage(...)`;
      `update()` drops to init, the inline loop, and finish. Delete
      `.action_intent_capture` (no body) → `carried = {action_intents}` on
      `.action_react`. Comptime `EnumSet` walks use `@setEvalBranchQuota(4000)`.
- [x] **Extract `SensoryBus`** (`src/game/sensory_bus.zig`, in the
      DigController/AudioController mold): sensory state, promote/footstep/
      hearing/sticky/impact enqueue, and `StimulusConfig`
      (`footstep_min_speed_sq`, `impact_min_approach_speed_sq`,
      `impact_min_penetration`). `contact_query.zig` shares
      `clamp(penetration/18, 0.25, 1)` with audio. Sticky capacity is the fixed
      `(stimulus_max_impacts_per_step + 1) * (cognition_stagger_n - 1)` (27),
      with a counted `stimuli_sticky_dropped` on overflow.
- [x] **Evict domain logic**: `applyPlaneTraversalStage` → `DigController`, with
      plane scratch reserved once to `movement_body_capacity + 1`; the
      gate/clamp/`rectOverlap` family → `src/game/systems/world_gate.zig`
      (scalar; SIMD is a separate benched follow-up in Scaling Gaps);
      `applyAiMovementIntents` → `MovementSystem.applyIntents`.
- [x] **Own the budgets**: `SimulationPipeline.reserve(frame, pop)` tops up
      events to the sum of `maxEventsPerStep` and reserves cognition scratch.
      `ai`/`perception`/`affect`/`ai_memory` `reserve` runs from pipeline init.
      Their `FailingAllocator` tests are reserve-then-run. `EventProducerId` is
      exhaustive. The composite `pipeline.update` test (dig + fall + contact,
      smallest multi-level world) swaps frame stream allocators to
      `FailingAllocator` after reserve and allocates nothing on those streams.
- [x] **Ordering-backstop tests**: fear selects `.flee` before movement; a
      contact push across a chunk boundary leaves `chunk_derive` matching the
      settled pose; perception acquire refreshes memory `last_known` the same
      step; the investigate-marker row is in the AI serial/threaded parity test.
- [x] **Follow-ups**: producers go through `SensoryBus.emit`. A full live bus
      fails dig and leaves the tile unchanged; optional emit drops once and
      counts it. The AI bench fixture sets memory, affect, and two investigate
      markers. `findBestInvestigateMarker` runs in `writeAiSeparationJob`, and
      only when `gain_investigate > 0`.
- [x] [architecture.md](../../architecture.md),
      [simulation-tiers-and-pipeline.md](../../simulation-tiers-and-pipeline.md), and
      `docs/coding-standards.md` (since replaced by `.claude/rules/`) record `carried`, the four
      event tags, `runStage`, and `SensoryBus` stage placement. `stimuli` and
      `interest_markers` are tagged resources.

### Acceptance checks

- [x] `update()` is a short `runStage` loop; no untagged sensory mutation
      remains; reordering `stage_order` either fails to compile or fails a causal
      test.
- [x] The sensory bus, `world_gate`, and movement-intent apply live in their
      owning modules; the pipeline composes them like `DigController`.
- [x] Every per-step budget stays fixed/world-size-independent; the composite
      `update()` path is proven allocation-free-after-reserve by `FailingAllocator`.
- [x] `zig build bench -- --group ai` and `--group movement` (quick profile)
      completed. Movement serial throughput stayed flat (~48–50M bodies/s at
      1024/4096/10000). The ReleaseSafe in-game AI-stage band (0.15–0.20 ms) is
      a gameplay soak, not this microbench, and is unchanged. `world_gate` SIMD
      remains a Scaling Gap. `zig build verify` passes.

