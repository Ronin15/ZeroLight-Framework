## Slice 71B: Static Collider Index, Collision Static Split, And Group-Field Prewarm

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 62](slice-62.md), [Slice 71A](slice-71a.md) (71B.3 only; 71B.1 ungated, 71B.2 bench-gated) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** Landed 2026-10-05: 71B.1's first item (the fixed
group-field threshold) and the 71B.1 steering level gate. 71B.1 capacity-audit
follow-up landed 2026-10-06: the demo's `max_agent_budget` is content-sized
(2053 at battle scale, was 4096) and the threshold clamp uses the ceiling
frozen at reserve. Nav-memory requirement for the procedural capacity
(`budgetForCapacity(...).requiredBytes`, 0 links): 512,998,432 B → 362,372,128
B; `autoSizedMaxNavMemoryBytes` rounds both to 536,870,912 B (the same power
of two). The rest of 71B.1 (static-collider rows, steering migration), 71B.2,
and 71B.3 are not started. It has three parts with different gates:

- **71B.1, fixed group-field threshold + shared static-collider rows +
  steering migration + steering level gate.** No gate. It needs only live
  code and can land any time. It is the foundation that 71B.2 depends on.
  - **Its first checklist item, the fixed group-field threshold, fixes a
    confirmed live violation** of the CLAUDE.md fixed-budget rule
    (`pathfinding/system.zig:220-225`, `types.zig:88-96`). It lands
    unconditionally and first, as its own change if the rest of 71B.1 is not
    ready. It must not wait for 62, 71A, a bench gate, or the static-collider
    work: it shares no code with any of them.
- **71B.2, collision static/dynamic split.** Gated on a bench. Gate:
  `zig build -Doptimize=ReleaseFast bench -- --group collision-static-heavy-sap --case serial-direct`
  shows the 4096-static row's mean ≥ 2.0× its own 256-static row (statics
  dominate the broadphase and sort). The control group lands in the first
  checklist item so the gate can be measured. If it is not met, record both
  numbers in this Status and 71B.2 stays not started. That is a measured "not
  needed", not a backlog line.
- **71B.3, path prewarm.** Gated on **62** and **71A** landing, because its
  sources (posted guards, anchors, patrol routes) must exist. The demo
  default for `prewarm_shared_goals` is decided by the A/B capture in
  Acceptance.

Slices 61 and 62 keep adding their world-sized capacities to the contact,
trigger, and intent capacity body count, before and after 71B.2. The split removes only
static×static pairs, and the dynamic×static contacts those terms warm-size
still exist.

Goal:

- Steering and collision read **one** commit-rebuilt, level-aware static
  collider structure instead of re-deriving static obstacles separately.
- Collision stops re-gathering, re-sorting, and pair-testing static
  colliders every step. Its contact stream is byte-identical to today's
  single SAP minus static×static pairs, in identical order.
- The `PathfindingSystem` prewarms reverse-Dijkstra group fields for authored
  shared goals inside empty `group_fields` slots, under fixed per-step
  budgets.
- The derived world-scaled group-field threshold is replaced by a fixed
  constant (71B.1, first, ungated).

### Current foundation (do not rebuild)

- **Collision** (`src/game/systems/collision.zig`):
  - `ProxyRow` MAL (`:71-85`) and `CollisionConfig` (`:99-111`).
  - `gatherBodies` (`:407-443`) does 3 slot lookups per bounds row every
    step.
  - `ensureOrder` (`:453-461`) and the warm insertion / full `sortWarm`
    (`:587-603`).
  - Serial SIMD SAP (`:643-704`) and the threaded range SAP with
    overflow-grow-replay (`:706-743,771-813`).
  - Range-order pair merge (`:563-577`).
  - Narrowphase SIMD with a scalar tail (`:831-895`), bit-identical to
    `contactForCandidate` (`:905-929`; parity test `:1658`).
  - Sort key `proxyIndexLessThan` = `(min_x, min_y, entity.index,
    generation)` (`:960-971`).
  - The SAP emits **exactly** every same-level, positive-overlap pair. Pair
    order is lexicographic `(key(a), key(b))` with `a` the earlier-sorted
    proxy.
- **Contact consumers are order-sensitive:**
  - `CollisionResponseSystem` applies intents sequentially
    (`collision_response.zig:228-260`). Static×static solid pairs produce no
    intent (`:148`), but a trigger pair emits a trigger event before the
    mobility check (`:117-121`).
  - `AudioController.queueCollision` (`audio_controller.zig:99`) and
    `SensoryBus.enqueuePlayerImpacts` (`sensory_bus.zig:174`) consume
    player-involving contacts in order under caps.
