## Slice 71D: AI Merchant Selling (Forage → Sell Loop)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 63](slice-63.md), [Slice 61](slice-61.md), [Slice 57](slice-57.md), [Slice 56](slice-56.md), [Slice 55](slice-55.md), [Slice 71A](slice-71a.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Depends on:

- **63** (`Merchant`, `MerchantProfileId` catalog with `accepts`,
  `TradeController` `.sell` validation, `trade_pricing.zig`, `attitude`,
  `trade_reach = 96`);
- **61** (`forage`, the `forager` archetype, the berries/wood/stone items);
- **57** (`InventoryView`, `ItemKind`, `canRemove`);
- **56** (`ai_action_select` per-kind arms, shared budget, deferral: 56's
  rotation start, replaced by deferral-age priority once Slice 68A lands);
- **55** (`coastableBehavior`);
- **71A** (behavior append order after `return_home`, and the
  `leashSuppressed` switch).

It lands after 71A.

**Owner decision:** this is a new section, not Slice 63 Checklist additions.

- Slice 63 owns the trade *substrate*: intents, validation, pricing, events,
  and UI.
- This slice is the AI *consumer*: an arbitration row, a goal resolver, and an
  `ai_action_select` arm. That matches how 61 owns `forage` on top of 57's
  substrate.
- The new `AiBehavior` tag must be appended after 71A's tags, and its leash
  classification needs 71A's switch. 63 lands before both.
- Slice 63's **Deferred** "AI↔merchant trade emission" line becomes "landed
  in Slice 71D". Slice 56's "a future AI trade arm for 63" note points here.

Goal:

- Foragers holding sellable surplus walk to the nearest merchant whose profile
  accepts it and sell through Slice 63's `.sell` intent. That frees inventory,
  so `forage` resumes.
- All of it runs through one new arbitration row (`trade`), one goal resolver,
  and one `.sell` arm in the single AI emitter.
- No second emitter, claim set, transfer path, or pricing code exists. Gain 0
  is byte-identical to today.

Out of scope, decided rather than deferred:

- **AI buying.** No AI consumer for bought goods exists. `need` is relieved
  only by harvest impulses (Slice 61), and Slice 57's `.use` has no AI arm.
- **AI gifts.** No appraisal reason exists.
- **Prewarm of merchant goals.** Merchants walk, so a field keyed to a
  merchant's current cell goes stale as it moves; see 71B.3.

### Current foundation

- **Slice 63:**
  - `ActionKind.sell` with `ActionIntent.item`, `quantity: u16`, and
    `price_limit: u32`. A sell is rejected when `unit < price_limit`.
  - `TradeController` sits first in the claim order and validates alive,
    level, `trade_reach`, `attitude ≥ refuse_below`, quote, `canRemove`/`canAccept`,
    `profile.accepts`, and a free transfer slot. A success queues one
    `TransferBatch` and emits `trade_completed`, which `SocialController`
    turns into ledger +2.
  - `trade_pricing.sellUnit(base, sell_bp_eff)` and `attitude(npc, subject)`
    are pure integer functions.
  - `MerchantStore` is hashed; `merchant_cell_scan_budget = 64`.
  - `ai_action_select` already carries `faction_relations`.
- **Slice 56:** `ai_action_select`'s exhaustive per-kind arm switch, the
  two-pass threaded emit, the `ai_action_budget_per_step = 48` shared budget
  with its deferral (rotation start; deferral-age priority from Slice 68A),
  and the single append path.
- **Slice 61:** the `.harvest` arm precedent (it recomputes its target on
  settled poses inside `ai_action_select`), the `forager` archetype (with a
  Slice 57 inventory block), and inventory-full rejection → frustration
  impulse lowering `need`.
- **Slice 57:** `InventoryView` (const inventory and slot-pool slices plus
  `*const ItemCatalog`), slot runs of 8–64 slots, `ItemKind` (8 tags), item
  `value`, and `canRemoveCoins(view, pending, entity, amount: u64)`, the
  funds preflight 63 uses.
- **Live AI anchors:** `gatherAiData` (`ai.zig:590-765`),
  `resolveRowArbitration` (`:1252-1365`), `priorityForBehavior`
  (`:1026-1033`), and the arbitration tables
  (`arbitration.zig:111-117,174-207,411-419`).

### Architecture notes

**Behavior row**

