## Slice 75: Far Simulation

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md); [Slice 73](slice-73.md) for its think-interval item; its core-branch items after [Slice 88](../archive/slice-88.md) (branch order) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: in progress.** Inert rows, tier mechanics, the tier docs, the dig-stage bench timer, the far-from-observer signal, far path requests, the scope-state classification, and the scope-file audit have landed. Still open: 73's think interval, five audit findings below, the tests item, and acceptance. Its core-branch items (owner 2026-10-16; index,
merged order 9b) are the inert-rows item and the tier mechanics: fidelity
bands, every agent thinking at its band's cadence, whole-population index
coverage, movement near full rate, and `dormant` for inert rows only. They
need nothing from 73; 73's per-agent interval later takes the band as one
input (Architecture notes).

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
  excludes out-of-halo agents entirely; the spatial index (every neighbor
  query's candidates) indexes the unstaggered halo, and the think set is its
  rows on this step's phase, in the index's cell-major order
  (`ai_cognition_order`, Slice 84); `always_active` bypasses halo, stagger,
  and demotion.
- Source: `simViewRegion` (`src/game/simulation_pipeline.zig`) reads
  `sim_view` = `GameDemoState.simViewRect()`, the camera as of the previous
  step's end (`updateCamera` runs after `pipeline.update`), anchored at
  `player.current_level`. Render visibility never feeds it.
- Full-active fallback: a world with no chunks yields no region, so no halo,
  stagger, or demotion applies and everything runs at full cost.
- One observer, one view, one world (74).
- Movement integrates every row (`src/game/systems/movement.zig:55`) and the
  tier policy scans every row (`scanTierPolicy`,
  `src/game/systems/simulation_scope.zig:576`), rows at rest included.
- Measured, `production-step` tuned (Debug, `5d5a089`):
  - At the base config (spread P 4,096, 1024², 8 levels), half the rows are
    dormant and 101 think per step. At L 32, 87% are dormant; at side
    2048, 68%. Across spread P 1,024 → 16,384, only 28 → 436 rows think per
    step.
  - The step gets cheaper as rows freeze: 4.76 / 2.29 / 1.09 ms at L 1 / 8 /
    32, and 3.12 / 2.29 / 1.28 ms at side 512 / 1024 / 2048. The group's pass
    shape requires every row to advance.
  - Inert rows take tiers like agents and raise the step on the
    `production-step` inert axis ([86](../archive/slice-86.md) holds the
    numbers). This slice's collision checklist item carries collision's share.
  - `untimed` (stages with no perf-log timer: scope advance, tier policy,
    collision scope gather, plane traversal, action react, dig) is 2–20% of
    the step.

### Architecture notes

- Owner direction (2026-10-08), fixed: far AI thinks on slower ticks;
  movement stays near full rate; `dormant` only for inert things, which still
  change slowly; only unimportant ambient spawns are recycled, far from the
  observer; worlds the observer is not in still step; nothing is evicted from
  the simulation (`.grok/rules/engine-design.md` § Target scale).
- Tiers set fidelity, never whether an entity advances
  (`.grok/rules/simulation.md` § Scope and tiers).
- Cadences are pure functions of deterministic state (band, entity,
  `StepIndex`), never wall clock, render cadence, or measured cost
  (`.grok/rules/simulation.md` § Determinism). Per-step work budgets are
  fixed counts with deterministic deferral
  (`.grok/rules/budgets-capacities.md`).
- Scope derives from the observer's fixed-step view and defines a lowest
  band that 74 applies to worlds the observer is not in, instead of the
  full-active fallback. The Scope-and-tiers rule names a single `sim_view`
  and is updated in the same change.
- Far agents path over the whole-world chunked nav within the fixed per-step
  request budget (`.grok/rules/pathfinding.md`; needs 64G).
- 62 owns the important/ambient population classes and the recycling
  itself; 75 provides the deterministic far-from-observer signal it uses.
- 75 owns spatial-index coverage of the whole population: every agent thinks,
  so every agent is indexed for perception and steering queries, in every
  band.
- Think work follows population divided by each band's cadence. The index
  and movement follow the agents, every step. None of that grows with world
  extent (`.grok/rules/engine-design.md` § Cost model). Serial and threaded
  paths have parity (`.grok/rules/threading.md`).
- Think-set membership is the rows that can think this step. It does not
  scan the indexed population to drop the ones that are not due. The index
  still covers every AI row (`.grok/rules/engine-design.md` § Cost model).
- Needs from 64G: whole-world chunked nav. From 73: the per-agent think
  interval, which 75's distance bands feed as one input (55's idle coasting
  is another).
- Provides: the far-from-observer signal 62's ambient recycling uses; the
  lowest band 74 applies to worlds the observer is not in.
