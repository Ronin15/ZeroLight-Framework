## Slice 68C: Carried-Inventory Death Drop And Ranged Ammo

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56B](slice-56b.md), [Slice 57](slice-57.md), [Slice 61](slice-61.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Hard dependencies:
- **Slice 57**: inventory, equipment, world items, `worldItemTemplate`, the
  Loot phase, and the `TransferBatch` / `canRemove` substrate.
- **Slice 56B**: ranged spawn and refusal semantics.
- **Slice 61**: lands the `inventory_transfers` resource, the `StepState`
  queue, and the phase 0 drain that this slice's ammo consumption appends to.
- **Slice 56** (through 56B): `combat_resolve`'s pure phase 1 / preflight /
  mutating phase 2 split, which the drop-admission phase 1b slots into.

It reads 57B's toast for coin piles if 57B has landed. The toast is only a
consumer of the extended `ItemPickedUpEvent`; nothing here depends on 57B.

Goal: a destroyed victim drops everything it carried, as world items. That is
every equipped item, every non-empty slot stack, and its coins as one coin
pile. A fixed per-step create budget and a fixed persistent FIFO absorb
bursts, with deterministic kill deferral when the FIFO cannot admit a victim
(nothing is ever lost). Ranged weapons that require ammo consume one matching
ammo item per projectile through the one inventory transfer substrate. An
attacker without ammo falls back to melee at a fixed reach.

Out of scope:
- **Decided non-goals of the framework item model:** arrow recovery from spent
  projectiles, ammo crafting, and corpse containers. A spent projectile is
  consumed at spawn and never becomes an item; drops are world items, never a
  container entity.
- Multiple ammo classes beyond `arrow`. The enum is append-only; a class is
  appended with its first weapon.
- Player death drops: the player has `destroy_on_death = false` (Slice 56).

### Current foundation (do not rebuild)

- **Slice 57 Loot (phase 3 of `inventory_update`):**
  - One loot-table roll per `entity_killed` creates one world item at the
    victim center.
  - `world_item_creates_per_step_max = combat_max_kills_per_step` (+1 from
    58, +1 from 57B), with
    `world_items.len + world_item_creates_per_step_max < world_item_live_capacity (1024)`
    gating creates.
  - The victim's carried slots are not dropped. That is Slice 57's documented
    gap, which this slice closes.
  - The victim is still alive during `inventory_update`; its destroy commits
    afterward.
- **Slice 57 world items and catalog:**
  - `WorldItem { item, count: u16, despawn_step }`, where `count == 0` means
    "taken; destroy queued".
  - Pickup is single-winner. Currency credits `coins += count * value`
    (saturating at `max_coins`).
  - `ItemKind { weapon, armor, consumable, currency, material, key, quest, tool }`.
  - `ItemDefRow` and the strict `items.json` loader. `fingerprint()` folds
    `(key, kind, max_stack, equip_slot)`.
  - `ItemPickedUpEvent { holder, item, count }`.
- **Slice 57 transfers:**
  - `TransferBatch` (`grant`), `InventoryTransferQueue.tryAppend`,
    `canRemove(view, pending, entity, item, count)`, and all-or-nothing
    `applyTransferBatch`.
  - Phase 0 drains the queue before Use, Pickup, and Loot. Slice 61 wires the
    resource: `action_react` writes it and `inventory_update` reads it.
- **Slice 56B:**
  - `CombatStats.attack_mode`; phase 1 treats an accepted ranged `.attack` as
    a spawn request.
  - Refusal at the live or spawn cap keeps the cooldown (`projectiles_refused`).
  - The `archer` archetype sits outside the 8-slot demo cycle, with
    `demo_archer_count = 4`.
  - 56B's text defers ammo consumption ("Ammo consumption waits for 57").
- **Atlas:** `assets/sprites/grim_items.json` contains `bow`, `arrows`, and
  `gold_coins`.

### Architecture notes

#### 1. Ranged ammo

**Catalog** (`src/game/item_catalog.zig`).
- Append `ItemKind.ammo`.
- New `AmmoClass = enum(u8) { arrow }`. Only `arrow` has a consumer; append
  more classes with their first weapon.
- `ItemDefRow` gains `ammo_class: ?AmmoClass` (kind `ammo` only) and
  `requires_ammo: ?AmmoClass` (weapon-slot equippables only).
- JSON:
  - An ammo item has `"ammo": { "class": "arrow" }`. It is required iff
    `kind == "ammo"`, and forbidden with `equip` or `consume`.
  - A weapon may set `"requires_ammo": "arrow"` inside `equip`, only when
    `slot == "weapon"`.
  - Unknown class strings fail.
- `fingerprint()` also folds `ammo_class` and `requires_ammo`.
- `ItemCatalog.weaponAmmo(slots: [equip_slot_count]ItemId) ?AmmoClass`
  returns the weapon slot's `requires_ammo`, in O(1).

**Content** (`assets/items/items.json`):
- `{ "key": 100, "id": "arrows", "name": "Arrows", "kind": "ammo", "icon": "arrows", "max_stack": 99, "value": 1, "ammo": { "class": "arrow" } }`
- `{ "key": 2, "id": "short_bow", "name": "Short Bow", "kind": "weapon", "icon": "bow", "max_stack": 1, "value": 25, "equip": { "slot": "weapon", "requires_ammo": "arrow" } }`
- Demo `archer` archetype:
  `"inventory": { "size": 8, "auto_pickup": false, "items": [ { "item": "short_bow", "count": 1, "equip": true }, { "item": "arrows", "count": 24 } ] }`.

**Query** (`src/game/inventory_transfer.zig`, pure):
`findAmmo(view, pending, entity, class) ?ItemId`.
- Scans the entity's run in slot order for the first item whose
  `ammo_class == class` and for which `canRemove(view, pending, entity, item, 1)`
  holds.
- Its cost is bounded by `class_size (≤ 64) × inventory_transfer_capacity (128)`.
  It runs only for accepted ranged attacks (≤ `projectile_spawns_per_step`)
  and in AI qualification for ranged rows.
- `TransferBatch.consume(entity, item, count)` is new: a one-sided negative
  `ItemDelta`, the mirror of `grant`. It is an **amendment to Slice 57's
  `inventory_transfer.zig`** (57 stays the owner): it is added beside `grant`
  in 57's module, and the overview shared-contracts row for 57 lists
  "`consume` (68C)".

**Rule.** Applies when `attack_mode == .ranged` and
`weaponAmmo(equipment) != null`. Attackers without equipment, or whose weapon
has no `requires_ammo`, keep Slice 56B behavior unchanged.

- `ai_action_select` `.attack` arm (threaded pass 1, read-only):
  - `has_ammo = findAmmo(view, &empty_pending, actor, class) != null`. The
    queue is empty at this stage because no producer has run yet.
  - Reach is `attack_range + range_bonus` when `has_ammo`, otherwise
    `ammo_melee_fallback_range`.
- `combat_resolve` phase 1, for an accepted ranged attack with an ammo
  requirement:
  - `ammo = findAmmo(view, &step.inventory_transfers, attacker, class)`.
  - If found: a spawn request carrying `ammo`.
  - Otherwise, **melee fallback**:
    - resolve it as a melee hit, with the explicit-target reach rechecked at
      `ammo_melee_fallback_range`;
    - the arc is `melee_cos_half_arc`, with no projectile;
    - out of reach counts `combat_attacks_rejected`;
    - an accepted fallback counts `ranged_melee_fallbacks`.
- `combat_resolve` phase 2, per spawn in phase-1 order:
  - `if (!step.inventory_transfers.tryAppend(TransferBatch.consume(attacker, ammo, 1)))`,
    refuse the spawn exactly like 56B's cap refusal: no create, cooldown
    untouched. Count `ammo_consume_refused`.
  - Otherwise queue the projectile `create_entity`, consume the cooldown, and
    count `ammo_consumed`.
  - Spawn and consume are both-or-neither.
- `inventory_update` phase 0 applies the consume batch.
  - Success is guaranteed: `canRemove` saw committed state plus every batch
    queued before `combat_resolve` (only `action_react` producers precede
    it), and nothing appends between `combat_resolve` and phase 0.
  - Phase 0 `std.debug.assert`s success, and still counts
    `transfers_rejected` in every mode.

**Constant:** `ammo_melee_fallback_range: f32 = 36` px, equal to the player's
melee reach. Comptime-assert it is `≤ max_combat_attack_range`.

**Stage graph:** `combat_resolve` gains `reads += {inventory_transfers}` (the
pending scan), `writes += {inventory_transfers}`, and
`carried += {inventory_state}`. The carried entry covers both `findAmmo`'s
committed inventory view and the death-drop admission's read of
`pending_drops` and the victim's inventory size class (§2); all of them are
previous-step values, and `inventory_update` (stage 24) is the later writer,
which satisfies the carried rule. `action_react` writes `inventory_transfers`
earlier, and `inventory_update` reads it later, so the comptime order holds.
`ai_action_select` already carries `inventory_state` (Slice 57).

#### 2. Carried-inventory death drop

**Persistent FIFO** (`src/game/data_system/pending_drops.zig`, field
`DataSystem.pending_drops: PendingDropQueue`).

- Fixed inline SoA arrays, each `[pending_drop_capacity]`:
  `item: ItemId`, `count: u16`, `coins: u32`, `x: f32`, `y: f32`,
  `level: u16`. Plus `head: u16` and `len: u16`.
- It is a **named exception** to the MAL default (fixed-capacity ring buffer,
  not row-per-entity). It never allocates.
- API:
  - `tryPush(entry) bool` refuses when `len == pending_drop_capacity`.
  - `peekFront() ?PendingDrop` and `popFront()`.
  - `logicalLen()`.
- **Owner:** its only writer is `inventory_update`, under the existing
  `inventory_state` tag (no new resource). `combat_resolve` reads
  `logicalLen()` as carried state for admission (below) and never writes it.
- **Checksum:** `hashSimulationState` hashes `len`, then entries in FIFO order
  from `head`. `head` goes into `checksum_excluded_fields` as "ring layout,
  rebuilt on load".
- **Save:** Slice 46 gains a `pending_drops` section that writes entries in
  FIFO order; load restores `head = 0`.

**World-item coin piles** (Slice 57 `WorldItem` extension).
- `WorldItem` gains `coins: u32 = 0`.
- A coin pile is `item = .none, count = 1, coins in 1..=max_coins`. An item
  row has `coins == 0`.
- `validateWorldItem` enforces both shapes at create. `count == 0` remains
  runtime-only.
- Pickup, for a coin pile:
  - `holder.coins = min(max_coins, coins + pile.coins)` in `u64`, then
    `count = 0` and queue the destroy;
  - single-winner, counted as one take within `pickup_budget_per_step`;
  - coins never need a free slot.
- `ItemPickedUpEvent` gains `coins: u32 = 0`. The payload is still scalar, so
  the purity test passes.
- Coin pile icon:
  - `items.json` becomes `"version": 2` with a required top-level
    `"coin_pile_icon": "gold_coins"`.
  - It resolves at load to `ItemCatalog.coin_pile_icon: AssetReference` and
    must exist in `grim_items`.
  - The loader accepts only version 2.
- `worldItemTemplate` gains a sibling
  `coinPileTemplate(icon, coins, position, level, step) EntityTemplate`.

**Why admission happens in `combat_resolve`, before the kill.** A victim is
destroyed at step s's structural commit (Slice 56 phase 2 queues
`destroy_entity`), so its contents cannot be retried after the fact. Any
deferral must therefore happen before the kill is decided. Two designs were
weighed:
- **Chosen: admission gate plus kill deferral** (the cross-slice consistency
  review's design, which is also the per-slice review's "minimum acceptable
  alternative"). It is sound because `pending_drops` has exactly one writer
  (`inventory_update`, stage 24), which runs after `combat_resolve` (stage 23)
  in the same step. So the length `combat_resolve` reads is exactly the length
  phase 4 pushes onto, and an admitted victim's entries always fit. It adds no
  entity kind, no structural command, and no new persistent state.
- **Rejected: "drop source" entities** (the per-slice review's primary
  proposal: a non-fitting victim's contents move into a new inventory-only
  entity created in the victim's place, drained later). It needs a new entity
  shape with no movement/AI/render, a content move inside the structural
  commit (where inventory is not otherwise written), extra structural reserve
  per kill, and a second drain source in phase 5. It keeps the kill on time,
  but nothing in the framework needs a kill to land on a particular step, and
  the extra moving parts are new failure modes on a path that must never lose
  items.

**Drop admission (`combat_resolve` phase 1b, serial, in Slice 56's per-target
order).** It runs after phase 1 has accumulated every target's summed damage
(so lethality is known) and before the preflight, so a deferral leaves no
partial mutation.
- Applies to a target whose summed damage this step is lethal
  (`sum >= hit_points`), that has `destroy_on_death`, and that carries
  `inventory` or `equipment` (coins live in `Inventory`, Slice 57).
- `dropEntryBound(target) = equip_slot_count + slotCount(inventory.size_class) + 1`,
  with the inventory term 0 when the target has no `inventory`. It is a fixed
  per-victim upper bound that does not depend on this step's pending
  transfers. A grant, equip, or pickup that runs later in the same step's
  `inventory_update` (phases 0–2: transfers, Use, Pickup; all before phase 4)
  can therefore never make the real push count exceed it. The `+ 1` is the coin entry, counted even when `coins` is 0
  now, because a coin pickup in phase 2 can make it nonzero.
- Admit the target only if
  `pending_drops.logicalLen() + reserved_drop_entries + dropEntryBound(target) <= pending_drop_capacity`.
  `reserved_drop_entries` is a phase-local `u32` accumulator starting at 0.
- An admitted target adds its bound to `reserved_drop_entries` and is resolved
  exactly as in Slice 56 (damage, `entity_killed`, `destroy_entity`).
- A target that does not fit is **deferred, not killed**:
  - every hit on it this step is removed from the pending set before the
    preflight, the same way 56B's cap refusal leaves no trace: no damage, no
    `entity_damaged` / `entity_killed` events, no knockback (68B), and the
    attackers' `next_attack_step` untouched, so they retry;
  - a projectile hit on a deferred target was already resolved by
    `projectile_update` (pierce decrement or destroy, Slice 56B), so that
    projectile is spent without damage. That costs one ammo unit, never a
    carried item;
  - count `combat_kills_deferred_drop_capacity` (once per deferred target per
    step).
- **Liveness.** Phase 5 drains the FIFO at `death_drop_creates_per_step`
  whenever the world-item cap has headroom, and Slice 57 world items expire
  after `world_item_lifetime_steps` (or are picked up), so headroom returns in
  bounded steps. `pending_drop_capacity >= max_carried_drop_stacks_per_victim`
  (comptime-asserted) guarantees that any single victim fits an empty FIFO, so
  a deferral always ends.
- **Determinism.** Phase 1b walks targets in Slice 56's first-hit order, which
  is a pure function of merged intents and projectile hits, so the admitted
  set is identical for any thread count.

**Inventory controller phases.** Slice 57's phase 3 (Loot) is followed by two
new phases; Expiry becomes phase 6.
- **Phase 4, Carried drop.** For each merged `entity_killed` with
  `destroyed == true`, in event order (at most `combat_max_kills_per_step`),
  whose victim carries `inventory` or `equipment`:
  - Push into the FIFO, in this fixed order:
    1. each non-`.none` equipment slot in `EquipSlot` declaration order
       (count 1);
    2. each non-empty inventory slot in slot order;
    3. one coin entry when `coins > 0`.
  - Every entry uses the victim center and level (`movement_positions` and
    `world_level` reads, which 57 already declares).
  - Every push fits by construction (admission reserved the victim's bound).
    Each push is `const pushed = tryPush(entry); std.debug.assert(pushed);`,
    and a `false` (impossible unless admission and phase 4 disagree) also
    counts `death_drop_push_refused` in every build mode. That counter must
    stay 0; it is a release-build canary reported in the soak.
  - The Slice 57 loot-table roll for the same victim already ran in phase 3
    and is unaffected.
- **Phase 5, Drop spawn.** While the FIFO is non-empty and
  `spawned < death_drop_creates_per_step`:
  - Stop for this step, without popping, when the Slice 57 live-cap rule
    refuses a create (`world_items.len + world_item_creates_per_step_max >= world_item_live_capacity`).
    That is deferral, not loss.
  - Otherwise pop the front and queue `create_entity(worldItemTemplate(...))`
    or `coinPileTemplate(...)` with
    `despawn_step = stepAfter(step, world_item_lifetime_steps)`.
    `items.row(item).icon` gives the icon.
  - Count `death_drops_spawned`.
  - Entries a victim pushed this step can spawn this same step. Burst
    overflow waits in FIFO order.

**Constants** (`inventory_controller.zig`, comptime-asserted):

| Constant | Value | Reason |
| --- | --- | --- |
| `max_carried_drop_stacks_per_victim` | `64 + equip_slot_count + 1` (72) | Largest class plus 7 equip slots plus one coin entry |
| `pending_drop_capacity` | `death_drop_creates_per_step × 16` (512) | Backlog budget, not a content capacity: 16 drain steps (0.27 s) of `death_drop_creates_per_step`, whatever the world or population; sustained overload defers kills (phase 1b) and never grows the FIFO. Assert `>= max_carried_drop_stacks_per_victim`, so one full victim always fits an empty FIFO (also 7 full `slots_64` carriers in one step). Admission keeps `len ≤ capacity` without ever discarding an entry. |
| `death_drop_creates_per_step` | 32 | Drains a full FIFO in 16 steps (0.27 s) when the world has headroom |
| `world_item_creates_per_step_max` | `combat_max_kills_per_step + 1 (58) + 1 (57B) + death_drop_creates_per_step` | Assert `< world_item_live_capacity`. 162 with 56B. |
| Structural share | No new term | Phase 5 runs in `inventory_update`, a pipeline stage, so its creates are pipeline-owned. `death_drop_creates_per_step` is already a term of `world_item_creates_per_step_max`, which sizes Slice 57's `world_item_structural_event_share` (a term of `pipeline_structural_event_share`). Adding it again would double-count; callers add nothing |

Phase 1b and phases 4 and 5 are serial and bounded:
- Phase 1b: at most `combat_max_hits_per_step` (128) pending targets, O(1)
  each (one slot resolve for the inventory size class).
- Phase 4: kills × 72 enumerations, at most 9216 cheap reads per step.
- Phase 5: at most 32 creates.

The FIFO lives in `DataSystem`, so nothing is pending outside persistent state
at a step boundary.

**Diagnostics.**
- Counters `ammo_consumed`, `ammo_consume_refused`, `ranged_melee_fallbacks`,
  `death_drops_spawned`, `combat_kills_deferred_drop_capacity` (a pipeline
  combat stat beside Slice 56's `combat_kills`, recorded through
  `runtime_perf_log`), and `death_drop_push_refused` (must stay 0).
- `pending_drops_peak` via `recordMetricMax`.
- One `logging.game` debug line at init with the drop constants. No per-step
  logging.

**Persistence.** The new `pending_drops` field, `WorldItem.coins`, and the
`ItemDefRow` fields feed the catalog fingerprint. Slice 49 / 64B
classification (`pending_drops` entries hashed in FIFO order, `head`
excluded) and a `checksum_format_tag` bump (live value + 1); Slice 46
`pending_drops` section (FIFO order, `head = 0` on load, appended after the
other `DataSystem` store sections), `WorldItem` field, a save `format_version`
bump (live value + 1; v17 in the merged order, Table T3), and the content fingerprint
changing through `ItemCatalog.fingerprint()`. Kill deferral adds no state:
`reserved_drop_entries` is phase-local.

### Checklist

- [ ] Catalog: `ItemKind.ammo`, `AmmoClass`, the `ammo_class` /
      `requires_ammo` columns, strict validation, the fingerprint fold, and
      `weaponAmmo`. `items.json` v2 with `coin_pile_icon`, `arrows`, and
      `short_bow`. Archer inventory content.
- [ ] `findAmmo` and `TransferBatch.consume`, with unit tests:
      - slot-order choice;
      - a pending removal hides the last arrow;
      - no matching class returns null.
- [ ] Ammo rule in `ai_action_select` (fallback reach) and `combat_resolve`
      (spawn plus consume both-or-neither, melee fallback). Contract
      `combat_resolve` `reads/writes += inventory_transfers`,
      `carried += inventory_state`, and its contract test. Counters.
- [ ] Drop admission, `combat_resolve` phase 1b: `dropEntryBound`, the
      phase-local `reserved_drop_entries`, kill deferral that strips every
      hit on a non-admitted target before the preflight, and the
      `combat_kills_deferred_drop_capacity` stat. Amend Slice 56's phase list
      in the roadmap text (phase 1 → **1b** → preflight → phase 2).
- [ ] `WorldItem.coins`, `validateWorldItem`, `coinPileTemplate`, the
      coin-pile pickup branch, and `ItemPickedUpEvent.coins`.
- [ ] `PendingDropQueue` (`data_system/pending_drops.zig`) with its logical
      checksum hash, its Slice 46 section, and the `checksum_format_tag` and
      save `format_version` bumps.
- [ ] Phases 4 and 5 in `InventoryController` (phase 4 asserts every push and
      counts `death_drop_push_refused`). Constants and comptime asserts.
      `pending_drops_peak`. No separate structural term: phase 5's creates grow Slice 57's
      pipeline-owned `world_item_structural_event_share` through
      `world_item_creates_per_step_max`. `demo_structural_headroom` is
      unchanged (callers add nothing), and the demo `capacity_limit` literal is
      re-pinned. Test: extend Slice 57's world-item structural-share test in
      `simulation_pipeline.zig` (`structural_headroom = 0`,
      `world_item_creates_per_step_max` creates plus the pickup and expiry
      destroys) so its `death_drop_creates_per_step` share of the creates uses
      `coinPileTemplate`. The full set commits through
      `applyStructuralCommandsBudgeted(&data, pipeline.structuralCommitBudget(0))`
      and lands every create and destroy.
- [ ] Tests:
      - **Full drop:** a `slots_8` victim with 3 stacks, 1 equipped sword,
        and 57 coins drops exactly 5 world items (sword, 3 stacks, coin pile)
        at its center in the fixed order, after the loot roll's item.
      - **Burst deferral:** 3 `slots_64` full victims (216 entries) in one
        step spawn 32 per step in FIFO order, and all spawn within 7 steps.
      - **Admission deferral:** with the FIFO pre-filled to 500, a lethal hit
        on a `slots_64` carrier (bound 72) is refused. The target is alive
        with unchanged `hit_points`, no `entity_damaged` / `entity_killed`
        event is published, the attacker's `next_attack_step` is untouched,
        and `combat_kills_deferred_drop_capacity == 1`. Once phase 5 has
        drained the FIFO to at most 440 entries, the same attack kills, and
        every non-empty carried stack, equipped item, and the coin entry
        spawn in the fixed order. Total dropped stacks equal carried stacks,
        and `death_drop_push_refused == 0`.
      - **Admission is victim-atomic:** two lethal carriers in one step where
        only the first (in first-hit order) fits: the first dies and drops
        everything; the second is deferred whole. Nothing is split.
      - **Late pickup stays inside the bound:** a victim with `coins == 0` and
        one free slot is admitted; in the same step's Pickup phase it gains a
        coin pile and an item; phase 4 pushes both plus its earlier stacks
        without a refusal.
      - **Deferred projectile hit:** an arrow that hits a deferred target is
        spent (56B pierce/destroy), deals no damage, and the target's
        inventory is unchanged.
      - **Live-cap deferral:** at world-item headroom 0 nothing pops. After
        expiry frees room, spawning resumes in order.
      - **Coin pile:** credits exactly, saturates at `max_coins`, needs no
        free slot, and two holders on one pile get a single winner.
      - **Player downed:** a `destroyed == false` kill drops nothing.
      - **Ammo:** 24 arrows give 24 projectiles, then melee fallback. A
        refused spawn keeps the arrow and the cooldown. A full transfer queue
        refuses both spawn and consume.
      - **Composite determinism:** a 120-step archer-vs-raider `pipeline.update`
        run with deaths gives identical inventory, world-item, and
        pending-drop checksums for 0 workers and N workers.
      - **FIFO hash:** two queues with equal logical contents and different
        `head` hash equal.
- [ ] FailingAllocator proofs:
      - `InventoryController.process` covering phases 4–5, coin-pile pickup,
        and ammo consume batches after frame reserve.
      - `CombatController` phase 1b on the deferral path (FIFO pre-filled, one
        target deferred, one admitted) after reserve: zero allocations, and
        the admitted kill's structural `destroy_entity` and events still land
        (the reserved-then-commit success branch).
      - `PendingDropQueue` ops (no allocator at all; proven by signature).
      - The composite proof (Slice 57's proof 6) extended with one carried
        drop and one ammo consume.
- [ ] Bench: add `zig build bench -- --group death-drop`
      (`src/benchmarks/inventory.zig`, beside 57's groups;
      `defaultItemCounts` = victims per step `{16, 64, 128}`, every victim a
      full `slots_64` carrier plus 7 equipped plus coins). Each iteration is
      phases 4 and 5 for one step, plus a FIFO reset. Internal asserts:
      creates ≤ `death_drop_creates_per_step` and FIFO length ≤ capacity.
- [ ] Docs:
      - `docs/architecture.md`: the death-drop FIFO and coin piles.
      - `docs/simulation-tiers-and-pipeline.md`: the ammo consume path through
        transfers and the new inventory phases.
      - `docs/development-workflow.md`: ammo and `requires_ammo` item
        authoring, and `items.json` v2.
- [ ] Re-baseline the control table by Slice 68A §3 (`pending drops (peak)`
      row).

### Acceptance checks

- [ ] Loader rejects:
      - `ammo` on a non-ammo kind;
      - a missing `ammo` block on an ammo kind;
      - `requires_ammo` off the weapon slot;
      - an unknown class;
      - a missing `coin_pile_icon`.
      The installed v2 files load, and reordering entries leaves IDs and the
      fingerprint unchanged.
- [ ] The drop, burst, admission-deferral, victim-atomic, late-pickup,
      deferred-projectile, live-cap, coin-pile, downed-player, and ammo tests
      pass. No code path discards a carried stack: grep in the PR finds no
      `death_drop_stacks_lost` and no unchecked `tryPush`.
- [ ] Composite 0-vs-N worker checksum parity passes. The FIFO logical-hash
      test passes.
- [ ] FailingAllocator proofs pass. Comptime payload-purity holds for the
      extended `ItemPickedUpEvent`.
- [ ] Bench, ReleaseFast:
      - `zig build -Doptimize=ReleaseFast bench -- --group death-drop --case serial-direct`
        is run and its actuals recorded in Status (reference estimate for
        128 victims: under 0.2 ms).
      - `zig build -Doptimize=ReleaseFast bench -- --group inventory-update`
        stays within noise of a same-session pre-change capture.
- [ ] Battle soak per 68A §3: the `pending drops (peak)` and
      `kills deferred (drop capacity)` rows are recorded, and
      `death_drop_push_refused` is 0.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Ported.**
  - `EntityDataManager::consumeRequiredAmmoForRangedAttack` /
    `findCompatibleAmmo` (`src/managers/EntityDataManager.cpp:2550-2630`): a
    weapon's required ammo type is matched by the first compatible inventory
    stack, and one unit is consumed per shot. This becomes `requires_ammo` /
    `AmmoClass`, `findAmmo` in slot order, and `TransferBatch.consume`.
  - `hasRequiredAmmoForRangedAttack` (`src/ai/behaviors/AttackBehavior.cpp:255-305`)
    gating the AI's ranged shot. This becomes the reach switch in
    `ai_action_select`.
- **Changed.** VoidLight's out-of-ammo path equips a melee weapon from the
  inventory (`CombatController.cpp:169-178`,
  `AICommandBus::enqueueMeleeFallbackEquip`). ZeroLight keeps equipment
  unchanged and resolves a fixed-reach melee fallback. That avoids an
  equipment mutation outside `inventory_update`.
- **Not ported.**
  - String ammo types and `dynamic_pointer_cast<Ammunition>` lookups.
  - Ammo consumption inside the combat controller's mutation path, which was
    immediate and not batched.
  - UI event-log strings ("No ammunition!").

