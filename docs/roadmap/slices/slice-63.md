## Slice 63: Social Relationships And Trade

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md), [Slice 57](slice-57.md), [Slice 57B](slice-57b.md), [Slice 61](slice-61.md), [Slice 56](slice-56.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **57** (inventory, item base `value`
bounded by `max_item_value`, coins, and the transfer substrate: `TransferBatch`
/ `InventoryTransferQueue.tryAppend` / `canAccept` / `canRemove` /
`canRemoveCoins`), **57B** (the
`PendingPlayerActions` FIFO, the `live_modal_overlay` preset, the `toast` HUD
primitive, and replay format v3 action records), **53B** (UI toolkit widgets for
the trade screen), **61** (`harvest_completed` theft input, the `AffectImpulse`
substrate, and the `inventory_transfers` pipeline wiring), and **56** (the
`ActionClaimSet` and fixed claim order, and the combat events behind the
assault/kill rows; 56 lands before 57, so it is present). It must land before
**62**'s merchant entry.

Goal: bounded, deterministic social state.

- A directed faction-standing matrix replaces the const stance table as the
  runtime stance source. It is seeded byte-identically from it, so crossing a
  threshold flips perception and AI hostility with no new AI code.
- A 4-slot per-NPC opinion ledger tracks individuals.
- A `SocialController` turns trade, gift, theft, and combat facts into standing
  and ledger deltas plus affect impulses.
- Merchants trade through action intents with integer pricing in Slice 57
  coins, under a live-modal trade screen built on Slice 53B and 57B.

### Current foundation (do not rebuild)

- `Faction` closed enum (4 tags) and const symmetric `relationship_matrix` /
  `stance()` (`src/game/faction.zig:7-28`). Hot call sites are
  `perception.zig:1326` (candidate visitor), `perception.zig:1524` (player
  fold-in), and `ai.zig:1168` (cohere friendly filter).
- Action intents and claims (Slice 56 `ActionClaimSet`, fixed claim order
  trade → harvest → destructible), `.interact` faced-cell capture
  (`simulation_pipeline.zig:896-926`), and the `action_react` controller
  composition (Slice 56, with Slice 61's harvest controller).
- `AffectImpulse` substrate with exhaustive producer budgets and the
  commit-seam drain (Slice 61); `harvest_completed` carries `owned`/`owner`
  (Slice 61).
- Slice 57 transfer substrate and `inventory_transfers` wiring (Slices 57 and
  61); Slice 57 `max_item_value = 1_000_000` and `max_coins`.
- Slice 57B: `PendingPlayerActions` (fixed FIFO of 8, drained by
  `pipeline.capturePendingPlayerActions`), `state_policy.live_modal_overlay`,
  the `toast` HUD primitive, and `ReplayActionRecord` (format v3).
- State stack: `StatePolicy` presets `gameplay`, `modal_overlay`
  (`update_below = false`), and `pass_through_overlay`
  (`src/app/state.zig:30-56`). Modal push with a borrowed pointer into the state
  below (`main_menu_state.zig:173-181` → `settings_menu_state.zig:48,76`).
- Post-step event access in `GameDemoState.update` (`game_demo_state.zig:512-564`).

### Architecture notes

**Relationship layout: two bounded tiers, no N² pairs**

1. **`FactionRelations`**, a fixed struct field on `DataSystem` (persistent,
   saved by Slice 46, checksummed by Slice 49):
   - `standing: [faction_count][faction_count]i8`, directed (`from` regards
     `toward`) and clamped `[-100, 100]`;
   - `stance_cache: [faction_count][faction_count]Stance`, derived at commit
     only (and recomputed after a Slice 46 load).
   - Seed: const `friendly → +60`, `neutral → 0`, `hostile → -60`.
   - Thresholds: `≤ -50 → hostile`, `≥ +50 → friendly`, else neutral (VoidLight
     `PLAYER_STANDING_*_AT`).
   - The diagonal is locked (`adjust` with `from == toward` is a validation
     error).

   `relations.stance(a, b)` is one array index, the same cost as today.
   `faction.stance` is renamed `baselineStance` and used only to seed.
2. **`SocialLedger`**, a component (one tag, appended after the last tag
   present at landing): `subjects: [4]EntityId`, `affinity: [4]i8`
   (`[-100, 100]`), and `last_step: [4]u32`. Fixed array fields in the MAL row
   follow the `AiMemory.ring` precedent. Replacement when full picks the slot
   with the smallest `|affinity|`, then the oldest `last_step`, then the lowest
   slot.
3. **`Merchant`**, a component (one tag, appended):
   `{ profile: MerchantProfileId }`.

**Slice 49 checksum classification (and the matching Slice 46 save
sections):** `DataSystem.faction_relations.standing` is hashed; `stance_cache`
is excluded (derived at commit, rebuilt on load). `SocialLedgerStore` and
`MerchantStore` are hashed.

`attitude(npc, subject)` is computed in `i32`: `clamp(@as(i32,
standing[npc.faction][subject.faction]) + @as(i32, ledger(npc, subject)), -100,
100)`. The two `i8` terms are widened before the add, so `i8 + i8` never
overflows. The ledger contributes 0 when the subject is absent or the NPC has no
ledger. The ledger feeds trade and affect only. Per-entity stance in perception
is deferred, because it would put a 4-slot scan in the candidate hot loop.

**Merchant profiles (`assets/social/merchant_profiles.json`)**

`MerchantProfileId = enum(u8) { general_goods, provisioner }`. Fields:
`buy_markup_bp` (default 12000), `sell_bp` (6000), `refuse_below: i8` (-50),
`accepts: [57 item categories]`, and `stock: [{ item, qty }]`. The
`provisioner` profile buys the berries, wood, and stone from Slice 61. Loading
is strict, with Slice 57 item and category resolution. The profile catalog
fingerprint joins Slice 46's `content_fingerprint`.

**Pricing (pure, integer, shared by UI preview and the sim):**
`trade_pricing.zig`

- Inputs: `base = item.value` (`u32`, bounded `0..=max_item_value =
  1_000_000` by Slice 57's loader), `attitude: i32` in `[-100, 100]`,
  `quantity: u16`.
- Basis points are computed in `i32` and then clamped:
  `buy_bp = clamp(buy_markup_bp - attitude * 30, 5000, 20000)`,
  `sell_bp_eff = clamp(sell_bp + attitude * 30, 1000, 9500)`
  (`attitude * 30` ∈ `[-3000, 3000]`).
- Units are computed in `u64`:
  `buyUnit = ceilDiv(@as(u64, base) * buy_bp, 10000)`,
  `sellUnit = floorDiv(@as(u64, base) * sell_bp_eff, 10000)`.
  The largest product is `1_000_000 × 20000 = 2×10^10`, and the largest unit is
  `2_000_000`.
- Totals are `unit * quantity` in `u64`, at most `2×10^6 × 65535 < 2^38`, so
  they always fit Slice 57's `CoinDelta.delta: i64`. A comptime assert pins
  `max_item_value * 20000 / 10000 * maxInt(u16) <= maxInt(i64)`, so no runtime
  overflow path exists. A payee already near `max_coins` saturates under
  Slice 57's apply rule (documented; the cap is 10^9 coins).
- No floats, so prices are identical everywhere.

**Trade via action intents**

- Append `ActionKind.buy`, `.sell`, and `.give`. `ActionIntent` reuses Slice
  57's `item: ItemId` and gains `quantity: u16` and `price_limit: u32`. Because
  this adds `ActionIntent` fields, this slice extends Slice 57B's
  `ReplayActionRecord` with `quantity` and `price_limit` and bumps
  `replay_format_version` to the live value + 1 (v4 in the merged order) in the
  same change (57B's rule).
- `TradeController` runs first at `action_react`, per Slice 56's fixed claim
  order trade → harvest → destructible. Within `action_react`, social
  interaction outranks gathering, which outranks breaking.
- `.interact` resolving a merchant is claimed. The merchant is either the
  explicit target or the first match within `merchant_cell_scan_budget = 64`
  merchant rows whose AABB overlaps the faced cell on the level. It emits
  `trade_session_requested { customer, merchant, refused: bool }`.
- `.buy`, `.sell`, and `.give` validate in this order:
  1. the customer and merchant (or recipient) are alive;
  2. they share a level and are within `trade_reach = 96 px`;
  3. `attitude ≥ profile.refuse_below` (`refused`), except for `.give`;
  4. the quote at current attitude: buy rejects when `unit > price_limit`, and
     sell rejects when `unit < price_limit` (`price_changed`), so a stale
     preview never overcharges;
  5. stock and capacity through Slice 57's pure `canRemove(view, pending, ...)`
     / `canAccept(view, pending, ...)`, and funds through Slice 57's coin analog
     `canRemoveCoins(view, pending, entity, amount)` (committed `coins` plus
     queued `CoinDelta`s), where `pending` is this step's
     `InventoryTransferQueue`. Earlier same-step trades and grants are therefore
     already counted, and no trade-local pending scratch exists. Slice 57 owns
     `canRemoveCoins` beside `canAccept`/`canRemove` (Slice 57 pure queries);
  6. `profile.accepts` for sell;
  7. a free `InventoryTransferQueue` slot.
- On success it appends one Slice 57 `TransferBatch` with
  `InventoryTransferQueue.tryAppend`: buy/sell carry two `ItemDelta`s (goods out
  of the seller, into the buyer) and two `CoinDelta`s; a gift carries two
  `ItemDelta`s. `inventory_update` phase 0 applies it all-or-nothing after
  revalidation later in the same step. It also emits `trade_completed {
  customer, merchant, item, quantity, total, direction }` or `gift_given {
  giver, recipient, item, quantity, value }`. Rejections are
  `TradeStats.rejected[reason]` counters. Because preflight reads the step's
  queue and no stage between `action_react` and `inventory_update` phase 0
  mutates inventories or coins, phase 0 cannot reject a batch this controller
  queued: a debug assert plus Slice 57's `transfers_rejected` counter guard
  that invariant, so an emitted `trade_completed` always matches the committed
  transfer.
- No session state exists in the sim: every request revalidates.

**Trade UI (`src/game/trade_menu_state.zig`, Slice 53B widgets)**

- `GameDemoState` scans this step's events after `pipeline.update`. On a
  `trade_session_requested` whose customer is the player and not refused, it
  queues a push of `TradeMenuState` (applied after dispatch). When refused, it
  raises a 57B toast.
- Uses Slice 57B's `live_modal_overlay` preset. The world keeps stepping, so a
  merchant killed or walking out of reach mid-trade is real.
- The state borrows `*PendingPlayerActions` (Slice 57B) plus `*const
  DataSystem` for render-time read-only inventory and quote views. This follows
  the settings-menu borrowed-pointer precedent and 57B's read-only panel
  signature rule.
- Confirm pushes a request carrying the previewed `price_limit`.
- Session validity (alive, reach, level) is checked by the pure check in the
  menu state's **fixed `update`**, not per render frame. When invalid, it queues
  its own pop through the state stack's transition queue, applied after
  dispatch.
- `pipeline.capturePendingPlayerActions` (Slice 57B) drains the FIFO into
  `action_intents` in `main_thread_inputs`.

**`SocialController` (new `StageId.social_react`)**

It sits after `inventory_update` (57) and before `tier_policy`, so it reads this
step's `combat_events` and `trade_events`. It is serial and consumes this step's
merged events:

| Event | Ledger (subject) | Standing (`from` → `toward`) | Affect impulse (producer `.social`) |
| --- | --- | --- | --- |
| `trade_completed` | merchant→customer +2 | — | merchant `aggression −0.05` |
| `gift_given` | recipient→giver `+min(5 + value/100, 25)` | recipient.faction→giver.faction `+15` if `value ≥ 100` | recipient `aggression −0.10`, `fear −0.05` |
| `harvest_completed` with `owned` and `owner ≠ harvester.faction` | — | owner→harvester.faction `−25` (player) / `−10` (NPC) | — |
| 56 assault (attacker = player, victim not already hostile) | victim→attacker −10 | victim.faction→player `−10` | — (56 owns pain/fear) |
| 56 kill (attacker = player) | — | victim.faction→player `−30` | — |

- Deltas net in fixed scratch, in widened types:
  - standing: `[faction_count][faction_count]i32` sums, each clamped to
    `[-200, 200]` at emit, emitting ≤ 12 `adjust_faction_standing` commands
    (`delta: i16`). `[-200, 200]` is enough to cross the whole `[-100, 100]`
    range in one step;
  - ledger edits: `{npc, subject, delta: i16}`, sized to
    `maxEventsPerStep(.action_react) + maxEventsPerStep(.combat_resolve)`. It
    stays symbolic, because Slice 56B raises the combat budget, so overflow is
    impossible by construction. Each NPC gets one `set_social_ledger` command,
    a full-row replace computed in `i32` from the committed ledger plus netted
    deltas and clamped to `[-100, 100]` before narrowing to `i8`.
- Impulses go through `enqueueImpulses(.social, ...)` with
  `maxAffectImpulsesPerStep(.social) = 2 * 64`; the exhaustive
  `AffectImpulseProducer` gains `.social`.
- Combat reputation therefore reaches feelings through stance: hostile
  standing → perception `nearest_threat` → existing fear and aggression
  appraisal. Trade and gift reach feelings directly through impulses.

**Commit seam.** The new `StructuralCommand.adjust_faction_standing { from,
toward, delta: i16 }` (validated `[-200, 200]`) widens the stored `i8` to `i16`,
adds, clamps to `[-100, 100]`, narrows, and recomputes the 16-entry
`stance_cache`. When a stance band changes, it emits the structural event
`faction_stance_changed { from, toward, old: Stance, new: Stance }`. The
consumers are stats and the Slice 67B event-log feed. Perception holds
no stance cache, so no post-commit cache reaction is needed.

**Reserves.** The demo's `demo_structural_headroom` adds, as named terms: ≤ 12
`adjust_faction_standing` commands plus ≤ `maxEventsPerStep(.action_react) +
maxEventsPerStep(.combat_resolve)` `set_social_ledger` commands (one `component_changed`
event each at commit). `faction_stance_changed` gets its own `EventProducerId` arm (its
producing stage) with budget 12, summed by `SimulationPipeline.eventCapacitySum()`. The
demo's `capacity_limit` literal test is re-pinned deliberately.

**Stage contract**

- New `PipelineResource` tags:
  - `faction_relations` (external, committed at the seam);
  - `trade_events` (`trade_session_requested`, `trade_completed`,
    `gift_given`).
- `perception_update`, `ai_decide`, and `ai_action_select`:
  `carried += {faction_relations}`. `PerceptionConfig.relations` and
  `AiConfig.relations` take `*const FactionRelations`; tests pass
  `&FactionRelations.baseline`.
- `action_react`: `writes += {trade_events}`; `carried += {faction_relations}`
  (it already writes `inventory_transfers` and `affect_impulses` after 61).
- `social_react`: `reads {world_events, trade_events, combat_events}`,
  `writes {structural_commands, affect_impulses}`.
- `EventProducerId` gains nothing new: trade events share the `.action_react`
  budget through claims. `social_react` emits commands and impulses only.

**Fixed budgets:** faction matrix 4×4; ledger 4 slots; `trade_reach` 96 px;
`merchant_cell_scan_budget` 64; trades ≤ `action_intent_live_capacity` per step
(within Slice 57's `inventory_transfer_capacity` 128, shared with harvest
grants); ledger edits `maxEventsPerStep(.action_react) +
maxEventsPerStep(.combat_resolve)`; standing commands ≤ 12 per step;
`faction_stance_changed` ≤ 12 per step; `PendingPlayerActions` 8 (57B); social
impulses 128 per step. None scale with world or population.

**Determinism contract.**

- Trades resolve in merged-intent order against committed state plus this
  step's queued transfer batches.
- Social deltas net in event order, which comes from the deterministic
  `action_react`/56 emit order. Commands are emitted in ascending `(from,
  toward)` and ascending NPC entity index.
- Pricing is integer only, with every product widened before it is formed.
- Stance changes apply only at the commit seam and are read next step.
- The UI never mutates sim state: it only enqueues intents.
- Replays record the `PendingPlayerActions` drain through the Slice 57B action
  records, extended by this slice to format v4 (live value + 1).

**Deferred:**

- witness-gated reputation, using perception of the incident by owner-faction
  members;
- guard alert broadcast on theft (VoidLight `alertNearbyGuards`): Slice 71A's
  `guard_alarm` theft source;
- merchant restock (Slice 59 day boundary);
- AI↔merchant trade emission, closing the forage → sell loop, as an
  `ai_action_select` arm: Slice 71D;
- per-entity ledger stance in perception;
- multiple currencies.

### Checklist

- [ ] `FactionRelations` on `DataSystem`, with:
  - baseline seed from the const matrix;
  - thresholds;
  - `adjust_faction_standing { delta: i16 }` command + widened commit add/clamp + recompute + `faction_stance_changed` event.

  Tests: seed parity for all 16 pairs, clamp, threshold flip, diagonal rejection, a `±200` delta from `±100`.
- [ ] Slice 49 checksum classification + Slice 46 save sections: `faction_relations.standing` hashed (`stance_cache` excluded, rebuilt on load); `SocialLedgerStore` and `MerchantStore` hashed.
- [ ] Rewire `perception.zig:1326,1524` and `ai.zig:1168` to `relations.stance`; config plumbing; pipeline passes `data.factionRelationsConst()`.
- [ ] `SocialLedger` component (one appended tag; full store pattern + `set_social_ledger`) with the replacement-policy tests and a `FailingAllocator` proof.
- [ ] `Merchant` component (one appended tag) + `MerchantProfileId` strict catalog; demo places one `general_goods` and one `provisioner` merchant with stock.
- [ ] `trade_pricing.zig` pure integer quote, with a table test covering attitude ±100 (including standing ±100 plus ledger ±100 before the clamp), the bp clamps, and `value = max_item_value` with `quantity = maxInt(u16)`; the comptime no-overflow assert.
- [ ] `ActionKind.buy`, `.sell`, `.give` and the `ActionIntent` `quantity` / `price_limit` fields; `ReplayActionRecord` extension and `replay_format_version` live value + 1 (v4 in the merged order) with a round-trip test; `TradeController` at the front of Slice 56's claim order.
- [ ] Trades and gifts through Slice 57 `TransferBatch` + `tryAppend` with `canAccept` / `canRemove` / `canRemoveCoins` preflight against the step's queue; test that phase 0 never rejects a trade batch queued by this controller.
- [ ] Trade events and stats counters.
- [ ] (added by Slice 64) The format bump is **relative**: set `replay_format_version` to the
      live value + 1 in the same change, and keep every earlier header and
      frame extension (64C's 80-byte header and `build_fingerprint`, 64A's
      renamed flags bit0). The round-trip test decodes a file that exercises
      all earlier extensions plus the new records.
- [ ] (added by Slice 67) Event-log feed arms for `trade_completed`,
      `gift_given`, `trade_session_requested` (`null`), and
      `faction_stance_changed` per Slice 67B. Every
      `SimulationEventPayload` arm this slice adds gets a line or `=> null`.
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes.
      Otherwise 67E migrates it.
- [ ] `TradeMenuState` on 53B widgets and 57B's `live_modal_overlay` / `PendingPlayerActions` / toast, with headless tests:
  - selection;
  - quantity;
  - the quote matches the sim;
  - submit enqueues;
  - auto-close on an invalid session, decided in the fixed `update` through a queued pop.
- [ ] `SocialController` + `StageId.social_react` (after `inventory_update`, before `tier_policy`) + contract + `runStage` arm; delta table above; `.social` impulse producer. Raise `@setEvalBranchQuota` at `simulation_pipeline.zig:287` if the comptime contract walk needs it.
- [ ] Combat rows wired to Slice 56's `combat_events`.
- [ ] Reserves: standing and ledger commands added to `demo_structural_headroom`; an
  `EventProducerId` arm with budget 12 for `faction_stance_changed`; demo `capacity_limit`
  literal re-pinned.
- [ ] Bench group `social-react` (one `BenchmarkGroup` in `src/benchmarks/social.zig`, default items 128 events, registered in `runner.zig`). Re-run `--group perception` and `--group ai` for the relations-table indirection.
- [ ] Docs:
  - `architecture.md` (relations, ledger, merchant, `SocialController`);
  - `simulation-tiers-and-pipeline.md` (claim order, trade events, stage, transfer batches);
  - `state-stack-and-input.md` (trade screen on `live_modal_overlay`, routing).

### Acceptance checks

- [ ] With baseline relations, perception, AI cohere, and arbitration outputs are byte-identical to the pre-slice const-stance path (fixture parity).
- [ ] Driving player standing with `ally` below −50 (theft of ally-owned nodes plus assault) flips ally perception of the player to hostile on the next step, and timid allies flee with no AI code change.
- [ ] Buy and sell move goods and coins atomically. These failures each reject cleanly with no partial transfer:
  - insufficient funds;
  - insufficient stock;
  - full inventory;
  - refused;
  - out of reach;
  - `price_changed`.

  Two same-step buys of the last stock: the first succeeds and the second is rejected (preflight against the step's transfer queue).
- [ ] Each intent is claimed at most once across trade, harvest, and destructible (shared `.action_react` event budget test).
- [ ] Trade and gift move ledger affinity and emit calming impulses that lower merchant aggression on the next step's appraisal.
- [ ] Serial == threaded perception and AI with non-baseline relations.
- [ ] A replay containing UI trade intents (format v4) verifies.
- [ ] `FailingAllocator` composite `pipeline.update` with trades, gifts, and social deltas.
- [ ] `zig build bench -- --group social-react` recorded; no perception or AI regression; `zig build verify` passes.
- [ ] Manual/`gpu-smoke`: trade screen renders, navigates by keyboard and gamepad, and closes when the merchant walks away. This mirrors the Slice 33/43 manual-residual posture.

### VoidLight reference

**Port:**

- `AIManager` directed faction stance and player standing:
  - `int8 [-100, 100]` with ±50 bands;
  - `recordPlayerIncident` deltas: assault −10, kill −30, theft −25, gift +15;
  - `worsenStance` for NPC cross-faction theft, as a −10 standing delta.
- `SocialController` trade rules:
  - `BUY_PRICE_MULTIPLIER 1.2` / `SELL 0.6`;
  - `getPriceModifier` ±30% by relationship;
  - `willRefuseTrade < -0.5`;
  - trade +0.02 / gift-based relationship gains;
  - merchant inventories as stock.
- `applySocialInteraction` emotion deltas, as affect impulses (theft-victim
  numbers retained for the deferred pickpocket path).
- `StanceChangedEvent`, as `faction_stance_changed`.

**Do not port:**

- Float prices with `std::ceil` and the hand-written multi-step rollback chain
  in `tryBuy`/`trySell`. Integer quotes and a Slice 57 atomic transfer batch
  replace them.
- `getRelationshipLevel` summing unbounded interaction memories with emotion
  terms on every query.
- `GameTimeManager` float timestamps in memory entries.
- `EventManager::dispatchEvent(..., Immediate)` callback dispatch.
- `UIManager` string-keyed widget construction inside the controller.
- `alertNearbyGuards` immediate behavior messages (deferred to the Guard gap).
- `m_isTrading` controller session state. The sim stays stateless per request.