- Persistent scope state is the hashed movement-row fields and the
  stagger-arrival history in the checklist. This item adds no column, no
  hasher, and no tag. 49 writes the lists, 64B walks the hashed fields, and
  46's v1 saves them. `was_far` stays with 62.

### Checklist

- [x] Fidelity bands from the observer, including a lowest band for 74; the
      § Scope and tiers rule in `.grok/rules/simulation.md` updated in the
      same change. Landed: `cognition` / `locomotion` / `kinematic` / `lowest`
      at 16 / 32 / 48 chunks and beyond, think cadences 4 / 16 / 32 / 64.
      A null region assigns `lowest`.
- [x] Every agent thinks at its band's cadence; no agent is excluded from
      cognition by distance. The think set is the due groups of the whole
      AI population.
- [ ] 73's per-agent think interval takes the band as one input (after 73).
- [x] The spatial index covers the whole population in every band.
- [x] Movement and terrain gating near full rate in every band; collision
      fidelity per band set by the design pass. Movement stays on `advancing`.
      Cognition and locomotion collide every step. Kinematic and `lowest`
      stay past `dynamic_ids[0..colliding)`.
- [x] `dormant` reserved for inert rows, which still advance (57 schedules
      item decay); agents are never dormant. Distance does not write
      `dormant`.
- [x] Rows at rest cost no per-step movement or tier-scan work
      (`movement.zig:55`, `systems/simulation_scope.zig:576`). Failure scenario: items
      and resource nodes at rest raise every step's cost (measured above).
      Pass: `production-step` flat in inert rows. Collision's share is
      the item below; render collect's is [87](slice-87.md).
      Landed: an at-rest row is the suffix past `advancing`. Movement, tier
      policy, chunk derive, the world gate, and plane entry dispatch that
      prefix. Measured (Debug, `x86_64_v2`, tuned, `settled=no`, so the step
      times are not the verdict): inert 0, 1, and 4 at spread P 4,096 keep
      movement, tier policy, chunk derive, world gate, and plane entry at
      4097 `items/call` while rows go 4101, 8197, 20485.
      `scope_movement_stage_entities=4097`.
- [x] Collision's share of rows at rest (moved from 86). Failure: an inert
      row in a collision tier is gathered, sorted, and swept every step.
      Measured (`production-step` tuned, Debug, `5d5a089`, spread P 4,096):
      0, 1, 4 inert rows per agent give collision main 0.63 / 1.37 / 3.76 ms
      and collision bodies 1,541 / 3,077 / 7,685. Pass: `production-step`
      collision cost flat in inert rows. It runs in the inert-row step after
      slice 88. Landed: an at-rest bounds row leaves `dynamic_ids`. On the
      same three items, collision fill stays at 1537 `items/call`. The tuned
      cases printed `settled=no`, so collision main is not the verdict.
- [x] Bench-only (`--details`) timers for the untimed stages, so the
      `production-step` census attributes the 2–20% `untimed` share before
      this slice's policy change (`.grok/rules/threading.md`). Landed
      (`f59cf3b`) for scope gather, cognition order, collision scope, plane
      traversal, tier policy, and action react (`BenchTiming`,
      `src/app/runtime_perf_log.zig:331-338`; census
      `benchmarks/production_step.zig:668-689`). Landed:
      `pipeline_dig_world_edit` on `stageDigWorldEdit`, census via the
      `BenchTiming` tags, not in `Timing`.
- [x] A deterministic far-from-observer signal for 62's ambient
      recycling. `farFromObserver(tier, was_far)` follows the stored tier;
      `kinematic` holds the caller's bit; nothing is stored.
- [x] Far path requests over the whole-world nav within the fixed request
      budget. Every band, including `lowest`, already emits one request.
      A zero admission budget leaves them `.pending`. The solve ceiling
      stays `default_max_solves_per_frame` (512).
- [x] New persistent scope state classified for 49/64B; included in 46's
      v1. No column, hasher, or tag added. 49 writes the lists, 64B walks
      the hashed fields, and 46's v1 saves them. Those slices are not done
      here. There is no live checksum tag to bump.
      Hashed, on the movement row: `tier`, `level`, `stagger_phase`,
      `stagger_settled`, `always_active`. Hashed with them: the
      stagger-arrival history (`arrivals.next`, `level_origins`,
      `arrivals.live`, `arrival_holds`, `arrival_holder_rows`). World 0
      uses the store fields; any other id uses the same fields on
      `other_worlds`. Map entries are hashed and saved in ascending key
      order. `arrival_holder_rows` stays list order.
      `arrival_holds.holder_slot` stays the index into that list.
      Excluded, rebuilt: `chunk_x` and `chunk_y`; `cell_size`, `cells_x`,
      and `cells_y` (and the same three on `OtherStaggerWorld`); the
      `AiAgentRow` copies of `level`, `chunk_x`, `chunk_y`, `tier`,
      `stagger_phase`, and `always_active`; `CollisionBoundsRow.tier`;
      `DataSystem.tier_counts`. `was_far` is not a column. 62's caller
      keeps that bit.
