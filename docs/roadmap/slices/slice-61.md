## Slice 61: Harvesting And World Resource Nodes

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 56](slice-56.md), [Slice 57](slice-57.md), [Slice 49](slice-49.md), [Slice 41](../archive/slice-41.md), [Slice 45](../archive/slice-45.md) · Before: [Slice 58](slice-58.md), [Slice 63](slice-63.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.**

Goal: resource nodes (bushes, trees, stone) are plain `DataSystem` entities
with integer charges, node-side work progress, and step-scheduled regrowth
that advances wherever the node is. The player (`.interact` on the faced
cell) and AI foragers (`.harvest` from Slice 56's one emitter) go through
one pipeline-owned `HarvestController` at `action_react`. Yields roll
deterministically and arrive in Slice 57 inventories through its transfer
batches. Foraging is emergent: a `need` drive and a `forage` behavior are
Slice 73 content, nearby nodes and `resource` markers resolve the goal, and
a harvest relieves `need` through an affect impulse drained at the same
step's commit seam. No sessions, timers, or per-harvester state.

### Current foundation

- Action bus and player `.interact` capture with a faced cell
  (`src/game/simulation.zig`, `SimulationPipeline.captureActionIntent`);
  `DestructibleController` at `action_react` with a fixed cell-scan budget
  and capacity preflight (`src/game/destructible_controller.zig`).
- Interest markers: `InterestMarkerStore` with kinds
  `investigate | cover | resource | patrol` and `findBestInvestigateMarker`
  (`src/game/world_interest.zig`); AI gathers markers gain-gated in
  `src/game/systems/ai.zig`.
- Affect drive thresholds emit capped crossing events; the pipeline's affect
  event share widens with the drive count (`src/game/simulation.zig`
  `affect_events_per_row_max`).
- Post-commit reactions run from
  `GameDemoState.applyStructuralCommandsAndPostCommitEvents`
  (`src/game/game_demo_state.zig`).
- From earlier slices: 56's emitter, claim set, budget, and step helpers;
  57's `ItemId`, inventories, `TransferBatch`, transfer queue, and pure
  `canAccept` / `canRemove` (57 ships no pipeline wiring for it); 49's seed
  domains; 73's drive and behavior catalogs.

### Architecture notes

- `resource_node` is one appended component, mutually exclusive with
  `destructible`; a node is a static collider reusing existing nav and
  steering invalidation.
- Node kinds are strict JSON content resolved at load (yield item through
  57's catalog, yield range, charges, work per yield, regrow or remove,
  need relief, visuals); the catalog fingerprint joins Slice 46's.
- Node storage starts at what the load places and grows at the commit seam;
  the only fixed ceiling is the `u32` index width, failing loudly at load
  (`.claude/rules/budgets-capacities.md`).
- The spatial node lookup is owned per chunk, so a node create, destroy, or
  move costs its chunk, never a rebuild over every node
  (`.claude/rules/engine-design.md` § Cost model); queries take fixed
  per-query candidate budgets with a deterministic visit order.
- Availability is a pure function of charges, regrow step, and the current
  step, so regrowth needs no sweep for correctness and holds in every world
  at every distance; a fixed per-step refill budget only updates visuals.
- Claim order trade → harvest → destructible (Slice 56); an intent is
  claimed at most once, so `action_react`'s event and structural shares
  count the largest claimant, not the sum.
- Harvest is serial over merged intents in merged order; first accepted
  intent wins a node's yield for the step; NPCs keep an area reserve the
  player does not.
- Grants go through 57's transfer batches with `canAccept` preflight; this
  slice lands the pipeline wiring of 57's transfer queue as its first
  producer.
- One affect-impulse substrate: domain outcomes move drives through a
  per-producer budgeted queue drained after the same step's structural
  commit, so nothing is pending at a step boundary. 63 and 71A add
  producers; never a second substrate (`.claude/rules/simulation.md` § AI
  and affect).
- Yield rolls draw from `seed.derive(.harvest)` (Slice 49).
- New hashed state is classified in Slice 49's lists and saved by Slice 46;
  the node lookup is derived and rebuilt after load.
- VoidLight reference: port the single harvest commit for player and AI,
  the NPC area reserve, the max-yield inventory pre-check, and data-table
  yields and respawns; not thread-local RNG, wall-clock harvest timers,
  shared-mutex spatial maps, string resource ids, biome-count-scaled
  placement, or per-NPC fail counters (frustration impulses replace them).

### Checklist

- [ ] `resource_node` component, store, wiring, validation; store
      `FailingAllocator` proof.
- [ ] Node storage sized from content at load, grown at the seam; `u32`
      width checked at load.
- [ ] Slice 49 classification and Slice 46 section; `SeedDomain.harvest`.
- [ ] Content: berries / wood / stone items with atlas icons; node kind
      catalog with strict loader tests.
- [ ] Node template builder for Slice 58 and a hand-placed demo set with one
      `resource` marker.
- [ ] Per-chunk node lookup with fixed query budgets; a local change touches
      only its chunk.
- [ ] `ActionKind.harvest`; `HarvestController` in the claim order;
      destructible parity unchanged.
- [ ] Slice 57 transfer queue wired into the pipeline as its first
      producer.
- [ ] Harvest resolve, deterministic yield, depletion, regrow or remove,
      visual refill under a fixed per-step budget.
- [ ] `action_react` structural share re-derived for the largest claimant;
      capacity-limit test re-pinned.
- [ ] Affect-impulse substrate with per-producer budgets and the
      commit-seam drain; `FailingAllocator` proof.
- [ ] `need` drive and `forage` behavior as Slice 73 content; forage
      signals over the node lookup and `resource` markers; the harvest
      action emitted through Slice 56's emitter.
- [ ] Forager archetype content; loader rejects foraging without an
      inventory.
- [ ] Stage contract edits; causal test that a harvest at step N lowers
      `need` before step N+1 decides.
- [ ] (added by Slice 67) Event-log line for `harvest_completed`;
      `StringId` text if 67E has landed.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      Emergent AI track (`resource` wired).

### Acceptance checks

- [ ] A forager reaches a bush as `need` rises, yields into its inventory,
      relieves `need`, and returns to wander; the node depletes and refills
      at its regrow step.
- [ ] Three player presses on a tree grant one wood roll; a cell with node
      and crate harvests only; an attack on a node reaches destructible.
- [ ] Same seed and step give the same yield, within `[min, max]`; a
      different seed changes the sequence.
- [ ] Two same-step harvesters yield once (first in merged order); each
      intent is claimed at most once across trade, harvest, destructible.
- [ ] NPC area reserve refuses the last node, the player is exempt; a full
      inventory leaves the node untouched.
- [ ] A node create past the loaded count grows storage; no create is
      refused for capacity.
- [ ] No nodes and zero forage gain give byte-identical AI outputs and
      destructible outputs.
- [ ] Serial == threaded forage selection and emitter output, including a
      capped case; the composite pipeline allocates nothing after reserve.
- [ ] Benches `harvest-forage-query`, `harvest-controller`, and
      `harvest-node-change` (a node change flat across total node count at
      three sizes); `ai` unchanged at zero forage gain.
- [ ] Slice 68A soak rows recorded; `zig build verify` passes.
