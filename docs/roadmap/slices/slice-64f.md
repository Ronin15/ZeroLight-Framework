## Slice 64F: Nav Edge Storage Simplification

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: 64E · Before: 65B · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: implemented (2026-10-07).** Per-level edge windows, a level repack on
overflow, and the edge arena out of the nav memory gate. The checklist is
done; three small review follow-ups stay open below (a bench record, a cheap
repack trim, and a threaded repack gated on a soak trigger).

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
   the arena. The one fixed cap is the u32 edge index: `rebuild` fails
   (`NavWorldTooLarge`, next to the memory gate and before any allocation) when
   this extent's worst case (every chunk at `windowCap((4·ct + K)²)`) could
   overflow it; placement and repack assert the bound. For one chunk the bound
   falls between ct = 11,583 and 11,584 (tested). OOM stays an ordinary error that leaves the old layout
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

Cave-in (`nav-update-cave-in`, 1024×1024 tiles, 32 levels, 16-tile chunks, a
4×4-chunk lattice carved on 3 levels in one step, every caved level repacks):
exploratory ReleaseFast serial-direct run (1 warmup, 5 iterations, 1 rep)
1.99 ms per step: a scaling stress test on one rare growth step, not a frame-budget target (see the gated follow-up below). The per-iteration full
rebuild that resets the windows costs ~50 s at this size, so one serial case
took ~6 min.

### Interior link capacity growth (2026-10-07)

The last ramp refusal is gone: 64E's fixed 8 interior link slots per chunk are
now a floor. `computePortalGeometry` sizes each chunk's capacity (floor, else
the next power of two of its distinct interior endpoint cells) at every full
build and relabel. A cursor endpoint past it grows that one chunk in place
(`growChunkLinkCapacity`, main thread, before the patch): reserve the slot
arrays and patch scratch first (an OOM keeps the layout and the cursor), shift
later chunks' slot windows on that level (see per-level geometry below), remap stored slot indices (edge
targets, `cell_to_portal`, `portal_order`, label starts), and tombstone the new
tail; the cursor's dirty mark patches the chunk that step. No relabel and no
`nav_version` bump: slot ids are never kept across steps (caches hold cells).

Bench (ReleaseFast, serial-direct, vs `40064d5`):

| Group | Before | After |
| --- | --- | --- |
| `nav-update-links` 1 / 8 | 26.53 us / 207.21 us | 26.85 us / 199.72 us |
| `nav-update-links-dense` 8 | 45.66 us | 43.31 us |
| `pathfinding` 512 (tuned) | 3.39 ms (472 us) | 3.38 ms (464 us) |
| `nav-update-links-capacity` 1, 3 reps (relabel at `4ffbaf7` → in-place growth) | 5.20 / 5.10 / 5.22 ms | 95.4 / 96.8 / 95.5 us |

The capacity step on the 256×256-tile, 2-level bench world (256 chunks per
level) now shifts and remaps both levels' slots (O(slots + edges)) and patches
the grown chunk, instead of relabeling the whole graph (−98%).
It runs once per doubling of one chunk's distinct interior endpoints (at the
9th, 17th, 33rd, ...). Same reps, before → after: `nav-update-links` 1 / 8
26.4 / 208.0 us → 26.1 / 200.6 us, `-dense` 8 43.4 → 42.6 us, `pathfinding`
512 3.39 ms → 3.27 ms (serial-direct medians; within noise).

**Per-level slot geometry.** `chunk_portal_cap` / `chunk_portal_base` /
`total_slots` and the interior link-endpoint table live on `NavLevelGraph`,
sized per level from that level's own endpoints, so a growth shifts only the
levels the new link touches (was: all levels, ~1.1 ms on the 32-level demo).
Slot ids stay level-local (`packRef`). An OOM keeps the failing level's layout
and the cursor; a level the same link already grew stays grown (retry skips
it). Bench (ReleaseFast, 3 interleaved reps vs `8271ae5`, serial-direct;
the 2-level bench world grows both levels either way, so this is a no-regression
check): `nav-update-links-capacity` 1 96.3 / 95.2 / 99.8 → 99.5 / 96.8 / 96.2 us,
`nav-update-links` 8 ~208 → ~200 us, `-dense` 8 ~42.7 → ~44 us, `pathfinding`
512 ~3.3 → ~3.4 ms (noise). Demo memory (256 chunks × 32 levels, computed): a
fresh build carries per-level link tables and cap/base/count arrays,
+~350 KB; each growth no longer adds its slots (32 B each) to the 30 unlinked
levels, saving 7.7 KB at 8 → 16 and 15 KB at 16 → 32.

### Review follow-ups (open)

- [ ] **Cave-in bench, finished measurement.** Run `nav-update-cave-in` and
  `nav-update-cave-in-warm` (ReleaseFast, 3 interleaved reps, serial-direct and
  the tuned threaded case; `--iterations 10 --warmup 1` is enough given the
  rebuild cost). Record per-step time, and per-level repack time as
  (cold − warm) / 3, in Measurements above.
- [ ] **Cut redundant repack work.** In `repackLevelEdges`, start the copy and
  rebase at the first chunk whose base moves (the prefix before the first grown
  window keeps its bases: copy it with one `@memcpy` and skip its start rebase).
  Measure step 1 cheaply for that prefix too. Keep allocate-before-mutate.
  Tests: the existing repack, OOM-sweep and parity tests keep passing; add a case
  where the first grown chunk is not chunk 0 and assert the result equals a full
  rebuild.
- [ ] **Threaded level repack: gated on a real trigger.** A repack runs only
  on a step where a chunk's window overflows, and it touches only the levels
  that step changed, a handful at most. It does not scale with population. The
  1024² / 32-level cave-in bench, at about 2 ms for 3 levels on one rare step,
  is a scaling stress test, not a frame-budget target. Thread it, with serial
  and threaded paths across levels, allocate-before-mutate on the main thread,
  and serial == threaded plus OOM tests, only if the demo-scale soak (Slice
  69A) shows repack steps above 1 ms or several per second.
### Acceptance checks

- [x] `zig build verify` passes, and `zig build test -Doptimize=ReleaseFast`
  passes.
- [x] The benches above stay within max(3%, spread) of the 64E baseline, or a
  regression is justified by the deletion it buys (links-dense, above).
