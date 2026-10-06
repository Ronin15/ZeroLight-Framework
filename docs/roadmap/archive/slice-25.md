## Slice 25: Z-Aware Scalable Navigation Redesign

Goal: make the pathfinder correct, scalable, and functional for multi-Z-level,
fixed-but-variable-size worlds with event-driven dynamic tile changes and
mostly per-agent distinct goals. This supersedes the single-flat-grid,
goal-field-centric core from Slices 18/20 while keeping the frame-delayed
request/result contract and steering integration from Slices 18/19 intact.

Current foundation:

- Slice 18 frame-delayed pathfinding, Slice 19 steering/local avoidance, and
  Slice 20 bounded hard-path budgets define the request/result contract,
  deterministic deferral, and fixed-capacity caches this redesign keeps.
- Slice 21 typed events (`world_tile_changed`, `world_obstacle_changed`,
  `nav_region_invalidated`) are the dynamic-update signal source.
- Slice 23 world rendering provides `WorldSystem` levels (`addLevel`/
  `level_base_z`), dense render bands (`addDenseLayer`/`denseLayerCount`), sparse
  obstacles, `cellRect`, and tile size (32).
- Slice 22 `SimulationPipeline` owns the per-tick `pathfinding.update` call site
  and the one-time nav build; the per-stage `pipeline_pathfinding` timer exists.

Problem (observed defects this slice fixes):

- A Z-level is a `WorldSystem` level (floor), not a render band. `NavGrid`
  collapses every dense band of every level into one flat blocked mask
  (`pathfinding.zig` `markWorldObstacles`), which is wrong across bands and
  across floors. There is no inter-level connectivity.
- Whole-grid scratch sizing is the real scalability wall: goal fields and
  per-worker scratch are sized to total cell count, costing ~293 MB at 512²/32px
  before the demo coarsened to 128px nav cells. The 65,536-cell `goalFieldsEnabled`
  / `fallbackSearchEnabled` gates then silently degrade navigation to direct seek
  with no error — a correctness landmine.
- `PathQueryKey` includes the agent start cell, so a drifting agent mints a new
  key every cell, pending entries never dedup, and agents replan-storm (observed
  `replans=17256` in a 60s sample).
- Goal fields only build for ≥2 same-goal requests in the same step, so with
  per-agent distinct goals they never cache-hit (`field_cache_hits=0`,
  `fields_built=51`, `evictions=277`) — pure thrash and the source of the
  `pipeline_pathfinding_max≈31ms` dropped-frame spike.
- `update()` writes `deferred_requests` twice (`pathfinding.zig` ~1008 then
  ~1041); budget exhaustion can read as `unavailable` instead of `pending`.
- Coarse 128px cells push waypoints away from walls, raising `stuck`/`unavailable`.

Architecture notes:

- Navigable unit is the level (Z-floor). A level's per-cell blocked mask is the
  OR of that level's dense bands plus its sparse obstacles, exposed by a new
  `WorldSystem.levelBlocksMovement(level, x, y)` accessor so pathfinding stops
  iterating render bands directly.
- Two-tier (HPA*-style) structure per level: a fine per-level blocked bitset
  (cell = one 32px tile) plus a coarse chunk-portal graph (default 16-tile
  chunks). Inter-level travel uses explicit `LevelLink` records (ramp/stair/
  teleport) owned by `WorldSystem` as persistent world facts carrying only stable
  cell coordinates and level indices — never live nav indices or handles.
- A path query maps start/goal to `(level, cell)`, projects a blocked goal to the
  nearest open cell within a bounded radius, rejects cross-component goals via
  per-level connected components, then runs abstract A* over the portal graph plus
  link edges (Z-crossing is a link edge between portal nodes in different levels).
  The chosen corridor is then STITCHED into one obstacle-aware (level,cell) path by
  running per-segment local A* between consecutive corridor portals (a discrete jump
  only across a link edge) and cached whole; the per-agent query walks the path on its
  current level cell by cell, so multi-hop and cross-level routes converge with every
  heading a traversable neighbor. The `PathView` contract
  (`status`/`next_waypoint`/`path_len`) is unchanged.
