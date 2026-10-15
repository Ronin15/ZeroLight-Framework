## Slice 55: Cognition Think-Interval Coasting (Decision LOD)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md) · Before: [Slice 75](slice-75.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.**

Goal: idle agents run the decide path (AI gather, separation, cohere, marker
scan, score / select / resolve, intent emit, and the steering and path work
that follows) less often than alert ones, coasting on persisted velocity and
behavior in between. Any sensing signal that could give the agent a goal
puts it back on the base cadence on the same step. The interval and wake are
pure functions of deterministic state (behavior class, sensing columns,
drive thresholds, distance band from the fixed-step sim view, entity index,
step), never wall clock, render cadence, or measured cost. Sensing never
coasts. Coasting is one input to Slice 73's per-agent think interval;
Slice 75's distance bands are another.

### Current foundation

- Stagger: `cognition_stagger_n = 4` and `stagger_phase` assigned at
  movement-body append (`src/game/simulation_scope.zig`); the tier and LOD
  distance helpers live there too.
- `SimulationScopeSystem` (`src/game/systems/simulation_scope.zig`) gathers
  the unstaggered halo and the staggered think set (`gatherAiPopulations`
  with a serial twin, padded per-range slots, range-ordered merge).
- `simViewRegion(context)` in `src/game/simulation_pipeline.zig` is the one
  scope-band source; `stageTierPolicy` already reads it.
- Coasting already happens off-phase: an agent with no `NavigationIntent` is
  never selected by steering, and `MovementSystem.applyIntents` leaves its
  velocity alone.
- `AiSystem.gatherAiData` (`src/game/systems/ai.zig`) accepts any ordered
  subsequence of the halo as its think list; `resolveRowArbitration`
  persists `active_behavior`, `commitment_remaining`, `last_score`.
- Arbitration (`src/game/systems/arbitration.zig`): a score is
  `gain × (...)`, so inputs only zero-gain behaviors consume cannot change
  the selection; `resolveGoal` gives pursue / flee / investigate a goal only
  from a threat, fresh memory, focus, stimulus, marker, or ring contact.
- Slice 47 guards: the dual-list perception test and the sticky dig-linger
  test in `simulation_pipeline.zig`.
- Benches: `ai` (every row thinks, no scope) and `scope` (halo / think
  gathers, then AI).

### Architecture notes

- Composes with the stagger: the stagger stays the sensing cadence and the
  alert decide cadence; coasting is a per-agent power-of-two multiple of it.
  Replacing the stagger would re-couple sensing to thinking, the Slice 47
  defect class.
- Only the decide path coasts; perception, memory, affect, and the spatial
  index keep their cadence, so a coasting agent is still seen, avoided, and
  cohered with, and still perceives what wakes it.
- Classification reads Slice 73's behavior data (coast class, which signals
  can resolve a goal), never a per-behavior switch; a producer that adds a
  goal-resolving signal adds it to the alert inputs.
- Wake reads columns written this step before the decision, never event
  streams, which are capped per step and may drop.
- No new persistent state: the cached decision is state that already
  persists; phase is a stateless hash of the entity index (a named
  exemption in Slice 49's determinism contract).
- Fixed power-of-two intervals and a fixed distance band, never scaled to
  population, world size, or cost; coasting only removes work, so there is
  no cap or deferral (`.claude/rules/budgets-capacities.md`).
- The decide set never depends on the render window
  (`.claude/rules/simulation.md` § Scope and tiers).
- Threaded gather with a serial twin, range-ordered merge
  (`.claude/rules/threading.md`).
- Provides: idle coasting as one input to 73's per-agent think interval
  (75's distance bands are another); the decide set that Slice 68A's shared
  table is walked by. 75 replaces the halo bound on the think set.
- VoidLight reference: `WanderBehavior` throttles idle movement with urgent
  checks bypassing it; ported as fixed step intervals with a stateless
  phase, not per-entity timers or a thread-local query cache.

### Checklist

- [ ] Pure coast contract (classes, intervals, phase, decide-on-tick) with
      unit tests: each alert input alone, band boundary, agitation override,
      phase spread, exact decisions per cycle.
- [ ] Threaded decide-set gather with a serial twin, fed from the think set.
- [ ] Pipeline: new stage between affect and AI decide with its resource tag
      and contract; AI decide reads the decide set; scope stats count coast
      skips.
- [ ] AI early-out on an empty think list.
- [ ] Diagnostics: coast-skip metric and stage timer.
- [ ] Tests: wake preempts the interval on the same step; gain-0 inputs
      still coast; decide ⊆ think order; load spread; serial ==
      threaded over worker counts and range sizes; `FailingAllocator` proof
      on the real multi-worker path.
- [ ] Pipeline tests: causal wake after perception; Slice 47 guard; decide
      set independent of the render window; existing per-agent tests
      audited for the longer cadence.
- [ ] Benches `ai-idle-stagger` (control) and `ai-idle-coast` on one
      fixture; the `scope` bench inserts the decide gather.
- [ ] Docs: `docs/architecture.md` scope paragraph,
      `docs/simulation-tiers-and-pipeline.md`, bench examples in
      `docs/development-workflow.md`.

### Acceptance checks

- [ ] Sensing is never coasted: contract test, the Slice 47 dual-list and
      dig-linger tests, and the coast-step guard test pass.
- [ ] A not-due agent decides in the same step its sensing produces a
      gain-relevant threat or stimulus (unit and pipeline).
- [ ] Decide sets are identical for serial and threaded runs at any worker
      count and range size.
- [ ] Every idle agent decides exactly once per cadence window; per-step
      load is spread by the phase hash.
- [ ] `ai-idle-coast` decides the analytic fraction of think rows, and its
      per-step cost tracks decided rows at three population sizes against
      `ai-idle-stagger`; `ai` is unchanged
      (`.claude/rules/tests-benchmarks.md`).
- [ ] `zig build verify` passes.
