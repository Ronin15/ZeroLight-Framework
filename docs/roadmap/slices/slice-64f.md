## Slice 64F: Nav Edge Storage Simplification

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64E](slice-64e.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: implemented; superseded by [Slice 64G](slice-64g.md).** Per-level
edge windows with a level repack on overflow, the edge arena out of the nav
memory gate, and per-level interior link capacity growth are landed. Its
remaining follow-ups (cave-in bench record, repack prefix trim, threaded
repack) are dropped: 64G replaces per-level storage with chunk-owned storage.
Archive with 64G.

Goal: remove 64E's shared edge arena with relocation and its retryable memory
ceiling, so nav edge storage has no holes, compaction, rebasing, or
gameplay-reachable refusal.

### Current foundation

- **Per-level edge windows.** Each `NavLevelGraph` owns `chunk_edge_cap` /
  `chunk_edge_base` / `total_edge_slots`; its arena is allocated exactly. A
  patch flags chunks whose edges outgrow their window and leaves them with
  empty adjacency; after the level's dirty set is patched (serial and threaded
  alike), one main-thread `repackLevelEdges` re-measures every chunk, sizes
  grown ones at `windowCap(edges) = max(edges * 2, 32)`, allocates the new arena
  before any layout write, copies live edges, and re-patches the flagged
  chunks. A\* reads only `portal_edge_start/count` within its level, so layout
  cannot change a result.
- **No refusal.** The edge arena is runtime-growing; `max_nav_memory_bytes`
  budgets reserve-time stores and only estimates the arena. The one fixed cap
  is the u32 edge index: `rebuild` fails with `NavWorldTooLarge` before any
  allocation when the extent's worst case could overflow it. OOM leaves the old
  layout valid. `nav_apply_degraded` covers an OOM mid-apply.
- **Interior link capacity.** 64E's fixed 8 interior link slots per chunk are a
  floor; `computePortalGeometry` sizes each chunk at build and relabel, and
  `growChunkLinkCapacity` grows one chunk in place (reserve first, shift later
  slot windows on that level, remap stored slot indices, tombstone the new
  tail). Slot geometry and the interior link-endpoint table are per level.
  Every growth for a link is reserved before any write, so a failed link grows
  nothing and the retry starts clean.
- Known cost shape: a window overflow or link growth costs O(level) (the whole
  level's slots or edges move). That fails the local-change rule
  (`.claude/rules/budgets-capacities.md`) and is why 64G exists.

### Checklist

- [x] Per-level windows and repack on overflow; edge arena out of the memory
  gate; the shared-arena machinery and its seven tests deleted.
- [x] Tests: destruction-shaped batch repacks each affected level once, serial
  equals threaded, no refusal; a level repack touches only its own level and an
  OOM leaves the old layout intact; repeated dig/fill grows windows once then
  stays allocation-free and equal to a full rebuild; an arena past the memory
  gate's estimate builds and grows without refusal; the u32 edge-index bound at
  its boundary.
- [x] Per-level interior link capacity growth (`61d2f6a`); no ramp refusal.
- [x] 64E, 64B, 65B, 69A, 72, and `docs/architecture.md` Pathfinding updated.

### Acceptance checks

- [x] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
- [x] Benches show no regression beyond run-to-run spread except
  `nav-update-links-dense`, whose repack cost is the accepted price of deleting
  the shared arena; numbers are in the landing commits.
