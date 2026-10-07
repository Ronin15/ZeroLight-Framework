## Slice 64E: Incremental Nav Patch Ramp/Link Parity

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: landed (2026-10-05); the capacity-audit follow-ups landed
2026-10-06** (nav dirty buffers sized by the structural-stage event bound;
level links grow at the dig commit seam), and the edge-window overflow the
manual run found is fixed (2026-10-06: in-place per-chunk window growth
replaces the full-rebuild fallback; its review follow-ups add OOM, edge-order,
A*-result, and cached-path proofs, in-place hole compaction, and a nav memory
gate on growth), and the second review's follow-ups landed 2026-10-07 (M4–M7:
a failed growth still patches the whole dirty set, re-admission charges live
edge slots, the build checks its measured arena, and link-cursor stats survive
a failed apply), and the third review's follow-ups landed 2026-10-07
(M8–M13: one slacked → unslacked → refuse window-sizing ladder, arena
capacity within the gate's ceiling, failed-step growth stats carried,
one refusal `err` per step, a cache clear after a degraded apply, and the
tombstone oracle in the OOM sweeps). The pre-fix manual run passed (owner, 2026-10-06; see
Acceptance checks). **Open: one post-fix manual acceptance check on current
code** (display-gated; not run in the implementing sessions). Every code,
test, doc, and bench item below is checked. The slice stays in `slices/`
until the owner confirms that check.
No open prerequisite. This
was a live gameplay defect (confirmed below), so it landed independently of
49–64D and **before 46 and 65B**. 65B's lane rebuild runs the same chunk patch
and inherits this fix (see Checklist additions). It touches
`src/game/systems/pathfinding/`, the `.ramp` refusal in `dig_controller.zig`,
the geometry wiring in `simulation_pipeline.zig`, and one reservation call in
`game_demo_state.zig`.

Bench record (2026-10-05, ReleaseFast, `serial-direct`, 5 interleaved
before/after repetitions of adjacent builds, medians):

| group | items | before | after | delta |
|---|---|---|---|---|
| `nav-update-scattered` | 16 | 201.45 us | 199.76 us | -0.8% |
| `nav-update-scattered` | 32 | 398.70 us | 411.51 us | +3.2% (runs spread 391–420 us) |
| `nav-update-scattered` | 64 | 803.86 us | 825.61 us | +2.7% |
| `nav-update-scattered` | 128 | 1.63 ms | 1.62 ms | -0.6% |
| `nav-update-scattered` | 256 | 3.22 ms | 3.24 ms | +0.6% |
| `nav-update-multichunk` | 256 | 55.43 us | 56.23 us | +1.4% |
| `nav-update-multichunk` | 1024 | 62.32 us | 63.20 us | +1.4% |
| `nav-update-multichunk` | 4096 | 243.33 us | 252.36 us | +3.7% (after runs spread 241–261 us) |
| `nav-update-multichunk` | 8192 | 531.84 us | 548.78 us | +3.2% (before runs spread 526–546 us) |
| `nav-update-multichunk` | 16384 | 967.71 us | 975.55 us | +0.8% |
| `pathfinding` | 512 | 3.38 ms | 3.26 ms | -3.6% |
| `nav-update-links` (new) | 1 | n/a | 26.24 us | n/a |
| `nav-update-links` (new) | 8 | n/a | 210.76 us | 1.06x the scattered-16 mean (gate: ≤ 2x) |

Every delta is within max(3%, run-to-run noise). Debug and ReleaseFast
`zig build test` pass, and `zig build verify` passes.

Review follow-up (2026-10-05), each item with a test:
- **Event reservation:** a demo test (ramp on an already-walkable cell, tight
  `capacity_limit`) proves the `hasPendingNavLinks` term makes the preflight
  fail before any mutation.
- **Cursor across fallback:** links deferred in the same step as an edge-cap
  fallback or full relabel stay on the cursor. The next step counts the
  unslotted endpoint once, and the graph matches a full rebuild.
- **Mark before assign:** `markNewNavLinksDirty` now marks first and assigns
  slots afterwards. A failed mark therefore leaves the slot table, counts, and
  cursor untouched, so nothing is double-counted or warned twice.
- **Unbuilt graph:** `linkSlotGeometry` returns `.unresolved` when the graph is
  not valid.
- **Link storage: load-time initial reservation; dig-seam growth landed
  2026-10-06** (CLAUDE.md budgets/capacities rule):
  - `WorldSystem.reserveLevelLinks` sets the initial limit, and the demo sizes
    it as authored links + world chunks × K.
  - The memory gate and the build's `link_edges` reservation both use
    `levelLinkLimit`.
  - The original load-time refusal (`addLevelLink` refused links past the
    limit, counted in `dig_ramp_refused_link_slots`) is gone: the dig commit
    seam grows the pool (see the link-growth Checklist item), so a
    load-sized capacity no longer changes behavior.
  - A FailingAllocator test covers the world, graph, and system.
- **Admission:** admission replays the assignment rule, so a cell that is an
  existing but unslotted endpoint is refused.
- **Bench:** `nav-update-links` rebuilds a fresh zero-link world and runs a full
  nav build (the load path) before each timed batch, so every batch measures
  fresh slot assignment.

**Owner decision: a new 64E, not 65B bullets.** 65B moves *large*
patches/relabels onto the background lane. This defect is in the patch
*algorithm* (slot geometry, endpoint admission, and which chunks a new link
dirties), and it shows up on every single-ramp dig, which 65B never routes to
the lane. Fixing it in the synchronous patch fixes both paths; putting it in
65B would leave the main-thread path wrong and tie a live fix to the lane
slices.

Goal: a `LevelLink` added at runtime (today only `DigController.digRamp`)
becomes part of the abstract nav graph in the same step's post-commit nav
reaction, on **both** linked levels, whether its endpoints are perimeter or
interior cells. After any sequence of incremental updates the graph equals a
full rebuild over the same world. Per-step work stays bounded by fixed
constants, with deterministic deferral when a step adds more links than the
budget. No player-dug ramp is ever silently inert: a dig that would exceed a
nav chunk's fixed interior slots is refused before it changes the world.

### Current foundation and defect confirmation (live code)

1. **Interior slots are fixed at init from the init-time link set.**
   - `computePortalGeometry` (`nav_graph.zig:1121-1180`) sizes
     `chunk_portal_cap[D] = 4*ct + chunk_link_count[D]` from
     `world.levelLinks()` **at the last full build**
     (`recordLinkEndpoint` `:1182-1191`, sorted runs `:1195-1219`).
   - `tryLinkPortal` (`:1495-1506`) skips any interior endpoint absent from
     that run (`interiorLinkSlotExists` `:1512-1517`): "picked up by the next
     full rebuild".
   - Pinned by `test "runtime interior link endpoint is deferred by the
     incremental patch, then slotted by a full rebuild"` (`:2223-2276`).
   - Procedural worlds start with zero links; the only producer is
     `digRamp` (`dig_controller.zig:179-193`). So every interior-cell ramp
     (196 of 256 cells per 16-tile nav chunk, `types.zig:130`) is inert for
     the whole session.
   - A full rebuild only happens on a >8-level batch
     (`default_nav_full_relabel_level_threshold`, `types.zig:142`), an
     edge-window overflow, or a fresh init (load).
2. **The partner level is never patched.**
   - A ramp dig emits one `world_tile_changed` for the digger's level only
     (`dig_controller.zig:157-160`).
   - `reactToPostCommitNavEvents` marks only `changed.level`
     (`systems/pathfinding/system.zig:622`).
   - Endpoint portals come only from `addChunkLinkPortals` during a chunk
     patch (`nav_graph.zig:1483-1493`, called from `patchChunk` `:1340-1348`).
     The level-above endpoint therefore never gets a portal, and the abstract
     solver skips a link whose endpoint resolves to `no_cell` in
     `cell_to_portal`.
   - This holds even for a perimeter endpoint.
3. **No nav event at all when blocking does not flip.**
   `eventInvalidatesNavigation` returns `old_blocks_movement !=
   new_blocks_movement` for tile changes (`system.zig:684`). A ramp dug on a
   cell already tunneled (walkable → walkable ramp) triggers no
   `applyNavUpdates`, so `rebuildLinkEdges` (`nav_graph.zig:1257-1298`) never
   even adds the link edge.
