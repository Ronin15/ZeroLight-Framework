## Slice 64F: Nav Edge Storage Simplification

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: 64E · Before: 65B · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Gated before 65B. 65B's background lane must build on
the chosen edge storage, not on machinery this slice may delete.

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

### Checklist

- [ ] Design pass: the A/B/C comparison with the numbers above; pick one and
  record why.
- [ ] Implement the winner. The existing 64E parity, OOM-sweep, tombstone and
  cached-path tests must keep passing unchanged, or be replaced by equivalents
  that state the same property. Delete tests that only cover removed machinery.
- [ ] 64E M14/M15: implement them if A or C wins; mark them superseded if B
  removes the code they cover.
- [ ] 65B: update its non-fatal failure-state items and copy-role table to the
  chosen storage.
- [ ] Docs: `docs/architecture.md` Pathfinding, and 64E's Gate and M-item text
  where superseded.

### Acceptance checks

- [ ] `zig build verify` passes, and `zig build test -Doptimize=ReleaseFast`
  passes.
- [ ] The benches above stay within max(3%, spread) of the 64E baseline, or a
  regression is justified by the deletion it buys.
