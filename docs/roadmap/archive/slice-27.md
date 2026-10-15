## Slice 27: Deterministic Per-Entity RNG Facility

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: provide reproducible randomness for AI (wander jitter, appraisal noise,
investigate targets) that does not break the determinism contract
(serial == threaded, replayable, range-order-independent).

Current foundation:

- `src/core` owns shared math/SIMD/logging helpers but has no deterministic RNG
  facility; existing wander randomness is ad hoc.
- The fixed-step loop provides a stable per-step index usable as an RNG input.

Architecture notes:

- A counter-based / hash-based stream (e.g. `hash(entity_index, step, salt)`) is
  required rather than a stateful PRNG, so a worker can derive an entity's noise
  independent of range partitioning or execution order.

Checklist:

- [x] Add a stateless, seeded, splittable RNG in `src/core` keyed by
      `(entity_index, step, salt)` returning uniform f32 / bounded ints.
- [x] Document the determinism guarantee: same inputs → same outputs regardless
      of thread count or range order.
- [x] Migrate existing AI wander randomness onto it as the first consumer.

Acceptance checks:

- [x] Identical RNG outputs across serial and threaded runs for the same step.
- [x] No per-call allocation; no shared mutable RNG state across workers.
- [x] `zig build test` covers reproducibility and distribution bounds.

`src/core/rng.zig` adds `mix64`/`uniformF32`/`boundedU32`/`unitVec2`, generalizing
the splitmix64-style mixer that was previously a private, non-reusable helper
inside `ai.zig`. The migration also fixed a real bug, not just a refactor: the
old call was keyed only by a hardcoded seed and the entity's dense index, both
constant over time, so wander direction never resampled. `SimulationScopeSystem`
now exposes `currentStep()`, `SimulationPipeline` threads it into `AiConfig.step`
each fixed step, and `ai.zig`'s `decideDir` keys its wander draw off
`(seed, entity_index, step, wander_rng_salt)` so direction actually varies over
time while staying deterministic for a fixed step and identical across serial
and threaded runs. A first landing resampled on every AI-active step, which
review caught as trading the "never varies" bug for a "zero continuity" one
(uncorrelated direction every tick reads as jitter, not wandering). Fixed by
quantizing `step` into coarser epochs (`AiConfig.wander_resample_period_steps`,
default 300 steps / 5s at 60Hz) before hashing, so direction holds steady for a
stretch and then jumps to a new per-entity-distinct heading.


