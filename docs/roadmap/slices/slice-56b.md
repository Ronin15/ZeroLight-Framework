## Slice 56B: Projectiles And Ranged Combat

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56](slice-56.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 56. Independent of 57.

Goal: ranged attackers spawn deterministic projectile entities from the same
`.attack` intents. Projectiles move with the existing movement integrator, hit
through the existing collision-trigger stream, and deal damage through
`CombatController`'s accumulation and rolls. No swept physics; fixed
spawn/hit/expiry budgets, a content-derived live projectile capacity, and every combat array and reserve is resized from
Slice 56's named caps.

### Current foundation (do not rebuild)

- Slice 56: `AiActionSelectSystem` (`.attack` arm), `CombatController`'s
  two-phase accumulation sized by `combat_max_hits_per_step` /
  `combat_max_kills_per_step`, `combat_state`, `entity_damaged` /
  `entity_killed`, `combat_seed = seed.derive(.combat)`, and the
  `stepAfter` / `stepReached` helpers.
- Movement integrates the full contiguous range
  (`simulation_pipeline.zig:1215-1221`).
- Collision response appends one trigger pair per contact when either side is
  `.trigger` (`systems/collision_response.zig:113-131`), read through
  `frame.collision_triggers`. One projectile overlapping several bodies
  therefore yields several pairs in one step.
- `always_active` scope metadata (`types.zig:181`, set via
  `setSimulationMetadata`) keeps an entity in active scope off-camera.
- `WorldSystem.levelBlocksMovement` / `cellContaining`
  (`world_system.zig:1464,1549`). `world_gate` clamps only AI agents and the
  player (`world_gate.zig:24-27`), never projectiles.
- Demo collision capacity: `estimateContactCapacity(mover_count +
  obstacle_count + 1)` / `estimateTriggerCapacity` and `.movement_body_capacity`
  (`game_demo_state.zig:127-135,431,442-443`).
- Demo archetype cycle: `demo_archetype_cycle_len = ai_archetypes.archetype_count`
  with `demo_slot_ids` and `demoArchetypeForIndex` (`index %
  demo_archetype_cycle_len`) (`game_demo_state.zig:1003-1035`).

### Architecture notes

**Ranged stats.**

- `CombatStats` gains cold fields and matching archetype keys:
  `attack_mode: AttackMode { melee, ranged } = .melee`,
  `projectile_speed: f32` in `(0, max_projectile_speed]`,
  `projectile_lifetime_steps: u16` in `1..=240`, and
  `projectile_size: f32` in `[4, 16]`.
- `max_projectile_speed = 720` px/s, which is at most 12 px per 60 Hz step.
  **Documented limit:** a projectile cannot skip a collider of 12 px or more,
  and may tunnel through a smaller one. Target collider size is authored
  elsewhere, so this slice does not claim to enforce it; it documents the limit
  and pins it with a 12 px test.

**New component `projectile` (one `Component` tag, appended).**

- Fields: `owner: EntityId`, `owner_faction: Faction`, a snapshot of
  `base_damage`, `damage_variance`, `crit_chance`, `crit_multiplier` (so the
  owner's death does not cancel the hit), `expire_step: StepIndex` (written with
  `stepAfter`), `pierce_remaining: u8` (0 = destroyed on first hit), and
  `last_hit_target: EntityId`.
- MAL store in `data_system/combat.zig` and `EntityTemplate.projectile`. No set
  variant. Slice 49 classification: the projectile store is hashed, with its
  Slice 46 save section in the same change.
- Projectile entities also carry `movement_body`, `collision_bounds`,
  `collision_response{ .trigger, .dynamic }`, `world_level`, `primitive_visual`
  plus `asset_reference(.grim_items, "arrows")`, and `always_active` scope
  metadata (bounded by `projectile_live_capacity`).

**Spawn.**

- In `CombatController`, phase 1 treats an accepted ranged `.attack` as a spawn
  request (no roll).
- Phase 2 queues a `create_entity` at the attacker center plus
  `dir * (half_extent + 4)`:
  - `dir` is the normalized vector to the target's AABB center (through
    `core/math.normalizeOrDefaultFinite`), or the facing for a target-less
    attack.
  - Velocity is `dir * projectile_speed`, and the cooldown is consumed.
- A spawn is refused when it would exceed `projectile_spawns_per_step`, or when
  `projectile store len + spawns queued this step >= projectile_live_capacity`.
  The second check is a canary: the capacity (Budgets below) is sized from
  the per-step spawn budget and the longest authored lifetime, which makes it
  unreachable, so it also counts `projectiles_refused_live_capacity`,
  which must stay 0. On either refusal the cooldown is not consumed (the
  attack retries), and `projectiles_refused` is incremented.

