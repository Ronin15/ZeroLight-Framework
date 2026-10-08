## Slice 63: Social Relationships And Trade

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 53B](slice-53b.md), [Slice 56](slice-56.md), [Slice 57](slice-57.md), [Slice 57B](slice-57b.md), [Slice 61](slice-61.md) · Before: [Slice 62](slice-62.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: bounded, deterministic social state per world.

- A directed faction-standing matrix over 73's faction content becomes the
  runtime stance source, seeded byte-identically from its baseline
  relations, so crossing a threshold flips perception and AI hostility with
  no new AI code.
- A per-NPC opinion ledger, sized by archetype content, tracks individuals.
- A `SocialController` turns trade, gift, theft, and combat facts into
  standing and ledger deltas plus affect impulses on Slice 73 drives.
- Merchants trade through action intents with integer pricing in Slice 57
  coins, under a live-modal trade screen on Slices 53B and 57B.

### Current foundation

- `Faction` is a closed enum of 4 tags with a const symmetric
  `relationship_matrix` and `stance()` (`src/game/faction.zig`); hot call
  sites are perception's candidate visitor and player fold-in
  (`src/game/systems/perception.zig`) and AI's cohere friendly filter
  (`src/game/systems/ai.zig`). 73 makes factions content.
- State-stack presets `gameplay`, `modal_overlay`, `pass_through_overlay`
  (`src/app/state.zig`); modal push with a borrowed pointer into the state
  below (main menu → settings menu).
- From earlier slices: 56's claim set and order (trade first) and combat
  events; 57's item `value`, coins, transfer batches, and `canAccept` /
  `canRemove` / `canRemoveCoins`; 57B's `PendingPlayerActions`,
  `live_modal_overlay`, toast, and replay action records; 61's affect-impulse
  substrate, `harvest_completed` ownership facts, and transfer wiring; 73's
  drive catalog and factions.

### Architecture notes

- Two relationship tiers: the faction matrix (directed, clamped
  `[-100, 100]`, ±50 stance bands, diagonal locked) and the per-NPC ledger.
  `attitude(npc, subject)` is standing plus ledger.
- Ledger size is content per archetype, never a fixed slot count
  (`.claude/rules/budgets-capacities.md`).
- Stance changes apply only at the commit seam and are read next step; the
  stance lookup stays one index on the hot path.
- Merchant profiles are strict content (markup, sell rate, refusal
  threshold, accepted categories, stock); the catalog fingerprint joins
  Slice 46's.
- Pricing is pure integer math shared by the UI preview and the sim, every
  product widened before it forms, with a comptime no-overflow proof
  against 57's value and quantity bounds.
- Buy, sell, and give are action intents claimed first at `action_react`;
  each revalidates (alive, level, reach, refusal, quote against the
  intent's price limit, stock, capacity, funds against this step's queued
  transfers, accepted category) and applies through one all-or-nothing 57
  transfer batch; no session state in the sim.
- Adding `ActionIntent` fields extends 57B's replay records and bumps the
  replay format relative to live (Tables T1–T6).
- Social deltas net in event order and emit commands in ascending order;
  affect impulses go through 61's substrate under a new producer budget;
  combat reputation reaches feelings through stance → perception.
- Per-step budgets are fixed counts; new hashed state is classified in
  Slice 49's lists and saved by Slice 46 (Ground Rules).
- The trade screen reads sim state read-only and only enqueues intents;
  session validity is checked in the menu's fixed `update`
  (`.claude/rules/input-state.md`).
- Out of scope: guard theft alert (71A), AI selling (71D).
- VoidLight reference: port the directed standing with incident deltas
  (assault −10, kill −30, theft −25, gift +15), buy 1.2 / sell 0.6 with
  ±30% attitude modifier, refusal below −50, emotion deltas as impulses,
  and the stance-changed event; not float prices with rollback chains,
  unbounded memory sums per query, immediate dispatch, string-keyed UI in
  the controller, or controller session state.

### Checklist

- [ ] Faction relations on `DataSystem`: baseline seeded from 73's faction
      content, thresholds, the standing-adjust command with widened clamp,
      stance cache, and `faction_stance_changed`.
- [ ] Slice 49 classification and Slice 46 sections (standing hashed, cache
      rebuilt on load; ledger and merchant stores hashed).
- [ ] Perception and AI stance sites read the runtime relations.
- [ ] Social ledger component sized by archetype content, with replacement
      tests and a `FailingAllocator` proof.
- [ ] Merchant component and strict profile catalog; demo merchants.
- [ ] Integer pricing module with table tests and the comptime overflow
      proof.
- [ ] Buy / sell / give intents and fields; replay record extension and
      relative format bump with round-trip test; `TradeController` first in
      the claim order.
- [ ] Trades and gifts through 57 transfer batches with step-queue
      preflight; a queued trade batch never fails at apply.
- [ ] Trade events and stats; (added by Slice 67) event-log lines and
      `StringId` text.
- [ ] Trade screen on 53B / 57B with headless tests (selection, quantity,
      quote matches sim, submit, auto-close).
- [ ] `SocialController` stage after inventory update with the delta table
      and the `.social` impulse producer.
- [ ] Combat rows on 56's events.
- [ ] Pipeline-owned structural share for standing and ledger commands;
      capacity-limit test re-pinned.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      `docs/state-stack-and-input.md`.

### Acceptance checks

- [ ] With baseline relations, perception, cohere, and arbitration outputs
      are byte-identical to the const-stance path.
- [ ] Driving the player's standing with `ally` below −50 flips ally
      perception to hostile next step, and timid allies flee with no AI code
      change.
- [ ] Buy and sell move goods and coins atomically; each failure (funds,
      stock, full, refused, reach, price changed) rejects with no partial
      transfer; two same-step buys of the last stock: first wins.
- [ ] Each intent is claimed at most once across trade, harvest, and
      destructible.
- [ ] Trade and gift move ledger affinity and lower merchant aggression on
      the next appraisal.
- [ ] Serial == threaded perception and AI with non-baseline relations; a
      replay with UI trades verifies; the composite pipeline allocates
      nothing after reserve.
- [ ] Bench `social-react` (cost linear in events); no perception or AI
      regression; `zig build verify` passes.
- [ ] Manual / `gpu-smoke`: the trade screen renders, navigates by keyboard
      and gamepad, and closes when the merchant walks away.
