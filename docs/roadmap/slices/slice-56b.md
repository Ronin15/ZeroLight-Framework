## Slice 56B: Projectiles And Ranged Combat

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56](slice-56.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Independent of 57.

Goal: ranged attackers spawn deterministic projectile entities from the same
`.attack` intents. Projectiles move with the existing movement integrator,
hit through the existing collision-trigger stream, and deal damage through
Slice 56's accumulation and rolls. No swept physics. Spawns, hits, and
expiries run under fixed per-step budgets with deterministic deferral; the
projectile store starts at content-derived size and grows at the commit
seam, so a shot is never refused for capacity.

### Current foundation

- Slice 56 provides the attack data path, `CombatController`'s two-phase
  accumulation sized from its named per-step caps, combat events, the
  combat seed domain, and the absolute-step helpers.
- Movement integrates the full contiguous range in `movement_integrate`
  (`src/game/simulation_pipeline.zig`).
- `CollisionResponseSystem` appends one trigger pair per contact when either
  side is `.trigger` (`src/game/systems/collision_response.zig`), read
  through `frame.collision_triggers`; one projectile overlapping several
  bodies yields several pairs in a step.
- `WorldSystem.levelBlocksMovement` / `cellContaining`
  (`src/game/world_system.zig`); `world_gate` clamps only AI agents and the
  player (`src/game/systems/world_gate.zig`).
- Population capacities grow at one commit-seam point
  (`SimulationPipeline.syncPopulationCapacity`, Slice 72).

### Architecture notes

- Ranged stats are `CombatStats` content (mode, speed, lifetime, size) with
  strict validation. A fixed maximum speed (720 px/s, 12 px per step) is the
  documented tunnelling limit: a projectile cannot skip a collider of 12 px
  or more.
- `projectile` is one appended component; an owner's death never cancels a
  hit; the store is hashed and saved (Slice 49 lists, Slice 46 section).
- At most one hit per projectile per step, first qualifying pair in the
  deterministic trigger order; never the owner, a friendly, or the last
  target.
- Projectile hits fold into `combat_resolve`'s accumulation; every combat
  cap and reserve is resized from Slice 56's named caps plus this slice's
  hit term, comptime-checked so an undersized array cannot compile.
- Fixed per-step counts for spawns, hits, and expiries; over-budget spawns
  defer with the cooldown kept, over-budget hits defer deterministically to
  later steps (never dropped or refused), over-budget expiries wait in dense
  order (`.claude/rules/budgets-capacities.md`). No live-capacity refusal.
- Expiry, tile impact, and leaving the world destroy the projectile;
  projectiles advance at every distance like any entity.
- Collision and movement capacities include projectiles at their initial
  size and grow with them at the seam (`.claude/rules/memory-performance.md`).
- Projectile work scaling with live count runs through the thread system
  where the cost model says so (`.claude/rules/threading.md`).
- Ammo consumption lands in Slice 68C.
- VoidLight reference: port owner, damage, lifetime (range / speed + slack),
  and the spawn offset; not embed-into-target, thread-local pending vectors,
  singleton managers, or ammo coupled to combat.

### Checklist

- [ ] Ranged `CombatStats` content and validation; one ranged archetype.
- [ ] `projectile` component, store, template; store `FailingAllocator`
      proof; Slice 49 classification and Slice 46 section.
- [ ] Spawn from accepted ranged attacks with budget deferral keeping the
      cooldown.
- [ ] `projectile_update` stage with its tags and contract: expiry, tile
      impact, out-of-world, one-hit-per-step rule, pierce.
- [ ] Projectile hits folded into `combat_resolve`; combat caps resized with
      comptime checks.
- [ ] Event budget and pipeline-owned structural share for projectile
      creates and destroys; capacity-limit test re-pinned.
- [ ] Projectile store and collision capacities grow at the commit seam;
      counters for spawned, deferred, hits, expired, out-of-world.
- [ ] (added by Slice 67) Event-log and `StringId` text for new payloads.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md`, `docs/architecture.md`
      (the 12 px tunnelling limit).

### Acceptance checks

- [ ] A projectile hits its target and never its owner or friendlies;
      pierce 1 hits two distinct targets; an overlap of two targets hits only
      the first in trigger order, once.
- [ ] Tile impact, expiry, and leaving the world destroy it; a deferred
      spawn keeps the cooldown.
- [ ] A max-speed projectile cannot skip a 12 px collider.
- [ ] Sustained max-rate fire grows the store at the seam and never refuses
      a spawn for capacity.
- [ ] A step at every hit cap fills the combat arrays exactly, with no
      overrun, under the composite `FailingAllocator` proof; hits past the
      cap land on later steps, none dropped.
- [ ] Same seed gives the same hits; an archer duel has identical checksums
      at 0 and N workers.
- [ ] Bench `combat-projectiles` at three live counts shows cost linear in
      live projectiles; Slice 68A soak rows recorded.
- [ ] `zig build verify` passes.
