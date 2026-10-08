## Slice 71B: Static Collider Index, Collision Static Split, And Group-Field Prewarm

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 62](slice-62.md), [Slice 71A](slice-71a.md) (71B.3 only; 71B.1 ungated, 71B.2 bench-gated) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status:** in progress; 71B.1's fixed group-field threshold, its
capacity-audit follow-up, and the steering level gate are landed; the shared
static-collider rows and steering migration, 71B.2, and 71B.3 are open.

Goal:

- Steering and collision read **one** commit-rebuilt, level-aware static
  collider structure instead of re-deriving static obstacles separately.
- Collision stops re-gathering, re-sorting, and pair-testing static
  colliders every step. Its contact stream is byte-identical to today's
  single SAP minus static×static pairs, in identical order.
- The `PathfindingSystem` prewarms reverse-Dijkstra group fields for authored
  shared goals inside empty `group_fields` slots, under fixed per-step
  budgets.
- The group-field threshold is a fixed constant (landed).

### Current foundation

- **Collision** (`src/game/systems/collision.zig`): `ProxyRow` MAL and
  `CollisionConfig`; `gatherBodies` (3 slot lookups per bounds row per
  step); `ensureOrder` with warm insertion / full `sortWarm`; serial SIMD SAP
  and threaded range SAP with overflow-grow-replay; range-order pair merge;
  SIMD narrowphase bit-identical to `contactForCandidate`. Sort key
  `proxyIndexLessThan` = `(min_x, min_y, entity.index, generation)`. The SAP
  emits exactly every same-level positive-overlap pair, ordered
  lexicographically `(key(a), key(b))` with `a` the earlier-sorted proxy.
- **Contact consumers are order-sensitive:** `CollisionResponseSystem`
  applies intents sequentially (static×static solid pairs produce no intent,
  but a trigger pair emits its event before the mobility check);
  `AudioController.queueCollision` and `SensoryBus.enqueuePlayerImpacts`
  consume player contacts in order under caps.
- **Steering static snapshot** (`steering.zig`): lazy rebuild when invalid or
  the cell size changed; `rebuildStaticObstacleSnapshot` walks
  `collision_responses` in store order, filters `.static` with bounds and
  movement, reads `previous_x`, and derives `spatial_obstacle_query_extra`
  from content. `ObstacleSnapshotRow` carries the row level and
  `accumulateObstacleSample` skips other-level obstacles (landed).
  Invalidation: `reactToPostCommitSteeringEvents` and
  `eventInvalidatesStaticObstacleSpatial` (fires on static
  `.world_level` changes too).
- **Static contract:** `isStaticNavigationObstacle` = movement + bounds +
  `mobility == .static`. Nothing moves a body without `ai_agent` except
  movement integrate (zero velocity) and structural commands (`world_gate`
  and plane traversal touch AI rows and the player only; collision response
  never writes the static side). A created static emits `component_changed`
  with `is_static`.
- **Scope:** collision gates on `tier.allowsCollision()` via
  `gatherCollisionBoundsIndices`, with a null fast path when no dormant or
  kinematic rows exist.
- **Pipeline:** `stageSteeringUpdate`, `stagePathfindingUpdate`,
  `stageCollisionDetect`; `SimulationPipelineConfig.static_obstacle_capacity`
  (steering reserve); post-commit reactions from
  `GameDemoState.applyStructuralCommandsAndPostCommitEvents`.
- **Group fields** (`systems/pathfinding/`): `GroupField` state
  `empty|building|ready` with `beginBuild`/`expand`/`sample`; `group_fields`
  reserved to `max_group_fields`, sized O(cells) at nav build;
  `serviceGroupFields` → `ensureGroupField` → `buildGroupSlot` (empty slot
  first, else round-robin `next_group_evict`, plus stale-slot rekey); each
  building field expands `group_field_build_budget` (8192) per step;
  `statusForKeyAndStart` samples a ready field for any request kind. Every
  nav update drops **all** fields (`dropGroupFields`), although fields are
  level-local and `affected_levels` is known. Demo: `max_group_fields = 4`;
  live, it builds no demand field.