- **Steering static snapshot** (`src/game/systems/steering.zig`):
  - Fields at `:136-140`. It rebuilds lazily when invalid or the cell size
    changed (`:491-505`).
  - `rebuildStaticObstacleSnapshot` (`:561-606`) walks `collision_responses`
    in store order, filters `.static` with bounds and movement, reads
    `previous_x`, and has a content-derived `spatial_obstacle_query_extra`.
  - `ObstacleSnapshotRow` has **no level** (`:926-931`). The obstacle query
    (`:1135-1158`) and `accumulateObstacleSample` (`:1168-1200`) apply
    **no level gate**. **Live defect:** underground agents avoid surface
    crates and the reverse. *(Fixed 2026-10-05 ahead of the shared-rows
    migration: see the split checklist item below. Line refs in this
    section predate that fix.)*
  - Invalidation is `reactToPostCommitSteeringEvents` (`:190-206`) and
    `eventInvalidatesStaticObstacleSpatial` (`:1403-1413`).
- **Static contract:** `isStaticNavigationObstacle` = movement + bounds +
  `mobility == .static` (`data_system/system.zig:336-341`). Nothing moves a
  body without `ai_agent` except movement integrate (zero velocity) and
  structural commands:
  - `world_gate.apply` touches AI rows and the player only
    (`world_gate.zig:17-28,36-47`);
  - plane traversal touches the player and AI only
    (`dig_controller.zig:313-338`);
  - collision response never writes the static side.

  Create records template component changes (`data_system/structural.zig:350-357`),
  so a created static emits `component_changed` with `is_static`.
- **Scope:** collision gates on `tier.allowsCollision()`
  (`simulation_scope.zig:59-64`) via `gatherCollisionBoundsIndices`
  (`systems/simulation_scope.zig:255-285`), with a null fast path when no
  dormant or kinematic rows exist.
- **Pipeline:**
  - `stageSteeringUpdate` (`simulation_pipeline.zig:1190-1195`),
    `stagePathfindingUpdate` (`:1197-1204`), `stageCollisionDetect`
    (`:1230-1237`), and `reactToPostCommitSteeringEvents` (`:850-855`).
  - `SimulationPipelineConfig.static_obstacle_capacity` (`:373`, used for the
    steering reserve at `:646`).
  - Post-commit reactions called from
    `GameDemoState.applyStructuralCommandsAndPostCommitEvents`
    (`game_demo_state.zig:653-669`).
- **Group fields** (`src/game/systems/pathfinding/`):
  - `GroupField` state `empty|building|ready`, `beginBuild`/`expand`/`sample`
    (`group_field.zig:27-31,38-76,156,185,284`).
  - The system's `group_fields` (`system.zig:86`), reserved to
    `max_group_fields` (`:257-260`) and sized O(cells) at nav build
    (`:404-406`).
  - `serviceGroupFields` → `ensureGroupField` → `buildGroupSlot`
    (`:1133-1227`): empty slot first, else a round-robin `next_group_evict`
    (`:1206-1217`), plus a stale-slot rekey (`:1247-1267`).
  - Each building field expands `group_field_build_budget` (8192) per step
    (`:1137-1144`).
  - `statusForKeyAndStart` samples a ready field for **any** request kind
    (`:801-816`), so a field serves every agent whose goal key matches.
  - Every nav update drops **all** fields (`dropGroupFields` at `:479-496`,
    `:756-759`), even though fields are level-local and `affected_levels` is
    known (`nav_graph.zig:637-677`).
  - `keyForWorld` (`nav_graph.zig:1690-1699`).
  - The demo pins `min_group_field_agents = 2000` and `max_group_fields = 4`
    (`game_demo_state.zig:210,236`). Live, the demo builds no demand field,
    so its slots sit `.empty`.
