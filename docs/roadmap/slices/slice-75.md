## Slice 75: Far Simulation

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md), [Slice 73](slice-73.md) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.**

Goal: fidelity falls with distance from the observer (the camera focus, or
a player when a game has one), and nothing that exists stops advancing.
Far-off AI thinks on slower ticks instead of being skipped; movement stays
near full rate; `dormant` holds only inert things (items at rest), which
still change slowly (decay outdoors); only unimportant ambient spawns may be
recycled far from the observer, never important population. Scope derives
from the observer (`docs/architecture.md` § Target Model). This slice covers
the observer's world; 74 applies the lowest band to worlds the observer is
not in.

### Current foundation

Scope comes from one camera and puts far entities to sleep.

- Tiers (`src/game/simulation_scope.zig`): `SimulationTier` `dormant`,
  `kinematic` (moves, no collision), `locomotion` (moves and collides),
  `cognition` (adds AI, steering, path requests). `allowsCognition` is true
  for `cognition` only, so `kinematic` and `locomotion` rows never think.
- Bands: `tierForChunkDistance` over `cognition_halo_chunks` (16),
  `locomotion_halo_chunks` (32), and `kinematic_halo_chunks` (48) chunks
  past the view; `ActiveRegion.lodDistance` adds `level_distance_chunks`
  (16) per level away from the view's level.
- Tier policy (`scanTierPolicy` in `src/game/systems/simulation_scope.zig`,
  stage `tier_policy`) demotes every row that is not `always_active` past
  `kinematic_halo_chunks` to `dormant` through `set_simulation_tier` commands
  at the commit seam. Entering `dormant` zeroes velocity
  (`DataSystem.snapInterpolationIfStill`), so dormant rows freeze while
  movement integrates the full contiguous range.
- Inside the cognition halo an agent thinks one step in
  `cognition_stagger_n` (4) by `stagger_phase`; `gatherAiPopulations`
  excludes out-of-halo agents entirely; the spatial index and perception
  candidates use the unstaggered halo; `always_active` bypasses halo,
  stagger, and demotion.
- Source: `simViewRegion` (`src/game/simulation_pipeline.zig`) reads
  `sim_view` = `GameDemoState.simViewRect()`, the camera as of the previous
  step's end (`updateCamera` runs after `pipeline.update`), anchored at
  `player.current_level`. Render visibility never feeds it.
- Full-active fallback: a world with no chunks yields no region, so no halo,
  stagger, or demotion applies and everything runs at full cost.
- One observer, one view, one world (74).
- Movement integrates every row (`src/game/systems/movement.zig:47`) and the
  tier policy scans every row (`scanTierPolicy`,
  `src/game/systems/simulation_scope.zig:689`), rows at rest included.
- Measured, `production-step` tuned (Debug, `5d5a089`):
  - At the base config (spread P 4,096, 1024², 8 levels), half the rows are
    dormant and 101 think per step. At L 32, 87% are dormant; at side
    2048, 68%. Across spread P 1,024 → 16,384, only 28 → 436 rows think per
    step.
  - The step gets cheaper as rows freeze: 4.76 / 2.29 / 1.09 ms at L 1 / 8 /
    32, and 3.12 / 2.29 / 1.28 ms at side 512 / 1024 / 2048. The group's pass
    shape requires every row to advance.
  - Inert rows (0, 1, 4 per agent at P 4,096) take tiers like agents and
    raise the step 2.29 → 3.42 → 7.31 ms.
  - `untimed` (stages with no perf-log timer: scope advance, tier policy,
    collision scope gather, plane traversal, action react, dig) is 2–20% of
    the step.

### Architecture notes

- Owner direction (2026-10-08), fixed: far AI thinks on slower ticks;
  movement stays near full rate; `dormant` only for inert things, which still
  change slowly; only unimportant ambient spawns are recycled, far from the
  observer; worlds the observer is not in still step; nothing is evicted from
  the simulation (`.claude/rules/engine-design.md` § Target scale).