**New stage `projectile_update`, between `action_react` and `combat_resolve`.**
New tags `projectile_state` and `projectile_hits`. Raise `@setEvalBranchQuota`
at `simulation_pipeline.zig:287` if the comptime contract walk needs it.

- Contract: reads `{movement_positions, world_level, world_tiles, collision_triggers}`;
  writes `{projectile_state, projectile_hits, structural_commands}`.
- Runs serially over the projectile store (at most `projectile_live_capacity`):
  - Expiry (`stepReached(step, expire_step)`), tile-blocked impact, and
    **out-of-world** (`cellContaining == null`) queue `destroy_entity`, at most
    `projectile_expiry_budget_per_step` per step. The rest wait for the next
    step, in dense order.
  - Scan merged `collision_triggers` for (projectile, other) pairs where the
    other side carries `health`, is not the owner, is not `last_hit_target`,
    and is not friendly. **At most one hit per projectile per step: the first
    qualifying pair in trigger order wins** (trigger order is the merged,
    deterministic contact order); later pairs for the same projectile that
    step are skipped. A per-step `projectile_hit_this_step` bit (indexed by
    projectile dense row; a pipeline-owned `std.DynamicBitSetUnmanaged`
    reserved to `projectile_live_capacity` in `SimulationPipeline.reserve` and
    cleared at the start of `projectile_update`; per-step scratch, excluded
    from the checksum and never saved) enforces it.
  - Each accepted pair becomes a `ProjectileHit {projectile, target}` in a
    fixed `[projectile_hits_per_step]ProjectileHit` `StepState` array; the
    append asserts `len < projectile_hits_per_step`. Overflow is deferred
    naturally, because the overlap re-triggers next step.
  - A static `.solid` partner destroys the projectile.
  - A hit decrements pierce or destroys the projectile.

**Resolve.**

- `combat_resolve` adds `projectile_hits` and `projectile_state` to its reads
  and folds the hits into the same `PendingTarget` accumulation.
- **Caps (redefined here, in `combat_controller.zig`):**
  `combat_max_hits_per_step = action_intent_live_capacity +
  projectile_hits_per_step` (128) and `combat_max_kills_per_step =
  combat_max_hits_per_step` (128). Slice 56's `PendingHit` / `PendingTarget`
  arrays, event budget, and pipeline-owned `combat_structural_event_share` are
  sized from these, so they grow with this change; the comptime array-length asserts from Slice 56 catch
  any missed site. Without this, 64 intents plus 64 projectile hits would
  overrun 64-entry arrays (out-of-bounds UB in ReleaseFast).
- The roll treats the projectile entity as the attacker in `hit_seed`. Killer
  attribution uses `owner`.

**Budgets and the live capacity.**

| Constant | Value |
| --- | --- |
| `projectile_live_capacity` | content-derived at state init (capacity, not a budget; see below) |
| `projectile_spawns_per_step` | 32 |
| `projectile_hits_per_step` | 64 |
| `projectile_expiry_budget_per_step` | 64 |
| `combat_max_hits_per_step` | `action_intent_live_capacity + projectile_hits_per_step` (128) |
| `combat_max_kills_per_step` | `combat_max_hits_per_step` (128) |

- **`projectile_live_capacity` is a content-derived capacity.**
  `deriveProjectileLiveCapacity` (`combat_controller.zig`) computes it once at
  state init, after the archetype catalog loads:
  `projectile_live_capacity = projectile_spawns_per_step ×
  (max_projectile_lifetime_steps + 1)` (≤ 32 × 241), or 0 when no loaded
  `CombatStats` is ranged.
  - `max_projectile_lifetime_steps` is the largest authored
    `projectile_lifetime_steps` over every loaded ranged `CombatStats`.
    Validation caps it at 240, so the capacity never exceeds `32 × 241`; no
    separate ceiling is needed. No population source adds a term: the bound
    depends only on the fixed spawn budget and loaded lifetimes.
  - `GameDemoState` passes it through
    `SimulationPipelineConfig.projectile_live_capacity`. The projectile store,
    the `projectile_hit_this_step` bitset, `.movement_body_capacity`, and the
    collision body count reserve from it at init.
  - Soundness: per-step spawns are at most `projectile_spawns_per_step`, every
    projectile is destroy-eligible `projectile_lifetime_steps` after its
    spawn, and `comptime assert(projectile_expiry_budget_per_step >=
    projectile_spawns_per_step)` drains the eligible backlog at least as fast
    as spawns refill it. The store therefore holds at most
    `projectile_spawns_per_step × (L_max + 1)` rows at a step boundary, and the live-capacity
    refusal is a canary, never the working limit.
  - The value is a pure function of loaded content and fixed constants, so
    serial and threaded runs size identically.