4. **Cross-level NPC pathing is live.** The comment at `nav_graph.zig:1503-1504`
   ("cross-level NPC pathing is not active") is stale:
   - underground movers spawn on levels `1..` (`game_demo_state.zig:858-864`);
   - steering requests paths with `start_level` = the agent's level
     (`steering.zig:686`) and `goal_level` = the intent's default 0
     (`simulation.zig:471`);
   - so every underground NPC issues cross-level requests to the surface.

**What players observe.** Underground NPCs never climb a ramp the player
digs. Their surface-bound requests stay `unavailable`, so they sit in
unavailable-backoff or direct-steer against the ceiling level. Hours later a
large edit, or (with Slice 46) a save/load, silently "fixes" every ramp at
once. The player's own traversal (`plane_traversal`, `DigController`) is
unaffected.

Existing parity infrastructure (reuse it, do not rebuild it):
- incremental-vs-full tests (`nav_graph.zig:1998-2938`, including byte-identical
  portal slots `:2340` and a constant patched-chunk set independent of world
  size `:2763`);
- the sorted edge-set compare helper (`:1840-1860`);
- `rebuildLinkEdges` (O(links), once per batch);
- the bench groups `nav-update-scattered`, `nav-update-multichunk`, and
  `nav-update-entity-obstacles` (`src/benchmarks/nav_update.zig:101,107,421`);
- the memory gate slot term `levels * (4*ct*chunks + 2*links)`
  (`nav_memory.zig:170-176`).

### Architecture notes

**E1. Fixed per-chunk interior link slots (geometry independent of the link set).**

- `pub const nav_interior_link_slots_per_chunk: u32 = 8` (`types.zig`).
  - It is fixed, independent of world size, link count, and level count.
  - 8 is one eighth of the 64 perimeter slots of a 16-tile chunk, so slot
    arrays grow by at most 12.5%.
  - The slot table is shared by every level: `recordLinkEndpoint`
    (`nav_graph.zig:1182-1191`) maps a link cell through level 0's grid and
    dedupes by cell, so K bounds the **distinct interior endpoint cells per
    nav chunk across all levels** (a ramp's two endpoints share one cell and
    use one slot).
  - The runtime producer cannot exceed K (producer-side refusal below), and
    a load-time link set that exceeds it is rejected (Slice 46 addition
    (c)). The unslotted overflow path below is the deterministic
    degradation for links authored directly through
    `WorldSystem.addLevelLink` (tests today; worldgen producers validate
    with the same helper before adding links).
- `chunk_portal_cap[D] = 4*ct + nav_interior_link_slots_per_chunk` for every
  chunk, and `total_slots = chunk_count * (4*ct + K)`. That is a pure function
  of the dimensions, so adding a link never renumbers any slot and the
  incremental and full builds share one layout.
- `chunk_link_cells` becomes a fixed-stride `[chunk_count * K]u32` table
  (`no_cell` = empty), with `chunk_link_count[D] ≤ K`. `chunk_link_base` is
  deleted (base = `D * K`). `linkTailIndex` becomes a linear scan of at most K
  entries (`orelse unreachable` kept with its lint annotation).
