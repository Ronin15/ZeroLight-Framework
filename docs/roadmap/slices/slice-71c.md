## Slice 71C: Cover-Aware Flee And Ranged Pursue (`cover` Interest Markers)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 56B](slice-56b.md), [Slice 41](../archive/slice-41.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Depends on **56B** (`CombatStats.attack_mode` /
`attack_range` and the `archer` archetype) and on archive **41** (interest
markers, landed). It is independent of 71A, 71B, and 71D. No `SeedDomain`, no
new component, no new stage, and no new `PipelineResource`.

Goal: wire the reserved `cover` marker kind into exactly two goal resolvers,
with no score term and no investigate input:

- **Flee:** a fleeing agent runs to the nearest authored cover that lies away
  from its threat, instead of a point 96 px straight away.
- **Ranged pursue:** a ranged pursuer (`attack_mode == .ranged`) moves to the
  nearest authored cover within its attack range of the target instead of
  closing to melee distance. From there Slice 56's `.attack` arm fires
  because the target is in reach.

With no `cover` markers, every score, behavior, goal, and intent is
byte-identical to today.

Out of scope:
- Concealment, meaning cover changing perception visibility. That would be a
  perception rule. This slice changes goal choice only.
- Cover for melee pursue. A melee attacker in cover cannot reach its target.

### Current foundation (do not rebuild)

- **Markers:**
  - `InterestMarkerKind.cover` is reserved with no consumer
    (`world_interest.zig:27-36`).
  - `marker.radius` is the "authored influence footprint (interaction/cover
    size later)" and not a discovery gate (`:16-20,58-59`).
  - The faction filter is "restricted unless proven" (`:101-108`), with a
    slot-order tie-break (`:195`).
  - Investigate ignores the reserved kinds; the test at `ai.zig:2359` pins
    that and must keep passing.
- **Goals:**
  - `resolveFleeGoal` uses the visible threat, else fresh memory; the goal is
    `self + normalize(self − threat) × flee_lead_distance (96)`
    (`arbitration.zig:295,328-351`).
  - `resolvePursueGoal` tiers: visible → fresh memory matching focus → focus
    fallback (`:297-326`).
  - `resolveGoal` is pure signal-in/goal-out (`:408-419`).
- **AI threading:** `resolveRowArbitration` runs inside the threaded
  `writeAiIntentsJob` (`ai.zig:1252-1365,1367-1404`), and its `Signals` value
  is a per-row local built before `scoreBehaviors` (`:1275-1307`). The marker
  store is a read-only external resource `ai_decide` already carries
  (`simulation_pipeline.zig:194`).
- **From Slice 56B:** `CombatStats` cold `attack_mode { melee, ranged }`,
  `attack_range ≤ max_combat_attack_range (256)`, and the demo's 4 `archer`
  rows. The Slice 56 `.attack` arm checks reach against `attack_range` on
  settled poses.

### Architecture notes

**Queries** (`world_interest.zig`, pure, allocation-free, fixed 128-slot
scans):

- `findFleeCover(level, self_x, self_y, threat_x, threat_y, query_radius, faction) ?Point`
  accepts live `cover` markers that meet all of these:
  - on `level`, and the faction filter accepts the agent;
  - `dist²(self, m) ≤ query_radius²`;
  - **away from the threat:** `dot(m − self, self − threat) ≥ 0`, so the run
    never passes the threat;
  - **an improvement:**
    `dist(m, threat) ≥ dist(self, threat) + cover_min_gain`, compared in
    squared form with the non-negative sum squared.

  It picks the minimum `dist²(self, m)`, then the lowest slot.
- `findRangedCover(level, self_x, self_y, threat_x, threat_y, attack_range, query_radius, faction) ?Point`
  accepts live `cover` markers that meet all of these:
  - on `level`, faction accepted, `dist²(self, m) ≤ query_radius²`;
  - `ranged_cover_min_standoff² ≤ dist²(m, threat) ≤ (attack_range −
    ranged_cover_reach_margin)²`.

  It uses the same tie-break.
  - **Why the margin.** A marker at exactly `attack_range` would leave an
    archer that stops anywhere inside the steering arrival tolerance around
    the marker just out of reach. Then Slice 56's `.attack` arm never fires,
    and the archer holds cover forever. The margin keeps any stop point near
    the marker within reach.
  - If `attack_range − ranged_cover_reach_margin ≤ ranged_cover_min_standoff`
    for a row, its band is empty and the query returns null. The row closes
    to its normal pursue goal.