- **World-scaled threshold (live violation of the fixed-budget rule):**
  `groupFieldThreshold` derives `cellCount / default_cells_per_group_agent`
  when the pin is 0 (`system.zig:220-225`; `types.zig:89-96`: "auto-scales
  with world size"). The pin path returns the pin **unclamped**
  (`system.zig:221`). Derivation tests: `system.zig:4445-4503`.
  - Live pins (none above 4096): demo 2000 with `max_agent_budget = 4096`
    (`game_demo_state.zig:211,236`); benches 8
    (`src/benchmarks/pathfinding.zig:1045,1231,1325`); tests 1/3/4
    (`system.zig:1919,2010,2058,2093`, `test_support.zig:49,81`).
  - Unpinned bench fixtures that currently derive the threshold:
    `src/benchmarks/pathfinding.zig` capacities near `:406`, `:509`, `:617`,
    `:767`, and `:902`.
- **Benches:** `collision` / `collision-sparse` (`src/benchmarks/collision.zig:17-27`)
  and the pathfinding groups (`src/benchmarks/pathfinding.zig:29-161`),
  registered in `runner.zig:26-65`.

### Architecture notes

**71B.1, first item (ungated): fixed group-field threshold (live-violation fix)**

- `default_min_group_field_agents` becomes the fixed `1024` (the value the
  old divisor landed on for the 512×512 demo, `types.zig:91-93`). It is a
  per-query policy constant, independent of world size, cell count, and
  population.
- `default_cells_per_group_agent`, `group_field_threshold_floor`, and the
  `cellCount` branch of `groupFieldThreshold` are deleted. The function
  becomes
  `std.math.clamp(self.capacity.min_group_field_agents, 1, @max(min_capacity_floor, self.capacity.max_agent_budget))`.
  The upper bound is the live derivation's existing ceiling expression, so
  the threshold never demands more sharers than can ever exist.
- **Clamp change, stated.** The live pin path returned the pin unclamped.
  Now a pin above the population ceiling is clamped, and a pin of 0 (which
  used to mean "derive") clamps to 1. No live pin is affected: every pin is
  ≤ 2000 against a ceiling ≥ 4096 or ≥ 8 (demo 2000/4096; benches 8 against
  `@max(8, item_count)`; tests 1/3/4).
- The `PathfindingCapacity.min_group_field_agents` doc comment
  (`types.zig:465-468`) and the `types.zig:88-96` block comment drop
  "0 derives" and "auto-scales with world size". They say "fixed per-query
  threshold; never derived from world size".
- The demo's 2000 pin is unchanged.
- **Capacity-audit follow-up (2026-10-06): doc comment only.** The literal
  `default_min_group_field_agents = 1024` stays. It is a measured per-query
  policy constant. Only its `types.zig` block comment changes: it drops the
  "value the retired cellCount / 256 derivation landed on" sentence and
  states the gated operation instead (a shared flow-field build costs up to
  `group_field_max_cells` relaxations and earns that cost only for a large
  same-goal crowd). No value, test, or bench changes.
- **Capacity-audit follow-up (2026-10-06): `max_agent_budget` is a
  content-sized capacity.** `PathfindingCapacity.max_agent_budget` is the
  elastic ceiling for the request queue, result cache, and solve scratch, and
  the nav memory gate admits that ceiling at load. The demo pins the literal
  4096 against a 2048-mover battle population.
  `proceduralPathfindingCapacity` takes the population and sets
  `max_agent_budget = @max(population.intent_capacity, cap.min_group_field_agents)`
  (one navigation intent per steering agent per step, the bound
  `deriveDemoPopulationCapacity` already computes and later slices' spawn
  terms extend). The threshold never clamps below the measured
  `min_group_field_agents`: `groupFieldThreshold` (`system.zig:226`) clamps
  to `max_agent_budget`, so the `@max` keeps a small population from pulling
  the threshold down through a capacity. `default_max_agent_budget = 4096`
  stays only as the library default for bare callers (benches, tests), and
  its doc comment says so. The elastic grow/shrink policy, Slice 72 C3's seam
  raise (`raiseAgentBudget`, which composes with this content-sized initial
  ceiling) and the `dropped_requests` path are unchanged. The threshold clamp
  uses the ceiling frozen at reserve (`group_field_threshold_ceiling`), so a
  seam raise never moves the group-field policy: without it a configuration
  whose budget is below `min_group_field_agents` changed its threshold when
  the memory gate admitted a raise (budget 8 → threshold 8; raised to 48 →
  threshold 48), making behavior follow capacity history.
- **Unpinned bench fixtures** (`pathfinding.zig` near `:406/:509/:617/:767/:902`)
  move from the derived value to 1024 (clamped by their budget). Record each
  affected `pathfinding*` group before and after. Where a case's purpose
  depends on group fields building, pin that fixture's literal explicitly.
  That is a fixture constant, not a runtime derivation.
- Nothing else in 71B touches this item.

**71B.1: `StaticColliderIndex` rows (`src/game/systems/static_colliders.zig`, owned by `SimulationPipeline` as `static_colliders`)**

- Rows: `std.MultiArrayList(StaticColliderRow{ entity: EntityId, level: u16,
  min_x, min_y, max_x, max_y: f32, grid: bool })`. This is the default
  layout.
- Membership and order are **exactly** today's steering walk:
  `collision_responses` in store order, `mobility == .static`, with bounds
  and movement dense indices.
- The AABB uses collision's expression,
  `min = body.position + offset; max = min + size` (`collision.zig:426-437`),
  so collision proxies and index rows are bit-identical.
- `level` is `worldLevelConst(entity) orelse 0`.
- `version: u32` bumps on every rebuild, and `dirty: bool = true` at init.
- `ensureBuilt(data) !void` rebuilds when dirty, on the main thread.
  - Both `stageSteeringUpdate` and `stageCollisionDetect` call it first; the
    first caller builds. It runs inside stages, so there is no new stage.
    Statics do not move between those stages.
  - Rows are reserved to `config.static_obstacle_capacity` at init, so a
    rebuild within that capacity allocates nothing.
  - Past it, the rebuild grows amortized. It is a cold, event-triggered path,
    the same policy as steering's existing rebuild.
- **Invalidation (shared predicate, the only one).**
  `eventInvalidatesStaticColliders(event)` moves out of steering
  (`eventInvalidatesStaticObstacleSpatial` is deleted). It fires on:
  - `entity_destroyed.was_static_navigation_obstacle`;
  - `component_changed` of `movement_body`, `collision_bounds`,
    `world_level`, `collision_response`, `ai_agent`, or `steering_agent`
    when `was_static_navigation_obstacle or is_static_navigation_obstacle`.

  `SimulationPipeline.reactToPostCommitStaticColliderEvents(frame)` sets
  `dirty`. `reactToPostCommitSteeringEvents` keeps only the
  steering↔movement index-cache part.
  `SimulationPipeline.invalidateStaticColliders()` serves out-of-band edits
  (tests, init).
- `PipelineResource.static_colliders` is added to `external_resources`
  (committed at the seam). `steering_update` and `collision_detect` add it to
  `carried`.
  - **Why `carried` is honest although the first caller rebuilds in-stage.**
    `ensureBuilt` is idempotent within a step: it rebuilds only when `dirty`.
    `dirty` is set by the post-commit reaction and by `invalidateStaticColliders`
    (out of band), and in 71B.2 by the mismatch path inside `collision_detect`,
    which runs after both reads and takes effect at the next step's first
    call. Statics cannot change between `steering_update` and
    `collision_detect`, because nothing in between writes a static body (see
    the static contract). So the in-stage rebuild is a lazy materialization
    of seam-committed state, not a mid-step write that a later stage could
    observe differently. A comment at both `ensureBuilt` call sites states
    this.
- **Slice 64B field table** (consistency F18), same change:
  - `SimulationPipeline.static_colliders` is `checksum_cache_fields`. Its
    proving test is 71B's single-SAP parity test plus the steering
    bit-identity test: a cold (dirty) index and a warm one produce identical
    contacts and steering output.
  - The `steering` obstacle snapshot row stays `cache`; its row note now
    cites `static_colliders` as its source.
- **Steering migration:**
  - `rebuildStaticObstacleSnapshot` reads the shared rows instead of walking
    responses: same order and membership, so the same `obstacle_index`
    numbering, bins, and `spatial_obstacle_query_extra`.
  - It rebuilds when `static_colliders.version != obstacle_index_version` or
    the cell size changed.
  - `ObstacleSnapshotRow` gains `world_level`.
  - `accumulateObstacleSample` skips an obstacle whose level ≠ the agent's
    `movementScopeLevel` (the agent snapshot already carries it). The skip
    still counts against `max_obstacle_candidate_checks`, so single-level
    candidate truncation is unchanged.
  - Result: on single-level worlds steering output is **bit-identical**. The
    only exception is the step right after a `set_movement_body` teleport of
    a static whose command wrote `previous_position ≠ position`; the shared
    rows use the committed position, the correct one. Multi-level worlds get
    the level fix.

**71B.2: collision static/dynamic split**

*Grid (built in the same `ensureBuilt` pass as the rows)*

- A row is `grid = true` (grid-eligible) when all of these hold:
  - `CollisionResponse.mode != .trigger`;
  - no `ai_agent` and no `steering_agent`, so no processor writes its
    velocity or position;
  - `velocity == 0 and speed == 0` at build;
  - half-extents `≤ static_collider_max_half_extent`;
  - finite;
  - cell coordinates within the `i24` range.

  Every other static (triggers, oversize walls, agent-carrying, moving) stays
  in the SAP. Their pairs with the grid are still found, because every SAP
  proxy queries the grid.
- `grid_entries: std.ArrayList(GridEntry{ key: u64, row: u32 })`, one entry
  per grid row, center-binned:
  - `cx = floor(center_x / 64)`, likewise `cy`;
  - `key = level << 48 | @as(u24, @intCast(cy + 0x800000)) << 24 | @as(u24, @intCast(cx + 0x800000))`,
    so the bias keeps geometric order;
  - sorted with `std.sort.pdq` by `(key, entity.index, generation)`;
  - storage is O(statics), never sized from world extent.

  This is a named exception to the MAL default: a sorted key array searched
  by binary search (spatial hash grid).
- `grid_static_generation: std.ArrayList(u32)`, indexed by `entity.index`
  (0 = not a grid static). It is the gather skip test. Dense collision-bounds
  renumbering (any destroy) does not touch it.
  - **Sized by the quantity that indexes it.** It is keyed by
    `entity.index`, which is bounded by the entity-slot count, not by the
    static count. So `static_obstacle_capacity` (the row reserve) is the wrong
    bound for it: a fixture with low indices would pass a reserve proof that
    a production rebuild then fails.
  - `SimulationPipelineConfig` gains `entity_slot_capacity: usize = 0`, the
    caller's structural entity reserve (the demo passes its reserved body
    count plus every named non-body term, the same total its structural
    reserve already sums). `StaticColliderIndex.reserve` calls
    `grid_static_generation.ensureTotalCapacity(entity_slot_capacity)` at
    init.
  - At rebuild, the length is set to `max grid entity.index + 1` with
    `std.debug.assert(max_index < reserved_capacity)`. Because ReleaseFast
    strips that assert, the rebuild also carries an explicit fallback: past
    the reserve it grows amortized (the rebuild is cold and event-triggered)
    and logs one `logging.game.warn` with the index and the reserve, counted
    in `CollisionStats.static_generation_grown`.