- **Assignment rule** (one function, `assignLinkEndpointSlots(links:
  []const LevelLink, first: usize)`, used by both paths):
  - visit links in `world.levelLinks()` order from index `first`, endpoint a
    then b;
  - an interior endpoint cell already in chunk D's run is skipped;
  - otherwise, if `chunk_link_count[D] < K` it is appended at tail index
    `chunk_link_count[D]`;
  - otherwise it is **unslotted**: inert, exactly like a blocked endpoint.
    `stats.link_endpoints_unslotted` counts every unslotted endpoint the
    assignment visits. The `logging.game.warn("nav chunk {d} interior link
    slots full ({d}); link {d} endpoint ({d},{d}) stays inert", ...)` fires
    only when the **cursor** first assigns that endpoint (the incremental
    path, link index ≥ the cursor's start), never again for the same link
    on a later full rebuild, so a world with one unslotted authored link
    logs once per session, not once per rebuild; full rebuilds only count.
  - Links are append-only (no removal API exists), so processing new links
    incrementally from a cursor yields exactly the table a full build
    computes from index 0. Existing endpoints never lose a slot.
- **Producer-side refusal (the runtime path never reaches the cap).**
  - Pure helper in `nav_graph.zig`:
    `pub fn interiorLinkSlotsAvailable(links: []const LevelLink, cell:
    CellCoord, geometry: NavLinkSlotGeometry) bool`, where
    `NavLinkSlotGeometry = struct { chunk_tiles: u32, width: u32, height:
    u32 }` (nav cells). It returns true when `cell` is a perimeter cell,
    when `cell` is already an interior endpoint in `links`, or when its
    nav chunk holds fewer than `nav_interior_link_slots_per_chunk` distinct
    interior endpoint cells over `links` (same `isPerimeterCell` predicate,
    same cell dedupe as `recordLinkEndpoint`). O(links), cold
    (per dig attempt, not per step), allocation-free.
  - `DigController` gains `nav_link_geometry: NavLinkSlotGeometry` (config,
    set by `SimulationPipeline` from `pathfinding.graph`'s `chunk_tiles`,
    `width`, `height` at init and after every full nav build) and
    `ramp_refused_link_slots: u64` (telemetry). In `process`, the `.ramp`
    no-op filter (`dig_controller.zig:139`) gains a third condition:
    `!nav_graph.interiorLinkSlotsAvailable(world.levelLinks(), cell,
    self.nav_link_geometry)` → increment `ramp_refused_link_slots` and
    `return` before any event preflight or world mutate, exactly like the
    existing "link already present" no-op. There is no dig-refused feedback
    path in the live code; the refusal is silent in the world and visible
    in the perf metric `dig_ramp_refused_link_slots` (comptime-gated like
    the nav metrics).
  - Because the count runs over `world.levelLinks()` (including links the
    cursor has not processed yet), a refusal is consistent with the slot
    assignment the cursor will make.
  - The latch semantics are unchanged: the rising edge was consumed, so the
    player re-presses to retry elsewhere.
- `tryLinkPortal` keeps the `interiorLinkSlotExists` guard: it now means
  "unslotted by the K cap" in both paths, never "added after init". Its
  comment and the stale "not active" sentence are rewritten.

**E2. New links dirty both endpoints on both levels, under a fixed budget.**

- `PathfindingSystem.nav_links_processed: usize` is a cursor into
  `world.levelLinks()`, set to `levelLinks().len` by every full build.
- `pub const nav_new_links_per_step_max: usize = 8` (`types.zig`). It is fixed
  and covers every current producer (`DigController` makes at most one ramp
  per step).
- In `reactToPostCommitNavEvents`, before applying buffered updates:
  - take `new = levelLinks()[cursor .. min(len, cursor + 8)]`;
  - call `graph.assignLinkEndpointSlots(levelLinks(), cursor)` limited to
    that range;
  - for each new link, `markNavDirty(level_a, cell_a)` and
    `markNavDirty(level_b, cell_b)`;
  - advance the cursor by the processed count.
- Links past the budget are **deferred deterministically**: they keep link
  order and are processed by the next step's reaction, with
  `stats.links_deferred` counting them. The deferral depends only on world
  state and step, never on timing.
- `eventInvalidatesNavigation` is unchanged. The link cursor is a separate,
  world-derived trigger, so a non-flipping ramp dig still patches.
- `SimulationPipeline.pendingEventsMayInvalidateNavigation` callers also
  consult `PathfindingSystem.hasPendingNavLinks(world)` (`cursor <
  levelLinks().len`). `game_demo_state.zig`'s extra-event reservation in
  `applyStructuralCommandsAndPostCommitEvents` therefore covers the
  `nav_region_invalidated` event this produces.
- Per-step work for one ramp: 2 dirty cells, so at most 2 chunks per level ×
  2 levels plus their orthogonal border neighbors (at most 20 chunk patches),
  plus the existing O(links) `rebuildLinkEdges`. It is bounded by the fixed
  constants and independent of world size.

**E3. Memory gate.** `nav_memory.zig` `abstractGraphBytes` slot term becomes
`levels * chunk_count * (4*ct + nav_interior_link_slots_per_chunk)`. The
`2 * link_count` term is dropped. Its test and `docs/` sizing note are
updated. `budgetForCapacity` keeps `link_count` only for the `link_edges`
term.

**E4. Determinism and cache reaction.** No new event type. The existing
`nav_region_invalidated` (emitted when `incremental_rebuilds > 0`) drops
stale unavailable entries, as in `system.zig:4162`'s test, so NPCs that were
backing off re-request. `nav_version` stays stable (geometry-stable slots).
No allocation on the steady path: the fixed-stride table is sized at full
build; the dirty buffers are capacities sized from the loaded world and the
step's event capacity (capacity-audit item in the Checklist), so they do not
grow on the steady path. The claim is
proven by the FailingAllocator test in the Checklist, on the real
multi-worker patch path and the serial one.

### Checklist

- [x] **E1.** `nav_interior_link_slots_per_chunk`, fixed geometry,
      fixed-stride run table, `assignLinkEndpointSlots`, linear
      `linkTailIndex`, the warn-once-on-cursor rule, and the rewritten
      `tryLinkPortal` comment.
      (2026-10-05: `types.zig` constant; `nav_graph.zig`
      `computePortalGeometry`, `assignLinkEndpointSlots(links, first, source)`
      with `source = .full_build | .cursor` (warn only in `.cursor`), fixed-stride
      `chunk_link_cells`, `chunk_link_base` deleted, linear `linkTailIndex`.
      A ramp's two endpoints share one cell and count once. Full builds record
      their count in `NavGraph.full_build_link_endpoints_unslotted`.)
- [x] **E1 producer refusal.** `NavLinkSlotGeometry`,
      `interiorLinkSlotsAvailable`, `DigController.nav_link_geometry` +
      `ramp_refused_link_slots`, the pipeline wiring that sets the geometry,
      and the `dig_ramp_refused_link_slots` metric. Tests:
      (2026-10-05: `DigController.process` now takes `*DigController`. The
      geometry defaults to `NavLinkSlotGeometry.unresolved`, and a ramp dig with
      it unresolved returns `error.UnresolvedNavLinkGeometry` before any mutate,
      mirroring `UnresolvedDigTiles`. The metric is recorded through
      `SimulationPipelineStats.dig_ramp_refused_link_slots`, a per-step delta.)
  - [x] `interiorLinkSlotsAvailable` unit cases: perimeter cell always true;
        an already-present interior endpoint true at a full chunk; a ninth
        distinct interior cell false; links on two different levels at the
        same cell count once;
  - [x] in `dig_controller.zig`, `test "a ninth interior ramp in one nav
        chunk is refused"`: on a 2-level 8×8-tile fixture with an 8-tile nav
        geometry (36 interior cells; a 4-tile chunk has only 4 and could
        never reach K = 8), pre-author 8 distinct interior endpoints in
        chunk (0,0) through `addLevelLink`, then dig a ramp at a ninth
        interior cell of that chunk → no tile change, no event,
        `levelLinks().len` unchanged, `ramp_refused_link_slots == 1`; a ramp
        at a perimeter cell of the same chunk still digs.
- [x] **E2.** `nav_links_processed` cursor (reset by full builds),
      `nav_new_links_per_step_max`, endpoint dirtying on both levels,
      `links_deferred`/`link_endpoints_unslotted` stats (perf metric names
      `pathfinding_links_deferred`, `pathfinding_link_endpoints_unslotted`),
      `hasPendingNavLinks`, and the reservation wiring.
      (2026-10-05: `PathfindingSystem.markNewNavLinksDirty` advances the cursor
      only after both marks succeed. The cursor is reset by
      `rebuildStaticNavGridWithWorld`. It is deliberately NOT jumped by an
      in-update edge-cap fallback, so per-step accounting and the warn-once rule
      do not depend on whether a fallback fired; the cursor still visits deferred
      links (idempotent assignment). `SimulationPipeline.hasPendingNavLinks` is
      ORed into `game_demo_state.zig`'s extra-event reservation.)
- [x] **E3.** Memory-gate slot formula and its test.
      (2026-10-05: `abstractGraphBytes` and the per-participant patch-scratch
      bound both use `4*ct + K`. `link_count` now sizes an explicit
      `link_edges`/`link_edge_refs` term. Test: `"abstract slot term is levels *
      chunks * (4*ct + K) and links add only the link_edges term"`.)
- [x] Tests (tiny fixtures: `abstractCapacity()` 4-tile chunks on the
      384×384 px two-level world used by `nav_graph.zig:2223`, except where
      a test names an 8-tile chunk; a 4-tile chunk has only (4−2)² = 4
      interior cells, `isPerimeterCell` `nav_graph.zig:1074-1078`):
  - [x] Replace the `:2223` deferral test with `test "runtime interior ramp
        link is slotted and live after the incremental patch"`. Add a runtime
        link at interior (2,2) on levels 1↔0 and run the post-commit
        reaction. A cross-level request from level 1 to level 0 then returns
        `available` with `cross_level_solves == 1`. This test fails on
        today's code.
  - [x] `test "runtime link patch matches a full rebuild"`, covering four
        cases: an interior endpoint, a perimeter endpoint, a ramp on an
        already-walkable cell (no blocking flip), and links added across two
        steps. In each case, compare the incremental graph to a fresh full
        rebuild over the same world: `portals` and `cell_to_portal`
        byte-identical per level, per-portal edge sets equal (`:1840`
        helper), and `link_edges`/`link_edge_refs` equal.
  - [x] `test "a ninth authored interior link endpoint in one chunk stays
        unslotted in incremental and full builds"` (authored links only;
        the runtime producer refuses this case): use an **8-tile nav
        chunk** (36 interior cells) on the same 384×384 px two-level world,
        author 9 links with 9 distinct interior endpoint cells in chunk
        (0,0) through `WorldSystem.addLevelLink` after init, and run the
        post-commit reaction. Both the incremental graph and a fresh full
        rebuild leave the 9th inert, parity holds (same compare as the
        full-rebuild test), and `link_endpoints_unslotted == 1` in both
        builds' stats. (The warn-once-on-cursor rule is a review item: the
        `warn` call sits only in the cursor branch.)
  - [x] `test "new links beyond the per-step budget defer in link order"`:
        10 links in one step. Step 1 processes links 0–7 (`links_deferred ==
        2`) and step 2 processes 8–9. After step 2 the graph matches a full
        rebuild.
  - [x] `test "runtime link patch touches a constant chunk set independent of
        world size"`: mirror `:2763`'s two world sizes. The patched-chunk
        count is equal.
  - [x] `test "incremental runtime link assignment is allocation-free after
        warmup"`: warm one link reaction (one interior and one perimeter
        link processed through the cursor, so the dirty buffers and patch
        scratch reach their steady capacity); install
        `std.testing.FailingAllocator` on `graph.allocator` and
        `PathfindingSystem.allocator`; add one more interior and one more
        perimeter link; run `reactToPostCommitNavEvents` with a real
        3-worker `ThreadSystem` (the chunk patch is threaded through
        `nav_patch_tuner`, forced multi-range with `adaptive = false`), then
        repeat the same add + react with `null`. Both runs allocate zero
        times and match a full rebuild. The dirty-buffer appends (which grow
        rather than drop) stay within the capacity the warm cycle reached,
        which is what this test pins.
  - [x] End to end in `simulation_pipeline.zig`, on the sticky-dig fixture
        `testMinimalMultiLevelWorld`: `test "player-dug ramp is routable by
        an underground NPC the same step"`. Dig a ramp with the `dig_ramp`
        intent at an interior cell. After that step's post-commit reaction,
        `pathfinding.statusForWorld(lower, npc_pos, upper, goal, ...)`
        resolves to `available` within the next 2 steps.
- [x] **Capacity audit (2026-10-06): nav dirty buffers are load-time
      capacities.** Landed 2026-10-06 on its landed prerequisites: Slice 72
      B1 made `SimulationPipeline.reserve` the production init entry and C3's
      population seam re-runs it on growth. They were sized by the wrong quantity: `nav_dirty_levels`
      to a fixed `@max(nav_full_relabel_level_threshold, 8)` "independent of
      map size", and `nav_dirty_edits` / `nav_dirty_cell_spans` /
      `nav_changed_spans` to the agent-derived `max_frame_requests` (floor 8),
      so a 32-level world or a battle step grew them on the post-commit path.
  - `nav_dirty_levels` is reserved to `graph.levelCount()` in
    `rebuildStaticNavGridWithWorld`, beside `affected_levels`. It is deduped,
    so it holds at most one entry per level.
  - Every buffered mark comes from one committed `.structural_commit`-stage
    event (the reaction's stage filter; a `component_changed` adds at most two
    spans) or one new-link endpoint (at most `2 * nav_new_links_per_step_max`
    per step). The bound is therefore the **structural-stage event bound**,
    not the whole `capacity_limit`: `simulation.eventStageOf` classifies every
    `EventProducerId` (exhaustive switch beside `maxEventsPerStep`;
    `dig_world_edit`, `plane_traversal`, and `structural_commit` are
    `.structural_commit`; perception, affect, `action_react`, and
    `nav_reaction` are `.domain_reaction` and can never mark), and
    `SimulationPipeline.structuralStageEventBound()` sums `maxEventsPerStep`
    over that stage. Sizing from `capacity_limit` would also reserve for the
    perception and affect shares, about 2.5 MB at the 2053-body battle demo
    that can never be used. `SimulationPipeline.reserve`, after it settles
    `capacity_limit`, calls `pathfinding.reserveNavDirty(structuralStageEventBound())`,
    which reserves `nav_dirty_edits` to `bound + 2 * nav_new_links_per_step_max`,
    `nav_dirty_cell_spans` to `2 * bound`, and `nav_changed_spans` to their
    sum, and records the logical reservations (`nav_dirty_edits_reserved`,
    `nav_dirty_cell_spans_reserved`; grow-only). C3's `growPopulationCapacity`
    re-runs `reserve`, so the reservation follows the grown bound.
    `applyDerivedCapacity` no longer sizes these four buffers from
    `max_frame_requests`. A misclassified producer only under-reserves (a
    counted grow), never corrupts.
  - The grow-rather-than-drop fallback stays as the ReleaseFast safety net (a
    dropped cell leaves the graph stale, and a failed step's marks union into
    the next step's), now counted (`NavUpdateStats.dirty_buffer_grown`, perf
    metric `nav_dirty_buffer_grown`, `nav_dirty_buffer_grown_total`) with one
    `logging.game.warn`. `applyBufferedNavUpdates` compares each list's
    `.len` with its logical reservation (Slice 72 A1 rule), never
    `.capacity`, and counts only on a successful apply.
  - `default_nav_full_relabel_level_threshold` is unchanged: it is a fixed
    per-batch level fan-out bound that Slice 65B's classifier also reads, not
    a capacity. Its doc comment drops the stale "the demo's worlds have very
    few levels" (the procedural world has 32).
  - Tests (minimal fixtures; landed): after a build on a 128-level 1×1-tile
    world (past the old fixed 8 and its `ArrayList` growth rounding, so the
    test fails on the old reserve), marking every level dirty under a
    `FailingAllocator` allocates nothing and leaves
    `nav_dirty_levels.capacity` unchanged;
    with `std.testing.FailingAllocator` installed on `PathfindingSystem.allocator`
    and `graph.allocator` after `SimulationPipeline.reserve`, a step whose
    committed `.structural_commit` events fill `structuralStageEventBound()`
    with nav-invalidating tile changes plus 8 new perimeter links runs
    `reactToPostCommitNavEvents` (serial, then a real 3-worker
    `ThreadSystem` forced off the inline path) with zero allocations,
    `dirty_buffer_grown == 0`, and full-rebuild parity
    (`simulation_pipeline.zig` "post-commit nav reaction at the
    structural-stage bound allocates nothing"); a direct mark past the
    reserve grows, counts 1, and the graph still equals a full rebuild
    (`nav_graph.zig`); `eventStageOf` is pinned per tag (`simulation.zig`);
    a real demo-config commit step's structural-stage event count stays
    within the bound and the seam keeps the reservation at the grown bound
    (`game_demo_state.zig`).
- [x] **Capacity-audit follow-up (2026-10-06) to the landed 64E work:
      level links grow at the dig commit seam.** Landed 2026-10-06. As
      landed: the seam is `SimulationPipeline.ensureLevelLinkRoom`, called
      from the `dig_world_edit` stage when this step's `dig_intent == .ramp`
      and `!world.hasLevelLinkRoom()`, on the main thread before
      `DigController.process` mutates the world. It grows by a bounded
      ladder: `grownLevelLinkLimit(len) = len + len/2 +
      nav_new_links_per_step_max` (0 → 8, 8 → 20, 2048 → 3080), else exactly
      `len + 1`, whichever `PathfindingSystem.admitsLinkLimit` (the same
      `budgetForCapacity` gate as the build and `raiseAgentBudget`, charging
      the live agent ceiling) admits first; `reserveLinkCapacity` (→
      `NavGraph.reserveLinkEdges`) grows the nav link stores first, then
      `WorldSystem.ensureLevelLinkCapacity` raises the world's logical limit
      (exact) and storage (geometric), so an OOM leaves the world untouched
      and the next press retries. A refused growth keeps the pool, warns
      once, and the dig refuses the ramp into the new
      `ramp_refused_link_capacity` counter (perf metric
      `dig_ramp_refused_link_capacity`); `ramp_refused_link_slots` now counts
      only the K stride. Per-step stats `nav_link_capacity_grows` and
      `dig_ramp_refused_link_capacity` (`SimulationPipelineStats`, perf log
      nav line). `error.LevelLinkLimitReached` is deleted (`grep -rn
      LevelLinkLimitReached src/` is empty); `addLevelLink` past the limit
      grows it by one (authoring safety net). Extra sites carried (Slice 72
      K6, world-data-world-02): the `level_link_limit` field comment (now
      "the logical link count derived stores size from; set at load, raised
      at the dig seam, not a refusal bound"), the `demoLevelLinkLimit` doc
      ("initial reservation"), and the `hasLevelLinkRoom` callers (the seam
      trigger and the dig's capacity refusal). Tests: `world_system.zig`
      "addLevelLink past the reserved limit grows the logical limit instead
      of refusing" (+ FailingAllocator OOM variant); `simulation_pipeline.zig`
      "a ramp dig past the initial link reservation grows at the dig seam and
      is routable", "link growth happens only at the dig seam" (world, graph,
      and pathfinding allocators failing: seven ramps within the grown pool
      allocate nothing; the ninth's seam growth returns `OutOfMemory` with
      limit, links, and tile unchanged; after restore it grows to 20 and the
      following dig + reaction allocate nothing), and "a link growth the nav
      memory gate refuses keeps the pool and refuses the ramp loudly" (+ the
      `len + 1` ladder rung); `dig_controller.zig` "a ramp dig with no
      reserved link room is refused before mutating"; `nav_graph.zig`'s
      runtime-link proof now expects `OutOfMemory` for the seventh link under
      the failing world allocator, then lands it and checks parity. Each was
      confirmed to fail with the growth reverted. Bench (ReleaseFast, 5
      interleaved reps, `1e951ba` → this commit; the build path now goes
      through `reserveLinkEdges`): every case within max(3%, spread), 0
      breaches; `nav-update-links` 8 serial 202.02 → 195.57 us, tuned 196.77
      → 196.46 us; `nav-update-scattered` 256 serial 3.13 → 3.18 ms (spread
      5.7%). No group isolates the dig stage. Original item text: today a perimeter-ramp dig
      is refused once the load-sized level-link pool is spent
      (`WorldSystem.addLevelLink` / `ensureLevelLinkCapacity` return
      `error.LevelLinkLimitReached`), so a capacity changes gameplay.
      `addLevelLink` grows `level_links`, `link_edges`, `link_edge_refs` at
      the dig commit seam (main thread, geometric); only the 8-per-chunk
      interior stride (`nav_interior_link_slots_per_chunk`, a layout bound)
      refuses. The load-time reservation stays as the initial size, the nav
      memory gate re-admits after a grow, and `level_link_limit` stops being
      a refusal bound. FailingAllocator proof for steady state +
      growth-at-seam (steady link adds within the reached size allocate
      nothing; a grow happens only at the dig commit seam, and the commit
      completes when the next allocation after the grow fails); test that a
      dig past the initial link reservation succeeds (the ramp tile, the
      link, and a routable path all land, and `dig_ramp_refused_link_slots`
      stays 0 for a perimeter cell). `docs/architecture.md`'s level-link
      paragraph is updated in the same change.
  - [x] **Review follow-ups (2026-10-06)** to the link-growth item, each with
        a test confirmed to fail with its fix reverted. Supersedes the as-landed
        text above where they differ.
    - **L3 · growth only for an admitted dig.** The seam used to run for any
      ramp intent, so a press the dig then refused or no-oped (surface,
      existing link, off-world, K stride) still grew the pool, and press
      history could change later refusals. `DigController.process` is now
      `admit` (every no-op and refusal except pool room; reads the world,
      mutates only the K-stride counter) + `commit` (the capacity refusal,
      the event/stimulus preflight, the mutate). The stage runs
      `SimulationPipeline.admitDigAndGrowLinks` (admit, then
      `ensureLevelLinkRoom` only for an admitted ramp), then commit. A
      K-stride refusal now wins over a full pool (it used to count as a
      capacity refusal when both held). Test: `simulation_pipeline.zig` "a
      ramp press the dig does not admit never grows the full link pool"
      (surface and off-world presses through `pipeline.update` leave the
      limit, link edges, and grow counters at 0; the next admitted ramp
      grows). Branch-review follow-up: the remaining test-only
      `DigController.process` wrapper (admit + commit with no seam) was
      removed from the production API; pipeline and demo tests dig through
      the real pipeline step (`SimulationPipeline.update` via the demo's
      `digFacedForTest`; the admission seam is private again), and
      `dig_controller.zig`'s own tests
      use a private `digPressForTest` helper.
    - **L4 · no in-step growth past a reserved limit.** `addLevelLink` /
      `ensureLevelLinkCapacity` on a reserved world used to grow the limit by
      one without the nav-memory gate or `reserveLinkCapacity`, leaving the
      nav link edges to grow in-step through `rebuildLinkEdges`' authoring
      safety net. Past the limit they now return
      `error.LevelLinkRoomUnreserved` without growing; the seam raises the
      limit with `reserveLevelLinks(target)` after `reserveLinkCapacity`.
      Unreserved (authoring) worlds still grow. Tests: `world_system.zig`
      "addLevelLink past the reserved limit fails loudly; only
      reserveLevelLinks raises it" (replaces "…grows the logical limit
      instead of refusing"); `nav_graph.zig`'s runtime-link proof now
      expects the seventh direct link refused with zero allocations, then
      lands it through the seam's order (`reserveLinkCapacity`,
      `reserveLevelLinks`).
    - **L5 · a growth OOM leaves the step retryable.** The seam ran after
      `sensory.promote`, so an OOM had already moved the deferred impacts
      onto a live bus the next `beginStep` clears. Admission and growth now
      run first in `dig_world_edit`, before the promote. Test:
      `simulation_pipeline.zig` "a link-growth OOM leaves the step's stimuli
      and the pool for the retry press" (FailingAllocator on the world,
      pathfinding, and graph allocators: the step returns `OutOfMemory` with
      the impact still deferred, the live bus empty, and the pool, counters,
      and tile unchanged; the retry press grows, digs, and promotes the
      impact).
    - No bench: the dig stage has no isolating group, and the change only
      reorders cold per-press calls.
