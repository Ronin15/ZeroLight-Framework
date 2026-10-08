## Slice 64E: Incremental Nav Patch Ramp/Link Parity

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status:** Landed; one post-fix manual acceptance check on current code is
open (display-gated), and the edge storage moved to Slice 64F's per-level
repack, which [Slice 64G](slice-64g.md) replaces with chunk-owned storage.

**Goal:** a `LevelLink` added at runtime (today only `DigController.digRamp`)
joins the abstract nav graph in the same step's post-commit nav reaction, on
**both** linked levels, whether its endpoints are perimeter or interior cells.
After any sequence of incremental updates the graph equals a full rebuild over
the same world. Per-step work is bounded by fixed constants, and a step that
adds more links than the budget defers them deterministically. No player-dug
ramp is ever silently inert or refused.

### Current foundation

The fix lives in the synchronous chunk patch, so the main-thread path and
65B's lane rebuild (which runs the same patch) share it. Before it, runtime
interior ramps stayed inert until a full rebuild, the partner level was never
patched, and a ramp dug on an already-walkable cell produced no nav event, so
underground NPCs could never climb a dug ramp. Landed today:

- Runtime links are slotted by one assignment rule shared by full builds and
  the incremental cursor; both linked levels are dirtied.
- Per-chunk interior link capacity starts at the floor
  `nav_interior_link_slots_floor` (8) and grows in place
  (`growChunkLinkCapacity`, `61d2f6a`); no ramp refusal remains.
- Level links grow at the dig commit seam and are never refused.
- Nav dirty buffers are reserved from the structural-stage event bound.
- Edge windows are per level and repacked on overflow (`repackLevelEdges`,
  Slice 64F); 64E's in-place window growth (holes, compaction, tail
  relocation, the sizing ladder, growth refusal) is gone.

Parity infrastructure to reuse: the incremental-vs-full tests in
`nav_graph.zig` (byte-identical portal slots, constant patched-chunk set), the
sorted edge-set and edge-sequence compare helpers, `rebuildLinkEdges`
(O(links), once per batch), and the `nav-update-*` bench groups in
`src/benchmarks/nav_update.zig`.

### Architecture notes

**E1. Interior link slots.**

- Slot geometry is a function of the dimensions plus each chunk's interior
  link capacity, so adding a link never renumbers an existing slot and the
  incremental and full builds share one layout.
- `chunk_link_cells` is a per-chunk run table (`no_cell` = empty);
  `linkTailIndex` is a linear scan of the chunk's run.
- Assignment rule (`assignLinkEndpointSlots(links, first, source)`, `source =
  .full_build | .cursor`): visit links in `world.levelLinks()` order from
  `first`, endpoint a then b. An interior cell already in the chunk's run is
  skipped; otherwise it is appended. A ramp's two endpoints share one cell
  and one slot. Links are append-only, so the cursor yields exactly the table
  a full build computes from index 0.
- `tryLinkPortal` keeps the `interiorLinkSlotExists` guard.

**E2. New links dirty both endpoints on both levels, under a fixed budget.**

- `PathfindingSystem.nav_links_processed` is a cursor into
  `world.levelLinks()`, reset by every full build
  (`rebuildStaticNavGridWithWorld`).
- `nav_new_links_per_step_max = 8` (`types.zig`). In
  `reactToPostCommitNavEvents`, before the buffered apply,
  `markNewNavLinksDirty` takes up to 8 links from the cursor, assigns their
  slots, marks each endpoint dirty on its own level, and advances the cursor
  only after both marks succeed.
- Links past the budget defer in link order to the next step
  (`links_deferred`); deferral depends only on world state and step.
- `eventInvalidatesNavigation` is unchanged; the cursor is a separate
  world-derived trigger, so a non-flipping ramp dig still patches.
  `SimulationPipeline.hasPendingNavLinks` is ORed into `game_demo_state.zig`'s
  extra-event reservation, covering the resulting `nav_region_invalidated`.
- One ramp patches at most 20 chunks (2 dirty cells × 2 levels plus border
  neighbors) plus `rebuildLinkEdges`, independent of world size.
- `PathfindingSystem.nav_link_cursor_pending` carries cursor stats across a
  failed apply until the next successful one reports them.

**E3. Memory gate.** `abstractGraphBytes`' slot term counts per-chunk
perimeter plus interior link slots; `link_count` sizes only the
`link_edges` / `link_edge_refs` term.

**E4. Determinism and cache reaction.** No new event type. The existing
`nav_region_invalidated` drops stale unavailable entries so backing-off NPCs
re-request. Incremental patches keep `nav_version` stable. The steady path
allocates nothing.

**E5. Nav dirty-buffer capacity.**

- `nav_dirty_levels` is reserved to `graph.levelCount()` at full build.
- Every buffered mark comes from one committed `.structural_commit`-stage
  event (`simulation.eventStageOf`, an exhaustive switch beside
  `maxEventsPerStep`) or one new-link endpoint.
  `SimulationPipeline.structuralStageEventBound()` sums `maxEventsPerStep`
  over that stage.
- `SimulationPipeline.reserve` calls `pathfinding.reserveNavDirty(bound)`:
  `nav_dirty_edits` = `bound + 2 * nav_new_links_per_step_max`,
  `nav_dirty_cell_spans` = `2 * bound`, `nav_changed_spans` = their sum, with
  grow-only logical reservations; C3's population growth re-runs `reserve`.
