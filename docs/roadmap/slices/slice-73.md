## Slice 73: Data-Driven Cognition

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 33](slice-33.md) (landed; archive [31](../archive/slice-31.md), [32](../archive/slice-32.md)), [Slice 49](slice-49.md) · Before: [42](slice-42.md), [55](slice-55.md), [56](slice-56.md), [61](slice-61.md), [63](slice-63.md), [68B](slice-68b.md), [71A](slice-71a.md), [71C](slice-71c.md), [71D](slice-71d.md), [75](slice-75.md) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Owner direction 2026-10-08; gates every open slice
that adds a drive or behavior.

Goal: emergent AI with many emotions and decisions at target scale. Drives,
behaviors, their couplings, and multi-step tasks are content, resolved at
load, with counts derived from content. Adding a feeling or a behavior that
uses existing signals and goals is a content change, never per-drive or
per-behavior code. Per-agent cost follows the drives and behaviors its
archetype uses, never catalog size, so cognition stays affordable for every
agent in every world, including far from the observer at the slower ticks
of Slice 75 (`.claude/rules/engine-design.md` § Target scale).

### Current foundation

The arbitration contract is sound and kept; the structure around it is
sized to today's four drives and five behaviors:

- Drives: `AiAffectDrive` is a closed enum (`fear`, `curiosity`,
  `aggression`, `fatigue`; `src/game/data_system/types.zig`). `AiAffect`
  carries four named fields per drive (`baseline_*`, `decay_rate_*`,
  `threshold_*`, value) plus `above_threshold_mask: u8`, which caps drives at
  8; store and validation in `src/game/data_system/affect.zig`.
- Appraisal (`src/game/systems/affect.zig`): one hand-written path per drive
  (`processFearColumn`, `processAggressionColumn`, `processCuriosityColumn`,
  `processFatigueColumn`) over the shared `combineDrive` lerp, module-level
  gain constants (`gain_fear`, `gain_aggression`, `gain_curiosity_*`,
  `gain_fatigue`), fatigue exertion hard-coded as `pursue or flee`, and
  threshold crossings packed in a `u32` (`2 * affect_events_per_row_max <= 32`,
  a second cap at 16 drives).
- Behaviors: `AiBehavior` is a closed enum (`wander`, `pursue`, `flee`,
  `investigate`, `cohere`; `types.zig`). `AiAgent` has one named cold
  `gain_*` field per behavior plus `wander_amplitude`,
  `commitment_max_steps`, `sticky_bonus`; hot `active_behavior`,
  `commitment_remaining`, `last_score`.
- Scoring (`src/game/systems/arbitration.zig`): `behavior_count = 5` literal;
  `Signals` has a named field per drive; `drive_behavior_weight` is a dense
  comptime `[drive][behavior]` table; `gainFor`, `perceptionTerm`,
  `memoryTerm`, and `resolveGoal` are per-behavior switch arms with named
  bonus constants. `scoreBehaviors` is dense: every agent scores every
  drive × behavior pair. `selectSticky` (commitment, sticky bonus, minimum
  delta) and the Schmitt thresholds (`ai_affect_threshold_hysteresis`) are
  the hysteresis kept by this slice.
- AI processor (`src/game/systems/ai.zig`): main-thread `gatherAiData`,
  threaded `writeAiIntentsJob` → `resolveRowArbitration`, per-behavior
  `priorityForBehavior`; gain-gated focus, interest-marker, and cohere
  queries.
- Archetypes (`src/game/ai_archetypes.zig`, `assets/ai/archetypes.json`): a
  closed `AiArchetypeId` (8 ids) and a strict loader into an enum-indexed
  bundle table. The debug overlay (`src/game/ai_debug_overlay.zig`) draws
  per-drive bars and per-behavior colours.
- No task layer: a decision resolves one goal (`GoalResolution`); multi-step
  work (dig, haul, build) has no representation.
- Cognition runs only inside the cognition halo at a 1-in-4 stagger
  (`src/game/simulation_scope.zig` `cognition_halo_chunks`,
  `cognition_stagger_n`); beyond the tier bands entities are `dormant`.
  Slice 75 replaces that with slower ticks.