- **Threshold and agent budget (landed):** `groupFieldThreshold` =
  `clamp(min_group_field_agents, 1, @max(min_capacity_floor,
  group_field_threshold_ceiling))`, the ceiling frozen at `reserve`; default
  `default_min_group_field_agents = 1024`; demo pin 2000.
  `proceduralPathfindingCapacity` sets `max_agent_budget =
  @max(population.intent_capacity, min_group_field_agents)`;
  `default_max_agent_budget = 4096` is the library default for bare callers.
- **Benches:** `collision` / `collision-sparse` and the pathfinding groups,
  registered in `runner.zig`.

### Architecture notes

**Parts and gates.**

- **71B.1** (ungated): shared static-collider rows + steering migration. The
  foundation 71B.2 depends on.
- **71B.2** (bench-gated): collision static/dynamic split. Gate: `zig build
  -Doptimize=ReleaseFast bench -- --group collision-static-heavy-sap --case
  serial-direct` shows the 4096-static row's mean ≥ 2.0× its 256-static row.
  The control group is the first checklist item. If the gate fails, 71B.2 is
  closed as measured not needed (numbers in the commit message).
- **71B.3** (gated on 62 and 71A, whose posted guards, anchors, and patrol
  routes are its sources): path prewarm. The A/B capture in Acceptance sets
  the demo default for `prewarm_shared_goals`.
- Slices 61 and 62 keep adding world-sized terms to the contact, trigger,
  and intent capacity body count; the split removes only static×static
  pairs, so those dynamic×static terms stay.

**71B.1: `StaticColliderIndex` rows** (`src/game/systems/static_colliders.zig`,
owned by `SimulationPipeline` as `static_colliders`)

- Rows: `std.MultiArrayList(StaticColliderRow{ entity: EntityId, level: u16,
  min_x, min_y, max_x, max_y: f32, grid: bool })`.
