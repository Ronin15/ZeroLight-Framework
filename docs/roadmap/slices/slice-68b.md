## Slice 68B: Knockback Impulses And Retaliation Memory

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 56](slice-56.md), [Slice 56B](slice-56b.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Hard dependencies:
- **Slice 56**: `combat_resolve`, `Health.last_attacker`, the top-contributor
  rule, `CombatStats`, and `stepAfter` / `stepReached`.
- **Slice 49**: `StepIndex = u64` and `stepKey` (see "Slice 49 + Slice 56 —
  `StepIndex`" below).
- **Slice 56B**: the `projectile` snapshot, which gains `knockback_speed`.
- **Slice 55**: the alert predicate, which gains the retaliation signal.

Independent of 57, 61, and 68A. Slice 42 later moves this slice's arbitration
bonuses to per-entity data along with its other gains.

Goal: hits push targets and victims learn who hit them, both deterministically
and with no new queue at a step boundary.
- **Knockback.** `combat_resolve` writes a per-body knockback velocity column.
  A new `knockback_apply` stage after `movement_integrate` integrates it as
  extra displacement and decays it, before collision and the tile gate settle
  the pose. `combat_resolve` therefore never writes `movement_positions`
  between `chunk_derive` and `tier_policy`.
- **Retaliation.** A victim's `AiMemory` gains one fixed retaliation slot,
  ingested by `ai_memory_update` from `Health` (written by `combat_resolve` the
  step before). It gives pursue and flee a goal even when the attacker was
  never seen, and it wakes a coasting agent the same way fresh memory does.

Out of scope (decisions, not deferrals):
- Stun and loss of control: knockback is additive and never touches
  `velocity_*`.
- Knockback from non-combat sources. No such producer exists in the framework.
  The column and the `movement_knockback` contract are the extension point; a
  producer slice writes the same column under the same contract.
- Retaliation against more than the most recent attacker. **Decided:** when
  several damage steps land between two of a victim's sensing ticks, only the
  last damage step's top contributor is ingested (`Health.last_attacker` holds
  one entity, and the watermark skips intermediate steps). A per-victim
  attacker history would need a ring in `Health` written by `combat_resolve`
  for every hit, for a signal the 1-in-4 sensing cadence already compresses.
  The memory ring still learns earlier attackers that the victim sees.
- Sharing retaliation with allies. That is Slice 71A's `guard_alarm` help-call
  (an `AffectImpulse` producer on Slice 61's substrate), not this slice.

### Current foundation (do not rebuild)

- **Motion:**
  - `MovementSystem.applyIntents` (`systems/movement.zig:59-71`) overwrites
    AI velocity only from this step's movement intents. Velocity otherwise
    persists, and coasting relies on that (Slice 55).
  - Player velocity is set from input every step (`player.zig:61`).
  - `movement_integrate` (`:84-172`) writes
    `previous = position; position += velocity * dt` over the full contiguous
    range, SIMD plus a scalar tail.
- **Tier entry:** `DataSystem.snapInterpolationIfStill`
  (`data_system/system.zig:281`) zeroes velocity and snaps `previous` on entry
  to a non-moving tier (`MovementBodyStore.zeroVelocity`,
  `data_system/movement.zig:158`).
- **Settle order:**
  - `collision_scope_gather → collision_detect → collision_respond → bounds_and_tile_gate → plane_traversal → chunk_derive`
    (`simulation_pipeline.zig:274-279`).
  - The tile gate reverts each axis to the pre-step pose when the post pose
    overlaps a solid tile, and zeroes that axis's velocity
    (`systems/world_gate.zig:56-79`).
  - Tile size is 32 px (`assets/sprites/world_tileset.json:11`).
- **Freshness:** `chunk_derive` derives `chunk_columns` from
  `movement_positions` (`simulation_pipeline.zig:242-250`). That is why Slice
  56 keeps knockback out of `combat_resolve`, which sits after `chunk_derive`
  (Slice 56 Architecture notes, "Knockback is out of scope").
- **Slice 56:**
  - `combat_resolve` phase 2 applies per-target sums and picks the killer, or
    the top contributor for a survivor: the largest applied contribution,
    with ties broken by lowest entity index, then generation. That choice is
    intent-order independent.
  - It writes `Health.last_attacker` and `last_damage_step`.
  - `CombatStats` is a cold MAL. `combat_state` is the `Health` hot columns
    plus `next_attack_step`.
- **Slice 56B:** a `projectile` row snapshots the attacker's damage stats.
  Killer attribution uses `owner`.
- **Memory:**
  - `AiMemorySystem` (`systems/ai_memory.zig`) gathers think rows that carry
    both `AiPerception` and `AiMemory`. Decay is a SIMD gather/scatter
    (`processDecayRange`, `:244`) plus `ageRingForRow` (`:296`).
    `finishMemoryRefresh` (`:316`) runs the event refresh, then
    `refreshVisibleTargets` (`:400`).
  - `upsertRingContact` (`:434`) maintains a 4-slot ring
    (`ai_memory_ring_capacity = 4 = simd.lane_count`, `types.zig:528`).
  - `AiMemoryRow` is defined at `data_system/memory.zig:64-76`, and
    `validateAiMemory` at `:23-31`.
- **Arbitration** (`systems/arbitration.zig`):
  - `Signals` is at `:34`, `memoryFresh` at `:146`, `memoryMatchesFocus` at
    `:158`, `memoryTerm` at `:196`, `resolvePursueGoal` at `:297`, and
    `resolveFleeGoal` at `:328`.
  - With a configured focus target (the demo's player), fresh memory of a
    **different** entity never gives pursue a goal. That is why an NPC hit by
    another NPC currently never fights back.

### Architecture notes

#### 1. Knockback

**Data.**
- `MovementBodyRow` (`data_system/movement.zig`) gains hot columns
  `knockback_vx: f32 = 0` and `knockback_vy: f32 = 0` (px/s).
  - They are part of the existing MAL; the movement kernel never loads them.
  - `MovementBody` and `MovementBodySlice` / `ConstMovementBodySlice` gain the
    fields. `validateMovementBody` requires them to be finite with magnitude
    ≤ `max_knockback_speed`.
  - `snapInterpolationIfStill` also zeroes both columns, so a non-moving row
    always has zero knockback.
  - Destroy and swap-remove are free (same MAL).
- `CombatStats` gains two cold fields with archetype keys:
  - `knockback_speed: f32 = 0`, in `[0, max_knockback_speed]`, key
    `"knockback_speed"`;
  - `knockback_resistance: f32 = 0`, in `[0, 1]`, key
    `"knockback_resistance"`.
- The Slice 56B `projectile` row gains `knockback_speed: f32`, snapshotted
  from the owner at spawn like the damage fields.
- Content:
  - `player_combat.knockback_speed = 240`.
  - `aggressive.combat.knockback_speed = 180`.
  - `archer.combat.knockback_speed = 120`.
  - Every other value defaults to 0, so Slice 56/56B parity tests that author
    no knockback are bit-identical.

**Constants** (`src/game/combat_controller.zig`, comptime-asserted):

| Constant | Value | Reason |
| --- | --- | --- |
| `max_knockback_speed` | 480 px/s | 8 px/step. Plus the fastest mover (player 120 px/s, 2 px/step) that stays under Slice 56B's documented 12 px collider-tunnel limit and far under the 32 px tile, so the per-axis tile gate cannot be skipped. Assert `max_knockback_speed * fixed_delta_seconds <= 8`. |
| `knockback_decay_per_step` | 0.75 | Geometric decay. The untruncated bound on displacement is `v0 / 60 / (1 - 0.75)`: 16 px for 240 px/s and 32 px (one tile) for 480 px/s. The rest snap truncates the series, so a 480 px/s knock rests at `8 · (1 − 0.75^16) / 0.25 ≈ 31.68 px` after 16 integrations, and a 240 px/s knock at `4 · (1 − 0.75^13) / 0.25 ≈ 15.62 px` after 13. |
| `knockback_rest_speed` | 6 px/s | Snap to exactly 0 below this. 480 px/s rests after 16 integrations (0.27 s): `480 · 0.75^15 ≈ 6.4 ≥ 6`, `480 · 0.75^16 ≈ 4.8 < 6`. Compared squared (36) to avoid a sqrt. |

**Producer: `combat_resolve` phase 2.** This extends Slice 56's per-target
loop, which is serial.
- Applies only when the target is not destroyed this step, has a movement
  body, has a tier where `allowsMovement()`, and has no `collision_response`
  with `.static` mobility.
- Takes the step's top contributor (the same entity Slice 56 records as
  killer or `last_attacker`).
  - `speed = contributor_knockback_speed * (1 - target_resistance)`. For a
    projectile hit, the contributor speed is the projectile row's
    `knockback_speed`. A target without `combat_stats` has resistance 0.
  - Skip when `speed == 0`.
- `dir`:
  - Melee: `math.normalizeOrDefaultFinite(target_center - attacker_center, 1e-4, attacker_facing_unit)`.
  - Projectile: `normalizeOrDefaultFinite(projectile_velocity, 1e-4, .{1, 0})`.
- `k = existing + dir * speed`. If `|k|² > max²`, scale `k` by
  `max / sqrt(|k|²)`. IEEE `sqrt` is correctly rounded, so this is
  deterministic.
- Write `knockback_vx` / `knockback_vy`. Count `knockbacks_applied`.
- Inputs are the top contributor (intent-order independent), stable poses, and
  the persisted column. Permuting merged intents therefore gives identical
  columns, which extends Slice 56's permutation acceptance.

**Consumer: new stage `knockback_apply`.** It runs immediately after
`movement_integrate`, before `collision_scope_gather`.
- Processor `src/game/systems/knockback.zig` (`KnockbackSystem`, with an
  owned `AdaptiveWorkTuner`).
- Threaded `parallelForWithOptions` over the full movement range, with
  `range_alignment_items = movement_range_alignment_items`, dual worker
  asserts, and the serial twin `updateSerial` sharing `processRange`.
- Kernel, 4 lanes:
  - `len2 = lengthSquared2Float4(kx, ky)`. Skip the group when all 4 lanes are
    0 (`countTrue(equalFloat4(len2, 0)) == lane_count`), so idle rows cost
    one 8-byte read.
  - Otherwise:
    - `pos += k * dt`, as a separate multiply then add, matching the scalar
      tail bit for bit.
    - `k *= decay`.
    - `k = select(len2(k) < rest², 0, k)`.
    - Store pos and k.
- The scalar tail performs the same operations.
- Placement reasons:
  - After `movement_integrate`, `previous_*` still holds the pre-step pose, so
    render interpolation shows a smooth push.
  - Collision and the tile gate then settle the knocked pose: contacts push
    bodies apart, and a knock into dirt is reverted per axis by the gate.
  - It runs before `chunk_derive`, so freshness holds.

**Gate and bounds interplay (changed: `systems/world_gate.zig`).** The live
gate reverts an axis to the pre-step pose and zeroes that axis's
`velocity_*` (`world_gate.zig:72-79`, player twin `:94-97`), but it does not
know about knockback. Left alone, a body knocked into a wall would have that
axis reverted on every step for up to 16 steps. Its own velocity on that axis
would be reverted together with the knock (so it could not walk away), and
each revert would also zero the AI velocity that Slice 55 coasting relies on.
So, in this slice:
- `gateBodyColumnsToWalkableTiles` (NPC columns) and `gateBodyToWalkableTiles`
  (player) also set `knockback_vx = 0` when the x axis was reverted and
  `knockback_vy = 0` when the y axis was reverted. `MovementBodyPtr` gains the
  two knockback pointers.
- `clampAiEntitiesToBounds` (`:114-134`) and `Player.clampToBounds`
  (`player.zig:74-88`) zero the knockback component on a clamped axis, so the
  world edge behaves like a wall.
- The gate returns early on level 0 (`world_gate.zig:63`, surface is fully
  walkable). On level 0 only the bounds clamp applies.
- Contract: `bounds_and_tile_gate` gains `writes += {movement_knockback}`
  (`simulation_pipeline.zig:212`). `knockback_apply` (stage 13) runs before
  it in the same step and the next step's `knockback_apply` reads the zeroed
  value, so no carried rule is involved.
- No events. Stats are `{ active_rows, batch }`, plus a `StageTimer`
  `pipeline_knockback` timing in `runtime_perf_log.zig`.

**Stage graph.**
- New `PipelineResource.movement_knockback`. New
  `StageId.knockback_apply` in `stage_order` between `movement_integrate` and
  `collision_scope_gather`.

| Stage | reads | writes | carried |
| --- | --- | --- | --- |
| `knockback_apply` (new) | `movement_positions` | `movement_positions`, `movement_knockback` | — |
| `bounds_and_tile_gate` (changed) | unchanged | `+ movement_knockback` | — |
| `combat_resolve` (changed) | unchanged | `+ movement_knockback` | — |

- `knockback_apply` reads the column `combat_resolve` wrote on the previous
  step as owned read-modify-write. The contract declares that as a write,
  following the `ai_memory_update` precedent, because `carried` must be
  disjoint from `writes`.
- `combat_resolve` writes `movement_knockback`, never `movement_positions`, so
  the comptime freshness check (`simulation_pipeline.zig:348-366`) still
  passes.
- Raise `@setEvalBranchQuota` (`:287`) if the walk needs it.

**Determinism.**
- Per-row independent, so serial and threaded are identical.
- The knockback is "next-step" by construction: written at step `s` and
  integrated from step `s+1`. The column is persistent `DataSystem` state.
  It is hashed by Slice 49, because it is a `MovementBodyStore` MAL column,
  and saved by Slice 46.
- Nothing is pending outside `DataSystem` at a step boundary. This is distinct
  from Slice 61's `AffectImpulse` queue, which this slice does not touch.

#### 2. Retaliation memory

**Producer data.**
- `Health` (Slice 56) gains hot `last_attacker_x: f32` and
  `last_attacker_y: f32`, written with `last_attacker` in phase 2.
- The value is the top contributor's AABB center on current poses. For a
  projectile hit it is the owner's center when the owner is alive, otherwise
  the projectile's center (memory ignores dead attackers).
- It belongs to `combat_state`, with no new tag.

**Memory slot.** One fixed retaliation slot per `AiMemory` row, separate from
the 4-slot sighting ring so that sightings can never evict it.
- New fields on `AiMemory` / `AiMemoryRow` / both slices:
  - `retaliation_target: EntityId = invalid`
  - `retaliation_x: f32 = 0`, `retaliation_y: f32 = 0`
  - `retaliation_age: f32 = ai_memory_retaliation_ticks`
  - `retaliation_damage_step: StepIndex = 0`, the watermark of the last
    ingested `Health.last_damage_step`
- `validateAiMemory` requires a finite age in `[0, max_ai_memory_staleness]`.
- Memory entry kinds after this slice:
  - `last_known` (the perception target)
  - `ring` (4 sighted contacts)
  - `retaliation` (1 attacker slot, most recent wins)
- Constant `ai_memory_retaliation_ticks: f32 = 150` sensing ticks
  (`data_system/types.zig`, beside `max_ai_memory_staleness`).
  - That is 10 s at the 1-in-4 stagger and 2.5 s for pinned agents. It uses
    the same cadence semantics as `staleness`, which is documented and
    unchanged.
  - Comptime-assert it `< max_ai_memory_staleness`.

**Ingest.** A new serial pass `refreshRetaliation` in `finishMemoryRefresh`,
after `refreshVisibleTargets`, over the gathered memory rows:
1. `hi = data.healthDenseIndex(entity) orelse continue`.
2. If `last_damage_step[hi] == retaliation_damage_step`, continue (already
   ingested).
3. Set `retaliation_damage_step = last_damage_step[hi]`. The watermark
   advances even when the attacker is dead or invalid, so a dead attacker is
   checked once.
4. If `last_attacker` is valid, alive, and not self:
   - `retaliation_target = last_attacker`, `retaliation_x/y = last_attacker_x/y`,
     and `retaliation_age = 0`;
   - `upsertRingContact(target, x, y)`, so investigate-only agents also learn
     the contact.

There is no stance re-check. The attacker passed combat's non-friendly check
at hit time, at most one sensing tick earlier.

- Every damage step's recorded attacker is ingested at most once whatever the
  stagger cadence, the same watermark idiom as Slice 56's
  `appraised_damage_total`. Multiple damage steps between two sensing ticks
  ingest only the last one's attacker (a decision; see Out of scope).
- The cost is O(gathered rows) health lookups on the main thread, beside the
  existing serial refresh passes. That is bounded by the think set, not the
  halo.

**Aging.**
- `processDecayRange` adds `retaliation_age` to its 4-lane gather/scatter:
  `+1`, clamped to `max_ai_memory_staleness`.
- The scalar per-row expiry (in `ageRingForRow`) sets
  `retaliation_target = invalid` when
  `age >= ai_memory_retaliation_ticks`.

**Arbitration** (`systems/arbitration.zig`).
- `Signals` gains `retaliation_target: EntityId = invalid`,
  `retaliation_x: f32 = 0`, and `retaliation_y: f32 = 0`.
  `retaliationFresh(signals) = retaliation_target.isValid()`, because expiry
  already invalidated stale slots.
- A new `retaliationTerm(behavior, signals)` is added inside the gain product
  in `scoreBehaviors`:
  - pursue: `pursue_retaliation_bonus = 0.6`;
  - flee: `flee_retaliation_bonus = 0.6`;
  - both only when `retaliationFresh and !target_visible`;
  - 0 for every other behavior.
  - 0.6 sits between the fresh-memory bonus (0.5) and the visible bonus (1.0).
  - Being gain-multiplied, it is zero-gain safe.
- `resolvePursueGoal` order: visible threat → **retaliation** (no
  `memoryMatchesFocus` gate, because the attacker is the direct cause) →
  focus-matched fresh memory → focus fallback.
- `resolveFleeGoal` order: visible → **retaliation** → fresh memory.
- Parity: with no retaliation slot set, scores and goals are bit-identical,
  and the existing arbitration tests pass unchanged.
- `AiGatherRow.memory` gains the three fields, gathered in `gatherAiData`
  from the memory row.

**Coasting (Slice 55 producer contract).**
- `aiDecideGatherJob`'s threat signal becomes
  `(target_visible or memoryFresh or retaliationFresh) and (gain_pursue > 0 or gain_flee > 0)`.
  `DecisionCoastInputs` is unchanged, since this only adds a term to
  `threat_signal`.
- Damage alone still wakes a row through the affect watermark (`idle_near`).
  Retaliation now promotes it to `alert`, so it decides in the same step its
  memory ingests the attacker.

**Stage graph.**
- `ai_memory_update` gains `carried = {combat_state}`. `Health` is read from
  the previous step; the later `combat_resolve` writes it, satisfying the
  carried rule, the same as Slice 56's `affect_update`.
- `ai_decide_gather` and `ai_decide` already read `ai_memory`.

#### Persistence and checksum (both features, same change)

- New `MovementBodyStore` columns, `CombatStats` fields, the projectile
  snapshot field, `Health` fields, and `AiMemory` fields are all in hashed
  MALs (Slice 49 completeness walk).
- Bump `checksum_format_tag` (live value + 1). Slice 46 sections gain the
  fields, and the save `format_version` is bumped (live value + 1; v16 in the
  merged order, Table T3).
- **Slice 64B classification** (same change, B3 table): `KnockbackSystem`
  (its `AdaptiveWorkTuner` and per-step stats) is `excluded` (scratch and
  tuner). The knockback columns, `Health.last_attacker_x/y`, and the
  `AiMemory` retaliation fields are hashed through their MALs.

### Checklist

- [ ] `MovementBody` knockback columns: store, slices, validator, tier-entry
      zeroing, round-trip and FailingAllocator store tests.
- [ ] `CombatStats.knockback_speed` / `knockback_resistance` with archetype
      keys and validation. Projectile `knockback_speed` snapshot. Demo and
      player content values.
- [ ] `combat_resolve` knockback write: top contributor, direction rules,
      clamp, skip rules, and the `knockbacks_applied` counter.
- [ ] `KnockbackSystem` (`systems/knockback.zig`): threaded plus serial twin,
      zero-group skip, dual asserts, scalar-tail parity. Pipeline
      `PipelineResource.movement_knockback`, `StageId.knockback_apply`,
      `stageContract` arms, `runStage` arm, `stageKnockbackApply` with
      `pipeline_knockback`, and `StepState.knockback`. Update the contract
      tests.
- [ ] `world_gate.zig`: both tile-gate functions zero the knockback component
      of a reverted axis; `clampAiEntitiesToBounds` and
      `Player.clampToBounds` zero it on a clamped axis; `MovementBodyPtr`
      gains `knockback_vx` / `knockback_vy`. Contract
      `bounds_and_tile_gate.writes += {movement_knockback}` and its contract
      test.
- [ ] `Health.last_attacker_x/y` written in phase 2.
- [ ] `AiMemory` retaliation slot: types, store, slices, validator, decay and
      expiry, `refreshRetaliation`, and `ai_memory_update`
      `carried += combat_state`.
- [ ] Arbitration: `Signals` fields, `retaliationTerm`, both goal-order
      changes, the gather fields in `ai.zig`, and the Slice 55 alert-predicate
      term in `aiDecideGatherJob`.
- [ ] Persistence: completeness lists, `checksum_format_tag` bump, Slice 46
      fields, and the save `format_version` bump (both relative). Slice 64B B3
      row: `KnockbackSystem` `excluded`.
- [ ] Tests, knockback:
      - **SIMD == scalar** over counts `{0, 3, 4, 9}` (the movement-test
        pattern).
      - **Serial == threaded** over 0/1/2 workers.
      - **Rest:** a 480 px/s impulse on an unobstructed body rests at exactly
        0 after 16 integrations, and total displacement equals the truncated
        geometric sum `8 · (1 − 0.75^16) / 0.25 ≈ 31.679 px` within 0.01 px
        (f32 probe: 31.679276). 32 px is only the untruncated bound and is
        not asserted.
      - **Additive:** an AI velocity set by an intent is unchanged by
        knockback.
      - **Pipeline wall test** (fixture on level 1, because the gate is a
        pass-through on level 0, `world_gate.zig:63`): a body one pixel from a
        solid tile on +x is knocked at 480 px/s along +x while its own AI
        velocity is 0. On the first step the gate reverts x, the body never
        ends inside the tile, and `knockback_vx == 0` afterwards while
        `knockback_vy` is untouched. On the next step an intent of −x moves
        the body away by its full `speed · dt`.
      - **Bounds test:** a body knocked into the world edge on level 0 is
        clamped and its knockback on that axis is 0 after the step.
      - **Pipeline contact test:** two dynamic bodies, one knocked into the
        other, separate through collision response.
      - **Tier test:** a dormant transition zeroes knockback.
      - **Permutation:** permuted intents give identical knockback columns.
      - **Parity:** a 0-knockback attacker leaves columns at 0 and
        positions bit-identical to the no-knockback build.
      - **Composite determinism:** a 60-step `pipeline.update` fixture with
        melee and archers gives identical position and knockback checksums for
        0 workers and N workers.
- [ ] Tests, retaliation:
      - An ally hit from outside its FOV by a hostile with `focus_entity` set
        to the player and `gain_pursue > 0` pursues the attacker's hit
        position on its next think. Today it pursues the player.
      - A timid row (`gain_flee > 0`) flees away from `retaliation_x/y`.
      - Each damage step is ingested exactly once across stagger phases.
      - Two damage steps (attackers A then B) between one victim's sensing
        ticks ingest B only (the decided last-attacker rule).
      - Expiry after `ai_memory_retaliation_ticks` ticks.
      - A dead attacker is ignored and the watermark still advances.
      - Four new sightings do not evict the retaliation slot.
      - Arbitration parity with an empty slot.
      - A zero-gain row is unaffected.
      - **Slice 55:** a coasting `idle_far` row hit by an unseen attacker
        becomes `alert` and decides on its next sense tick.
- [ ] FailingAllocator proofs:
      - `KnockbackSystem.update` after warm-up on real 2 workers, and serial.
      - `AiMemorySystem.update` with the retaliation pass after `reserve`.
      - The composite `pipeline.update` proof (Slice 56's proof 4) extended
        with one knockback and one retaliation ingest.
- [ ] Bench: add `zig build bench -- --group knockback`
      (`src/benchmarks/knockback.zig`, registered after `movement`; same item
      counts as `movement`). It has two cases families:
      - `idle`: all knockback zero;
      - `active`: 10% of rows nonzero, re-seeded every 16 steps.
- [ ] Re-baseline the control table by Slice 68A §3 (`knockback stage` row).
- [ ] Docs:
      - `docs/simulation-tiers-and-pipeline.md`: the stage, the
        `movement_knockback` contract, and next-step semantics.
      - `docs/architecture.md`: knockback ownership and the memory entry
        kinds.
      - Archetype schema comment.

### Acceptance checks

- [ ] `combat_resolve` never writes `movement_positions`. The comptime
      freshness check passes with `knockback_apply` in `stage_order`
      (`zig build check`).
- [ ] Knockback determinism: SIMD == scalar, serial == threaded, permutation
      invariance, and the composite 0-vs-N worker checksums all pass.
- [ ] Knockback collision interplay: the wall (level 1), bounds, and contact
      pipeline tests pass. No knocked body ends a step inside a solid tile,
      and a reverted or clamped axis carries zero knockback into the next
      step.
- [ ] Retaliation behavior tests pass. Arbitration parity holds with an empty
      slot. The Slice 55 wake test passes.
- [ ] FailingAllocator proofs pass.
- [ ] Bench, ReleaseFast: `zig build -Doptimize=ReleaseFast bench -- --group knockback --case serial-direct`:
      - **Hard gate:** at every item count, `idle` mean ≤ 0.35× the same-run
        `movement` group mean. The kernel reads 8 B per row versus
        movement's 16 B read plus 16 B write.
      - The `movement` group is unchanged within noise versus a pre-change
        capture, because its code is untouched.
      - Record the `active` actuals.
- [ ] Battle soak per 68A §3: the `knockback stage` row is recorded, and
      collision and steering bands do not move beyond their recorded band.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Knockback.** VoidLight has none in combat (Slice 56's "do not port" list
  names it as deferred). Nothing is ported. The design follows the
  ZeroLight stage contract instead of a VoidLight velocity write.
- **Retaliation.**
  - VoidLight `AttackBehavior.cpp:486-490` (critical health → flee) and its
    recent-attack urgent check (`WanderBehavior.cpp:293-334`, a per-frame
    pre-throttle check).
  - Ported: "being attacked bypasses idle throttling and yields a reaction",
    as a memory slot read through columns.
  - Not ported: message-bus PANIC/RAISE_ALERT dispatch or per-frame urgent
    queries.

