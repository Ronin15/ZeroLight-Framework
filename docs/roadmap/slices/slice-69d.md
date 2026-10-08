## Slice 69D: Scripted Weather Override

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 59](slice-59.md), [Slice 69B](slice-69b.md) (when regions exist) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first scripted weather consumer** (a
quest, cutscene, or world-event controller that must force weather for a
window, such as "a storm starts when the quest begins"). That consumer's
slice lands this checklist in the same change, so no request API ships
without a producer.

Goal: a deterministic, persistent, per-region weather override window that
blends in and out over Slice 59's transition time. Weather stays a pure
function of `(config, env_seed, game_ms, overrides)`, so an expired override
needs no sweep.

### Current foundation

- Slice 59 (not landed): weather is a pure function of time; transitions blend
  over a fixed transition time; `weather_changed` fires from the snapshot
  diff. Slice 69B (not landed) makes it per region.
- The commit seam already applies post-commit reactions in order
  (`applyStructuralCommandsAndPostCommitEvents`); Slice 61 plans its affect
  impulse drain there.

### Architecture notes

- One override slot per region per world, stored on `WorldSystem`, hashed and
  saved (Slices 49 / 46); a load rejects an invalid override.
- Producers append scalar set/clear requests during the step; they apply at
  the commit seam in append order under a fixed per-step count, and requests
  past it defer in order to the next step, never refused for queue capacity
  (`.claude/rules/budgets-capacities.md`). Invalid requests (bad region,
  out-of-range duration) are counted and dropped.
- A request applied at the seam takes effect in the next step's snapshot;
  nothing is pending at a step boundary that a save would miss.
- The override blends from the natural weather into the forced kind, holds,
  then blends back to the natural weather at the time it ends.
- VoidLight: port forced weather with a transition time; do not port string
  weather names, the no-op force path, or caller-thread dispatch.

### Checklist

- [ ] Per-region override store on `WorldSystem`; classification and save
      section with validation.
- [ ] Scalar override requests with ordered seam application and in-order
      deferral past the per-step count.
- [ ] Pure override blend in the snapshot derivation.
- [ ] Override resource external to the stage graph, carried by the
      environment stage.
- [ ] The gating consumer's producer call, in the consumer's slice.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md` (override seam, purity).

### Acceptance checks

- [ ] Blend in, hold, blend out, natural after; replaced and cleared
      mid-window; N steps == one jump with an override active.
- [ ] A request at step N shows in step N+1's snapshot; a burst past the
      per-step count applies over later steps in order.
- [ ] Save/load with an active override reproduces the checksum trace; an
      invalid saved override is rejected.
- [ ] `FailingAllocator`: append, apply, and derive allocate nothing.
- [ ] `zig build verify` passes.