- [x] Docs:
  - `docs/architecture.md` / pathfinding docs: runtime links patch both
    levels, the fixed interior link slots, the per-step link budget, and
    deferral;
  - `docs/reviews/` pathfinder note if present;
  - drop the "deferred until full rebuild" wording.

### Acceptance checks

- [x] `zig build verify` passes. All E tests pass in Debug and ReleaseFast.
      The replaced deferral test is gone (`grep -n "deferred by the
      incremental patch" src/` is empty).
- [x] Manual (display, procedural demo): dig a ramp at a non-border cell on
      level 1. NPCs on level 1 path up it within a second, with no
      save/load or restart. Confirmed by the owner 2026-10-06 (Debug build,
      battle demo): NPCs followed dug ramps out; perf dump showed 14 tile
      changes → 13 incremental rebuilds, `full_relabel=0`, `links_deferred=0`,
      `link_endpoints_unslotted=0`, both ramp refusal counters 0.
- [ ] **Post-fix manual check on current code** (display; Debug or
      ReleaseSafe build). The run above predates the in-place edge-window
      growth and its M1–M7 follow-ups. Dig several ramps in one open chunk:
      the perf dump shows `edge_windows_grown > 0` and `full_relabel=0`,
      the log has no `nav update refused` error (no edge-growth refusals)
      and no `landed without edge growth slack` warn, and NPCs route over
      the new ramps.