- Per-agent A* uses a binary-heap open set and generation-stamped closed/g-cost
  storage sized to a bounded `max_explored_nodes` budget (e.g. 4096) via a
  cell→slot hash, not whole-grid arrays. Budget exhaustion returns `pending`
  (loud `path_budget_exhausted` counter), never silent `unavailable`.
- Cache/pending key is `{ nav_version, agent_class, goal_level, goal_cell }` —
  start is dropped. A cached result stores the abstract corridor; the per-entity
  waypoint is re-refined from the agent's current cell each step it is consumed,
  so a moving agent reuses one corridor for its whole trip and many agents sharing
  a goal share one pending entry.
- The core provides TWO coordinated solver modes. (1) Per-agent A* for distinct
  goals (the default). (2) A MANAGED shared-goal flow field for declared common
  goals (crowds converging on the player/an objective): a small fixed registry of
  reverse-Dijkstra integration fields keyed by `{nav_version, goal_cell}`,
  persistent and reused across frames and all agents, rebuilt only when nav
  changes or the declared goal crosses into a new nav cell, throttled by a minimum
  rebuild interval, and built under a per-frame expansion budget (a field may be
  `building` across frames) so it never spikes. This is NOT the old per-step
  auto-grouped goal field (which thrashed at `field_cache_hits=0`); grouping is
  declared by the request, not detected. Agents sample the field in O(1) and the
  result surfaces through the unchanged `PathView` contract. The long-range
  individual mechanism is the Slice 25C chunk-portal abstract tier; the group
  field is the shared-goal mechanism — both coexist.
- Dynamic updates are event-driven: `world_tile_changed`/`world_obstacle_changed`
  map to affected cells, flip blocked bits, mark owning (and border-touching
  neighbor) chunks dirty, and `applyNavUpdates` recomputes only dirty chunks'
  cells/portals/adjacency plus dirty-driven component relabel (full relabel only
  past a threshold, loud counter). One `nav_version` bump per batch invalidates
  goal-keyed cache/pending entries. The whole-world build runs only at init.
- The cell gates are deleted. Oversized worlds fail loud at construction via a
  configured `max_nav_memory_bytes` (`error.NavWorldTooLarge` with a diagnostic),
  not at query time. Per-query work is bounded by the abstract graph plus the node
  budget, independent of total world cell count.
- Threading: per-request abstract+local A* runs on workers with worker-indexed
  scratch and deterministic per-`pending_index` output (existing fallback
  dispatch shape); small batches stay inline via the adaptive tuner.
  `applyNavUpdates` runs single-threaded at the event reaction point before the
  next step's solves; chunk recompute is parallelizable later if needed.

Capacity/memory model (per level: W·H nav cells = C, L levels, K-cell chunks):
nav ≈ `L·(C/8 bitset + 4·C components) + links·16`. The per-worker local A* scratch
is now generation-stamped DIRECT per-cell arrays (g-cost + parent + stamp + closed
≈ 13 B/cell), so A* scratch ≈ `slots · C · 13 B` — O(cells) instead of
O(`max_explored_nodes`). This is a deliberate speed-for-bounded-memory trade (O(1)
node access, no hash probes); slots = `worker_participant_count` (workers+1, sized at
the build), and the build-time `max_nav_memory_bytes` gate counts exactly that
resident scratch, so a large world that exceeds the budget fails loud at the gate. `max_explored_nodes` remains the per-solve node BUDGET (a spill cap), enforced
by an explicit expansion counter rather than a hash-table-full condition.
`components` width (u32→u16 or abstract-graph-only reachability) is a
future memory lever for very large worlds.

Sub-slices (each independently shippable and headless-testable):

- Slice 25A — `WorldSystem` per-level navigability accessor + `LevelLink` store;
  pathfinding consumes `levelBlocksMovement` for level 0 only (behavior-preserving
  for the single-level demo).
