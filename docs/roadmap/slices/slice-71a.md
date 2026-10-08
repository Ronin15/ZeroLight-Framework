## Slice 71A: AI Behavior Parity — Patrol, Follow, Guard

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 56](slice-56.md), [Slice 61](slice-61.md), [Slice 62](slice-62.md), [Slice 63](slice-63.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Depends on **55** (the `coastableBehavior` exhaustive
switch and the `ai_decide_gather` alert predicate), **56** (`entity_damaged`
combat events, `stepAfter`/`stepReached`), **61** (`AiBehavior.forage`,
derived `behavior_count`, the `need` drive, and the `AffectImpulse` substrate
with its exhaustive `AffectImpulseProducer`), **62** (`SpawnAnchorStore`,
`SpawnOrigin`, and the `guard`/`merchant`/`villager` archetypes), and **63**
(`social_react` stage position, `harvest_completed.owned/owner` theft facts
consumed through 61). It lands after 62, the last of these in the merged
order. No `SeedDomain` is added: every 71A decision is a pure function of
state, the step, and `entity.index`.

It composes with two slices that may land before or after it (consistency
F17; see "Composition with 68A and 68B" below):

- **68A** (shared halo table, decide-only gather);
- **68B** (retaliation memory).

Cross-slice tables: 71A bumps `checksum_format_tag` (T6) and the save
`format_version` (T3, v12 in the merged order) by one, relative to the live
value. It appends the `ai_post` tag (T5: 25 of 32) and the `guard_alarm`
stage (T4: position 26, between `social_react` and `tier_policy`).

Goal: an agent can **patrol** an authored route of `patrol` interest markers,
**follow** a designated leader, and **guard** a home (a patrol post or its
Slice 62 spawn anchor):

- Beyond a fixed leash, pursue/investigate/forage scores drop to zero.
- A `return_home` behavior brings the agent back.
- A help call raises allied guards' drives and leaves an `alarm` stimulus
  that gives hearers an investigate goal.

All of it is utility + sticky arbitration over new `Signals`. Every new gain
defaults to 0, and at gain 0 every existing agent's scores, behaviors,
intents, and coast decisions are byte-identical to before.

In scope:
- `AiBehavior.patrol` / `.follow` / `.return_home`;
- the `AiPost` component (`leader`, `patrol_route`);
- `InterestMarker.route` / `sequence` and the derived route table;
- the leash and its hysteresis;
- the `guard_alarm` stage (help call), `StimulusKind.alarm`;
- `SpawnAnchorStore.patrol_route`;
- archetype keys and content;
- the debug label and guard alert level;
- the Slice 55 classification.

Out of scope. Each item is either a decided non-goal with its reason or owned
by a named section; none is a backlog line:
- **Autonomous level changes** (an AI choosing a goal on another level) are
  a decided non-goal of the framework AI. Levels change only through plane
  traversal and player-dug ramps (64E). What 71A does own is the other half
  of that policy: every post goal it adds is an **own-level** goal and is
  written with `goal_level = row level` (Goal level row below), so posted
  agents underground never request surface paths. Slice 69A extends the same
  own-level write to every other behavior (its M3 fix).
- **`cover` markers:** owned by Slice 71C.
- **Worldgen-placed patrol routes:** a decided non-goal. Routes are authored
  content, because a route's legs must respect `patrol_dwell_steps` and the
  author's intent for the post. Worldgen anchors reference an authored route
  through Slice 58's anchor JSON `patrol_route` key, which this slice adds.
- **Auto-assigning leaders inside Slice 62 group spawns:** decided.
  Leaders are assigned through `AiPost.leader` at runtime by the spawning
  code after commit. 62 group spawns do not auto-assign, because entity ids
  do not exist until commit.

### Current foundation

- **Arbitration** (`src/game/systems/arbitration.zig`):
  - `behavior_count` (`:24`; Slice 61 makes it `@typeInfo`-derived) and
    `Signals` (`:34-88`). Every field defaults to "no signal".
  - `PersonalityGains` (`:92-98`).
  - Drive×behavior `drive_behavior_weight` (`:111-117`; Slice 61 adds the
    `need` row and `forage` column).
  - Named bonus constants (`:119-134`), `gainFor` (`:136-144`),
    `perceptionTerm` (`:174-194`), and `memoryTerm` (`:196-207`).
  - `scoreBehaviors` = `gain[b] × (Σ drive·weight + perceptionTerm +
    memoryTerm)` (`:214-236`).
  - `selectSticky` (`:260-285`) uses a lowest-index tie-break.
  - `GoalResolution` (`:287-293`) and `resolveGoal` (`:411-419`).
- **AI processor** (`src/game/systems/ai.zig`):
  - Grouped MAL gather row `AiGatherRow` (`:224-248`). It is grouped so the
    MAL comptime field sort stays under the branch quota (`:199-208`).
  - `RowGains` (`:97-103`) and `RowInterest` with the row level (`:158-164`,
    filled at `:759`).
  - Main-thread `gatherAiData` (`:590-765`), whose gain-gated focus is at
    `:652-655`.
  - Threaded `writeAiSeparationJob` with the gain-gated marker scan
    (`:1061-1096`), and fixed `interest_marker_query_radius = 400` (`:282`).
  - `resolveRowArbitration` (`:1252-1365`). Its invalid-goal path degrades
    the row to `.wander` with commitment cleared (`:1349-1364`), and the
    resolved-gain switch is at `:1331-1337`.
  - `priorityForBehavior` (`:1026-1033`).
  - `writeAiIntentsJob` (`:1367-1404`) never writes
    `NavigationIntent.goal_level` (`:1394-1401`; the field defaults to 0 at
    `simulation.zig:471`). The policy comment at
    `simulation_pipeline.zig:1148-1152` ("NPCs stay on the surface until
    autonomous descent lands") is about **cross-level** goals: not seeding the
    player's plane. But the side effect is that a level-1 row's goal on its
    own level is sent as a level-0 goal, which is a cross-level request to the
    surface at those coordinates. Pathfinding serves cross-level requests
    (`pathfinding/system.zig:789-795`), and 64E makes ramps routable.
  - The row level is already gathered: `row.interest.level =
    worldLevelConst(ent) orelse 0` (`ai.zig:759`).
- **Components:**
  - `AiBehavior` (`data_system/types.zig:339-345`), `AiAgent` cold/hot
    (`:351-365`), and `max_ai_gain = 16` (`:368`).
  - `validateAiAgent` and the `AiAgentRow` MAL (`data_system/agents.zig:26-36,63-78`).
  - `Component` enum (`types.zig:61-76`), `EntityTemplate` (`:740-755`), and
    `StructuralCommand` (`:790-808`).
- **Interest markers** (`src/game/world_interest.zig`):
  - Fixed 128-slot `InterestMarkerStore` with generational ids
    (`:25,38-169`). The `patrol` kind is reserved with no consumer (`:27-36`).
  - `findBestInvestigateMarker` (`:172-204`); Slice 61 generalises it to
    `findNearestMarker(kind, …)`.
- **Archetypes:** `AiArchetypeId` closed enum and strict loader
  (`src/game/ai_archetypes.zig:52-61,70-76,106-116`), with
  `assets/ai/archetypes.json`.
- **Affect:** fatigue exertion is `pursue or flee` (`systems/affect.zig:368`;
  Slice 61 turns it into an exhaustive `.forage`-classified switch).
- **Debug overlay:** behavior colours are indexed by `@backingInt`
  (`ai_debug_overlay.zig:47,60-67`). The `ai` bench histogram switch
  (`src/benchmarks/ai.zig:141`) is exhaustive.
- **Stimuli:**
  - `StimulusKind {dig, footstep, impact}` (`simulation.zig:536-540`),
    `defaultStimulusIntensity` (`:543-549`), and capacities live 32 /
    deferred 16 / impacts 8 / sticky (`:566-580`).
  - SensoryBus deferred buffer (`sensory_bus.zig:46`) and sticky capture of
    dig/impact (`:136-162`, kind switch `:151-154`).
  - Sticky-capacity comptime assert (`:40`).
- **Events:** `EntityPerceivedEvent {observer, target}` (`simulation.zig:125-128`).
- **Pipeline:**
  - `PipelineResource` (`simulation_pipeline.zig:86-120`), `StageId`
    (`:128-148`), and `external_resources` (`:161`).
  - `stageContract` (`:167-232`), `stage_order` (`:262-282`), and the
    comptime checks (`:284-367`).
  - `stageAiDecide` (`:1145-1188`).
- **From earlier slices (cite sections):**
  - **55:** `coastableBehavior`, `DecisionCoastInputs`, and
    `aiDecideGatherJob`. Its wake-rule table says "a future coastable
    path-follower (for example a `patrol` marker consumer) must either stay
    non-coastable or add a carried steering→scope path-status resource".
  - **61:** `AffectImpulse`, `enqueueImpulses(producer, …)`,
    `maxAffectImpulsesPerStep`, the commit-seam drain, and
    `PipelineResource.affect_impulses`.
  - **62:** `SpawnAnchorStore` (256 slots), `SpawnAnchorId`, `SpawnOrigin
    {anchor, entry, despawn}`, `PipelineResource.spawn_anchors` (written by
    `population_update`, the last stage), and `PopulationController` spawn
    templates.
  - **63:** `social_react` sits after `inventory_update` and before
    `tier_policy`.

### Architecture notes

**Decision summary**

| Question | Decision |
| --- | --- |
| New behaviors | Append `patrol`, `follow`, `return_home` to `AiBehavior` after Slice 61's `forage` (`behavior_count` becomes 9). Guard is **not** a behavior. It is `return_home` plus a leash modulation in `scoreBehaviors`, enabled by `gain_return_home > 0` and a resolved home. |
| Per-agent state | One new optional component, `AiPost` (cold `leader: EntityId`, `patrol_route: u8`). No cursor, timer, alert-level, or home column. The patrol cursor comes from the step, home is derived each decide, and alert level is derived from the drive mask. |
| Patrol routes | `patrol` markers gain `route: u8` and `sequence: u8`. `InterestMarkerStore` keeps a derived route table, rebuilt on add/remove (a cold path). The query is O(1). |
| Home | `resolveHome` precedence: (1) the row's `AiPost.patrol_route` target, when that route is live on the row's level; (2) its `SpawnOrigin` anchor, when the anchor is live and on the row's level; (3) none. Home is never stored. |
| Leash | Pursue, investigate, and forage scores are multiplied by 0 while `leash_engaged`. Engagement uses hysteresis read from the existing hot `active_behavior` (no new column). |
| Help call | New stage `guard_alarm`, serial and pipeline-owned. It turns perceived-intruder, damaged-guard, and theft facts into ≤ 4 alarms per step. Each alarm sends affect impulses (`.guard_alarm` producer) to ≤ 8 nearest same-faction recipients, plus one deferred `StimulusKind.alarm`. |
| Goal level | Post goals (patrol, follow, return_home) write `NavigationIntent.goal_level = row level` in `writeAiIntentsJob`, from `row.interest.level`. Every post resolver produces only own-level goals (route level, leader level, and anchor level must equal the row's level), so this is a same-level goal, and the "NPCs stay on the surface until autonomous descent" policy (`simulation_pipeline.zig:1146-1151`), which concerns cross-level goals, is unchanged. Other behaviors keep `goal_level = 0` until Slice 69A makes every AI goal own-level. Off-level homes, leaders, and routes read as "not present". |
| Coasting (55) | `coastableBehavior(.patrol/.follow/.return_home) = false` (path followers). `DecisionCoastInputs.post_signal` forces `alert` for any gain-relevant post assignment (conservative, component-presence only). |

**`AiPost` component** (one tag appended after the last tag present at
landing; 25 of 32 after the VoidLight port's 24)

```zig
// data_system/types.zig
pub const max_patrol_routes: u8 = 16;
pub const max_patrol_route_len: u8 = 16;
pub const no_patrol_route: u8 = 0xff;
pub const AiPost = struct {
    leader: EntityId = EntityId.invalid, // follow target; cold
    patrol_route: u8 = no_patrol_route,   // 0..max_patrol_routes-1 or none; cold
};
```

- Store: `src/game/data_system/post.zig` holds `AiPostStore`, a
  `std.MultiArrayList(AiPostRow{entity, leader, patrol_route})`. That is the
  default layout; there are no hot columns.
- It gets the full track-contract wiring:
  - `Component.ai_post` and `component_masks.ai_post`;
  - `EntitySlot.ai_post_index`;
  - `EntityTemplate.ai_post`;
  - `StructuralCommand.set_ai_post: AiPostCommand`;
  - `StructuralCapacityNeeds.ai_posts` and `TooManyAiPostRows`;
  - preflight/commit arms and destroy cleanup;
  - `set/get/denseIndex/ConstAiPostSlice` accessors.
- `validateAiPost(entity, post)`:
  - `patrol_route < max_patrol_routes or == no_patrol_route`;
  - `leader` may be invalid but never equals `entity`;
  - otherwise it fails with `error.InvalidAiPost`.
- A stale leader (destroyed, generation mismatch) is harmless: it reads as
  "leader not present" and is never cleared.
- Constants live in `data_system/types.zig` so `world_interest.zig` imports
  them from the data layer. `data_system` imports no game module.

**Patrol routes on `InterestMarker`**

- `InterestMarker` gains `route: u8 = no_patrol_route` and `sequence: u8 = 0`.
- `addMarker` validates them:
  - `kind == .patrol` requires `route < max_patrol_routes` and
    `sequence < max_patrol_route_len`;
  - a live `(route, sequence)` pair is unique (`error.DuplicatePatrolSequence`);
  - every live marker of a route shares one level
    (`error.PatrolRouteLevelMismatch`);
  - any other kind requires `route == no_patrol_route`
    (`error.InvalidInterestMarkerRoute`).
- `InterestMarkerStore` gains a derived `PatrolRouteTable`:
  - `route_len: [16]u8`, `route_level: [16]u16`, and
    `route_slots: [16][16]u8`, the live slot indices in ascending `sequence`
    (gaps allowed, so length is the live count);
  - it is about 300 B inline, rebuilt by `addMarker` / `removeMarker` /
    `clear` in O(`interest_marker_capacity`), and is cold, authoring-time
    work.
- `patrolTarget(route, level, step, entity_index) ?struct { x: f32, y: f32 }`:
  - returns null when the route is empty or `route_level != level`;
  - otherwise uses slot `route_slots[route][i]`, where
    `i = @intCast((step / patrol_dwell_steps + entity_index) % route_len)`
    with `step: StepIndex` (`u64`, Slice 49), so no widening cast is needed.
- Allocation-free signature tests follow the `:354` precedent.

**Fixed constants** (`systems/ai_post.zig` unless noted; none derive from
world, route, or population size)

| Constant | Value | Reason |
| --- | --- | --- |
| `patrol_dwell_steps` | 600 (10 s) | Stateless cursor epoch. Authored legs should take under 10 s at agent speed (documented in the authoring note). `+ entity.index` spreads patrollers across the route. |
| `max_patrol_routes` / `max_patrol_route_len` | 16 / 16 | Inline route table. The 128 marker slots are shared with investigate/resource. |
| `guard_leash_radius` | 384 px | Backlog value. Beyond it pursue/investigate/forage score 0. |
| `guard_leash_release_radius` | 192 px | Hysteresis: once `active_behavior == .return_home`, the leash stays engaged until within 192 px, so a target parked at the boundary cannot cause flapping. |
| `return_home_arrive_radius` | 24 px | Inside it the `return_home` goal is invalid, which degrades to wander. That is the existing invalid-goal path. |
| `follow_distance` | 64 px | VoidLight `followDistance = 100` (`BehaviorConfig.hpp:309`), scaled to ZeroLight's 32 px tiles (2 tiles). |
| `patrol_route_bonus` / `follow_leader_bonus` / `return_home_leash_bonus` | 0.3 / 0.6 / 2.0 | `perceptionTerm` arms. 2.0 makes the leash dominate any idle score. |
| Priorities | `return_home` 8, `follow` 5, `patrol` 3 | `priorityForBehavior`: the leash outranks investigate/cohere (5) but not pursue (10) or flee (20) |
| `guard_alarm_sources_per_step` | 4 | Alarms per step after merge; excess counted `guard_alarms_dropped` |
| `guard_alarm_merge_radius` | 64 px | Same-faction alarms within it merge (first in event order wins) |
| `guard_alarm_radius` / `guard_alarm_candidate_checks` | 256 px / 64 | Spatial query: `cellScanRadius(256, 32) = 8`; fixed candidate cap |
| `guard_alarm_max_recipients` | 8 | Backlog cap; the nearest 8 among visited candidates |
| `guard_alarm_aggression_delta` / `guard_alarm_curiosity_delta` | +0.4 / +0.25 | Two impulses per recipient |
| `maxAffectImpulsesPerStep(.guard_alarm)` | `4 × 8 × 2 = 64` | Comptime product; joins Slice 61's `affect_impulse_capacity` sum |
| `stimulus_max_alarms_per_step` (`simulation.zig`) | `guard_alarm_sources_per_step` (4) | Deferred alarm stimuli per step |
| `defaultStimulusIntensity(.alarm)` | 0.9 | Between impact (0.85) and dig (1.0) |

**Arbitration rows** (`arbitration.zig`; table-driven, append-only)

- `PersonalityGains` gains `patrol`, `follow`, `return_home`. `gainFor` gets
  three arms.
- `Signals` gains these fields, all defaulting to "no signal":
  - `patrol_present: bool`, `patrol_x`, `patrol_y`;
  - `leader_present: bool`, `leader_x`, `leader_y`;
  - `home_present: bool`, `home_x`, `home_y`;
  - `leash_engaged: bool`.
- Weight table columns (rows fear, curiosity, aggression, fatigue, need):
  - patrol `{-0.5, 0, 0, -0.5, -0.5}`: fear, fatigue, and hunger pull off
    the route;
  - follow `{0.5, 0, -0.3, 0, 0}`: fear clusters on the leader;
  - return_home `{0.5, 0, 0, 1.0, 0}`: scared or tired guards go home. This
    is the VoidLight Guard roam → return emergent rule.
- `perceptionTerm` arms:
  - `.patrol`: `patrol_route_bonus` if `patrol_present`;
  - `.follow`: `follow_leader_bonus` if `leader_present`;
  - `.return_home`: `return_home_leash_bonus` if `leash_engaged`.
- `memoryTerm` is 0 for all three.
- **Leash modulation** sits inside `scoreBehaviors` after the gain product:
  `if (signals.leash_engaged) for (0..behavior_count) |b| if (leashSuppressed(b)) scores[b] = 0;`.
  - `leashSuppressed` is an exhaustive switch: pursue, investigate, and
    forage return `true`; wander, flee, cohere, patrol, follow, and
    return_home return `false`. Flee is never leashed.
  - A new tag fails to compile until it is classified.
- `resolveGoal` arms:
  - `.patrol`: `(patrol_x, patrol_y)` when present, else invalid. Arriving
    at the post keeps the goal valid (the agent stands its post, the same
    arrival behavior investigate has at a marker).
  - `.follow`: when `leader_present`,
    `leader + normalizeOrDefaultFinite(self − leader, 0.0001, (1, 0)) × follow_distance`,
    else invalid.
  - `.return_home`: when `home_present` and
    `dist² > return_home_arrive_radius²`, the home position; else invalid.
- All three use `kind_hint = .individual`. Prewarmed group fields (71B) serve
  them through `statusForWorld`'s kind-agnostic field lookup
  (`pathfinding/system.zig:801-816`).
- **Gain-0 parity proof.** A new behavior with gain 0 scores exactly 0.
  Wander's score is ≥ 0 at index 0, so the strict-greater argmax never picks
  a new tag. In `selectSticky`, a 0 score can only challenge a negative hold
  threshold, and wander (index 0, score ≥ 0) already challenges there. So the
  selection is unchanged bit for bit. `leash_engaged` is gated on
  `gain_return_home > 0`, so it is false at gain 0.

**AI gather and `Signals` population** (`ai.zig` plus the new pure helper
module `src/game/systems/ai_post.zig`)

`ai_post.zig` imports `std`, `core/math.zig`, `data_system.zig`
(types only), `world_interest.zig`, and Slice 62's `spawn_anchors.zig`. It
holds pure functions only:

- `patrolGoal(markers, post, level, step, entity_index) ?Point`;
- `resolveHome(markers, anchors, post: ?AiPost, origin: ?SpawnOrigin, level, step, entity_index) ?Point`,
  using the precedence above;
- `leashEngaged(self, home, prev_behavior) bool`. It is
  `d² > guard_leash_radius²`, or `prev_behavior == .return_home and d² > guard_leash_release_radius²`;
- `guardAlertLevel(above_threshold_mask, target_visible) u2`:
  - 3 when `target_visible` and the aggression bit is set;
  - else 2 when the aggression bit is set;
  - else 1 when the curiosity bit is set;
  - else 0.

  This maps VoidLight's alert levels 0–3 (`GuardBehavior.cpp:302-319`) onto
  the existing Schmitt thresholds. It is a derived label only.

`gatherAiData` changes:

- `AiGatherRow.gains` gains `patrol`, `follow`, `return_home`.
- A new grouped column `post: RowPost { patrol_present, patrol_x, patrol_y,
  leader_present, leader_x, leader_y, home_present, home_x, home_y,
  leash_engaged }` is added. It is one MAL field, which keeps the comptime
  sort under quota.
- It is filled on the main thread, gated like `has_focus`:
  - `gain_patrol > 0 or gain_return_home > 0`: resolve `AiPost` once.
  - `gain_patrol > 0`: run `patrolGoal`.
  - `gain_follow > 0` and a valid `AiPost.leader`: the leader must be alive
    (`movementBodyDenseIndex(leader)`) and share the row's level (missing
    level counts as 0). Its position comes from `movement.previous_x/y` at
    the leader's dense index, the same step-start pose every other signal
    uses.
  - `gain_return_home > 0`: `resolveHome` (with an optional `SpawnOrigin`),
    then `leashEngaged` with `sticky.prev_behavior`.
- Rows with all three gains at 0 do no lookups. Cost is one compare per row.
- `AiConfig` gains `spawn_anchors: ?*const SpawnAnchorStore = null`. Null
  means no anchor homes, so tests and benches without a world are unchanged.
  `interest_markers` already exists.
- `resolveRowArbitration` builds the new `Signals` fields and adds the
  resolved-gain arms. `priorityForBehavior` gets the three arms.
- **Goal level.** `AiJobContext` gains `row_levels: []const u16` (the
  `interest.level` column, already gathered). `writeAiIntentsJob` writes
  `goal_level = row_levels[i]` when the resolved behavior is `.patrol`,
  `.follow`, or `.return_home`, and leaves the default 0 otherwise. A
  pure `postGoalLevel(behavior, row_level) u16` helper holds the mapping;
  its exhaustive switch fails to compile until a new behavior is classified.
  Slice 69A later replaces it with "every behavior is own-level".
- Row work stays scalar, as gather is. The new signal math is a handful of
  compares and one normalize, inside the existing threaded intent job.

**Composition with 68A and 68B** (consistency F17)

- **68A.** If 68A has landed, the `AiGatherRow.post` columns are gathered in
  68A's decide-only gather through `rowForAiIndex`, and the `guard_alarm`
  recipient search reads 68A's spatial-index halo columns (faction, level)
  instead of resolving per-row slots. If 71A lands first, 68A's rewrite
  carries the `post` column over as one more decide-only field.
- **68B.** The leash multiplier (pursue/investigate ×0 beyond
  `guard_leash_radius`) multiplies the whole pursue product, including 68B's
  `retaliationTerm`. `resolvePursueGoal`'s retaliation tier is skipped when
  `leash_engaged`, so `return_home` wins outside the leash. Whichever of
  71A and 68B lands second adds the skip and its test.

**Slice 55 classification** (`systems/simulation_scope.zig`, pure contract
in `simulation_scope.zig`):

- `coastableBehavior`: `.patrol`, `.follow`, and `.return_home` return
  `false`.
- `DecisionCoastInputs` gains `post_signal: bool = false`; true classifies
  the row `alert`. `aiDecideGatherJob` sets it when
  `(gain_patrol > 0 and the row has AiPost with patrol_route != none) or (gain_follow > 0 and AiPost.leader.isValid()) or (gain_return_home > 0 and (AiPost.patrol_route != none or the row has SpawnOrigin))`.
- It is component-presence only, with no world lookups. That is conservative:
  over-alerting costs only perf, and Slice 55's contract ("any new signal
  that can resolve a goal by itself must be added to the alert predicate")
  holds. Posted agents (guards, escorts, patrollers) therefore never coast.
  This is documented as the cost of path-following posts.
- At all-zero post gains `post_signal` is false, so the decide set is
  unchanged.

**Help call: `GuardAlarmController`** (`src/game/guard_alarm_controller.zig`,
pipeline-owned, serial, no per-entity state)

A **guard** is a row with `AiAgent.gain_return_home > 0`,
`AiAgent.gain_pursue > 0`, and a resolved home this step: a homed agent that
can fight.

- The `gain_pursue` term is deliberate. The `merchant` content below also
  gets `gain_return_home 2.0` (its leash), and without the term every homed
  merchant would raise alarms. A merchant with `gain_pursue 0` is homed but
  is not a guard, so it never raises an alarm. It can still *receive* one as
  an ordinary same-faction recipient.
- If Slice 62's merchant bundle has `gain_pursue > 0`, that merchant can
  fight and acting as a guard is consistent with that. The definition is a
  rule over gains, not a content list.

The controller runs these steps:

1. **Collect** alarm sources from this step's merged `frame.events`, in event
   order:
   - `entity_perceived{observer, target}`: the observer is a guard and the
     target's step-start position is within `guard_leash_radius` of the
     observer's home. Alarm at the observer's position, with the observer's
     faction.
   - Slice 56 `entity_damaged{attacker, target}`: the target is a guard.
     Alarm at the target's position, with its faction.
   - Slice 61 `harvest_completed{owned = true, owner, harvester, level,
     cell_x, cell_y}` where the harvester's faction ≠ `owner`. Alarm at the
     cell center, faction = `owner`. This is the Slice 63 deferred "guard
     alert on theft", now owned here. Standing changes stay in 63.
   - An alarm within `guard_alarm_merge_radius` of an earlier same-faction,
     same-level alarm this step is merged.
   - Stop at `guard_alarm_sources_per_step` and count the rest as
     `guard_alarms_dropped`.
   - An event dropped by its producer's per-step cap only loses an alarm. It
     is never a coast wake (Slice 55 forbids event-based wakes, and this is
     not one).
2. **Recipients** per alarm:
   - Query `spatial_index.view().queryNeighbors` around the alarm position
     with radius `guard_alarm_radius` and `max_candidate_checks = 64`.
   - **Map a candidate row to its entity through the view's own entity
     column, never through halo indices.** A candidate index is a *spatial
     row* index. Spatial rows are compacted: both builds skip a halo entry
     with no movement body (`spatial_index.zig:603`
     `movementBodyDenseIndex(ent) orelse continue`, and the worker job at
     `:854`). So row `r` is not halo entry `r`. After the first skipped entry,
     every later row would map to the wrong entity, and the
     faction/level/`AiAffect` checks and the impulses would hit arbitrary
     allies. Small fixtures where every agent has a body would not show it.
   - **View column.** `SpatialIndexView` has no entity column today
     (`spatial_index.zig:257-268`), but `SpatialIndexRow.entity` is already
     stored (`:431-436`). This slice adds `entities: []const EntityId` to the
     view, filled as `slice.items(.entity)` in `view()` (`:515-533`) beside
     `pos_x`/`pos_y`. If 68A has landed first, its view already carries the
     column and this edit is a no-op.
   - Candidate `r` is `view.entities[r]`. The guard_alarm stage does not read
     `ai_halo_indices`.
   - Accept a candidate that is alive, shares the alarm's level and faction
     exactly, and has `AiAffect`.
   - Keep the nearest `guard_alarm_max_recipients` by
     `(dist², entity.index, generation)` in a fixed `[64]` scratch with
     partial selection.
3. **Impulses:** for each recipient, `{entity, .aggression, +0.4}` and
   `{entity, .curiosity, +0.25}`, appended in alarm order then recipient
   order through `enqueueImpulses(.guard_alarm, …)`. The budget is 64 by
   construction (comptime assert). They are drained at Slice 61's commit seam.
4. **Stimulus:** one deferred `WorldStimulus{position, intensity 0.9, kind
   .alarm, level}` per alarm through the new
   `SensoryBus.enqueueAlarm(stimulus) bool`. A full deferred buffer counts
   into `stimuli_deferred_dropped`.
   - It is promoted next step before perception, like impacts.
   - `advanceSticky` gives `.alarm` the dig/impact linger, so every stagger
     cohort hears it.
   - The kind-agnostic hearing path then gives curious and alerted agents an
     investigate goal at the alarm. Hostiles in hearing range hear it too.
     That is intended emergence, not a filter bug.

**Stimulus capacity update** (`simulation.zig`, `sensory_bus.zig`)

- `StimulusKind.alarm` is appended; it has a real producer, as the
  `StimulusKind` doc requires.
- `stimulus_sticky_capacity` becomes
  `(stimulus_max_impacts_per_step + 1 + stimulus_max_alarms_per_step) * (cognition_stagger_n - 1)`,
  that is 39. The `sensory_bus.zig:40` assert is updated to match.
- Comptime asserts:
  - `stimulus_max_impacts_per_step + stimulus_max_alarms_per_step <= stimulus_deferred_capacity`
    (12 ≤ 16);
  - `stimulus_deferred_capacity + 2 <= stimulus_live_capacity` (promote +
    dig + footstep ≤ 32).
- `hearing_stimuli_scratch_capacity` follows automatically.

**Stage graph: one new `StageId`, no new `PipelineResource` tag**

Merged tail of `stage_order`:
`… inventory_update → social_react → guard_alarm → tier_policy → population_update`.

| Stage | reads | writes | carried |
| --- | --- | --- | --- |
| `ai_decide` (changed) | unchanged | unchanged | `interest_markers` (already), **`spawn_anchors`** (written later by `population_update`) |
| `guard_alarm` (new) | `perception_events`, `combat_events`, `world_events`, `spatial_index` (including the new `entities` view column), `movement_positions`, `world_level` | `affect_impulses` | `interest_markers`, `spawn_anchors` |

- Every read has an earlier writer: `perception_update`, `combat_resolve`,
  `dig_world_edit` / `plane_traversal` / `action_react`,
  `spatial_index_build`, and the movement writers. `ai_halo_indices` is
  deliberately not read (see Recipients). Every carried entry is external
  or has a later writer.
- The stage writes no `movement_positions`, so the
  `chunk_derive → tier_policy` freshness derivation (`:242-249`) holds.
- The SensoryBus deferred append follows `collision_respond`'s untagged
  `enqueuePlayerImpacts` precedent: SensoryBus-owned, promoted next step.
- `affect_impulses` gains a third writer after `action_react` and
  `social_react`; enqueue order is stage order.
- Raise `@setEvalBranchQuota` at `simulation_pipeline.zig:287` once, sized
  for the merged 29-stage order (consistency T4), if the walk needs it.

**Authoring**

- `archetypes.json` `agent` block gains optional `gain_patrol`, `gain_follow`,
  and `gain_return_home` (strict; `validateAiAgent` checks
  `[0, max_ai_gain]`).
- `AiPost` is not archetype-authored: leaders are runtime ids and routes are
  per-world.
- Content:
  - `guard` (Slice 62): `gain_patrol 1.5`, `gain_return_home 2.0`,
    `gain_pursue 1.5`, `gain_investigate 1.0`, plus perception, memory, and
    affect `baseline_aggression 0.3`.
  - `merchant` (62): `gain_return_home 2.0`. This is the merchant leash from
    Slice 61's VoidLight reference, now homed at its anchor.
  - New `escort` (appended after 62's ids, outside the 8-slot demo cycle):
    `gain_follow 2.0`, `gain_flee 1.0`, `gain_wander 0.5`, perception,
    memory, affect `baseline_fear 0.3`, plus Slice 62 `body`/`visual`
    blocks.
- `SpawnAnchorStore` slots gain `patrol_route: u8 = no_patrol_route`
  (validated as above; hashed). `PopulationController` adds
  `ai_post = .{ .patrol_route = anchor.patrol_route }` to a spawn template
  when the route is set and the archetype bundle has `gain_patrol > 0`.
  Slice 58's worldgen anchor JSON gets an optional `patrol_route`, defaulting
  to none.
- Demo:
  - one 4-marker `patrol` route (route 0, square, 160 px legs) near spawn;
  - two hand-placed `guard`s with `AiPost{.patrol_route = 0}`;
  - one `wanderer` leader with two `escort`s carrying `AiPost{.leader}`;
  - the demo `settlement` anchor sets `patrol_route = 0`.

  The demo body count, cognition reserve, and structural reserves gain these
  5 entities as named terms.

**Determinism and checksum (Slice 49 lists / Slice 46 sections, same change)**

- Hashed:
  - `AiPostStore` (`leader` is an `EntityId` slot + generation, inside 46's
    stable-ID boundary);
  - the new `AiAgent` cold gains (inside the existing `ai_agents` MAL);
  - `InterestMarker.route/sequence` (live slots, with the marker hash);
  - `SpawnAnchorStore.patrol_route`.
- Excluded: the route table (derived, rebuilt on load by re-adding markers)
  and `GuardAlarmController` scratch.
- SensoryBus alarm deferred/sticky entries take whatever class SensoryBus
  state already has. Once Slice 64B lands, SensoryBus history is hashed and
  saved in `"pipeline_history"`, so `.alarm` entries ride along with no
  separate row.
- **Slice 64B field table** (consistency F18), same change: add
  `GuardAlarmController` as `excluded` (per-step scratch). Its proving test is
  that two pipelines that differ only in a stale `GuardAlarmController`
  scratch produce identical next-step checksums.
- **Version bumps** (relative rule): `checksum_format_tag` gets v+1 (Table
  T6). Save `format_version` gets live value + 1 (Table T3, v12 in the merged
  order). The `ai_post` section is appended in `DataSystem` store
  declaration order. `SpawnAnchorStore.patrol_route` rides in `world_meta`
  with 62's `spawn_anchors`.
- Inputs are step-start poses, columns, the step, and `entity.index`. The
  alarm controller is serial, in event order. Recipient order is
  `(dist², index, generation)`. There is no RNG.
- AI serial and threaded runs give identical `RowPost` columns and intents.

**Diagnostics.**

- `SimulationPipelineStats` gains `guard_alarms_raised`,
  `guard_alarms_dropped`, and `guard_alarm_recipients`, recorded through
  `runtime_perf_log` metrics and a `pipeline_guard_alarm` `StageTimer`.
- One `logging.game` debug line at `SimulationPipeline.init` lists the 71A
  constants.
- The debug overlay labels the three behaviors and shows `alert N`
  (`guardAlertLevel`) for guards, read-only.

### Checklist

- [ ] `AiPost` component end to end (one appended tag, `post.zig` MAL store,
      validation, template, `set_ai_post`, capacity needs, preflight/commit,
      destroy cleanup, accessors). Store `FailingAllocator` append proof and
      round-trip test; `validateAiPost` rejects self-leader and route 16.
- [ ] `InterestMarker.route/sequence`, addMarker validation errors (duplicate
      sequence, level mismatch, non-patrol route), `PatrolRouteTable` rebuild
      on add/remove/clear, `patrolTarget`. Tests: sequence gaps compact;
      removal shortens the route; cursor wraps; `step = maxInt(u32) + 1`
      (past the `u32` range of `StepIndex`) and `entity.index = maxInt(u32) - 1`
      match a hand-computed reference; wrong level → null; allocation-free
      signature test.
- [ ] `ai_post.zig` pure helpers (`patrolGoal`, `resolveHome` precedence
      route > anchor > none, `leashEngaged` hysteresis at 384/192,
      `guardAlertLevel` all four levels) with unit tests.
- [ ] Arbitration: append the three `AiBehavior` tags; gains, `Signals`
      fields, weight columns, `perceptionTerm`/`memoryTerm`/`gainFor` arms,
      `leashSuppressed` exhaustive switch and the in-`scoreBehaviors`
      modulation, `resolveGoal` arms. Tests: patrol wins over wander at calm
      drives; follow goal sits `follow_distance` from the leader on the
      leader→self line (and `(1, 0)` default when coincident); return_home
      invalid inside 24 px; leash zeroes pursue/investigate/forage but not
      flee; **gain-0 parity** — for a seeded sweep of 4096 random `Signals`
      (drives, perception, memory, markers) with new gains 0, scores of the
      old behaviors, `selectSticky` results, and resolved goals equal the
      pre-slice table (fixture constants copied into the test).
- [ ] `ai.zig`: `RowGains` fields, `RowPost` column, gain-gated main-thread
      gather (leader same-level/alive check, `resolveHome`, `leashEngaged`
      with `sticky.prev_behavior`), `AiConfig.spawn_anchors`, resolved-gain
      and `priorityForBehavior` arms; `AiJobContext.row_levels` and the
      `postGoalLevel` exhaustive switch in `writeAiIntentsJob`. Tests:
      **underground post goals:** a level-1 guard patrolling a level-1 route
      emits `goal_level == 1` and issues no cross-level path request; a
      level-1 escort's follow goal and a level-2 guard's `return_home` goal
      carry their row level; a level-1 wanderer keeps `goal_level == 0`
      (unchanged until 69A); serial == threaded (0, 1, 2
      workers) intents with patrol/follow/guard rows mixed in; zero-gain
      rows do no `AiPost` lookups (counter-free proof: a row with gains 0
      and a stale `AiPost.leader` produces the same intent as a row without
      `AiPost`); `FailingAllocator` warmed update including post rows.
- [ ] Slice 55 hooks: `coastableBehavior` arms (false), `post_signal` input
      and its gather computation. Tests: a posted row is `alert` on a not-due
      tick; the same row with all post gains 0 coasts as before; the
      decide-list determinism test (serial vs 0/1/2 workers, two range
      sizes) passes with posted rows present.
- [ ] Affect exertion switch (Slice 61's exhaustive form): `.patrol`,
      `.follow`, `.return_home` → not exertion. Debug overlay colours and
      labels for the three tags plus the `alert N` label; `src/benchmarks/ai.zig`
      histogram arms.
- [ ] `StimulusKind.alarm`, intensity 0.9, `stimulus_max_alarms_per_step`,
      sticky-capacity formula + assert, deferred/live comptime asserts,
      `advanceSticky` capture arm, `SensoryBus.enqueueAlarm`. Tests: an alarm
      enqueued at step N is heard by every stagger cohort within the linger
      window at N+1..N+3; a full deferred buffer counts a drop.
- [ ] `GuardAlarmController` + `StageId.guard_alarm` (contract as tabled,
      `runStage` arm, `StageTimer`), `AffectImpulseProducer.guard_alarm` with
      `maxAffectImpulsesPerStep = 64` comptime-tied to the three constants;
      `ai_decide` carried `spawn_anchors`; `SpatialIndexView.entities`
      (`slice.items(.entity)` in `view()`, unless 68A already added it).
      Tests: **compacted-row mapping regression:** a halo agent with no
      movement body sits in the halo before two guards; the alarm's
      recipients are exactly those two guards' `EntityId`s (asserted by id),
      and no impulse targets any other entity; the same fixture run threaded
      (0, 1, 2 workers) gives the same recipient ids; **merchant is not a
      guard:** a homed `merchant` (`gain_return_home 2.0`, `gain_pursue 0`)
      perceiving an intruder inside its leash raises no alarm, but it is
      still accepted as a recipient of a guard's alarm; perceived intruder
      inside the leash raises one alarm, outside it raises none; damaged guard
      raises one; theft of an owned node raises one at the cell with
      `faction = owner`; two same-faction alarms 40 px apart merge; the 5th
      alarm in a step is dropped and counted; recipients are the nearest 8
      same-faction, same-level `AiAffect` rows in `(dist², index,
      generation)` order; hostile and other-level agents receive no impulse;
      impulses are drained at step N's commit seam and visible to step N+1's
      `ai_decide`; contract test asserts the tabled reads/writes/carried.
- [ ] Archetypes: strict `gain_patrol`/`gain_follow`/`gain_return_home`
      keys (unknown-key and out-of-range tests), `guard`/`merchant` content
      updates, `escort` appended, parity table updated (every pre-existing
      archetype bundle unchanged field-for-field).
- [ ] `SpawnAnchorStore.patrol_route` (validation, Slice 49 hash, Slice 46
      section field), `PopulationController` template `ai_post`, Slice 58
      anchor JSON key. Test: a settlement anchor with route 0 spawns a guard
      carrying `AiPost{.patrol_route = 0}`; a `villager` (gain_patrol 0) from
      the same anchor carries none.
- [ ] Demo content: route 0 markers, two posted guards, leader + two escorts,
      settlement anchor route; demo reserves add the named terms.
- [ ] Slice 49 completeness lists + Slice 46 save sections for `AiPostStore`,
      marker route fields, anchor `patrol_route` (same change). Slice 64B
      field table row: `GuardAlarmController` `excluded` with its proving
      test. Bump `checksum_format_tag` (v+1) and the save `format_version`
      (live + 1) once each in this change.
- [ ] **Composition with 68A/68B** (consistency F17), in whichever of the
      slices lands second: the leash zeroes 68B's `retaliationTerm` with the
      rest of the pursue product, and `resolvePursueGoal`'s retaliation tier
      is skipped while `leash_engaged`. Test: a guard hit from beyond its
      leash returns home and does not chase its retaliation target. If 68A
      is present, the `post` column is gathered through `rowForAiIndex` and
      the serial == threaded intent test covers it.
- [ ] Bench group `ai-post` (`src/benchmarks/ai.zig`, registered after
      `ai.group`): the `ai` fixture at the same item counts with every 4th
      row a patroller on one of 8 routes, every 8th an escort of the
      preceding row, every 16th a homed guard (anchor home); timed
      `AiSystem.update` like `ai`.
- [ ] Docs: `docs/architecture.md` (AiPost, route table, guard alarm stage,
      goal-level policy restated as "post goals are own-level; autonomous
      level changes are a decided non-goal"; the guard definition over
      gains), the `simulation_pipeline.zig:1146-1151` comment updated to the
      same wording, `docs/simulation-tiers-and-pipeline.md`
      (`guard_alarm` stage, alarm stimulus, coast classification of posts),
      archetype schema doc comment (`ai_archetypes.zig` header) and the
      authoring note (patrol leg length vs `patrol_dwell_steps`); roadmap:
      Emergent AI track table gains a "Posts / guard (71A)" row; Scaling Gaps
      "Interest marker consumers beyond investigate" marks `patrol` wired;
      Slice 62 **Deferred** home/leash line and Slice 63 **Deferred** guard
      theft-alert line are replaced by "landed in Slice 71A".

### Acceptance checks

- [ ] Minimal fixture worlds (`1×1`-chunk pattern):
  - two guards on a 4-marker route visit markers in cursor order across
    `2 × patrol_dwell_steps`;
  - an escort stays within `follow_distance + 32 px` of a moving leader over
    300 steps on one level, and degrades to wander when the leader changes
    level;
  - a level-1 guard on a level-1 route next to a ramp to the surface (64E)
    patrols for 600 steps and never takes the ramp: every post intent has
    `goal_level == 1`, and `world_level` stays 1;
  - a guard lured 400 px from its post by a visible hostile switches to
    `return_home`, does not resume pursuit until within 192 px, and never
    flaps across the 384 px boundary in a 600-step run (behavior edge count
    ≤ 2).
- [ ] Help call end to end: a hostile entering a guard's leash zone at step
  N:
  - raises one alarm;
  - two allied guards 200 px away have `aggression` raised at N's commit;
  - they hear the `alarm` stimulus at N+1..N+3 and select investigate or
    pursue toward it by N+4;
  - a hostile agent 200 px away gets no impulse.
- [ ] Gain-0 parity:
  - the 4096-sample arbitration sweep matches;
  - a 120-step `GameDemoState.update` checksum (Slice 49
    `simulationChecksum`) over a fixture with only pre-71A archetypes is
    identical before and after the slice (the new stage runs and finds no
    guards).
- [ ] Serial == threaded:
  - AI intents, decide lists, and `RowPost` columns are identical for 0, 1,
    and 2 workers;
  - whole-pipeline checksum parity holds over 120 steps with guards,
    escorts, patrollers, and alarms active.
- [ ] `FailingAllocator`: the composite `pipeline.update` with posts, an
  alarm, and a theft allocates nothing after reserve (streams, impulses,
  deferred stimuli, alarm scratch).
- [ ] Benches:
  - `zig build bench -- --group ai-post` recorded;
  - `--group ai` and Slice 55's `--group ai-idle-coast` stay within the
    same-session noise band versus a pre-change capture (zero-gain rows pay
    one compare);
  - `--group ai-affect` shows no regression.
- [ ] Comptime: the stage-contract walk passes with `guard_alarm`; the
  impulse-budget and stimulus-capacity asserts hold. `zig build verify`
  passes.

### VoidLight reference

- **Ported:**
  - Guard post and roam radius (`include/ai/BehaviorConfig.hpp:362`
    `guardRadius`, `GuardBehavior.cpp:573-595`) become home + leash +
    `return_home`.
  - `RAISE_ALERT` / alert levels 0–3 (`GuardBehavior.cpp:79-100,302-319`)
    become the help call and the derived `guardAlertLevel`.
  - Follow's `desiredPos = target − dir × followDistance`
    (`FollowBehavior.cpp:143`).
  - Patrol waypoint cycling (`PatrolBehavior.cpp:139-147`) becomes authored
    routes.
  - The merchant leash (Slice 61 VoidLight note) becomes `gain_return_home`
    on `merchant`.
- **Changed:**
  - Waypoints are authored `patrol` markers, not
    `generateRandomWaypoint(currentPos)` (`PatrolBehavior.cpp:19,75`).
  - The waypoint cursor is step-derived, not per-entity `currentPatrolIndex`
    plus timers.
  - Alert escalation is drive thresholds, not `threatDuration` timers.
  - Catch-up speed (`catchupSpeedMultiplier`, `FollowBehavior.cpp:191-193`)
    is left to steering. ZeroLight has no per-behavior speed multiplier.
- **Not ported:**
  - `thread_local std::mt19937 s_rng{std::random_device{}()}`
    (`GuardBehavior.cpp:19`, `PatrolBehavior.cpp:15`).
  - `ctx.deltaTime` accumulator timers (`GuardBehavior.cpp:385-407`,
    `PatrolBehavior.cpp:131`).
  - Message-queue dispatch (`BehaviorMessage`).
  - Per-entity `GuardStateData` / `PatrolStateData` sidecars.