- Membership and order equal today's steering walk: `collision_responses` in
  store order, `mobility == .static`, with bounds and movement dense indices.
  AABB uses collision's expression (`min = body.position + offset; max = min
  + size`), so proxies and rows are bit-identical. `level` is
  `worldLevelConst(entity) orelse 0`.
- `version: u32` bumps on every rebuild; `dirty: bool = true` at init.
  `ensureBuilt(data) !void` rebuilds when dirty, on the main thread; both
  `stageSteeringUpdate` and `stageCollisionDetect` call it first (first
  caller builds; no new stage). Rows reserve to
  `config.static_obstacle_capacity` at init; past it the cold,
  event-triggered rebuild grows amortized.
- Invalidation: `eventInvalidatesStaticColliders(event)` replaces steering's
  `eventInvalidatesStaticObstacleSpatial`. It fires on
  `entity_destroyed.was_static_navigation_obstacle`, and on
  `component_changed` of `movement_body`, `collision_bounds`, `world_level`,
  `collision_response`, `ai_agent`, or `steering_agent` when
  `was_static_navigation_obstacle or is_static_navigation_obstacle`.
  `SimulationPipeline.reactToPostCommitStaticColliderEvents(frame)` sets
  `dirty`; `reactToPostCommitSteeringEvents` keeps only the
  steering↔movement index part; `invalidateStaticColliders()` serves
  out-of-band edits.
- Contract: `PipelineResource.static_colliders` in `external_resources`;
  `steering_update` and `collision_detect` list it in `carried`. That is
  honest because `ensureBuilt` is idempotent within a step and nothing
  between the two stages writes a static body: the in-stage rebuild
  materializes seam-committed state (`dirty` comes from the post-commit
  reaction, out-of-band invalidation, or 71B.2's mismatch path, which takes
  effect next step). A comment at both call sites says so.
- Slice 64B field table: `static_colliders` is `checksum_cache_fields`
  (proving tests: single-SAP parity and steering bit-identity, cold vs warm
  index); the steering snapshot row stays `cache`, citing `static_colliders`
  as its source.
- Steering migration: `rebuildStaticObstacleSnapshot` reads the shared rows
  (same order and membership, so the same `obstacle_index` numbering, bins,
  and `spatial_obstacle_query_extra`) and rebuilds when
  `static_colliders.version != obstacle_index_version` or the cell size
  changed; the row level comes from the shared rows. Single-level output is
  bit-identical except the step after a `set_movement_body` teleport of a
  static with `previous_position ≠ position` (shared rows use the committed
  position).

**71B.2: collision static/dynamic split**

- **Grid eligibility** (built in the same `ensureBuilt` pass): not
  `.trigger`; no `ai_agent` or `steering_agent`; `velocity == 0 and speed ==
  0`; half-extents ≤ `static_collider_max_half_extent`; finite; cell
  coordinates within `i24`. Other statics stay in the SAP; their pairs with
  grid statics are still found because every SAP proxy queries the grid.
- `grid_entries: std.ArrayList(GridEntry{ key: u64, row: u32 })`, one per
  grid row, center-binned: `cx = floor(center_x / 64)` (likewise `cy`);
  `key = level << 48 | @as(u24, @intCast(cy + 0x800000)) << 24 | @as(u24,
  @intCast(cx + 0x800000))` (bias keeps geometric order); sorted with
  `std.sort.pdq` by `(key, entity.index, generation)`; O(statics) storage.
  A sorted key array searched by binary search, off MAL
  (`.claude/rules/memory-performance.md`).
- `grid_static_generation: std.ArrayList(u32)` indexed by `entity.index` (0
  = not grid), the gather skip test; unaffected by dense renumbering. It is
  sized by entity slots, not static count: `SimulationPipelineConfig` gains
  `entity_slot_capacity: usize = 0` (the demo passes its structural entity
  reserve total) and `reserve` calls `ensureTotalCapacity` on it. At rebuild
  the length is `max grid entity.index + 1` with `assert(max_index <
  reserved_capacity)`; past the reserve it grows amortized and logs one
  `logging.game.warn` (index, reserve), counted in
  `CollisionStats.static_generation_grown`.
- Fixed constants: `static_collider_cell_size = 64`;
  `static_collider_max_half_extent = 64` (statics up to 128×128);
  `static_collider_query_slack = 1` px. None is content-derived.
- **Query** (in the broadphase range job, per SAP proxy `d` in sorted
  order): `cx0 = floor((d.min_x − 64 − 1) / 64)`, `cx1 = floor((d.max_x + 64
  + 1) / 64)`, likewise `cy`, clamped to `i24`; per `cy`, `lowerBound(key(L,
  cy, cx0))` then scan while `key ≤ key(L, cy, cx1)`. Emit `StaticPair{
  proxy: u32, row: u32 }` on strict overlap (`overlap_x > 0 and overlap_y >
  0`). An overlapping static's center lies within `(d.min − half, d.max +
  half)` with `half ≤ 64`, so no pair is missed. No candidate cap; work is
  bounded by the dynamic's extent and statics present.
  `BroadphaseRangeBuffer` gains `static_pairs` with the same
  `required_capacity` overflow → grow → replay, reserved at `range_len × 2`;
  the serial path gets `static_pairs_serial` with checked counting.
- **Gather:** `gatherBodies` skips grid statics (`entity.index < gen.len and
  gen[entity.index] == entity.generation`) before any slot lookup. `order`
  is sized to dynamic proxies; touched statics append to `rows` after sort
  and broadphase.
- **Main-thread resolve, orient, merge** (after the broadphase join):
  1. merge `static_pairs` in range order;
  2. resolve each touched row once (stamp arrays reserved to row count at
     rebuild, `touch_epoch: u32`): row alive and
     `scope.tier[mi].allowsCollision()` (dormant/kinematic dropped, as in
     the SAP); live AABB, level, and velocity must equal the row, else count
     `static_index_mismatch`, set `dirty`, use live values, and drop the pair
     if it no longer overlaps; append a static proxy row with live
     `movement_index` and velocity 0;
  3. orient so `a` has the lower `proxyIndexLessThan` key;
  4. `std.sort.pdq` static pairs by `(key(a), key(b))`;
  5. merge backward in place into `candidate_pairs` (capacity dyn + static)
     by the same comparator.

  Narrowphase, contact merge, and response are unchanged.
- **Parity:** split contacts = single-SAP contacts minus grid×grid pairs,
  identical in every field and order. Removed pairs are output-neutral (no
  intent, no trigger, no player).
- `CollisionConfig.static_colliders: ?*const StaticColliderIndex = null`;
  null is today's single SAP (benches, bare users).
- **Static contract:** a grid static moves only through structural commands.
  Debug builds verify every grid row against its live body each step in
  `stageCollisionDetect`; release builds rely on eligibility plus per-touch
  validation. The index assumes no processor writes a static-mobility body
  (a future writer such as knockback would exclude statics or set `dirty`).
- **Threading:** query writes go to range-disjoint padded buffers reserved
  before dispatch; resolve, sort, and merge are serial.
- **Stats:** `CollisionStats` gains `static_rows`, `static_grid_rows`,
  `static_pairs`, `static_touched`, `static_index_mismatch`,
  `static_rebuild_ns` with perf metrics; `body_count` counts SAP proxies
  only (documented).

**71B.3: group-field prewarm for authored shared goals**

- `GroupField` gains `origin: GroupFieldOrigin = .demand` (`enum { demand,
  prewarm }`) and `prewarm_source: PrewarmSourceId = .none` (`{ slot: u16,
  generation: u16 }`).
- **Source domain** (slot-ordered): interest-marker slots `[0,
  interest_marker_capacity)` (128) of kind `patrol` or `resource`, then
  Slice 62 anchor slots up to `path_prewarm_source_domain =
  interest_marker_capacity + spawn_anchor_capacity`, computed at load and
  stored on the pipeline. A larger domain only lengthens the sweep period.
  Merchant positions are excluded (merchants move; 71D's `trade` goal uses
  the demand path).
- **Eligibility:** slot live with matching generation; its level has a nav
  grid; `simViewRegion(context)` non-null and the source chunk's
  level-anchored `lodDistance` ≤ `path_prewarm_band_chunks`. Goals match the
  71A `patrol`/`return_home` resolvers and Slice 61 forage fallback exactly
  (same `keyForWorld` cell).
- **Per step**, pipeline method `prewarmSharedGoals(step)` in
  `stagePathfindingUpdate` after `pathfinding.update` (main thread):
  1. Release: `pathfinding.releasePrewarmFieldsWhere(ctx, comptime keepFn)`
     (static dispatch) empties every `.prewarm` field whose source is no
     longer eligible (≤ `max_group_fields` checks).
  2. Visit `path_prewarm_candidates_per_step` slots starting at
     `@intCast((step * path_prewarm_candidates_per_step) %
     path_prewarm_source_domain)` (`step: StepIndex`, `u64`). Each eligible
     source calls `pathfinding.prewarmGroupField(level, pos, .default,
     source)` → `.started | .present | .no_empty_slot | .no_goal_cell`; stop
     after `path_prewarm_goals_per_step` starts. It claims only `.empty`
     slots, never evicts, and reuses `buildGroupSlot(…, origin = .prewarm)`
     and `projectToNearestOpen`.
- **Demand interaction:** `ensureGroupField` reusing a `.prewarm` field
  promotes it to `.demand`; with no empty slot, eviction takes the
  lowest-index `.prewarm` slot before round-robin; `staleGroupSlot` may rekey
  a prewarm slot (rebuilt as `.demand`). Building prewarm fields advance in
  `serviceGroupFields` under the same per-field budget, so the per-step worst
  case stays `max_group_fields × group_field_build_budget`.
- **Level-scoped drop:** the incremental branch of `applyNavUpdatesImpl`
  calls `dropGroupFieldsOnLevels(affected_levels)` (fields are built and
  sampled on their goal level only); the version-bump branch drops all. Both
  origins.
- **Shared cache-reaction helper:**
  `PathfindingSystem.reactToGraphUpdate(stats, affected_levels,
  eviction_spans, had_full_level)` owns the version bump, full-level clear,
  scoped eviction, and group-field drop; the synchronous branch and 65B's
  deferred swap both call it. Whichever of 65B/71B.3 lands first introduces
  it; 71B.3 changes only the drop inside it.
- No world scaling: no sectors or quantization, no use of
  `groupFieldThreshold`; `ResultCache` untouched.
- **Constants:**

  | Constant | Value | Reason |
  | --- | --- | --- |
  | `path_prewarm_goals_per_step` | 1 | at most one new field per step |
  | `path_prewarm_candidates_per_step` | 8 | full sweep of `D` slots every `ceil(D / 8)` steps |
  | `path_prewarm_band_chunks` | `cognition_halo_chunks` (16) | prewarm only where agents decide |
  | `PathfindingCapacity.prewarm_shared_goals` | `true` (default) | runtime policy knob; demo value set by the A/B acceptance |

- **Contract:** `pathfinding_update` adds `interest_markers` (external) and
  `spawn_anchors` (later writer `population_update`) to `carried`.
- **Stats:** `PathfindingStats` gains `prewarm_started`, `prewarm_released`,
  `prewarm_promoted`, `prewarm_no_slot`, `prewarm_no_sim_view` with perf
  metrics.
- **Checksum:** prewarm fields are `normalized` (64B), since a prewarmed
  field changes which requests short-circuit; `normalize` resets each to
  `.empty`, `origin = .demand`, `prewarm_source = .none` (64B B5 (d)). The
  step-derived cursor holds no state.
- **Allocation:** fields are reserved O(cells) at nav build; prewarm
  allocates nothing.

### Checklist

- [x] **71B.1** Fixed group-field threshold (`default_min_group_field_agents
      = 1024`, world-size derivation deleted, pin clamped) with
      world-size-independence, ceiling, and clamp tests.
- [x] **71B.1** Capacity-audit follow-up: content-sized demo
      `max_agent_budget`, threshold ceiling frozen at reserve, nav-memory
      requirement test.
- [ ] **71B.1** `static_colliders.zig` rows + `version`/`dirty` +
      `ensureBuilt`; `eventInvalidatesStaticColliders` (moved + extended)
      with a table test over every listed event/component and a negative
      (`primitive_visual`, value-only `set_resource_node`);
      `reactToPostCommitStaticColliderEvents` wired in
      `applyStructuralCommandsAndPostCommitEvents`;
      `PipelineResource.static_colliders` external + carried by
      `steering_update`/`collision_detect`, with the idempotence comment at
      both `ensureBuilt` call sites; `FailingAllocator` rebuild within
      `static_obstacle_capacity`; Slice 64B field-table rows
      (`static_colliders` = `checksum_cache_fields`, steering snapshot note)
      with the cold-vs-warm proving test.
- [x] **71B.1** `ObstacleSnapshotRow.world_level` and same-level gate in
      `accumulateObstacleSample`, with static `.world_level` invalidation.
- [ ] **71B.1** Steering reads the shared rows (version-driven rebuild),
      carrying `world_level` from the shared rows into the existing gate.
- [ ] **71B.2 (gate item, lands first)** Bench groups in
      `src/benchmarks/collision.zig`, registered after `collision.sparse_group`:
      `collision-static-heavy-sap` (null index, today's path) and
      `collision-static-heavy` (production config with the index built once
      outside timing), plus `collision-static-index-rebuild` (rebuild only).
      Fixture: items = static count (`defaultItemCounts`: quick 256/1024/4096,
      standard + 16384, stress 4096/16384); 28×24 px statics on a 40 px grid
      with every 10th offset 16 px into its neighbour (static×static
      overlaps); `static_heavy_dynamic_count = 512` 12×12 dynamics on a
      hashed-jitter lattice over the static field, ~30% overlapping a static.
- [ ] **71B.2** Grid build (eligibility, center keys, pdq sort,
      `grid_static_generation` reserved to
      `SimulationPipelineConfig.entity_slot_capacity` with the assert and the
      grow-and-warn fallback; the demo passes its entity reserve) with tests:
      oversize/trigger/agent/moving statics are not grid; negative
      coordinates and out-of-`i24` cells; key order equals `(level, cy, cx)`
      geometric order.
- [ ] **71B.2** `CollisionConfig.static_colliders`, gather skip, range-job
      grid query with `static_pairs` overflow/replay (threaded + serial),
      main-thread resolve (stamps, scope tier, live validation + mismatch
      counter + `dirty`), orient, sort, in-place merge; stats; Debug full
      verification.
- [ ] **71B.2 parity tests** (small hand-built fixtures): split vs null-index
      contacts equal after filtering grid×grid from the reference — fixture
      includes a static trigger over a grid static, a 200×20 static wall,
      a static with `ai_agent`, a kinematic-tier static under a dynamic
      (scope list non-null), a level-1 static under a level-0 dynamic, a
      dynamic straddling 4 cells, equal `min_x` ties, negative coordinates;
      then `CollisionResponseSystem.update` on both streams gives identical
      positions/velocities/triggers. Serial vs threaded (0, 1, 2 workers × two
      range sizes) identical. A static moved out-of-band (test-only direct
      body write, no event) is caught by the touch validation (counter,
      `dirty`, live-value contact) and by the Debug verification.
- [ ] **71B.2** `FailingAllocator`: warmed split `update` (serial + 2-worker)
      allocates nothing; rebuild within reserve allocates nothing. The
      rebuild proof creates `entity_slot_capacity` entities and makes the
      **last** one (`entity.index == entity_slot_capacity - 1`) a grid
      static, so the `grid_static_generation` reserve is exercised at its
      bound. A second test with one entity past the reserve takes the grow
      fallback and counts `static_generation_grown`.
- [ ] **71B.2** Pipeline wiring: `stageCollisionDetect` calls
      `static_colliders.ensureBuilt` and passes the index. Contact, trigger,
      and intent reserves are unchanged: the 61/62 static terms still
      warm-size dynamic×static contacts. Add a pipeline test that the reserve
      test's literal worst case is unchanged.
- [ ] **71B.3** `GroupFieldOrigin`, `PrewarmSourceId`, `prewarmGroupField`,
      `releasePrewarmFieldsWhere`, prewarm-preferred eviction, promotion,
      `buildGroupSlot` origin parameter, `dropGroupFieldsOnLevels`. Tests:
      prewarm claims only `.empty` and returns `.no_empty_slot` when full;
      demand eviction takes the prewarm slot first; reuse promotes; a ready
      level-0 field survives a level-1 incremental update and is dropped by a
      level-0 one; version bump drops all. The drop runs through the shared
      `reactToGraphUpdate` helper. If 65B has landed, its
      equivalence-to-synchronous test gains a case where a field on an
      unaffected level survives both the synchronous path and the deferred
      swap.
- [ ] **71B.3** Slice 64B normalization (B5 (d)): `PathfindingSystem.normalize`
      resets each group field to `.empty`, `origin = .demand`,
      `prewarm_source = .none`; the 64B test "normalized pathfinding equals a
      freshly initialized system" covers a pipeline holding a ready prewarm
      field and a building one.
- [ ] **71B.3** Pipeline `prewarmSharedGoals` (release → cursor → start),
      eligibility via `simViewRegion(context)`, contract carried edits,
      stats/perf metrics. Tests: cursor at `step = maxInt(u32) - 1`,
      `maxInt(u32)`, and `maxInt(u32) + 1` (the `StepIndex` continues past
      `u32`) matches a hand-computed reference; a removed marker
      (generation change) releases its field next step; a source leaving the
      band releases; null sim view prewarms nothing and counts it; a 71A
      patroller whose goal is a prewarmed marker gets `.available` from
      `statusForWorld` and emits no path request once the field is ready;
      `FailingAllocator` over 64 steps of prewarm after reserve;
      whole-pipeline serial == threaded with prewarm on.
- [ ] **71B.3** Bench group `pathfinding-prewarm`
      (`src/benchmarks/pathfinding.zig`, registered after
      `pathfinding.query_group`): 256×256/32 px grid, items = in-band sources
      (16/128/384), 4 field slots, timed per step = release + cursor + one
      start + building expansions.
- [ ] Docs: `docs/architecture.md` (shared static index, static contract,
      collision split, prewarm origin policy, fixed group threshold);
      `docs/simulation-tiers-and-pipeline.md` (`static_colliders` external
      resource, contact-order parity); `docs/development-workflow.md`
      bench examples; roadmap Scaling Gaps "Path group fields + cache
      pressure" and "Collision full-sort under melee density" note that
      statics leave the sort once 71B.2 lands.
- [ ] Add the static-mobility writer rule to `.claude/rules/simulation.md` when this lands.

### Acceptance checks

- [ ] 71B.1: the steering suite passes unchanged and the level-gate test
  passes. Steering no longer walks `collision_responses` on rebuild
  (`--group steering` within noise or faster).
- [ ] 71B.2 parity: identical filtered contact streams and identical response
  outcomes across every fixture and worker/range configuration.
- [ ] 71B.2 bench gate, ReleaseFast, same session, 4096 statics:
  - `--group collision-static-heavy` is ≤ 0.5× `collision-static-heavy-sap`
    for `serial-direct` and ≤ 0.6× for `thread-adaptive-tuned-range`;
  - at 256 statics it is ≤ 1.05× the control;
  - `--group collision` and `--group collision-sparse` (no statics, empty
    index) stay within noise;
  - `--group collision-static-index-rebuild` is recorded.
- [ ] 71B.2 battle soak (ReleaseSafe, 60 s, 2048 movers), recorded as
  diagnostic trend data against the control band: the collision stage and the
  `collision_setup` gather/sort lines. `static_index_mismatch` is 0 and
  `static_touched` is recorded.
- [ ] 71B.3 A/B capture (ReleaseSafe, 60 s, the demo with Slice 62 settlement
  population and 71A guards, prewarm on vs off), recorded as diagnostic trend
  data: `path_solved_requests`, `path_accepted_requests`,
  `path_group_field_reuses`, `prewarm_promoted`, and the pathfinding stage
  line. The gate is the `pathfinding-prewarm` bench: fewer solves with prewarm
  on and no regression beyond run-to-run spread
  (`.claude/rules/tests-benchmarks.md`).
  - If the bench gate fails, set `prewarm_shared_goals = false` in
    `proceduralPathfindingCapacity` (numbers in the commit message). The
    mechanism and its tests still land.
  - The `min_group_field_agents = 2000` demo pin stays unchanged in this
    slice.
- [ ] `zig build bench -- --group pathfinding-prewarm` is recorded, and the
  `pathfinding-group-field-detour*` groups stay within noise (the
  `samples_total > 0` guard holds).
- [x] 71B.1 fixed threshold: no budget derives from world size; the
  retired derivation constants are gone.
- [x] 71B.1 capacity-audit follow-up: no pathfinding threshold or capacity
  default cites world size; default-demo `groupFieldThreshold()` is 2000.
- [ ] `zig build check` (comptime contracts) and `zig build verify` pass.

### VoidLight reference

- **Static split:**
  - VoidLight pre-sorts statics and binary-searches per movable
    (`src/managers/CollisionManager.cpp:1725-1779`). **Not ported:** the
    search assumes `maxX` is monotonic in `minX` order, which it is not, and
    a 1D x-sweep degrades in tall worlds.
  - ZeroLight keeps the idea, a commit-built sorted static structure queried
    per dynamic. It uses a level-aware 2D center grid with a fixed extent
    bound, and the merge reproduces SAP contact order exactly.
- **Prewarm:**
  - VoidLight `PathfinderManager.cpp:1334-1361` prewarms a sector graph sized
    by world width (`worldW / 200` endpoint quantization, 4/8/16 sectors,
    5% of the world diagonal). **Rejected:** every budget is world-scaled.
  - ZeroLight prewarms only authored shared goals inside the band, into
    otherwise-idle field slots, under fixed per-step caps, and yields to
    demand.