- Tiers set fidelity, never whether an entity advances
  (`.claude/rules/simulation.md` § Scope and tiers); the live tier policy and
  the halo-only AI gather contradict this and are replaced.
- Cadences are pure functions of deterministic state (band, entity,
  `StepIndex`), never wall clock, render cadence, or measured cost
  (`.claude/rules/simulation.md` § Determinism). Per-step work budgets are
  fixed counts with deterministic deferral
  (`.claude/rules/budgets-capacities.md`).
- Scope derives from the observer's fixed-step view and defines a lowest
  band that 74 applies to worlds the observer is not in, instead of the
  full-active fallback. The Scope-and-tiers rule names a single `sim_view`
  and is updated in the same change.
- Far agents path over the whole-world chunked nav within the fixed per-step
  request budget (`.claude/rules/pathfinding.md`; needs 64G).
- 62 owns the important/ambient population classes and the recycling
  itself; 75 provides the deterministic far-from-observer signal it uses.
- 75 owns spatial-index coverage of the whole population: every agent thinks,
  so every agent is indexed for perception and steering queries, in every
  band.
- Per-step cost follows population divided by each band's cadence, never
  world extent × world count; serial and threaded paths with parity
  (`.claude/rules/threading.md`).
- Needs from 64G: whole-world chunked nav. From 73: the per-agent think
  interval, which 75's distance bands feed as one input (55's idle coasting
  is another).
- Provides: the far-from-observer signal 62's ambient recycling uses; the
  lowest band 74 applies to worlds the observer is not in.
- New persistent scope state is classified for 49/64B and included in 46's
  v1.

### Checklist

- [ ] Fidelity bands from the observer, including a lowest band for 74; the
      § Scope and tiers rule in `.claude/rules/simulation.md` updated in the
      same change.
- [ ] Every agent thinks, at a tick 73's interval derives
      with the band as an input; no agent is excluded from cognition by
      distance.
- [ ] The spatial index covers the whole population in every band.
- [ ] Movement and terrain gating near full rate in every band; collision
      fidelity per band set by the design pass.
- [ ] `dormant` reserved for inert rows, which still advance (57 schedules
      item decay); agents are never dormant.
- [ ] Rows at rest cost no per-step movement or tier-scan work
      (`movement.zig:47`, `simulation_scope.zig:689`). Failure scenario: items
      and resource nodes at rest raise every step's cost (measured above).
      Pass: `production-step` flat in inert rows. Collision's share is
      [86](slice-86.md); render collect's is [87](slice-87.md).
- [ ] Perf-log timers for the untimed stages, so the census attributes the
      2–20% `untimed` share (`.claude/rules/threading.md`: per-stage timing
      before a policy change).
- [ ] A deterministic far-from-observer signal for 62's ambient
      recycling.
- [ ] Far path requests over the whole-world nav within the fixed request
      budget.
- [ ] New persistent scope state classified for 49/64B; included in 46's
      v1.
- [ ] Tests: an agent in every band advances (thinks, moves, paths) at its
      cadence; the far signal is deterministic; results are identical across render cadence and worker
      count; serial equals threaded.
- [ ] Bench `far-sim`: per-step cost at three or more populations and world
      sizes with most agents far from the observer.
- [ ] Docs: `docs/architecture.md` tier model; `docs/simulation-tiers-and-pipeline.md`
      scope, bands, and cadences.

### Acceptance checks

- [ ] No entity stops advancing because of distance from the observer
      (tests over every band).
- [ ] `far-sim` matches the cost model (linear in population ÷ cadence);
      `scope`, `ai`, and `steering` show no near-observer regression beyond
      run-to-run spread.
- [ ] `production-step` meets its pass shape on the level-count and
      level-side axes with every row advancing at its tier.
- [ ] Manual (display, Debug): NPCs revisited after travelling far away have
      moved and acted.
- [ ] `zig build verify` passes.
