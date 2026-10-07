## Slice 65B: Deferred Nav Rebuild On The Background Lane

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 51](slice-51.md), [Slice 65A](slice-65a.md), [Slice 64E](slice-64e.md), [Slice 49](slice-49.md), [Slice 64B](slice-64b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **51** (`BackgroundLane`,
`background_handoff.submitWithHandoff`/`isDue`, and the lane passed through
`UpdateContext.background_lane`) and **65A**, the first CPU-heavy in-game
lane consumer, which needs the lowered-priority gate to hold. Uses **49**'s
determinism stepper and `simulationChecksum()` for the lane-invariance test.
Depends on **64E** (fixed interior link slots and the `nav_links_processed`
cursor, which the back-graph patch and the fence use) and **64B**
(`PathfindingSystem.normalize`, which this slice extends with
`abandonDeferred`). Edits roadmap text and adds checklist bullets in 46, 49,
51. It adds no save section and does not gate 46: saves never persist
pathfinding state (64B B5).

Goal:
- A nav batch classified heavy no longer runs its components, chunk patch,
  and abstract rebuild on the main thread. Heavy means more than
  `nav_full_relabel_level_threshold` affected levels, or at least
  `nav_deferred_patch_min_changed_chunks` changed chunks.
- The main thread does only the input phase, bounded by the edit footprint,
  at the post-commit seam of step `s`.
- The lane copies the frozen front graph into a back graph and applies the
  batch with the existing serial code.
- The back graph is swapped in at the start of step `s + 30`, regardless of
  lane speed or presence.
- The swapped graph is equivalent to what the synchronous path would have
  produced for the same batch.

### Current foundation (do not rebuild)

- **Post-commit nav reaction.** `PathfindingSystem.reactToPostCommitNavEvents`
  (`systems/pathfinding/system.zig:617-673`):
  - It marks events into the system-owned dirty buffers.
    `markNavDirty` / `markNavObstacleRectDirty` / `markNavTileRectDirty` /
    `markNavLevelDirty` are at `:511-572`, and the buffers at `:121-128`
    grow rather than drop.
  - It then calls `applyBufferedNavUpdates` → `applyNavUpdatesImpl`
    (`:447-498`).
  - It emits at most one `nav_region_invalidated` event.
  - Callers: `SimulationPipeline.reactToPostCommitNavEvents`
    (`simulation_pipeline.zig:822-829`), from
    `GameDemoState.applyStructuralCommandsAndPostCommitEvents`
    (`game_demo_state.zig:653-669`). It runs after `pipeline.update`, in the
    `merge_outputs` phase (`:551-555`), outside `stage_order`.
- **`NavGraph.applyNavUpdates`** (`nav_graph.zig:630-761`) does everything
  in place on the queried graph:
  - It counts affected levels.
  - It refreshes static coverage. For whole-level-dirty that is
    `markStaticBodies`, which writes both `static_blocked` and the live mask
    (`nav_grid.zig:105-131`). Cell edits use `refreshStaticCoverageSpan`,
    which writes `static_blocked` only (`nav_grid.zig:150-159`).
  - It remasks changed chunks with `remaskChangedChunks` (`:930-1003`),
    threaded via `nav_remask_tuner`, plus a component re-flood.
  - It builds the dirty set (`buildDirtySet`, `:816-840`: changed chunks
    plus orthogonal neighbors) and patches it (`patchDirtyChunks`,
    `:768-810`, threaded via `nav_patch_tuner`).
  - Past `nav_full_relabel_level_threshold = 8` (`types.zig:142`,
    `PathfindingCapacity` `:457`), it instead runs `buildComponents` over
    every level plus `buildAbstractGraphs` (`:710-718`).
  - A chunk that outgrows its edge window has that window relocated and is
    re-patched on the main thread after the patch barrier
    (`growChunkEdgeWindow`, `stats.edge_windows_grown`; 64E follow-up
    2026-10-06 — the old full-rebuild fallback is gone).
  - Then `rebuildLinkEdges` runs, and `version` bumps only on a full
    relabel.
- **The queried graph.** `PathfindingSystem.graph: NavGraph` (`system.zig:78`)
  is read every step by `pathfinding_update` workers and by steering's
  `statusForWorld` (`:789-852`).
  - It is mutated only by `rebuildStaticNavGridWithWorld` (`:379-427`) and
    `applyNavUpdatesImpl`; a grep of `self.graph` writes in `system.zig`
    confirms this.
  - `static_blocked` is read only by remask (`staticBodyCoversNavCell`,
    `nav_grid.zig:367-380`), never by queries.
- **Cache handling after an update** (`system.zig:479-496`):
  - A version bump runs `clearTransientRequestsRetainingFields` +
    `dropGroupFields`.
  - A whole-level request runs `completed.clear()`.
  - Otherwise `evictCachedPathsCrossingEdits` (`:729-754`, one-cell halo)
    runs.
  - Then `clearRequestStateKeepingCompleted` + `dropGroupFields`.
- **World use.** The graph phase (components, patch, abstract build, link
  edges) reads the world **only** through `world.levelLinks()`:
  - `computePortalGeometry` `:1136-1141`;
  - `buildLevelInit` `:1243`;
  - `patchChunk` `:1344` → `addChunkLinkPortals` `:1485-1492`;
  - `rebuildLinkEdges` `:1257-1297`.

  Links grow at runtime (`dig_controller.digRamp`;
  `WorldSystem.addLevelLink`). The world's load-time `reserveLevelLinks`
  (sized by `GameDemoState` from the authored links plus
  `nav_interior_link_slots_per_chunk` per world chunk) is only the initial
  size: per Slice 64E's link-growth follow-up (landed 2026-10-06),
  `level_links`, `link_edges`, and `link_edge_refs` grow geometrically at the
  dig commit seam (main thread; `SimulationPipeline.ensureLevelLinkRoom` →
  `PathfindingSystem.reserveLinkCapacity`), and only the 8-per-chunk interior
  stride (a layout bound) or a refused nav-memory ceiling refuses. Slice 64E removed `groupLinkCellRuns` and its per-build
  temporary `allocator.alloc`: interior link endpoints live in the
  fixed-stride `chunk_link_cells` table (`chunk_count ×
  nav_interior_link_slots_per_chunk`, sized from the dimensions in
  `computePortalGeometry`), and the full build reserves `link_edges` /
  `link_edge_refs` to `levelLinkLimit()` / `2 × levelLinkLimit()`.
- **Allocation contract.** The graph is allocation-free at steady state.
  Growth happens only in the cold, event-triggered topology blow-up
  (`nav_graph.zig:623-629`). The established `FailingAllocator` pattern swaps
  `system.graph.allocator` (`system.zig:2316`).
- **Equivalence oracle:** `expectGraphsEquivalent` (`nav_graph.zig:1823-1857`)
  compares masks, counts, components, portal membership, and the normalized
  edge multiset.
- **Memory gate:** `NavMemoryBudget.requiredBytes` (`nav_memory.zig:90-153`)
  counts one graph.
- **Allocator thread-safety.** `std.process.Init.gpa` is documented
  "Threadsafe" (`lib/std/process.zig:36-40`). `Engine.init` passes it
  everywhere (`engine.zig:73`). Every production allocating struct gets it.
- **VoidLight shows the defect to avoid.** `PathfinderManager::rebuildGrid`
  (`src/managers/PathfinderManager.cpp:646-726`) rebuilds from the live
  world on a pool task and calls `setGrid` whenever the task finishes.

### Architecture notes

**Placement and ownership**

- `src/game/systems/pathfinding/nav_deferred.zig` (new): `NavDeferredRebuild`,
  `NavDeferredPlan`, `classifyNavBatch`. Owned by `PathfindingSystem`, which
  already owns nav-invalidation classification and the post-commit reaction.
  The state and pipeline only invoke it.
- `PathfindingSystem.nav_deferred: ?*NavDeferredRebuild = null`:
  - It is heap-allocated by the first `rebuildStaticNavGridWithWorld` (load
    time) with `allocator.create`, so a moved `PathfindingSystem` value never
    invalidates a job context.
  - It holds the back `NavGraph`, the plan, the job result, the ticket, and
    `front: *const NavGraph` (`&self.graph`, re-pointed at every submit).
  - It stores the lane pointer captured at submit, so `deinit` can cancel
    the ticket. The lane outlives every state (Slice 51).
- **No new `StageId`, no `PipelineResource`, no `stageContract` change.**
  The nav graph is not a pipeline resource today: `pathfinding_update`
  declares only `path_requests`. It is mutated only outside `stage_order`,
  at the commit seam. This slice adds the second out-of-graph mutation
  point: the swap in `main_thread_inputs`, before `pipeline.update`. That is
  the same place Slice 51's replay capture calls `serviceDue`.

**Constants (fixed, independent of world size)**

```zig
// types.zig
/// Steps between a deferred nav submit at step s and its swap at s + k.
/// 0.5 s at 60 Hz: covers the measured serial full relabel of the production
/// world (gate below) with 2x headroom, so the due-step wait is the exception.
pub const nav_deferred_rebuild_latency_steps: u32 = 30;
/// A non-full-relabel batch whose distinct changed (level, chunk) count reaches
/// this is deferred. 64 chunks = 16,384 cells at the 16-tile default chunk,
/// the largest `nav-update-multichunk` footprint, plus up to 4 border
/// neighbours each to patch. A whole-level request counts that level's chunk
/// count. Below it, the threaded synchronous path stays on the main thread.
pub const default_nav_deferred_patch_min_changed_chunks: usize = 64;
comptime {
    std.debug.assert(nav_deferred_rebuild_latency_steps >= background_handoff.min_background_handoff_latency_steps);
    std.debug.assert(nav_deferred_rebuild_latency_steps <= background_handoff.max_background_handoff_latency_steps);
}
```

- `PathfindingCapacity` gains
  `nav_deferred_patch_min_changed_chunks: usize = default_nav_deferred_patch_min_changed_chunks`.
  It is a caller-supplied runtime knob like `nav_full_relabel_level_threshold`,
  not derived. Tests set it to 1 or 2 on small fixtures through the real
  field.
- The value 64 is a fixed constant. If the bench gate below fails at 64, the
  constant moves to the smallest of {128, 256} that passes, and the chosen
  value is recorded in Status. **Final outcome:** if 256 also fails, the
  constant is set to 256 and kept, and every rung's numbers are recorded in
  Status as an accepted deviation. Batches below 256 changed chunks then
  stay on the synchronous threaded path, which is today's behavior, so the
  fallback never regresses anything; the gate closes. It is never derived
  from a map's chunk count.

**Classification (main thread, at the post-commit seam of step `s`)**

`pub const NavBatchClass = enum { empty, synchronous, deferred };`

`classifyNavBatch(front, world, edits, cell_edits, full_level_ids, capacity) NavBatchClass`:

1. Count distinct affected levels, using the same loops as
   `nav_graph.zig:654-680`. If there are none, return `.empty`. If the count
   exceeds `nav_full_relabel_level_threshold`, return `.deferred`; this is
   the full-relabel shape.
2. For each affected level (≤ the threshold, so 8 or fewer), count distinct
   changed chunks with the epoch-stamp walk from `remaskChangedChunks`
   (`:936-956`). A whole-level request counts `chunkCount()`. Stop early once
   the sum reaches `nav_deferred_patch_min_changed_chunks`, then return
   `.deferred`.
3. Otherwise return `.synchronous`. That is today's path, unchanged.

Work is O(edit spans × affected levels ≤ 8). It writes only the front's
`dirty_stamp` scratch. Classification never runs while a job is in flight,
because of the fence below.

**The fence: the front graph is frozen from submit until the swap**

- `NavDeferredRebuild.state: enum { idle, in_flight }`. While `in_flight`:
  - `reactToPostCommitNavEvents` runs its marking loop (`:618-660`) and
    returns with `stats.deferred_held_batches = 1`. It does not classify,
    apply, or emit an event. The marks stay in the dirty buffers, which
    already grow rather than drop, and are applied at the swap step's seam.
  - **Fence-window reserve (capacity, sized at load).** The fence holds up
    to `k = nav_deferred_rebuild_latency_steps` steps of marks (seams
    `s+1 … s+k`), so the dirty buffers are sized for the window, not for
    one step. 65B scales Slice 64E's `reserveNavDirty` by the fence window:
    64E (landed 2026-10-06) sizes `nav_dirty_edits` to
    `structuralStageEventBound() + 2 × nav_new_links_per_step_max`,
    `nav_dirty_cell_spans` to `2 × structuralStageEventBound()`, and the
    synchronous eviction scratch `nav_changed_spans` to their sum, from
    `SimulationPipeline.reserve`; 65B multiplies the per-step bound by `k`.
    That scratch consumes the same held marks when the swap step's batch
    classifies `.synchronous`. `nav_dirty_levels` is already reserved to
    the nav level count `L` at the nav build (landed by 64E): the deduped
    level set holds every level whatever the window. The reserve is a pure function of the structural-stage event bound,
    the fixed latency, and the loaded world. Marks within it never allocate. A
    step whose marks exceed its per-step share keeps pathfinding's
    grow-rather-than-drop overflow on the main thread (never a drop, never
    on the lane).
  - 64E's link-cursor step in `reactToPostCommitNavEvents` is held too: the
    cursor does not advance, `graph.assignLinkEndpointSlots` is not called
    on the frozen front, new links count in `stats.links_deferred`, and
    `hasPendingNavLinks` stays true. The swap does not touch the cursor;
    step `s + k`'s seam processes `[nav_links_processed, len)` with the
    normal 8-per-step budget.
  - `applyNavUpdatesImpl` begins with
    `if (self.isNavDeferredInFlight()) @panic("NavGraph mutated during a deferred nav rebuild")`.
    That covers the direct `applyNavUpdates` / `applyBufferedNavUpdates`
    APIs used by benches and tests. The check is a cold branch on a cold
    path. Following Slice 50's foreign-thread policy, a loud crash beats a
    silent race in ReleaseFast.
  - `rebuildStaticNavGridWithWorld` first calls `abandonDeferred()`
    (described below), then rebuilds.
- So, by construction, nothing writes any `NavGraph` field of the front
  between submit and swap. The readers are `pathfinding_update` workers, the
  main thread's `statusForWorld` / `keyForWorld` / `markNavObstacleRectDirty`
  span lookup, and the lane's copy. Concurrent reads are safe. TSan covers
  this (Acceptance).

**Submit (main thread, step `s`, `class == .deferred`, state `.idle`)**

`NavDeferredRebuild.prepare(front, data, world, dirty buffers, thread_system)`
fills the plan. Every buffer is a plan field whose capacity is sized from the
loaded world at nav build (`rebuildStaticNavGridWithWorld`, the same
load-time call that ends with `back.ensureCapacityLike(front)`), so `prepare`
never grows a plan buffer on the step path. With `L` = nav level count, `C` =
nav chunks per level (`chunkCount()`), and `ct` = `chunk_tiles`:

| Plan buffer | Capacity reserved at nav build | Why it bounds the plan |
| --- | --- | --- |
| `level_runs` | `L` | one run per affected level |
| `chunks` | `2 × L × C` | per level, changed ≤ `C` and dirty ≤ `C` (stamp-deduped) |
| `overlay_entries` | `L × C` | one entry per changed `(level, chunk)` |
| `overlay_cells` | `L × C × ct²` | one `ct²` stride slot per entry; edge chunks keep the full stride |
| `eviction_spans` | the fence-window `nav_dirty_edits` + `nav_dirty_cell_spans` reserve (see the fence) | one span per held cell edit or cell span |
| `links` | `world.levelLinkLimit()`, re-reserved at the dig commit seam (main thread): 65B adds its plan `links` buffer to `PathfindingSystem.reserveLinkCapacity`, which `SimulationPipeline.ensureLevelLinkRoom` calls before the world's link store grows (64E) | the snapshot is a prefix of the world's link set (64E) |

The only plan growth left is `eviction_spans` after a dirty-buffer overflow
(a window whose marks exceeded the fence-window reserve, which pathfinding
grows rather than drops). In that case `prepare` grows it by the same
overflow on the main thread, never on the lane. A later
`rebuildStaticNavGridWithWorld` re-reserves every plan buffer from the
rebuilt world. `prepare` fills the plan in this order:

1. **Static coverage, on the front's `static_blocked` only** (the cache
   queries never read):
   - Whole-level-dirty level 0 calls the new
     `NavGrid.rebuildStaticCoverage(allocator, data)`. It is the
     `markStaticBodies` loop minus `markBlockedRectSimd`, so the front mask
     is untouched. Both functions share one private loop that resolves each
     static body's bounds through `data.collisionBoundsDenseIndex(entity)`
     (O(1) through the entity slot). The per-call `std.AutoHashMap` that
     `markStaticBodies` builds today (`nav_grid.zig:116-120`) is deleted, and
     `static_blocked` keeps its load-time `cellCount()` length. A level-0
     whole-level batch therefore allocates nothing after load on either the
     synchronous or the deferred path.
   - Each cell span calls the existing `refreshStaticCoverageSpan`.