- [x] **Edge-window overflow after runtime ramps (found in the 2026-10-06
      manual run).** Later in the same run the log printed
      `nav abstract-graph edge-cap fallback: per-chunk edge window overflow,
      full rebuild with slack 4`. Fixed 2026-10-06.
  - **Root cause.** A full build sized each chunk's edge window as
    max(measured edges × 2, 32) and never grew it. A chunk's edge count is
    quadratic in its same-component portals: b border-run portals plus k link
    endpoints give b + (b+k)(b+k−1) edges. An open interior chunk builds with
    4 border portals, so 16 edges and a 32-edge window. Since this slice, every
    runtime ramp endpoint is a real portal, so the **second** ramp in one open
    chunk (4 + 6·5 = 34 edges) overflowed. The overflow fell back to a full
    abstract rebuild of every level with doubled slack (the logged "slack 4" is
    the first fallback) plus a `nav_version` bump. Digging alone triggers the
    same overflow: a corridor lattice giving a walled chunk 12 border runs makes
    144 edges. So the cause is the window policy, not the slot count.
  - **True maximum rejected.** Edges per chunk are bounded by layout, but the
    bound is quadratic. Every perimeter cell can be a ramp endpoint (perimeter
    endpoints need no interior slot), so at ct = 16 the bound is 60 perimeter
    cells + 8 link slots in one component: 32 + 68·67 = 4,588 edges, about
    37 KB per chunk-level. For the 256×256×32 demo that is about 300 MB of
    resident edge arena against about 2 MB measured.
  - **Fix: deterministic in-place window growth.** Nothing is rebuilt.
    - A chunk whose edges outgrow its window has just that window (shared by
      every level) relocated to the arena tail with cap = max(2 × its new edge
      count, 32). Every level's window contents are copied, and the chunk's
      `portal_edge_start` entries are rebased. Arena capacity for every level
      is ensured before any mutation, so an OOM leaves the layout intact.
    - The chunk is then re-patched on the main thread
      (`NavGraph.growChunkEdgeWindow` / `relocateChunkEdgeWindow` in
      `nav_graph.zig`). The serial patch does this inline. The threaded patch
      sets a per-chunk flag (`chunk_edge_overflow`, a disjoint write sized at
      build), and a serial pass after the barrier grows the flagged chunks in
      dirty-set order, so the resulting layout is the same either way.
    - The step stays an incremental patch with no `nav_version` bump, and the
      graph equals a full rebuild.
    - Growth is geometric (a window at least doubles each time, so a chunk
      grows at most about 8 times between full builds). Vacated windows are
      holes until the arena is compacted in place or the next full build
      re-measures it (see the review follow-ups below).
    - `edge_slack` and the fallback are deleted. `NavUpdateStats.edge_cap_fallback`
      becomes `edge_windows_grown` (perf metric `nav_edge_windows_grown`), and
      growth logs one `debug` line.
    - Slice 72 E4 (a fallback without the version bump) is superseded and
      closed. The 65B, 69A, and 64B cross-references and `architecture.md`
      are updated.
  - **Tests (the regression tests failed before the fix with
    `edge_cap_fallback == 1`):**
    - `"runtime ramps filling one chunk's link capacity grow its edge window in
      place, never rebuilding"`: 8 ramps, one per step, in one 8-tile chunk.
      It covers the interior and perimeter variants, each serial and through the
      3-worker threaded patch. Every step has `version_bumps == 0`, there are
      exactly 2 growths (32 → 68 → 152), and the result matches
      `expectLinkPatchMatchesFullRebuild`.
    - `"incremental dig opening many border crossings in one chunk grows its edge
      window in place"`: the dig-only classifier, compared against a full
      rebuild.
    - `"after an edge-window growth, ramps that fit the grown window are
      allocation-free"`: a FailingAllocator on the world, graph, and system,
      threaded and serial, with 0 allocations.
    - Updated tests: the forced-overflow test now expects every window to grow
      with no bump; `system.zig`'s high-water test expects `version_bumps == 0`
      and stays allocation-free afterwards; the cursor test keeps only the
      full-relabel variant.
  - **Verify and bench.** `zig build verify` and `zig build test` pass in Debug
    and ReleaseFast. Bench: ReleaseFast, 3 interleaved runs against a `HEAD`
    export, medians. Every recorded case of `nav-update-links`,
    `nav-update-scattered`, and `nav-update-multichunk` is within
    max(3%, spread), with 0 breaches:
    - links 8, serial: 198.68 → 205.05 us (spread 7%);
    - scattered 64, serial: 830.55 → 828.99 us;
    - scattered 256, serial: 3.23 → 3.26 ms;
    - multichunk 16384, serial: 999.08 → 995.75 us.
  - **New group `nav-update-links-dense`.** It adds 8 ramps in one chunk in one
    step, which crosses the window. Serial: 196.30 → 31.47 us (−84%). Tuned:
    185.70 → 30.53 us. That is on the 2-level bench fixture; the removed full
    rebuild scales with level count, so the 32-level demo saves more.
  - **Memory.**
    - Steady state is unchanged: build-time window sizing is identical, plus
      one bool per chunk. `ChunkPatchScratch` loses a field but keeps its
      64/128 B slot.
    - A growth adds 2 × edges × 8 B per level. At 32 levels that is 17 KB for
      the first growth of an open chunk and 39 KB for the second.
    - The first growth that exceeds an arena's capacity reallocates it
      geometrically (ArrayList growth, about 1.5×; about 1 MB of capacity at
      256×256×32), so later growths usually allocate nothing.
    - The old fallback instead re-measured every window at slack 4, roughly
      doubling every busy chunk's window.
  - [x] **Review follow-ups (2026-10-06) to the edge-window growth.** Each
        behavior test below was confirmed to fail with its fix temporarily
        reverted; the coverage tests pass on both.
    - [x] **M1 · OOM at any allocation of a growth step.** `nav_graph.zig`
          "an edge-window growth failing at any allocation retries to a
          full-rebuild graph" sweeps `FailingAllocator.fail_index` 0..N over
          the step whose second ramp relocates chunk (1,1)'s window (each
          level's arena is trimmed to its length first, so the relocation
          really allocates), serial and through the real 3-worker patch.
          Every failure leaves no overflow flag set and `nav_version`
          unchanged; the retry (the step's marks stay buffered) gives the
          68-edge window and `expectLinkPatchMatchesFullRebuild` parity. Fix:
          the threaded post-barrier grow loop now visits and clears every
          flag of the batch even past a failed growth (first an `errdefer`,
          replaced by M4's visit-all loop), so a failed growth no longer
          leaves later chunks flagged into the next patch. Behavior test: "a threaded multi-chunk window growth that
          fails clears every overflow flag" (an odd-row/column lattice dig
          overflows all nine chunks in one threaded batch; same sweep, then
          full-rebuild parity).
    - [x] **M2 · edge order, A* results, serial = threaded.**
          `expectGraphsEquivalent` now also compares every portal's edge
          SEQUENCE keyed by (level, cell) (`expectPortalEdgeSequencesEqual`):
          abstract A* relaxes edges in CSR order (`solve.zig`
          `abstractCorridor`), so order decides tie-breaks. Every existing
          incremental-vs-full test passes the stricter compare. New: "abstract
          A* after an edge-window growth returns the paths of a fresh full
          rebuild" (after two growths, same-level paths across the grown
          chunk on both levels and two cross-level paths through its ramps
          give identical cached plain and stitched paths) and "serial and
          threaded edge-window growth build identical layouts" (lattice dig
          growing several windows in one batch, and the 8-ramp sequence:
          `chunk_edge_base`/`cap`, arena size, holes, per-slot CSR starts and
          counts, and edge sequences identical after every step).
    - [x] **M3 · holes, memory, and the nav memory gate.**
      - Hole metric: `NavGraph.edge_hole_slots` (per-level arena slots no
        window references; zeroed by a full build or a compaction), reported
        every step as `NavUpdateStats.edge_hole_slots` (perf gauge
        `nav_edge_hole_slots`, printed as `edge_hole_slots_max`), plus the
        counters `edge_compactions` (perf `nav_edge_compactions`),
        `edge_compactions_total`, and `edge_growth_refused_total`.
      - Compaction: `NavGraph.compactEdgeArena` packs the windows toward the
        arena front in place, visiting chunks in ascending current base so a
        forward copy never overwrites an unmoved window. It keeps caps and
        edge order, rebases `portal_edge_start`, keeps each arena's capacity
        for later growths, and allocates nothing (the chunk order reuses
        `build_u32_scratch`, sized to `total_slots` at every full build). It
        runs only on the memory-gate path below. Owner decision 2026-10-06:
        the first version also had a post-patch trigger ("compact when holes
        outnumber live window slots") and a test that relied on a test-built
        fragmented layout. Both were removed because the trigger could never
        fire. Each relocation adds its old cap to the holes and a new cap of
        max(2 × needed, floor), which is more than 2 × the old cap, to the
        live windows. So holes ≤ live window slots always holds, and
        `applyNavUpdates` now `std.debug.assert`s it after the patch barrier
        where the trigger used to sit. The compaction's zero-allocation proof
        moved into the gate test (threaded, `FailingAllocator`).
      - Gate: the full build sets `edge_arena_slot_limit` from
        `NavMemoryBudget.edgeArenaSlotLimit`, which is the gate's own
        per-level edge-arena estimate plus the headroom `max_nav_memory_bytes`
        (e.g. `autoSizedMaxNavMemoryBytes`) leaves. The full build and a
        full relabel refuse (`NavWorldTooLarge`) when the measured arena
        exceeds the ceiling even unslacked, before any layout write (M5,
        M8's ladder). A relocation past it compacts first, then tries an
        unslacked window (M8). If it still does not fit, the step fails
        deterministically with `NavWorldTooLarge`, counted in
        `edge_growth_refused_total` with an `err` log; the chunk keeps its
        live portals with empty adjacency, and the rest of the dirty set is
        still patched (M4). The arena's geometric growth is clamped to the
        limit. `raiseAgentBudget`, `admitsLinkLimit`, and
        `reserveLinkCapacity` charge the arena's live edge slots (M6) and
        re-derive the limit, so headroom spent on edges is not admitted
        twice. Tests: "an
        edge-window growth past the nav memory gate compacts first, then
        refuses loudly" (compaction admits ramp 5's growth under a pinned
        ceiling, through the real 3-worker patch's post-barrier pass with a
        `FailingAllocator` on the graph and system: 0 allocations,
        `edge_compactions == 1`; then a growth with no hole to reclaim is refused twice in a
        row, counted, with no flag left set, and lands with parity once
        admitted); "link growth and agent-budget raises charge the edge
        arena's live slots grown by real relocations, never physical capacity
        or holes" (M6's rewrite); `nav_memory.zig` "edgeArenaSlotLimit
        is the per-level arena estimate plus the budget's headroom".
      - Memory: steady state is unchanged (24 B of new `NavGraph` fields, no
        per-chunk arrays). Holes stay below the live window slots, so an
        arena is at most about 2× its live windows plus at most 1.5×
        capacity growth. That growth is clamped to the gated ceiling, and a
        compaction returns the holes to the free tail for reuse instead of
        allocating.
    - [x] **E4 · cached path survives a growth.** `nav_graph.zig` "a cached
          path outside the dirty batch survives an edge-window growth and
          equals a fresh solve": a top-row path (chunks 0–2) cached before
          the step that grows chunk (1,1)'s window keeps its cache slot and
          stitched cells unchanged, `nav_version` stays the same, it still
          answers `available`, and it equals a fresh solve on a full rebuild.
          This is the test Slice 72 E4 (closed as superseded) now points to.
    - [x] **M4 · a failed growth still patches the whole dirty set.** The
          serial patch used to `try` each chunk's growth and return at the
          first refusal or OOM. The refused chunk's orthogonal neighbors come
          later in the dirty set, so they kept CSR edges into its old
          border-run slot, which its own patch had just tombstoned (when the
          edit moved that run's midpoint). Abstract A* then popped the
          tombstone and indexed `components` with `no_cell`: a Debug panic,
          UB in ReleaseFast. The threaded path already patched every chunk
          before its post-barrier growth pass.
      - Policy (`NavGraph.patchDirtyChunks`, both paths): every dirty chunk
        is patched and, where it overflowed, grown; the first error
        (`ChunkPatchError = Allocator.Error || NavGridError`) is returned
        after the loop. A refused chunk keeps the live portals
        `buildChunkPatch` rebuilt, with empty adjacency, and its neighbors
        are patched against them, so no CSR edge targets a tombstone. The
        serial and threaded failure layouts are identical. The serial
        `patchChunk` error routes through the main-thread re-patch like
        `patchChunkJob`'s (`catch true`). `edge_growth_refused_total` now
        counts one per refused chunk. Later affected levels keep their old
        mask and abstract layer (self-consistent) until the retry, which
        re-patches the buffered dirty set.
      - `solve.zig` `abstractCorridor` asserts a popped portal is live
        (`std.debug.assert(portal.cell_index != no_cell)`) instead of
        skipping: a tombstone there is a graph-invariant bug, the assert is
        stripped from the ReleaseFast hot loop, and a skip would hide the
        bug.
      - Test: "a refused edge-window growth still patches the rest of the
        dirty set, serial and threaded, with no edge into a tombstone".
        Chunk (1,1) holds one ramp; one step adds a second and blocks
        (8,12), the midpoint of its left border run, under a gate pinned at
        the arena size (5 border + 2 link portals = 47 edges > 32, refused).
        Serial and 3-worker threaded: `NavWorldTooLarge`, one refusal, no
        flag set, `nav_version` unchanged, the chunk's level-0 edge counts
        zero with (9,9), (11,9), (8,10), (8,14) live and (8,12) not, and
        `expectNoEdgeTargetsTombstone` holds; the two layouts, portals, and
        `cell_to_portal` are identical. A same-level and a cross-level solve
        then route around the chunk (`available`). Admitted, the retry grows
        the window to 94 and matches a full rebuild, serial == threaded, and
        a new request equals a fresh solve. Before the fix the oracle fails
        and the cross-level solve traps (h = 0 on its start level pops the
        tombstone).
    - [x] **M6 · re-admission charges live edge slots, not physical
          capacity.** `edgeArenaFitsBudget` compared the largest per-level
          `portal_edges.capacity` with the ceiling. That is
          history-dependent (`setLen` rounding, 1.5× geometric growth,
          compaction keeps capacity), so `raiseAgentBudget` and the dig
          seam's `admitsLinkLimit` could refuse or admit on allocator
          history; the old test flipped results only by changing physical
          capacity.
      - One logical quantity: `NavGraph.edgeArenaLiveSlots()` =
        `total_edge_slots - edge_hole_slots`, what the arena occupies after
        a compaction. The relocation gate already admits exactly
        live + new_cap ≤ limit (it compacts first when holes exist), so
        charging live makes the build, relocation refusal, and
        re-admission one predicate. Charging `total` would refuse what the
        next relocation admits. `edgeArenaCapacitySlots` is deleted.
      - Physical capacity is not charged and never consulted; M9 clamps it
        to the ceiling at every seam (build reserve, growth, re-admission),
        so resident arena bytes stay within the gate's arena share.
      - Asserts: `applyEdgeArenaBudget` and `applyNavUpdates` assert live ≤
        `edge_arena_slot_limit` (callers gate first); the relocation asserts
        each arena's capacity covers the new length before its `.len`
        write; the compaction asserts its packed length equals the live
        slots. The refusal log prints the live slots.
      - Test (rewritten): "link growth and agent-budget raises charge the
        edge arena's live slots grown by real relocations, never physical
        capacity or holes". A one-chunk 8×8 two-level world takes 36 ramps,
        8 per step; real relocations grow its window 32 → 112 → 480 → 1104
        → (fits) → 2520, leaving 1728 holes (total 4248, live 2520; both
        verified by running). With a byte ceiling one slot under the live
        slots at 600 links, `admitsLinkLimit(600)` flips from true to false
        only through the relocations, while `admitsLinkLimit(36)` stays
        true even though `total_edge_slots` exceeds its ceiling. Growing
        every arena to 10,000 slots and trimming it back to its length
        changes neither answer. An agent-budget raise is refused one slot
        under the live slots and admitted at them, which sets the growth
        ceiling. The test fails with the old capacity-based gate.
    - [x] **M5 · the build checks its measured arena against the gate.**
          `rebuild` set `edge_arena_slot_limit` from the gate's structural
          estimate, but `computeEdgeCaps` sized the arena from measured
          topology and never compared the two (nor did the full relabel).
          A dense world built past its ceiling, and every later relocation
          and re-admission was then refused.
      - `computeEdgeCaps` now measures the per-chunk maxima into
        `build_u32_scratch` (allocation-free after the first build), sums
        the would-be arena, and returns `NavWorldTooLarge` with an `err` log
        when it exceeds `edge_arena_slot_limit` (holes are zero at this
        seam), before writing caps, bases, overflow flags, the total, or
        the holes. M8 adds an unslacked rung before the refusal. The init build fails at load as the gate promises. A
        failed full relabel keeps the old windows, caps, bases, and arena;
        `buildLevelInit` has already rebuilt every level's portals with zero
        edge counts, so the graph is solve-safe, and `version` is not
        bumped.
      - Tests: "a measured edge arena past the nav memory gate fails the
        build loudly" (36 ramps authored before the build of the one-chunk
        8×8 two-level world: 36·35 = 1260 edges, a measured 2520-slot arena
        against the gate's 704-slot estimate; a byte ceiling one slot under
        it fails the build, at it the build lands with the arena exactly at
        the ceiling) and "a full relabel whose re-measured arena exceeds the
        gate fails before touching the edge layout" (2×2 chunks, relabel
        threshold 1, ceiling pinned one slot under the arena, one interior
        ramp: `NavWorldTooLarge`, caps, bases, total, and every level's arena
        byte-identical, no holes, `version` unchanged, every edge count zero,
        the ramp cell live on both levels, no edge into a tombstone, a
        cross-chunk solve completes; admitted, the retry relabels and
        matches a full rebuild). Both fail with the check removed.
    - [x] **M7 · link-cursor stats survive a failed apply.**
          `markNewNavLinksDirty` advances the cursor and returns per-call
          stats when its marks land; `reactToPostCommitNavEvents` then
          applied the buffered updates, and a failed apply dropped those
          stats. The retry's cursor call found nothing new and reported
          `links_deferred = link_endpoints_unslotted = 0` for the links it
          actually folded.
      - Fix: `PathfindingSystem.nav_link_cursor_pending` (a
        `NavLinkCursorStats`) carries the counts until an apply succeeds:
        `processed` and `unslotted` accumulate, `deferred` is the latest
        gauge. `reactToPostCommitNavEvents` reports and clears it after a
        successful apply; a full build resets it. The cursor's standalone
        contract (its return value, used by the `nav-update-links` bench) is
        unchanged. Rolling the cursor back instead would re-mark the same
        links on the retry and push the dirty buffer past its logical
        reservation (a false `dirty_buffer_grown`).
      - Test: "link cursor stats of a failed apply are reported once by the
        successful retry". Chunk (0,0)'s interior slots are filled; one step
        then adds a ninth interior ramp there (unslotted) and five interior
        ramps in chunk (1,1), whose growth (2 + 7·6 = 44 edges > 32) the
        pinned gate refuses. After the failed step the cursor is at 14 and
        the pending stats are {6 processed, 0 deferred, 1 unslotted}; the
        admitted retry reports `link_endpoints_unslotted == 1` and
        `links_deferred == 0`, clears the pending stats, and matches a full
        rebuild. Before the fix the retry reported 0. This also exercises
        M4's serial continue-after-refusal.
    - [x] **Bench (M4–M7).** ReleaseFast, 3 interleaved runs of `3f54b79`
          (before) and `cf1107f` (after) exported with `git archive`,
          medians. All touched paths are cold (refusal, build check, gate)
          except the serial patch loop's `catch` restructure; the solve
          assert is stripped in ReleaseFast. Every case of
          `nav-update-links`, `nav-update-links-dense`, and
          `nav-update-scattered` is within max(3%, spread), with 0 breaches:
          links 1 serial 25.62 → 26.08 us (spread 4.8%); links 8 serial
          195.38 → 195.95 us; links-dense 8 serial 31.51 → 31.31 us;
          scattered 16 serial 207.30 → 204.43 us; scattered 64 serial 820.43
          → 818.79 us; scattered 128 serial 1.54 → 1.62 ms (spread 5.8%);
          scattered 256 serial 3.12 → 3.14 ms. `pathfinding` 512 (4
          interleaved runs, since the first single run was noisy): serial
          3.42 → 3.49 ms (spread 12%), adaptive-tuned 485.8 → 488.7 us.
    - [x] **M8 · one slacked → unslacked → refuse sizing ladder** (third
          review, 2026-10-07). The build required 2× slack per window while
          relocation only preferred it, so an admitted incremental session
          could fail to re-measure: reproduced on `aad4acb` (one 8×8 chunk,
          1600-slot ceiling, windows 112/480/1104, 992 live edges; the relabel
          and a same-budget load both returned `NavWorldTooLarge`, the relabel
          on every retry).
      - Fix: `windowCap(needed, slack)` shared by `computeEdgeCaps` and
        `relocateChunkEdgeWindow`: slacked, then (relocation compacts first)
        unslacked, then refuse; unslacked landings count in
        `edge_arena_unslacked_total` (build: one `warn`). Every live window
        holds ≥ max(edges, floor), so any admitted state re-measures under
        its ceiling. No constant changes; rungs move only window layout.
      - Tests (fail with rung 2 removed): "a world grown incrementally under
        the nav memory gate re-measures under the same ceiling (1600-slot
        relabel)" (relabel and load land at 992; past-ceiling ramps still
        refused), "a window growth whose slacked size exceeds the ceiling
        lands unslacked before refusing" (56-slot unslacked landing under a
        100-slot ceiling, then refusal), and the updated build test (refuses
        at 1259, unslacked 1260–2519, slacked 2520; same graph and paths).
    - [x] **M9 · every arena's capacity stays within the ceiling.** Build
          `setLen` rounding (~1.5×, unclamped), holes, and a re-admission
          that lowered the ceiling under the arena's length all left resident
          arena past `levels × limit × 8 B`. Fix: `placeLevelEdges` reserves
          `max(total, min(growCapacity(total), limit))` (unchanged away from
          the ceiling); `applyEdgeArenaBudget` compacts when `total > limit`
          and `fitArenaCapacityToCeiling` shrinks each arena to its length
          when its capacity exceeds the ceiling (best effort by std
          `shrinkAndFree`); `compactEdgeArena` is infallible
          (`buildScratchAssumeCapacity`: every build sized the scratch to
          `total_slots ≥ chunk count`). The gate stays logical (live slots).
          `NavLevelGraph.edge_scratch` (a whole level's build staging) was
          resident too: it is now freed at the end of every build, a
          build-time transient outside the resident bound (no current
          allocation proof covers a relabel with edges; 65B's planned
          allocation-free rebuild test excludes it). Tests (fail with the
          fix reverted): the M6 test's admitted raise now ends compacted with
          every arena at 2520; "a re-admission that lowers the ceiling under
          the arena's length compacts first and never past the gate" (1728 →
          1104 under a 1600 ceiling, then the next growth is refused); the
          build test asserts the clamp at the ceiling (pre-fix 3788 > 2520),
          the unchanged reserve away from it, and freed staging lists.
    - [x] **M10 · a failed step's growths and compactions are reported by
          the next success** (third review, 2026-10-07). Fix: lifetime
          `edge_windows_grown_total` counted at the source plus
          `edge_windows_grown_reported` / `edge_compactions_reported` cursors;
          a successful `applyNavUpdates` reports `total − reported` after its
          last fallible step; a full build syncs the cursors.
          `patchDirtyChunks`/`growChunkEdgeWindow` return `!void`. Test: "edge-window
          growths and compactions of a failed step are reported by the next
          successful step" (a step grows chunk 1, compacts twice, and is
          refused on chunk 4; the retry reports 2 growths and 2 compactions;
          per-step counting reports 1 and fails).
    - [x] **M11 · one refusal `err` per failed step.** The per-chunk refusal
          line in `relocateChunkEdgeWindow` is now `debug`; `applyNavUpdates`
          logs one comptime-gated `err` per failed step (refused-chunk count,
          level, live slots, ceiling). No test (logs are gated out of tests;
          `edge_growth_refused_total` is already asserted).
    - [x] **M12 · a degraded apply drops the completed cache.** Paths
          solved between a failed apply (refused chunk with empty adjacency,
          later levels on their old layer) and its retry could detour and
          survive the retry's scoped eviction. Fix:
          `PathfindingSystem.nav_apply_degraded`, set on any apply error; the
          next successful incremental apply clears the whole completed cache
          (a relabel or full build already does) and resets it. Test: the M4
          refusal test now asserts the flag across the failure and retry and
          that the detour cached before the retry re-solves to a fresh
          rebuild's direct path (fails without the clear: the stale detour
          stays cached). 65B's `NavWorldTooLarge` swap rule sets it.
    - [x] **M13 · tombstone oracle in the OOM sweeps.** Both growth OOM
          sweeps call `expectNoEdgeTargetsTombstone` on every failed step
          before the retry, and the lattice sweep now runs serial and
          threaded (`ran_inline` checked per variant). Test-only coverage of
          M4's failure state under OOM.
    - [x] **Bench (M8–M13).** ReleaseFast, 3 interleaved runs of `aad4acb`
          (before) and `3c31040` (after) exported with `git archive`,
          serial-direct medians; per-step change is two u64 subtractions.
          All within max(3%, spread): links-dense 8 31.47 → 31.15 us;
          scattered 16 208.64 → 206.67 us, 32 412.33 → 408.72 us, 64 811.76
          → 807.34 us, 128 1.57 → 1.55 ms, 256 3.11 → 3.07 ms.
    - [x] Docs: `slice-64b.md` (relocation moves a window, not edge order),
          `slice-69a.md` soak bounds for `edge_windows_grown` and the hole
          gauge, `slice-72.md` E4 reference, `architecture.md`.
    - [x] Bench: ReleaseFast, 3 interleaved runs against a `b39e016` export,
          medians, serial-direct (the growth, compaction check, and gate
          check are cold, main-thread, and off the per-chunk path). Every
          case is within max(3%, spread): links-dense 8: 32.90 → 32.69 us;
          links 1: 27.44 → 27.08 us; links 8: 212.61 → 213.41 us; scattered
          16: 211.88 → 210.97 us; scattered 64: 838.06 → 839.60 us; scattered
          256: 3.34 → 3.34 ms. The adaptive-tuned rows are tuner-noisy (up to
          240% spread) and none regressed.
