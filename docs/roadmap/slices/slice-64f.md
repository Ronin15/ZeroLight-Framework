## Slice 64F: Nav Edge Storage Simplification

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64E](../archive/slice-64e.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: implemented; superseded by [Slice 64G](slice-64g.md).** Its open
follow-ups (cave-in bench record, repack prefix trim, threaded repack) are
dropped: 64G replaces per-level nav storage with chunk-owned storage. Archive
with 64G.

Goal: remove 64E's shared edge arena with relocation and its retryable memory
ceiling, so nav edge storage has no holes, compaction, rebasing, or
gameplay-reachable refusal.

### Current foundation

- Each `NavLevelGraph` owns its edge windows and an exactly sized arena. A
  chunk whose edges outgrow its window is flagged during the patch; after the
  level's dirty set is patched (serial and threaded alike), one main-thread
  `repackLevelEdges` regrows windows and re-patches the flagged chunks. A\*
  reads only a portal's own edge range, so layout never changes a result.
- No refusal: the edge arena grows at runtime and is outside the
  `max_nav_memory_bytes` gate. The one fixed cap is the `u32` edge index,
  checked before any allocation (`NavWorldTooLarge`). OOM leaves the old
  layout valid.
- Interior link capacity per chunk starts at 8 and grows in place
  (`growChunkLinkCapacity`), reserved before any write, so a failed link
  grows nothing; no ramp is refused.
- Cost shape: a window overflow or link growth moves the whole level's slots
  or edges, O(level). That fails the local-change rule
  (`.claude/rules/budgets-capacities.md`) and is why 64G exists.

### Checklist

- [x] Per-level windows and repack on overflow; edge arena out of the memory
      gate; the shared-arena machinery and its tests deleted.
- [x] Tests: a destruction-shaped batch repacks each affected level once,
      serial equals threaded, no refusal; a repack touches only its level and
      OOM leaves the old layout; repeated dig/fill grows once then stays
      allocation-free and equal to a full rebuild; the arena grows past the
      gate's estimate; the `u32` edge-index bound at its boundary.
- [x] Per-level interior link capacity growth (`61d2f6a`); no ramp refusal.
- [x] 64E, 64B, 65B, 69A, 72, and `docs/architecture.md` Pathfinding updated.

### Acceptance checks

- [x] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
- [x] Benches show no regression beyond run-to-run spread except
      `nav-update-links-dense`, whose repack cost is the accepted price of
      deleting the shared arena; numbers are in the landing commits.
