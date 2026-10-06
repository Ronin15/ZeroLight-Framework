## Slice 61: Harvesting And World Resource Nodes

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56](slice-56.md), [Slice 57](slice-57.md), [Slice 40](../archive/slice-40.md), [Slice 45](../archive/slice-45.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Depends on archive **40/45** (action-intent bus +
domain-controller pattern), archive **41** (interest markers; this slice wires
the reserved `resource` kind), **33** (archetype JSON), **49**
(`seed.derive(.harvest)` for yield rolls; this slice appends
`SeedDomain.harvest = 7`), **56** (the `ai_action_select` stage this slice adds
its `.harvest` arm to, and the `ActionClaimSet` / `action_claims` claim set),
and **57** (`ItemId`, inventory component, the `InventoryTransferQueue` /
`TransferBatch` substrate with pure `canAccept` and `applyTransferBatch`, and
`inventory_state`; this slice is that substrate's first producer and lands its
pipeline wiring). **58**
owns world resource-node *placement* (58 lands after this slice and calls
`resourceNodeTemplate`); this slice ships the node runtime, the placement
template builder, and a hand-placed demo set. **59** season scaling of regrowth
is a deferred consumer, not a dependency. Must land before **63** (theft
reputation reads `harvest_completed`).

Goal: resource nodes (bushes, trees, stone) are plain `DataSystem` entities
with integer charges, node-side work progress, and step-scheduled regrowth. The
player (`.interact` on the faced cell) and AI foragers (`.harvest` with an
explicit target, emitted by Slice 56's `ai_action_select`) go through one
pipeline-owned `HarvestController` at `action_react`. Yields are rolled
deterministically and granted into Slice 57 inventories through Slice 57
`TransferBatch`es. Foraging is an emergent arbitration behavior: a new `need`
affect drive scores a new `forage` behavior, nearby available nodes and
`resource` interest markers resolve the goal, and a successful harvest relieves
`need` through an affect impulse drained at the same step's commit seam (the
next step's appraisal reads it). No sessions, timers, or per-harvester state
live in the controller.

### Current foundation (do not rebuild)

- Action-intent bus: `ActionKind` / `ActionIntent` / `action_intent_live_capacity = 64`
  (`src/game/simulation.zig:478-501`), `tryAppendActionIntent` one range per
  append (`simulation.zig:787`), player rising-edge `.interact` with faced cell
  (`simulation_pipeline.zig:896-926`).
- Controller pattern: `DestructibleController.process` at `action_react`. It has
  a fixed pending scratch, a fixed `destructible_cell_scan_budget = 256`, and it
  preflights structural and event capacity before writing.
  (`destructible_controller.zig:36,75-170,263-323`); stage method
  `stageActionReact` (`simulation_pipeline.zig:1283`); contract
  (`simulation_pipeline.zig:225-229`); `external_resources`
  (`simulation_pipeline.zig:161`).
- From Slice 56 (lands first): the generic threaded `ai_action_select` stage
  (one exhaustive per-kind qualification switch, shared
  `ai_action_budget_per_step = 48` with rotating deterministic deferral) and
  `ActionClaimSet = std.StaticBitSet(action_intent_live_capacity)` held in
  `StepState` as the `action_claims` resource written by `action_react`.
- From Slice 57 (lands first, `src/game/inventory_transfer.zig`): the types
  `TransferBatch` (up to 4 `ItemDelta` plus 2 `CoinDelta`; one-sided grants via
  `TransferBatch.grant(entity, item, count)`), `InventoryTransferQueue` (fixed
  `[inventory_transfer_capacity = 2 * action_intent_live_capacity]TransferBatch`,
  `tryAppend(batch) bool`), the pure `canAccept(view, pending, entity, item,
  count)` / `canRemove(...)` queries over committed slots plus the queue, and
  `InventoryController.applyTransferBatch(batch) bool` (all-or-nothing, counted
  in `transfers_rejected`). Slice 57 deliberately ships **no** pipeline wiring
  for it (no dead resource tag); the first producer lands it (this slice).
  `inventory_state` is written by `inventory_update`.
- From Slice 56 (lands first): `simulation_scope.stepAfter(now, delta)`
  (saturating `+|`) and `stepReached(now, due)` for every absolute-step write
  and comparison.
- Event budgets: exhaustive `EventProducerId` + `maxEventsPerStep`
  (`simulation.zig:48-70`); `.action_react` budget is
  `action_intent_live_capacity`.
- Interest markers: fixed 128-slot `InterestMarkerStore`, kinds
  `investigate|cover|resource|patrol`, `findBestInvestigateMarker`
  (`world_interest.zig:25-36,172-204`); AI gathers them gain-gated in
  `writeAiSeparationJob` (`systems/ai.zig:1061-1092`) with fixed
  `interest_marker_query_radius = 400` (`ai.zig:282`).
- Arbitration: `behavior_count = 5` literal, `Signals`, drive×behavior table,
  `perceptionTerm`, `scoreBehaviors`, `resolveGoal`
  (`systems/arbitration.zig:24,34-88,111-117,174-236,411`).
- Affect: `AiAffectDrive` (4 drives) + `AiAffect` cold/hot columns
  (`data_system/types.zig:601,634-652`), `combineDrive` lerp-to-baseline
  (`systems/affect.zig:483-492`), `above_threshold_mask: u8` (8-drive headroom).
  The Emergent AI Track Overview runbook ("How to add a new feeling") governs
  adding a drive. `AffectSystem` caps crossings at `max_events_per_step`
  (`affect.zig:413`); the pipeline passes the derived share
  `affect_events_per_row_max × AiAffect rows` (`simulation.zig`, Slice 72 C4),
  where `affect_events_per_row_max` is
  `@typeInfo(AiAffectDrive).@"enum".field_names.len`, so a new drive widens the
  share automatically. The demo's `capacity_limit` test pins a literal
  (`game_demo_state.zig:2156`).
- Contact, trigger, and intent capacity: `estimateContactCapacity(mover_count +
  obstacle_count + 1)` and the trigger estimate (`game_demo_state.zig:127-135`)
  feed `reserveStreams` and `.contact_capacity`.
- Components: `Component enum(u5)`, 14 of 32 tags used today
  (`data_system/types.zig:61-76`); Slices 56, 56B, and 57 append theirs first.
  Tags are appended in landing order and never pinned in slice text. Dense MAL
  store pattern (`data_system/destructible.zig`); `EntityTemplate` /
  `StructuralCommand` (`types.zig:740-808`); `StructuralCapacityNeeds`
  (`data_system/structural.zig:45-100`).
- Archetypes: `AiArchetypeId` closed enum + strict loader
  (`ai_archetypes.zig:50-244`); demo cycle `demo_archetype_cycle_len =
  archetype_count` with `comptime assert len == 8`
  (`game_demo_state.zig:1003-1027`).
- RNG: stateless `mix64` / `boundedU32` (`src/core/rng.zig:21,48`); step counter
  `SimulationScopeSystem.currentStep()` (`systems/simulation_scope.zig:181`),
  `step_count: u32` with a plain non-wrapping `+= 1` (`:168`).
- Post-commit reaction seam: `applyStructuralCommandsAndPostCommitEvents`
  (`game_demo_state.zig:653-669`); steering's retained static-obstacle cell
  snapshot is the model for a commit-invalidated static index
  (`systems/steering.zig:181-198,561-600,1403`).

### Architecture notes

**Owners / new modules**

- `src/game/data_system/resource_node.zig`: `ResourceNodeStore` (MAL, row per
  index) plus validation. It is fronted by `data_system.zig`.
- `src/game/resource_nodes.zig` (game layer, Slice 33 loader shape):
  `ResourceNodeKindId`, `ResourceNodeKindCatalog` (JSON → dense enum table),
  `ResourceNodeIndex` (commit-rebuilt sorted cell index), and
  `resourceNodeTemplate(kind, level, pos, owner)`, the `EntityTemplate` builder
  Slice 58 and the demo call.
- `src/game/harvest_controller.zig`: pipeline-owned `HarvestController`. It
  owns the index and its rebuild scratch, the per-step pending scratch, and the
  regrowth sweep. It holds no per-harvester state.
- `src/game/systems/affect.zig`: `AffectImpulse` substrate (below). It is owned
  by `AffectSystem`. Slice 61 owns the only affect-impulse substrate.
- `assets/world/resource_nodes.json` (installed like `assets/ai/archetypes.json`).
- Content: `berries`, `wood`, and `stone` entries appended to Slice 57's
  `items.json`, with icons added to the `grim_items` atlas through
  `docs/atlas-asset-workflow.md`. Without them the node catalog fails with
  `UnknownItem`.

**Component and storage: `Component.resource_node`** (one tag, appended after
the last tag present at landing)

```zig
pub const ResourceNodeKindId = enum(u8) { berry_bush, tree, stone_outcrop };
pub const ResourceNode = struct {
    kind: ResourceNodeKindId,
    charges: u8,          // yields left; 0 = depleted
    work_progress: u8,    // work units toward the next yield, < kind.work_per_yield
    owner_faction: ?Faction = null, // ownership for Slice 63 theft; never blocks harvest
    regrow_at_step: StepIndex = 0, // absolute step when a depleted node refills; 0 iff charges > 0
};
```

`ResourceNodeStore.rows: std.MultiArrayList(ResourceNodeRow)` with `entity` plus
the fields above. It is cold and small, with no hot/cold split. Add the full
track-contract set: `Component` tag, `component_masks.resource_node`,
`EntityTemplate.resource_node`, `StructuralCommand.set_resource_node`,
`StructuralCapacityNeeds.resource_nodes` + `TooManyResourceNodeRows`, an
`EntitySlot.resource_node_index`, `set/get/ConstResourceNodeSlice`, and
`validateResourceNode`. Validation: `charges <= kind.charges`;
`work_progress < kind.work_per_yield`; `regrow_at_step == 0` iff `charges > 0`.
A node entity also carries `movement_body` (static, zero speed),
`collision_bounds`, `collision_response{.solid,.static}` when
`blocks_movement`, `world_level`, and either `asset_reference` or
`primitive_visual`. It reuses the existing static-obstacle nav and steering
invalidation with no new nav code. It is mutually exclusive with `destructible`
(validation error `ResourceNodeAndDestructible`).

- **World-sized capacity.** `resource_node_capacity` is sized from the loaded
  world, never a fixed number.
  - It is the number of node creates the load path queues: Slice 58
    `GeneratedNodes.len` + Slice 69A socket nodes + the demo's
    `placeDemoResourceNodes`, or the node rows of a Slice 46 save.
  - `GameDemoState.initWithWorld` computes it before the first structural
    commit and passes it to `HarvestController.reserve(resource_node_capacity)`.
    The store, the index, and its rebuild scratch reserve to it at load, so
    nothing grows after reserve.
  - No runtime node producer exists today (regrowth refills in place;
    `remove` only destroys). A later runtime producer grows the store, index,
    and scratch geometrically at the structural-commit seam (main thread);
    refusal stays only at the `u32` ceiling.
  - The only fixed ceiling is the format one: index entries carry
    `dense_row: u32`, so a capacity above `maxInt(u32)` fails the load
    (`TooManyResourceNodeRows`), and a create that would pass it is refused
    and counted as `resource_node_creates_refused` (the Slice 57 world-item
    precedent).
- **Collider populations.** Nodes carry `collision_bounds` and join the
  collision broadphase as static proxies. The demo's body count used for
  contact, trigger, and intent capacity (`game_demo_state.zig:127-135`) and the
  pipeline's `movement_body_capacity` and spatial-index reserves add the term
  `resource_node_capacity` (an initial size only; `syncPopulationCapacity` is the growth point — Slice 72 C3).
- **Slice 49 checksum classification (and the matching Slice 46 save
  section):** `ResourceNodeStore` is hashed (`?Faction` folds as an enum).
  `ResourceNodeIndex` is excluded (commit-derived, owned by
  `HarvestController`; rebuilt after load).

**Kind catalog (`assets/world/resource_nodes.json` → `ResourceNodeKindCatalog`)**

```json
{ "resource_nodes": [
  { "id": "berry_bush", "yield_item": "berries", "yield_min": 1, "yield_max": 3,
    "charges": 3, "work_per_yield": 1, "on_depletion": "regrow", "regrow_seconds": 120,
    "need_relief": 0.6, "interact_size": [28, 24], "blocks_movement": true,
    "visual": { "available_color": [0.2,0.6,0.25,1], "depleted_color": [0.35,0.3,0.2,1] } },
  { "id": "tree", "yield_item": "wood", "...": "work_per_yield 3, regrow 600 s" },
  { "id": "stone_outcrop", "yield_item": "stone", "...": "on_depletion remove" } ] }
```

The loader is strict (`ignore_unknown_fields = false`). Each entry declares its
`id`; duplicate or missing ids fail. `yield_item` resolves through Slice 57's
item catalog at load (`UnknownItem`). Bounds: `1 <= yield_min <= yield_max <=
64`, `1 <= charges <= 64`, `1 <= work_per_yield <= 32`, and `need_relief` in
`(0, 1]`. `on_depletion` is `regrow` (requires `0 < regrow_seconds <= 3600`,
converted once to `regrow_steps = round(s * 60)`) or `remove`, which emits
`destroy_entity` at zero charges and uses the existing `entity_destroyed` nav
re-mask. `visual` is either primitive colors or `{ sprite, available_entry,
depleted_entry }`. The entry names resolve against the sprite-atlas metadata at
load (`UnknownAtlasEntry`); new art goes through
`docs/atlas-asset-workflow.md`. The hot path sees only enum indices. The catalog
fingerprint joins Slice 46's `content_fingerprint`.

**`ResourceNodeIndex` (commit-rebuilt, read-only during the step)**

- Entries are `{ key: u64, x: f32, y: f32, entity: EntityId, dense_row: u32 }`,
  where `key = level<<48 | cy<<24 | cx`, `cx/cy = floor(center / resource_index_cell_size)`.
  They are sorted by `(key, entity.index)`. There is no per-cell table, so
  storage is O(nodes) and never sized from world extent.
- **Ring count.** A query of radius `r` visits `rings = ceil(r /
  resource_index_cell_size)` rings around the center cell, that is a
  `(2*rings+1)²` block, with one `lower_bound` per cell. A comptime
  `assert(rings <= max_index_query_rings = 2)` guards every radius constant:
  - forage (`forage_node_query_radius = 256`): 1 ring, 3×3 = 9 `lower_bound`s;
  - area reserve (`harvest_area_reserve_radius = 512`): 2 rings, 5×5 = 25
    `lower_bound`s.
- Query: `nearestAvailable(level, x, y, radius, step, budget)`. It visits the
  center cell first, then the rest of the block row-major. Availability is lazy:
  `charges > 0 or stepReached(step, regrow_at_step)`. The result is the nearest
  by `dist²` within `radius`, then lowest `entity.index`. Candidates count
  against the budget in visit order, so truncation is a deterministic prefix,
  not a distance-ordered one. `countAvailableWithin(...)` serves the area
  reserve with the same visit order, the 2-ring block, and an early exit.
- Rebuild runs in `reactToPostCommitResourceEvents(frame, data)`, which
  `GameDemoState` calls beside the nav, perception, and steering reactions. The
  index is dirty when any of these holds:
  - the store count changed;
  - an `entity_destroyed` event's mask has `resource_node`;
  - an `entity_created` entity's live mask has `resource_node`;
  - `component_changed{movement_body|world_level}` hits an entity with
    `resource_node`.

  Value-only `set_resource_node` (every harvest) never rebuilds. `dense_row` is
  valid because swap-remove only happens on a dirty-marking event. The rebuild
  writes into entry and sort scratch reserved to `resource_node_capacity` at
  init; it never allocates.

**Availability and regrowth**

- Availability is a pure function of `(charges, regrow_at_step, step)`, so
  harvest and AI correctness never wait on a sweep. A harvest on a lazily
  regrown node refills `charges = kind.charges` inline. Every absolute-step
  write goes through Slice 56's `simulation_scope.stepAfter` and every
  comparison through `stepReached`.
  `regrow_at_step` is a `step_count`-domain value (`StepIndex`, Slice 49;
  Slice 59 clock role split): regrowth is step-scheduled, not calendar time, so
  a Slice 59 time skip does not regrow nodes.
- Visual and persistent refill: the regrowth sweep at `action_react` scans rows
  starting at `start = @intCast((step * regrowth_sweep_budget) % len)`
  for `regrowth_sweep_budget` rows (wrapping). The product is computed directly
  in `StepIndex` (`u64`, Slice 49), so it overflows only after 2^64 / budget
  steps. The cursor
  is derived from the step, so there is no stored cursor and nothing extra for
  save/load. Each row with `charges == 0 and stepReached(step, regrow_at_step)`
  gets `set_resource_node{charges=kind.charges, work=0, regrow_at_step=0}` plus
  the available visual. Visual latency grows with node count, but correctness
  does not.

**Action intents and the claim policy**

- Append `ActionKind.harvest` (AI with an explicit `target`). The player keeps
  `.interact`.
- Reuse Slice 56's `ActionClaimSet` / `action_claims`. `stageActionReact` runs
  its controllers in Slice 56's fixed claim order: trade (63) → harvest (61) →
  destructible (45). This slice inserts `harvest.process(..., &claims)` before
  `destructible.process(..., &claims)`; the destructible controller already
  skips claimed intents. An intent is claimed by at most one controller, so the
  shared `.action_react` event budget (64) still covers harvest and
  destructible events together. A test asserts this.
- Harvest accepts `.harvest`, and `.interact` only when the target or faced cell
  resolves to a node. Cell resolve uses the index cell for the faced cell plus
  an AABB-overlap check, capped at `harvest_cell_candidate_budget`, with lowest
  entity index then generation on ties. `.attack` never harvests. With no nodes
  present, destructible output is byte-identical.

**`HarvestController.process`** runs serially on the main thread over merged
intents in merged order: player captures first, then the intents
`ai_action_select` appended (in its deterministic, rotation-selected emit
order).

1. Kind or claim check; resolve the target. It must be alive, hold
   `resource_node`, and be on the harvester's level (missing `world_level` → 0).
2. Reach: point-to-AABB distance from the harvester body center to the node's
   collision AABB `<= harvest_reach`.
3. Availability (lazy, as above).
4. Area reserve applies only to non-`player`-faction harvesters. At least
   `npc_harvest_area_reserve` other available nodes must lie within
   `harvest_area_reserve_radius` (2-ring block). If the scan budget runs out
   first, the reserve counts as violated (conservative).
5. Inventory preflight: Slice 57's pure `canAccept(view, pending, harvester,
   item, kind.yield_max)`, where `pending` is Slice 57's pending view over this
   step's already-queued `TransferBatch`es (including grants this controller
   queued earlier in the same step).
6. Work: `work_progress += 1`. On reaching `work_per_yield`, yield once. At most
   one yield per node per step. Excess same-step work is dropped, so the first
   accepted intent in merged order wins.
7. Yield: `qty = yield_min + boundedU32(harvest_seed, node.index, step,
   harvest_yield_salt, yield_max - yield_min + 1)`, where `harvest_seed =
   seed.derive(.harvest)` is computed once in `SimulationPipeline.init`. Then
   `charges -= 1` and `work_progress = 0`. At zero charges, `regrow` sets
   `regrow_at_step = stepAfter(step, regrow_steps)` (saturating at the
   documented `step_count` horizon) and the depleted visual; `remove`
   emits `destroy_entity`.
8. Outputs, preflighted before any write (the dig/destructible pattern,
   including free `InventoryTransferQueue` slots):
   - a net `set_resource_node` per node;
   - visual swap commands;
   - one Slice 57 grant, `TransferBatch.grant(harvester, item, qty)`, appended
     with `InventoryTransferQueue.tryAppend` (free slots are part of the
     preflight; a `false` return is counted and latches nothing);
     `inventory_update` phase 0 applies it all-or-nothing after revalidation
     later in the same step;
   - a `harvest_completed` event;
   - affect impulses.

Rejections increment `HarvestStats.rejected[reason]`, where
`HarvestRejectReason = { no_target, out_of_reach, unavailable, area_reserve,
inventory_full, no_inventory }`. A rejected harvest by an agent with `AiAffect`
enqueues a frustration impulse (below). The node is untouched.

**`need` drive and the `AffectImpulse` substrate**

- Append `AiAffectDrive.need` (5/8 mask bits). Add the cold
  `baseline_need/decay_rate_need/threshold_need` and hot `need` columns, plus
  validation, slices, and archetype keys, per the runbook. There is no per-step
  appraisal signal: `need` decays toward its baseline. A forager authors a high
  baseline, so `need` regrows after relief. Agents with baseline 0 never feel
  `need`. Threshold edges come from the existing Schmitt path.
- **Affect event share.** A fifth drive needs no capacity edit: the pipeline's
  share is `affect_events_per_row_max × AiAffect rows` (Slice 72 C4), and the
  constant becomes 5 automatically. Only the demo's `capacity_limit` literal test
  (`game_demo_state.zig:2156`) is re-pinned deliberately (+12 at the default 32
  movers).
- `AffectImpulse = { entity: EntityId, drive: AiAffectDrive, delta: f32 }`
  (scalar only). The exhaustive `AffectImpulseProducer = enum { harvest }` has
  a matching `maxAffectImpulsesPerStep(.harvest) = action_intent_live_capacity`.
  `affect_impulse_capacity` is the comptime sum of those budgets.
  `AffectSystem` owns a fixed inline `[affect_impulse_capacity]AffectImpulse`
  buffer plus per-producer counters.
  - Producers call `enqueueImpulses(producer, []const AffectImpulse) !void`,
    which fails with `AffectImpulseBudgetExceeded` past the producer's budget.
    Callers preflight.
  - **Drain at the commit seam.** `GameDemoState.applyStructuralCommandsAndPostCommitEvents`
    calls the pipeline wrapper `reactToPostCommitAffectImpulses(data)`, which
    drains the buffer **after the structural commit of the same step**: main
    thread, enqueue order, alive + `AiAffect` only (entities destroyed by this
    commit are skipped), add then clamp to `[0, 1]`. Entities outside the think
    set also receive it. The buffer is then cleared. The next step's
    `affect_update` appraises the updated drives. No impulse is pending at a
    step boundary, so neither Slice 46 nor Slice 49 sees the buffer.
- Harvest impulses:
  - success: `need -= kind.need_relief`;
  - rejection: `need -= harvest_frustration_relief`. Repeated failure gives up
    deterministically, which replaces VoidLight's per-NPC fail counters and
    backoff.
- Slice 61 owns the only affect-impulse substrate. Slice 63 adds producer
  `.social`. Slice 56 feeds affect through the persistent
  `appraised_damage_total` watermark, an appraisal input column rather than an
  impulse. Never two substrates. (Slice 68B's knockback is a movement column
  under `movement_knockback` and does not reuse this queue.)

**AI forage (arbitration and `ai.zig`)**

- Append `AiBehavior.forage`. `arbitration.behavior_count` becomes
  `@typeInfo(AiBehavior)` derived. Every exhaustive `AiBehavior` switch gains a
  `.forage` arm: `gainFor`, `perceptionTerm`, `memoryTerm`, `resolveGoal`,
  affect fatigue input (forage is not exertion), the debug overlay colour and
  label (`ai_debug_overlay.zig:60-67`), and `simulation_scope.coastableBehavior(.forage)
  = false` (path-following, Slice 55). A `need` threshold crossing raises the
  row to `idle_near` through the drive mask, so a coasting row wakes for it.
- `AiAgent.gain_forage: f32 = 0` gets a cold column, `max_ai_gain` validation,
  and archetype key `gain_forage`.
- Weight table, after the change (rows = drives, cols = wander, pursue, flee,
  investigate, cohere, forage):
  - fear `{0,-0.5,3,0,-0.3,-0.5}`
  - curiosity `{0.3,0,0,2.5,0.5,0}`
  - aggression `{0,3,0,0,-0.3,0}`
  - fatigue `{2,-1,-1,0,0,-0.5}`
  - need `{0,0,0,0,0,3.0}`

  Gain 0 zeroes forage for every existing archetype. Wander is always `>= 0` at
  index 0, so the lowest-index tie-break keeps parity.
- `Signals` adds `need`, `resource_node_present/entity/x/y`, and
  `resource_marker_present/x/y`.
  - `perceptionTerm(.forage)`: `forage_node_bonus = 0.35` when a node is
    present; else `forage_marker_bonus = 0.2` when a `resource` marker is
    present; else 0.
  - `resolveGoal(.forage)`: the node, else the marker, else invalid. Invalid
    falls back to the existing wander noise, which reads as searching.
- Gather: in `writeAiSeparationJob`, gated on `gain_forage > 0` exactly like the
  investigate gate, read-only:
  - `ResourceNodeIndex.nearestAvailable(level, pos, forage_node_query_radius,
    step, forage_node_candidate_budget)`;
  - then `InterestMarkerStore.findNearestMarker(.resource, ...)`, a generalised
    `findBestInvestigateMarker`, which stays as a thin wrapper.

  Results go into a new grouped `RowForage` column, including the node AABB for
  reach.
- **Action emission** reuses Slice 56's `ai_action_select` stage and adds the
  `.harvest` arm to its exhaustive per-kind qualification switch. A row
  qualifies when `active_behavior == .forage`,
  `ResourceNodeIndex.nearestAvailable(level, settled pose, harvest_reach, step,
  forage_node_candidate_budget)` returns a node, and the node is within
  `harvest_reach` of the settled pose. It emits `{ entity, kind = .harvest,
  target = node, level }` through 56's single append path and shares 56's
  `ai_action_budget_per_step` and rotating deferral (`ai_actions_deferred`). A
  deferred agent retries on its next think. There is no second AI emitter and
  no write of `action_intents` from `ai_decide`.
- The `cover`/`patrol` marker kinds stay unconsumed.

**Stage contract (`simulation_pipeline.zig`): no new `StageId`**

- **Slice 57 transfer wiring (landed here, as the first producer):**
  `PipelineResource.inventory_transfers` (written by `action_react`, read by
  `inventory_update`), the `StepState.inventory_transfers:
  InventoryTransferQueue` instance (cleared in `beginStep`), and the
  `inventory_update` phase 0 call that drains it in append order through
  `applyTransferBatch` before Use/Pickup/Loot, all using Slice 57's types
  unchanged.
- New `PipelineResource` tags:
  - `resource_nodes`: the `DataSystem` node columns plus the index, mutated
    only at commit. Add it to `external_resources`.
  - `affect_impulses`: written by `action_react` (and by Slice 63's
    `social_react`), consumed at the commit seam, external to the stage graph
    like `structural_commands`. No stage reads or carries it.
- `ai_decide` and `ai_action_select`: `carried += {resource_nodes}`.
- `action_react` (already reads `action_intents` and writes `action_claims`
  after Slice 56):
  - `writes += {inventory_transfers, affect_impulses}`;
  - `carried += {resource_nodes, inventory_state}` (`inventory_state` is
    written later in the step by `inventory_update`).
- `inventory_update`: `reads += {inventory_transfers}`.
- `affect_update`: unchanged.
- Update the existing contract test `stage contracts split event families...`
  (`simulation_pipeline.zig:1350-1353`) to match.
- Causal test: a harvest at step N lowers `need` (drained at step N's commit
  seam) before `ai_decide` reads drives on step N+1.

**Budgets, thresholds, and the one capacity** (budgets and thresholds are fixed
constants, never derived from world, map, or node count;
`resource_node_capacity` is the world-sized capacity)

| Constant | Value | Reasoning |
| --- | --- | --- |
| `resource_node_capacity` | nodes placed at load (`u32` dense-row ceiling) | Capacity, not a budget: sized from the loaded world (worldgen + sockets + demo, or the save) and reserved at load for store, index, and rebuild scratch; a later runtime producer grows them at the structural-commit seam; refusal (counted) only at the `u32` ceiling |
| `resource_index_cell_size` | 256 px | Forage radius 256 ⇒ 1 ring (3×3, 9 binary searches); reserve radius 512 ⇒ 2 rings (5×5, 25) |
| `max_index_query_rings` | 2 | Comptime bound on `ceil(radius / cell)` for every query radius |
| `forage_node_query_radius` | 256 px | Beyond vision (192), inside marker radius (400): markers are the long-range attractor, nodes the local target |
| `forage_node_candidate_budget` | 32 | Per forager think; deterministic prefix in visit order (destructible-scan precedent) |
| `harvest_cell_candidate_budget` | 16 | Player faced-cell resolve |
| `harvest_reach` | 48 px | VoidLight `HARVEST_RANGE`; > one 32 px tile so a faced adjacent cell always passes |
| `harvest_area_reserve_radius` / `npc_harvest_area_reserve` / `harvest_reserve_scan_budget` | 512 px / 1 / 32 | VoidLight reserve rule over the 2-ring block; budget exhaustion ⇒ refuse |
| `regrowth_sweep_budget` | 64 rows/step | Visual-refill latency only; cursor widened to `u64` |
| yields per node per step | 1 | Canonical first-wins |
| `harvest_frustration_relief` | 0.25 | ~3 failed attempts fall below the default 0.6 threshold |
| affect impulses (harvest producer) | 64 | One per intent |
| transfer batches | ≤ 64 / step | One grant per accepted intent, within Slice 57's `inventory_transfer_capacity` (128) |
| structural headroom | `64*2 + 64*2 = 256` cmds/step | Node set + visual per intent (grants are transfer batches, not structural commands); refill + visual per sweep row; reserved at state init |

**Events.** `harvest_completed { harvester, node, kind, level, cell_x, cell_y,
item: ItemId, quantity: u8, owned: bool, owner: Faction, depleted: bool }` is a
scalar payload at `.domain_reaction`. It joins `world_events` with a
`SimulationEventStats` counter, a `record`/`addProduced` arm, and a perf metric.
It reuses the `.action_react` producer budget. Rejections are stats, not events.

**Determinism contract.** The inputs are:

- merged `action_intents` order;
- committed `DataSystem` and inventory state, plus this step's queued transfer
  batches;
- `currentStep()`, the same counter for the AI availability check and the
  controller;
- `harvest_seed = seed.derive(.harvest)` (`SeedDomain.harvest = 7`).

The controller, the index rebuild, the sweep, and the impulse drain are all
serial. AI forage selection and the `.harvest` qualification are row-local and
read-only. Counts and work are integers. There is one RNG draw per yield, keyed
`(node.index, step, salt)`. The regrowth-sweep cursor is derived from the step
(widened to `u64`). Serial and threaded AI produce identical `RowForage`
columns and identical `ai_action_select` candidates.

**Deferred (named, not silently dropped):** harvest noise stimulus. It needs a
`StimulusKind` producer through `SensoryBus`'s deferred path, because
`action_react` runs after perception. Also deferred: Slice 57 equipment tool
gating, Slice 59 seasonal regrowth multipliers (and moving regrowth onto
`game_ms` if a "sleep regrows nodes" consumer appears), dropping overflow yields
as Slice 57 world items, and NPC↔merchant selling of harvested goods (a future
`ai_action_select` trade arm for Slice 63).

### Checklist

- [ ] `ResourceNode` component (one appended tag) + MAL store + structural/template/capacity/slot wiring + validation; store `FailingAllocator` append proof.
- [ ] World-sized `resource_node_capacity` (the load path's node count, computed in `GameDemoState.initWithWorld` before the first commit; `u32` dense-row ceiling): store, index, and rebuild scratch reserved to it at load; refusal only at the `u32` ceiling, counted as `resource_node_creates_refused`. Test: the derived capacity equals the placed count on a minimal fixture. `FailingAllocator` proof: after the load reserve, creating exactly `resource_node_capacity` nodes, committing them, and rebuilding the index allocate nothing.
- [ ] Collider capacity: add `resource_node_capacity` to the demo body count feeding contact, trigger, and intent capacity (`game_demo_state.zig:127-135`) and to the pipeline's `movement_body_capacity` and spatial-index reserves (an initial size only; `syncPopulationCapacity` is the growth point — Slice 72 C3).
- [ ] Slice 49 checksum classification + Slice 46 save section: `ResourceNodeStore` hashed; `ResourceNodeIndex` excluded (rebuilt after load).
- [ ] `src/game/simulation_seed.zig`: append `SeedDomain.harvest = 7` (Slice 49 reserved value); `harvest_seed` derived once at pipeline init.
- [ ] Content: `berries`, `wood`, `stone` in Slice 57's `items.json` with `grim_items` icons (atlas workflow); `zig build assets-lint` passes.
- [ ] `ResourceNodeKindId` + strict JSON catalog loader; tests:
  - good file;
  - unknown key;
  - unknown item;
  - `yield_min > yield_max`;
  - zero charges or work;
  - regrow out of range;
  - `remove` with `regrow_seconds`;
  - duplicate and missing ids;
  - unknown atlas entry.
- [ ] `resourceNodeTemplate` builder; demo `placeDemoResourceNodes` (all 3 kinds) + one `resource` interest marker; Slice 58 consumes the builder.
- [ ] `ResourceNodeIndex` build, query (ring count from radius, comptime `max_index_query_rings`), and count; rebuild-trigger rules; `reactToPostCommitResourceEvents` pipeline wrapper called from `applyStructuralCommandsAndPostCommitEvents`; `FailingAllocator` proofs for the query and for a rebuild at `resource_node_capacity`.
- [ ] `ActionKind.harvest`; `HarvestController` inserted before destructible in Slice 56's claim order using 56's `ActionClaimSet`; destructible parity tests are unchanged.
- [ ] Slice 57 transfer wiring: `PipelineResource.inventory_transfers`, the `StepState` queue instance, and `inventory_update` phase 0 via `applyTransferBatch`; a two-sided batch with insufficient funds still applies nothing (57's test, now through the pipeline).
- [ ] `HarvestController.process`, steps 1–8 above (grants via `TransferBatch.grant` + `tryAppend` with `canAccept` preflight), plus the regrowth sweep with the `u64`-widened cursor and `stepAfter`/`stepReached`.
- [ ] `AiAffectDrive.need` end to end via the runbook: columns, validation, archetype keys, debug bar, table row; the affect share widens automatically through `affect_events_per_row_max` (Slice 72 C4); the demo `capacity_limit` literal is re-pinned.
- [ ] `AffectImpulse` substrate in `AffectSystem`; per-producer budgets; `reactToPostCommitAffectImpulses` drain at the commit seam; `FailingAllocator` proof.
- [ ] `AiBehavior.forage`, `gain_forage`, the `Signals` fields, the weight column, `resolveGoal`, `coastableBehavior(.forage) = false`; generalised `findNearestMarker`; `RowForage` gather; `.harvest` arm in `ai_action_select`.
- [ ] Archetypes:
  - append the `forager` archetype (slot 8);
  - decouple `demo_archetype_cycle_len` to a literal 8 (`game_demo_state.zig:1003`);
  - the demo spawns 4 foragers near demo nodes;
  - loader rejects `gain_forage > 0` without a Slice 57 inventory block (`ForageWithoutInventory`).
- [ ] Stage contract edits, test updates, the N→N+1 relief causal test; `SimulationPipelineStats` harvest counters and perf metrics.
- [ ] Bench groups (one `BenchmarkGroup` per workload in `src/benchmarks/harvest.zig`, sizes in `defaultItemCounts`, registered in `runner.zig`):
  - `harvest-forage-query` (2048 agents × 4096 nodes);
  - `harvest-controller` (64 intents);
  - `harvest-index-rebuild` (default items 1024 / 4096 nodes; the fixture reserves its capacity to the item count).
- [ ] Docs:
  - `architecture.md` (controller list, component, index, impulse substrate);
  - `simulation-tiers-and-pipeline.md` (`action_react` composition and claims, `harvest_completed`, impulses and the commit-seam drain, contract changes);
  - the Emergent AI track table: `resource` is wired; `need` is the first post-31 drive.
- [ ] (added by Slice 67) Event-log feed arm for `harvest_completed` per Slice
  67B. Every `SimulationEventPayload` arm this slice adds gets a line or
  `=> null` in the same change.
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and event-log
  text as `StringId`s with English `StringSpec` entries in
  `src/assets/strings.zig`, value-bearing text through `strings.format`;
  67E's comptime table validation passes. Otherwise 67E migrates it.

### Acceptance checks

- [ ] In a minimal fixture world, a `forager` reaches a berry bush as `need`
  rises, yields berries into its inventory, and drops below threshold. It then
  returns to wander. The node depletes and refills on exactly `regrow_at_step`.
- [ ] Three player R presses on a `tree` (`work_per_yield = 3`) grant one wood
  roll. An R press on a cell with both a node and a crate harvests only; attack
  on a node falls through to the destructible path.
- [ ] Same seed and step give the same yield; across steps the yield varies and
  stays within `[min, max]`. A different session seed changes the yield
  sequence.
- [ ] Two same-step harvesters on one node produce one yield, and the first in
  merged order wins. Each intent is claimed at most once across trade, harvest,
  and destructible (shared event budget test).
- [ ] NPC area reserve refuses the last node while the player is exempt; a
  second available node 256–512 px away (outer ring) satisfies the reserve;
  inventory full refuses and leaves the node untouched.
- [ ] Regrowth sweep at `step = maxInt(u32)` and `maxInt(u32) - 1` computes the
  same cursor as the `u64` reference with no overflow.
- [ ] A node create at `resource_node_capacity` is refused and counted.
- [ ] No nodes and `gain_forage = 0` give byte-identical AI scores, behaviors,
  and navigation intents versus pre-slice fixtures. Destructible outputs are
  unchanged.
- [ ] Serial == threaded for forage selection and for `ai_action_select` with a
  capped (rotating) case. The test crosses ranges.
- [ ] The composite `pipeline.update` with foragers and nodes allocates nothing
  after reserve (`FailingAllocator` on frame streams, transfer queue,
  impulses, index query, and index rebuild).
- [ ] `zig build bench -- --group harvest-forage-query`, `--group
  harvest-controller`, and `--group harvest-index-rebuild` recorded, and
  `--group ai` shows no regression at `gain_forage = 0`.
- [ ] (added by Slices 68A–68C) Run the Slice 68A §3 re-baseline procedure and record
  this slice's schema rows (the harvest rows of this slice's own metrics).
- [ ] `zig build verify` passes.

### VoidLight reference

**Port:**

- `HarvestCommit::commit` as the single commit path for player and AI: a
  generation-checked target, deplete, roll, event.
- `NPC_HARVEST_RESERVE` / `SCARCITY_RADIUS` as the area-reserve rule.
- `AIManager::commitQueuedHarvests`: lowest-first per-node arbitration
  (ZeroLight: merged-intent order) and the max-yield inventory pre-check before
  depletion.
- `HarvestableSnapshotView`: a commit-rebuilt sorted cell index with
  binary-search validation, rebuilt only on version change (ZeroLight: dirty
  rules, no per-cell table).
- `DepositConfig` yield, respawn, and type tables, as a JSON enum table.
- Forage need pressure, giving up on repeated failure, and the merchant leash.
  The leash is Slice 71A (`merchant` `gain_return_home`; a merchant is not a
  guard unless it has `gain_pursue > 0`).

**Do not port:**

- `thread_local std::mt19937(random_device)` yield rolls and cooldown jitter.
- `steady_clock` and float `deltaTime` harvest timers, including movement-cancel
  sessions. Node-side work progress replaces them.
- `HarvestableData.currentRespawn`, which is set but never ticked down in
  VoidLight: regrowth was dead code there.
- `unordered_map` spatial cells with `shared_mutex` and atomic counters in
  `WorldResourceManager`.
- String resource ids and `getHarvestTypeForResource` string chains on spawn.
- `WorldHarvestInit` counts scaled by biome tile counts (`forestTiles / 40`).
  Placement belongs to Slice 58; this slice sizes its store from what the
  load places.
- Per-NPC `NpcNeedData` sidecar fail counters and exponential backoff. The
  `need` drive and frustration impulses replace them.
- `ResourceChangeEvent` string reason tags.