- Fixed constants:
  - `static_collider_cell_size = 64` (2 tiles);
  - `static_collider_max_half_extent = 64` (statics up to 128×128; demo
    crates, Slice 61 nodes, and Slice 58 props fit);
  - `static_collider_query_slack = 1` px (float-rounding margin on the
    center bin).

  None is content-derived. Steering's `spatial_obstacle_query_extra`
  derives from content and is not reused.

*Query (inside the existing broadphase range job, per SAP proxy `d` in sorted order)*

- `cx0 = floor((d.min_x − 64 − 1) / 64)`, `cx1 = floor((d.max_x + 64 + 1) / 64)`,
  likewise `cy0..cy1`, clamped to `i24`.
- For each `cy`: `lo = lowerBound(key(L, cy, cx0))`, then scan while
  `key ≤ key(L, cy, cx1)`. That is one binary search per cell row, and the
  cx range is contiguous.
- Emit `StaticPair{ proxy: u32, row: u32 }` on an exact strict-overlap test
  (`overlap_x > 0 and overlap_y > 0`, the narrowphase predicate).
- Correctness: an overlapping static's center lies within
  `(d.min − half, d.max + half)`, and `half ≤ 64`. So no pair is missed.
- No candidate cap applies (correctness-critical). Per-query work is bounded
  by the dynamic's own extent and the statics actually present, never by
  world size.