- `EventProducerId.combat_resolve` stays
  `combat_max_hits_per_step + combat_max_kills_per_step` (now 256).
- **Structural share, enumerated per stage.** `combat_resolve` and
  `projectile_update` are pipeline stages, so every projectile structural
  command is pipeline-owned and counted in `pipeline_structural_event_share`
  (`simulation.zig`). Callers add nothing: `demo_structural_headroom` stays
  `structuralEventHeadroom(demo_creates_per_step, 0)`.
  - `combat_resolve`: Slice 56's `combat_structural_event_share` is redefined
    as `structuralEventHeadroom(projectile_spawns_per_step,
    combat_max_kills_per_step)`. That is the projectile spawn creates (32, each
    up to `max_structural_events_per_create` events) plus the victim kill
    destroys. The kill term stays Slice 56's own: it reaches 128 through the
    redefined `combat_max_kills_per_step`, so this slice does not add kills a
    second time.
  - `projectile_update`: a new sibling constant
    `projectile_structural_event_share = structuralEventHeadroom(0,
    projectile_hits_per_step + projectile_expiry_budget_per_step)`. That is the
    destroys on hit (64) plus the expiry/impact/out-of-world destroys (64). It
    is added as a term of `pipeline_structural_event_share`.
  - A projectile that hits and expires in one step queues two destroys. The
    share counts both, and structural commit tolerates the double destroy.
    The `.structural_commit` share, the structural-command stream room
    (`structuralCommandHeadroom()`), and the demo's pinned `capacity_limit`
    all grow by these terms through the pipeline. The demo re-pins its
    `capacity_limit` literal test by hand.
- **Collision capacity.** Add `projectile_live_capacity` to the body count the
  demo passes to `estimateContactCapacity` (and therefore
  `estimateTriggerCapacity`) and to `.movement_body_capacity`. Intent capacity
  is unchanged: trigger pairs never produce physical intents
  (`collision_response.zig:113-121`). The spatial index is unchanged:
  projectiles carry no `AiAgent`, and the index population is the cognition
  halo.
- Slice 57's world-item creates derive from `combat_max_kills_per_step`, so
  its loot bound follows this change automatically (asserted there).

**Demo content.** Append `AiArchetypeId.archer` (hostile, perception, memory,
affect, health, and ranged combat) with a JSON entry. It sits **outside the
8-slot demo cycle**, so existing archetype parity really is untouched:

- `demo_archetype_cycle_len` is pinned to `demo_slot_ids.len` (8) instead of
  `ai_archetypes.archetype_count`, keeping `comptime assert(demo_slot_ids.len
  == 8)`. `demoArchetypeForIndex`, `demo_cognition_archetypes_per_cycle` (3),
  `demoCognitionAgentCount`, the perception/affect reserves, and the
  battle-scale baseline do not change.
- The demo spawns a fixed `demo_archer_count = 4` archers near the player
  start through a separate fixed placement (the same precedent Slice 61 uses
  for `forager`). `deriveDemoPopulationCapacity` adds `demo_archer_count` to
  its mover, cognition, and event terms as a fixed constant.

Ammo consumption lands in Slice 68C (`requires_ammo`, `TransferBatch.consume`).

### Checklist

- [ ] `CombatStats` ranged fields with archetype keys and validation; `archer`
      archetype outside the 8-slot cycle (`demo_archetype_cycle_len` pinned to
      `demo_slot_ids.len`), `demo_archer_count` placement and capacity terms.
- [ ] `projectile` component (one appended tag), store, and template, with the
      FailingAllocator store proof. Slice 49 classification (hashed) and Slice
      46 save section.
- [ ] Spawn path in `CombatController`, including the refusal semantics.
- [ ] Content-derived `projectile_live_capacity`: `deriveProjectileLiveCapacity`
      (`projectile_spawns_per_step` × (catalog max ranged
      `projectile_lifetime_steps` + 1))
      passed through `SimulationPipelineConfig`; the comptime
      `projectile_expiry_budget_per_step >= projectile_spawns_per_step` assert;
      the pipeline-owned `projectile_hit_this_step` bitset reserved to it; the
      `projectiles_refused_live_capacity` canary counter.
      - Tests: the derivation equals the hand formula on a minimal catalog,
        and is 0 with no ranged content; a sustained max-rate fixture
        (`projectile_spawns_per_step + 1` ranged attackers, cooldown 1, the
        largest authored lifetime, every shot missing) holds the store at
        `<= projectile_spawns_per_step × (L_max + 1)` and never trips the
        canary.
      - `FailingAllocator` proof: `projectile_update` plus spawns with the
        store at the derived capacity allocate nothing after the init
        reserve (store, bitset, structural and event streams).
