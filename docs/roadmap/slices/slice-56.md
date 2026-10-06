## Slice 56: Health, Damage, And Combat Domain Controller

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 40](../archive/slice-40.md), [Slice 45](../archive/slice-45.md), [Slice 33](slice-33.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Depends on archive 31/32/40/45 (affect, arbitration,
action-intent bus, destructible controller pattern) and Slice 33 (landed; visual
residual) for archetype authoring, and **Slice 49** (`SimulationSeed` /
`SeedDomain`). Unblocks 56B, 57, 61 (claims, `ai_action_select`), 63's combat
rows, and the damage appraisal signal Slice 42's optional `pain` drive reads.

Goal: entities can be damaged and die. NPCs and the player attack through the
existing `action_intents` bus. This slice owns the **single AI action-emission
stage** (`ai_action_select`) and the **`ActionClaimSet`** that every later
action consumer shares. Damage and crit rolls are deterministic functions of
`seed.derive(.combat)`, stable entity IDs, and the step, computed through
`src/core/rng.zig`. Deaths commit as deferred `destroy_entity`. Damage feeds the
existing fear/aggression appraisal, and scalar domain events drive audio and
particles. Serial == threaded, allocation-free after reserve, and every per-step
budget is a fixed constant.

In scope: melee (explicit-target AI attacks plus the player's faced-arc swing),
simultaneous same-step resolution, death, affect hookup, events with
audio/particle reactions, archetype authoring. Out of scope: projectiles (56B),
equipment modifiers (57 adds them as an optional input), knockback and
retaliation memory (Slice 68B), loot (57), stamina, status effects, regen,
game-over flow.

### Current foundation (do not rebuild)

- Action bus: `ActionKind` / `ActionIntent` / `action_intent_live_capacity = 64`
  (`src/game/simulation.zig:478-501`); `ensureActionIntentAppendCapacity`,
  `actionIntentLiveCount`, `appendActionIntent`, `tryAppendActionIntent`
  (`:743-792`). `.attack` already exists. Player `.interact` capture with a
  rising-edge latch is `SimulationPipeline.captureActionIntent`
  (`src/game/simulation_pipeline.zig:896-926`).
- First consumer: `DestructibleController.process`
  (`src/game/destructible_controller.zig:75-170`). It uses a fixed
  `[action_intent_live_capacity]` pending scratch, preflights then queues
  structural/event writes, emits `destructible_destroyed` while the target is
  alive, and soft-drops a particle burst. `stageActionReact` is at
  `simulation_pipeline.zig:1283-1291`.
- Stage graph: `PipelineResource` (`simulation_pipeline.zig:86-120`), `StageId`
  (`:128-148`), `external_resources` (`:161`), `stageContract` (`:167-232`;
  `action_react` carries `action_intents` at `:225-229`), `stage_order`
  (`:262-282`), the comptime reads/carried/freshness checks (`:284-367`),
  `StepState` (`:937-1003`). `reserve` sums `maxEventsPerStep` over the
  exhaustive `EventProducerId` (`:721-737`, `simulation.zig:48-70`).
- Events: payload union and stats `record` / `addProduced` / `recordTo`
  (`simulation.zig:145-239`). Perf metric enum: `src/app/runtime_perf_log.zig:123,155,176`.
- Component pattern: `Component = enum(u5)` with 14 tags
  (`data_system/types.zig:61-76`), `EntityTemplate` (`:740-755`),
  `StructuralCommand` (`:790-808`), `EntitySlot` index fields
  (`data_system/system.zig:1068-1097`), set/get/slice accessors (`system.zig:900-927`),
  MAL store (`data_system/destructible.zig`), capacity needs and
  preflight/commit (`data_system/structural.zig:62-99,146,587,634,706,779`).
- RNG: stateless `mix64` / `uniformF32` / `boundedU32` (`src/core/rng.zig:21-56`).
  AI keys `(seed, entity, step, salt)` today with a literal
  `intent_seed = 0xfeedf00d` (`simulation_pipeline.zig:1168`), which Slice 49
  replaces.
- Affect: `AiAffect` (`data_system/types.zig:634-652`), module gain constants
  (`systems/affect.zig:93-97`), packed `AffectGatherRow` with "no signal"
  defaults for optional inputs (`:126-137`).
- Spatial index timing: the index is built at stage 3 (`spatial_index_build`)
  from the halo's step-start positions (`simulation_pipeline.zig:1066-1070`).
  `SpatialIndexView` holds that `pos_x/pos_y` snapshot, and its radius prefilter
  is a strict `<` on those positions (`spatial_index.zig:257-307`).
- Absolute steps: `step_count: u32` with a plain `+= 1`
  (`systems/simulation_scope.zig:99,168,181`). It traps in Debug and is UB in
  ReleaseFast on overflow (about 2.27 years of play at 60 Hz).
- Input classification: `isGameplayAction` (`src/app/input.zig:186-191`)
  accepts exactly 8 actions today.
- Demo collision capacity: `estimateContactCapacity(mover_count +
  obstacle_count + 1)` and `estimateTriggerCapacity` feed `reserveStreams` and
  `.contact_capacity` / `.movement_body_capacity`
  (`game_demo_state.zig:127-135,431,442-443`).
- `faction.stance` (`src/game/faction.zig:26-28`). Perception `nearest_threat`
  (`types.zig:467`) is faction-generic and already folds in the player. The
  spatial index `SpatialIndexView.queryNeighbors` takes `max_candidate_checks`
  (`systems/spatial_index.zig:257-307`).
- Archetype authoring: strict JSON is parsed into an enum-indexed bundle table
  (`src/game/ai_archetypes.zig:50-244`, `assets/ai/archetypes.json`).
- `AudioController` (`src/game/audio_controller.zig`). `collision_sfx` is the
  only SFX asset (`src/assets/manifest.zig:14-18`). `ParticleSystem.emitBurst`
  (`systems/particle.zig:341`).
- Demo capacity derivation: `structural_reserve` / `event_reserve`
  (`src/game/game_demo_state.zig:139,159`).

### Architecture notes

**New components: two `Component` tags, appended after the last tag present at
landing.** Never reorder; tag numbers are landing-order artifacts and are not
pinned here.

- `health` (`Health`, in `data_system/types.zig`):
  - Cold fields: `max_hit_points: u32 = 100` (validated
    `1..=max_health_hit_points`) and `destroy_on_death: bool = true`.
  - Hot fields, written only by stages that declare a `combat_state` write
    (`combat_resolve`, and Slice 57's heal in `inventory_update`):
    `hit_points: u32` (`<= max`),
    `damage_taken_total: u32` (wrapping cumulative applied damage, the source
    for the appraisal watermark), `last_damage_step: StepIndex`,
    `last_attacker: EntityId`.
  - Health is an integer so save/load (46) and golden checks stay exact.
- `combat_stats` (`CombatStats`):
  - Cold fields:

    | Field | Type | Range |
    | --- | --- | --- |
    | `base_damage` | f32 | `(0, 10_000]` |
    | `damage_variance` | f32 | `[0, 0.5]` |
    | `crit_chance` | f32 | `[0, 1]` |
    | `crit_multiplier` | f32 | `[1, 4]` |
    | `armor_mitigation` | f32 | `[0, 0.9]` |
    | `attack_range` | f32, px | `(0, max_combat_attack_range = 256]` |
    | `melee_cos_half_arc` | f32 | `[-1, 1]` |
    | `attack_cooldown_steps` | u16 | `1..=600` |

    `melee_cos_half_arc` is derived at load from authored degrees, the same way
    `cos_half_fov` is.
  - Hot field: `next_attack_step: StepIndex`. It holds an absolute step, so there is
    no per-step countdown and it freezes cleanly under LOD.
- **Absolute-step arithmetic (owned here; 56B, 57, 61, 62 reuse it).** This is
  the first slice that stores absolute steps, so it lands two helpers in
  `src/game/systems/simulation_scope.zig` next to `currentStep()`:
  - `stepAfter(now: StepIndex, delta: u32) StepIndex` = `now +| delta`. A due
    step saturates at `maxInt(StepIndex)` instead of trapping (Debug) or
    wrapping into the past (ReleaseFast UB).
  - `stepReached(now: StepIndex, due: StepIndex) bool` = `now >= due`.
  - `StepIndex = u64` is Slice 49's type (Slices 68A–68C addition; F5).

  Every absolute-step write (`next_attack_step`, 56B `expire_step`, 57
  `despawn_step`) goes through `stepAfter`, and every comparison through
  `stepReached`. A step-derived rotating cursor (`(step * budget) % len`, used
  by 61 and 62) is computed directly in `StepIndex` (Slice 49). Test both
  helpers at the boundaries listed in the Checklist.
- Storage: `src/game/data_system/combat.zig` holds `HealthStore` and
  `CombatStatsStore`, each a `std.MultiArrayList(Row)` (the default, no
  exception). They also hold `validateHealth` / `validateCombatStats`, which
  return `error.InvalidHealth` / `error.InvalidCombatStats`.
  - Mutable slices expose hot columns only; cold columns stay const, as in
    `PerceptionSlice`.
  - Full track-contract wiring: `component_masks`, `EntitySlot.health_index` /
    `combat_stats_index`, `EntityTemplate.health` / `.combat_stats`,
    `StructuralCapacityNeeds` fields with `validateLimits`, preflight/commit
    arms, destroy cleanup, and `DataSystem` set/const/denseIndex/slice
    accessors.
  - No new `StructuralCommand` set variants. Spawns use templates or init-time
    setters, and runtime health changes are hot-column writes, so there is no
    deferred producer for a set command.
- Determinism and save classification (Slice 49 completeness lists, Slice 46
  save sections, same change): `HealthStore` and `CombatStatsStore` are hashed
  MALs with their own save sections. `AiAffect.appraised_damage_total` is
  covered by the existing `ai_affects` MAL. The player `attack_held_last` latch
  is controller state, excluded under Slice 49's rule (listed in its
  "Controller state in the checksum" gap).

**Authoring.**

- `DemoArchetype` (`ai_archetypes.zig:70-76`) gains `health: ?Health = null`
  and `combat: ?CombatStats = null`.
- `archetypes.json` gains two optional strict blocks:
  - `"health": { "max_hit_points": u32, "destroy_on_death": bool }`
  - `"combat": { "base_damage", "damage_variance", "crit_chance",
    "crit_multiplier", "armor_mitigation", "attack_range",
    "melee_arc_degrees" (0,360], "attack_cooldown_steps" }`
- Absent numeric keys fall back to the struct defaults. Unknown keys fail
  (`UnknownField`). `BuildError` gains `InvalidHealth` and
  `InvalidCombatStats`.
- Demo content: `aggressive` gets `health` and `combat`. `timid` gets `health`
  only, so it can be hurt, feel fear, and flee. The other archetypes are
  unchanged and cannot be attacked, because combat requires a `health` target.
- Player: `player.zig` defines constants `player_health`
  (`max_hit_points = 100`, `destroy_on_death = false`) and `player_combat`
  (`base_damage = 12`, `crit_chance = 0.1`, `crit_multiplier = 2`,
  `attack_range = 36`, 120 degree arc, `attack_cooldown_steps = 20`).
  `Player.spawn` (`src/game/player.zig:31`) attaches both.

**Stage graph: two new `StageId`s and three new `PipelineResource` tags.**

New tags:

- `combat_state`: the `Health` hot columns plus `CombatStats.next_attack_step`.
- `combat_events`: `entity_damaged` and `entity_killed`.
- `action_claims`: a per-step bitset of merged action-intent indices that a
  consumer already resolved.

Tail of `stage_order`:
`… plane_traversal → chunk_derive → ai_action_select → action_react → combat_resolve → tier_policy`

| Stage | reads | writes | carried |
| --- | --- | --- | --- |
| `ai_action_select` (new) | `ai_cognition_indices`, `perception_sensed`, `ai_behavior`, `movement_positions`, `world_level` | `action_intents` | `combat_state` (written by the previous step's `combat_resolve`) |
| `action_react` (changed) | `movement_positions`, `world_level`, **`action_intents`** (was carried) | `structural_commands`, `world_events`, **`action_claims`** | — |
| `combat_resolve` (new) | `action_intents`, `action_claims`, `movement_positions`, `world_level`, `spatial_index` | `combat_state`, `combat_events`, `structural_commands` | — |
| `affect_update` (changed) | unchanged | unchanged | `ai_behavior`, **`combat_state`** |

- `action_intents` stays in `external_resources`, because input capture still
  appends before `update`. It becomes a read for `action_react` because an
  earlier stage now writes it; the existing comptime error "carries a resource
  an earlier stage writes" forces that change. Rewrite the assertions at
  `simulation_pipeline.zig:1350-1353`.
- Neither new stage writes `movement_positions`, so the
  `chunk_derive → tier_policy` freshness derivation (`:242-249`) stays valid.
- Placing both stages after `chunk_derive` means range checks read final
  settled poses.
- Adding two stages and three resources lengthens the comptime contract walk:
  raise `@setEvalBranchQuota` at `simulation_pipeline.zig:287` (4000 today) if
  the walk needs it.

**`AiActionSelectSystem` (`src/game/systems/ai_action_select.zig`, processor).**
This is the **only** AI action emitter. It turns qualifying cognition agents
into explicit-target action intents. This slice lands the `.attack` arm.

- **One emitter, per-kind arms.** Qualification is a per-kind arm in one
  exhaustive switch over emitting behaviors. This slice lands the `.attack` arm
  (`active_behavior == .pursue`, below). Later slices add arms (61: `.harvest`;
  the AI trade arm for 63 is Slice 71D's `.sell` arm). They never add a second AI emitter or a write
  of `action_intents` from `ai_decide`.
- Population: the think set `ai_cognition_indices`, which is stagger-gated
  (null means all agents). Attack latency is therefore at most
  `cognition_stagger_n - 1` steps; document this.
- A row qualifies for the `.attack` arm only when all of these hold (pure
  reads):
  - `active_behavior == .pursue`.
  - The row has `combat_stats` and `stepReached(step, next_attack_step)`.
  - It has `AiPerception` with a valid `nearest_threat`. An agent without
    perception never attacks, by design.
  - The target is alive, has `health` with `hit_points > 0`, and shares the
    attacker's `world_level` (missing level counts as 0).
  - `faction.stance` is not `.friendly` (missing faction counts as `.neutral`).
  - Reach: squared distance from the attacker's collision-AABB center to the
    closest point of the target's collision AABB is `<= attack_range²`.
    Missing bounds means the body position with zero extent.
- Deterministic emit follows the capped partitioned-emitter rule
  (`docs/coding-standards.md:136-148`):
  1. Pass 1 runs threaded ranges over the think set (adaptive tuner with a
     serial fallback). It writes a per-row `target` into a system-owned row
     scratch and records per-range counts.
  2. The main thread computes prefix offsets.
  3. Pass 2 writes `ActionCandidate {actor, kind, target, level}` rows into a
     system-owned `RangeOutputStream(ActionCandidate)` in range order.

  The merged order equals think-set order for any range count.
- Budget selection (main thread), shared across every AI action kind:
  - `budget = min(ai_action_budget_per_step, action_intent_live_capacity - frame.actionIntentLiveCount())`.
  - If `n <= budget`, emit all candidates.
  - Otherwise emit `budget` candidates starting at
    `rng.boundedU32(combat_seed, 0, step, ai_action_rotation_salt, n)` and
    wrapping around. This is deterministic and unbiased across steps. The
    rotation draws from the `.combat` domain seed, the domain this slice lands;
    later arms reuse it rather than adding a domain.
  - (Rotation start; deferral-age priority from Slice 68A.)
  - Unselected candidates count toward `ai_actions_deferred`. Their cooldown is
    untouched, so they retry on their next think. This is graceful degradation,
    not a bigger number.
- Append: one range via `ensureActionIntentAppendCapacity(k)` →
  `appendRangeCounts(1)` / `addCount` / `prefixAppendedRanges` / writer /
  `finishWrite`. This is the same multi-producer append destructible uses.
  Each intent is `{ entity = actor, kind, target, level }` (`kind = .attack`
  for this slice's arm).
- The row loop stays scalar. Each row costs 4–6 dense-index lookups and is
  gather-bound; there is no float kernel worth packing. Revisit only if the
  `ai-action-select` bench shows math-bound rows.
- Reserve (pipeline init/`reserve`, before dispatch): size the row scratch and
  the candidate stream as `(rangeCount(pop, alignment), pop)` from the same
  profile value the dispatch uses. Each job asserts its write range and
  `range.index`.

**`CombatController` (`src/game/combat_controller.zig`, pipeline-owned, serial).**
Intent and hit work is bounded by the fixed `combat_max_hits_per_step`,
regardless of world size or population. The only population-length work is
phase 0's single dense, branch-light pass over the `hit_points` column.

- **Per-step combat caps (owned here; every sizing derives from them).**
  - `combat_max_hits_per_step = action_intent_live_capacity` (64): at most one
    hit per intent. Slice 56B redefines it as
    `action_intent_live_capacity + projectile_hits_per_step`.
  - `combat_max_kills_per_step = combat_max_hits_per_step`: at most one kill
    per hit.
  - `PendingHit` / `PendingTarget` arrays, the `.combat_resolve` event budget,
    and the structural headroom are all sized from these two constants, never
    from `action_intent_live_capacity` directly. Comptime asserts tie each
    array length to its constant and check that `combat_max_hits_per_step`
    equals the sum of every hit-source cap (one term per source; 56B adds
    `projectile_hits_per_step`). A slice that adds a hit source adds its term
    there, so an undersized array is a compile error, never an out-of-bounds
    write (ReleaseFast UB). Slice 57 sizes loot creates from
    `combat_max_kills_per_step`.
- **Phase 0, downed revive (single `combat_state` writer).** Before resolving
  intents, scan `HealthStore` rows with `destroy_on_death == false`,
  `hit_points == 0`, and `last_damage_step < step`, and restore
  `hit_points = max_hit_points` (counter `combat_revives`). The scan is bounded
  by the health store length and touches only hot columns (rows with
  `hit_points > 0` exit on the first compare). No revive runs
  outside the stage graph (nothing in `GameDemoState.update`'s
  `main_thread_inputs`), so `combat_resolve` stays the only writer of these
  columns besides 57's heal, and revive is pipeline-testable. `destroy_on_death == false` therefore means "downed for
  one step, then revived". A game-over flow is a later state-level slice that
  adds a policy enum here.
- Consumes merged `.attack` intents whose bit is not set in `action_claims`.
  `.interact`, `.use`, and `.signal` are ignored.
- Conflict policy is one consumer per intent:
  - `action_react` runs first. `DestructibleController.process` gains a
    `claims: *ActionClaimSet` parameter and sets the bit for every intent it
    applied damage for, so a faced crate wins over an arc enemy for the same
    swing.
  - **Fixed claim order.** Later `action_react` controllers run **before**
    destructible, in this order: trade (63) → harvest (61) → destructible (45).
    `combat_resolve` (a separate, later stage) consumes only unclaimed
    `.attack` intents. The shared `.action_react` event budget (64) stays
    sufficient because each intent is claimed at most once (61 and 63 each
    assert this in a test).
  - An entity that carries both `destructible` and `health` is resolved by the
    destructible path. Document this precedence; authoring should pick one
    component.
  - `ActionClaimSet = std.StaticBitSet(action_intent_live_capacity)` lives in
    `simulation.zig` and is held in `StepState`. It is the only claim set:
    Slices 61 and 63 reuse it and never define their own.
- Target resolve:
  - Explicit target: validate alive, `hit_points > 0`, same level, not
    friendly, and reach rechecked against current poses.
  - Target-less (player swing): call `spatial_index.view().queryNeighbors`
    around the attacker's current center with radius
    `attack_range + combat_arc_query_slack` and
    `combat_arc_candidate_checks = 32`. The index holds step-start positions
    (built at stage 3, before movement and collision), so the fixed
    `combat_arc_query_slack = 16 px` admits candidates whose relative
    displacement this step is at most 16 px (960 px/s). A candidate index maps
    through `spatial.entities[r]` (Slice 68A shared halo table). If 56 lands
    before 68A, keep the current mapping (`ai_halo_indices` →
    `AiAgent.entities`, the same mapping perception uses) and assert the halo
    row has a movement body; 68A replaces it. Accept a candidate only if, **on current poses**,
    it passes the health/level/stance/reach checks and
    `dot(dir, facing) >= melee_cos_half_arc·|dir|` (`Facing` mapped to a unit
    vector). Pick the nearest; break ties by lowest entity index, then
    generation.
  - Documented limit: a target that closes more than the slack in one step is
    a candidate on the next step (one-step lag), never a missed hit forever.
    The slack is a fixed constant, never derived from speeds in the loaded
    content.
  - Target-less swings only reach cognition-halo agents, because that is the
    index population. Non-agent health entities are hit only by explicit-target
    intents. Document this limit.
- Attacker gate: alive, has `combat_stats`, `stepReached(step,
  next_attack_step)` (otherwise count `combat_attacks_on_cooldown`), and if it
  has `health`, `hit_points > 0` at step start.
- **Simultaneous resolution, so the outcome does not depend on intent order:**
  1. Phase 1 is pure. Roll damage for every accepted intent into fixed
     `[combat_max_hits_per_step]PendingHit` and accumulate per target into
     `[combat_max_hits_per_step]PendingTarget`, kept in first-hit order. Every
     hit source is bounded by a term of `combat_max_hits_per_step` (merged
     intents ≤ `action_intent_live_capacity`; 56B projectile hits ≤
     `projectile_hits_per_step`), and each append still asserts
     `len < capacity`.
  1b. (Slice 68C) Drop admission: a lethal carrier the `pending_drops` FIFO
     cannot admit is not killed this step; all its hits are removed before the
     preflight.
  2. Preflight `frame.events.ensureEventAppendCapacity(hits + kills)` and
     structural capacity for kills, as dig and destructible do. A capacity
     failure leaves no partial mutation.
  3. Phase 2 mutates:
     - attacker: `next_attack_step = stepAfter(step, attack_cooldown_steps)`
     - each target: `hit_points -|= sum`, `damage_taken_total +%= applied`,
       `last_damage_step = step`, `last_attacker = killer` (or the top
       contributor if the target survives)
     - a target that reaches 0 emits `entity_killed`, plus `destroy_entity`
       when `destroy_on_death` is set
  - Killer = the attacker with the largest applied contribution this step; ties
    go to the lowest entity index, then generation. That is independent of
    intent order, so two attackers can kill each other in the same step.
- Damage roll (`rng.zig` only, never `std.Random`):

  ```
  hit_seed = rng.mix64(rng.mix64(combat_seed, target.index, target.generation, combat_pair_salt),
                       attacker.index, attacker.generation, combat_hit_salt)
  v   = rng.uniformF32(hit_seed, 0, step, combat_variance_salt)
  c   = rng.uniformF32(hit_seed, 0, step, combat_crit_salt)
  raw = base_damage * (1 + (2v - 1) * damage_variance)
  if (c < crit_chance) raw *= crit_multiplier
  amount = math.roundClampToU32(raw * (1 - target_mitigation), 1, max_damage_per_hit)
  ```

  - `amount` is clamped while still wide (f32) before `@intFromFloat`, through
    a new named primitive in `src/core/math.zig`:
    `roundClampToU32(value: f32, min: u32, max: u32) u32` (round half away from
    zero, NaN → `min`, ±inf and out-of-range saturate). It ships with its own
    tests at both bounds, NaN, and ±inf; there is no SIMD form because no
    vector caller exists. A target without `combat_stats` has mitigation 0.
  - `combat_seed = self.seed.derive(.combat)`, computed once in
    `SimulationPipeline.init`, never per step. This slice appends
    `SeedDomain.combat = 3` (the value Slice 49 reserves).
  - The salts are distinct named `u32` constants in `combat_controller.zig`; a
    test asserts they are pairwise distinct.
  - Inputs are stable IDs, the step, and the seed, so the result is identical
    for any thread count, range split, or intent order.
- Particles: a soft-drop hit burst at the target center on every hit and a
  larger burst on kill, through a borrowed `?*ParticleSystem` (same as
  destructible).

**Events (domain_reaction stage, scalar-only payloads).**

- `EntityDamagedEvent { attacker, target, amount: u32, level: u16, critical: bool, lethal: bool }`
- `EntityKilledEvent { victim, killer, level: u16, destroyed: bool }`, emitted
  while the victim is still alive; the commit then emits `entity_destroyed`.
- Add the union variants, `SimulationEventStats` counters with
  `record`/`addProduced`/`recordTo` arms, and perf metrics.
- `EventProducerId.combat_resolve => combat_max_hits_per_step +
  combat_max_kills_per_step` (at most one hit per intent and one kill per hit;
  128 in this slice). `SimulationPipeline.reserve` picks it up automatically.

**Affect hookup: a real appraisal signal with no new drive.**

- `AiAffect` gains a hot `appraised_damage_total: u32` column, an affect-owned
  watermark.
- The `AffectSystem` gather resolves the row's optional `Health` and computes:
  - `delta = damage_taken_total -% appraised_damage_total`
  - `damage_signal = clamp(delta / max_hit_points, 0, 1)`, packed into
    `AffectGatherRow`.
- The range-disjoint scatter writes `appraised_damage_total = damage_taken_total`.
  Each store keeps a single writer, and each hit is appraised exactly once
  whatever the stagger cadence.
- Drive updates use two new module constants next to the existing gains:
  - `fear += gain_fear_damage (0.5) * damage_signal`
  - `aggression += gain_aggression_damage (0.3) * damage_signal`

  Slice 42 moves these gains to per-entity fields and may add an optional
  `pain` drive on the same watermark. The first new drive (`need`) lands in
  Slice 61, not here.
- Coast contract (if Slice 55 landed): damage reaches a coasting row through
  `Health.damage_taken_total` → watermark → drive mask (`above_threshold_mask`
  → at least `idle_near`). The attacker becomes alert input only through
  perception/memory.
- Rows without `Health` contribute zero (the optional-input rule). Undamaged
  rows stay bit-identical to today.
- Accepted edge case: attaching `AiAffect` after damage has been taken
  appraises the prior total once.

**Player.**

- Input: a new `Action.attack` (`src/app/input.zig:9-26`), default key `J`
  (an `SDL_SCANCODE_*` value in `default_key_bindings` if this lands after
  Slice 67A), gamepad `SDL_GAMEPAD_BUTTON_RIGHT_STICK` until Slice 70B moves
  it to `right_trigger`. `isGameplayAction` (`input.zig:186-191`) classifies `.attack` as
  gameplay, so modal routing blocks it like the other held gameplay actions;
  extend the routing tests.
- Replay: append the pinned replay bit for `attack` (bit 8, Slice 49 table) in
  the same change.
- Capture: `captureActionIntent` adds an `attack_held_last` rising-edge latch
  that advances only on a successful append. It emits `.attack` with
  `target = invalid` plus the faced cell (`has_cell`), so crates resolve first.
- Death: the player has `destroy_on_death = false`, so death emits
  `entity_killed{destroyed = false}` and leaves `hit_points = 0`.
  `combat_resolve` phase 0 restores `max_hit_points` on the next step. This is
  demo policy; a game-over transition belongs to a later state-level slice.

**Audio.** `AudioController.queueCombat(audio, frame, player.entity)` runs after
`pipeline.update`, next to `queueCollisionAudio`.

- Only `entity_damaged`/`entity_killed` events involving the player play
  `collision_sfx`, with distinct `frequency_ratio` values: hit 1.3, crit 1.6,
  kill 0.7.
- At most `combat_sfx_per_step = 4` per step, in event order.
- No new `AudioAssetId` until real files exist.

**Knockback is out of scope.** A velocity write in `combat_resolve` counts as a
`movement_positions` write between `chunk_derive` and `tier_policy`, which fails
the comptime freshness check. Knockback needs a next-step movement impulse
applied at `apply_ai_movement_intents` (Slice 68B; distinct from Slice 61's
`AffectImpulse`).

**Fixed budgets.**

| Constant | Value | Reason |
| --- | --- | --- |
| `action_intent_live_capacity` | 64 (unchanged) | Shared bus ceiling; combat does not raise it |
| `ai_action_budget_per_step` | 48 | Shared across all AI action kinds. Leaves at least 16 slots for player and other producers (2880 AI actions/s); overflow is rotating deferral (rotation start; deferral-age priority from Slice 68A) |
| `combat_max_hits_per_step` | `action_intent_live_capacity` (64) | One hit per intent; 56B adds `projectile_hits_per_step` |
| `combat_max_kills_per_step` | `combat_max_hits_per_step` | One kill per hit |
| `combat_arc_candidate_checks` | 32 | Player arc query cap, independent of world size |
| `combat_arc_query_slack` | 16 px | Step-start index vs current poses; fixed, not content-derived |
| `max_combat_attack_range` | 256 px | Bounds the arc `cellScanRadius` (with slack: 272 px) |
| `max_health_hit_points` / `max_damage_per_hit` | 1_000_000 | Keeps u32 headroom and exact integer math |
| `combat_sfx_per_step` | 4 | Audible ceiling, not scaled by population |
| Event budget `.combat_resolve` | `combat_max_hits_per_step + combat_max_kills_per_step` | At most 1 hit per intent and 1 kill per hit |
| Structural headroom | `+ combat_max_kills_per_step` destroys | At most 1 kill per hit |

The demo's `deriveDemoPopulationCapacity` adds `combat_max_kills_per_step` to
`structural_reserve` and `combat_max_hits_per_step + combat_max_kills_per_step`
to `event_reserve`.

**FailingAllocator proofs.**

1. `HealthStore` / `CombatStatsStore` append after `ensureCapacity`.
2. `AiActionSelectSystem.update` after reserve, on a real multi-worker
   `ThreadSystem` (at least 2 ranges), with the frame `action_intents`
   allocator failing.
3. `CombatController.process` covering revive, hit, kill, and cooldown reject
   after frame reserve. Swap the stream allocators the same way
   `destructible_controller.zig:673-728` does.
4. Extend the composite `pipeline.update` FailingAllocator test (smallest
   multi-level world) with one player attack and one lethal AI attack.

### Checklist

- [ ] `Health` / `CombatStats` types, two appended `Component` tags,
      `data_system/combat.zig` MAL stores and validators, and full component
      wiring (masks, slot indices, template, capacity needs, preflight/commit,
      destroy cleanup, accessors). Add store FailingAllocator and round-trip
      tests.
- [ ] Slice 49 classification: `HealthStore` / `CombatStatsStore` hashed in
      the completeness lists; their Slice 46 save sections in the same change.
- [ ] `simulation_scope.stepAfter` / `stepReached` helpers; every
      absolute-step write and comparison in this slice uses them.
- [ ] `core/math.roundClampToU32` with bound, NaN, and ±inf tests.
- [ ] Archetype `health` / `combat` blocks: strict parse,
      `melee_arc_degrees` → `melee_cos_half_arc`, validator errors. Add
      `aggressive`/`timid` content, update the parity table, and wire the
      player constants into `Player.spawn`.
- [ ] Pipeline graph: add `PipelineResource` `combat_state` / `combat_events` /
      `action_claims` and `StageId` `ai_action_select` / `combat_resolve` in
      `stage_order`. Add the `stageContract` arms and the
      `action_react` / `affect_update` contract changes. Add `runStage` arms and
      stage methods with `StageTimer` metrics `pipeline_ai_action_select` /
      `pipeline_combat_resolve`. Rewrite the contract tests. Raise
      `@setEvalBranchQuota` at `simulation_pipeline.zig:287` if the comptime
      contract walk needs it.
- [ ] `AiActionSelectSystem`: exhaustive per-kind arm switch with the
      `.attack` arm, threaded two-pass emit, rotating budget selection,
      deferral counter, reserve, worker asserts.
- [ ] `ActionClaimSet` (the only claim set), destructible claims, and the
      documented claim order trade → harvest → destructible. Update the
      existing destructible tests to pass a claim set.
- [ ] `CombatController`: `combat_max_hits_per_step` /
      `combat_max_kills_per_step` with comptime array-length asserts, phase 0
      downed revive, explicit and arc resolve (slack query + current-pose
      acceptance), two-phase simultaneous apply, rng rolls, preflight, death →
      `destroy_entity`, particles.
- [ ] `EventProducerId.combat_resolve`, the event payloads, stats, and metrics.
- [ ] Pipeline stats `ai_actions_emitted` / `ai_actions_deferred`,
      `combat_attacks_on_cooldown` / `_rejected`, `combat_hits`,
      `combat_kills`, `combat_revives`, recorded through `runtime_perf_log`.
- [ ] `combat_seed = seed.derive(.combat)` computed once at
      `SimulationPipeline.init`; append `SeedDomain.combat = 3`. No literal
      seed anywhere in combat code.
- [ ] Affect: `appraised_damage_total` column (store, slices, defaults), gather
      and scatter, and the two gain constants. Existing affect parity tests
      stay unchanged.
- [ ] `Action.attack` key/gamepad bindings, `isGameplayAction` classification
      with routing tests, the pinned replay bit (Slice 49 table, bit 8), and
      `attack_held_last` capture.
- [ ] (added by Slices 68A–68C) `stepAfter(now: StepIndex, delta: u32) StepIndex = now +| delta` and
      `stepReached(now: StepIndex, due: StepIndex) bool`.
      - Slice 56's own fields are typed `StepIndex`:
        `Health.last_damage_step` and `CombatStats.next_attack_step`.
      - Tests:
        - `stepAfter(maxInt(StepIndex) - 1, 5) == maxInt(StepIndex)`;
        - `stepReached(@as(StepIndex, maxInt(u32)) + 1, maxInt(u32))`, which
          crosses the old horizon without wrapping.
- [x] (added by Slices 68A–68C; applied in the roadmap split) Replace "must widen
      first: `@intCast((@as(u64, step) * budget) % len)` … is a Scaling Gap"
      with "is computed directly in `StepIndex` (Slice 49)", and retire the
      Scaling Gaps `step_count` width item.
- [ ] (added by Slices 68A–68C) Pipeline test (stays in 56, the first absolute-step consumer):
      - Set `pipeline.scope.step_count = maxInt(u32) - 1` with an attacker
        whose cooldown is due at `maxInt(u32) + 2`.
      - Run 4 `pipeline.update` steps.
      - Expect no trap, `staggerStep()` continuing `(maxInt(u32)+1) % 4 == 0`,
        and the attack landing on step `maxInt(u32) + 2`.
- [ ] (added by Slices 68A–68C) No checksum or save version bump for the type itself: v1 already hashes
      and saves `u64`. 56's bumps ride with its new stores.
- [ ] (added by Slice 64) `attack_held_last` is classified in 64B's
      `checksum_hashed_fields` and joins Slice 46's `"pipeline_history"`
      section in the same change. Test: toggling it changes the checksum.
- [ ] (added by Slice 67) Event-log feed arms for `entity_damaged` /
      `entity_killed` per the Slice 67B mapping table (exhaustive `lineFor`
      switch). Every `SimulationEventPayload` arm this slice adds gets a line
      or `=> null` in the same change.
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes.
      Otherwise 67E migrates it.
- [ ] `AudioController.queueCombat`, wired in `GameDemoState.update`.
- [ ] Demo `structural_reserve` / `event_reserve` terms from the named combat
      caps.
- [ ] (If 55 landed) Test: a coasting `idle_far` timid row with
      `gain_flee > 0`, hit by a visible attacker, decides on its next sense
      tick.
- [ ] Docs:
      - `docs/simulation-tiers-and-pipeline.md`: stage order, `action_intents`
        now stage-written plus claims, new events.
      - `docs/architecture.md`: combat controller and the `ai_action_select`
        processor in the landed-controllers list, the fixed-step pipeline
        list, the claim order, and the combat → affect signal.
      - `docs/state-stack-and-input.md`: the `attack` binding.
      - Archetype schema doc comment.

### Acceptance checks

- [ ] Determinism:
      - Identical `(seed, attacker, target, step)` gives identical amount and
        crit.
      - A different `SimulationSeed` gives a different roll sequence.
      - Across 1000 or more synthetic rolls, the crit rate is within ±3
        percentage points of `crit_chance`.
- [ ] `AiActionSelectSystem` serial (`max_worker_threads = 0`) and threaded
      (at least 2 ranges) runs produce identical merged candidates and emitted
      intents, including a budget-capped case where rotation applies. Deferred
      attackers keep their `next_attack_step`.
- [ ] Permuting the merged intent order gives identical final `hit_points`,
      death set, killers, and cooldowns. A mutual kill in one step works.
- [ ] Composite `pipeline.update` over 60 steps (small fixture with
      aggressive attackers, timid targets, and the player) gives identical
      health, cooldown, and kill checksums with 0 workers and with N workers.
- [ ] Resolution rules:
      - With a faced crate and an enemy, the crate is destroyed and the enemy
        is untouched (claims).
      - An explicit-target attack on a friendly is rejected.
      - Cooldown rejects a second swing.
      - A target-less swing respects arc and reach on current poses.
      - A target that was outside reach at step start and moved into reach
        this step (within `combat_arc_query_slack`) is hit by a target-less
        swing this step; one that closed more than the slack is hit on the
        next step (documented lag).
      - A cooldown set at `step = maxInt(StepIndex) - 5` saturates and never
        traps.
- [ ] Kill path: `entity_killed` is emitted while the victim is alive, then
      commit emits `entity_destroyed`. With `destroy_on_death = false` the
      entity stays at 0 HP for that step and `combat_resolve` phase 0 revives
      it on the next step (through `pipeline.update`, counted in
      `combat_revives`).
- [ ] Affect:
      - A damaged timid row's fear rises exactly once per damage delta across
        stagger phases.
      - Undamaged rows are bit-identical to pre-slice outputs.
      - `affect_update` carries `combat_state`.
- [ ] Comptime payload-purity tests for both events. No test-only tags or
      stages.
- [ ] FailingAllocator proofs (1)–(4) pass.
- [ ] Benchmarks (one `BenchmarkGroup` per workload in `src/benchmarks/`,
      hyphenated names, sizes in `defaultItemCounts`; the shared worker-mode
      cases such as `serial-direct` / `thread-fixed-2` are the cases):
      - Add and run `zig build bench -- --group ai-action-select` (default
        items 1024 / 4096 / 10000 cognition rows, about 25% in reach).
      - Add and run `zig build bench -- --group combat-resolve --case
        serial-direct` (default items 64 intents).
      - `zig build bench -- --group ai-affect` shows no multi-x regression.
- [ ] Run the battle-scale control re-baseline procedure (Slice 68A §3:
      hands-off, default seed, ReleaseSafe, three 60 s soaks, ±2% count
      agreement, row schema). Record the 56 rows (`ai_action_select`,
      `combat_resolve`, `ai_actions emitted / deferred`,
      `combat hits / kills`, `movers start / avg`) and move the pre-56 table
      to History. (Replaced by Slices 68A–68C.)
- [ ] `zig build verify` passes.

### VoidLight reference

Port:

- Damage formula shape: base × variance × crit (`AttackBehavior.cpp:211-231`).
  `armorDefense` becomes `armor_mitigation`.
- Attack cooldown (`CombatController.cpp:95-101,115-120`), held as an absolute
  `next_attack_step`.
- Player faced-arc melee (`CombatController.cpp:192-264`): the 180 degree arc
  becomes `melee_cos_half_arc`, resolved to a single nearest target.
- `CharacterData` health / maxHealth / attackDamage / attackRange
  (`include/managers/EntityDataTypes.hpp:249-266`) become `Health` and
  `CombatStats`.
- The "critical health → flee" rule (`AttackBehavior.cpp:486-490`) emerges
  through damage → fear → arbitration instead of a hard-coded rule.

Do not port:

- `thread_local std::mt19937 s_rng{std::random_device{}()}` and the
  `uniform_real_distribution` rolls (`AttackBehavior.cpp:24-28`). They are
  nondeterministic and implementation-defined.
- Immediate-dispatch damage events and thread-local deferred event vectors
  (`AttackBehavior.cpp:238-252,1084-1087`).
- UI event-log strings inside combat code (`CombatController.cpp:246-262`).
- Stamina; berserker, combo, special, and AoE attacks; knockback (Slice 68B;
  not a VoidLight port).
- The `dynamic_pointer_cast<Equipment>` weapon lookup.