2. **Changed and dirty chunk runs per affected level**, in ascending level
   order. They use the same rules as `remaskChangedChunks` and
   `buildDirtySet` (front stamps). Dirty runs are skipped when
   `full_relabel`.
   - `level_runs: std.ArrayList(PlanLevelRun)`, where
     `PlanLevelRun = struct { level: u16, full_level: bool, changed_start: u32, changed_len: u32, dirty_start: u32, dirty_len: u32 }`.
   - `chunks: std.ArrayList(u32)`.
3. **Mask overlay.** For each changed `(level, chunk)` in run order, the new
   `NavGrid.deriveChunkMask(chunk, data, world, out: []bool)` writes the
   chunk's cells, chunk-local row-major, into the stride slot
   `overlay_cells[entry * ct*ct ..]`.
   - It uses the same per-cell rule, `navCellBlockedFromSources`
     (`nav_grid.zig:345-365`), that `remaskChunkFromWorld` uses. Edge
     chunks write only their clamped cells.
   - It is threaded through `thread_system.parallelForWithOptions` under
     `nav_remask_tuner`, which is the same per-chunk remask work shape.
     Each range writes only its entries' disjoint stride slots. On the main
     thread, before dispatch, `overlay_entries` is filled and
     `overlay_cells.resize(allocator, overlay_entries.items.len * ct * ct)`
     runs (within the `L × C × ct²` capacity reserved at nav build, so it
     never allocates), and the dispatch's
     `item_count` is that same
     `overlay_entries.items.len`, so the reservation and the dispatch are
     sized from one value. The job opens with
     `std.debug.assert(range.index < range_count)` and
     `std.debug.assert(range.end <= overlay_entries.len and
     overlay_entries.len * ct * ct <= overlay_cells.len)`. The serial
     fallback applies when `thread_system == null`.
   - Layout: `overlay_entries: std.ArrayList(OverlayEntry{ level: u16, chunk: u32 })`
     and `overlay_cells: std.ArrayList(bool)`. This is the striped-arena MAL
     exception (`capacity × stride`, not row-per-index).
