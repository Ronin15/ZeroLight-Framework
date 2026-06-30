# MAL Commits Review

**Commits:** 9466ee2, 99284c3  
**Range:** 20331eb..99284c3  
**Date:** 2026-06-29  
**Reviewer:** zig-review-specialist (orchestrated)

## Findings

### Medium — `coding-standards.md` omits the hot-path fast-append pattern
- **File:** docs/coding-standards.md:81
- **Behavior:** The MAL section tells agents to gather with `rows.appendAssumeCapacity(row)`, but every hot gather path in commit 99284c3 uses `addOneAssumeCapacity()` + `row_slice.len = rows.len` + `row_slice.set(index, row)` (`appendProxyRow`, `appendIntentRow`, `appendAiGatherRow`, `appendMalRow`).
- **Why it matters:** `MAL.appendAssumeCapacity` internally hits `set()`/`slice()` per row and caused ~45% Debug regressions before the cleanup commit. Future contributors following the doc literally will reintroduce the regression.
- **Fix direction:** Add a mandatory bullet for hot gather loops documenting the fast-append helper pattern; reserve `appendAssumeCapacity` for cold emit/setup paths (particles, world build).

### Medium — Second-commit MAL surfaces lack column-compactness tests
- **File:** src/game/systems/steering.zig:761
- **Behavior:** Commit 99284c3 migrated steering snapshots, AI gather rows, world chunk/layer/sparse rows, and pathfinding scratch slots to MAL, but only collision proxies gained an explicit post-migration column-alignment contract test (`expectProxyColumnsAligned`). Particle and `DataSystem` stores already had compactness/alignment tests from commit 9466ee2.
- **Why it matters:** MAL correctness bugs (stale `row_slice.len`, mis-synced columns after `swapRemove`) are easiest to catch with narrow alignment/compactness tests. Steering and AI are hot parallel paths; a len/slice bug would surface as subtle gameplay drift rather than a clean crash.
- **Fix direction:** Add small tests mirroring `particle.zig`'s `expectParticleColumnsAligned` for at least one steering snapshot (`agent_snapshot_rows` after gather) and one AI gather pass; optional for cold `world_system` build paths.

### Low — `data_system` cold accessors call `rows.items(.field)` directly
- **File:** src/game/data_system.zig:1804
- **Behavior:** `tierAt` and `directionAt` use `self.rows.items(.tier)[index]` / `self.rows.items(.direction)[index]` instead of caching a slice once.
- **Why it matters:** Violates the letter of the new MAL hot-path rule, though these are single-index cold accessors with negligible cost.
- **Fix direction:** Either cache `const s = self.rows.slice()` in each helper or add a one-line comment that these are intentional cold-path exceptions.

### Low — `particle.emit` still uses `MAL.appendAssumeCapacity`
- **File:** src/game/systems/particle.zig:314
- **Behavior:** Emission uses `self.rows.appendAssumeCapacity(spawnToRow(spawn))` while gather-heavy systems use the fast-append helper.
- **Why it matters:** No measured regression — emit is cold and bounded — but the inconsistency may confuse readers about which pattern applies where.
- **Fix direction:** Leave as-is for cold emit, or switch to the fast-append helper for uniformity; document the cold/hot split in `coding-standards.md`.

### Low — Commit message typo
- **File:** git commit 9466ee2
- **Behavior:** Subject reads "Zig Mulit-Array Lists refactor".
- **Why it matters:** Cosmetic only; makes `git log` search harder.
- **Fix direction:** Amend on next touch if rewriting history is acceptable; otherwise ignore.

## Open Questions

None that block merge. The intentional non-migrations (collision thread range slots, pathfinding `ResultCache` hot/cold split, spatial hash `cell_entries`/`cell_ranges`) are consistent with the new `coding-standards.md` guidance.

## Summary

The two-commit MAL migration is **correct and well-structured**. Commit 9466ee2 cleanly consolidates `DataSystem` and `ParticleSystem` into MAL with existing compactness/alignment tests and a correct `movement.zig` slice-type fix (`HotI32Slice` drops an invalid 64-byte alignment requirement on MAL columns). Commit 99284c3 extends MAL to hot gather/scratch buffers with the right performance patterns: cached column slices in pathfinding scratch (`refreshSlotColumns`/`refreshCellColumns` on `reserve` only), `sliceConst()` before proxy sort comparisons, and fast-append helpers in collision, collision-response, AI, and steering.

`zig build verify` passes (check + test + shader compile + atlas lint). No High-severity correctness, lifetime, or boundary violations found. Residual risk is documentation drift (fast-append pattern undocumented) and thinner test coverage on steering/AI MAL gather buffers compared to particle/collision/data_system. Debug bench may show ~10% collision-response overhead from MAL safety checks; ReleaseFast benchmarks showed improvement, not regression.

**Issue counts:** 0 High, 2 Medium, 3 Low