## Slice 64E: Incremental Nav Patch Ramp/Link Parity

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: implemented (2026-10-05)**, except the display-gated manual
acceptance check (not run: no display in the implementing session). Every
code, test, doc, and bench item below is checked. No open prerequisite. This
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
- **Link storage is a load-time capacity** (CLAUDE.md budgets/capacities rule):
  - `WorldSystem.reserveLevelLinks` sets a limit, and the demo sizes it as
    authored links + world chunks × K.
  - The memory gate and the build's `link_edges` reservation both use
    `levelLinkLimit`.
  - `addLevelLink` refuses links past the limit, and the ramp dig refuses
    first (counted in `dig_ramp_refused_link_slots`).
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
build; the dirty buffers keep their existing reserve contract. The claim is
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
- [ ] Manual (display, procedural demo): dig a ramp at a non-border cell on
      level 1. NPCs on level 1 path up it within a second, with no
      save/load or restart.
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