4. **Eviction spans with halo.** These use exactly the rule of
   `evictCachedPathsCrossingEdits` / `appendChangedSpanWithHalo`
   (`system.zig:729-754`), stored into `eviction_spans: std.ArrayList(types.ChangedSpan)`.
   It also records `had_full_level` and `full_relabel`.
5. **Link snapshot:** `links: std.ArrayList(LevelLink)` copies
   `world.levelLinks()[0..nav_links_processed]` (64E's processed prefix, not
   the live length), and `plan_link_count = nav_links_processed`. Links past
   the cursor have no interior slot yet; patching with them would break
   incremental == full parity. They are processed by the cursor after the
   swap (fence bullet above).
6. `back.ensureCapacityLike(front)`. On the main thread, this grows any back
   list shorter than the front's current length; it is a no-op at steady
   state.
7. Clear the dirty buffers; they are consumed into the plan.
8. Submit:
   - With a lane, call
     `background_handoff.submitWithHandoff(lane, .{ .run = runNavDeferredJob, .context = self }, s, nav_deferred_rebuild_latency_steps)`.
   - If it returns `BackgroundLaneFull`, apply Slice 51's prescribed
     refusal: run `runNavDeferredJob` inline now and still swap at `s + k`.
     Count it in `stats.deferred_refused_inline`.
   - With no lane (`UpdateContext.background_lane == null`: tests, tools),
     record `due_step = s + k` and run the job inline at the due step, the
     same as Slice 51's thread-less lane.
   - The swap step is therefore identical with no lane, a thread-less lane,
     a fast lane, a slow lane, or a full lane.
