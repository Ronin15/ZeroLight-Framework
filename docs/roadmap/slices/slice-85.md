## Slice 85: Steering On The Shared Neighbor Index

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 84](slice-84.md), [Slice 86](slice-86.md) (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Routed by the 64G combined review (area D M1, M4,
L10) and the movement intent measurement. [Slice 35](slice-35.md) owns
vectorizing steering's per-neighbor math.

Goal: steering queries 84's shared index instead of building and sorting a
private grid; an entity create or destroy invalidates only what it changed in
steering's caches; steering's movement intents reach movement in an order that
keeps the apply local.

### Current foundation

- Private grid (`src/game/systems/steering.zig`): `buildAgentGrid` (`:689`),
  banded build (`:716`), `sortCellEntries` (`:2023`). It sorts the positions
  the spatial index already sorted.
- `changeInvalidatesSteeringMovementIndexCache` (`:2122`) drops the whole
  movement-index cache on any `entity_created`.
- `accumulateAgentAvoidanceBounded` (`:1938`) is scalar over up to 64
  candidates per agent and states no SIMD verdict; the sibling obstacle push
  is SIMD.
- Steering writes the movement intents (`:1794`) that
  `apply_ai_movement_intents` applies.
- Measured:
  - `production-step` tuned `--details` (Debug, `5d5a089`): `steering_grid`
    0.59 ms at spread P 16,384; steering 0.84 ms on main of a 9.8 ms step.
  - `movement-apply-intents` vs `movement-apply-intents-sorted`, 16,384
    intents, serial, ReleaseFast (`639f55d`): 61.5 vs 38.5 µs, with no false
    sharing between ranges.

### Architecture notes

- Neighbor queries use the shared index (`.claude/rules/simulation.md`);
  steering's private grid is not an allowed exception.
- A create costs work in what it changed (`.claude/rules/engine-design.md`
  § Cost model).
- Each hot loop carries a SIMD verdict (`.claude/rules/memory-performance.md`
  § SIMD); 35 lands the vectorized avoidance.
- Serial == threaded bitwise (`.claude/rules/threading.md`).

### Checklist

- [ ] Steering reads 84's index; its grid and sort are deleted. Failure
      scenario: two sorts of the same positions every step. Measured:
      `steering_grid` 0.59 ms above. Pass: one sort per step in the
      `production-step` census; `steering` within spread or faster.
- [ ] A create or destroy invalidates only the cache entries it affects
      (`:2122`). Failure scenario (derived): a spawn burst makes every
      steering row re-resolve its movement index that step, nanoseconds per
      row, threaded. Pass: a test that unrelated rows keep their cached
      index; a spawn-churn `steering` case flat in population for a fixed
      churn.
- [ ] A SIMD verdict at `accumulateAgentAvoidanceBounded` (`:1938`): scalar
      with its reason at the site until 35 vectorizes it.
- [ ] Movement intents in movement-row order if the ordering costs less than
      the apply gain. Measured gain above (ReleaseFast only; Debug numbers
      come first, `.claude/rules/build-validation.md`). Pass:
      `movement-apply-intents` within spread of `-sorted`, with the ordering
      cost counted in steering.
- [ ] The whole subsystem checked against the cost model and the rules
      (owner 2026-10-16), not only the items above: every file in
      `src/game/systems/steering/` (selection, directions, avoidance, the
      movement-intent write). Each finding becomes an item here.
- [ ] Tests: steering output on today's fixtures unchanged, or changed only by
      a stated order; serial == threaded; allocation-free warmed step.
- [ ] Docs: `docs/architecture.md` steering;
      `docs/simulation-tiers-and-pipeline.md` stage list.

### Acceptance checks

- [ ] `steering` at three sizes shows no regression beyond run-to-run spread;
      `production-step` steering main time no higher than at `5d5a089`.
- [ ] `zig build verify` passes.