- Both join the allocation-free signature test (`:354` precedent).
- The module doc and the `cover` tag comment change to "consumed by flee and
  ranged-pursue goal resolution only; never an investigate input".

**Fixed constants** (`world_interest.zig`; none derived from world or content
size)

| Constant | Value | Reason |
| --- | --- | --- |
| `cover_query_radius` | 320 px | Inside the 400 px marker radius. Beyond flee's 96 px lead, so cover is worth a detour. |
| `cover_min_gain` | 32 px (one tile) | Cover must add real distance from the threat, or flee stays the straight lead. |
| `ranged_cover_min_standoff` | 96 px | Never picks cover in the target's face. |
| `ranged_cover_reach_margin` | 16 px (half a tile) | At least the steering arrival tolerance, so an archer that stops short of or past the marker is still within `attack_range`. `comptime assert(max_combat_attack_range - ranged_cover_reach_margin > ranged_cover_min_standoff)`, so the band is non-empty at the largest range. |

**Arbitration** (`arbitration.zig`). Cover is a **goal-only** input with no
score term, so `scoreBehaviors` and `selectSticky` are untouched.

- `Signals` gains `flee_cover_present`, `flee_cover_x`, `flee_cover_y`,
  `ranged_cover_present`, `ranged_cover_x`, and `ranged_cover_y`, defaulting
  to "no signal".
- Two pure helpers are exported and become the single source of truth that
  `resolveFleeGoal` / `resolvePursueGoal` already compute inline:
  - `fleeThreat(signals) ?Point`: visible, else fresh memory;
  - `pursueThreat(signals) ?Point`: visible, else fresh memory matching
    focus. The focus tier is excluded.
- `resolveFleeGoal`: a threat with `flee_cover_present` makes the goal the
  cover point. Otherwise it keeps the existing lead.
- `resolvePursueGoal`: on the visible and memory tiers, `ranged_cover_present`
  makes the goal the cover point, with `goal_entity` still the threat. The
  focus tier never uses cover.
- Arrival is unchanged: the goal stays the cover point and the agent holds
  it, the same as a reached investigate marker.

**AI** (`ai.zig`)

- `AiGatherRow` gains the grouped column `combat: RowCombat { ranged_attack_range: f32 = 0 }`.
  The main-thread gather fills it only when `gain_pursue > 0` and the row's
  Slice 56 `CombatStats.attack_mode == .ranged` (one dense lookup).
- `AiJobContext` gains `markers: ?*const InterestMarkerStore` and
  `combat: []const RowCombat`.
- **Lazy, selected-behavior-only queries.** In `resolveRowArbitration`, after
  `selectSticky` and before `resolveGoal`:
  - selected `.flee` with `fleeThreat(signals)` non-null and markers non-null
    → `findFleeCover` fills the flee cover fields on the local `Signals`;
  - selected `.pursue` with `ranged_attack_range > 0` and
    `pursueThreat(signals)` non-null → `findRangedCover`.

  Only rows actually fleeing or pursuing ranged pay the 128-slot scan. Scoring
  never sees these fields, so filling them after selection is sound.
- Workers read the const store, which is never mutated during the step.

**Coasting (55):** flee and pursue are already non-coastable. Cover cannot
resolve a goal without a threat, which is already alert input. So there is no
`coastableBehavior` or alert-predicate change.

**Demo:** four `cover` markers (`radius 24`, no faction filter) near the
archer placement and the timid spawn cluster.

**Determinism and checksum:** pure functions of the step-start `Signals`,
the const marker store, and slot order. There is no new persistent state;
cover markers are already hashed with `interest_markers`.

### Checklist