9. `state = .in_flight`.

The main-thread cost is the edit footprint: classification, coverage refresh,
overlay derive (the same remask work the synchronous path does), and small
copies. The O(nav memory) copy and the patch/relabel move to the lane.

**Lane job (`runNavDeferredJob`): serial, with no `ThreadSystem` in reach**

Every function it calls takes no `ThreadSystem`, `NavUpdateThreads`,
`DataSystem`, or `WorldSystem` parameter. This is the Slice 50 foreign-thread
rule enforced structurally: the job cannot reach `parallelFor`.

1. `back.copyGraphFrom(front)` returns `error{OutOfMemory}!void`.
   - It deep-copies every `.copied` field (table below) with
     `ensureTotalCapacity` (a no-op after `ensureCapacityLike`) plus
     `@memcpy`. Growth is safe if it ever occurs, because the allocator is
     thread-safe.
   - Scratch fields keep the back's own capacity and its own self-consistent
     `dirty_epoch` / `dirty_stamp`.
2. `back.applyMaskOverlay(&plan)`: per entry, the new
   `NavGrid.applyChunkMask(chunk, cells) isize` writes the chunk's cells and
   returns the delta, then `applyBlockedDelta` (`nav_graph.zig:1026-1037`).
3. `back.applyPlannedBatchSerial(&plan) error{OutOfMemory}!NavUpdateStats`:
   - If `full_relabel`: `buildComponents` on every level,
     `buildAbstractGraphs(links)`, `stats.full_relabel = 1`.
   - Otherwise, per run:
     - `recomputeChunkComponents` over changed chunks, with
       `remask_scratch[0].queue`;
     - `patchChunk(level, links, chunk, &patch_scratch[0])` over dirty
       chunks;
     - `stats.chunks_patched += dirty_len`;
     - a chunk that overflows its edge window is grown and re-patched
       (`growChunkEdgeWindow`, counted at the source in
       `edge_windows_grown_total`), the same as the synchronous serial path.
   - `stats.edge_windows_grown` / `stats.edge_compactions` are reported as
     `total - reported` after every fallible step succeeds, advancing the
     two `_reported` cursors (64E M10), so a failed lane job's growths are
     reported by the next successful apply.
   - Then `rebuildLinkEdges(links)`.
   - On a full relabel, bump `version` (skipping 0) and set
     `stats.version_bumps = 1`.
   - `stats.incremental_rebuilds = 1`.

   This order matches the synchronous path. Levels are independent: all
   overlays are applied, then each level's components and patch, and within
   a level remask comes before patch, the same as `nav_graph.zig:721-732`.
4. Store `result: union(enum) { pending, ok: NavUpdateStats, failed: error{OutOfMemory} }`.
   The job writes only `back` and `result`.

**Graph-phase refactor (`nav_graph.zig`, same change)**

- `computePortalGeometry`, `buildAbstractGraphs`, `buildLevelInit`,
  `patchChunk`, `addChunkLinkPortals`, `rebuildLinkEdges`, and
  `patchDirtyChunks` take `links: []const LevelLink` instead of a
  `world` / `?world`. `LevelLink` comes from `world_system.zig:167`.
- The synchronous callers pass `world.levelLinks()` (or `&.{}` for a null
  world). `patchDirtyChunks` still takes `world` for its threaded remask
  sibling only where `navSpanForTile` needs it.