- `BroadphaseRangeBuffer` gains `static_pairs` with the same
  `required_capacity` overflow → grow → replay discipline (`:131-157`,
  `:734-736`). It is reserved at `range_len × 2` (warm heuristic). The
  serial SIMD path gets a matching `static_pairs_serial` with
  `appendCandidatePairChecked`-style counting.

*Gather*

- `gatherBodies` tests
  `entity.index < gen.len and gen[entity.index] == entity.generation` and
  skips grid statics **before** any slot lookup.
- The order is sized to the dynamic proxy count. Touched statics are
  appended to `rows` after the sort and broadphase, never into `order`.

*Main-thread resolve, orient, merge (after the broadphase batch)*

1. Merge `static_pairs` in range order.
2. Resolve each touched row once. Per-row stamp arrays are reserved to the
   row count at rebuild; the `touch_epoch: u32` stamp means no clear is
   needed.
   - The row must be alive (`movementBodyDenseIndex`) and
     `scope.tier[mi].allowsCollision()`. Dormant and kinematic statics are
     dropped, which matches SAP scope exclusion.
   - **Live validation:** the AABB, level, and velocity must equal the row.
     On a mismatch, count `static_index_mismatch`, set `dirty`, and use the
     live values. Re-test the overlap with live values and drop the pair if
     it no longer overlaps.
   - Append a static proxy row to `rows` with the live `movement_index` and
     velocity (0).
3. Orient each pair so `a` has the lower `proxyIndexLessThan` key.
4. `std.sort.pdq` the static pairs by `(key(a), key(b))`. That is a total
   order with unique pairs.
5. Merge backward in place into `candidate_pairs` (capacity ensured to
   dyn + static; warm after the first high-water mark) by the same
   comparator. The result equals the full-SAP pair order restricted to
   non-grid×grid pairs.

Narrowphase, contact merge, and response are unchanged.

- **Parity statement:** split contacts = single-SAP contacts minus pairs
  where both proxies are grid statics. Every field and the order are
  identical.
- The removed pairs are output-neutral: no response intent (`:148`), no
  trigger (grid excludes triggers), and no audio or impact (no player is a
  grid static, because the player carries no `.static` response).
- `CollisionConfig.static_colliders: ?*const StaticColliderIndex = null`.
  Null is today's single SAP: benches and bare collision users. It is a
  runtime input, not a test hook.
- **Static contract (documented, enforced):**
  - A grid static moves only through structural commands.
  - A Debug-build full verification in `stageCollisionDetect` compares every
    grid row against its live body each step (`builtin.mode == .Debug` only).
  - Release builds rely on eligibility plus the per-touch validation above.
  - A future processor that writes a static-mobility body (for example
    knockback) must exclude statics or set `dirty`. The architecture doc
    states this.
- **Threading/determinism:** query writes are range-disjoint padded buffers
  reserved before dispatch. Resolve, sort, and merge are serial. The output
  is independent of worker count.
- **Stats:** `CollisionStats` gains `static_rows`, `static_grid_rows`,
  `static_pairs`, `static_touched`, `static_index_mismatch`, and
  `static_rebuild_ns`, with perf metrics. `body_count` now counts SAP proxies
  only; document this.

**71B.3: group-field prewarm for authored shared goals**

- `GroupField` gains `origin: GroupFieldOrigin = .demand`
  (`enum { demand, prewarm }`) and
  `prewarm_source: PrewarmSourceId = .none`
  (`{ slot: u16, generation: u16 }`).
