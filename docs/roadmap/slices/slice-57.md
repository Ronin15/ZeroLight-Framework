## Slice 57: Items, Inventory, And Equipment

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56](slice-56.md), [Slice 49](slice-49.md), [Slice 59](slice-59.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 56 (health, combat stats, kill events), 49
(seed domains), and 59 (sky exposure for outdoor decay). The player UI is
57B; 61 and 63 consume the transfer substrate; 68C drops carried contents.

Goal: data-authored items with stable IDs, per-entity inventories, equipment
that modifies combat, currency, consumable use, loot drops, and world items
that can be picked up, plus the one inventory-transfer substrate (grants,
trades, gifts) every later producer uses. Items at rest in the world are
dormant: they cost nothing per step, persist wherever they lie, and decay
slowly only outdoors (`.claude/rules/engine-design.md` § Target scale). All of
it is deterministic and allocation-free after reserve.

### Current foundation

- Strict JSON-to-table authoring precedent: `ai_archetypes.zig` and the
  tileset and sprite metadata loaders.
- `assets/sprites/grim_items.json` holds item icons (weapons, armor, potions,
  coins, keys, gems, tools); `RuntimeAssets.spriteAtlasMeta(.grim_items)` and
  `SpriteAtlasMeta.spriteByName` resolve them; `AssetReference { sprite,
  atlas_entry_id }` (`data_system/types.zig`) carries them in sim data.
- `ActionKind.use` exists in `simulation.zig` with no consumer.
- The collision-trigger stream (`systems/collision_response.zig`) emits one
  pair per contact, so several holders touching one world item yield several
  pairs in a step.
- Slice 56 (not landed) provides `action_claims`, kill events under fixed
  per-step budgets (no kill is refused; over-budget work defers), and the
  `stepAfter` / `stepReached` helpers.

### Architecture notes

- Owner direction: dormant is for inert things only; items at rest still
  change slowly (outdoor decay). Nothing about an item at rest depends on
  distance from the observer.
- Item and loot-table identity is the authored numeric key, never load order;
  names resolve once at load (`.claude/rules/assets-audio.md`). Catalog and
  loot-table fingerprints feed Slice 46's content fingerprint.
- Three appended components (inventory, equipment, world item) follow the
  component-store pattern (`.claude/rules/simulation.md` § Persistent data).
  Inventory slot storage grows at the structural-commit seam; only the index
  width is a fixed ceiling (`.claude/rules/budgets-capacities.md`).
- The checksum hashes logical inventory contents, never allocation layout, so
  saves made after slot reuse load to the same checksum.
- World items are created by every producer (loot, 57B drops, 58 dig yields,
  68C death drops) through one template helper; no world-item create is ever
  refused for capacity. Only per-step create, pickup, and decay counts are
  fixed budgets; overflow defers deterministically.
- A dormant item costs nothing per step: pickup and decay work follow
  holders and due decays, never the count of items at rest. 57 owns decay
  scheduling: lazy, computed from elapsed steps, keyed by whether the item
  lies outdoors (sky exposure from 59/38); indoors and underground items
  persist.
- Pickup is single-winner in canonical order: no duplication when several
  holders touch one item.
- The transfer substrate (one-sided grants, two-sided trades with coins) is
  all-or-nothing, with pure preflight queries over committed plus queued
  state; it lands here with tests, and Slice 61 wires its first producer and
  pipeline resource (no dead resource tags ship).
- One new pipeline stage for inventory work, placed by its real reads
  (`.claude/rules/simulation.md` § Pipeline); equipment changes take effect
  next step.
- Persistent: inventories, equipment, and world items are hashed and saved in
  the same change (Slices 49 / 46); unknown item keys reject a load.
- VoidLight: port item stats and auto-equip-on-pickup; do not port runtime
  handle IDs, per-entity overflow heaps, radius-scan pickup, or currency as
  slot items.

### Checklist

- [ ] Item catalog and loot tables: strict loaders, key-stable IDs, icon
      resolution, fingerprints; `assets/items/*.json` installed.
- [ ] Inventory, equipment, and world-item components with full store
      wiring; slot storage growing at the structural-commit seam.
- [ ] Logical-content checksum and Slice 49 / 46 classification and save
      sections, in the same change.
- [ ] Archetype `inventory` authoring; demo loot and player kit.
- [ ] Inventory stage with use, pickup (single winner), loot (one roll per
      kill on `seed.derive(.loot)`), and decay phases under fixed per-step
      budgets with deterministic deferral.
- [ ] Dormant world items: no per-step work at rest; outdoor decay
      scheduled lazily from elapsed steps; pickup cost follows holders.
- [ ] Transfer substrate: batches, preflight queries, all-or-nothing apply.
- [ ] Equipment modifiers in action selection and combat.
- [ ] Events, stats, structural share, and audio for pickups.
- [ ] `use_item` player action with its replay bit (Table T1).
- [ ] (added by Slice 64) The use-item latch is hashed (64B) and saved in
      Slice 46's `pipeline_history`.
- [ ] (added by Slice 67) Event-log arm for pickups (67B); strings as
      `StringId`s if this lands after 67E.
- [ ] Docs: `docs/architecture.md` (inventory ownership, transfer substrate,
      dormant items, persistence boundary),
      `docs/simulation-tiers-and-pipeline.md` (stage, events),
      `docs/development-workflow.md` (item authoring).

### Acceptance checks

- [ ] Loaders reject malformed content; reordering entries changes no ID or
      fingerprint.
- [ ] Stacking, partial pickup, currency, auto-equip, swap-on-use, and
      no-revive heal behave as authored.
- [ ] Two holders on one item in one step: exactly one grant; total granted
      equals the item's count.
- [ ] Transfers: an underfunded trade applies nothing; queries see queued
      deltas.
- [ ] Loot is deterministic per seed, victim, and step; at most one roll per
      kill.
- [ ] A burst of world-item creates beyond the per-step budget defers in
      order and every item is eventually created; no create is refused.
- [ ] Items at rest: per-step cost is flat as the resting-item count grows;
      an outdoor item decays on schedule, an underground item never does.
- [ ] Equal inventories hash equal regardless of slot layout; kill → loot →
      pickup is identical with 0 and N workers.
- [ ] `FailingAllocator` proofs for store appends, slot growth and reuse,
      the stage, and transfer apply.
- [ ] Benches: `inventory-update` and `world-items-at-rest` (resting-item
      count across three sizes, flat per step).
- [ ] (added by Slices 68A–68C) The 68A re-baseline procedure is run and this
      slice's rows recorded.
- [ ] `zig build verify` passes.