- No link-sort scratch is added. Slice 64E already removed
  `groupLinkCellRuns`'s temporary `alloc` / `free`: endpoints live in the
  dimension-sized `chunk_link_cells` table, and the full build reserves
  `link_edges` / `link_edge_refs` to the world's current link capacity
  (grown at the dig commit seam per 64E's link-growth follow-up). A full rebuild
  that fits the prior edge-window high-water mark is therefore
  allocation-free on either thread.
- **Copy-role table.** `NavGraphFieldRole = enum { owner, copied, scratch }`,
  with one exhaustive comptime role table per type: `NavGraph`, `NavGrid`,
  `NavLevelGraph`. Each table is checked against
  `@typeInfo(T).@"struct".fields`, so an unclassified new field fails
  `zig build check`.
  - **copied**:
    - `NavGraph`: `cell_size`, `width`, `height`, `chunk_tiles`, `version`,
      `levels`, `level_graphs`, `link_edges`, `link_edge_refs`,
      `chunk_portal_cap`, `chunk_portal_base`, `total_slots`,
      `chunk_edge_cap`, `chunk_edge_base`, `total_edge_slots`,
      `edge_hole_slots` (layout state: `total` includes holes; the
      hole ≤ live assert and compaction read it), `edge_arena_slot_limit`
      (the ceiling the background rebuild's growths must respect),
      `edge_windows_grown_total`, `edge_windows_grown_reported`,
      `edge_compactions_total`, `edge_compactions_reported`,
      `edge_growth_refused_total`, `edge_arena_unslacked_total` (lifetime
      counters and their report cursors, carried across the swap; 64E
      M8/M10), `chunk_link_cells` (64E's
      fixed-stride `[chunk_count * nav_interior_link_slots_per_chunk]`
      table), `chunk_link_count`, `full_build_link_endpoints_unslotted`
      (last-full-build diagnostic, recomputed by the copy's own build).
      (`chunk_link_base` and `edge_slack` no longer exist; 64E deletes
      them.)
    - `NavGrid`: `level`, `cell_size`, `width`, `height`, `chunk_tiles`,
      `blocked_count`, `blocked`, `components`, `static_blocked`.
    - `NavLevelGraph`: every list except `edge_scratch`.
  - **scratch** (capacity and count ensured, contents not copied):
    `build_u32_scratch`, `patch_scratch`, `remask_scratch`,
    `last_patch_batch`, `last_remask_batch`, `chunk_edge_overflow`
    (per-batch flags, sized to chunk count, all false), `dirty_set`,
    `dirty_stamp`, `dirty_epoch`, `changed_chunks`,
    `NavGrid.component_queue`, `NavLevelGraph.edge_scratch`.
  - **owner**: `allocator`.

**Swap (main thread, start of step `s + k`)**

`PathfindingSystem.serviceDeferredNavRebuild(executing_step, lane) !NavUpdateStats`
is called through `SimulationPipeline.serviceDeferredNavRebuild` by
`GameDemoState.update`.
- The call is placed right after `beginStep`, using Slice 51's
  `executing = scope.currentStep() + 1`, and after `capture.serviceDue`.
  The order is fixed: replay capture first, then nav. Their outputs are
  disjoint.
- It returns zero stats when idle or not yet due (`background_handoff.isDue`).
- When due:
  1. Complete the job. With a ticket, `lane.complete(ticket)`, which steals
     if queued and waits if running. Without one, run `runNavDeferredJob`
     inline now.
  2. On `.failed`:
     - Re-mark every plan run's level as whole-level dirty
       (`markNavLevelDirty`), so the "grows rather than drops" contract
       holds.
     - Set `state = .idle`.
     - Return the error. This is exactly where the synchronous path would
       have returned its OOM, `k` steps earlier. The front is unchanged.
  3. Run `std.mem.swap(NavGraph, &self.graph, &deferred.back)`.
     `std.debug.assert(deferred.front == &self.graph)` confirms the system
     has not moved. The old front becomes the next back buffer, so the swap
     itself never allocates.
  4. Run the shared `PathfindingSystem.reactToGraphUpdate(stats,
     affected_levels, eviction_spans, had_full_level)`, the same private
     helper the synchronous branch at `system.zig:479-496` now calls (this
     slice extracts it from that branch, behavior-preserving). It covers
     the version bump (`clearTransientRequestsRetainingFields` +
     group-field drop), the full-level `completed.clear()`, the scoped
     eviction over the plan's `eviction_spans`, and the trailing
     `clearRequestStateKeepingCompleted` + group-field drop. The group-field
     drop is `dropGroupFields` (all levels) before Slice 71B.3 and
     `dropGroupFieldsOnLevels(plan levels)` after it; because both paths
     call one helper, the deferred and synchronous paths always invalidate
     identically for the same batch. Old cached results were computed on
     the frozen front, which differs from the new front only by this batch,
     so scoped eviction is exact.
  5. `state = .idle`, `swap_event_pending = true`. Return the job stats plus
     `deferred_applied = 1`.
- The marks held during the window stay in the dirty buffers. Step `s + k`'s
  own seam classifies them together with that step's events. They become
  either a synchronous apply or the next deferred job (due `s + 2k`). At
  most one job is ever in flight.
- **Event.** `reactToPostCommitNavEvents` at the seam of `s + k` emits the
  single `nav_region_invalidated` (`reason = .static_obstacle_changed`) when
  `swap_event_pending` or its own batch changed the graph, then clears the
  flag.
  `GameDemoState.applyStructuralCommandsAndPostCommitEvents`'s reservation
  (`:660-662`) ORs in `pipeline.navDeferredSwapEventPending()`. Still at
  most one event per step.

**How queries behave in the window (steps `s+1 … s+k-1`)**

- Every reader sees the pre-batch front, unchanged: pathfinding solves,
  steering `statusForWorld`, group fields, and `keyForWorld` (same
  `nav_version`).
- Paths may still route through cells the batch closed. Movement never
  enters them, because `bounds_and_tile_gate` and collision read the world,
  not the nav graph. Agents re-path after the swap evicts or invalidates.
- Cells the batch opened are not used until `s + k`.
- Nav marks from steps inside the window wait at most `k` steps. This
  includes small digs and another heavy batch.
- All of it is a pure function of the step sequence. Lane timing changes
  only whether `complete` steals or waits, never the step or the result.

**Lifetime**

- `abandonDeferred()` is used by `rebuildStaticNavGridWithWorld`,
  `deinit`, and 64B's `PathfindingSystem.normalize` (B5 item (a): normalize
  calls it first, then asserts `swap_event_pending == false`).
  - With a ticket, it calls `lane.cancel(ticket)`. `cancel` waits on a
    running job; Slice 51 makes it return `.cancelled` or `.completed`.
  - It then discards `back` contents and plan, sets `state = .idle`, and
    leaves the dirty buffers alone, because a rebuild re-derives everything.
- `PathfindingSystem.deinit` calls `abandonDeferred` before freeing anything.
  States deinit before the lane (Slice 51).
- `rebuildStaticNavGridWithWorld` ends with `back.ensureCapacityLike(front)`.
  That is cold load-time reservation, so the first heavy batch does not
  allocate a second graph on the main thread.

**Memory and the nav gate**

- `NavMemoryBudget.requiredBytes` adds the back buffer:
  `static_bytes + abstractGraphBytes(...) + build_scratch_bytes`, plus the
  load-reserved plan buffers from the Submit table and the fence-window
  dirty-buffer reserve, so the gate charges exactly what load reserves. The
  plan terms are `overlay_cells` at `L × C × ct²` bytes (≥ `levels × cells`
  when edge chunks are partial), `chunks` at `2 × L × C × 4` bytes, and
  `overlay_entries`, `level_runs`, `links`, and `eviction_spans`.
- The budget is always counted, because deferral is always on. A world
  admitted before this slice can now fail the default 512 MiB gate only if
  it was already above about 45% of it. The production 256×256×32 config is
  far below; record its before and after `requiredBytes` in Status.
- Existing `nav_memory.zig` expected-byte tests are updated in the same
  change.

**Allocator rule**

- The lane may grow back-graph buffers only on the topology blow-up paths:
  a full relabel that re-measures edge windows past the prior high-water
  mark, or an edge-window growth past the edge arena's capacity. This is the
  same exception
  `nav_graph.zig:623-629` grants the synchronous path. It goes through
  `PathfindingSystem.allocator`, which must be thread-safe.
- `PathfindingSystem.init`'s doc comment states this requirement. Production
  passes `std.process.Init.gpa` (thread-safe per `lib/std/process.zig:36-40`).
  Tests use `std.testing.allocator`.
- `FailingAllocator` proofs therefore run the job on a thread-less lane or
  with no lane. `FailingAllocator`'s counters are not atomic.

**Slice 51 contract amendment (this slice owns it): frozen borrow**

The job-input rule ("a job reads only data it owns: an immutable snapshot
copied at submit") gains one clause:

> A job may also read a structure it does not own when its consumer
> **freezes** it.
> - From submit until `complete`/`cancel` returns, no thread writes that
>   structure. Concurrent readers are allowed.
> - The consumer enforces the freeze with a state check at every mutating
>   entry point, which defers or panics, never silently proceeds.
> - The consumer names the frozen structure in the job context's doc comment
>   and covers it with a `-Dsanitize-thread` test.
>
> Jobs still never receive a `ThreadSystem`, renderer, SDL handle, or live
> `DataSystem`/`WorldSystem` pointer. Slices into a world that is under
> construction and not yet live are allowed (65C).

**Determinism, checksum, and saves**

- The nav graph and the deferred state (in-flight job, plan, fence-held dirty
  marks, the held link cursor, `swap_event_pending`) belong to
  `PathfindingSystem`, which Slice 64B classifies `normalized`. None of it is
  hashed or saved.
- Within a session the window is a pure function of the step sequence (see
  "How queries behave in the window").
- **Saves (decision: the saved image is normalized, the live session is
  untouched; 64B B5).** Slice 46's capture saves no `PathfindingSystem`
  state and never calls `normalizeDerivedState` or `abandonDeferred` on the
  live session. So:
  - an in-flight job in the continuing session keeps running and swaps at
    `submit + k` exactly as in a run that never saved (saving is invisible,
    and nothing waits on the lane at save time);
  - the loaded session starts with a fresh `PathfindingSystem` (no job, no
    held marks): the batch's edits are already in the saved world, so the
    load's full build includes them immediately instead of at `submit + k`.
    That is the stated, accepted divergence of a load from the continuing
    session (64B B5); the load equals the continuing session **normalized**
    at the save step, which is the parity oracle;
  - persisting the job would not give parity on its own: `ResultCache`, the
    pending queue, and group fields change simulation results (64B B5
    tests) and are not saved either.
- 64B's `PathfindingSystem.normalize` gains B5 item (a) in this slice: it
  calls `abandonDeferred()` first (lane `cancel`, which waits if the job is
  running), clears the held dirty marks (item (b)), and asserts
  `swap_event_pending == false`, then rebuilds from the world.
- This slice adds no `nav_history` or `nav_deferred` save section, no
  `NavGraph.rebuildFromHistory`, no `capture`/`restoreNavPersistedState`,
  and no `geometry_link_count`/`link_edge_source_count` fields. Slice 64E
  already makes slot geometry independent of the link set.
- Slice 49's "Pipeline controller state in the checksum" text names the
  deferred nav state as part of the `normalized` `pathfinding` field.

**Diagnostics**

- `NavUpdateStats` gains `deferred_submitted`, `deferred_refused_inline`,
  `deferred_held_batches`, and `deferred_applied`. `recordTo` adds the
  `runtime_perf_log` metrics `nav_deferred_submitted`,
  `nav_deferred_refused_inline`, `nav_deferred_held`, and
  `nav_deferred_applied`. They are comptime-gated like the existing nav
  metrics (`types.zig:303-310`).
- `GameDemoState` records the swap stats as `last_nav_swap_stats` next to
  `last_nav_update_stats`.
- Logging:
  - One comptime-gated `logging.game.debug` per submit:
    `"nav deferred rebuild submitted step={} due={} changed_chunks={} full_relabel={}"`.
    Submits are rare and never on the per-step path.
  - One `logging.game.warn` on a job `.failed`.
- Lane wait and steal counts come from Slice 51's `background_jobs_waited`
  and `background_jobs_completed_inline`.

### Checklist

- [ ] Graph-phase refactor in `nav_graph.zig`: functions take `links`
  instead of `world` (no link-sort scratch; 64E already removed the
  temporary `alloc`/`free`), plus the copy-role tables with comptime
  exhaustiveness.
  - Existing nav tests stay green unchanged, including the
    incremental-matches-full-rebuild and edge-cap tests.
  - New tests:
    - `test "a full abstract rebuild that fits its high-water mark is allocation-free"`:
      `FailingAllocator` on `graph.allocator` after one warm rebuild, then a
      second `buildAbstractGraphs(links)`.
    - `test "copyGraphFrom produces an equivalent graph"`:
      `expectGraphsEquivalent` plus equal `version` / `total_edge_slots` /
      `edge_hole_slots` / `edge_arena_slot_limit`, on the 256-px, 4-tile-chunk two-level fixture used
      at `:1904-1913`.
- [ ] `NavGrid.rebuildStaticCoverage`, `deriveChunkMask`, and `applyChunkMask`.
  - `test "deriveChunkMask plus applyChunkMask equals remaskChunkFromWorld"`:
    every chunk of a 2×2-chunk level after edits; equal masks and deltas.
  - `test "rebuildStaticCoverage never writes the blocked mask"`.
- [ ] `nav_deferred.zig`: `classifyNavBatch`, `NavDeferredPlan` (prepare with
  the threaded overlay derive), `NavDeferredRebuild` (state, fence, job,
  result, `abandonDeferred`), and the constants plus the
  `PathfindingCapacity` field. Tests:
  - `test "classifyNavBatch uses fixed thresholds independent of world size"`:
    the same edit footprint on a 16×16-tile and a 64×64-tile world gives the
    same class. Exceeding `nav_full_relabel_level_threshold` levels and
    reaching the chunk threshold each give `.deferred`.
  - `test "deferred overlay derive is identical serial and threaded"`: a
    real 3-worker `ThreadSystem` against `null`.
  - `test "deferred overlay derive is allocation-free after load on a
    multi-worker pool"`: directly after the load-time
    `rebuildStaticNavGridWithWorld`, with no warm `prepare` (so the test
    proves the load-time plan reserve), install
    `std.testing.FailingAllocator` on `system.allocator` and
    `graph.allocator`, then run `prepare` with a real 3-worker
    `ThreadSystem` and `nav_remask_tuner` forced to multi-range
    (`adaptive = false`, `items_per_range = 1`, so every worker writes
    overlay stride slots), then again with `null`. Zero allocations, equal
    `overlay_cells`. This pins that `overlay_cells` is reserved on the main
    thread before dispatch from the same entry count the dispatch uses (an
    undersized threaded reserve would be a data race, not a clean OOM).
- [ ] `PathfindingSystem` wiring:
  - The fence in `reactToPostCommitNavEvents` / `applyNavUpdatesImpl`.
  - The `NavHandoff { lane: ?*BackgroundLane, step: StepIndex }` parameter
    (Slice 49's `StepIndex = u64`) on `reactToPostCommitNavEvents`. Every
    existing test call site passes `.{ .lane = null, .step = N }`.
  - `serviceDeferredNavRebuild`, the swap, the shared
    `reactToGraphUpdate` helper extracted from `system.zig:479-496` and
    called by both paths, the event flag, the 64E link-cursor hold under
    the fence, `rebuildStaticNavGridWithWorld` abandon plus back reserve,
    `deinit`, and the thread-safe allocator doc.
  - 64B B5 item (a): `PathfindingSystem.normalize` calls `abandonDeferred()`
    first and asserts `swap_event_pending == false`.

  Tests in `system.zig`, on small fixtures: 16×16-tile world, `nav_chunk_tiles = 4`,
  2 levels, `nav_deferred_patch_min_changed_chunks = 2`.
  - `test "deferred nav rebuild equals the synchronous update at the due step"`:
    - Twin systems receive the same multi-chunk batch. A defers it and swaps
      at `s + k`; B calls `applyBufferedNavUpdates` synchronously.
    - Expect `expectGraphsEquivalent(A.graph, B.graph)` and equal
      `NavUpdateStats` (incremental case).
    - Repeat with `nav_full_relabel_level_threshold = 1` (full relabel,
      version bumped on both).
    - Repeat with an edge-window overflow (window growth, no version bump).
    - Repeat with a runtime ramp (64E) added before submit and another added
      during the job: the during-job link is held by the fence (cursor
      unchanged, `links_deferred` counted) and processed from step `s + k`'s
      seam; after that seam both systems equal a full rebuild.
    - Both systems hold one group field on each level before the batch; the
      group-field invalidation after the swap equals the synchronous path's
      (same `reactToGraphUpdate` helper; Slice 71B.3 extends this case with a
      field on an unaffected level surviving both paths).
  - `test "front graph and query results are unchanged until the due step"`:
    `statusForWorld` for a fixed key is identical on steps `s+1 … s+k-1`
    and changes at `s + k`.
  - `test "nav marks during an in-flight rebuild are held and applied at the swap step seam"`.
  - `test "a heavy batch during the window becomes the next deferred job at the swap step"`:
    due `s + 2k`; never two jobs in flight.
  - `test "isNavDeferredInFlight reports the fence state"`: false before
    submit, true from submit through `s + k − 1`, false after the swap and
    after `abandonDeferred`. The `@panic` in `applyNavUpdatesImpl` cannot be
    exercised in-process, so it is a review-check item (Acceptance), as with
    Slice 50's foreign-thread panic.
  - `test "normalize discards an in-flight deferred rebuild"` (64B B5 (a)):
    - submit a deferred job at step s and normalize at s+5, with no lane,
      with a thread-less lane, and with a threaded lane;
    - afterwards `state == .idle`, the dirty buffers are empty, and the
      portal and edge arrays are byte-identical to a fresh rebuild;
    - the next 60-step trace equals a freshly initialized pipeline's.
  - `test "rebuilding the nav grid abandons an in-flight deferred rebuild"`:
    threaded lane; a gate job holds the lane; release, then rebuild; no
    leak (`std.testing.allocator`).
  - `test "deinit cancels an in-flight deferred rebuild"`: threaded lane,
    same pattern.
  - `test "lane refusal runs the nav rebuild inline and still swaps at the due step"`:
    32 gate jobs fill the lane; release all gates before cancelling them
    (Slice 51 rule).
  - `test "a failed deferred job surfaces OOM at the due step and re-marks its levels"`:
    no lane; `FailingAllocator` on the back graph's growth during a full
    relabel past high-water.
  - `test "deferred submit, job, and swap are allocation-free after load"`:
    `FailingAllocator` on `system.allocator`, `graph.allocator`, and the back
    graph's allocator, armed directly after the load-time nav build. There
    is no warm cycle: any buffer this path needs that load does not reserve
    moves into the nav-build reserve. `prepare` runs
    with a real 3-worker `ThreadSystem` (overlay derive multi-range), and the
    lane job runs with no lane (inline at the due step), because
    `FailingAllocator`'s counters are not atomic and the lane job is serial
    by construction. Run it twice: once with a tile-edit batch, and once
    with a level-0 whole-level batch (`rebuildStaticCoverage` through the
    shared dense-index loop, with no per-call map).
- [ ] Pipeline and state wiring:
  - `SimulationPipeline.reactToPostCommitNavEvents` gains `lane` and passes
    `scope.currentStep()`.
  - New `SimulationPipeline.serviceDeferredNavRebuild`,
    `isNavDeferredInFlight`, and `navDeferredSwapEventPending`.
  - `GameDemoState.update` calls `serviceDeferredNavRebuild(executing, context.background_lane)`
    after `beginStep` and capture `serviceDue`.
  - `applyStructuralCommandsAndPostCommitEvents` takes the lane, and its
    reservation ORs in the event flag.
  - `last_nav_swap_stats` is recorded.

  Test in `game_demo_state.zig`, reusing Slice 49's
  `initDemoForDeterminismTest` and stepper:
  `test "deferred nav outcome is identical across lane speeds"`.
  - It sets `pipeline.pathfinding.capacity.nav_deferred_patch_min_changed_chunks = 1`
    and scripts a multi-tile dig at step 20.
  - It runs 120 steps on: no lane (`null`), a thread-less lane, a threaded
    fast lane (spin on `completed_on_lane`), and a threaded slow lane (a gate
    job submitted first, released after the due step, so the nav job is
    stolen).
  - The per-step `simulationChecksum()` traces and the swap step are
    identical across all four. The slow lane reports
    `background_jobs_completed_inline >= 1`.
- [ ] `nav_memory.zig`: the back-buffer, plan-buffer, and fence-window
  dirty-reserve terms, updated expected values, and
  `test "the nav gate counts the deferred back buffer"`.
- [ ] Load-time capacities (capacity audit):
  - plan buffers reserved at nav build to the Submit table's formulas;
  - 65B scales `reserveNavDirty` by the fence window (`nav_dirty_edits`,
    `nav_dirty_cell_spans`, and `nav_changed_spans` for `k` steps of the
    structural-stage bound);
  - the nav build reserves `nav_dirty_levels` to `L`: landed by 64E;
  - `markStaticBodies` and `rebuildStaticCoverage` share the dense-index
    loop, with no per-call map.

  Tests in `system.zig` (16×16-tile world, `nav_chunk_tiles = 4`, 2 levels,
  `max_frame_requests = 2`):
  - `test "deferred plan buffers are reserved from the loaded world at nav build"`:
    each plan capacity equals its formula. A 32×32-tile fixture (4× the
    chunks) scales them 4×, while `nav_deferred_patch_min_changed_chunks`
    and `nav_deferred_rebuild_latency_steps` stay unchanged: capacities
    scale with the world, thresholds and budgets do not.
  - `test "fence-held marks across the whole window are allocation-free"`:
    `FailingAllocator` on `system.allocator` and `graph.allocator` right
    after load. Submit a deferred job, then on every seam `s+1 … s+k` mark
    `max_frame_requests` cell edits, `2 × max_frame_requests` cell spans,
    and a whole-level mark on each level. Zero allocations, including at
    `s + k`, where the held batch is classified and applied (synchronously
    or as the next deferred job).
  - `test "whole-level static coverage refresh is allocation-free after load"`:
    `FailingAllocator` right after load. A level-0 whole-level mark through
    the synchronous path (`markStaticBodies`) and through the deferred path
    (`rebuildStaticCoverage`) allocates nothing, and on both paths
    `static_blocked` equals a fresh build's.
- [ ] Bench: new group `nav-update-deferred` in `src/benchmarks/nav_update.zig`,
  registered in `runner.zig`.
  - Items: changed-chunk counts `{64, 128, 256}` on the existing 256-tile
    scattered fixture, plus one full-relabel row on a 12-level 128-tile
    fixture (12 > threshold 8).
  - The `serial-direct` row times the synchronous `applyBufferedNavUpdates`.
    The threaded rows time the main-thread deferred cost: classify, prepare,
    submit on a real threaded lane, and swap.
  - `--details` reports the lane job's own duration and whether the swap
    waited.
- [ ] (added by Slice 64) The lane's back-graph patch/relabel uses 64E's fixed interior link
      slots, `assignLinkEndpointSlots`, and the `nav_links_processed`
      cursor. Links added while a deferred rebuild is in flight are held by
      the fence and processed by the main-thread cursor from step `s + k`'s
      seam (≤ 8 per step), never dropped. 65B's equivalence-to-synchronous
      test includes a runtime ramp added before submit and one added during
      the job.
- [ ] Roadmap cross-edits (same change):
  - Slice 51 "Consumer decision": "Not now: nav large patch …" now reads
    "Slice 65B: deferred nav rebuild".
  - Slice 51 "Job inputs and outputs": add the frozen-borrow clause.
  - Slice 49 "Out of scope … Pipeline controller state": name the deferred
    nav state as part of `PathfindingSystem`, which Slice 64B classifies
    `normalized` (never hashed, never saved).
  - Slice 46 "Post-load rebuild" stays `rebuildStaticNavGridWithWorld`
    (no 65B edit; the loaded pipeline is fresh and has no deferred job).
  - **Slice 46 Checklist addition** (paste verbatim into that slice's
    Checklist):

    ```markdown
    - [ ] (65B) Round-trip trace test, mid-job variant: with `nav_deferred_patch_min_changed_chunks = 1`, dig a multi-tile batch at S−5 and another at S−2 (held by the fence), then save at S with the job in flight. (1) Invisibility: the saving session's per-step `simulationChecksum()` trace for S+1…S+120 and its swap step (S−5+30) equal a run that never saved. (2) Load parity: the reference run (the uninterrupted session with 64B's `normalizeDerivedState` called at S, which abandons the job and rebuilds) and the loaded session have equal traces for S+1…S+120, and neither swaps after S. Run with no lane, a thread-less lane, and a threaded lane.
    ```

  - **Slice 51 Checklist addition** (paste verbatim into that slice's
    Checklist):

    ```markdown
    - [ ] (65B) Job-input rule: add the frozen-borrow clause (Slice 65B "Slice 51 contract amendment") to `docs/architecture.md` Background Lane and the `background_handoff.zig` doc comment.
    ```

- [ ] Docs:
  - `docs/architecture.md` Pathfinding: synchronous versus deferred
    classification, the front/back graphs, the fence, and the swap point.
    Background Lane: the frozen-borrow clause.
  - `docs/simulation-tiers-and-pipeline.md` Determinism Contract: the nav
    window semantics, swap at `s + k` in `main_thread_inputs`, and the event
    at the swap step's seam.
  - `docs/development-workflow.md`: the `nav-update-deferred` group, and
    `background-lane` plus `nav-update-deferred` in the Thread Sanitizer
    group list.

### Acceptance checks

- [ ] `zig build test` passes. Under `zig build test -Dsanitize-thread=true`,
  the lane-speed test, the abandon/deinit tests, and the threaded-lane cases
  report zero races. This proves the frozen front is read concurrently by
  the lane and never written.
- [ ] The equivalence tests pass in all three shapes: incremental, full
  relabel, and edge-window growth. The four-lane checksum traces are equal.
- [ ] The `FailingAllocator` proofs pass for submit, the job, and the swap
  with no warm cycle (armed right after load), for fence-held marks across
  the whole window, and for the whole-level static coverage refresh. The
  plan-buffer capacities equal the load-time formulas and scale with the
  world, while the latency and the changed-chunk threshold stay fixed.
- [ ] `normalize discards an in-flight deferred rebuild` passes on all
  three lane shapes. Slice 46's mid-job trace bullet (invisibility + load
  parity) is present in its checklist; 65B lands before 46 in the merged
  order, so 46's passing trace test is the end-to-end proof when 46 lands.
- [ ] Bench gate in ReleaseFast:
  `zig build -Doptimize=ReleaseFast bench -- --group nav-update-deferred --details`.
  - At 64 changed chunks, the main-thread deferred cost is ≤ 75% of the
    `thread-fixed-auto` synchronous cost. Otherwise move the threshold per
    the constants note and re-run; its final outcome (256 kept, recorded as
    an accepted deviation) also closes this check.
  - The lane job for the full-relabel row and for the 256-chunk row finishes
    in ≤ 250 ms (half the `k` window), with no swap wait recorded.
  - Record every number and the 256×256×32 `requiredBytes` before and after
    in Status.
- [ ] `zig build bench -Dsanitize-thread=true -- --profile quick --group nav-update-deferred`
  is clean.
- [ ] Review check: `applyNavUpdatesImpl` begins with the
  `isNavDeferredInFlight()` `@panic`, and every public `NavGraph`-mutating
  entry point of `PathfindingSystem` either routes through it or defers
  under the fence (`reactToPostCommitNavEvents`) or abandons first
  (`rebuildStaticNavGridWithWorld`, `normalize`).
- [ ] Review grep:
  - No `ThreadSystem`, `NavUpdateThreads`, `DataSystem`, or `WorldSystem`
    appears in the signature of any function reachable from
    `runNavDeferredJob`.
  - No `isDone` appears in `src/game/systems/pathfinding/`; this consumer
    observes the job only at its due step.
- [ ] `zig build verify` passes. Docs updated as listed.

### VoidLight reference

- **Port:**
  - Building a replacement grid off-thread and publishing it whole, as
    `PathfinderManager::rebuildGrid` → `setGrid` does
    (`src/managers/PathfinderManager.cpp:646-726`). ZeroLight swaps whole
    graphs too.
- **Do not port:**
  - Rebuilding from the live world on a worker (`newGrid->rebuildFromWorld()`
    reads `WorldManager` concurrently with gameplay). ZeroLight's job reads
    only the frozen front plus a main-thread overlay and link snapshot.
  - Publishing when the future completes (`m_gridRebuildFutures`,
    `PathfinderManager.hpp:458`), so the frame a path changes depends on
    worker speed. ZeroLight swaps at `submit + 30` and blocks if late.
  - `clearOldestCacheEntries(0.5f)` after a rebuild: a heuristic,
    proportion-based eviction. ZeroLight evicts exactly what the batch
    changed, or invalidates by version.
  - World-scaled worker and batch budgets (`WorkerBudgetManager::getOptimalWorkers(..., gridHeight)`).
    ZeroLight's thresholds are fixed constants.

---