- Slice 25B — hybrid core: per-agent A* (goal-keyed corridor cache, budgeted
  scratch) PLUS a managed shared-goal flow-field registry. Remove the old
  auto-grouped goal fields, cell gates, and the start-cell key; add
  `max_explored_nodes`, `max_group_fields`, group rebuild throttle/budget, and
  `max_nav_memory_bytes`; fix the `deferred_requests` double-write; redefine
  `unavailable` vs `pending`; request contract carries individual-vs-group kind.
- Slice 25C — chunk-portal abstract tier and cross-level query; `PathRequest`/
  `NavigationIntent` gain `start_level`/`goal_level`; steering fills them.
- Slice 25D — event-driven incremental rebuild: dirty nav-cell set, `applyNavUpdates`,
  per-affected-level mask/component recompute, single `nav_version` bump, nav-update
  metrics; wire world-tile/obstacle events from the post-commit reaction point into the
  pipeline instead of full rebuilds. Granularity: per-AFFECTED-LEVEL recompute (the
  bounded fallback the brief permits) — only affected levels' masks/components are
  re-derived and the shared chunk-portal abstract graph is rebuilt once (bounded by
  chunk borders, not cells); true per-chunk portal/CSR surgery would require a
  per-chunk-addressable portal store (a larger redesign) and is deferred. A relabel of
  every level happens only past a configured affected-level threshold and increments a
  loud `nav_full_relabel` counter; unaffected levels are never touched and the
  whole-world build stays init-only.

Checklist:

- [x] 25A: add `WorldSystem.levelBlocksMovement`, `levelCount`, and `LevelLink`
      store/accessors; switch `markWorldObstacles` to per-level composition.
- [x] 25B: per-agent A* (budgeted scratch, goal-keyed corridor cache, no
      start-cell key); delete the old auto-grouped goal fields, cell gates, and
      their stats; add memory-gate validation; fix the `deferred_requests`
      single-write. Heap A* is now the sole individual solver; scratch is sized
      to `max_explored_nodes` via a cell->slot hash, not whole-grid arrays; the
      node-budget spill returns `pending` and increments `path_budget_exhausted`.
- [x] 25B: managed shared-goal flow-field registry (`max_group_fields`,
      cell-quantized + throttled + per-frame-budgeted rebuilds, declared by
      request kind, sampled O(1) through `PathView`); both modes tested. Group
      fields are built only on declared `group` requests (zero cost when unused),
      throttled by `group_field_rebuild_min_steps`, and built across frames under
      `group_field_build_budget`.
- [x] 25C: build per-level chunk-portal graph; abstract A* over portals + link
      edges; stitch the chosen corridor into one full obstacle-aware (level,cell) path
      via per-segment local A* (link edges are discrete jumps) and walk it per-agent on
      its current level cell by cell; add level fields to request/intent/steering.
      Abstract scratch saturation or a per-segment node-budget spill returns
      `budget_exhausted` (retry), reserving `unavailable` for a missing corridor.
      Abstract seeding scans only the start level's portals via a per-level portal
      index, so per-query work is bounded independent of total cells and of other
      levels' portals. (Performance, post-25: the per-level index is further grouped
      by connected component — a per-(level,component) CSR — so seeding scans only the
      START component's portals, not the level's full border; architecture unchanged.)
- [x] 25D: incremental nav rebuild driven by typed world events. `applyNavUpdates`
      flips the affected level's blocked bits, recomputes only affected levels'
      masks/components, rebuilds the chunk-portal abstract graph once, and bumps
      `nav_version` once per batch so goal-keyed cache/pending/group entries re-solve.
      `GameDemoState` collects blocking `world_tile_changed`/`world_obstacle_changed`
      (and entity-driven obstacle) changes into a pre-reserved dirty nav-cell set and
      feeds `pipeline.applyNavUpdates`; the whole-world build path is init-only. Added
      `nav_dirty_chunks`, `nav_incremental_rebuilds`, `nav_full_relabel`,
      `nav_version_bumps` metrics; the per-affected-level relabel degenerates to a
      counted full relabel only past `nav_full_relabel_level_threshold`. The build
      helpers were moved off per-call `allocator.alloc` onto persistent scratch, and
      the abstract-graph buffers grow to their real size at the init rebuild and
      retain that high-water capacity, so an incremental rebuild within the
      high-water mark allocates nothing (a failing-allocator test drives both the
      system and graph allocators across a block-then-reopen). A genuine topology
      expansion past the high-water mark does one bounded amortized growth — a cold,
      event-triggered path covered by a separate test. The `max_nav_memory_bytes`
      gate estimates nav memory from realistic structure (portals bounded by
      chunk-border cells, CSR edges by portal count times a small abstract degree),
      not a per-chunk pairwise worst case, so large sparse worlds build. `PathView`
      and request contracts are unchanged.
