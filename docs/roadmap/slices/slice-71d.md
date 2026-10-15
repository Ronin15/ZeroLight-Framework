## Slice 71D: AI Merchant Selling (Forage → Sell Loop)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 63](slice-63.md), [Slice 61](slice-61.md), [Slice 57](slice-57.md), [Slice 56](slice-56.md), [Slice 55](slice-55.md), [Slice 71A](slice-71a.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Owner decision: a separate section, not Slice 63
checklist additions (63 owns the trade substrate; this slice is its AI
consumer, as 61 is for 57).

Goal: foragers holding sellable surplus walk to the nearest merchant whose
profile accepts it and who would trade with them and can pay, and sell
through Slice 63's `.sell` intent, freeing inventory so foraging resumes.
It is one Slice 73 behavior (`trade`) with its goal primitive and the
`.sell` action through Slice 56's one emitter; no second emitter, claim set,
transfer path, or pricing code. Zero gain is byte-identical.

Out of scope, decided: AI buying (no AI consumer for bought goods), AI gifts
(no appraisal reason), prewarming merchant goals (merchants move).

### Current foundation

- From Slice 63: `.sell` with item, quantity, and price limit (rejected
  below the live quote); `TradeController` first in the claim order with
  full revalidation; pure integer `sellUnit` and `attitude`; hashed merchant
  store; merchant profile catalog with accepted categories.
- From Slice 56: the one emitter, shared per-step budget, deterministic
  deferral (68A's age priority once landed).
- From Slice 61: the harvest action precedent (target rechecked on settled
  poses in the emitter), the `forager` archetype with an inventory,
  frustration impulses.
- From Slice 57: inventory views, item kinds and values, `canRemove`,
  `canRemoveCoins`.
- Live AI anchors: `gatherAiData`, `resolveRowArbitration`, and
  `priorityForBehavior` in `src/game/systems/ai.zig`; arbitration tables in
  `src/game/systems/arbitration.zig`.

### Architecture notes

- `trade` is behavior content: hunger, fear, and fatigue defer selling; a
  calm, sated forager with surplus sells; it is leash-suppressed (71A), a
  path follower (never coasts), and not exertion.
- A merchant is never a trade goal if it would refuse the agent or cannot
  pay the quote; otherwise an agent would stand at it without selling and
  livelock. The emitter keeps its own refusal check on settled state.
- Merchants are found through a spatial query with a fixed per-query
  budget and deterministic order, never a prefix of the merchant store, so
  no merchant becomes invisible as merchant count grows
  (`.claude/rules/budgets-capacities.md`).
- Surplus and quantity thresholds and the search radius are fixed
  constants, never world- or population-derived.
- The sale is quoted from committed relations and ledger, so a stale quote
  is rejected as price-changed, never undersold; a failed sale enqueues
  nothing.
- The gather reads committed inventories, coins, and relations; contracts
  add them as carried where needed.
- The trade gain is hashed and saved with the AI agent store; relative
  version bumps; per-step scratch excluded (64B).
- Serial == threaded (`.claude/rules/threading.md`).
- VoidLight reference: the forage → sell loop with profile acceptance and
  attitude-based price; not string resource ids, float prices, per-NPC
  trade timers, or immediate trade commits.

### Checklist

- [ ] `trade` behavior content with its gain and every classification;
      gain-0 parity sweep extended.
- [ ] Pure sellable-surplus and stack-pick helpers; accepted-category mask
      derived at Slice 63 load.
- [ ] Merchant discovery through a budgeted spatial query with refusal and
      funds filters; trade signals and goal; contract edits.
- [ ] `.sell` action through the emitter with settled-pose reach, refusal
      gate, and integer price limit.
- [ ] Slice 55 alert input for traders.
- [ ] Content: `forager` trade gain; demo provisioner accepts 61's items.
- [ ] Persistence: gain hashed and saved, relative bumps; 64B rows.
- [ ] Bench `ai-action-select-trade`.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`;
      Slice 63 and 56 pointers read "landed in 71D".

### Acceptance checks

- [ ] A forager with surplus selects `trade`, walks into reach, sells; stock
      and coins move in the same step's inventory update; the ledger records
      the trade; the forager returns to foraging.
- [ ] A refusing or broke merchant is never a goal; a farther accepting
      merchant is chosen instead.
- [ ] Merchant discovery cost is flat in total merchant count at three
      sizes and no in-range merchant is ever skipped for count.
- [ ] Gain-0 parity: the sweep matches and a 120-step checksum without
      foragers is unchanged.
- [ ] Serial == threaded gather, emitter output, and pipeline checksum;
      the composite pipeline allocates nothing after reserve.
- [ ] `ai-action-select-trade` recorded; `ai` and `ai-action-select` show
      no regression; `zig build verify` passes.