- Append `AiBehavior.trade` after `return_home`. `AiAgent.gain_trade: f32 = 0`
  gets a cold column, `max_ai_gain` validation, and archetype key
  `gain_trade`.
- Weight column (fear, curiosity, aggression, fatigue, need):
  `{-0.5, 0, -0.3, -0.3, -0.5}`. Hunger, fear, and fatigue defer selling; a
  calm, sated forager with surplus sells.
- `perceptionTerm(.trade) = trade_sell_bonus (0.5)` when `trade_present`.
  `memoryTerm` is 0.
- `resolveGoal(.trade)`: the merchant's step-start position,
  `goal_entity = merchant`, `kind_hint = .individual`. It is valid iff
  `trade_present`.
- Exhaustive arms:
  - `gainFor`;
  - `leashSuppressed(.trade) = true`, because selling pulls a guard off post;
  - `priorityForBehavior(.trade) = 3`;
  - the affect exertion switch (not exertion);
  - `coastableBehavior(.trade) = false` (path follower);
  - the debug overlay colour and label;
  - the bench histogram.
- Gain-0 parity follows the same argument as 71A: score 0, appended index,
  and wander ≥ 0.

**Sellable mask** (pure, `src/game/ai_trade.zig`)

- `sellableKindMask(view, entity) u8` sets bit `@backingInt(kind)` for every
  slot whose `count ≥ ai_sell_min_quantity`. It is O(run length ≤ 64).
- `MerchantProfileCatalog.acceptsMask(profile) u8` is derived once at the
  Slice 63 load from `accepts`. This is a 63-owned helper added here, a pure
  load-time derivation.
- `pickSellStack(view, entity, accepts_mask) ?struct { item: ItemId, quantity: u16 }`
  picks the lowest slot index with `count ≥ ai_sell_min_quantity` and an
  accepted kind. `quantity = min(count, ai_sell_max_quantity)`.

**Merchant snapshot.** `AiSystem` gains a fixed inline
`[ai_trade_merchant_capacity]MerchantSnap{ entity, level, x, y, accepts_mask }`
plus a count.

- It is built on the main thread at most once per `update`, lazily, on the
  first think row with `gain_trade > 0`.
- It holds the first `ai_trade_merchant_capacity` live `MerchantStore` rows
  in store order with a movement body, using step-start `previous_x/y`.
- It is a deterministic prefix, the 63 `merchant_cell_scan_budget`
  precedent. Merchants past the prefix are invisible to AI selling, counted
  in `ai_trade_merchants_truncated`.

**Gather.** For a think row with `gain_trade > 0` and an `inventory`
component:

1. `mask = sellableKindMask(...)`; when it is zero, the row is not present.
2. Find the nearest snapshot merchant that passes every filter below. Ties
   go to the lowest entity index, then generation.
   - Cheap filters first: same level (missing level counts as 0),
     `dist² ≤ ai_trade_query_radius²`, and `accepts_mask & mask != 0`.
   - **Refusal predicate:** `attitude(merchant, agent) ≥
     profile.refuse_below`. This is the same pure integer function the
     `.sell` arm and `TradeController` use, evaluated on committed relations
     and ledger.
   - **Funds preflight:** with `stack = pickSellStack(view, entity,
     merchant.accepts_mask)` and
     `price = stack.quantity × sellUnit(item.value, sell_bp_eff(profile,
     attitude))`, require `canRemoveCoins(view, pending, merchant, price)`
     (Slice 57). `pending` is empty at gather, because `ai_decide` runs before
     `inventory_update`, so this reads committed coins.
   - The refusal and funds checks run only for a merchant that passes the
     cheap filters and is nearer than the current best (or ties it on the
     tie-break), so the per-row cost stays ≤ 64 snapshot rows, each with at
     most one `pickSellStack` (≤ 64 slots).
   - **Why gather filters rather than only the arm.** If a refusing or
     broke merchant could still be the `trade` goal, `trade_present` would
     stay true and `trade` would keep scoring its 0.5 bonus. The agent would
     stand at the merchant without selling: once `need` is relieved, it
     returns, which is a livelock. A merchant that would refuse is therefore
     never a trade goal, and the agent's `trade` signal goes to the next
     qualifying merchant or to "not present".
3. Write `RowTrade { present, merchant: EntityId, x, y }`, a new grouped MAL
   column.