- [x] Reset the demo `nav_cell_size` stopgap (currently 128) to a tile-aligned
      principled value (32 = one nav cell per tile); coarseness lives in the chunk
      tier, not the cell size.
- [x] Keep pathfinding a gameplay system in `src/game/systems/`; no test-only
      enum tags, marker fields, or fixture hooks in production contracts.

Acceptance checks:

- [x] Intra-level paths are correct against a per-level composed mask; a blocked
      goal projects to the nearest open cell (`path_goal_projected`); disconnected
      goals return `unavailable` exactly once and cache.
- [x] Cross-level `LevelLink` traversal works (25C): a bidirectional link routes an
      off-level agent across floors (`cross_level_solves`); a directed link works one
      way only; a missing or blocked-endpoint link returns `unavailable` (not a
      permanent stall); per-level obstacles do not bleed across floors; a multi-hop
      same-level corridor (split component bridged by a same-level teleport) and a
      cross-level corridor both travel obstacle-free past a concave wall in single-cell
      steps (no straight-line cut) and reach the goal; abstract scratch saturation
      reads pending (not cached unavailable); a warmed abstract solve does not
      allocate; a cross-level group member falls back to an individual corridor once
      the goal-level field is ready. All asserted by headless tests.
- [x] A moving agent toward a fixed goal produces one accepted request then cache
      reuse (no per-cell churn): asserted by the goal-keyed dedup-under-drift test.
- [x] Per-query explored-node count is bounded (`max_explored_nodes`) and
      independent of total world cell count; spills return `pending`.
- [x] An oversized world returns `error.NavWorldTooLarge` at construction; no query
      path ever silently degrades to direct seek (the cell gates were removed).
- [x] A tile/obstacle event blocks/unblocks a corridor and the next path reflects
      it; `nav_incremental_rebuilds`/`nav_version_bumps` are non-zero and full
      rebuild runs only at init. (Slice 25D.) Headless tests cover: flipping a
      corridor gap to blocking reroutes the next solve through a different gap (and
      stale cached path invalidates because its `nav_version` key no longer matches);
      closing the last gap returns `unavailable`; unblocking a tile opens a shorter
      path; an edit on level 0 leaves a second level's mask/components byte-for-byte
      untouched (work scales with the dirty set, not world size); an empty batch is a
      no-op; and the steady-path update is allocation-free under a failing allocator.
- [x] `zig build fmt`, `zig build check`, `zig build test`, `zig build verify`, and
      targeted pathfinding benchmarks pass.

Open decisions (recommendation in parentheses): inter-level link representation
(explicit `LevelLink` records, not inferred tile flags); chunk size (16 tiles);
shared-goal flow field is folded into the 25B core (declared by request kind,
persistent, cell-quantized + throttled + budgeted), not opportunistically grouped;
parallel-solve threshold (keep existing adaptive/inline behavior; `applyNavUpdates`
serial initially); `components` width (u32 initially); goal-level source
(`NavigationIntent`, default 0 until multi-level gameplay exists).