- The grow-rather-than-drop fallback stays, counted
  (`NavUpdateStats.dirty_buffer_grown`, perf `nav_dirty_buffer_grown`) with
  one warn, comparing `.len` to the logical reservation
  (`.claude/rules/memory-performance.md`).

**E6. Level-link growth at the dig commit seam.**

- `DigController` splits into `admit` (every no-op and refusal check, read
  only) and `commit` (preflight and mutate).
  `SimulationPipeline.admitDigAndGrowLinks` runs admit, then
  `ensureLevelLinkRoom` only for an admitted ramp, at the start of
  `dig_world_edit` before `sensory.promote`, so an OOM leaves the step
  retryable.
- `ensureLevelLinkRoom` always grows to `grownLevelLinkLimit(len) = len +
  len/2 + nav_new_links_per_step_max`. `reserveLinkCapacity` grows the nav
  link stores first, then `reserveLevelLinks` raises the world limit, so an
  OOM leaves the world untouched. `max_nav_memory_bytes` is a load-time check
  only.
- On a reserved world, `addLevelLink` past the limit returns
  `error.LevelLinkRoomUnreserved`; unreserved (authoring) worlds still grow.

### Checklist

- [x] E1: `assignLinkEndpointSlots`, run table, linear `linkTailIndex`,
      warn-once-on-cursor, rewritten `tryLinkPortal` comment.
- [x] E1 producer refusal: landed, then deleted by Slice 64F's interior link
      capacity growth (no ramp refusal remains).
- [x] E2: link cursor, per-step budget, both-level dirtying, `links_deferred`
      stats, `hasPendingNavLinks`, reservation wiring.
- [x] E3: memory-gate slot formula and its test.
- [x] Tests:
  - [x] "runtime interior ramp link is slotted and live after the incremental
        patch" (replaces the deferral test).
  - [x] "runtime link patch matches a full rebuild" (interior, perimeter,
        non-flipping, two-step cases).
  - [x] Ninth authored interior endpoint stays unslotted: superseded by
        per-chunk link capacity growth (Slice 64F).
  - [x] "new links beyond the per-step budget defer in link order".
  - [x] "runtime link patch touches a constant chunk set independent of world
        size".
  - [x] "incremental runtime link assignment is allocation-free after warmup"
        (serial and 3-worker).
  - [x] "player-dug ramp is routable by an underground NPC the same step"
        (`simulation_pipeline.zig`).
- [x] Capacity audit: nav dirty buffers reserved from the structural-stage
      event bound (E5), with FailingAllocator proofs serial and threaded.
- [x] Level links grow at the dig commit seam (E6);
      `error.LevelLinkLimitReached` deleted; the growth refusal was removed
      by owner decision 2026-10-07.
  - [x] L3: growth only for an admitted dig (`admit` / `commit` split).
  - [x] L4: no in-step growth past a reserved limit
        (`error.LevelLinkRoomUnreserved`).
  - [x] L5: a growth OOM leaves the step retryable (seam runs before
        `sensory.promote`).
- [x] Docs: `architecture.md` and pathfinding docs updated; "deferred until
      full rebuild" wording dropped.
- [x] M14: superseded by Slice 64F (no unslacked relocation).
- [x] M15: superseded by Slice 64F (`edge_arena_unslacked_total` deleted).

### Acceptance checks

- [x] `zig build verify` passes; all E tests pass in Debug and ReleaseFast;
      the deferral test is gone.
- [x] Manual (display, procedural demo): NPCs on level 1 path up a dug
      non-border ramp within a second; confirmed by the owner 2026-10-06.
- [ ] **Post-fix manual check on current code** (display; Debug or
      ReleaseSafe build). The run above predates the edge-window overflow fix
      and interior link capacity growth. Dig several ramps in one open chunk:
      the perf dump shows `edge_windows_grown > 0`, `edge_repacks > 0`, and
      `full_relabel=0`, and NPCs route over the new ramps.
- [x] Edge-window overflow after runtime ramps (found in the 2026-10-06
      manual run): the full-rebuild fallback is gone; overflow is now handled
      by Slice 64F's per-level repack.
  - [x] M1: OOM at any allocation of a growth step retries to a
        full-rebuild-equal graph (serial and threaded sweeps).
  - [x] M2: edge sequence order, A* results, and serial == threaded layouts
        match a full rebuild.
  - [x] M3: hole metric, compaction, and edge-arena gate: deleted by Slice
        64F.
  - [x] E4: a cached path outside the dirty batch survives a window growth.
  - [x] M4: a failed patch still patches the whole dirty set; no edge targets
        a tombstone.
  - [x] M5, M6, M8, M9, M11: superseded by Slice 64F (no arena gate,
        ladder, or growth refusal).
  - [x] M7: link-cursor stats survive a failed apply.
  - [x] M10: a failed step's growths (and `edge_repacks`) are reported by the
        next success.
  - [x] M12: a degraded apply drops the completed cache.
  - [x] M13: tombstone oracle in the OOM sweeps, serial and threaded.
  - [x] Docs: `slice-64b.md`, `slice-69a.md`, `slice-72.md`, `architecture.md`.
- [x] Capacity audit: the dirty-buffer FailingAllocator test passes serial and
      threaded; no bench regression.
- [x] Bench gate: `nav-update-links` added (8-link batch 1.06× the
      scattered-16 mean, gate ≤ 2×); `nav-update-scattered`,
      `nav-update-multichunk`, and `pathfinding` within max(3%, noise).