- [x] The whole of `systems/simulation_scope.zig` and `simulation_scope.zig`
      checked against the cost model and the rules (owner 2026-10-16), not only
      the items above. Each finding is an item below. `simulation_scope.zig`
      had none.
- [x] Think order is a B+ tree per think group. `orderThinkPhases` does not
      column-write a key that did not change. The due-span pack stays the
      think-work copy. The motion record is an `EntityId` resolved at the next order.
- [ ] `deriveChunkJob` finishes the cell math with a scalar tail
      (`systems/simulation_scope.zig:1216`). Failure: full lanes run
      `worldPosToCell4`, then `chunkCoordFor` repeats that math one row at a
      time (`memory-performance.md` § SIMD and core math). Pass: one lane
      kernel, last batch masked, stores `chunk_x` and `chunk_y` from lanes.
      The visual change list stays a scalar compact. Serial and threaded
      chunk columns still match, including a short tail.
- [ ] `scanTierDistance` drains lanes into scalar tier branches and repeats
      the compares in a scalar tail (`systems/simulation_scope.zig:1407`).
      Failure: the chebyshev and the band compares run in lanes, then each
      lane branches, and the remainder calls `lodDistance` /
      `tierForChunkDistance` (`memory-performance.md` § SIMD and core math).
      Pass: distance and tier class stay in lanes through one masked tail of
      that same kernel. The command compact stays scalar. Serial and threaded
      tier commands still match, including a short tail.
- [ ] Chunk derive grows a destination run inside the change loop
      (`systems/simulation_scope.zig:367`). Failure: `reserveDrawableDestination`
      calls `ensureTotalCapacity` once per visual chunk change, and
      `drainPendingChunks` does the same per pending row
      (`memory-performance.md` § Hot paths). Pass: one geometric reserve per
      destination run on the main thread before any per-row link. After that
      reserve, a `FailingAllocator` proves the link allocates nothing. OOM
      still rolls the new reserves and the chunk columns back. Growth is
      counted. Drawable runs stay off workers.
- [ ] Think-pack tuners record the cognition span for work that is not that
      span (`systems/simulation_scope.zig:560`). Failure: `think_pack_tuner`
      samples include optional-column rounds, and the hole and retie tuners
      are begun and finished at the span while they walk a shorter list or
      another store (`threading.md` § Building a stage). Pass:
      `think_pack_tuner` records one sample whose rounds are only that span's
      AI image, scatter, and apply. Perception, memory, and affect each use
      their own tuner at `listed`. Hole classify and optional retie begin,
      run, and finish at the index count that round walks.
- [ ] Think pack writes `pack_stamp` outside the range window
      (`systems/simulation_scope.zig:1857`). Failure: `thinkPackJob` and
      `optionalPackJob` store a moved source's stamp in a scattered `u32`
      column, so neighboring ranges share cache lines
      (`threading.md` § Writes, capacity, and determinism). Pass: each
      range's stamp stores land in a contiguous window that range owns,
      bucketed by destination in range order before the write. The threaded
      pack parity test stays clean under ThreadSanitizer at its small fixture.
- [x] `thinkPlaceJob`'s per-batch column slice is gone with that loop, and the
      place job does not call `.items` inside a batch loop.
- [ ] Tests: an agent in every band advances (thinks, moves, paths) at its
      cadence; the far signal is deterministic; results are identical across render cadence and worker
      count; serial equals threaded.
- [x] Bench `far-sim`: per-step cost at three or more populations and world
      sizes with most agents far from the observer. Debug, `x86_64_v2`.
      Think-set sums over 64 steps equal the agent count at 1024, 4096, and
      10000 (steps 16, 64, and 156–157). Extent items at population 4096
      keep that 4096 sum and the index count. Collision items stay 1.
      Several runs printed `settled=no`; the counters are the proof.
- [x] Docs: `docs/architecture.md` tier model; `docs/simulation-tiers-and-pipeline.md`
      scope, bands, and cadences. The tier sections cite the scope rule.
      Think work follows the due rows. The index and movement follow the agents.

### Acceptance checks

- [ ] No entity stops advancing because of distance from the observer
      (tests over every band).
- [ ] `far-sim` matches the cost model: think rows follow population divided
      by cadence, the index and movement follow the agent count, and neither
      grows with world extent. `production-step`, `ai`, and `steering` show
      no near-observer regression beyond run-to-run spread.
- [ ] `production-step` meets its pass shape on the level-count and
      level-side axes with every row advancing at its tier.
- [ ] Manual (display, Debug): NPCs revisited after travelling far away have
      moved and acted.
- [ ] `zig build verify` passes.
