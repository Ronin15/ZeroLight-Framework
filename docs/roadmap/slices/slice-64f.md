## Slice 64F: Nav Edge Storage Simplification

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: 64E · Before: 65B · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: implemented (2026-10-07).** Per-level edge windows, a level repack on
overflow, and the edge arena out of the nav memory gate. All checklist items
below are checked.

### Why

64E's in-place edge-window growth needed four review rounds (M1–M13). Nearly
every finding traced to two design choices, not to the pathfinder:

1. **A shared per-level edge arena with relocation.** A growing chunk moves to
   the arena tail and leaves a hole. That brings hole accounting, the
   hole ≤ live invariant, compaction, start-offset rebasing, logical vs
   physical capacity, and resident holes (M6, M9, part of M8).
2. **A retryable, graceful memory ceiling.** A refused growth must leave a
   queryable graph and retry next step. That brings half-patched failure
   states, the build vs incremental sizing ladder, failed-step stat carry,
   degraded-apply cache clearing, and log rate-limiting (M4, M5, M8, M10–M12).
   The demo treats the error as fatal, so the retry path serves only 65B.

### Decision to make (one design pass, then implement the winner)

Compare these options, sized for the current demo world and a 10k-agent battle
world:

- **A. Keep:** today's arena, ladder and retryable ceiling.
- **B. Per-chunk edge storage:** each chunk owns a contiguous edge block from a
  slab or pool allocator and grows on its own. There are no holes, no
  compaction and no rebasing, and resident memory is the sum of block
  capacities. Slot edges stay contiguous within the block.
- **C. Fatal ceiling:** keep the arena, but make a growth past the ceiling a
  loud fatal platform-limit error, like OOM, with no retry contract.
- **B + C.**

Criteria, all measured: production lines and failure states removed; A* cost
with the extra chunk → block hop (`--group pathfinding`, tuned and serial);
`nav-update-links-dense` and `nav-update-scattered`; resident nav bytes;
allocation count at build; serial == threaded; incremental == full-rebuild
parity. Default is keep (A) unless B or C wins on these numbers. Do not change
budgets, capacities or thresholds for their own sake.

### Decision (2026-10-07)

Neither A, B nor C as written. Two owner decisions replaced the comparison:

1. **Per-level windows, repack on overflow.** Each `NavLevelGraph` owns its
   `chunk_edge_cap` / `chunk_edge_base` / `total_edge_slots`, and its arena is
   allocated exactly (len == capacity). A patch flags every chunk whose edges
   outgrow its window and leaves it with empty adjacency. After the level's
   whole dirty set is patched (serial and threaded alike), one main-thread
   `repackLevelEdges` measures every chunk, keeps each cap whose edges still
   fit, sizes grown ones at `windowCap(edges) = max(edges * 2, 32)` (the same
   function the build uses), allocates the new arena before any layout write,
   copies live edges, and re-patches the flagged chunks. A* reads only
   `portal_edge_start/count` within its level, so layout is pure allocation
   policy and cannot change a result.
2. **The edge arena is runtime-growing data, never refused** (dig/cave-in
   game: no gameplay path may fail because terrain got dense).
   `max_nav_memory_bytes` budgets the reserve-time stores and only estimates
   the arena. The one fixed cap is the u32 edge index: `computePortalGeometry`
   fails the build (`NavWorldTooLarge`) when this extent's worst case (every
   chunk at `windowCap((4·ct + K)²)`) could overflow it; placement and repack
   assert the bound. OOM stays an ordinary error that leaves the old layout
   valid.

Decided from the code:
- The repack runs right after its level's patch (the dirty set is per level),
  which is level order.
- `nav_apply_degraded` (M12) stays: an OOM in a repack leaves flagged chunks at
  empty adjacency and later levels on their old layer until the retry, so
  detours can still be cached.
- `edge_windows_grown` counts per-level windows; `edge_repacks` replaces the
  compaction and hole metrics on the same report-cursor carry (M10).
- The full build stages one level at a time (`NavGraph.build_edge_scratch`)
  and commits each level on its own.

Deleted: `edge_hole_slots`, `edge_arena_slot_limit`,
`NavMemoryBudget.edgeArenaSlotLimit`, `edge_compactions_*`,
`edge_growth_refused_total`, `edge_arena_unslacked_total`,
`compactEdgeArena`, `buildScratchAssumeCapacity`, `relocateChunkEdgeWindow`,
`growChunkEdgeWindow`, `ensureEdgeArenaCapacity`, `edgeArenaLiveSlots`,
`edgeArenaFitsBudget`, `applyEdgeArenaBudget`, `fitArenaCapacityToCeiling`,
`computeEdgeCaps`, the per-step refusal `err`, and 7 tests that covered only
that machinery. `nav_graph.zig` production code is 2,191 → 1,987 lines.

### Checklist

- [x] Decision recorded above (owner-directed instead of the A/B/C bench
  comparison).
- [x] Implemented. The 64E parity, OOM-sweep, tombstone and cached-path tests
  keep passing; the M4, M7 and M10 failure-path tests inject an OOM instead of
  a pinned ceiling. New tests: "a destruction-shaped batch repacks each
  affected level once, serial equals threaded, no refusal" (dense and sparse
  level in one step), "a level repack touches only its own level, and an OOM in
  it leaves the old layout intact", "repeated dig and fill cycles grow windows
  once, then stay allocation-free and equal a full rebuild", and "an edge arena
  past the nav memory gate's estimate builds and grows without refusal".
- [x] 64E M14/M15 marked superseded.
- [x] 65B failure-state items and copy-role table updated.
- [x] Docs: `docs/architecture.md` Pathfinding, 64E status and M items,
  64B, 69A soak bounds, 72 E4.

### Measurements

Dense-vs-sparse fixture (24×24 cells, 8-tile chunks, two levels; one step
carves a lattice over all of level 0 and the middle of level 1): per-level
arenas 2,000 + 788 = 2,788 slots, against 4,000 with shared windows. Resident
arena bytes 54,432 (shared windows, geometric capacity) → 22,304 (−59%).

Demo world config (256×256, 32 levels, 16-tile chunks, fresh build): resident
arena bytes 3,191,296 → 2,098,016 (−34%; length 2,124,800 → 2,098,016). The
per-level cap/base arrays add 64 KB.

Bench (ReleaseFast, 3 interleaved reps vs `20b5d68`, serial-direct medians):

| Group | Before | After |
| --- | --- | --- |
| `nav-update-links-dense` 8 | 33.02 us | 44.25 us (+34%) |
| `nav-update-scattered` 16 / 64 / 256 | 209.67 us / 848.18 us / 3.30 ms | 209.90 us / 834.65 us / 3.30 ms |
| `pathfinding` 512 | 3.41 ms (tuned 564 us) | 3.28 ms (tuned 534 us) |

The links-dense step repacks both levels (each: one exact 66 KB allocation,
a copy of the live edges, rebasing moved chunks' starts), about 5.6 us per
level: the one-level-copy cost the decision accepted. It runs only on a step
that outgrows a window. Scattered and pathfinding are within noise.

### Acceptance checks

- [x] `zig build verify` passes, and `zig build test -Doptimize=ReleaseFast`
  passes.
- [x] The benches above stay within max(3%, spread) of the 64E baseline, or a
  regression is justified by the deletion it buys (links-dense, above).