- [x] Capacity audit: the dirty-buffer `FailingAllocator` test passes serial
      and threaded, and `nav-update-scattered` / `nav-update-links` stay
      within max(3%, noise) of their recorded medians. Recorded 2026-10-06
      (ReleaseFast, 5 interleaved reps, medians, `1e951ba` → nav dirty-buffer
      commit; every case of `nav-update-scattered`, `nav-update-links`, and
      `nav-update-multichunk` within max(3%, spread), 0 breaches):
      scattered 64 serial 825.24 → 821.45 us, 256 serial 3.17 → 3.21 ms
      (spread 4.4%), 256 tuned 580.68 → 532.03 us; links 8 serial 196.39 →
      195.53 us, tuned 198.04 → 195.75 us; multichunk 4096 serial 253.38 →
      245.02 us, 16384 serial 980.17 → 933.70 us.
- [x] Bench gate (ReleaseFast, 5 interleaved repetitions, medians, adjacent
      commits):
  - new group `nav-update-links` (`src/benchmarks/nav_update.zig`
    `links_group`, registered in `runner.zig`; items = links added per batch
    `{1, 8}` on the 256×256×32 fixture). The 8-link batch mean must be ≤ 2×
    the `nav-update-scattered` 16-chunk mean, the same dirty footprint
    order;
  - `nav-update-scattered`, `nav-update-multichunk`, and
    `--group pathfinding` must not regress by more than max(3%, noise) at
    any recorded count (slot arrays grow by ≤ 12.5%; abstract search visits
    only live portals).

  Record the tables in Status.

---