- **Source domain** (slot-ordered, sized at load):
  - interest-marker slots `[0, interest_marker_capacity)` (128, fixed inline
    array) of kind `patrol` or `resource`;
  - then Slice 62 anchor slots
    `[interest_marker_capacity, interest_marker_capacity + spawn_anchor_capacity)`;
  - `path_prewarm_source_domain = interest_marker_capacity + spawn_anchor_capacity`
    is a runtime value computed at load from the loaded anchor capacity
    (Slice 62's world-sized `spawn_anchor_capacity`) and stored on the
    pipeline; it is never recomputed per step. The per-step visit budget
    `path_prewarm_candidates_per_step` stays fixed, so a larger domain only
    lengthens the sweep period (deterministic deferral).
- **Merchant positions are excluded permanently**, against the backlog
  draft. Merchants walk: 71A's leash keeps them near home, not stationary. A
  field keyed to a merchant's current cell goes stale as soon as it moves.
  Slice 71D's `trade` goal is that moving position, and the demand path
  (stale-slot rekey) serves it.
- **Eligibility** of a source slot:
  - the slot is live with a matching generation (marker kind patrol or
    resource);
  - its level has a nav grid;
  - `simViewRegion(context)` is non-null, and the source chunk's level-anchored
    `lodDistance` from it is `≤ path_prewarm_band_chunks`.

  These goals match the 71A `patrol` / `return_home` resolvers and the
  Slice 61 forage marker fallback **exactly** (same world position → same
  `keyForWorld` cell).
- **Per step**, in `stagePathfindingUpdate` after `pathfinding.update`, as
  pipeline method `prewarmSharedGoals(step)` (main thread):
  1. **Release.**
     `pathfinding.releasePrewarmFieldsWhere(ctx, comptime keepFn)`. This is a
     generic comptime callback with static dispatch and no vtable. Every
     `.prewarm` field whose source is no longer eligible goes `.empty`
     (`path_prewarm_released`). That is ≤ `max_group_fields` checks.
  2. **Visit.** Visit `path_prewarm_candidates_per_step` source slots
     starting at `@intCast((step * path_prewarm_candidates_per_step) % path_prewarm_source_domain)`
     (`step: StepIndex`, which is `u64` from Slice 49; the product overflows
     only after 2^64/8 steps).
     - For each eligible source call
       `pathfinding.prewarmGroupField(level, pos, .default, source)`, which
       returns `.started | .present | .no_empty_slot | .no_goal_cell`.
     - Stop after `path_prewarm_goals_per_step` `.started` results.
     - `prewarmGroupField` claims **only** a `.empty` slot. It never evicts.
       It reuses `buildGroupSlot(…, origin = .prewarm)` (beginBuild + one
       expand) and the existing `projectToNearestOpen` goal projection.
- **Demand interaction (pathfinding-owned):**
  - `ensureGroupField` reusing a `.prewarm` field promotes it to `.demand`
    (`path_prewarm_promoted`).
  - With no empty slot, eviction prefers the lowest-index `.prewarm` slot
    before the round-robin `next_group_evict`. Prewarm is dropped on
    contention.
  - `staleGroupSlot` may rekey a prewarm slot (it has no active tally); the
    rebuilt field is `.demand`.
  - Building prewarm fields advance in `serviceGroupFields` with the same
    per-field `group_field_build_budget`. The worst case per step is
    unchanged, `max_group_fields × group_field_build_budget`, the same bound
    demand fields already have.
- **Level-scoped drop.** The incremental branch of `applyNavUpdatesImpl`
  (`:483-496`) calls `dropGroupFieldsOnLevels(affected_levels)`. Group
  fields are built and sampled on their goal level only, so a field on an
  unaffected level stays correct. The version-bump branch keeps dropping
  all. This applies to both origins. It is what "after any
  `nav_region_invalidated` that touches a goal's level" means.
- **One shared cache-reaction helper** (consistency F10). The drop lives in
  `PathfindingSystem.reactToGraphUpdate(stats, affected_levels,
  eviction_spans, had_full_level)`: the version bump, the full-level clear,
  scoped eviction, and the group-field drop. The synchronous branch at
  `system.zig:479-496` and Slice 65B's deferred swap both call it, so the
  two paths invalidate identically for the same batch.
  - If 65B lands first, it introduces the helper with an all-levels drop,
    and 71B.3 changes only the drop inside it.
  - If 71B.3 lands first, it extracts the helper from the synchronous branch
    and 65B's swap calls it.
- **No world scaling.** There is no sector count, endpoint quantization, or
  cache-key quantization, and no use of `groupFieldThreshold`. `ResultCache`
  is untouched: it is goal-keyed per start and serves no other start.
- The fixed threshold itself is 71B.1's first item (above), not part of
  this gated part.
- **Constants:**

  | Constant | Value | Reason |
  | --- | --- | --- |
  | `path_prewarm_goals_per_step` | 1 | Backlog value; at most one new field per step |
  | `path_prewarm_candidates_per_step` | 8 | Full sweep of `D` source slots every `ceil(D / 8)` steps (384 slots: 48 steps, 0.8 s) |
  | `path_prewarm_band_chunks` | `cognition_halo_chunks` (16) | Prewarm only where agents decide |
  | `PathfindingCapacity.prewarm_shared_goals` | `true` (default) | A runtime policy knob like `min_group_field_agents`; the demo value is set by the A/B acceptance |

- **Contract:** `pathfinding_update` adds `interest_markers` (external) and
  `spawn_anchors` (later writer `population_update`) to `carried`.
- **Stats:** `PathfindingStats` gains `prewarm_started`, `prewarm_released`,
  `prewarm_promoted`, `prewarm_no_slot`, and `prewarm_no_sim_view`, with
  perf metrics.
- **Checksum:** prewarm fields are `PathfindingSystem` state, classified
  `normalized` by Slice 64B. They are not an output-transparent cache,
  because a prewarmed field changes which requests short-circuit.
  `normalize` resets every `group_fields[i]` to `.empty` with
  `origin = .demand` and `prewarm_source = .none` (64B B5 (d)). The
  step-derived cursor holds no state.
- **Allocation:** fields are reserved O(cells) at nav build (existing). The
  prewarm path allocates nothing.

### Checklist

- [x] **71B.1, first and ungated: fixed group-field threshold.**
      `default_min_group_field_agents = 1024`; delete
      `default_cells_per_group_agent`, `group_field_threshold_floor`, and the
      `cellCount` branch; `groupFieldThreshold` clamps the pin to
      `[1, @max(min_capacity_floor, max_agent_budget)]`; update the
      `types.zig` comments. Migrate the derivation tests
      (`system.zig:4445-4503`) to:
      - "group-field threshold is independent of world size": two grids of
        different cell counts (1024 and 262,144 cells) give the same
        threshold, 1024;
      - "threshold is capped by the population ceiling": `max_agent_budget =
        8` gives 8;
      - "a pin is clamped": a pin of 0 gives 1, and a pin above the ceiling
        gives the ceiling.

      Every existing pinned test passes unchanged. Record before/after for
      the `pathfinding*` bench groups whose fixtures were unpinned, and pin a
      literal where a case relies on group fields building. This item lands
      even if nothing else in 71B does.

      (2026-10-05: landed. `types.zig` `default_min_group_field_agents = 1024`;
      `default_cells_per_group_agent` and `group_field_threshold_floor` are
      deleted. `PathfindingSystem.groupFieldThreshold` is now
      `std.math.clamp(min_group_field_agents, 1, @max(min_capacity_floor,
      max_agent_budget))` with no `cellCount` read. Tests: `"group-field
      threshold is independent of world size"` (1024-cell and 262,144-cell
      grids both give 1024, and a 2-agent same-goal group builds no field),
      `"group-field threshold is capped by the population ceiling"`, and
      `"group-field threshold pin is clamped"` (0 gives 1, 5000 gives 4096,
      2000 is unchanged). Every pinned test passes unchanged.
      No pin was needed: the unpinned fixtures (`pathfinding.zig` near
      `:406/:509/:617/:767/:902`) submit only `.individual` requests, and
      `recordGroupRequest` runs only for `.group`, so the threshold is never
      consulted there. Before/after record (ReleaseFast, `serial-direct`, 3
      interleaved repetitions of adjacent builds, medians):
      `pathfinding` 512: 3.21 ms → 3.19 ms;
      `pathfinding-shared-goal` 128/512/1024: 10.73/19.18/22.83 us →
      10.51/15.51/22.46 us; `pathfinding-drain` 1024: 3.16 ms → 3.14 ms;
      `pathfinding-query` 256/1024: 5.28/20.91 us → 5.04/21.27 us;
      `pathfinding-escalated-detour` 1: 14.91 us → 14.52 us. All are within
      noise, as expected for an unchanged code path.)
- [x] **71B.1 capacity-audit follow-up (ungated; lands on its own like the
      threshold item).** Landed 2026-10-06. Beyond the text below:
      `PathfindingSystem.group_field_threshold_ceiling` is frozen at
      `reserve` and `groupFieldThreshold` clamps to it, so a C3 seam raise
      never moves the threshold (test "a seam raise never moves the
      group-field threshold"); a nav-memory test pins
      `budgetForCapacity(content-sized).requiredBytes < budgetForCapacity(4096).requiredBytes`
      (362,372,128 B < 512,998,432 B at battle scale, 0 links). Review
      follow-up: it first compared `autoSizedMaxNavMemoryBytes`, which rounds
      both to 536,870,912 B and so passed even with the ceiling pinned back to
      4096; the unrounded comparison fails then (confirmed by temporarily
      restoring the fixed 4096).
      The no-change spot check (`pathfinding-shared-goal`,
      `pathfinding-group-field-detour`, 5 interleaved ReleaseFast reps) is
      within noise: shared-goal 1024 serial 22.39 → 22.30 us, tuned 22.03 →
      21.89 us; group-field-detour 24 serial 471 → 480 ns (spread 32%), tuned
      454 → 449 ns. The literal `default_min_group_field_agents = 1024`
      stays; only its `types.zig` comment is rewritten around the gated
      operation's cost (no world-size citation). `proceduralPathfindingCapacity`
      gains the population and sets `max_agent_budget =
      @max(population.intent_capacity, cap.min_group_field_agents)`; the
      `default_max_agent_budget` comment names it a library default. Tests:
      the three existing threshold tests pass unchanged; the demo test
      "proceduralPathfindingCapacity reserves the shared flow-field for a
      future battle-scale crowd" asserts `max_agent_budget ==
      @max(deriveDemoPopulationCapacity(battle_scale_demo_mover_count).intent_capacity,
      min_group_field_agents)`; a `PathfindingSystem` reserved with the
      default-demo capacity reports `groupFieldThreshold() == 2000`; a
      population whose `intent_capacity` is below the pin still reports the
      pinned threshold (no clamp below `min_group_field_agents`); the
      existing elastic-ceiling `FailingAllocator` proof (`system.zig`,
      `effective_agent_capacity` steady state) passes at that ceiling. Record
      `autoSizedMaxNavMemoryBytes` before and after in Status.
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
- [x] **71B.1** `ObstacleSnapshotRow.world_level`, same-level gate in
      `accumulateObstacleSample`. Tests: every existing steering test passes
      unchanged (bit-identical single-level); a level-1 static at the agent's
      x/y exerts no push on a level-0 agent and does on a level-1 agent;
      candidate-check counts unchanged on a single-level fixture.
      *Done 2026-10-05 (live-defect fix, split out of the shared-rows item
      below).* The row level comes from `movementScopeLevel` in today's
      `rebuildStaticObstacleSnapshot`; the gate skips after the candidate is
      counted, so `max_obstacle_candidate_checks` truncation is unchanged.
      `eventInvalidatesStaticObstacleSpatial` now also fires on a
      `.world_level` `component_changed` for a static (was/is), because the
      cached row level would otherwise go stale. That is the subset of the
      `eventInvalidatesStaticColliders` extension this fix strictly needs.
      Tests (`steering.zig`): a level-1 agent overlapping a level-0 box gets 1
      candidate check, 0 samples, and an unchanged direction. After a
      committed `.world_level` move of the box to level 1, the snapshot is
      invalidated and the push returns. A predicate test covers static vs
      non-static `.world_level` events. A multi-level serial-vs-real-threaded
      parity test runs 2 splits. All existing steering tests pass unchanged.
      `zig build bench -- --group steering` workload candidates are unchanged
      (4173/17122/36302 at 128/512/1024) and timings are within noise.
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
      Record the gate numbers in Status.
- [ ] **71B.2** Grid build (eligibility, center keys, pdq sort,
      `grid_static_generation` reserved to
      `SimulationPipelineConfig.entity_slot_capacity` with the assert and the
      grow-and-warn fallback; the demo passes its entity reserve) with tests: oversize/trigger/agent/moving
      statics are not grid; negative coordinates and out-of-`i24` cells;
      key order equals `(level, cy, cx)` geometric order.
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
      `reactToGraphUpdate` helper (consistency F10). If 65B has landed, its
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
      resource, contact-order parity rule); `docs/development-workflow.md`
      bench examples; roadmap Scaling Gaps "Path group fields + cache
      pressure" and "Collision full-sort under melee density" note that
      statics leave the sort once 71B.2 lands.

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
- [ ] 71B.2 battle soak (ReleaseSafe, 60 s, 2048 movers): the collision stage
  and the `collision_setup` gather/sort lines are at or below the control
  band. Record `static_touched` and `static_index_mismatch` (must be 0).
- [ ] 71B.3 A/B capture (ReleaseSafe, 60 s, the demo with Slice 62 settlement
  population and 71A guards, prewarm on vs off):
  - `path_solved_requests` and `path_accepted_requests` per minute fall by
    ≥ 10%;
  - the pathfinding stage average rises by no more than 0.02 ms;
  - `path_group_field_reuses` / `prewarm_promoted` are recorded.
  - If this fails, set `prewarm_shared_goals = false` in
    `proceduralPathfindingCapacity` and record the numbers in Status. The
    mechanism and its tests still land.
  - Do not lower the `min_group_field_agents = 2000` pin in this slice.
- [ ] `zig build bench -- --group pathfinding-prewarm` is recorded, and the
  `pathfinding-group-field-detour*` groups stay within noise (the
  `samples_total > 0` guard holds).
- [x] 71B.1 (fixed threshold, checked on its own landing): no budget
  derives from world size. Grep shows no `cellCount()` in threshold or
  budget code paths, `default_cells_per_group_agent` and
  `group_field_threshold_floor` no longer exist, and the "independent of
  world size" test passes.
- [x] 71B.1 capacity-audit follow-up: no pathfinding threshold or capacity
  default cites world size, the group-field default stays the literal 1024,
  the demo's `max_agent_budget` is `@max(intent_capacity,
  min_group_field_agents)`, and the default-demo `groupFieldThreshold()` is
  2000.
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