4. Fill the `Signals` fields `trade_present`, `trade_x`, `trade_y`, and
   `trade_merchant`.

Rows with gain 0 do one compare.

Contract: the gather reads committed inventories, merchant coins, and
relations/ledger. `ai_decide` therefore adds `inventory_state` and
`faction_relations` to `carried` where not already carried (later writers:
`inventory_update` and `social_react`). That is a carried-list edit, not a
new stage (Table T4).

**Emission: the `.sell` arm** in Slice 56's exhaustive switch. A row
qualifies when all of these hold:

- `active_behavior == .trade`;
- it has `inventory`;
- a merchant among the first `ai_trade_merchant_capacity` `MerchantStore`
  rows (re-resolved, alive) shares its level and is within
  `trade_reach = 96` of the **settled** pose (AABB-center distance, the
  harvest-arm precedent);
- `pickSellStack(view, entity, merchant accepts_mask)` returns a stack;
- `attitude(merchant, agent) ≥ profile.refuse_below`, so a refused agent
  emits nothing.

The emitted intent is
`{ entity, kind = .sell, target = merchant, item, quantity, level, price_limit = trade_pricing.sellUnit(item.value, sell_bp_eff(profile, attitude)) }`,
quoted from committed relations and ledger, so a stale quote is rejected
by 63 as `price_changed`, never as an undersell.

- It goes through 56's two-pass threaded emit, the shared 48 budget, and the
  bus deferral (`ai_actions_deferred`; rotation, or 68A's deferral-age
  priority if landed).
- Pass 1 is row-local and read-only. The per-row merchant scan is ≤ 64 rows
  with a mask test.
- Contract: `ai_action_select` `carried += {inventory_state}`
  (`inventory_update` writes it later in the step). `faction_relations` is
  already carried (63).
- The arm emits nothing but intents. `TradeController` (claim order front)
  claims and applies them. Rejections stay 63's `TradeStats.rejected[reason]`.
- The arm keeps its own refusal check on settled state. Gather already
  excludes merchants that refuse or cannot pay, so in practice the arm only
  catches a change within the step: another agent's sale draining the
  merchant's coins first, which 63 rejects as funds, or a standing change
  committed at this step's seam. Such a rejection is one-off: next step's
  gather sees the committed state and drops that merchant as a goal. A
  failed sale enqueues nothing, so there is no impulse loop. Ledger and
  standing changes come only from successful trades (63).

**Coasting (55).** `DecisionCoastInputs` gains `trade_signal: bool = false`
(alert). `aiDecideGatherJob` sets it when `gain_trade > 0` and the row has
`inventory`. That is component presence only, which is conservative.

**Fixed constants** (`ai_trade.zig`; none world- or population-derived)

| Constant | Value | Reason |
| --- | --- | --- |
| `ai_trade_merchant_capacity` | 64 | Equals 63's `merchant_cell_scan_budget`. A fixed inline snapshot. |
| `ai_trade_query_radius` | 768 px | Sellers walk farther than foragers search (forage 256, markers 400). A fixed search radius. |
| `ai_sell_min_quantity` | 3 | Surplus threshold, so foragers do not shuttle single berries |
| `ai_sell_max_quantity` | 64 | Per-intent cap. Fits `u16`; 63's pricing comptime assert already covers `maxInt(u16)`. |
| `trade_sell_bonus` | 0.5 | `perceptionTerm` |

**Content:** `forager` (61) gains `gain_trade 1.5`. The demo `provisioner`
merchant (63) accepts `material` and `consumable`, so berries, wood, and stone
sell. The demo loop is forage → full inventory → sell at the provisioner →
forage.

**Checksum and determinism:**