- [ ] `findFleeCover` / `findRangedCover` + constants + comptime assert; module
      doc and tag comment updated. Tests: direction gate rejects cover behind
      the threat; `cover_min_gain` boundary at 31/32/33 px; query-radius,
      level, faction-filter, and slot tie-break; ranged band (standoff
      boundary, and the `attack_range − 16` boundary: a marker at exactly
      `attack_range` is rejected, one at `attack_range − 16` is accepted); an
      `attack_range` of 100 (band empty) returns null; non-cover kinds ignored; allocation-free
      signature.
- [ ] `Signals` cover fields, exported `fleeThreat`/`pursueThreat` reused by
      both resolvers, flee/pursue cover arms. Tests: flee goal is the cover
      point with cover and the 96 px lead without; ranged pursue goal is
      cover with `goal_entity == threat`; focus-tier pursue ignores cover;
      `scoreBehaviors` output unchanged by cover fields (same scores with and
      without).
- [ ] `ai.zig`: `RowCombat` gather (ranged only), `AiJobContext.markers` /
      `.combat`, lazy post-selection queries. Tests: melee pursuer ignores
      cover; a non-fleeing row performs no cover query (a fixture whose only
      cover marker would change a flee goal leaves a wandering row's intent
      unchanged); serial == threaded (0, 1, 2 workers) with cover markers;
      `FailingAllocator` warmed update; `ai.zig:2359` investigate-ignores-cover
      test passes unchanged.
- [ ] Parity: with zero `cover` markers, intents for a mixed fixture (flee,
      pursue incl. focus, ranged) are byte-identical to the pre-slice
      expected table.
- [ ] Demo cover markers; pipeline test (minimal fixture): a timid ally with
      a visible hostile and one qualifying cover marker 200 px away emits a
      flee intent whose goal is the marker, and an archer with a hostile at
      220 px and a marker 160 px from it emits a pursue intent toward the
      marker, then a Slice 56 `.attack` intent once in reach.
- [ ] Bench group `ai-cover` (`src/benchmarks/ai.zig`, after `ai-post`): the
      `ai` fixture plus 32 cover markers; 50% rows `gain_flee 1.5` with
      `target_visible`, 25% ranged pursuers.
- [ ] Docs: `docs/architecture.md` interest-marker paragraph (cover wired);
      roadmap Scaling Gaps "Interest marker consumers beyond investigate"
      closed (investigate/resource/patrol/cover all wired: 41/61/71A/71C);
      Emergent AI track table "World interest" row updated.

### Acceptance checks

- [ ] Pipeline flee-to-cover and archer-to-cover tests pass. A level-1 cover
  marker is never chosen by a level-0 agent.
- [ ] Zero-cover parity holds. Investigate never reads cover.
- [ ] Serial == threaded. The `FailingAllocator` proof passes.
- [ ] `zig build bench -- --group ai-cover` is recorded, and `--group ai` stays
  within the same-session noise band. Rows that are not fleeing or pursuing
  pay nothing.
- [ ] `zig build verify` passes.

### VoidLight reference

- **What VoidLight does:** `updateSeekCover` (`FleeBehavior.cpp:287-320`)
  blends the threat-away direction 40/60 toward `findNearestSafeZone`. Its
  destination is `coverSeekDistance = 720` px (`BehaviorConfig.hpp:298`),
  scaled ×1.2 or ×1.6 by `cachedNearbyCount`, and clamped to the world
  bounds.
- **Ported:** the idea that a fleeing agent heads for an authored safe point
  rather than a blind away-vector.
- **Changed:**
  - The safe point is a `cover` marker chosen by fixed predicates (direction
    gate, ≥ 32 px gain, 320 px radius), not a direction blend.
  - The away-vector lead stays as the no-cover fallback (96 px).
- **Not ported:**
  - Crowd-scaled destination distances (`cachedNearbyCount` multipliers).
    These are content- and population-dependent.
  - `deltaTime` speed modifiers.
- Ranged cover-holding has no VoidLight counterpart; it is a ZeroLight
  extension on 56B.

