## Slice 57: Items, Inventory, And Equipment

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56](slice-56.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 56 (health for heal effects,
`CombatStats` for equipment modifiers, `entity_killed` and
`combat_max_kills_per_step` for loot), Slice 49 (`seed.derive(.loot)`) and
Slice 33 (landed; archetype bundles). It adds its own Slice 46 save sections
(stable-ID persistence boundary below). The player-facing UI is Slice 57B, which
needs Slice 53B. Slices 61 and 63 consume this slice's inventory-transfer
substrate (`TransferBatch`, `canAccept`, `canRemove`, `canRemoveCoins`).

Goal: data-authored items with stable IDs, per-entity inventories, equipment
that modifies combat, world items that can be picked up, loot drops, currency,
consumable use, and the **one** inventory-transfer substrate (grants, trades,
gifts) every later producer uses. All of it goes through `DataSystem` plus one
pipeline stage, is deterministic, is allocation-free after reserve, and has
fixed per-step budgets.

### Current foundation (do not rebuild)

- Strict JSON-to-table authoring: `ai_archetypes.zig:155-244` and the tileset
  and sprite metadata loaders.
- `RuntimeAssets.spriteAtlasMeta(.grim_items)` and
  `SpriteAtlasMeta.spriteByName` (`src/assets/runtime_assets.zig:135`,
  `src/assets/sprite_atlas_meta.zig:131`). `assets/sprites/grim_items.json`
  already holds 48 item icons: weapons, armor, potions, coins, keys, gems,
  tools.
- `AssetReference { sprite, atlas_entry_id }` (`data_system/types.zig:245-254`).
  World items render through the existing movement-body render collect using
  stable IDs.
- `.use` action kind (`simulation.zig:478-497`). From Slice 56: `action_claims`,
  `combat_events` (`entity_killed`), `combat_state`,
  `combat_max_kills_per_step`, the `stepAfter` / `stepReached` helpers, and
  the `CombatController` / `AiActionSelectSystem` stat reads.
- The collision-trigger stream (`systems/collision_response.zig:113-131`) for
  overlap pickup. It appends **one pair per contact**, so N holders
  overlapping one world item produce N pairs in the same step.
- Demo collision capacity (`game_demo_state.zig:127-135,431,442-443`).
- The component/store/template/capacity pattern listed under Slice 56.

### Architecture notes

**Stable item identity.**

- `ItemId = enum(u16) { none = 0xFFFF, _ }` is a leaf type in
  `data_system/types.zig`. Its value is the **authored numeric `key`** in JSON,
  not the load order, so renaming or reordering entries never changes saved
  IDs.
- `LootTableId` follows the same rule.
- Runtime lookup is `ItemCatalog.row(id)` through a fixed
  `key_to_row: [max_item_key + 1]u16` table: O(1), with no hash map and no
  strings on hot paths.
- Code that needs specific items (the player kit, currency conversion)
  resolves names once at load into typed references, the same way
  `requireTileByName` works.

**`ItemCatalog` (`src/game/item_catalog.zig`, state-owned, immutable after load).**
Content lives in `assets/items/items.json`:

```json
{ "version": 1, "items": [
  { "key": 1,  "id": "iron_sword", "name": "Iron Sword", "kind": "weapon", "icon": "sword",
    "max_stack": 1, "value": 20, "equip": { "slot": "weapon", "attack_bonus": 4, "range_bonus": 6 } },
  { "key": 20, "id": "leather_hood", "kind": "armor", "icon": "hood", "max_stack": 1, "value": 8,
    "equip": { "slot": "head", "mitigation_bonus": 0.05 } },
  { "key": 40, "id": "health_potion", "kind": "consumable", "icon": "health_potion",
    "max_stack": 20, "value": 10, "consume": { "effect": "heal", "power": 40 } },
  { "key": 60, "id": "gold_coins", "kind": "currency", "icon": "gold_coins", "max_stack": 9999, "value": 10 },
  { "key": 80, "id": "iron_ore", "kind": "material", "icon": "sapphire_gem", "max_stack": 99, "value": 2 } ] }
```

- Enums:
  - `ItemKind { weapon, armor, consumable, currency, material, key, quest, tool }`
  - `EquipSlot { weapon, offhand, head, chest, hands, feet, accessory }` (7)
  - `ConsumeEffect { heal }`. Only effects with a consumer exist; there is no
    mana or stamina tag because no such stat exists.
- Storage: `std.MultiArrayList(ItemDefRow)` with these columns:
  - `kind`, `max_stack: u16`, `value: u32`, `icon: AssetReference`
  - `equip_slot: ?EquipSlot`, `attack_bonus: f32`, `mitigation_bonus: f32`,
    `range_bonus: f32`, `cooldown_bonus_steps: i16`
  - `consume_effect`, `consume_power: u32`
  - name offset/len into a cold `[]u8` name arena (UI and logs only)

  Plus `key_to_row`. The catalog owns its allocator and has a `deinit`.
- Validation is strict, loud, and never partially applies:
  - Unknown keys or enum strings fail. A duplicate `key` or `id` fails.
  - `key > max_item_key (4095)` fails, as does exceeding
    `item_catalog_capacity (1024)`.
  - `max_stack` must be in `1..=9999`.
  - `value` must be in `0..=max_item_value (1_000_000)`, so `count * value`
    and Slice 63's pricing math (`base * multiplier` in `u64`) never overflow.
  - `equip` is allowed only on weapon/armor/tool kinds, and needs a `slot`.
  - A consumable needs a `consume` block. Currency needs `value >= 1`.
  - `icon` must exist in the `grim_items` atlas metadata and resolves to an
    `atlas_entry_id`.
  - Bonus ranges: `attack_bonus` `[-1000, 1000]`, `mitigation_bonus`
    `[0, 0.9]`, `range_bonus` `[0, 128]`, `cooldown_bonus_steps`
    `[-300, 300]`.
- `fingerprint() u64` is an `rng.mix64` fold over `(key, kind, max_stack,
  equip_slot)` in key order. Slice 46 folds it (plus the loot-table
  fingerprint) into its `content_fingerprint` header so a save detects content
  drift.

**Loot tables (`assets/items/loot_tables.json`, loaded in the same module).**

```json
{ "version": 1, "loot_tables": [ { "key": 1, "id": "raider", "empty_weight": 40,
  "entries": [ { "item": "gold_coins", "weight": 40, "min": 1, "max": 5 },
               { "item": "health_potion", "weight": 20, "min": 1, "max": 1 } ] } ] }
```

- Caps: `loot_table_capacity = 256` (a loud load-time ceiling; rows are
  reserved to the authored table count, never to 256) and
  `max_loot_entries = 16` (the inline per-table entry array, a format bound).
- Rules: `u16` weights greater than 0 (`empty_weight` may be 0), and
  `1 <= min <= max <= the item's max_stack`.
- `LootTableCatalog.fingerprint() u64` folds `(key, empty_weight, entries)` in
  key order, the same way as the item fingerprint.

**New components: three `Component` tags, appended** (never pinned by number).

`inventory`:

- Row fields:
  - `size_class: InventorySizeClass enum(u2) { slots_8, slots_16, slots_32, slots_64 }`
  - `slot_run_start: u32`, `used_slots: u16`
  - `auto_pickup: bool`, `loot_table: LootTableId`
  - `coins: u32`, saturating at `max_coins = 1_000_000_000`

  Stored in a `std.MultiArrayList(InventoryRow)`.
- **Slot storage decision: pooled size-class runs, not a fixed per-entity
  array.** `InventorySlotPool` (`data_system/inventory.zig`):
  - Two columns, `items: []ItemId` and `counts: []u16`, in one striped arena
    (`capacity × stride`; a documented MAL exception), plus four per-class
    free lists of run starts.
  - Each entity's slots are one contiguous run of 8, 16, 32, or 64 slots
    (`slot i → run_start + i`). Every inventory operation is a contiguous scan
    with no page table.
  - Runs are allocated only at structural commit of a `create_entity` whose
    template carries `inventory` (there is no set variant and no component-add
    path), either from the class free list or by appending at the arena tail.
    Destroy clears a run and pushes it back on its free list.
  - Pool and free-list capacity are part of `StructuralCapacityNeeds`:
    preflight reserves, and commit uses `assumeCapacity`. So slot-content
    changes in the stage never allocate.
  - **Fragmentation bound and growable arena.** Per-class free lists never
    coalesce, so under spawn churn with a shifting class mix (Slice 62
    respawns) the arena tail grows to at most Σ_class peak_live(class) ×
    class_size. The arena is a runtime-growing store, so it grows at the
    structural-commit seam instead of carrying a fixed or summed cap:
    - `DataSystem.reserveInventorySlotArena(initial)` takes a content-derived
      initial bound passed in by the state (the slot runs its load-time
      inventory-bearing creates need) and reserves both columns and the
      per-class free lists at init.
    - The arena grows geometrically at the structural-commit seam (main
      thread, in the `StructuralCapacityNeeds` preflight) when free slots fall
      below one commit's run demand. `slot_run_start` is a `u32` index, not a
      pointer, so every run survives the realloc. Commit then uses
      `assumeCapacity`, and slot-content changes in the stage never allocate.
    - Refusal happens only at the `u32` ceiling: a growth that would put the
      arena past `maxInt(u32)` slots fails the preflight with
      `error.InventorySlotArenaTooLarge` (a load fails; a runtime producer's
      batch is refused and counted in `inventory_runs_refused`). No producer
      pre-checks headroom below that ceiling, and no later slice adds a term
      to the initial bound: a new inventory-bearing source is covered by
      growth at the seam.

    Free-list capacity per class grows with the arena (to
    `arena_len / class_size`), so a push on destroy never allocates.
- Why pooled runs:
  - VoidLight's 8-inline plus heap-overflow map is a per-entity heap
    structure.
  - A uniform inline array sized for the player (40+ slots) wastes about
    160 B per NPC at battle scale and still caps the player.
  - Size classes give the player 32 or 64 slots and loot carriers 8, each in
    one contiguous run.
- Run layout is not persisted (it is rebuilt on load). Logical slot contents
  are persisted.
- **Checksum (Slice 49).** `InventoryStore` provides its own
  `hashSimulationState` that hashes **logical** contents: per row in dense
  order, every column except `slot_run_start`, then all `class_size` slots'
  (item, count) read through the run in slot order (empty slots included, so
  slot positions are part of the logical state). `slot_run_start`, the free lists, and the arena
  tail go into `checksum_excluded_fields` with the reason "allocation layout,
  rebuilt on load". Otherwise any save made after free-list reuse would fail
  Slice 46's parity on load. Test: two inventories with identical contents but
  different run offsets hash equal.

`equipment`:

- `Equipment { slots: [equip_slot_count]ItemId = @splat(.none) }`, stored as a
  MAL row with one contiguous `ItemId` column per slot.
- No cached modifier sum: `ItemCatalog.equipmentModifiers(slots)` is a pure
  O(7) computation done where it is needed. It cannot drift, and resolve sees
  at most `combat_max_hits_per_step` hits per step.

`world_item`:

- `WorldItem { item: ItemId, count: u16, despawn_step: StepIndex }`. `count == 0`
  means "fully taken this step, destroy queued"; every reader skips such rows.
- A world-item entity is `movement_body` (speed 0) + `collision_bounds` 16×16
  + `collision_response{ .trigger, .static }` + `primitive_visual`
  (`.obstacle` depth band) + `asset_reference(.grim_items, icon)` +
  `world_level` + `world_item`.
- One shared helper builds it:
  `worldItemTemplate(item, icon: AssetReference, count, position, level, step) EntityTemplate`
  in `src/game/world_item.zig`. It takes a pre-resolved icon, not the catalog:
  loot resolves it through `context.items.row(item).icon`, and Slice 58's dig
  yields store it in `TileYield` (`DigController` holds no catalog). Loot,
  57B drops, and dig yields all use it. `despawn_step` is
  `stepAfter(step, world_item_lifetime_steps)`.

Template and intent changes:

- `EntityTemplate` gains:
  - `inventory: ?InventoryTemplate`, where `InventoryTemplate` is
    `{ inventory, initial: [inventory_template_stacks = 8]ItemStack, initial_count: u8 }`
  - `equipment: ?Equipment`
  - `world_item: ?WorldItem`
- No structural set variants. Runtime inventory changes are hot writes inside
  `inventory_update`; other stages request them only through the transfer
  substrate below, never through a structural command.
- `ActionIntent` gains `item: ItemId = .none`. It is a scalar, so the
  payload-purity test still passes.

**Authoring.**

- Archetype JSON gains an optional `"inventory"` block, built into an
  `InventoryTemplate` plus `Equipment`:

  ```
  "inventory": { "size": 8|16|32|64, "auto_pickup": bool, "loot_table": "raider",
                 "items": [ { "item": "health_potion", "count": 2 },
                            { "item": "iron_sword", "count": 1, "equip": true } ] }
  ```

- `ai_archetypes.load` takes `*const ItemCatalog` and
  `*const LootTableCatalog`. Load order in `GameDemoState.initWithWorld` is
  items, then loot tables, then archetypes.
- Validation rejects: unknown names, a count above `max_stack`, `equip` on a
  non-equippable item, two items for one slot, and more than
  `inventory_template_stacks` entries.
- Demo: `aggressive` gets `loot_table = raider`, size 8, and an equipped
  `iron_sword`.
- Player kit: constants in `player.zig` naming items, resolved at load:
  `iron_sword` equipped, 2× `health_potion`, `slots_32`, `auto_pickup = true`.

**Stage `inventory_update`.** One new `StageId` and two new tags,
`inventory_state` and `item_events`. Raise `@setEvalBranchQuota` at
`simulation_pipeline.zig:287` if the comptime contract walk needs it.

- Order: `… combat_resolve → inventory_update → social_react (63) → tier_policy`
  (56B's `projectile_update` sits between `action_react` and `combat_resolve`).
- Contract: reads `{action_intents, action_claims, combat_events, collision_triggers, movement_positions, world_level}`;
  writes `{inventory_state, combat_state (heal), item_events, structural_commands}`.
  The first transfer producer adds the `inventory_transfers` read (below).
- Slice 56 contract change: `ai_action_select` and `combat_resolve` add
  `carried = inventory_state`. The later `inventory_update` writes it, so
  equipment changes take effect on the next step.

**Inventory transfers (this slice owns the only inventory-transfer substrate).**
Slices 61 (harvest grants) and 63 (trades, gifts) consume it; neither adds its
own pending-delta scratch, grant command, or capacity query.

- Types in `src/game/inventory_transfer.zig`, all scalar:
  - `ItemDelta { entity: EntityId, item: ItemId, delta: i32 }`
  - `CoinDelta { entity: EntityId, delta: i64 }`
  - `TransferBatch { items: [max_transfer_item_deltas = 4]ItemDelta,
    item_count: u8, coins: [2]CoinDelta, coin_count: u8 }`. A **grant** is a
    one-sided batch built by `TransferBatch.grant(entity, item, count)` (one
    positive `ItemDelta`); a trade or gift is a two-sided batch (goods plus
    coins).
  - `InventoryTransferQueue`: a fixed `[inventory_transfer_capacity]TransferBatch`
    plus `len`, with `inventory_transfer_capacity = 2 *
    action_intent_live_capacity` (128). It is a fixed array held in
    `StepState`, so appends never allocate. `tryAppend(batch) bool` returns
    `false` when full; the producer counts the refusal and does not latch any
    success state.
- Pure queries (no mutation, no allocation):
  - `canAccept(view, pending, entity, item, count) bool`
  - `canRemove(view, pending, entity, item, count) bool`
  - `canRemoveCoins(view, pending, entity, amount: u64) bool`: true when the
    entity's committed `coins` plus the sum of every `CoinDelta` already
    queued this step for that entity (summed in `i64`; the queue is
    fixed-capacity, so the sum cannot overflow) is `>= amount`. It is the
    currency analog of `canRemove`, used by Slice 63's buy preflight. There is
    no `canAcceptCoins`: a coin credit never fails a batch, it saturates at
    `max_coins` under the apply rule below.

  `view` is an `InventoryView` (const inventory/slot-pool slices plus
  `*const ItemCatalog` for `max_stack`). `pending` is the step's
  `*const InventoryTransferQueue`; the queries read committed slots plus every
  delta already queued this step for that entity (an O(queue) scan bounded by
  the fixed capacity). Producers preflight with them before appending a whole
  batch.
- Apply: `InventoryController.applyTransferBatch(batch) bool` revalidates every
  delta against the current hot state and applies the batch **all-or-nothing**
  (no partial goods or coins). Item adds use the same slot-merge primitive as
  Pickup (merge into existing stacks in slot order, then empty slots); removes
  take from the last matching stacks first. Coins saturate at `max_coins` and
  never go below 0 (a coin removal past the balance fails the batch). Failures
  count in `transfers_rejected`.
- **Phase 0** of `inventory_update` drains the queue in append order through
  `applyTransferBatch`, before Use/Pickup/Loot, so a granted item is usable or
  equippable the same step.
- **Pipeline wiring lands with the first producer (Slice 61).** A stage that
  reads `inventory_transfers` with no earlier writer fails the comptime
  contract check, and this slice ships no dead resource tag (the same rule
  57B follows for `drop` / `unequip`). Slice 61 therefore adds
  `PipelineResource.inventory_transfers` (written by `action_react`, read by
  `inventory_update`), the `StepState.inventory_transfers` queue instance, and
  the phase 0 call, all using this slice's types and `applyTransferBatch`
  unchanged. This slice lands the types, queries, apply function, and their
  tests; Use and Pickup already go through the shared slot primitive, so it is
  live from day one.

`InventoryController` (`src/game/inventory_controller.zig`) is pipeline-owned
and serial, and every phase is bounded by a fixed constant. After the phase 0
transfer drain (wired by Slice 61), it runs four phases in order:

1. **Use.** Handle merged `.use` intents whose `action_claims` bit is unset
   (at most 64). No current claimant (trade, harvest, destructible, combat)
   claims `.use`; honoring the bit keeps one consumer per intent if one ever
   does. This adds `action_claims` to the stage's reads.
   - `item == .none` selects the first consumable in slot order.
   - A `heal` consumable sets `hit_points = min(max, hp + power)`, only when
     `hp > 0`, and decrements the stack.
   - An equippable item swaps into its equip slot. The previous item returns
     to the vacated slot, so it always fits.
   - Emits `item_used`.
2. **Pickup.** Scan merged `collision_triggers` (bounded by collision's own
   contact capacity, not world size) for (holder with `auto_pickup`,
   `world_item`) pairs, **in trigger order**.
   - **Single-winner rule (no duplication).** Collision emits one pair per
     contact, so several holders overlapping one world item yield several
     pairs this step, and the item's destroy is deferred to commit. Pickup
     therefore hot-writes `WorldItem.count` on every take: a full take sets
     `count = 0` and queues `destroy_entity`; a partial take writes the
     remainder. Any pair whose world item has `count == 0` is skipped. The
     first holder in trigger order (the merged, deterministic contact order)
     takes what it can accept; a later holder in the same step sees only the
     remainder.
   - Accept at most `pickup_budget_per_step = 16` takes, in trigger order.
     Later overlaps re-trigger next step, which is natural deferral.
   - Currency converts to `coins += count * value`, computed in `u64` and
     saturating at `max_coins`, and never occupies a slot.
   - An equippable item auto-equips when its slot is empty. Otherwise items
     merge into existing stacks in slot order, then the first empty slots.
   - A holder that can accept nothing increments `pickups_refused`.
   - Emits `item_picked_up`.
3. **Loot.** Handle merged `entity_killed` events (at most
   `combat_max_kills_per_step` per step, Slice 56/56B).
   - A victim with `loot_table != none` rolls exactly **one** entry:

     ```
     victim_seed = rng.mix64(loot_seed, victim.index, victim.generation, loot_victim_salt)
     entry pick: rng.boundedU32(victim_seed, 0, step, loot_entry_salt, total_weight)
     count = min + rng.boundedU32(victim_seed, 0, step, loot_count_salt, max - min + 1)
     ```

   - The drop is `create_entity(worldItemTemplate(...))` at the victim center.
   - One roll per kill means at most `combat_max_kills_per_step` creates per
     step, by construction.
   - The victim's carried contents drop through Slice 68C's FIFO (phases
     4–5), admission-gated in `combat_resolve` so nothing is ever lost.
4. **Expiry.** Scan the world-item store (at most `world_item_live_capacity`)
   and destroy up to `world_item_expiry_budget_per_step = 32` rows with
   `stepReached(step, despawn_step)` and `count > 0` (a `count == 0` row
   already has its destroy queued), in dense order. The rest wait for the next
   step.

World-item cap:

- `world_item_creates_per_step_max = combat_max_kills_per_step` (one loot roll
  per kill: 64 with Slice 56 alone, 128 once 56B lands). Slice 58 adds 1 for
  dig yields and Slice 57B adds 1 for UI drops. Comptime asserts:
  `world_item_creates_per_step_max >= combat_max_kills_per_step` and
  `world_item_creates_per_step_max < world_item_live_capacity`.
- Producers create only while
  `world_items.len + world_item_creates_per_step_max < world_item_live_capacity`,
  with `world_item_live_capacity = 1024`. Deferred creates therefore can never
  overshoot the cap.
- Refusals are counted.
- `loot_seed = seed.derive(.loot)`, computed once in `SimulationPipeline.init`.
  This slice appends `SeedDomain.loot = 4` (the value Slice 49 reserves).
- World items get
  `despawn_step = stepAfter(step, world_item_lifetime_steps)` with
  `world_item_lifetime_steps = 18_000` (5 minutes).
- **Collision capacity.** Add `world_item_live_capacity` to the body count the
  demo passes to `estimateContactCapacity` (and therefore
  `estimateTriggerCapacity`) and to `.movement_body_capacity`. Intent capacity
  is unchanged (trigger pairs produce no physical intents), and the spatial
  index is unchanged (world items carry no `AiAgent`).

**Equipment modifies combat.**

- `AiActionSelectSystem`'s `.attack` arm reach uses `attack_range +
  weapon.range_bonus` (one catalog lookup on the weapon slot).
- `CombatController` uses:
  - `base_damage + Σ attack_bonus`, clamped to at least 0
  - `attack_cooldown_steps + Σ cooldown_bonus_steps`, clamped to `1..=600`
    (then `stepAfter`)
  - target mitigation `clamp(armor_mitigation + Σ mitigation_bonus, 0, 0.9)`
- Both receive `*const ItemCatalog` through
  `SimulationPipelineUpdateContext.items`, borrowed per step. The state-owned
  catalog's address is not stable while `GameDemoState` is moved at init, so
  the pipeline never stores it.
- An entity without `equipment` has zero modifiers (optional input).

**Events (domain_reaction stage, scalar-only).**

- `ItemPickedUpEvent { holder, item, count: u16 }`
- `ItemUsedEvent { user, item }`
- `EventProducerId.inventory_update => action_intent_live_capacity + pickup_budget_per_step`.
- Audio: `AudioController.queueItems` plays `collision_sfx` (ratio 1.8) for
  player pickups, at most 2 per step.

**Budgets, format bounds, and the one growable store.** Every row is a
fixed per-step budget or a format/load-time bound except the inventory slot
arena, which grows at the structural-commit seam.

| Constant | Value | Reason |
| --- | --- | --- |
| `max_item_key` / `item_catalog_capacity` | 4095 / 1024 | Format bound (`key_to_row` direct-index table, 8 KB) / loud load-time ceiling; catalog rows are reserved to the authored entry count, never to 1024 |
| `max_item_value` | 1_000_000 | Keeps `count * value` and Slice 63 pricing inside `u64` with headroom |
| `pickup_budget_per_step` | 16 | Overflow re-triggers next step |
| Loot rolls per kill | 1 | Creates ≤ `combat_max_kills_per_step` per step by construction |
| `world_item_creates_per_step_max` | `combat_max_kills_per_step` (+1 58, +1 57B) | Comptime-tied to the combat kill cap |
| `world_item_live_capacity` | 1024 | Live-population budget, not a content capacity: world items are runtime-produced only, and the cap bounds the serial expiry scan and the trigger-body count per step whatever the world size. Refuse creates beyond `cap - creates_per_step_max` (counted; 68C defers carried drops in its FIFO) |
| `world_item_expiry_budget_per_step` | 32 | Dense-order deferral |
| Inventory slot arena | Content-derived initial bound from the state; geometric growth at the structural-commit seam; `u32` ceiling | Runtime-growing store, not a budget: covers pooled-run fragmentation by growth; refusal only at the `u32` ceiling |
| `inventory_transfer_capacity` / `max_transfer_item_deltas` | 128 / 4 | Fixed transfer queue; full queue refuses the producer's batch |
| Structural headroom | `+ world_item_creates_per_step_max` creates `+ pickup_budget_per_step` destroys `+ world_item_expiry_budget_per_step` expiry | Added to the demo's `structural_reserve` through the named constants |

**Persistence boundary (Slice 46 save sections, added in this slice).**

- Persist: each `Inventory` row (size class, `auto_pickup`, loot-table key,
  coins, logical slot list of `ItemId` + count); `Equipment` slots;
  `WorldItem` rows. All of these are stable keys. `ItemCatalog.fingerprint()`
  and `LootTableCatalog.fingerprint()` feed Slice 46's `content_fingerprint`.
- Do not persist: run offsets, free lists, catalog rows.
- An unknown `ItemId` key on load rejects the whole load (no partial apply).
- Slice 49 classification: `InventoryStore` (custom logical hash, above),
  `EquipmentStore` (`[7]ItemId` has a unique representation, so raw bytes),
  `WorldItemStore` (hashed MAL). The player's use-item rising-edge latch is
  classified hashed by Slice 64B and saved in Slice 46's `pipeline_history`
  (Slice 64 addition (f), Checklist); if 64B has not landed yet, it is listed
  in Slice 49's excluded list and 64B classifies it.

**FailingAllocator proofs.**

1. Store appends after reserve.
2. Slot-pool run allocation, both fresh-tail and free-list reuse, after the
   `StructuralCapacityNeeds` preflight.
3. Slot-pool churn and growth: reserve the arena with a small initial bound,
   fill to a class mix, destroy, then shift the class mix and refill within
   the reached arena size. Steady churn allocates nothing. A fill past the
   current arena grows it only inside the structural-commit preflight (the
   `FailingAllocator` fails the next allocation after the grow and the commit
   still completes via `assumeCapacity`), and no allocation happens outside
   that seam. Runs keep their `slot_run_start` and contents across the grow.
4. `InventoryController.process` covering use, partial and full pickup
   (including two holders on one item), loot create, and expiry, after frame
   reserve.
5. `applyTransferBatch` (grant, two-sided trade, rejected batch) with a
   failing allocator: zero allocations.
6. Composite `pipeline.update` covering kill → loot on one step and pickup on
   the next.

Threading: the controller stays serial because every phase is bounded by a
fixed per-step constant or by the fixed `world_item_live_capacity`.

### Checklist

- [ ] `ItemId` / `LootTableId`, plus `ItemCatalog` and the loot-table loader
      with strict validation (including `value <= max_item_value`), icon
      resolution, both `fingerprint`s, and `deinit`. Add
      `assets/items/items.json` and `assets/items/loot_tables.json`, and
      confirm both install with the runtime asset tree.
- [ ] `inventory` / `equipment` / `world_item` components (three appended
      tags): `data_system/inventory.zig` stores and `InventorySlotPool`, full
      component wiring, capacity needs including pool runs and free lists,
      the growable slot arena (`DataSystem.reserveInventorySlotArena(initial)`
      with a state-passed content-derived initial bound, geometric growth at
      the structural-commit seam, refusal only at the `u32` ceiling
      `InventorySlotArenaTooLarge`, counted in `inventory_runs_refused`), and
      destroy cleanup. Test: a create past the initial bound succeeds by
      growth at the seam.
- [ ] Slice 49 classification (`InventoryStore` logical hash with
      `slot_run_start` / free lists / arena tail excluded; `EquipmentStore`;
      `WorldItemStore`) and the Slice 46 save sections, in the same change.
- [ ] `InventoryTemplate` / `Equipment` / `WorldItem` template fields;
      `ActionIntent.item`; `worldItemTemplate` helper.
- [ ] Archetype `inventory` block and new load-order signature; demo
      `aggressive` loot/kit; player kit.
- [ ] `inventory_update` stage, tags, contract, `runStage` arm, and
      `pipeline_inventory` timer. Add `carried = inventory_state` to
      `ai_action_select` and `combat_resolve`. Raise `@setEvalBranchQuota` at
      `simulation_pipeline.zig:287` if needed.
- [ ] Inventory-transfer substrate: `ItemDelta` / `CoinDelta` /
      `TransferBatch` (+ `grant`), fixed `InventoryTransferQueue`, pure
      `canAccept` / `canRemove` / `canRemoveCoins` over committed + pending
      state, and
      all-or-nothing `applyTransferBatch` sharing the Pickup slot primitive,
      with the `transfers_rejected` counter. Document that Slice 61 wires the
      resource tag, the `StepState` queue, and phase 0.
- [ ] `InventoryController` phases (use, pickup, loot, expiry), the
      single-winner pickup rule (`count` hot-write, skip `count == 0`), the
      world-item cap rule tied to `combat_max_kills_per_step` (comptime
      asserts), the loot rng, and the counters `items_used`,
      `items_picked_up`, `pickups_refused`, `loot_dropped`, `loot_refused`,
      `world_items_expired`, `inventory_runs_refused`.
- [ ] `loot_seed = seed.derive(.loot)` at `SimulationPipeline.init`; append
      `SeedDomain.loot = 4`.
- [ ] Equipment modifiers wired into `AiActionSelectSystem` and
      `CombatController` through `SimulationPipelineUpdateContext.items`.
- [ ] Event payloads, stats, and metrics; `EventProducerId.inventory_update`;
      demo reserve terms through named constants; collision contact/trigger
      and `movement_body_capacity` body count includes
      `world_item_live_capacity`; `AudioController.queueItems`.
- [ ] Player hotkey `Action.use_item`: key `H` (an `SDL_SCANCODE_*` value in
      `default_key_bindings` if this lands after Slice 67A), gamepad
      `SDL_GAMEPAD_BUTTON_LEFT_STICK` until Slice 70B moves it to
      `left_trigger`. Classified by
      `isGameplayAction` (extend the routing tests); append the pinned replay
      bit (Slice 49 table, bit 9). It captures a rising-edge `.use` with
      `item = .none` in `captureActionIntent`.
- [ ] Docs:
      - `docs/architecture.md`: inventory ownership, item catalog, pooled slot
        runs and their arena growth at the structural-commit seam, the
        transfer substrate, and the
        persistence boundary.
      - `docs/simulation-tiers-and-pipeline.md`: stage, events, `.use`
        consumer, transfer phase 0.
      - `docs/development-workflow.md`: item and loot authoring workflow.
- [ ] (added by Slice 64) The use-item rising-edge latch is classified in 64B's
      `checksum_hashed_fields` and joins Slice 46's `"pipeline_history"`
      section in the same change (the same classification, save field, and
      test as Slice 56's `attack_held_last`). Test: toggling it changes the
      checksum.
  - If 64B has not landed yet, the latch is listed in Slice 49's
    "Deliberately excluded pipeline and controller runtime state" list
    instead, and 64B classifies it.
- [ ] (added by Slice 67) Event-log feed arm for `item_picked_up` per Slice
      67B; `lineFor` takes `*const ItemCatalog` for names. Every
      `SimulationEventPayload` arm this slice adds gets a line or `=> null`.
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes.
      `ItemCatalog` stores a name `StringId` per item, not a literal.
      Otherwise 67E migrates it.

### Acceptance checks

- [ ] Loader: rejects duplicate key/id, unknown kind/slot/icon/effect,
      out-of-range bonuses or `value`, `equip` on a consumable, and a missing
      `consume` block. The installed files load. Reordering entries does not
      change any `ItemId` or either fingerprint.
- [ ] Inventory operations:
      - Stacks merge up to `max_stack`, then fill empty slots.
      - A partial pickup leaves the remainder in the world.
      - Currency goes to `coins` and never into a slot; `9999 * max_item_value`
        saturates at `max_coins` without overflow.
      - Auto-equip happens only when the slot is empty.
      - Using an equippable item swaps it with the equipped item.
      - Heal never revives a 0 HP entity.
- [ ] Pickup duplication:
      - Two auto-pickup holders overlapping one world item in one step → exactly
        one grant (the first holder in trigger order), one destroy, and the
        second holder's inventory unchanged.
      - A partial take by the first holder, then a second holder in the same
        step → the second holder receives the remainder only, and the total
        granted equals the original `count`.
- [ ] Transfers:
      - A two-sided trade batch with insufficient coins applies nothing (goods
        and coins both unchanged).
      - `canAccept` accounts for a delta already queued this step for the same
        entity.
      - `canRemoveCoins` reads committed `coins` plus queued `CoinDelta`s: a
        debit already queued this step lowers the available balance, a queued
        credit raises it, and an `amount` above the resulting balance returns
        `false`.
      - A full `InventoryTransferQueue` refuses `tryAppend` without
        allocating.
- [ ] Combat integration: an equipped `iron_sword` raises damage and reach in
      `CombatController` / `AiActionSelectSystem`; armor mitigation clamps to
      0.9.
- [ ] Loot determinism: the same seed, victim, and step give the same entry
      and count, and at most one world item per kill.
- [ ] A composite kill → loot → pickup run over two `pipeline.update` steps
      gives identical inventory, coin, and world-item checksums with 0 workers
      and with N workers.
- [ ] Caps: exceeding `world_item_live_capacity` headroom refuses and counts;
      expiry deferral follows dense order and skips `count == 0` rows.
- [ ] Pool: free-list reuse returns a run of the same class; destroy clears
      the run; no allocation after preflight (proof 2); the churn test (proof
      3) shows steady churn allocation-free and growth only at the
      structural-commit seam.
- [ ] Checksum: two inventories with identical contents but different run
      offsets hash equal.
- [ ] FailingAllocator proofs (1)–(6). Comptime payload-purity tests for both
      events. No test-only tags.
- [ ] Benchmarks (new groups in `src/benchmarks/`, hyphenated names, sizes in
      `defaultItemCounts`): `zig build bench -- --group inventory-update`
      (full per-step budget; default items 1024 / 4096 / 10000 inventories)
      and `zig build bench -- --group world-item-expiry` (default items 1024
      rows) are added, run, and stay flat.
- [ ] (added by Slices 68A–68C) Run the Slice 68A §3 re-baseline procedure and
      record this slice's schema rows (`inventory stage` / world items live).
- [ ] `zig build verify` passes.

### VoidLight reference

Port:

- `InventorySlotData` (resource + quantity) → `ItemStack`.
- `maxStackSize`, `value`, and equipment `slot` / `attackBonus` /
  `defenseBonus` from `res/data/items.json`, `equipment.json`, `weapons.json`,
  `currency.json` → `ItemDefRow` fields (`defenseBonus` becomes
  `mitigation_bonus`).
- Weapon `attackRange` → `range_bonus`.
- The `equipFirstAvailableMeleeWeapon` fallback (`CombatController.cpp:22-61`)
  → auto-equip on pickup.
- Pickup that destroys the world item (`InventoryController.cpp:126-177`) →
  trigger-overlap pickup.

Do not port:

- Runtime-generated `ResourceHandle` id + generation
  (`ResourceTemplateManager.cpp:296-334`). It is not stable across runs.
- `unordered_map` template lookup and the `dynamic_pointer_cast<Equipment>`
  casts.
- `InventoryOverflow` per-entity heap vectors
  (`EntityDataTypes.hpp:449-510`).
- Radius-scan pickup (`WorldResourceManager::findClosestDroppedItem`).
- String reasons on `triggerResourceChange`.
- `durability` / `speedBonus` (no consumer).
- Currency modeled as stackable slot items.
- `textureId` strings at runtime; atlas entries resolve at load instead.

