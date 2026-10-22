## Slice 68C: Carried-Inventory Death Drop And Ranged Ammo

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56B](slice-56b.md), [Slice 57](slice-57.md), [Slice 61](slice-61.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Reads 57B's toast for coin piles if 57B has
landed; nothing depends on it.

Goal: a destroyed victim drops everything it carried as world items: every
equipped item, every non-empty stack, and its coins as one coin pile.
Drops wait in a persistent queue that grows at the commit seam and drains
under a fixed per-step spawn budget in FIFO order, so no item is ever lost
and no kill is refused; over-budget work defers. Ranged weapons that
require ammo consume one matching ammo item per projectile through Slice
57's transfer substrate; an attacker without ammo falls back to melee at a
fixed reach.

Out of scope, decided: arrow recovery, ammo crafting, corpse containers
(drops are world items); ammo classes beyond `arrow` (append-only, each with
its first weapon); player death drops (the player is downed, Slice 56).

### Current foundation

- Slice 57's Loot phase rolls one loot-table item per `entity_killed` at the
  victim center while the victim is still alive; carried slots are not
  dropped (57's documented gap, closed here).
- Slice 57's world items (`count == 0` means taken), single-winner pickup,
  currency credit to coins, `ItemKind`, the strict `items.json` loader and
  its fingerprint, `ItemPickedUpEvent`.
- Slice 57's transfers (`TransferBatch.grant`, the step queue, `canRemove`,
  all-or-nothing apply in phase 0); Slice 61 wires the queue into the
  pipeline.
- Slice 56B: ranged attacks become projectile spawns; a deferred spawn keeps
  the cooldown.
- Atlas `assets/sprites/grim_items.json` has `bow`, `arrows`, `gold_coins`.

### Architecture notes

- Kill outcomes never depend on queue capacity
  (`.claude/rules/budgets-capacities.md`): the drop queue is persistent
  `DataSystem` state that starts at content-derived size and grows at the
  commit seam (`.claude/rules/memory-performance.md`); only the per-step
  spawn budget is fixed.
- The queue's only writer is `inventory_update`; entries are pushed in a
  fixed order per victim (equipment slots, then inventory slots, then the
  coin entry) and spawned in FIFO order. It is hashed in FIFO order and
  saved (Slice 49 lists, Slice 46 section, relative bumps).
- World-item creates follow Slice 57's world-item policy.
- Coin piles are world items carrying coins; pickup credits coins and needs
  no free slot; the pickup event gains a scalar coins field.
- Ammo is catalog content (`ammo` kind, an ammo class, a weapon's required
  class); the catalog version and fingerprint change with it.
- Ammo is consumed through a one-sided transfer batch added to Slice 57's
  transfer module (57 stays owner); spawn and consume are both-or-neither,
  and a consume queued before apply never fails at apply.
- The AI emitter picks ranged or fallback reach from ammo presence, read
  only; combat resolve rechecks against this step's queued transfers.
- Work is bounded per step by fixed counts and runs serial only where the
  cost model allows (`.claude/rules/threading.md`).
- VoidLight reference: port required-ammo matching (first compatible stack,
  one per shot) and the AI ranged gate; change the out-of-ammo path from
  equipping a melee weapon to a fixed-reach fallback; not string ammo types,
  dynamic casts, or immediate consumption.

### Checklist

- [ ] Catalog: ammo kind and class, required-ammo on weapons, strict
      validation, fingerprint; `items.json` version bump with a coin-pile
      icon, arrows, and a short bow; archer inventory content.
- [ ] Ammo lookup and one-sided consume batch with unit tests.
- [ ] Ammo rule in the AI emitter (fallback reach) and in combat resolve
      (spawn and consume together, melee fallback); contract edits.
- [ ] Coin-pile world items, pickup branch, and pickup-event field.
- [ ] Persistent drop queue growing at the seam, with checksum and save
      sections and relative bumps.
- [ ] Carried-drop push and FIFO spawn phases in the inventory controller
      under the fixed spawn budget; structural share covered by 57's
      world-item term.
- [ ] Tests: full drop order; burst drains in FIFO order within the bound
      of the budget; a lethal hit always kills whatever the queue length;
      late same-step pickups are dropped too; coin pile credit, single
      winner; downed player drops nothing; ammo count, fallback, refused
      spawn keeps the arrow; composite checksums at 0 and N workers;
      FIFO hash independent of ring layout.
- [ ] `FailingAllocator` proofs: inventory phases after reserve; queue
      growth at the seam; composite pipeline.
- [ ] Bench `death-drop` (victims per step at three sizes).
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      `docs/development-workflow.md` (ammo authoring, `items.json` version).
- [ ] Slice 68A soak row (`pending drops (peak)`).

### Acceptance checks

- [ ] Loader rejects ammo on a non-ammo kind, a missing ammo block,
      required ammo off the weapon slot, an unknown class, and a missing
      coin-pile icon; reordered entries keep ids and fingerprint.
- [ ] Every carried stack, equipped item, and coin balance of a destroyed
      victim spawns as world items; no code path discards one, no kill is
      refused, and over-budget drops defer.
- [ ] Composite 0-vs-N worker checksum parity and the FIFO hash test pass.
- [ ] `FailingAllocator` proofs and event payload purity hold.
- [ ] `death-drop` cost is linear in victims; `inventory-update` shows no
      regression.
- [ ] `zig build verify` passes.