- `.claude/rules/simulation.md` § AI and affect ("appends an `AiAffectDrive`
  tag, its columns, one appraisal path, and one weight-table row") and the
  Emergent AI track's former add-a-feeling procedure encode the one-at-a-time
  shape.
- Benches: `ai`, `ai-affect`, `scope`, `perception`.

### Architecture notes

- Owner decisions (2026-10-08): utility scoring, sticky selection, and
  hysteresis drives are kept; drives and behaviors are data with counts from
  content; no per-drive or per-behavior code; sparse couplings and
  per-archetype behavior sets; a data-driven task/sequence layer under
  utility selection; the `u8` mask cap and the
  `.claude/rules/simulation.md` § AI and affect edit land with the design.
- Owner decisions (2026-10-08): factions are content, owned here (63 builds
  on them); only NPCs whose archetype can dig or has a reason to go
  underground choose goals on other levels, authored as archetype data and
  run by the task layer.
- Data resolves at load into dense ids and tables; hot paths never parse
  content or hash names (`.claude/rules/simulation.md` § AI and affect).
- Engine code provides a fixed set of signal and goal primitives
  (perception, memory, stimuli, markers, neighbors, focus; today's
  pursue/flee/investigate/cohere/wander goals) that content composes. The
  primitive set grows with engine features, never with content. Missing
  inputs contribute zero signal (`simulation.md`).
- Tasks are the execution of a utility-selected behavior, preemptible by
  reselection under the same hysteresis; never an exclusive FSM or behavior
  tree. Task progress is persistent per-agent state.
- Per-agent storage and work follow the archetype's drives, behaviors, and
  nonzero couplings; catalogs grow at load; nothing is sized to a fixed
  drive or behavior count (`.claude/rules/budgets-capacities.md`).
- 73 owns the per-agent think interval; 55's idle coasting and 75's
  distance bands are inputs to it. Drive decay and task timing are defined
  per elapsed step, so a slower tick lowers fidelity without changing
  rates.
- Serial equals threaded, SIMD equals scalar, and same-seed runs are
  bit-identical (`.claude/rules/threading.md`,
  `.claude/rules/memory-performance.md`, `.claude/rules/simulation.md`
  § Determinism).
- Persistent cognition state is `DataSystem`-owned, classified for 49/64B,
  and included in 46's v1; content fingerprints join 46's content
  fingerprint; versions bump relative to live (Tables T3/T6).
- Provides: 42 drives, coupling, and mood as content; 55's coast class as
  behavior data; 56 attack, 61 `need`/`forage`, 63 social impulses, 68B
  retaliation, 71A patrol/follow/return-home, 71C cover goals, 71D trade as
  content plus any new primitive; 63 factions; 75 runs cognition at slower
  ticks through the think interval.
- VoidLight reference: none; VoidLight behaviors are hand-coded classes.

### Checklist

- [ ] `.claude/rules/simulation.md` § AI and affect rewritten for
      catalog-defined drives and behaviors, in the same change as the
      design.
- [ ] Drive catalog in content (defaults, decay, thresholds, appraisal
      inputs over signal primitives); per-agent drive state sized from the
      archetype; the `u8` mask and `u32` crossing caps retired.
- [ ] Behavior catalog in content (scoring terms, goal primitive, priority,
      coast class, emitted action, exertion); per-archetype behavior sets and
      gains replace the named `gain_*` fields.
- [ ] Sparse drive → behavior weights and drive → drive coupling as
      per-archetype data.
- [ ] Engine signal and goal primitives addressed by data; per-behavior
      switch arms removed from arbitration, AI, affect, and the overlay.
- [ ] Task/sequence layer: content-defined multi-step tasks run under the
      selected behavior, preemptible with hysteresis; task state persistent.
- [ ] Today's four drives and five behaviors migrated to content with
      outputs equal to pre-change fixtures.
- [ ] Factions as content: per-archetype membership and relations.
- [ ] Cross-level goals for archetypes that can dig or have a reason to go
      underground, as archetype data run by the task layer.
- [ ] Per-agent think interval with idle coasting (55) and distance bands
      (75) as inputs; decay and task timing per elapsed step.
- [ ] Persistence: classified for 49/64B; included in 46's v1; content
      fingerprint; relative version bumps; stages and components stated for
      Tables T4/T5.
- [ ] Tests: strict catalog validation, parity, serial == threaded, SIMD ==
      scalar, missing-signal zero, `FailingAllocator` proofs.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      the archetype authoring doc, and the Emergent AI track.
- [ ] Re-base 42, 55, 56, 61, 63, 68B, 71A, 71C, and 71D checklists on the
      landed catalog.

### Acceptance checks

- [ ] A fixture catalog that adds drives, behaviors, and a task over
      existing primitives loads and runs with no code change.
- [ ] Demo archetypes produce scores, behaviors, and intents equal to the
      pre-change fixtures.
- [ ] A `cognition-scale` bench group (agent count, catalog size, and
      archetype set size, three points each) shows per-agent cost flat in
      catalog size and linear in agent count and used set size
      (`.claude/rules/tests-benchmarks.md`).
- [ ] `ai`, `ai-affect`, and `scope` show no regression against a baseline
      taken before the first change.
- [ ] `zig build verify` passes.