- [ ] `projectile_update` stage, tags, contract, `runStage` arm, and
      `pipeline_projectiles` timer; `@setEvalBranchQuota` raised if needed.
- [ ] One-hit-per-projectile-per-step rule and out-of-world destroy.
- [ ] Projectile hits folded into `combat_resolve`; `combat_max_hits_per_step`
      / `combat_max_kills_per_step` redefined, with the Slice 56 comptime
      array-length asserts still passing.
- [ ] Event budget and pipeline-owned structural terms. Slice 56's
      `combat_structural_event_share` is redefined as
      `structuralEventHeadroom(projectile_spawns_per_step,
      combat_max_kills_per_step)`, and the new
      `projectile_structural_event_share = structuralEventHeadroom(0,
      projectile_hits_per_step + projectile_expiry_budget_per_step)` is added
      as a term of `pipeline_structural_event_share`.
      `demo_structural_headroom` is unchanged (callers add nothing), and the
      demo `capacity_limit` literal is re-pinned.
      - Test (in `simulation_pipeline.zig`): use a pipeline with
        `structural_headroom = 0`. Write one step's maximal projectile command
        set with the test file's `writeStructuralCommands` helper:
        `combat_resolve`'s `projectile_spawns_per_step` projectile creates and
        `combat_max_kills_per_step` victim destroys, plus `projectile_update`'s
        `projectile_hits_per_step` hit destroys and
        `projectile_expiry_budget_per_step` expiry destroys, all on distinct
        live entities. It commits through `applyStructuralCommandsBudgeted(&data,
        pipeline.structuralCommitBudget(0))` and applies every command.
        `maxEventsPerStep(.structural_commit, pipeline.eventBudgets())` equals
        `pipeline_structural_event_share`, which includes both terms.
- [ ] Collision contact/trigger and `movement_body_capacity` body count includes
      `projectile_live_capacity` (initial sizes only;
      `SimulationPipeline.syncPopulationCapacity` grows every
      population-sized pipeline capacity at the commit seam — Slice 72 C3); counters `projectiles_spawned` / `_refused` /
      `_hits` / `_expired` / `_out_of_world`.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md` and
      `docs/architecture.md` (including the documented 12 px tunnel limit).
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes.
      Otherwise 67E migrates it. Every `SimulationEventPayload` arm this
      slice adds gets an `event_log_feed.lineFor` line or `=> null` (Slice
      67B) in the same change.

### Acceptance checks

- [ ] Behavior:
      - A projectile hits its target.
      - The owner and friendlies are never hit.
      - `pierce = 1` hits two distinct targets, then the projectile dies.
      - A projectile overlapping two health targets in one step hits only the
        first in trigger order, and only once.
      - Tile impact, lifetime expiry, and leaving the world
        (`cellContaining == null`) destroy the projectile.
      - A refusal at `projectile_spawns_per_step` keeps the cooldown, and so
        does the live-capacity canary when a fixture passes a capacity below
        the derived value.
- [ ] A projectile at max speed cannot skip a 12 px collider.
- [ ] Capacity derivation: `projectile_live_capacity` equals
      `projectile_spawns_per_step × (max_projectile_lifetime_steps + 1)` for
      the loaded content, and
      sustained max-rate fire never increments
      `projectiles_refused_live_capacity`.
- [ ] Capacity: a step with 64 accepted melee intents plus 64 projectile hits
      fills the resized `PendingHit` array exactly, with no overrun, under the
      FailingAllocator composite test.
- [ ] Determinism: same seed gives the same hit amounts. A 120-step archer
      duel through `pipeline.update` produces identical health/kill checksums
      with 0 workers and with N workers.
- [ ] Demo parity: `demoArchetypeForIndex` and `demoCognitionAgentCount`
      outputs are unchanged for indices 0..64 after `archer` is appended.
- [ ] FailingAllocator: `projectile_update` and `combat_resolve` with spawns
      and hits after reserve.
- [ ] `zig build bench -- --group combat-projectiles` (new group; default
      items 1024 live projectiles) is added and run.
- [ ] (added by Slices 68A–68C) Run the Slice 68A §3 re-baseline procedure and
      record this slice's schema rows (`projectile_update` / projectiles
      live).
- [ ] `zig build verify` passes.

### VoidLight reference

- Port: `ProjectileData` owner/damage/lifetime (`EntityDataTypes.hpp:333-339`);
  lifetime = range / speed + slack (`CombatController.cpp:183-186`); spawn
  offset along the attack direction.
- Do not port: the embed-into-target system
  (`ProjectileManager.cpp:130-171`); `thread_local` pending-embed vectors and
  per-manager WorkerBudget threading (`:349-500`); singleton manager state;
  ammo consumption coupled to combat (`CombatController.cpp:169-178`).

