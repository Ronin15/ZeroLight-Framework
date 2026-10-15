## Slice 68B: Knockback Impulses And Retaliation Memory

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 55](slice-55.md), [Slice 56](slice-56.md), [Slice 56B](slice-56b.md), [Slice 49](slice-49.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Independent of 57, 61, and 68A.

Goal: hits push targets, and victims learn who hit them, deterministically
and with nothing pending outside `DataSystem` at a step boundary.

- **Knockback.** `combat_resolve` writes a per-body knockback velocity; a
  stage after `movement_integrate` integrates and decays it before collision
  and the tile gate settle the pose, so `combat_resolve` never writes
  positions after `chunk_derive`.
- **Retaliation.** A victim's memory gains a retaliation entry for its most
  recent attacker, ingested from `Health` by `ai_memory_update` once per
  damage step. It gives pursue and flee a goal even when the attacker was
  never seen (through Slice 73 behavior data reading a retaliation signal),
  and it wakes a coasting agent like fresh memory does.

Out of scope (decided): stun or loss of control (knockback is additive and
never touches velocity); non-combat knockback producers (a future producer
writes the same column under the same contract); retaliation against more
than the most recent attacker per sensing tick; sharing retaliation with
allies (Slice 71A's help call).

### Current foundation

- `MovementSystem.applyIntents` (`src/game/systems/movement.zig`) overwrites
  AI velocity only from this step's intents; velocity otherwise persists,
  which coasting relies on. Player velocity is set from input every step
  (`src/game/player.zig`). `movement_integrate` is SIMD with a scalar tail
  over the full range.
- Settle order: collision scope gather → detect → respond → bounds and tile
  gate → plane traversal → chunk derive (`src/game/simulation_pipeline.zig`);
  the tile gate reverts an axis to the pre-step pose and zeroes that axis's
  velocity (`src/game/systems/world_gate.zig`); the surface level is a
  pass-through. Tiles are 32 px.
- `chunk_derive` derives chunk columns from positions, which is why knockback
  cannot be written in `combat_resolve`.
- Memory (`src/game/systems/ai_memory.zig`): decay gather/scatter, a 4-slot
  sighting ring (`upsertRingContact`), and the visible-target refresh.
- Arbitration (`src/game/systems/arbitration.zig`): with a configured focus
  target, fresh memory of a different entity never gives pursue a goal, so
  an NPC hit by another NPC never fights back today.
- From earlier slices: 56's top-contributor `last_attacker`,
  `last_damage_step`, and `CombatStats`; 56B's projectile damage snapshot;
  55's alert inputs; 73's signal primitives.

### Architecture notes

- Knockback is persistent movement state (hashed and saved with the movement
  store), written at step s and integrated from step s+1; inputs are the top
  contributor and stable poses, so permuted intents give identical columns.
- Fixed constants: a maximum knockback speed under 56B's tunnelling limit,
  geometric decay per step, and a rest speed snapping to exactly 0; never
  derived from content.
- A tile-gate revert or a bounds clamp on an axis also zeroes that axis's
  knockback, so a body never re-hits a wall for the decay's length and keeps
  its own velocity.
- The knockback stage is threaded with a serial twin and a SIMD kernel with
  scalar-tail parity; idle rows cost one small read
  (`.claude/rules/threading.md`, `.claude/rules/memory-performance.md`).
- Retaliation is a memory entry separate from the sighting ring, so
  sightings never evict it; it ages on the memory cadence and expires after
  a fixed time; ingest is a watermark on `last_damage_step`, so each damage
  step is read once whatever the cadence.
- Retaliation is a Slice 73 signal primitive; pursue and flee read it
  through behavior data, ranked between fresh memory and a visible threat;
  empty retaliation leaves scores and goals bit-identical. A producer adding
  a goal-resolving signal adds it to Slice 55's alert inputs.
- New hashed state is classified in Slice 49's lists and saved by Slice 46
  with relative bumps; the knockback processor's tuner and stats are
  excluded (64B).
- VoidLight reference: no combat knockback to port; retaliation ports "being
  attacked bypasses idle throttling", not message-bus alerts or per-frame
  urgent queries.

### Checklist

- [ ] Knockback columns on movement bodies: store, slices, validation,
      round-trip and `FailingAllocator` tests.
- [ ] Knockback speed and resistance as `CombatStats` content; projectile
      snapshot; content values.
- [ ] `combat_resolve` knockback write (top contributor, direction, clamp,
      skip rules, counter).
- [ ] Knockback stage after `movement_integrate`: tag, contract, threaded
      and serial paths, timer.
- [ ] Tile gate and bounds clamps zero the knockback on a reverted axis;
      contract updated.
- [ ] Attacker position recorded with `last_attacker`.
- [ ] Retaliation memory entry: store, aging, expiry, ingest; memory update
      carries combat state.
- [ ] Retaliation signal primitive and pursue / flee behavior data; Slice 55
      alert input.
- [ ] Persistence: classification, save fields, relative bumps; 64B row.
- [ ] Tests (knockback): SIMD == scalar, serial == threaded, rest and
      displacement, additive to AI velocity, wall on a gated level, bounds,
      contact separation, permutation, zero-knockback parity, composite
      checksum at 0 and N workers.
- [ ] Tests (retaliation): an ally hit from outside its FOV pursues the hit
      position; a timid row flees from it; once per damage step; last
      attacker wins between ticks; expiry; dead attacker ignored; sightings
      do not evict; empty-entry parity; zero gain unaffected; a coasting row
      wakes.
- [ ] `FailingAllocator` proofs: knockback stage, memory with ingest,
      composite pipeline.
- [ ] Bench `knockback` (idle and active families) and Slice 68A soak row.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md`, `docs/architecture.md`,
      archetype schema.

### Acceptance checks

- [ ] `combat_resolve` never writes positions; the comptime freshness check
      passes with the knockback stage in order.
- [ ] Knockback determinism: SIMD == scalar, serial == threaded,
      permutation invariance, composite checksums.
- [ ] No knocked body ends a step inside a solid tile; a reverted or clamped
      axis carries zero knockback into the next step.
- [ ] Retaliation behavior tests pass with arbitration parity on an empty
      entry and the Slice 55 wake test.
- [ ] `knockback` at three sizes: idle cost linear and well below
      `movement`; `movement` unchanged; active actuals recorded.
- [ ] `zig build verify` passes.
