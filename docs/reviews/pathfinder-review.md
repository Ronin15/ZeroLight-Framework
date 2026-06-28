# Pathfinder Module Review — Synthesis Report

## Executive Summary

The `src/game/systems/pathfinding/` module is in strong shape across all three lenses. **Coherency**: the load-bearing cross-file invariants hold — chunk-label encode/decode agreement, disjoint per-chunk threaded write windows, worker stripe/scratch/pending index separation, shared grid dimensions for cross-level cell comparability, and consistent `PathQueryKey`/hash/eq/downsample contracts were all traced and verified. **Cohesion**: the file split is clean and single-responsibility, the public facade (`pathfinding.zig`) is correctly re-export-only, and no external consumer reaches into sub-modules. **Standards**: allocation discipline on hot/per-step paths is meticulous (pre-reserved pools, `appendAssumeCapacity`, generation-stamped scratch), error sets are explicit, and logging is comptime-gated.

No Critical or High issues were found. There are **no crash, UAF, leak, or live state-corruption defects**. The material findings cluster into two buckets: (1) **test gaps** on the riskiest contracts (threaded parity, cache invalidation, the memory gate's anti-wrap math, the hard-fallback bench ceiling), and (2) **duplication-to-unify** drift hazards (chunk geometry/label-stride in two places, open-addressed table machinery in three). Most coherency disagreements are confined to not-yet-reachable branches.

> **Coverage note:** In the multi-agent run, the dedicated reviews of `system.zig` (errored on output) and `solve.zig` (degenerate output) did not complete; both were re-reviewed in a backfill pass and their findings are folded in under "Backfill findings" below. The cross-cutting agents had already read across both files.

---

## Findings (severity-ordered)

### Medium

**M1 — "Threaded" parity test runs inline; parallel patch/remask path is unexercised**
`correctness` · `src/game/systems/pathfinding/nav_graph.zig:2121-2169` (paths at 633-649, 783-797)
The test "incremental nav update threaded chunk patch matches a serial full rebuild" leaves `adaptive=true` on a 5-chunk batch; the adaptive tuner almost certainly runs it inline (the test comment at 2147 concedes this). The parallel patch branch and the parallel remask branch are likely never executed by any test; the threaded remask has no forced-parallel test at all. A future change letting a worker touch a neighbor chunk's cell would race silently and go uncaught.
*Fix*: Force a parallel run (`adaptive=false`, small fixed `items_per_range`), assert `last_patch_batch.ran_inline == false` (and the remask equivalent) before the equivalence check; add an analogous forced-parallel remask parity test.

**M2 — Scoped eviction can miss downsampled plain paths crossing an edited span**
`correctness` · `src/game/systems/pathfinding/caches.zig:378-389`
`crossesSpans`/`evictCrossing` test only the cells physically stored in a slot. A plain path longer than `path_stride` is stride-downsampled (non-adjacent samples). An incremental edit that does not bump `nav_version` is invalidated solely through `evictCrossing`, so an edited cell falling *between* two stored samples returns `false` and the agent follows a path through a now-blocked cell until TTL (~5s) re-solves. Exact for stitched corridors and plain paths ≤ stride; the gap is narrow but real.
*Fix*: Conservatively bound consecutive sample pairs against spans, or treat any downsampled plain slot whose level is in the span set as always-crossing. At minimum, document the approximation and TTL backstop.

**M3 — Invalidation path (`evictCrossing`) and `GroupKeyMap` have no tests**
`correctness` · `src/game/systems/pathfinding/caches.zig:319-333`
The invalidation contract — the focus of this unit — is unverified: no test exercises `evictCrossing`/`crossesSpans`, `GroupKeyMap` back-shift, or `waypointFromStitched`.
*Fix*: Add a test with one path crossing an edited rect and one clear of it; assert the crosser is evicted and the clear one still serves hits. Add a downsampled variant (edited cell between samples) to pin M2's intended behavior, a `GroupKeyMap` back-shift test, and a `waypointFromStitched` hint-recovery test.

**M4 — Memory gate's saturating-clamp (anti-wrap) contract is untested**
`correctness` · `src/game/systems/pathfinding/nav_memory.zig:57-89, 140-152`
`requiredBytes`/`abstractGraphBytes` rely on saturating arithmetic (`*|`/`+|`) so an overflowing term clamps to `maxInt` and the gate rejects rather than wrapping to a small value. This is only exercised indirectly via a 512×512 system-level test. A regression swapping `*|`→`*` would still pass that test yet let a genuinely huge world slip under the ceiling.
*Fix*: Add co-located unit tests directly on `NavMemoryBudget`: one with `width*height` chosen to overflow `usize`, asserting `check()` returns `NavWorldTooLarge` (proves saturation, not wrap); one with a large-but-sparse world that passes.

**M5 — Hard-fallback bench has an untested strict ceiling equality assert**
`correctness` · `src/benchmarks/pathfinding.zig:354, 459`
`runHardFallbackCase` runs with `fallback_budget == item_count`, routing into `serviced == @min(item_count, @min(fallback_budget, default_max_solves_per_frame))` — demanding 100% per-cell fallback at *every* count/side. The fixture's geometry makes abstract detours around the single blocking cell possible, and `fixtureGridSide` doubles per count, so 100% fallback is not provable from the fixture. The only hard-fallback test is the budgeted 8<16 case, which binds on the budget and never reaches the ceiling. If any agent routes abstractly, the `==` aborts the bench in Debug (the default mode).
*Fix*: Relax line 459 from `==` to `<=` (matching the `cold_solve` case at 460), OR add a co-located smoke test across all fallback counts.

**M6 — Bench hardcodes nav chunk size instead of importing `default_nav_chunk_tiles`**
`coherency` · `src/benchmarks/nav_update.zig:48`
`nav_chunk_tiles = 16` is guarded only by a comment. The scattered variant relies on chunk centers landing one dirty cell per distinct chunk; if `types.default_nav_chunk_tiles` changes, the literal silently diverges and the entire scattered scaling curve becomes invalid, with no compile error.
*Fix*: `const nav_chunk_tiles = @import("../game/systems/pathfinding/types.zig").default_nav_chunk_tiles;`

**M7 — Scattered bench variant has no co-located test**
`standards` · `src/benchmarks/nav_update.zig:229, 106`
Both file tests drive only `setFootprint(.multichunk, ...)`; `runScatteredCase` and the scattered branch are untested. The load-bearing invariant (each of `min(cells, total_chunks)` edits lands in a distinct chunk — exactly what M6's coupling can break) is unguarded.
*Fix*: Add a test asserting `setFootprint(.scattered, n)` yields `min(n, total_chunks)` edits each in a distinct chunk (derive chunk index from `edit.x`/`edit.y`, check uniqueness), mirroring the multichunk patch test.

**M8 — Chunk geometry and label-stride encode/decode duplicated across NavGrid and NavGraph**
`cohesion` · `src/game/systems/pathfinding/nav_grid.zig:363-375, 397` and `nav_graph.zig:827-845, 1087`
*(Corroborated by module-cohesion, module-coherency, and the nav_grid unit.)* `chunksX`/`chunkOf(Cell)`/`chunkBounds` and the label-stride formula (`chunk_tiles²+1`) are independent copies that are inverse operations on the *same* encoding (`recomputeChunkComponents` packs `chunk_id * stride`; `levelComponentPortals` unpacks `component / stride`). Correctness of the byte-identical-patch invariant and portal seeding silently depends on the copies agreeing; nothing enforces it. A secondary nit: the two halves use different integer widths (NavGrid `u64`, NavGraph `u32`), coherent only because a build-time assert rejects label overflow.
*Fix*: Make one chunk-geometry source authoritative — a small `(width, chunk_tiles)`-parameterized helper consumed by both, or have NavGraph delegate to `grid(0)`. At minimum, collapse `labelStride`/`chunkLabelStride` to a single definition (one width) so pack/unpack cannot diverge.

**M9 — Open-addressed probe/back-shift machinery duplicated three ways**
`cohesion` · `src/game/systems/pathfinding/caches.zig:31-123, 134-237, 340-361`
*(Corroborated by the caches and module-cohesion units.)* `KeySet` and `GroupKeyMap` are near-identical fixed-capacity linear-probe structures (differing only in a `u16` payload), and the subtle back-shift deletion is written a third time in `ResultCache.removeAt`. A fix to the probe-chain invariant must be mirrored in three places or they diverge.
*Fix*: Extract a generic open-addressed table keyed by `PathQueryKey` (V=void yields the set), with the back-shift compaction parameterized by a slot-move callback (covering `ResultCache`'s path/stitched stripe relocation). Keep the three call sites, one implementation of the tricky logic.

**M10 — Raw `@Vector` reduction hand-rolled in a system instead of via core/simd**
`standards` · `src/game/systems/pathfinding/nav_grid.zig:212-226` (esp. 224)
*(Corroborated by the nav_grid and standards-and-hotpath units.)* `markBlockedRectSimd` counts set lanes with a raw `@Vector` declaration and inline `@reduce(.Add, ...)`. `coding-standards.md` (62-73) makes routing named vector math through `core` unconditional and forbids declaring a raw `@Vector` / hand-rolling a named primitive in a system; `core/simd.zig` has no count-true helper, so this is the divergent-copy case the rule targets (build-time cost does not exempt it). The `Mask4` usage and all-true splat are already correct — only the reduction needs to move.
*Fix*: Add `countTrue(mask)` (or `reduceAddU32`) to `src/core/simd.zig` with scalar-vs-SIMD parity tests, and call it here.

### Low

**L1 — Threaded remask race-freedom depends on an unverified cross-file invariant**
`correctness` · `nav_graph.zig:744-806`
`remaskChunkJob` relies on `remaskChunkFromWorld`/`recomputeChunkComponents` being strictly chunk-local (reads and writes), an invariant living in `nav_grid.zig`. *Fix*: confirm chunk-locality in the nav_grid unit; back the threaded path with the forced-parallel parity test from M1.

**L2 — Out-of-range level: producer clamps to 0, consumer returns unavailable**
`coherency` · `system.zig:1043-1044` vs `nav_graph.zig:1396-1404`
`prepareRequestKeys` clamps an out-of-range `goal_level` to 0; `keyForWorld`/`statusForWorld` return `.unavailable`. A request would be cached under a phantom level-0 key the agent never reads. Not reachable today (steering passes a real world level to both sides). *Fix*: pick one fallback policy and apply it on both sides; add a test feeding an out-of-range level through both paths.

**L3 — `PathQueryKey` omits `start_level` — cross-level key sharing would serve a wrong-level waypoint**
`coherency` · `types.zig:243-248` (consumed at `caches.zig:654-655`, `system.zig:639-668`)
Two agents on different start levels heading to the same goal dedup to one corridor; an uncovered agent falls back to a cell center on the *representative's* floor. Not reachable today (all producers hardcode `start_level = 0`). *Fix*: when per-entity start levels land, include `start_level` in the key for cross-level requests or return `.unavailable` rather than emit an off-floor waypoint; add a parity test.

**L4 — Static-body world-rect geometry duplicated**
`cohesion` · `nav_grid.zig:114-121` vs `515-522`
`markStaticBodies` (using the O(1) `bounds_map`) and `staticBodyWorldRect` (using the O(n) scan) compute identical AABB math inline; offset/size convention can drift. *Fix*: extract `rectFromBoundsIndex(bounds, body, idx)` consumed by both.

**L5 — Half-open-rect epsilon (`0.001`) repeated as a magic literal at five sites**
`coherency` · `nav_grid.zig:132, 204, 302-303, 323-325, 353`
All five must stay identical for remask-vs-rebuild parity; it is also coordinate-magnitude dependent. *Fix*: hoist a named `rect_edge_epsilon` constant in `types.zig`.

**L6 — `refLevel`/`refLocal` carry an undocumented no-sentinel contract that can panic**
`correctness` · `types.zig:146-156, 128, 135`
Decoding `no_ref`/`no_parent` (`maxInt`) panics on `@intCast` to u16; `packRef(0xFFFF, 0xFFFFFFFF)` aliases `no_ref` exactly. All current callers are guarded. *Fix*: add a doc comment stating callers must not decode the sentinels, and note the aliasing.

**L7 — Memory gate per-level estimate mislabels and undercounts blocked storage**
`coherency` · `nav_memory.zig:62`
Comment says "blocked bitset" but storage is two `ArrayList(bool)` columns (byte-per-cell); the term counts one of two. Gate stays conservative overall (no functional break). *Fix*: count `2 *| cell_count` and fix the label, or document the deliberate single-array conservatism.

**L8 — Internal-only helpers exposed as `pub`**
`standards`/`cohesion` · `caches.zig:460-505` (`writeStitched`, `writePath`, `findOrEvictSlot`) and `group_field.zig:101-137, 212-242` (`setCost`, `nextGeneration`, `bucketPush`, `bucketUnlink`, `popNext`, `flowParentIndex`)
*(Two units.)* These are only called within the file (same-file tests can access non-`pub` decls). Widening the surface invites callers to bypass invariants (`put` writing slot/payload/cells together; the bucket-queue mechanics). *Fix*: drop `pub`; keep the genuine API public.

**L9 — Two octile implementations with divergent overflow behavior**
`cohesion` · `types.zig:477-488` (`octileCells`, i64 + saturate) vs `537-543` (`octileXY`, u32 no clamp)
Same formula/units, only one guards overflow; drift hazard if cost units or clamp policy change. *Fix*: have both delegate to one private scalar core.

**L10 — `rebuildLinkEdges`/`countDirtyChunks` diagnostic uses origin-corner, not full span**
`performance` · `nav_graph.zig:1035-1074, 723-735`
`countDirtyChunks` resolves edits via `navCellIndexForTile` (origin only) while real work uses `navSpanForTile` (full rect), so a span-straddling tile can undercount diagnostic `dirty_chunks`. Diagnostic-only (gated behind `runtime_perf_log`). *Fix*: base the diagnostic on `navSpanForTile`, or add a one-line approximation note.

**L11 — Edge-cap fallback warn is Debug-only on a cold event path**
`standards` · `nav_graph.zig:605-606`
`hot_log_enabled` compiles the warn out in release, but `applyNavUpdates` is event-triggered (dig), not per-frame, so a recovered-degradation `warn` is allowed in release. Signal survives via the `edge_cap_fallback` counter. *Fix*: gate behind `logging.enabled(.warn)` instead of `hot_log_enabled`, or document reliance on the counter. Low priority.

**L12 — `patchChunkJob` conflates allocation failure with edge-window overflow**
`correctness` · `nav_graph.zig:215-226`
Any error from `patchChunk` sets `overflow = true`, routing OOM into an edge-slack bump + full rebuild (which allocates more). Defensive and ultimately surfaces, but misreports memory pressure as topology blow-up. *Fix*: optionally propagate a distinct allocation-failure signal. Low priority.

**L13 — Per-step-repeatable warn in `update()` for participant/scratch mismatch**
`standards` · `system.zig:747`
A valid recovered-degradation warn, but it sits in the per-fixed-step path, so a misconfigured release emits a formatted warn every step. Both inputs are step-invariant. *Fix*: validate participant count vs scratch slots once at reserve/rebuild; leave `update()` with just the assert and clamp.

**L14 — `collisionBoundsIndex` is a collision-domain-named generic search in pathfinding types**
`cohesion` · `types.zig:575-580`
A plain `(index, generation)` lookup whose only caller is `nav_grid`'s `staticBodyWorldRect`; its name and DataSystem dependency undercut the "leaf module" docstring claim. *Fix*: relocate to `nav_grid.zig` (its only consumer) or rename to a generic name; likewise reconcile `PhaseTimer`'s platform/sdl dep with the docstring.

**L15 — `tileIndexClamped` asserts when `count == 0`**
`correctness` · `types.zig:231-236`
`max_index = -1` makes `std.math.clamp(idx, 0, -1)` assert. Callers pass `width`/`height` (≥1), so it is an edge case. *Fix*: document the ≥1 invariant or early-return 0 when `count == 0`.

**L16 — Facade re-exports `GridCell` and `PathQueryKey` with no external consumer**
`cohesion` · `pathfinding.zig:27-28`
Neither appears in any facade method signature or external importer. *Fix*: drop both re-exports; re-add only if a consumer needs to name them. (`PathView`/`PathStatus`/`NavGridError`/`PathfindingConfig` are legitimately retained.)

**L17 — `statusForKey` is dead production code reachable only from a test**
`cohesion` · `system.zig:611-617`
Its sole reference is the test at 1298. File-private, so it widens no contract. *Fix*: inline the goal-index derivation into the test and delete `statusForKey`.

**L18 — Scattered bench caps edits at `total_chunks` but reports throughput over full `item_count`**
`correctness` · `nav_update.zig:233, 357`
Defaults max at 256 so safe, but a CLI override >256 edits only 256 cells while reporting cells/sec over the larger count. *Fix*: skip when `item_count > total_chunks`, or accumulate using `fixture.edits.items.len`.

**L19 — Bench comment claims toggle "returns the world to start state" but leaves cells blocked**
`coherency` · `nav_update.zig:15, 264`
The world oscillates open↔blocked and ends each cycle blocked; measurement is still sound (relies on nested ascending footprints). *Fix*: reword to state the oscillation and that bounded dirty state comes from nested ascending counts.

**L20 — Cross-module public API uses `//` instead of `///` doc comments**
`standards` · `group_field.zig:62-95, 139-159, 245-260`
Externally consumed methods documenting lifetime/budgeting/allocation use ordinary `//`. *Fix*: convert declaration-level comments on public `reserve`/`expand`/`sample`/`beginBuild` (and scratch `reserve`/`slotFor`) to `///`.

**L21 — Repeated inline `@import` in test_support signatures**
`standards` · `test_support.zig:50-60`
`WorldTilesetMeta`/`assets`/`manifest` full import paths repeated inline. *Fix*: hoist top-level const aliases.

### Nit

- **N1** · `nav_graph.zig:1036-1074` — `link_edges`/`link_edge_refs` grow by append rather than one-shot reservation at rebuild (link counts tiny; consistent with high-water contract). Optionally `ensureTotalCapacity` at rebuild.
- **N2** · `nav_grid.zig:445-447` — `pub floodComponent` has an unasserted queue-capacity precondition (`>= chunk_tiles²`). Add `std.debug.assert(queue.capacity >= ...)`.
- **N3** · `types.zig:73-82, 99-103` and `pathfinding.zig`/bench comments (`pathfinding.zig:439, 93`; `group_field.zig:191-205`; `nav_memory`) — several constant-rationale comments run essay-length against the terse-comment preference. Trim to load-bearing intent.
- **N4** · `pathfinding.zig:6` (benchmarks) — unused `AdaptiveWorkTuner` import; remove.
- **N5** · `nav_update.zig:40` — stale "interior anchor (40)" comment; actual center anchor is 128. Update or drop.
- **N6** · `system.zig:313-368` — elastic capacity resize is the one per-step-path allocation; **adjudicated sanctioned** (explicit owner, bounded, hysteresis, single-threaded safe point). Optionally assert no realloc outside the resize branch.

---

## Cross-cutting themes

- **Test coverage targets the easy paths, not the dangerous ones.** The four highest-value gaps (M1 threaded parity, M3 cache invalidation, M4 gate anti-wrap, M5/M7 bench fallback + scattered) all share a pattern: the riskiest invariant is "trusted by design argument" while the green test exercises a different, safer branch. Several correctness guarantees rest on disjoint-window / saturation / 100%-fallback arguments that no test actually pins.
- **Duplication-as-drift-hazard is the dominant cohesion smell.** Three independent instances — chunk geometry/label-stride (M8), open-addressed table machinery (M9), and smaller copies (L4 static rect, L5 epsilon ×5, L9 octile) — encode one contract in multiple places kept consistent only by convention or by tests that catch results at rebuild boundaries rather than the divergence itself.
- **Latent cross-file disagreements are real but gated.** L1/L2/L3 are coherency divergences confined to not-yet-reachable branches (out-of-range levels, per-entity start levels, cross-file chunk-locality). They are correctly flagged as future-work landmines, not live bugs.
- **Standards adherence is genuinely high.** Hot/per-step allocation discipline, comptime-gated logging, explicit error sets, SoA, and idiomatic co-located tests all conform; the only recurring standards nits are over-broad `pub` surfaces (L8), one core/simd routing miss (M10), and comment verbosity (N3).

---

## Prioritized action list

0. **M11** — Guard `fallback_indices[1..]` with a `len > 1` check (fold into a shared `prepareSolvePhase` helper used by both `update` and `updateSerial`). The one finding that is a latent panic rather than a test/cohesion gap, and it lives in two places.
1. **M1** — Add forced-parallel patch and remask parity tests (`adaptive=false`, assert `ran_inline == false`). Highest leverage: the threaded byte-identity contract is currently asserted by argument, not test, and a future neighbor-touch race would be invisible.
2. **M5** — Relax the hard-fallback bench assert `==`→`<=` (or add the smoke test). Cheapest fix preventing a latent Debug abort of the default-mode bench.
3. **M3 + M2** — Add `evictCrossing`/`crossesSpans` tests including the downsampled-between-samples case; then close the downsample gap (conservative segment bound or treat downsampled-as-crossing).
4. **M4** — Add direct `NavMemoryBudget` unit tests for the saturating-clamp anti-wrap property (the thing that actually keeps an OOM world out).
5. **M6 + M7** — Import `default_nav_chunk_tiles` in the bench and add the scattered-distinct-chunk test (fix + guard together).
6. **M8** — Collapse chunk geometry + label-stride to a single `(width, chunk_tiles)` source (unify width to u32). Removes the most consequential drift hazard.
7. **M9** — Extract one generic open-addressed table for `KeySet`/`GroupKeyMap`/`ResultCache`.
8. **M10** — Add `countTrue`/`reduceAddU32` to `core/simd.zig` with parity tests; consume in `markBlockedRectSimd`.
9. **Low cluster (quick wins)**: L8 drop `pub` on internal helpers; L16 drop facade re-exports; L17 delete `statusForKey`; L5 hoist `rect_edge_epsilon`; N2 assert flood queue capacity; N4 remove unused import.
10. **Low cluster (latent guards)**: L2/L3 decide and document the out-of-range-level and start_level fallback policies before per-entity levels land; L1 confirm chunk-locality in nav_grid.

---

## Backfill findings

These two units were re-reviewed after their first-pass agents failed to emit usable output. The one promotable result is **M11** (a new correctness finding), now also reflected in the prioritized action list.

**M11 — Empty `fallback_indices[1..]` slice can panic in Debug/ReleaseSafe**
`correctness` · `src/game/systems/pathfinding/system.zig:727-731` (duplicated at `:776-780`)
The verification loop slices `self.fallback_indices.items[1..]` unconditionally. On a zero-length slice this is `items[1..0]`, whose bounds check (start `1` > end `0`) panics in Debug/ReleaseSafe. Reachable when `effectiveSolveLimit` returns `>= 1` while `effectiveFallbackLimit` returns `0` (e.g. a caller sets `config.max_fallback_requests_per_step = 0` with pending work), leaving `fallback_indices` empty. No in-tree caller sets that today and the production default never derives `0`, but it is a representable config and the hazard is duplicated in both the threaded and serial update paths.
*Fix*: Gate the loop on `self.fallback_indices.items.len > 1` (a single-element slice `items[1..1]` is already safe). Best landed once by extracting the duplicated `prepareSolveBuffers`+`prepareFallbackIndices`+strict-increase assert block into a shared `prepareSolvePhase(...)` helper (also resolves the L-tier duplication between `update` and `updateSerial`).

### system.zig backfill

The production code (lines 68–1181) is disciplined and well-tested: `deinit` is symmetric across every owned pool, worker output indexing is consistent (`solved_paths[pending_index]` carries `offset = path_slot * stride` into the worker pools, cross-checked against `solve.zig:542-588`), and the post-solve compaction's `write_index` never exceeds its read index. **No Critical/High issues.** Beyond M11:

- **[Low–Medium · test gap]** Threaded `update()` allocation-freeness is unverified (`:720-768`). The only warmed no-alloc regression (`:1741`) exercises `updateSerial()`, which touches a different, smaller steady-state footprint than the threaded path (per-participant scratch + per-`path_slot` worker pool stripes + adaptive `fallback_tuner` dispatch). Code reads allocation-free — this is a test gap. Add a warmed threaded `update()` under `std.testing.failing_allocator` (swap both `system.allocator` and `system.graph.allocator`, as the `:2454` cross-level test does).
- **[Low · observability]** `recordGroupRequest` (`:892-902`) silently drops a new group goal at capacity — members still fall through to individual A*, so it degrades gracefully, but the drop is untallied. Consider folding into `dropped_requests` or a dedicated stat.
- **[Low · maintainability]** Solve-phase setup duplicated between `update` (`:723-731`) and `updateSerial` (`:773-780`) — the same block that carries M11. Extracting `prepareSolvePhase(...)` removes the duplication and lands the M11 fix once.
- **[Low · standards]** Refines L17: `statusForKey` (`:611-617`) is not dead (the budget-exhaustion test at `:1298` calls it) but is a private production method existing solely to serve a test — the "test-only path in a production API" shape the standards discourage. Build the key and call the real `statusForKeyAndStart`/`statusForWorld` from the test instead.

Dispatch and cohesion lenses came back **clean**: the per-agent-per-frame query path is three O(1) goal-keyed lookups plus a single-digit linear scan over `group_fields` (no per-frame string lookup, hash-map dispatch, or broad dynamic dispatch); the file holds its single orchestrator responsibility and delegates solves/topology/cache-storage to the owning modules with no render/SDL/audio/`DataSystem`-mutation leakage.

_(M11 was asserted from Zig slice semantics, not reproduced by a test run.)_

### solve.zig backfill

**No correctness or allocation defects.** The per-request solver is carefully built: lazy-deletion g-recovery (`f -% h` at `:346`/`:484`) never drops the live-best heap entry; the abstract heuristic is computed from each target's own level so it stays consistent regardless of the reaching edge; `corridor_link[i]` stays aligned with the `slot_parent` chain; and every `appendAssumeCapacity` is capacity-guarded against pre-sized, per-worker-disjoint scratch — no per-solve allocation. One actionable finding:

- **[Medium · test gap]** Pure search primitives have no co-located unit tests (`solve.zig:277` `lowerBoundLinkRef`, `:523` `reconstructLocalPath`). Both are off-by-one-prone and currently covered only incidentally through `system.zig` integration fixtures, against the coding-standards preference for reusable co-located module tests. `lowerBoundLinkRef` is the highest-value target — it gates which links each abstract expansion considers (`abstractCorridor:386-390`); a boundary bug there silently drops/over-includes incident links and surfaces only as flaky long-range/cross-level pathing. *Fix*: add a co-located test over a hand-built sorted `[]LinkEdgeRef` asserting exact lower-bound + incident-loop behavior at, between, and across `(level, cell)` boundaries; add a `reconstructLocalPath` test on a hand-stamped scratch chain.

Residual design notes (not findings): `abstractCorridor` never reopens closed nodes, fine for the consistent octile heuristic except a hypothetical cheap same-level teleport link on the goal level (suboptimal, never invalid; the stitcher refines it) — worth a one-line note if such links are ever added. Plain paths longer than `max_stored_path_cells` are stride-downsampled into non-adjacent waypoints — the explicit owned contract of `downsamplePathInto` (`types.zig:421`), already captured by M2, not a solve.zig defect. Minor style: `var solved` (`:150`) could be `const`; the `i != 0` guard in `stitchCorridor` (`:184`) is redundant since `corridor_link[0]` is always false.