- `AiAgent.gain_trade` is inside the hashed `ai_agents` MAL. That adds
  hashed and saved state, so per Tables T3/T6 ("every slice that adds
  hashed state") 71D bumps `checksum_format_tag`
  (v+1) and the save `format_version` (live + 1; v13 in the merged order)
  once each. Tables T3/T6 list it.
- The snapshot and `RowTrade` are per-step scratch and are excluded.
- Emission order is the think-set order (56). Prices are integer only (63).
- Serial and threaded runs are identical.

### Checklist

- [ ] `AiBehavior.trade` + `gain_trade` (column, validation, archetype key)
      + every exhaustive arm listed above; gain-0 parity sweep (extend
      71A's 4096-sample sweep with `gain_trade = 0`).
- [ ] `ai_trade.zig`: `sellableKindMask`, `pickSellStack`, constants;
      `MerchantProfileCatalog.acceptsMask` at 63 load. Tests: min-quantity
      boundary (2/3), lowest-slot pick, quantity cap at 64, mask across kinds,
      empty inventory.
- [ ] `AiSystem` merchant snapshot (lazy, once per update, store-order prefix,
      truncation counter), `RowTrade` gather with the refusal and funds
      filters, `ai_decide` carried `inventory_state`/`faction_relations` with
      the contract test, `Signals` fields, `perceptionTerm`/`resolveGoal`
      arms. Tests: nearest accepting merchant
      on the same level is chosen; a merchant on another level or outside
      768 px is not; a merchant that accepts nothing held is skipped; the
      65th merchant is invisible and counted; **refusing merchant is never
      a goal:** an agent with sellable surplus and a single in-range
      merchant whose `attitude < refuse_below` has `trade_present == false`
      and selects `forage`/`wander`, not `trade`, over 300 steps; with a
      second, accepting merchant farther away, the agent targets that one;
      **broke merchant is never a goal:** a merchant whose coins are below the
      quoted price is skipped the same way; serial == threaded intents;
      `FailingAllocator` warmed update.
- [ ] `.sell` arm in `ai_action_select` with settled-pose reach, refusal
      gate, integer quote `price_limit`; contract `carried += inventory_state`
      and the contract test. Tests: serial == threaded candidates including a
      budget-capped deferral case mixing `.attack`/`.harvest`/`.sell`;
      a `.sell` intent is claimed by `TradeController` (never reaches
      harvest/destructible/combat); an attitude below `refuse_below` emits no
      intent.
- [ ] Slice 55 `trade_signal` and `coastableBehavior(.trade) = false`, with
      the decide-list determinism test re-run with traders.
- [ ] Content: `forager` `gain_trade 1.5`; demo provisioner accepts the 61
      items.
- [ ] Checksum/save: `gain_trade` hashed and saved with `ai_agents`; bump
      `checksum_format_tag` (v+1) and the save `format_version` (live + 1)
      once each in this change; the merchant snapshot and `RowTrade` go in
      the Slice 64B table as `excluded` (per-step scratch).
- [ ] Bench: extend `ai-action-select` (56) with a `.sell`-heavy population
      variant as group `ai-action-select-trade` (same fixture shape, 25% of
      rows `trade` within reach of one of 8 merchants).
- [ ] Docs: `docs/architecture.md` (AI trade consumer of 63's substrate),
      `docs/simulation-tiers-and-pipeline.md` (`.sell` arm, carried
      `inventory_state`); roadmap: Slice 63 **Deferred** AI↔merchant line →
      "landed in Slice 71D"; Slice 56's "future AI trade arm" note → 71D.

### Acceptance checks

- [ ] In a minimal fixture world:
  - a forager with 6 berries and an accepting provisioner 300 px away selects
    `trade`, walks into reach, and emits `.sell`;
  - the merchant's stock rises and the forager's coins rise by
    `6 × sellUnit` in the same step's `inventory_update`;
  - `trade_completed` is emitted, and the merchant ledger records +2 at
    `social_react`;
  - the forager returns to `forage` within one commitment window.
- [ ] Gain-0 parity:
  - the extended arbitration sweep matches;
  - the Slice 49 checksum over 120 steps of a fixture without foragers is
    identical before and after the slice.
- [ ] Serial == threaded for the AI gather, `ai_action_select` candidates,
  and the whole-pipeline checksum with selling active.
- [ ] `FailingAllocator`: the composite `pipeline.update` with a sale
  allocates nothing after reserve.
- [ ] `zig build bench -- --group ai-action-select-trade` is recorded, and
  `--group ai` and `--group ai-action-select` stay within noise.
- [ ] `zig build verify` passes.

### VoidLight reference

- Ported: the forage → sell loop (Slice 61 notes VoidLight
  `ForageBehavior` / merchant leash). Merchant acceptance comes from profile
  categories, and price comes from attitude (Slice 63 pricing).
- Not ported:
  - VoidLight's string resource ids and float prices;
  - per-NPC trade timers;
  - any immediate-dispatch trade commit.

  The sale is a deterministic `ActionIntent` resolved by 63's controller.