Status: 25A, 25B, 25C, and 25D implemented. The hybrid core ships goal-keyed individual
A* with budget-bounded scratch, the managed shared-goal flow-field registry, and the
chunk-portal abstract tier with cross-level `LevelLink` routing. Long-range and
cross-level queries route through abstract A* over portal/link nodes, then stitch the
chosen corridor into one full obstacle-aware (level,cell) path via per-segment local
A* (link edges are discrete jumps) and cache it whole; the per-agent query walks it on
its current level cell by cell, so every heading is a traversable neighbor. Abstract
seeding scans only the start level's portals (per-level portal index); abstract scratch
saturation or a per-segment node-budget spill returns `budget_exhausted` (retry) rather
than a hard negative. The old auto-grouped goal fields, cell gates, start-cell key, and
their stats remain removed; `deferred_requests` is a single post-compaction write in
both update paths; the memory gate fails loud at rebuild. 25D (event-driven incremental
rebuild) is implemented: `applyNavUpdates` folds a dirty nav-cell set from world-tile/
obstacle events, plus entity-driven obstacle events (`component_changed`/
`entity_destroyed`) resolved to a localized nav-cell span via the changed entity's
world-space collision rect, into the existing graph by remasking + patching only the
chunks the dirty cells/spans touch, rebuilding the chunk-portal abstract graph once, and
bumping `nav_version` once per batch so goal-keyed work re-solves; the whole-world build
runs only at init. A whole-level remask (recomputing every chunk on the affected level)
is a bounded fallback for the rare case an entity change carries no resolvable rect, not
the normal path; a full relabel of every level happens only past a configured
affected-level threshold, counted via `nav_full_relabel`. True per-chunk portal/CSR
surgery is deferred pending a per-chunk-addressable portal store. Route the slice diff to
review with attention to the goal-keyed cache reuse and corridor-advancement contracts,
the per-affected-chunk update scope, and the allocation-free steady-path claim.

Post-25 performance pass (architecture unchanged — same A* results, deterministic,
allocation-free on the warmed path; all layers retained): (1) the per-worker local A*
scratch is generation-stamped DIRECT per-cell arrays indexed by cell index, giving
O(1) node access with no hash probes/collisions in place of the prior open-addressed
cell→slot hash. Per-worker scratch is now O(cells); the build-time memory gate
(`NavMemoryBudget.requiredBytes`) counts `slots · cells · 13 B`, and `max_explored_nodes`
remains the per-solve node budget enforced by an explicit expansion counter.
(2) Abstract seeding is component-scoped: the per-level portal index is grouped by
connected component (a per-(level,component) CSR), so seeding scans only the start
component's portals rather than the level's full border. (3) `localAStar` derives each
neighbor's (x,y) incrementally from the current cell plus the direction offset and feeds
those coordinates straight to the octile heuristic, removing per-neighbor `index%width`/
`index/width` div/mod. A node-access design that would make a same-component
budget-spill escalate to the abstract corridor (the considered "WIN C") was NOT adopted:
with component-scoped seeding the abstract corridor for a same-component goal collapses
to a single portal, so escalation cannot subdivide the long segment and would only add
per-frame work — making it effective would require start-chunk-scoped seeding (a global
corridor-shape change), a design decision left for a future slice. (4) Entity-driven
static-obstacle changes (an entity destroyed or its `movement_body`/`collision_bounds`/
`collision_response` changed) now localize the same way tile edits already did: the
structural-commit event carries the entity's world-space collision rect (before and/or
after the change), `PathfindingSystem.markNavObstacleRectDirty` resolves it to a nav-cell
span, and the incremental update patches only the chunks that span touches. The prior
25D behavior — treating every entity-driven obstacle change as whole-level dirty,
remasking and re-flooding every chunk on level 0 — is now only the defensive fallback for
the case a change carries no resolvable rect (`markNavLevelDirty`/
`markNavLevelDirtyWithFallbackWarn`, logged at `warn`); it should not occur in practice
since every static-obstacle-eligible entity has the movement_body + collision_bounds a
rect needs.

Deferred follow-up: per-entity depth alignment across sim, navigation, and
render is tracked as Slice 25E below and under **Scaling Gaps And Hardening
Frontier** (simulation scale). The nav substrate is in place; the gap is entity
level column wiring in `DataSystem`, steering, path views, and render cull.


