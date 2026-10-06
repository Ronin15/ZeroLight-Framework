> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none (batch order is internal, see the batch table; Batch F lands after the [Slice 64E](slice-64e.md) nav dirty-buffer capacity item, which needs B1) · Track: [VoidLight port](../tracks/voidlight-port.md)

## Slice 72: Live Capacity Sizing Pass

**Status: in progress — Batches A (A1–A4), B (B1) and C (C1–C6) landed; Batch C is complete (C6, contact streams to the pair bound, landed 2026-10-06). The Batch A review follow-ups, the Batch B/C final-review follow-ups, the C5 review follow-up and the C6 review follow-up also landed (recorded below); K6 landed with its owners' items (64E, 71B.1, 68A note); Batch F is unblocked (64E's nav dirty-buffer item landed 2026-10-06); Batches M, D–J and K1–K5 not started.** No gate. Each batch lands and is benchmarked on its own, in batch-table order. An item is checked off only together with its tests and its bench record. The work listed under "Owned by other slices" is not part of this slice's completion. This slice only lands the cross-edits those owners need.

**Batch B + C bench record (2026-10-06).** `zig build -Doptimize=ReleaseFast bench -- --group <name>`, 5 interleaved before/after repetitions (odd reps before first, even reps after first). Before = `0e6a74e` (the commit preceding B1), after = B1–C4 together, both built from exported trees. Medians of each case's mean; run spread = the larger of the before/after (max − min) / median. Groups: the union of the B and C gates (`perception`, `ai-affect`, `collision`, `collision-sparse`, `steering`, `scope`, `spatial_index`, `ai`, `ai-memory`, `movement`), every case at every item count (240 cases) gated against max(3%, spread). The table lists the serial baseline and the production `thread-adaptive-tuned-range` row, all within the gate. **Two forced-scheduler control rows breached formally:** `perception` 4096 `thread-fixed-2` (130.07 us → 198.48 us, +52.6% vs 35.8% spread) and `steering` 512 `thread-fixed-auto` (55.55 us → 72.03 us, +29.7% vs 26.1% spread). Six extra interleaved diagnostic pairs of each show scheduler bimodality on both sides, not a regression: perception before {129, 194, 134, 206, 190, 131} us vs after {194, 130, 132, 131, 130, 138} us; steering before median 66.1 us vs after 64.4 us. Neither code path changes on those benches (perception: one constant of equal value plus a once-only drop-warn branch in the merge; steering: the statics pre-pass runs only on invalidation steps). The `perception` and `ai-affect` fixtures run the systems standalone at their default 512-event cap, so they now print C4's once-per-system drop warn; their workload columns are unchanged. Memory: C1 moves ≈0.28 MiB of first-step collision growth to init at 2053 bodies; C2 drops ≈0.12 MiB of idle obstacle scratch; C3's tier-command slot 0 costs population × 472 B (≈0.92 MiB at 2053, 17 KiB for the shipped 37-body demo; no demo init change otherwise); C4 leaves the shipped `capacity_limit` at 293. The seam's fast path (8 store-length loads, a `deriveCapacity` copy, 5 compares per step) has no isolating bench group; no gated group drives `SimulationPipeline`.

| group | case | items | before (median mean) | after (median mean) | delta | run spread | ok |
|---|---|---|---|---|---|---|---|
| `perception` | serial-direct | 1024 | 61.98 us | 62.29 us | +0.5% | 11.8% | ok |
| `perception` | thread-adaptive-tuned-range | 1024 | 61.90 us | 60.86 us | -1.7% | 3.7% | ok |
| `perception` | serial-direct | 4096 | 284.80 us | 285.50 us | +0.2% | 3.5% | ok |
| `perception` | thread-adaptive-tuned-range | 4096 | 280.43 us | 281.61 us | +0.4% | 54.0% | ok |
| `perception` | serial-direct | 10000 | 711.00 us | 716.11 us | +0.7% | 3.4% | ok |
| `perception` | thread-adaptive-tuned-range | 10000 | 224.78 us | 304.19 us | +35.3% | 195.3% | ok |
| `ai-affect` | serial-direct | 1024 | 10.96 us | 11.38 us | +3.8% | 13.7% | ok |
| `ai-affect` | thread-adaptive-tuned-range | 1024 | 11.07 us | 11.19 us | +1.1% | 8.7% | ok |
| `ai-affect` | serial-direct | 4096 | 45.63 us | 45.66 us | +0.1% | 11.4% | ok |
| `ai-affect` | thread-adaptive-tuned-range | 4096 | 45.26 us | 45.02 us | -0.5% | 2.0% | ok |
| `ai-affect` | serial-direct | 10000 | 111.98 us | 112.67 us | +0.6% | 25.9% | ok |
| `ai-affect` | thread-adaptive-tuned-range | 10000 | 112.31 us | 113.19 us | +0.8% | 4.9% | ok |
| `collision` | serial-direct | 1024 | 21.23 us | 19.44 us | -8.4% | 28.7% | ok |
| `collision` | thread-adaptive-tuned-range | 1024 | 20.71 us | 20.59 us | -0.6% | 16.5% | ok |
| `collision` | serial-direct | 4096 | 123.60 us | 122.77 us | -0.7% | 16.7% | ok |
| `collision` | thread-adaptive-tuned-range | 4096 | 132.54 us | 131.30 us | -0.9% | 2.5% | ok |
| `collision` | serial-direct | 10000 | 790.79 us | 787.48 us | -0.4% | 4.0% | ok |
| `collision` | thread-adaptive-tuned-range | 10000 | 390.54 us | 389.52 us | -0.3% | 30.6% | ok |
| `collision-sparse` | serial-direct | 1024 | 7.35 us | 6.77 us | -7.9% | 17.7% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 1024 | 7.20 us | 7.21 us | +0.1% | 11.7% | ok |
| `collision-sparse` | serial-direct | 4096 | 34.04 us | 34.08 us | +0.1% | 14.8% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 4096 | 36.16 us | 35.51 us | -1.8% | 13.2% | ok |
| `collision-sparse` | serial-direct | 10000 | 188.78 us | 186.79 us | -1.1% | 4.3% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 10000 | 203.06 us | 202.19 us | -0.4% | 18.1% | ok |
| `steering` | serial-direct | 128 | 23.94 us | 24.14 us | +0.8% | 9.9% | ok |
| `steering` | thread-adaptive-tuned-range | 128 | 23.88 us | 24.15 us | +1.1% | 21.4% | ok |
| `steering` | serial-direct | 512 | 101.37 us | 100.71 us | -0.7% | 19.4% | ok |
| `steering` | thread-adaptive-tuned-range | 512 | 100.38 us | 100.95 us | +0.6% | 7.7% | ok |
| `steering` | serial-direct | 1024 | 229.60 us | 245.86 us | +7.1% | 26.2% | ok |
| `steering` | thread-adaptive-tuned-range | 1024 | 235.72 us | 241.04 us | +2.3% | 13.9% | ok |
| `scope` | serial-direct | 1024 | 24.18 us | 23.94 us | -1.0% | 15.0% | ok |
| `scope` | thread-adaptive-tuned-range | 1024 | 25.05 us | 25.09 us | +0.2% | 6.1% | ok |
| `scope` | serial-direct | 4096 | 102.77 us | 102.36 us | -0.4% | 4.7% | ok |
| `scope` | thread-adaptive-tuned-range | 4096 | 106.80 us | 108.79 us | +1.9% | 9.1% | ok |
| `scope` | serial-direct | 10000 | 299.30 us | 293.79 us | -1.8% | 2.7% | ok |
| `scope` | thread-adaptive-tuned-range | 10000 | 302.10 us | 303.98 us | +0.6% | 1.5% | ok |
| `spatial_index` | serial-direct | 1024 | 10.40 us | 10.19 us | -2.0% | 19.8% | ok |
| `spatial_index` | thread-adaptive-tuned-range | 1024 | 11.19 us | 11.47 us | +2.5% | 7.2% | ok |
| `spatial_index` | serial-direct | 4096 | 47.79 us | 48.23 us | +0.9% | 6.3% | ok |
| `spatial_index` | thread-adaptive-tuned-range | 4096 | 53.87 us | 53.65 us | -0.4% | 10.4% | ok |
| `spatial_index` | serial-direct | 10000 | 157.87 us | 156.74 us | -0.7% | 11.0% | ok |
| `spatial_index` | thread-adaptive-tuned-range | 10000 | 167.27 us | 167.30 us | +0.0% | 1.8% | ok |
| `ai` | serial-direct | 1024 | 250.29 us | 231.69 us | -7.4% | 26.6% | ok |
| `ai` | thread-adaptive-tuned-range | 1024 | 220.86 us | 218.47 us | -1.1% | 2.3% | ok |
| `ai` | serial-direct | 4096 | 1.06 ms | 1.06 ms | +0.0% | 1.9% | ok |
| `ai` | thread-adaptive-tuned-range | 4096 | 504.19 us | 536.83 us | +6.5% | 94.2% | ok |
| `ai` | serial-direct | 10000 | 2.63 ms | 2.62 ms | -0.4% | 17.5% | ok |
| `ai` | thread-adaptive-tuned-range | 10000 | 821.89 us | 1.21 ms | +47.2% | 50.6% | ok |
| `ai-memory` | serial-direct | 1024 | 5.78 us | 5.80 us | +0.3% | 23.4% | ok |
| `ai-memory` | thread-adaptive-tuned-range | 1024 | 5.82 us | 5.77 us | -0.9% | 4.1% | ok |
| `ai-memory` | serial-direct | 4096 | 23.48 us | 23.37 us | -0.5% | 3.2% | ok |
| `ai-memory` | thread-adaptive-tuned-range | 4096 | 23.61 us | 23.95 us | +1.4% | 52.2% | ok |
| `ai-memory` | serial-direct | 10000 | 58.60 us | 58.42 us | -0.3% | 24.6% | ok |
| `ai-memory` | thread-adaptive-tuned-range | 10000 | 58.35 us | 58.46 us | +0.2% | 7.6% | ok |
| `movement` | serial-direct | 1024 | 222 ns | 223 ns | +0.5% | 6.8% | ok |
| `movement` | thread-adaptive-tuned-range | 1024 | 425 ns | 412 ns | -3.1% | 28.0% | ok |
| `movement` | serial-direct | 4096 | 864 ns | 866 ns | +0.2% | 1.3% | ok |
| `movement` | thread-adaptive-tuned-range | 4096 | 1.50 us | 1.53 us | +2.0% | 20.9% | ok |
| `movement` | serial-direct | 10000 | 2.06 us | 2.06 us | +0.0% | 13.6% | ok |
| `movement` | thread-adaptive-tuned-range | 10000 | 3.52 us | 3.64 us | +3.4% | 28.8% | ok |

**C3 accepted behavior shift (R2, 2026-10-06).** Moving the pathfinding grow to the population seam makes the pre-E2 goal-keyed cache wipe happen at the commit seam, before the next step's `steering_update` read, where it used to happen inside that step's `pathfinding_update`. The result is a deterministic one-step shift in path availability, only on steps where steering rows outgrow the pathfinding pools. E2's preserving resize removes the wipe. The demo's first-step floor→population growth stays in-stage until E6, as before.

**C3 resize OOM safety (2026-10-06).** `PathfindingSystem.applyDerivedCapacity` now commits `capacity`/`effective_agent_capacity` only after every pool is resized; on a mid-resize OOM the limits fall back to the smaller of the old and new derivations, and `resizeArrayList`/`resizeFilledArrayList` allocate a shrink's replacement before freeing. `ResultCache.reserve` and `ProbeTable.reserve` (`KeySet`, `GroupKeyMap`) used to free before reallocating on their shrink path; the Batch A follow-up below makes them failure-atomic.

**B/C forced-scheduler re-measure (2026-10-06).** The main thread re-ran the two breached control rows at HEAD (`7635978`), 3 runs each: `perception` 4096 `thread-fixed-2` = 129.3–129.9 us and `steering` 512 `thread-fixed-auto` = 54.8–55.9 us. Both match their before medians (130.07 us, 55.55 us), so the B/C breaches are accepted as scheduler noise.

**Batch B/C final-review follow-ups (2026-10-06).** Four commits, each with tests that fail on the pre-fix code (confirmed by temporarily reverting each fix).

- **M1 · C3 steering static snapshot reserved to the responder capacity** (`d292af8`). The seam reserved the obstacle snapshot to the live static count only when the responder capacity grew, so statics committed later within the responder headroom grew it inside `steering_update`. `SimulationPipeline.init` and the seam now reserve it to the tracked `responder_capacity` (statics ⊆ responders: an O(1) bound that also covers dynamic→static mobility flips), so `static_snapshot_grown_total` firing under the pipeline means a missed reserve. Memory: ≈58 B per responder-capacity row (18 B snapshot row + 16 B cell entry + 24 B cell range), ≈0.11 MiB at 2053 responders, about what C2 dropped. Test: after the first growth, 20 statics committed within the responder capacity step under `FailingAllocator` with zero allocations (fails on the old reserve inside `rebuildStaticObstacleSnapshot`).
- **M2 · B1 structural event share sized in events and enforced on its own** (`832d140`). `StructuralCommitPreparer` checked only the shared `capacity_limit`, so an over-headroom create burst borrowed idle perception/affect/action shares and the fatal `EventCapacityExceeded` depended on other producers. The budgeted commit (`applyStructuralCommandsBudgeted` + `SimulationPipeline.structuralCommitBudget`) now rejects an over-share commit before mutation. The share is a fixed per-step count, `structuralEventHeadroom(creates, single-event commands)` with `max_structural_events_per_create` (= 15) derived from `EntityTemplate`; `templateComponentCount` is field-driven. Plan R3 specifies fail-loud, not deferral, so overrun fails. The arm drops the `movement_body_capacity` term: `set_simulation_tier` emits no structural event, and the per-body term made the enforced burst budget scale with population (the per-step-budget rule). The structural-command stream keeps its body + headroom sizing. Demo headroom `structuralEventHeadroom(1, 64)` = 79; the shipped `capacity_limit` re-pins **293 → 255**. Tests: an over-share burst fails identically with other producers idle or saturated, and an in-share burst commits in both; a full-template create costs exactly 15 events.
- **L1 · Growth proof covers the world allocator and a real multi-range path** (`ebeb3c7`). The scenario's "multi-worker" run never left the inline path: every tuner keeps the 37-body workload under `threaded_batch_ns`. A test-local `pinPipelineThreadedProfiles` settles every pipeline tuner on a fixed 2-worker, 16-item profile (3 movement ranges). Per-owner counting allocators, which count allocations plus in-place resizes/remaps, prove the first post-growth step allocates nothing serially. On the pinned multi-worker path it allocates only on `collision`, `scope` and `spatial_index`, the documented slot ≥ 1 warm-up. The falling step then allocates zero with every allocator, `world.allocator` included, failing. The serial-vs-multi-worker determinism test now compares against a real multi-range run.
- **L2 · Demo budget and seam tests on a minimal fixture** (`a3031ab`). "every event producer has a nonzero budget under the demo config" and "demo commit seam grows pipeline capacity" run on `DemoConfigPipelineFixture` (1×1 world, demo headroom, one perception + affect agent) instead of the full demo world. The demo seam moved into `commitStructuralAndReact`, which `applyStructuralCommandsAndPostCommitEvents` calls, so the test still drives the demo's own seam (pinned: 6 bodies → capacity 32, bound 184).
- **Bench** (`zig build -Doptimize=ReleaseFast bench -- --group <name>`, 3 runs at `a3031ab`, median of each case's mean, vs the B + C "after" column above). `steering` serial / tuned: 128 = 24.12 / 24.11 us (−0.1% / −0.2%), 512 = 100.59 / 99.94 us (−0.1% / −1.0%), 1024 = 231.59 / 233.35 us (−5.8% / −3.2%). `scope` serial / tuned: 1024 = 23.81 / 25.06 us (−0.5% / −0.1%), 4096 = 101.84 / 106.53 us (−0.5% / −2.1%), 10000 = 294.31 / 308.53 us (+0.2% / +1.5%). All within max(3%, spread). Neither bench drives `SimulationPipeline` (the steering fixture reserves its obstacles directly), so no change is expected.

**C5 bench and memory record (2026-10-06).** `zig build -Doptimize=ReleaseFast bench -- --group <name>`, 5 interleaved before/after repetitions, medians, before = `1e951ba`, after = the C5 commit, both built from exported trees. `collision`, `collision-sparse`, `scope`, `spatial_index`: every case at every item count (96 cases) within max(3%, spread), 0 breaches, in two independent 5-rep runs. The table lists the serial baseline and the production `thread-adaptive-tuned-range` row. `collision` 1024 `thread-adaptive-tuned-range` read +15%/+21% in the first run's two passes (spread 28–34%); eight isolated interleaved pairs of that case alone read before 22.05–24.79 us, after 19.40–22.43 us (after faster in every pair), so it is noise, and the compaction pass costs no measurable time. Memory at 2053 bodies (R = `maxRangeCount(2053, 16)` = 129), measured from the reserved capacities: scope's tier-command slot 0 (1,453,760 B) and index slot 0 (24,888 B) are gone, and the threaded tier/index slots ≥ 1 that warmed in-stage (≈ another tier list) are never allocated; the tier-command and index lists themselves are the window buffers (unchanged size); one scope tally list +8,256 B. Spatial slot 0 (74,016 B) → staging 49,272 B + tallies 8,256 B. Narrowphase slot 0 (172,536 B) → staging 114,968 B + tallies 8,256 B. Broadphase slot 0 (49,392 B, 3,087 pairs) → 129 bound-reserved slots, 576,896 B (36,056 pairs × 16 B). Net seam reserve for these stores: 1,774,592 B → 765,904 B (−1.0 MB), plus the in-stage slot warm-ups that no longer happen.

| group | case | items | before (median mean) | after (median mean) | delta | run spread | ok |
|---|---|---|---|---|---|---|---|
| `collision` | serial-direct | 1024 | 36.68 us | 18.25 us | -50.2% | 134.6% | ok |
| `collision` | thread-adaptive-tuned-range | 1024 | 21.24 us | 19.76 us | -7.0% | 41.0% | ok |
| `collision` | serial-direct | 4096 | 123.25 us | 116.62 us | -5.4% | 8.4% | ok |
| `collision` | thread-adaptive-tuned-range | 4096 | 128.66 us | 122.95 us | -4.4% | 20.0% | ok |
| `collision` | serial-direct | 10000 | 755.37 us | 745.56 us | -1.3% | 8.9% | ok |
| `collision` | thread-adaptive-tuned-range | 10000 | 418.71 us | 379.46 us | -9.4% | 21.4% | ok |
| `collision-sparse` | serial-direct | 1024 | 10.40 us | 10.12 us | -2.7% | 140.7% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 1024 | 7.19 us | 7.26 us | +1.0% | 45.8% | ok |
| `collision-sparse` | serial-direct | 4096 | 33.97 us | 35.41 us | +4.2% | 56.6% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 4096 | 35.30 us | 35.20 us | -0.3% | 16.5% | ok |
| `collision-sparse` | serial-direct | 10000 | 185.95 us | 183.02 us | -1.6% | 8.3% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 10000 | 224.46 us | 209.79 us | -6.5% | 14.5% | ok |
| `scope` | serial-direct | 1024 | 26.30 us | 33.50 us | +27.4% | 54.9% | ok |
| `scope` | thread-adaptive-tuned-range | 1024 | 24.33 us | 24.43 us | +0.4% | 6.5% | ok |
| `scope` | serial-direct | 4096 | 98.29 us | 99.16 us | +0.9% | 31.8% | ok |
| `scope` | thread-adaptive-tuned-range | 4096 | 105.77 us | 101.58 us | -4.0% | 34.6% | ok |
| `scope` | serial-direct | 10000 | 291.24 us | 289.95 us | -0.4% | 7.3% | ok |
| `scope` | thread-adaptive-tuned-range | 10000 | 291.20 us | 297.11 us | +2.0% | 23.0% | ok |
| `spatial_index` | serial-direct | 1024 | 9.74 us | 10.17 us | +4.4% | 178.9% | ok |
| `spatial_index` | thread-adaptive-tuned-range | 1024 | 11.04 us | 11.12 us | +0.7% | 6.5% | ok |
| `spatial_index` | serial-direct | 4096 | 47.39 us | 46.58 us | -1.7% | 3.8% | ok |
| `spatial_index` | thread-adaptive-tuned-range | 4096 | 52.50 us | 51.84 us | -1.3% | 19.6% | ok |
| `spatial_index` | serial-direct | 10000 | 153.47 us | 153.80 us | +0.2% | 6.9% | ok |
| `spatial_index` | thread-adaptive-tuned-range | 10000 | 165.39 us | 163.88 us | -0.9% | 23.6% | ok |

**C5 review follow-up M1: bench and memory record (2026-10-06).** `78ed7e5` reserves the merged candidates, the narrowphase staging and its tallies to `broadphasePairBound(cap)` (4 pairs per body, the per-range slot density) instead of `estimateBroadphasePairCapacity(cap, cap)` (clamped to 1 pair per body). The hot loops are unchanged; only `reserve` sizes differ. `zig build -Doptimize=ReleaseFast bench -- --group <name>`, 3 runs at `78ed7e5`, medians of each case's mean (run spread = (max − min) / median of the 3 runs), against the C5 "after" column above:

| group | case | items | C5 after | M1 (3-run median) | delta | run spread | ok |
|---|---|---|---|---|---|---|---|
| `collision` | serial-direct | 1024 | 18.25 us | 25.18 us | +38.0% | 85.8% | ok |
| `collision` | thread-adaptive-tuned-range | 1024 | 19.76 us | 24.42 us | +23.6% | 20.0% | noise (interleaved below) |
| `collision` | serial-direct | 4096 | 116.62 us | 127.53 us | +9.4% | 18.4% | ok |
| `collision` | thread-adaptive-tuned-range | 4096 | 122.95 us | 125.94 us | +2.4% | 0.5% | ok |
| `collision` | serial-direct | 10000 | 745.56 us | 771.42 us | +3.5% | 1.0% | noise (interleaved below) |
| `collision` | thread-adaptive-tuned-range | 10000 | 379.46 us | 336.18 us | -11.4% | 20.7% | ok |
| `collision-sparse` | serial-direct | 1024 | 10.12 us | 9.54 us | -5.7% | 80.6% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 1024 | 7.26 us | 7.24 us | -0.3% | 4.0% | ok |
| `collision-sparse` | serial-direct | 4096 | 35.41 us | 33.25 us | -6.1% | 4.4% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 4096 | 35.20 us | 34.60 us | -1.7% | 16.5% | ok |
| `collision-sparse` | serial-direct | 10000 | 183.02 us | 183.79 us | +0.4% | 10.9% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 10000 | 209.79 us | 195.66 us | -6.7% | 5.5% | ok |

The two rows past max(3%, spread) against the cross-session record were re-measured interleaved against `c9496b8` (exported tree, 3 reps): `collision` 1024 tuned 22.56 → 19.52 us (after faster), 10000 serial 768.37 → 773.26 us (+0.6%), 10000 tuned 382.15 → 390.19 us (+2.1%), 4096 serial 125.83 → 116.54 us. The interleaved 4096 tuned row read 126.29 → 143.45 us, so six isolated interleaved pairs of that case alone were run: before median 134.74 us, after 135.84 us (+0.8%). All noise. The `collision` fixture runs 2.5 / 3.6 / 3.8 candidate pairs per body at 1024 / 4096 / 10000, the density M1 covers; before M1 its warmup grew `candidate_pairs` and the staging in-stage. Memory at 2053 bodies, from the reserved capacities: `candidate_pairs` 3,087 pairs (49,392 B) → 12,326 pairs (197,216 B), +147,824 B; staging 2,053 contacts (114,968 B) → 8,212 (459,872 B), +344,904 B; tallies 129 (8,256 B) → 514 (32,896 B), +24,640 B. Net +517,368 B (≈0.49 MiB, ≈252 B per body capacity).

**C6 bench and memory record (2026-10-06).** C6 changes no hot loop: `estimateContactCapacity` returns the pair bound, the contact-dependent reserves move into `SimulationPipeline.reserve`, and the collision system gains one compare per step (`countPairBoundOverflow`). `zig build -Doptimize=ReleaseFast bench -- --group <name>`, 3 interleaved before/after runs (odd runs before first), before = `3dc8fb2` built from an exported tree, medians of each case's mean, run spread = the larger of the before/after (max − min) / median. The table lists the serial baseline and the production `thread-adaptive-tuned-range` row, with the M1 column above for the cross-session record (the response groups have no earlier Slice 72 record):

| group | case | items | M1 record | before | after (C6) | delta vs before | run spread | ok |
|---|---|---|---|---|---|---|---|---|
| `collision` | serial-direct | 1024 | 25.18 us | 24.04 us | 26.12 us | +8.7% | 82.3% | ok |
| `collision` | thread-adaptive-tuned-range | 1024 | 24.42 us | 20.19 us | 22.75 us | +12.7% | 74.0% | ok |
| `collision` | serial-direct | 4096 | 127.53 us | 116.56 us | 139.18 us | +19.4% | 28.6% | noise (interleaved below) |
| `collision` | thread-adaptive-tuned-range | 4096 | 125.94 us | 123.62 us | 123.34 us | -0.2% | 10.7% | ok |
| `collision` | serial-direct | 10000 | 771.42 us | 753.10 us | 756.06 us | +0.4% | 13.1% | ok |
| `collision` | thread-adaptive-tuned-range | 10000 | 336.18 us | 464.28 us | 390.97 us | -15.8% | 26.0% | noise (interleaved below) |
| `collision-sparse` | serial-direct | 1024 | 9.54 us | 10.02 us | 10.33 us | +3.1% | 145.9% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 1024 | 7.24 us | 7.01 us | 7.28 us | +3.9% | 18.4% | ok |
| `collision-sparse` | serial-direct | 4096 | 33.25 us | 33.01 us | 33.11 us | +0.3% | 23.5% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 4096 | 34.60 us | 34.74 us | 36.55 us | +5.2% | 3.4% | noise (interleaved below) |
| `collision-sparse` | serial-direct | 10000 | 183.79 us | 183.80 us | 187.81 us | +2.2% | 2.3% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 10000 | 195.66 us | 223.45 us | 197.66 us | -11.5% | 2.7% | ok |
| `collision-response-mixed` | serial-direct | 1024 | — | 9.56 us | 7.91 us | -17.3% | 73.6% | ok |
| `collision-response-mixed` | serial-direct | 4096 | — | 32.08 us | 31.41 us | -2.1% | 38.7% | ok |
| `collision-response-mixed` | serial-direct | 10000 | — | 75.22 us | 75.06 us | -0.2% | 27.8% | ok |
| `collision-response-solid` | serial-direct | 1024 | — | 8.24 us | 11.97 us | +45.3% | 70.9% | noise (interleaved below) |
| `collision-response-solid` | serial-direct | 4096 | — | 34.87 us | 45.00 us | +29.1% | 80.9% | noise (interleaved below) |
| `collision-response-solid` | serial-direct | 10000 | — | 82.15 us | 105.11 us | +27.9% | 38.2% | noise (interleaved below) |

Re-measured outliers, 6 isolated interleaved pairs each, medians before → after: `collision` 4096 serial 140.73 → 125.15 us (after faster in 4/6); 10000 tuned 381.91 → 343.77 us (after faster in 6/6); the forced-scheduler controls that breached formally, 4096 `thread-fixed-auto` (+17.6%, spread 13.6%) and 10000 `thread-small-range` (+10.1%, spread 8.5%), re-read 161.00 → 176.46 us (bimodal on both sides: before 118–185 us, after 146–190 us) and 453.09 → 451.25 us; `collision-sparse` 4096 tuned 34.80 → 35.62 us (+2.4%, before 33.6–39.8 us, after 34.3–37.9 us). `collision-response-solid` is bimodal per process on both sides (a fast mode of 8.1–8.7 / 33.6–36.4 / 80.8–94.4 us and a slow mode of 13–22 / 48–67 / 109–128 us at 1024 / 4096 / 10000), and the 3-run medians fell in different modes. In the 6 pairs the fast-mode values match (before 8.08–8.47 / 33.64–36.35 / 80.84–88.78 us, after 8.31–8.72 / 33.62–34.29 / 82.21–94.37 us), and 10 more interleaved pairs at 4096 read before median 40.9 us, after 38.4 us. The response system, its bench fixture and `simulation.zig` are unchanged by C6. All noise. Memory at 2053 bodies (the battle-scale demo's init reserve), from the reserved capacities: `frame.contacts` values 3,081 contacts (172,536 B) → 12,320 (689,920 B), +517,384 B; `frame.collision_triggers` values 3,087 triggers (49,392 B) → 12,326 (197,216 B), +147,824 B; response intent rows 6,184 rows × 45 B (278,280 B) → 24,664 (1,109,880 B), +831,600 B; response trigger pairs 3,087 (49,392 B) → 12,326 (197,216 B), +147,824 B. The stream range lists are unchanged: the demo's `reserveStreams` already reserves `eventCapacitySum()` ranges, more than the 514 the narrowphase can stream. Net +1,644,632 B (≈1.57 MiB, ≈801 B per body capacity).

**C6 review follow-up: density, bench and memory record (2026-10-06).**
- **Contact density at battle scale.** Measured with `zig build -Doptimize=ReleaseFast bench -- --group collision --items 2048 --details`: 6,646 candidate pairs (6,646 contacts) over 2,048 bodies, 3.25 pairs per body. At the default counts (the 3 runs below) the figures are 2,556 / 14,826 / 38,407 pairs at 1024 / 4096 / 10000, which is 2.50 / 3.62 / 3.84 per body. The fixture is a 512-column grid at 7 px spacing with 9 px bodies, so every body overlaps its 8 neighbours. Interior bodies sweep exactly 4 pairs, so the density tends to 4 from below and never exceeds it. In x-sweep order each swept item emits at most 4 pairs, so no range of any partition exceeds the per-item bound either. `collision-sparse` runs 0.05 per body (52 / 205 / 500 pairs). `collision-response-mixed --items 2048` takes 2,048 hand-written contacts over 4,096 bodies (0.5 per body, no broadphase; 512 triggers, 1,536 intents). No shipped or bench scenario measured exceeds 4 pairs per body, so the bound is unchanged. The battle-scale demo spawns its 2,048 movers on a 96 × 88 px grid with 20–24 px bodies, so it starts at 0 contacts. Its in-play density needs a display run and was not measured. `collision_pair_bound_exceeded` in the runtime perf line is the live check.
- **Memory at 2053 bodies** (R = 129 slots, 16 B per pair, from the reserved capacities). Broadphase slots go from 36,056 pairs (576,896 B) to 44,960 (719,360 B): +142,464 B (≈139 KiB, ≈69 B per body capacity). Nothing else changes size.
- **Shape choice.** The per-range reservation is cap·H(R)·4 pairs, ≈5.5× the 4 × cap bound (131,392 B). The cheaper shape, one shared pair buffer with per-range windows of 4 pairs per item (C5's narrowphase shape), would save ≈588 KB. It was rejected because broadphase output per item is data. A window cannot keep growth, so any range locally denser than 4 per item (a cluster inside an otherwise sparse scene) would replay the whole broadphase on every such step. The slots grow once and then hold. They also give low-index ranges k/(r + 1)× headroom in a k-range partition. The cost is ≈69 B per body, against the ≈801 B per body that C6 added.
- **Bench.** `zig build -Doptimize=ReleaseFast bench -- --group <name> --details`, 3 runs at the follow-up tree, medians of each case's mean, run spread = (max − min) / median, against the C6 "after" column. The `collision` benches never call `reserve`, so only the per-step `grew` flag reaches them.

| group | case | items | C6 after | follow-up (3-run median) | delta | run spread | ok |
|---|---|---|---|---|---|---|---|
| `collision` | serial-direct | 1024 | 26.12 us | 26.61 us | +1.9% | 8.2% | ok |
| `collision` | thread-adaptive-tuned-range | 1024 | 22.75 us | 19.27 us | -15.3% | 0.5% | ok |
| `collision` | serial-direct | 4096 | 139.18 us | 118.97 us | -14.5% | 3.0% | ok |
| `collision` | thread-adaptive-tuned-range | 4096 | 123.34 us | 122.71 us | -0.5% | 21.1% | ok |
| `collision` | serial-direct | 10000 | 756.06 us | 750.37 us | -0.8% | 3.6% | ok |
| `collision` | thread-adaptive-tuned-range | 10000 | 390.97 us | 336.91 us | -13.8% | 0.9% | ok |
| `collision-sparse` | serial-direct | 1024 | 10.33 us | 9.41 us | -8.9% | 143.8% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 1024 | 7.28 us | 6.87 us | -5.6% | 7.6% | ok |
| `collision-sparse` | serial-direct | 4096 | 33.11 us | 34.22 us | +3.4% | 7.5% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 4096 | 36.55 us | 34.48 us | -5.7% | 14.5% | ok |
| `collision-sparse` | serial-direct | 10000 | 187.81 us | 189.56 us | +0.9% | 2.1% | ok |
| `collision-sparse` | thread-adaptive-tuned-range | 10000 | 197.66 us | 190.63 us | -3.6% | 15.0% | ok |

**Batch A review follow-ups (2026-10-06).**

- **A1/A2 drift counters compare against the reservation, not physical capacity.** `SpriteBatch` stores the frame's command reservation (`frame_command_reservation`, set by `markFrameReserved` from `Renderer.command_high_water`) and counts a reserved frame once when a submit crosses it. That is the same bound past which `ensureFrameBatchCapacity` grows prepared/vertex/group storage and the GPU streams (a possible GPU-idle stall), so drift absorbed by the command list's rounded-up capacity is no longer invisible. The warn fires on the 1st, 2nd, 4th, … drifting frame. `DigController` stores `plane_scratch_reserved` and counts every step whose carve count exceeds it, growing the scratch first only when its physical capacity is short. Tests that fail on the old comparison: `sprite_batch.zig` "submits past the reservation are drift even inside the physical slack" and "marking a frame reserved below its submitted count counts the drift", `renderer.zig` "submits past the reservation inside the command list's slack count as drift", `dig_controller.zig` "plane traversal counts carves past the reservation even inside the scratch's slack".
- **A1 FailingAllocator proof** also installs the failing allocator on `tw.world.allocator`, so world and dense-edit allocations are caught.
- **One thread-shared slot policy: 64 B.** `SearchScratch` now aligns to a private `thread_shared_record_alignment = 64` (seventh copy, consolidated by [Slice 65A](slice-65a.md)) instead of `std.atomic.cache_line` (128 on x86_64), with comptime `@alignOf`/`@sizeOf` asserts like `nav_graph.zig`'s scratch types. Measured with `zig build -Doptimize=ReleaseFast bench -- --group pathfinding --items 512`, 3 runs each, medians of each case's mean (128 → 64): `serial-direct` 3.41 → 3.53 ms, `thread-fixed-1` 1.79 → 1.79 ms, `thread-fixed-2` 1.40 → 1.28 ms, `thread-fixed-auto` 615 → 622 us, `thread-small-range` 440 → 376 us, `thread-large-range` 1.79 → 1.84 ms, `thread-adaptive-fixed-range` 476 → 479 us, `thread-adaptive-tuned-range` 497 → 471 us. Every row is inside its run spread except `thread-fixed-2`, which favors 64 in all three runs; 128 shows no gain from adjacent-line prefetch isolation, so the engine-wide 64 B rule applies.
- **Failure-atomic cache resize.** New `types.ListResize(T)`: `prepare` grows in place or allocates a shrink's replacement on the side, `commit` swaps it in and cannot fail, `abort` frees an uncommitted replacement. `ProbeTable.reserve` and `ResultCache.reserve` prepare every list before committing any, so an OOM at any allocation leaves the table or cache (entries, strides, `logical_capacity`) exactly as it was. Tests in `caches.zig` (fail on the old code): "pathfinding key set shrink OOM keeps the table and its entries" and "pathfinding result cache resize OOM at every allocation leaves the cache intact" (shrink and grow, each allocation failed in turn).
- `zig build verify` passes.


**Batch A bench record (2026-10-06).** `zig build -Doptimize=ReleaseFast bench -- --group <name> --details`, 5 interleaved before/after repetitions (odd reps before first, even reps after first). Before = `c648f61` (the commit preceding A1), after = A1–A4 together. Medians of each case's mean; run spread = the larger of the before/after (max − min) / median. Every case of every group (8 per item count) was gated against max(3%, spread): **no breach**. The table lists the serial baseline and the production `thread-adaptive-tuned-range` row; the worst positive delta over all cases was `render-prep` 4096 `thread-fixed-2` +27.9% inside its 55.8% spread. On every pathfinding group the `workload` column (requests, results, deferrals, evictions) is identical before and after, so A3 and A4 are behavior-neutral on the bench shapes (`pathfinding-escalated-detour` also asserts `available_results == 1` internally).

| item | group | items | case | before (median mean) | after (median mean) | delta | run spread | extra |
|---|---|---|---|---|---|---|---|---|
| A2 | `render-prep` | 1024 | serial-direct | 31.65 us | 23.71 us | -25.1% | 9.6% | `ordered_submit` 14.77 us → 6.73 us |
| A2 | `render-prep` | 1024 | thread-adaptive-tuned-range | 31.64 us | 23.68 us | -25.2% | 3.2% | `ordered_submit` 14.72 us → 6.71 us |
| A2 | `render-prep` | 4096 | serial-direct | 126.40 us | 94.84 us | -25.0% | 2.4% | `ordered_submit` 59.63 us → 27.02 us |
| A2 | `render-prep` | 4096 | thread-adaptive-tuned-range | 126.81 us | 94.48 us | -25.5% | 3.3% | `ordered_submit` 59.16 us → 26.95 us |
| A2 | `render-prep` | 10000 | serial-direct | 309.60 us | 232.13 us | -25.0% | 2.0% | `ordered_submit` 145.01 us → 65.95 us |
| A2 | `render-prep` | 10000 | thread-adaptive-tuned-range | 310.60 us | 230.09 us | -25.9% | 2.1% | `ordered_submit` 145.20 us → 65.92 us |
| A2 | `render-game-prep` | 1024 | serial-direct | 54.10 us | 41.78 us | -22.8% | 34.2% | `merge` 239 ns → 248 ns |
| A2 | `render-game-prep` | 1024 | thread-adaptive-tuned-range | 54.25 us | 42.17 us | -22.3% | 32.4% | `merge` 230 ns → 209 ns |
| A2 | `render-game-prep` | 4096 | serial-direct | 225.64 us | 178.07 us | -21.1% | 31.2% | `merge` 276 ns → 288 ns |
| A2 | `render-game-prep` | 4096 | thread-adaptive-tuned-range | 225.30 us | 177.16 us | -21.4% | 32.5% | `merge` 280 ns → 291 ns |
| A2 | `render-game-prep` | 10000 | serial-direct | 582.62 us | 472.83 us | -18.8% | 29.3% | `merge` 277 ns → 290 ns |
| A2 | `render-game-prep` | 10000 | thread-adaptive-tuned-range | 583.22 us | 470.82 us | -19.3% | 30.0% | `merge` 310 ns → 310 ns |
| A3 A4 | `pathfinding` | 512 | serial-direct | 3.33 ms | 3.40 ms | +2.1% | 13.2% | workload/output identical |
| A3 A4 | `pathfinding` | 512 | thread-adaptive-tuned-range | 786.37 us | 472.06 us | -40.0% | 26.7% | workload/output identical |
| A3 | `pathfinding-drain` | 1024 | serial-direct | 3.08 ms | 3.06 ms | -0.6% | 12.7% | workload/output identical |
| A3 | `pathfinding-drain` | 1024 | thread-adaptive-tuned-range | 770.50 us | 459.66 us | -40.3% | 20.4% | workload/output identical |
| A4 | `pathfinding-hard-fallback` | 16 | serial-direct | 92.26 us | 91.22 us | -1.1% | 42.4% | workload/output identical |
| A4 | `pathfinding-hard-fallback` | 16 | thread-adaptive-tuned-range | 91.75 us | 89.30 us | -2.7% | 4.9% | workload/output identical |
| A4 | `pathfinding-hard-fallback` | 64 | serial-direct | 351.18 us | 342.14 us | -2.6% | 8.0% | workload/output identical |
| A4 | `pathfinding-hard-fallback` | 64 | thread-adaptive-tuned-range | 187.57 us | 135.30 us | -27.9% | 44.7% | workload/output identical |
| A4 | `pathfinding-hard-fallback` | 128 | serial-direct | 663.34 us | 656.51 us | -1.0% | 7.5% | workload/output identical |
| A4 | `pathfinding-hard-fallback` | 128 | thread-adaptive-tuned-range | 271.06 us | 185.07 us | -31.7% | 14.1% | workload/output identical |
| A4 | `pathfinding-hard-fallback-budget` | 16 | serial-direct | 91.11 us | 93.49 us | +2.6% | 10.7% | workload/output identical |
| A4 | `pathfinding-hard-fallback-budget` | 16 | thread-adaptive-tuned-range | 89.23 us | 91.35 us | +2.4% | 11.0% | workload/output identical |
| A4 | `pathfinding-hard-fallback-budget` | 64 | serial-direct | 344.45 us | 341.84 us | -0.8% | 23.1% | workload/output identical |
| A4 | `pathfinding-hard-fallback-budget` | 64 | thread-adaptive-tuned-range | 185.87 us | 144.26 us | -22.4% | 66.2% | workload/output identical |
| A4 | `pathfinding-hard-fallback-budget` | 128 | serial-direct | 656.19 us | 655.45 us | -0.1% | 7.6% | workload/output identical |
| A4 | `pathfinding-hard-fallback-budget` | 128 | thread-adaptive-tuned-range | 284.47 us | 190.28 us | -33.1% | 37.0% | workload/output identical |
| A4 | `pathfinding-escalated-detour` | 1 | serial-direct | 15.42 us | 14.67 us | -4.9% | 49.5% | workload/output identical |
| A4 | `pathfinding-escalated-detour` | 1 | thread-adaptive-tuned-range | 13.14 us | 14.06 us | +7.0% | 9.9% | workload/output identical |

- A2: `ordered_submit` roughly halves because `drawSprite` is now one capacity compare plus `appendAssumeCapacity` instead of a growing `append`; `render-game-prep` gains the same in its entity-collect phase. **Correction (review, 2026-10-06): the −19% to −26% is a bench artifact, not a production gain.** The bench never marks the frame reserved (`render_prep.zig` ~:71), so "before" measured the pre-A2 unreserved path, a growing `append`. Production frames are reserved through `Renderer.reserveSpriteCommands`, where pre-A2 `drawSprite` already did one capacity compare plus `appendAssumeCapacity`, the same work as now, so production reserved frames gain about nothing. The rows show only that A2 does not regress the submit path.
- A4: the first A4 measurement regressed the threaded pathfinding cases (`pathfinding` `thread-adaptive-tuned-range` about +25–38% over 5–20 reps, serial unchanged). The three new limit fields shifted the size of the contiguous per-participant `SearchScratch` slots, which already false-shared hot counters across adjacent workers. A4 therefore also cache-line aligns `SearchScratch` (`generation: u32 align(std.atomic.cache_line)`, so every slot is whole lines), which turns the regression into the gains above; a layout test pins it. (The review follow-up above moves it to the engine's 64 B `thread_shared_record_alignment` by measurement and makes the layout check a comptime assert.)
- Debug and ReleaseFast `zig build test` pass; `zig build verify` passes.

**Goal.** The 2026-10-06 capacity audit sized the *planned* slices. This slice applies the same engine practice to every capacity in the *live* `src/` tree. For each data structure, the question is what an experienced engine programmer would do and why. The default answer is to keep it. A change lands only when its concrete benefit outweighs its cost and risk.

Success criteria:

- **Behavior.** No live behavior may depend on a physical `.capacity`, on allocation history, or on a load-time pool that runtime growth can outrun. That covers iteration order, deferral, refusal, drops, truncation, cache flushes and query reach. The exceptions are named work budgets, layout bounds, presentation budgets and the loud platform memory ceiling. Each exception is justified at its own site (Batch K).
- **Population.** Capacities sized by population grow at one point: the main-thread structural-commit seam. Growth is geometric and ahead of need. Hot paths stay allocation-free between growth points, and `std.testing.FailingAllocator` proves it.
- **World extent.** World-extent arrays are sized exactly once per world at load.
- **Assumed capacity.** No `appendAssumeCapacity` is protected only by a Debug assert.
- **Memory.** Memory savings are measured on a small, the shipped, and a large world instance.

In scope: the surviving changes below, grouped by area and ordered by priority. Also in scope: the per-site justification of the capacity-dependent sites that are kept, and the cross-slice text edits those changes require.

Out of scope (each item has a named owner):

- level-link growth at the dig seam and nav dirty buffers ([64E](slice-64e.md));
- the deferred-nav plan buffers and the `markStaticBodies` map ([65B](slice-65b.md));
- the content-sized `max_agent_budget` ([71B](slice-71b.md) 71B.1);
- retiring the stacked-UI headroom ([53B](slice-53b.md), then [60](slice-60.md));
- the zoom-band half of the spatial window ([60](slice-60.md));
- the perception `pending_dirty` bound ([64B](slice-64b.md) B3);
- `arbitration.behavior_count` ([61](slice-61.md));
- `DataSystem.reserveComponentRows` ([62](slice-62.md)).

### Current foundation (do not rebuild)

- `DataSystem` component stores are dense `std.MultiArrayList` SoA. Rows are added with an all-or-fail geometric preflight at the structural-commit seam (`data_system/structural.zig:541-635`). The entity slot map uses a LIFO free list with `u32` generations. FailingAllocator proofs exist (`data_system/system.zig:2144`, `:2597`).
- `SimulationEvents` has an explicit per-step `capacity_limit`:
  - required appends fail before any mutation;
  - diagnostic appends are dropped and counted (`simulation.zig:245-404`);
  - `ensureEventAppendCapacity` is the preflight.
- The exhaustive producer table already exists: `EventProducerId` with `maxEventsPerStep` (`simulation.zig:48-70`). It is summed by `SimulationPipeline.reserve(frame, pop)` (`simulation_pipeline.zig:752-768`), which only tests call today.
- `RangeOutputStream` follows a fixed sequence: count per range, then prefix, then contiguous write, then merge in range-index order. Growth happens only at the main-thread prefix (`simulation.zig:906-1000`).
- The pathfinding elastic resize runs on the main thread before dispatch:
  - growth is geometric, with a hysteresis shrink (`pathfinding/system.zig:315-377`);
  - pending work and group tallies are kept in snapshots;
  - logical-capacity gates already exist in `recordGroupRequest` (`:1176-1181`) and `resizePreservingLiveState` (`:353-361`).
- The budget-first queue pattern lives in `AudioCommandBuffer` (`app/audio.zig:92-114`, `:169-182`): the budget sets the capacity, and `reserve()` follows the budget.
- Renderer reservations are grow-only and track a high-water mark:
  - `reserveSpriteCommands` (`renderer.zig:439-453`);
  - `ensureFrameBatchCapacity` runs before the only threaded render phase (`renderer.zig:1236-1250`).
- Spatial index:
  - `DenseCellLookup` already supports non-square windows (`capacity_cells_x/_y`, `spatial_index.zig:136-183`);
  - the clamp-and-skip guard sits at `:718-748`.
- Already-planned capacity items are not repeated here:
  - 64E "Capacity audit (2026-10-06): nav dirty buffers" and "level links grow at the dig commit seam" (`slice-64e.md:376-430`);
  - 65B "Load-time capacities" (`slice-65b.md:737`);
  - 71B "71B.1 capacity-audit follow-up" (`slice-71b.md:558`);
  - 64B "B3 perception cache bound" (`slice-64b.md:432`);
  - 60 "Spatial-index dense window" (`slice-60.md:169-187`, `:387`);
  - 53B "Stacked-UI headroom retired" (`slice-53b.md:214-231`).
- The bench protocol follows the 64E record (`slice-64e.md:19-39`).

### Architecture notes

**Rules for this slice.**

- **No `stage_order` or `PipelineResource` change.**
  - `syncPopulationCapacity` runs at the commit seam (`merge_outputs`, main thread), outside `stage_order`.
  - The destructible resolve stays inside `action_react` with an unchanged contract.
  - Perception and affect still write `events` inside their own stages.
  - `stageContract()` is therefore untouched, and `zig build check`'s comptime order walk needs no new tag.
- **Growth points.**
  - Population-sized storage grows only in `SimulationPipeline.syncPopulationCapacity` (C3).
  - World-extent storage is sized exactly at load (F1, F3, D2).
  - Per-frame render storage grows on the main thread before the threaded emit (A2, H).
  - Every re-run reserve is grow-only and does nothing when the size is unchanged.
- **Logical limits.** Behavior gates compare against stored logical limits, never against `.capacity`. In std 0.17, `ArrayList.growCapacity(n) = n + n/2 + cache_line/@sizeOf(T)` and `MultiArrayList.resize` round capacity up, and shrink hysteresis keeps the slack. A3, A4 and B1 apply this rule, and X1 records it in `docs/coding-standards.md`.
- **Diagnostics.** New growth and drop counters log once through scoped loggers (`logging.game` or `logging.render`, from `src/core/logging.zig`). The once-only flag lives on the owning system and is never global. Each counter is also a perf metric.
- **Bench protocol.**
  - Run `zig build -Doptimize=ReleaseFast bench -- --group <name>` with every case in the group.
  - Use 5 interleaved before/after repetitions on adjacent commits and compare medians.
  - Gate: no case regresses by more than max(3%, its run-to-run spread).
  - Record the tables in Status, one table per batch.
- **Memory measurement (M1).**
  - `src/benchmarks/capacity_footprint.zig` adds three groups: `footprint-world`, `footprint-nav` and `footprint-spatial`.
  - Each group wraps its fixture in a private byte-counting allocator. It reports `reserved_bytes` (live after build) and `peak_bytes` (during build), plus the build time in `mean_ns`.
  - Items are the world side in tiles, {16, 256, 512}. A 16-tile world has 3 levels and 32 movers. The 256 and 512 worlds have 32 levels and 2048 movers.
  - Nav uses 16 fixed participants so results do not depend on the machine.
  - `footprint-nav` reports after the nav build and one pathfinding update with all movers requesting. That way the elastic result cache is counted.

**Batch plan.**

| Batch | Items | Priority | Lands after | Gate benches |
|---|---|---|---|---|
| M | M1 | enabling | — | new `footprint-*` (baseline recorded before D2/F/G) |
| A | A1 A2 A3 A4 | high (A4 medium) | — (independent) | `render-prep`, `render-game-prep`, `pathfinding`, `pathfinding-hard-fallback`, `pathfinding-hard-fallback-budget`, `pathfinding-escalated-detour` |
| B | B1 | high | — | `perception`, `ai-affect` (no-change check) |
| C | C1 C2 C3 C4 C5 C6 | high (C1, C2 low prerequisites; C5, C6 found by C3/C5 proofs) | B | `collision`, `collision-sparse`, `collision-response-mixed` (C6), `steering`, `spatial_index`, `scope`, `ai`, `ai-memory`, `ai-affect`, `perception`, `movement` |
| D | D1 D2 D3 D4 | high (D3 medium, D4 low) | M (D2 memory) | new `destructible-resolve`, `spatial_index`, `ai`, `perception`, `perception-los-dense`, `footprint-spatial` |
| E | E1–E8 | high (E3, E4, E6 medium; E5, E7, E8 low) | — (E2 before E3) | `pathfinding`, `pathfinding-shared-goal`, `pathfinding-drain`, `pathfinding-cache-open`, `pathfinding-cache-detour`, `pathfinding-cache-unreachable`, `pathfinding-group-field-detour*`, `nav-update-scattered`, `nav-update-multichunk`, `nav-update-links`, new `pathfinding-elastic-ramp` |
| F | F1 F2 F3 | high (F2, F3 medium); memory | M; F1 after 64E nav-dirty item; F2 after F1 | `nav-update-*`, `pathfinding`, `footprint-world`, `footprint-nav` |
| G | G1 G2 G3 | medium (G3 low); memory | F1, E2 | `pathfinding-escalated-detour`, `pathfinding-hard-fallback*`, `pathfinding-cache-*`, `pathfinding`, `footprint-nav` |
| H | H1 H2 H3 H4 | medium (H1, H4 low) | A2 | `render-prep`, `render-game-prep`, `render-game-prep-dense-surface`, `render-game-prep-dense-deep`; `gpu-smoke` |
| I | I1 I2 | medium | C4 | `perception`, `ai-affect` |
| J | J1 J2 J3 J4 | low | — | none (comptime, init or doc only) |
| K | K1–K6 | justify | B, C | none |

#### Area 1: Simulation pipeline, frame streams, pipeline controllers

**C3. Population-sized pipeline capacities follow the commit seam** (world-data-pipeline-01). High priority, Batch C.

- **Where:**
  - `simulation_pipeline.zig:378, 649, 687, 694, 719-723, 747-767`;
  - `dig_controller.zig:326-329, 366, 387, 392`;
  - `game_demo_state.zig:463-494, 695-714`.
- **Now:**
  - `movement_body_capacity` (demo value: movers + obstacles + 1) is fixed at `SimulationPipeline.init`. It sizes the scope, spatial index, ai, perception, ai_memory and affect scratch, the plane scratch, and the `.plane_traversal` event share.
  - DataSystem stores grow at the seam, but nothing in the pipeline follows them.
  - When AI population passes the init count, three things go wrong:
    1. A1's assert-only path corrupts memory in ReleaseFast.
    2. `ensureEventAppendCapacity` returns `EventCapacityExceeded` through `Engine.update`, and the app exits.
    3. Other gathers grow in the middle of a stage.
  - The "sum init caps" model used by 62/56B/61 is correct only while every create source is counted.
- **Change:** add `pub fn syncPopulationCapacity(self: *SimulationPipeline, frame: *SimulationFrame, data: *const DataSystem, world: *const WorldSystem) !PopulationSyncStats` (landed with `world`, so `raiseAgentBudget` charges the live reserved link limit).
  - **Call site.** `GameDemoState.applyStructuralCommandsAndPostCommitEvents` calls it right after `applyStructuralCommandsWithExtraEvents` and before `reactToPostCommitNavEvents`, so the post-commit reactions see grown capacities.
  - **Fast path.** Four compares, then return:
    - movement-body rows ≤ `movement_body_capacity`;
    - AiPerception rows × 2 ≤ the perception share (C4);
    - AiAffect rows × drive count ≤ the affect share (C4);
    - collision-response rows ≤ a tracked responder count.
  - **Slow path, sizing.** Every count that outgrew its tracking value moves to `grown(rows) = hotStoreCapacity(rows + rows / 2 + movement_range_alignment_items)`.
  - **Slow path, re-reserves.** All of these run with the new sizes and all are grow-only:
    - `scope.reserve`;
    - `spatial_index.reserveRows`. `reserve(capacity, geometry)` is split into `reserveRows(capacity)` (rows, entries, ranges, touched) and `reserveWindow(geometry)`. `reserve` calls both, so test call sites do not change. A population change never re-reserves or memsets the window;
    - `steering.reserveForCapacity(grown steering rows, counted statics)`, recounting statics only when responder rows grew (C2);
    - `collision.reserve` (C1);
    - `collision_response.reserveForContacts(CollisionSystem.estimateContactCapacity(new_cap))` (since C6: in `reserve`'s `reserveContactStreams`, at the pair bound);
    - `dig.reservePlaneScratch(new_cap + 1)`;
    - frame streams with `range_count = eventCapacitySum()`:
      - `navigation_intents`, `intents`: new_cap;
      - `contacts`: estimateContactCapacity (since C6: `CollisionSystem.reserveContactStream` in `reserve`, ranges to `maxRangeCount` of the pair bound);
      - `collision_triggers`: `estimateTriggerCapacity` (since C6: in `reserve`, one range);
      - `structural_commands`: new_cap + `structural_headroom` (B1).
  - **Event limit.** Then `self.reserve(frame, new_cap)` raises the event limit. That also re-runs every reserve the other slices attach to it: 64E `reserveNavDirty`, 68A `reserveAiRowMap`, 56B's projectile bitset.
  - **Pathfinding.** It calls a new `pathfinding.growForAgentCount(steering_rows)`. This is the grow half of `adjustCapacityForAgentCount` (`system.zig:315-337`), moved to the seam. Shrink stays in `beginUpdate` with its hysteresis, and `beginUpdate`'s grow remains the safety net. If `steering_rows > capacity.max_agent_budget`, `raiseAgentBudget(grown)` re-runs `nav_memory.budgetForCapacity(...).check`:
    - if admitted, the ceiling rises. A raise never moves the group-field threshold (71B.1): `groupFieldThreshold` clamps to the ceiling frozen at reserve;
    - if refused, the old ceiling stays, `agent_budget_raise_refused` is counted with one warn, and the pending backpressure (K2) applies. That gate is the loud platform-memory ceiling.
- **Benefit:**
  - removes a ReleaseFast corruption path and a crash caused by capacity;
  - gives every population-sized capacity a single growth point;
  - spawn sources (62, 56B, 61, 58) can no longer break correctness by forgetting an init term. Those init terms become initial sizes only.
- **Cost/risk:**
  - four compares per step; re-reserves are cold and seam-only;
  - a forgotten sub-reserve degrades to the existing in-stage growth (one allocation, never corruption);
  - the FailingAllocator test catches any such omission.
- **Determinism:** after this change capacity changes no output. Growth happens at a fixed seam, and its trigger is a pure function of committed row counts.

**B1. One owner for the per-step event bound** (world-data-pipeline-02, with world-data-pipeline-04 folded in). High priority, Batch B.

- **Where:**
  - `simulation_pipeline.zig:747-767`;
  - `simulation.zig:48-70, 667-683`;
  - `game_demo_state.zig:95-161, 441-494, 2156`.
- **Now:**
  - Production sets `capacity_limit` through `reserveStreams(pop_cap.event_reserve, …)`. That value is a hand sum that duplicates the producer table and adds structural and nav terms.
  - `SimulationPipeline.reserve` runs only in tests. So the planned reserves attached to it would never run in production: 64E `reserveNavDirty`, 68A `reserveAiRowMap`, 56B's bitset.
  - A forgotten demo term causes an `EventCapacityExceeded` exit.
- **Change:**
  - (a) The `EventProducerId` table gains two arms:
    - `.structural_commit => budgets.structural_headroom`, a fixed per-step share sized in events with `structuralEventHeadroom(creates, destroys + component sets)` (a create costs up to `max_structural_events_per_create` = 1 + the `EntityTemplate` component count; `set_simulation_tier` emits no event, so tier changes take no share and the share never follows population). The new field is `SimulationPipelineConfig.structural_headroom`; the demo passes `structuralEventHeadroom(1, action_intent_live_capacity)` = 79. The budgeted commit (`SimulationPipeline.structuralCommitBudget` → `StructuralCommitPreparer`) enforces the share on its own before any mutation, so an over-share burst fails with `EventCapacityExceeded` whatever other producers appended that step (final-review fix M2; the original arm `movement_body_capacity + structural_headroom` let bursts borrow idle perception/affect shares).
    - `.nav_reaction => 1`, the post-commit `nav_region_invalidated`.
  - (b) Add `pub fn eventCapacitySum(self) usize`, the exhaustive sum. `reserve` uses it, as does the demo's shared `range_count`.
  - (c) The demo init order becomes:
    1. `SimulationPipeline.init`;
    2. `reserveStreams(pipeline.eventCapacitySum(), 0, intent, contact, trigger, intent_capacity + structural_headroom)`;
    3. `try pipeline.reserve(&simulation_frame, pop_cap.mover_count + obstacle_count + 1)`.

    `reserve` only raises the limit. This keeps the "shared range_count equals the event bound" semantics that are recorded as kept.
  - (d) Delete `DemoPopulationCapacity.event_reserve`. The perception and affect terms stay until C4.
  - (e) Doc-only fixes from pipeline-04:
    - the three "No reserve method" comments at `:695-696` and `:706-711` become "reserved below to `movement_body_capacity`";
    - the `deinit` sentence moves from `reserve` onto `deinit`.
- **Benefit:**
  - one exhaustive switch protects the shipped path;
  - the 64E, 68A and 56B reserves run in production;
  - later producers (56, 59, 61, 63, 69B) add one arm instead of two edits.
- **Cost/risk:** the demo's literal test is re-pinned, and five slice texts need rewording (B1 cross-edits).
- **Determinism:** the limit only rises, so the set of accepted events is unchanged whenever the old limit was sufficient.

**C4. Perception and affect event shares derived from content** (world-data-pipeline-03, gameplay-systems-06, gameplay-systems-16). High priority, Batch C, lands in the same change as C3 or right after it.

- **Where:**
  - `simulation_pipeline.zig:384-395, 605-606, 742-743, 1164, 1189`;
  - `perception.zig:157, 187-191, 1075-1119`;
  - `affect.zig:88, 113-115, 412-414`;
  - `game_demo_state.zig:108-117, 158-160, 490-493`.
- **Now:**
  - Both config shares default to 0.
  - The demo derives them from `demoCognitionAgentCount`, a value hand-synced to `assets/ai/archetypes.json`.
  - A JSON edit, a new drive (Slice 61) or runtime spawns can silently truncate `entity_perceived`/`entity_lost`. AiMemory then never adopts the dropped acquisition, so behavior depends on capacity.
- **Change:**
  - Delete both config fields.
  - In `simulation.zig`, add:
    - `perception_events_per_observer_max: usize = 2`, because an identity swap emits both events;
    - `affect_events_per_row_max = @typeInfo(AiAffectDrive).@"enum".field_names.len`.
  - The pipeline stores the shares as `2 × AiPerception rows` and `drive_count × AiAffect rows`. They are computed at init and grown by C3.
  - The demo deletes `demoCognitionAgentCount`, `demo_cognition_archetypes_per_cycle` and both reserve terms.
  - The merge caps and `dropped_events` stay as the shared-frame safety net, with one `logging.game.warn` on the first drop (perception and affect each keep their own once-flag).
- **Benefit:**
  - truncation is impossible by construction;
  - Slice 61's fifth drive needs no literal edit;
  - pipeline tests get real perception events by default.
- **Cost/risk:** under 1 MB of cold `capacity_limit` growth at 2048 cognition agents. Tests that add observers after `init` must call `syncPopulationCapacity`, the production seam.
- **Determinism:** the events emitted are now a function of the step's state alone. There is no truncation.

**A1. Plane-traversal scratch preflight** (gameplay-systems-30). High priority, Batch A.

- **Where:** `dig_controller.zig:366` (assert), `:387`, `:392` (`appendAssumeCapacity`); the reserve is at `simulation_pipeline.zig:719`.
- **Now:** a Debug-only `std.debug.assert(pending_carves <= scratch.capacity)`. In ReleaseFast an overrun is a silent heap write.
- **Change:**
  - Replace the assert with `if (pending_carves > scratch.capacity) try self.growPlaneScratch(pending_carves);`. It sits ahead of the existing event and dense-edit preflights and before any carve. The cold `growPlaneScratch` resolves `self.scratch_allocator orelse return error.PlaneScratchUnreserved` only on the growth branch, so an unreserved controller with no carves still runs (resolving the allocator every step would fail it).
  - On an actual growth, increment `plane_scratch_grown: u64` (perf metric `dig_plane_scratch_grown`) and log one warn.
  - There is no loud `error.PlaneScratchCapacityExceeded`. That variant was rejected; see the Kept table.
- **Benefit / cost:** closes a latent out-of-bounds write for one compare per step.
- **Determinism:** the carve set and order are unchanged.

**C1. `CollisionSystem.reserve`** (gameplay-systems-21). Low priority, Batch C (prerequisite of C3).

- **Where:** `collision.zig:193-224` has no reserve; growth happens at `:407-461` and `:643-649`.
- **Now:** proxy rows, sweep `order`, `candidate_pairs` and narrowphase slot 0 are first sized inside the stage.
- **Change:** add `reserve(body_capacity)`:
  - `rows` gets `hotStoreCapacity(body_capacity)`;
  - `order` gets `body_capacity`;
  - `candidate_pairs` and narrowphase slot 0 get `estimateBroadphasePairCapacity(body_capacity, body_capacity)` (since the C5 review follow-up: `candidate_pairs`, the narrowphase staging and its tallies get `broadphasePairBound(body_capacity)`).

  `SimulationPipeline.init` calls it next to `reserveForContacts`, and C3 re-runs it. (Landed C1 left threaded per-range slots warming on their first threaded step; C5 removed that: the narrowphase writes per-range windows of one staging list and the broadphase slots are reserved to a per-range bound at `reserve`.)
- **Benefit:** the first collision step does not allocate, and an after-reserve proof becomes possible.
- **Cost:** about 150 KiB up front at battle scale, which step 1 allocated anyway.
- **Determinism:** unchanged.

**C2. Steering static-obstacle snapshot sized to statics** (gameplay-systems-19). Low priority, Batch C (prerequisite of C3).

- **Where:** `steering.zig:225-227` vs `:562-612`.
- **Now:** the init reserve uses `obstacle_count`. The first rebuild then grows to every collision-response row (about 2k vs 4 at battle scale), which is an in-stage allocation plus roughly 120 KiB that sits idle.
- **Change:**
  - `rebuildStaticObstacleSnapshot` counts `.static` mobilities in a pre-pass and ensures exactly that count for all three buffers. The pre-pass runs only on invalidation steps.
  - The pipeline derives the static capacity at init from the collision-response store, and `SimulationPipelineConfig.static_obstacle_capacity` is deleted.
  - C3 re-derives it when responder rows grow.
- **Benefit:** the init reserve covers the first rebuild, and capacity tracks content.
- **Cost:** one O(responders) column scan, only on invalidation steps.
- **Determinism:** snapshot order is unchanged.

#### Area 2: Pathfinding (`src/game/systems/pathfinding/`)

**A3. Request intake gated on the logical cap** (pathfinding-02). High priority, Batch A.

- **Where:** `system.zig:1349-1354`.
- **Now:** `limit = @min(requests.len, self.prepared_requests.capacity)`. Physical capacity is about 1.5× and depends on history: at the 4096 ceiling it is 6145. So `dropped_requests` and the accepted set depend on allocation history.
- **Change:** `limit = @min(requests.len, self.capacity.max_frame_requests)`, with `std.debug.assert(self.prepared_requests.capacity >= limit)`.
- **Benefit / cost:** a one-line fix.
- **Determinism:** intake becomes a pure function of the logical cap and the request stream.

**E1 and E2. Elastic resizes keep live work and cache entries** (pathfinding-04). High priority, Batch E.

- **Where:** `system.zig:243-296, 315-377`; `caches.zig:61-74, 294-327`.
- **Now:**
  - Every grow or shrink re-reserves `completed` and `unavailable`, which wipes them. A battle ramp-up from 8 to 4096 agents means 9 doublings.
  - Each wipe forces a re-solve storm, capped at 512 per step, and new representative-start paths. That is different agent motion caused by a capacity.
  - A shrink drops pending work past the new cap (`resize_dropped`).
- **Change (E1, lands first):** the shrink target becomes `max(derived, pending.len, group_requests.len)`, still capped at `max_agent_budget`. A shrink never drops accepted work.
- **Change (E2):** add `ProbeTable.resizePreserving` and `ResultCache.resizePreserving(allocator, new_logical)`:
  - **Grow.** Payload, `path_cells` and `stitched` columns grow in place, precisely. The stride is unchanged, so every `payload_index` stays put. New payload indices are pushed onto the free list in ascending order. A new 2× probe table is allocated and occupied slots are re-inserted in ascending old-slot order.
  - **Shrink.** The caller guarantees `new_logical ≥ live entries`: the cache shrink target is `max(derived, completed.len, unavailable.len)`. Live entries are compacted to indices `[0, live)` in ascending old-slot order, the columns are `shrinkAndFree`d, the free list is rebuilt in ascending order, and the probe table is rebuilt the same way.
  - `unavailable` and `pending_keys` use `ProbeTable.resizePreserving`.
- **Benefit:** a ramp-up no longer flushes caches or causes a re-solve spike, so resizes are neutral for existing entries.
- **Cost/risk:** about 150 lines in `caches.zig`. Risks are the re-insert order (fixed ascending) and stripe copying (tested). Growth still happens only at the resize point.
- **Determinism:** re-insert and compaction order is a fixed function of old slot order.

**F1. Exact reserves for exact-size and world-extent nav arrays** (pathfinding-01). High priority, Batch F.

- **Where:**
  - `types.zig:873-909` (`setLen`, `resizeArrayList`, `resizeFilledArrayList`; the `shouldShrinkCapacity` comment at `:878-885`);
  - `scratch.zig:90-94, 217-222`;
  - one-shot reserves at `nav_graph.zig:498, 505, 523, 573-574, 588-589, 594, 598, 1180-1181`, `nav_grid.zig:85`, `caches.zig:320-321`, `system.zig:261, 285`.
- **Now:** `ensureTotalCapacity` and `MultiArrayList.resize` allocate about 1.5×. "Hold exactly len" arrays and per-world arrays carry roughly a third extra memory, which the nav memory gate does not count. The comment blames allocator size classes.
- **Change:**
  - `ArrayList` paths use `ensureTotalCapacityPrecise`.
  - A package-local `reserveExactMultiArray(list, gpa, n)` does `if (list.capacity < n) try list.setCapacity(gpa, n)`, because std 0.17 MAL `setCapacity` always reallocates.
  - The `shouldShrinkCapacity` comment names the real cause.
  - Elastic pools keep their own ≥ 2× policy at the resize point.
  - Any steady-state proof that starts allocating is fixed by an explicit reserve at the seam that owns it (the 64E dirty buffers, hence the ordering), never by bringing slack back.
- **Benefit:** about one third less nav memory on every world. Estimated savings on 256×256×32 with 16 participants: about 45 MB of fixed arrays, plus up to about 75 MB in the result cache at 2048 movers. `max_nav_memory_bytes` then bounds real memory.
- **Cost/risk:** low and mechanical. The helpers are package-local.
- **Determinism:** unchanged, because A3, A4 and E5 already removed every behavioral read of physical capacity.

**A4. Logical spill and saturation limits in search** (pathfinding-03). Medium priority, Batch A.

- **Where:** `solve.zig:333, 398, 510, 597`; reserves at `scratch.zig:90, 93, 217`.
- **Now:** heap-full and corridor checks compare against physical `.capacity`. Per-slot reserve history could make a spill depend on which worker ran the request.
- **Change:**
  - At reserve, store `SearchScratch.open_limit = max(16, max_explored_nodes * open_heap_headroom_factor)`, the matching `AbstractScratch.open_limit`, and `AbstractScratch.corridor_limit = max_abstract_nodes`.
  - Compare `items.len` against those limits, and assert `capacity >= limit` at reserve.
- **Also (bench-driven):** `SearchScratch` is aligned to `thread_shared_record_alignment` (64 B; first `std.atomic.cache_line`, moved to 64 B by the review follow-up's measurement) so the contiguous per-participant slots never share a line; the new fields otherwise shifted slot boundaries onto hot counters and regressed threaded solves (see the Batch A bench record).
- **Benefit:** the spill point equals the documented budget on every worker.
- **Cost:** one field load per check; slots pad to whole cache lines (≤ one line per participant).
- **Determinism:** removes a latent dependence on which worker ran the request.

**E3. Negative cache with TTL and eviction** (pathfinding-10). Medium priority, Batch E (after E2).

- **Where:** `system.zig:259, 848, 1466`; `caches.zig:103-122, 167-197`.
- **Now:** `unavailable` is a `KeySet` with no expiry. When it is full, new definitive negatives are refused and those goals re-solve on every request.
- **Change:**
  - Add a `NegativeCache` type: a `ProbeTable` with a `u32` stamp payload and logical capacity `max_cached_results`.
  - `contains` treats `step - stamp >= ttl` as a miss. It uses the same `ttl` and the same `ttl == 0` rule as `ResultCache.freshSlotIndex`, for symmetry, since nav updates already clear negatives.
  - A full cache evicts round-robin over occupied physical slots, the same cursor policy as `findOrEvictSlot`.
  - It uses E2's `resizePreserving`. `pending_keys` stays a `KeySet`.
- **Benefit:** negative caching keeps working in long sessions, and capacity no longer decides re-solves.
- **Cost:** a stamp payload plus eviction code.
- **Determinism:** eviction uses a fixed cursor order.

**E4. Edge-window overflow evicts by scope instead of bumping the nav version** (pathfinding-25). Medium priority, Batch E.

- **Where:** `nav_graph.zig:750-774`; `system.zig:487-490`.
- **Now:** an edge-cap fallback rebuilds the abstract graph and bumps `nav_version`, which flushes the whole result cache. Cached results store cells, slots are geometry-stable, and the fallback graph equals the full rebuild, so the flush is purely conservative.
- **Change:**
  - The edge-cap fallback reports `edge_cap_fallback = 1, version_bumps = 0`, and `PathfindingSystem` takes the incremental branch: scoped eviction over the batch spans, or `completed.clear()` for whole-level batches.
  - The full-relabel bump past `nav_full_relabel_level_threshold` stays.
  - A full rebuild may slot links that are still behind the 64E cursor. That only adds connectivity, so scoped eviction stays correct.
- **Benefit:** the edge-window capacity no longer flushes the cache on a dig.
- **Cost:** a parity test against the full rebuild.
- **Determinism:** eviction is a pure function of the batch spans.

**E6. Initial elastic capacity from the loaded population** (pathfinding-05). Medium priority, Batch E.

- **Where:** `system.zig:231-236`; demo `game_demo_state.zig:220-256, 370`.
- **Now:** `reserve` starts at the floor of 8, so the first battle step grows straight to 2048. That allocates and memsets about 148 MB exact plus about 9 MB of worker pools inside `pathfinding_update`.
- **Change:**
  - Add `PathfindingCapacity.initial_agent_count` (default `min_capacity_floor`), and `reserve` applies `max(floor, initial)`.
  - The demo passes its load-time steering-agent count, and the pipeline forwards it.
- **Benefit:** the spike moves to load.
- **Cost:** a small API addition.
- **Determinism:** unchanged once E2 lands, since growth no longer wipes. Before E2, the only change is that the wipe happens at load instead of step 1.

**G1. Tier-1 scratch sized once per escalated ordinal, not per participant** (pathfinding-08 and pathfinding-07 as one change). Medium priority, Batch G.

- **Where:**
  - `scratch.zig:79-98`;
  - `system.zig:289-295, 418-420`;
  - `solve.zig:624-676`.
- **Now:**
  - Every participant reserves tier-1 abstract scratch: a 2×16384 slot table, a 4×16384 heap and a 16384 corridor, about 2 MB exact each (about 32 MB at 16 participants).
  - `worker_stitched_pool` gives each of 512 stripes a 2048-cell tier-1 stride (8 MB).
  - Yet at most `max_escalated_solves_per_step` (E = 1) tier-1 solves run per step.
- **Change:**
  - `prepareFallbackIndices` assigns an escalated ordinal (an array parallel to `fallback_indices`, serial, in fallback order) to each tier ≠ 0 item.
  - Participant `AbstractScratch` and `stitched_scratch` are reserved at the tier-0 caps (`tier0_abstract_node_cap`, `tier0_stitched_cell_cap`).
  - `PathfindingSystem` owns E dedicated tier-1 `AbstractScratch` and stitched buffers, plus E long stitched stripes, all indexed by ordinal.
  - `solveOne` uses them when `request.tier != 0`. Each ordinal belongs to exactly one fallback item, so this is race-free without pinning to a worker.
  - The `nav_memory` abstract term becomes tier-0 × participants + E × tier-1.
- **Benefit:** about 2 MB → about 0.5 MB per participant (≈22 MB exact at 16 participants, growing with core count). The worker stitched pool goes from 8 MB to about 2 MB.
- **Cost:** moderate plumbing.
- **Determinism:** ordinals follow the stable fallback order.

**G2. Result-cache stripes sized to the common bound plus a small long pool** (pathfinding-06). Medium priority, Batch G (after E2).

- **Where:** `caches.zig:252-327, 469-546`; `system.zig:258`.
- **Now:** every entry reserves a 512 × u32 plain stripe plus a 2048 × `StitchedCell` stripe, about 18 KB. That is about 148 MB at 2048 movers, and it is what drives `autoSizedMaxNavMemoryBytes`.
- **Change:**
  - The common stitched stripe uses `tier0_stitched_cell_cap` (512), about 6 KB per entry.
  - A long pool holds `max_escalated_solves_per_step × ttl` stripes at `max_stitched_path_cells`. With `ttl == 0` (no expiry, `caches.zig:449`) the long pool is sized to `max_cached_results`, so capacity never evicts a live entry.
  - When the long pool is full it evicts the oldest stamp, then the lowest index. A Debug assert checks that the victim satisfies `step - stamp >= ttl`.
  - The entry records which pool and stripe hold its path.
  - `nav_memory` terms are updated.
- **Benefit:** about 148 MB → about 54 MB at 2048 movers, and the gate's ceiling term drops from about 296 MB to about 100 MB.
- **Cost:** the two-pool free-list handling.
- **Determinism:** eviction order is fixed. It only removes already-stale long entries earlier than today.

**F2. Nav memory gate charges what load reserves** (pathfinding-37). Medium priority, Batch F (after F1).

- **Where:** `nav_memory.zig:105, 114-117`.
- **Now:**
  - It charges a flood queue of `cells × usize` per level, while the real queue is `ct²`. That overcounts by about 16.8 MB on the demo.
  - It counts the local open heap at 1×, while the reserve is `× open_heap_headroom_factor`.
  - It omits `stitched_scratch`.
- **Change:**
  - `per_level_bytes = cells × (4 + 2) + ct² × usize`.
  - Open heap: `max(16, max_explored × open_heap_headroom_factor) × @sizeOf(OpenNode)`.
  - Add `(max_stitched_path_cells + 1) × @sizeOf(StitchedCell)` per participant (tier-0 caps after G1).
  - Each term is derived from its real reserve site, using the `multiArrayRowBytes` pattern.
- **Benefit:** admission matches resident memory in both directions.
- **Cost:** updated expected-byte tests.
- **Determinism:** unchanged.

**E5. Group tally sized from per-step intake** (pathfinding-12). Low priority, Batch E.

- **Where:** `system.zig:265-266, 368, 1171-1192`; `caches.zig:199-240`.
- **Now:** capacity is `min(512, n)`, taken from the solve budget. When the table is full, a new shared goal's tally waits one step.
- **Change:**
  - Size `group_requests` and `group_key_map` to `max_frame_requests`.
  - Widen the `GroupKeyMap` payload to `u32`. The `max_frame_requests <= maxInt(u16)` assert variant was rejected because 71B makes intake content-sized.
  - `keep_group` clamps to the new logical cap.
- **Benefit:** the tally capacity no longer depends on the solve budget.
- **Cost:** a few KB more at large populations.
- **Determinism:** unchanged ordering.

**G3. Caller knobs separated from derived capacities** (pathfinding-38). Low priority, Batch G.

- **Where:** `types.zig:26-35, 435-497, 509-522`; fixtures in `test_support.zig:70-82`, `simulation_pipeline.zig:1431-1438` and similar, `benchmarks/steering.zig:62-69`.
- **Now:** five derived fields can be set by callers but are silently overwritten.
- **Change:**
  - `PathfindingCapacity` keeps only caller knobs: `max_agent_budget`, `initial_agent_count`, strides, budgets, chunk tiles, group-field config and the memory ceiling.
  - A private `DerivedCapacity` produced by `deriveCapacity` holds the five derived values.
  - Delete the dead `default_*` constants and the fixture assignments.
- **Benefit:** the compiler rejects stale knobs.
- **Cost:** churn in about 15 fixtures and benches.
- **Determinism:** unchanged.

#### Area 3: Gameplay systems (destructibles, spatial index, perception, affect, AI)

**D1. Destructible cell resolve reaches every row** (gameplay-systems-34). High priority, Batch D.

- **Where:** `destructible_controller.zig:31-36`, `:263-323`.
- **Now:** each cell intent scans only the first 256 dense destructible rows. Dense index order depends on creation and swap-remove history, so on maps with more than 256 crates some cannot be interacted with. The ai_update2 changelog lists this as a residual with no owner.
- **Check done:** the shared `SpatialIndexSystem` indexes AI agents only (`spatial_index.zig:546-596`), so it cannot serve this query.
- **Change:** a two-phase resolve inside `process`. The stage contract is unchanged, because the resolve reads only `data`, `world` and the merged intents, all const during `action_react`.
  - **Phase A.** Collect each cell intent (target invalid, `has_cell`) into a fixed `[action_intent_live_capacity]` stack array of `(level, cell_y, cell_x, intent_ordinal)` and sort it by key.
  - **Phase B.** Only if Phase A found intents, walk `destructibleSliceConst()` once:
    - Skip rows that are dead or lack `movement_body` and `collision_bounds`. The level is `worldLevelConst orelse 0`.
    - Compute the row's overlapped cell span from its AABB.
    - If `span_cells × ceil(log2(I + 1)) < I`, binary-search each span cell (lower bound, then walk equal keys). Otherwise test each intent cell directly. Per-row work is O(min(span × log I, I)).
    - The existing predicate (`contains_center or overlaps_cell`) makes the final accept decision, so floating-point edges match today's.
    - Each candidate updates that intent's best, using the existing lowest-(index, generation) tie-break.
  - Then `applyIntentDamage` runs in intent order with the pre-resolved targets.
  - Delete `destructible_cell_scan_budget`.
- **Benefit:** every destructible is reachable, and per-step work drops from O(I × min(D, 256)) to one O(D) pass, only on steps that have cell intents.
- **Cost:** a moderate refactor, about tens of µs at D = 10k on interact steps.
- **Determinism:** a min with a total tie-break does not depend on scan order. Results equal today's whenever D ≤ 256.
- **Cross-edits:**
  - `slice-61.md:41` foundation text becomes the inverted resolve.
  - `slice-63.md:134`, `:252`: the merchant `.interact` resolve uses the same inverted pass, and `merchant_cell_scan_budget` is deleted.
  - `slice-71d.md:120-127`, `:217`:
    - the merchant snapshot holds every live merchant row, right-sized from `MerchantStore` rows at state init and grown by C3's sync;
    - it is built lazily once per update as today, sorted by (level, cell), so the per-row nearest query walks only cells within `ai_trade_query_radius`;
    - `ai_trade_merchant_capacity` and `ai_trade_merchants_truncated` are deleted, along with the "63 precedent" sentence.

**D2. Spatial-index window sized to the world, clamp made visible** (gameplay-systems-25, world-extent half). High priority, Batch D.

- **Where:**
  - `spatial_index.zig:94-133, 160-183, 501-512, 684-754`;
  - caller `simulation_pipeline.zig:690-694`;
  - test helpers `ai.zig:1417-1427`, `perception.zig:1742-1752`.
- **Now:**
  - The window is 768² cells (4.7 MiB, allocated and memset) on every instance, including about 115 test fixtures on 1×1 worlds. The demo needs 257².
  - A populated bounding box wider than the window is clamped and skipped, so separation, cohere and perception neighbors are silently lost. This is reachable for whole-population builds on worlds wider than 768 cells.
- **Change:**
  - `DenseWindowGeometry` gains `world_extent_x: ?f32` and `world_extent_y: ?f32`.
  - Per axis, `window_cells = min(ceil(world_extent_px / cell_size) + 1, current halo formula)`. The +1 covers the inclusive span when an in-bounds position sits exactly on the far edge (span = floor(W/cs) − 0 + 1).
  - `SimulationPipeline.init` passes `bounds_width` and `bounds_height`, and the `testSpatialIndex` helpers pass their fixture extent.
  - The lookup uses the existing non-square `capacity_cells_x/_y`.
  - Add the counted `SpatialIndexStats.dense_window_clamped` (perf metric `spatial_dense_window_clamped`) with a once-per-session warn.
  - Both constants and the 4096² ceiling test stay until Slice 60 replaces the halo term with its band formula.
  - Cross-edit `slice-60.md:169-187` and `:387`: the world-extent term (with +1), the non-square sizing and the stat are landed by Slice 72. Slice 60 keeps only the band term and the constant deletion.
- **Benefit:** about 4.2 MiB saved on the shipped world and about 4.7 MiB per test fixture, plus a faster `zig build test`. The clamp becomes unreachable for in-bounds populations on worlds within the halo band.
- **Cost:** the row math touches `queryNeighbors`, which is covered by the existing parity tests.
- **Determinism:** neighbor sets become independent of the window for in-bounds populations.

**D3. LOS visit limit from the ray's own length** (gameplay-systems-07). Medium priority, Batch D.

- **Where:** `perception.zig:143-153`, `:1426-1492`.
- **Now:** `los_max_cells = 64` assumes 32-unit tiles. When `tile_size < ~11.3`, a full-range diagonal ray fails closed, so vision is silently truncated by a constant.
- **Change:**
  - After resolving `start_cell` and `end_cell`, compute `const visit_limit: u32 = @abs(end_x - start_x) + @abs(end_y - start_y) + 1;` and loop `while (visited < visit_limit)`.
  - Keep the fail-closed return as the float-pathology guard.
  - Delete `los_max_cells`.
- **Benefit:** an exact per-ray bound that is the same on every tileset.
- **Cost:** two `abs` and one add per call.
- **Determinism:** identical results on 32-pixel tiles.

**I1. Perception transitions derived from per-row columns** (gameplay-systems-05). Medium priority, Batch I.

- **Where:** `perception.zig:317-358, 497-499, 558-564, 609, 658, 1034-1045, 1075-1120, 1627-1676`.
- **Now:**
  - Each range keeps a cache-line-padded event slot sized `range_len × 2` at step time.
  - The tuner starts at 64-item ranges while `reserve` assumed 16, so the first threaded steps allocate in-stage, and every retune to a new partition may allocate again.
- **Change:**
  - Workers write only their own rows' `prev_nearest_threat_*` and `final_nearest_threat_*` columns, as they do today.
  - After the join, one serial pass derives the events. It calls `emitTransitionsForRange`'s body over a single full range, reusing `simd.equalInt4`.
  - Events are appended as one range, and the merge cap applies in row order.
  - Delete `PerceptionEventRangeSlot`, `event_ranges` and `range_take_counts`.
- **Benefit:**
  - allocation-free after reserve for every partition;
  - about 0.5 MiB freed at a population of 2053;
  - one fewer padded thread-shared type;
  - event-stream range use drops from `range_count` to 1.
- **Cost:** an O(rows/4) SIMD compare on the main thread, measured.
- **Determinism:** concatenating ranges in ascending order already equals row order, so the output is byte-identical.

**I2. Affect crossings from per-row bits, no sort** (gameplay-systems-15). Medium priority, Batch I (after C4).

- **Where:** `affect.zig:154-218, 258, 288, 373-446, 524-530, 730-747`.
- **Now:**
  - Per-range padded slots of `range_len × 4`, plus `merge_scratch` sized `item_count × 4`. Every crossing is held twice.
  - An O(E log E) canonical sort runs only because drive-major emission makes order depend on the partition. About 1.5 MiB is reserved at a population of 2053.
- **Change:**
  - Workers set per-row crossing bits, one `u32` column in the existing gather SoA.
  - A serial pass emits events in (think-set row, drive) order.
  - Delete the slots, `merge_scratch` and the sort.
  - Check done: no checksum or replay contract hashes `frame.events`. 64B's B2 table classifies only pipeline fields, and frame streams are per-step transient. Re-grep the checksum walker at landing. If a `frame.events` hash exists by then, bump T6 `checksum_format_tag` (live value + 1) in the same change.
- **Benefit:** about 1.5 MiB freed, plus everything I1 gains.
- **Cost:** a serial scan of one column.
- **Determinism:** the order changes from (entity, generation, drive) to (row, drive). It is still deterministic and independent of the partition. Once C4 lands, the cap cannot overflow, so cap membership never decides anything. The only consumers are stats (`simulation.zig:202`).

**D4. AI scan radius from the live cell size** (gameplay-systems-03). Low priority, Batch D.

- **Where:** `ai.zig:260-268, 277`.
- **Now:** a comptime `grid_cell_size = 32` "must match" the shared index, and nothing enforces that.
- **Change:**
  - `buildAiSeparationContext` computes the separation and cohere radii once per update with `spatial_index.cellScanRadius(radius, spatial.cell_size)` and stores them in `AiSeparationContext`.
  - Delete `grid_cell_size`.
  - If 68A's AiSystem rewrite lands first, it carries this change; check this item off with a pointer.
- **Benefit:** one source of truth, as perception already has (`perception.zig:1511`).
- **Cost:** two scalar calls per update.
- **Determinism:** identical at a cell size of 32.

#### Area 4: Render (`src/render/`)

**A2. `drawSprite` grows instead of failing past physical capacity** (render-assets-01). High priority, Batch A.

- **Where:**
  - `sprite_batch.zig:306-319` (refusal at `:313`);
  - `renderer.zig:439-453`, `1236-1250` (comment at `:1239-1244`);
  - `main.zig:45`;
  - `gpu_smoke_impl.zig:73-76`.
- **Now:**
  - In `frame_reserved` mode, `drawSprite` returns `error.SpriteCommandOverflow` at physical capacity. That capacity is the 4096 default or a past rounding by `growCapacity`, not the declared reservation.
  - The same frame succeeds in production and fails headless, and the error exits the app through `try engine.renderFrame`.
  - This contradicts the renderer's own stated policy.
- **Change:**
  - When `commands.items.len == commands.capacity`:
    - if `frame_reserved`, increment `command_overflow_grows` (perf metric `sprite_command_overflow_grows`) and log one `logging.render.warn` per growth event;
    - then `try commands.ensureTotalCapacity(allocator, len + 1)`.
  - Then `appendAssumeCapacity`. Remove `error.SpriteCommandOverflow`.
  - `ensureFrameBatchCapacity` is unchanged and still grows prepared, vertex and group storage plus the GPU streams before the threaded emit.
  - Update the comments at `renderer.zig:1239-1244` and `gpu_smoke_impl.zig:73-76`.
- **Benefit:** the outcome no longer depends on growth history, and drift in the reservation formula shows up as a counter.
- **Cost:** the loud failure becomes counter plus warn. Tests assert zero growth under a correct reservation. No hot-path cost, because the same compare is reused.
- **Determinism:** submission happens on the main thread only (`render_prep.zig:94-95`).

**H2. Geometric tile-edit transfer growth** (render-assets-11). Medium priority, Batch H.

- **Where:** `renderer.zig:285-286, 1075-1095, 1384-1397`.
- **Now:** the transfer buffer is recreated at the exact `required_bytes` on every new per-frame edit high, which is O(n) GPU-idle growths during dig-heavy play.
- **Change:**
  - `stageTileEdits` sizes the buffer with a pure helper, `tileEditTransferTargetBytes(len, capacity) !u32 = storageByteSize(max(len, tile_edit_scratch.capacity))`.
  - GPU growths can then never outnumber the geometric CPU scratch growths.
  - The growth point stays before acquire. `recordStorageRegionsInPass` already validates against `tile_edit_transfer_byte_size`.
- **Benefit:** logarithmically many stalls.
- **Cost:** a few KB.
- **Determinism:** presentation only.

**H3. Proof that a warmed tile-edit upload is allocation-free** (render-assets-10). Medium priority, Batch H, test only.

- **Where:** `renderer.zig:284, 1019-1048, 1377`.
- **Now:** the growth policy is correct, but the `ensureTotalCapacity` + `appendAssumeCapacity` pairing has no FailingAllocator proof, which coding-standards' allocator-discipline rule requires.
- **Change:** a new test using a local fixture (see Checklist). No production change.

**H1. GPU static streams created at the declared reservation** (render-assets-09). Low priority, Batch H (downgraded because the shipped config resolves to one bucket).

- **Where:** `renderer.zig:1399-1421, 495-502`; trigger at `world_system.zig:962-1040`.
- **Now:** the first creation uses exactly the needed vertices and then doubles lazily: 6 → 12 → … → 192 as interleave points appear. That is up to 5 GPU-idle growths during gameplay. The comment at `:1399-1402` predates composite bucketing.
- **Change:**
  - `reserveStaticGeometry` records `reserved_static_vertices`.
  - A pure `staticStreamTargetVertices(needed, reserved, current) usize` returns `max(needed, reserved)` on first creation and doubles past that.
  - Fix the comment.
- **Benefit:** zero GPU static growth after the first upload.
- **Cost:** at most about 6 KB of GPU memory.
- **Determinism:** presentation only.

**H4. GPU buffer growth without draining the device** (render-assets-12). Low priority, Batch H, gated on `gpu-smoke`.

- **Where:**
  - `renderer.zig:1263` (warn);
  - `:1270`, `:1415`, `:1086` (the `SDL_WaitForGPUIdle` calls);
  - the SDL contract at `SDL_gpu.h:3069`, `:3083`.
- **Now:** every growth runs create new → `SDL_WaitForGPUIdle` → release old, draining all frames in flight. SDL documents that `SDL_ReleaseGPUBuffer` and `SDL_ReleaseGPUTransferBuffer` free a buffer "as soon as it is safe to do so", so the idle buys no safety. The reserve path also warns "reserve capacity to avoid this" while it is reserving.
- **Change:**
  - Drop the idle in the three grow paths, so the sequence is create → swap → release.
  - The warn fires only on growth during a frame. `reserveSpriteCommands` logs at debug.
  - If a backend corrupts in `gpu-smoke`, keep the idle on that backend only, with a documented reason.
  - Texture replacement and `releaseTileDataBuffers` keep their idle.
- **Benefit:** growth events stop draining the frames in flight.
- **Cost:** relies on SDL's deferred release, so it needs display-gated validation.
- **Determinism:** presentation only.

**J2. Overlay headroom checked against the overlay's real cost** (render-assets-04). Low priority, Batch J.

- **Where:** `renderer.zig:196`; `fps_counter.zig:122-140`.
- **Change:**
  - Add `pub const max_sprite_commands = 1 + 10` to `FpsCounter`.
  - In `fps_counter.zig`, add `comptime { std.debug.assert(max_sprite_commands <= Renderer.k_overlay_command_headroom); }`.
  - Cross-edit 67B's `FpsCounter` "Bound" bullet (`slice-67b.md:124-125`) so it sets the constant to 4 + 10 = 14 under this assert.

**J3. Width guard for the composite-draw cap** (render-assets-07). Low priority, Batch J.

- **Where:** `renderer.zig:232, 545`; `sprite_batch.zig:233`.
- **Change:** next to `k_max_dense_composite_draws`, add `comptime { std.debug.assert(k_max_dense_composite_draws <= std.math.maxInt(@FieldType(DrawGroup, "window_slot")) + 1); }`. The value stays 32. This closes a latent ReleaseFast `@intCast` hazard.

#### Area 5: World data

**F3. Dense world arrays sized exactly at load** (world-data-world-01). Medium priority, Batch F.

- **Where:** `world_system.zig:459-513` (`initProceduralFromMeta`), `1731-1765` (`addDenseLayer`), `1772-1785` (`addUndergroundLevelStack`), `1930-1970` (`rebuildChunks`).
- **Now:**
  - `dense_tile_ids` grows 1.5× per layer. On 256×256×32 that is 7 reallocs and about 0.9 MB (22%) wasted.
  - At 512²×32 it is about 3.7 MB wasted and about 36 MB transient peak.
  - Chunk rows are over-allocated by 1.5×.
- **Change:**
  - `addUndergroundLevelStack` adds `dense_tile_ids.ensureTotalCapacityPrecise(len + underground_count × cellCount())` and a grow-only guarded `dense_layers.setCapacity(len + underground_count)`, next to the existing `level_base_z` reserve.
  - `initProceduralFromMeta` reserves precisely for `(1 + config.underground_level_count) × cellCount()` before the ground layer. `initProcedural` is the only production caller, and it always adds the stack.
  - `addDenseLayer` uses `ensureTotalCapacityPrecise` (load-only, OOM-atomic preflight kept).
  - `rebuildChunks` uses `next.rows.setCapacity(allocator, chunk_count)`.
- **Benefit:** saves about 0.9 MB on the shipped world and about 3.7 MB at 512², with one dense allocation at load and roughly half the load peak.
- **Cost:** a caller that adds layers one at a time without the bulk reserve recopies on each add. That costs at most 32 adds, and both shipped paths bulk-reserve.
- **Determinism:** unchanged.

**J4. Architecture doc matches MAL alignment reality** (world-data-ds-04). Low priority, Batch J, doc only.

- **Where:** `docs/architecture.md:387-391`; `data_system/types.zig:21-31`.
- **Change:** the text becomes: "contiguous scalar columns; worker ranges split at `movement_range_alignment_items` (16) boundaries; MAL does not guarantee 64-byte column bases (coding-standards Dense SoA)". Add the same sentence to the `hotStoreCapacity` doc comment.

#### Area 6: App core

**J1. `StateTransitions` budget first** (app-core-10). Low priority, Batch J.

- **Where:** `state.zig:184-224, 292-303`; `engine.zig:126-128`.
- **Now:** `reserve(capacity)` sets both the list capacity and the refusal bound, so any `reserve(n)` call moves behavior. That is the only coupling from capacity to refusal in app/core.
- **Change:**
  - Rename `default_capacity` to `pub const max_requests_per_frame: usize = 8`.
  - `max_requests` becomes a fixed value set at init.
  - `pub fn reserve(self) !void { try self.requests.ensureTotalCapacity(self.allocator, self.max_requests); }` mirrors `AudioCommandBuffer.reserve`.
  - `Engine.init` calls `try transitions.reserve();`.
  - Enqueue refusal and the lazy fallback stay. `slice-70b.md:49-50` stays accurate.

#### Owned by other slices (listed so this pass covers every site; not duplicated)

| Survivor | Site | Owner and item | This slice's part |
|---|---|---|---|
| render-assets-05 | `renderer.zig:198-212` stacked-UI headroom; `render_prep.zig:330-339` | 53B "Stacked-UI headroom retired", then 60 `k_post_state_command_headroom` | none; A2 composes unchanged |
| world-data-world-02, gameplay-systems-31, pathfinding-26 | level-link pool refusal (`world_system.zig:302-308, 1557-1619`; `dig_controller.zig:151-166`; `nav_graph.zig:569-576, 1299-1346`) | 64E "Capacity-audit follow-up … level links grow at the dig commit seam" (**landed 2026-10-06**: `SimulationPipeline.ensureLevelLinkRoom`; `LevelLinkLimitReached` deleted) | K6 adds the extra comment sites and callers to that item's text |
| pathfinding-17 | nav dirty buffers (`system.zig:110-127, 268-280`) | 64E "nav dirty buffers are load-time capacities" (**landed 2026-10-06**: `reserveNavDirty(structuralStageEventBound())` from `SimulationPipeline.reserve`; Batch F is unblocked); 65B "Load-time capacities" (fence window) | B1 makes `SimulationPipeline.reserve` production; C3 re-runs it on growth; K6 records the B1 prerequisite in 64E |
| pathfinding-29 | `nav_grid.zig:105-129` per-call map | 65B "Load-time capacities" | none |
| pathfinding-34 | `types.zig:97-100` 4096 ceiling; demo `:223` | 71B "71B.1 capacity-audit follow-up" (**landed 2026-10-06**: content-sized initial ceiling; threshold clamps to the ceiling frozen at reserve) | C3's `raiseAgentBudget` composes; K6 notes it in 71B |
| gameplay-systems-09 | `perception.zig:458-469, 857-889` `pending_dirty` | 64B "B3 perception cache bound" | none |
| gameplay-systems-17 | `arbitration.zig:24-25` `behavior_count` | 61 AI forage bullet | none |
| gameplay-systems-25 (band half) | spatial window zoom band | 60 spatial-index dense window item | D2 cross-edit |

#### Kept by decision

| Site | Kind | Why kept |
|---|---|---|
| `AudioCommandBuffer` 32/step (`config.zig:42`, `audio.zig:92-114`) | work budget | Budget sets capacity. Refusal is loud and deterministic, and the contact retries next step. |
| Lazy grow-to-bound fallback (`audio.zig:175-181`, `state.zig:296-301`) | other | Cold path. Grows once, straight to the bound, and never uses `assumeCapacity` unreserved. |
| SFX voice pool 16 | work budget | Bounds mixer cost. Voice stealing *is* the concurrency policy. |
| Audio ID arrays, perf-log/input enum arrays, `simd.lane_count`, stateless RNG, `frames_in_flight` [1,3] | format | Exact from manifest, enum or ISA, or an SDL range. |
| Audio name maps, `AssetCache` path map and leases, startup preload scratch, atlas JSON ceilings, shader 1 MiB ceiling | runtime-growing / other | Setup-time only, bounded by the manifest, loud on corrupt input. |
| Worker pool `cpu_count - 1`; `items_per_range` 64; tuner thresholds | other / budget / threshold | Sized per machine at init (65A owns the rule). Outputs do not depend on range shape. `threaded_batch_ns` derives from dispatch cost. |
| `StateStack.states` growth | runtime-growing | App structural seam; depth ≤ 4. |
| `TimeLoop.max_updates_per_frame` 5; frame-pacer fallback | work budget / threshold | Spiral-of-death clamp; the pacer derives from the fixed step. |
| Unbounded SDL event drain | work budget | Must drain fully. SDL owns the queue. |
| Overlay top-up 16 (`engine.zig:364-368`) | scratch | Bounded engine content; J2 compile-checks it. |
| Initial batch of 4096 commands; CPU/GPU batch growth policy | runtime-growing | Default ring for non-reserving states. Growth is geometric, before the threaded phase, and proven. 70A recorded this keep. Capacity stops affecting behavior after A2. |
| `k_max_tilemap_window_layers` 32; `k_max_dense_submit_stack_cap` 32 | format | std140 uniform width plus per-pixel work bound, refused loudly at load. |
| Static geometry and draw-list reservations; `staticGeometryCapacity` | runtime-growing | Bounded by the composite cap, grow-only, proven. |
| Texture and text slot maps (pool, free list, generations) | runtime-growing | Cold growth; 53A replaces dynamic text. |
| Tile-data buffer registry; `k_max_dense_tile_gpu_bytes` 64 MiB | world-extent / other | One exact buffer per world, plus a loud platform ceiling. |
| u32 GPU byte and vertex guards; `TileId` u16; component `enum(u5)`; entity `u32` | format | Index and format widths that fail loudly. |
| Sprite-prep range thresholds | threshold | Per-quad cost, tuned by the tuner. |
| Stimulus budgets; `action_intent_live_capacity` 64; `cognition_stagger_n` 4; LOD bands | work budget / threshold | Fixed per-step buses with counted drops, and cadences that change behavior by design. |
| `SimulationEvents.capacity_limit` mechanism | scratch | All-or-fail preflight. Sizing is fixed by B1/C3/C4; K1 justifies it. |
| `RangeOutputStream` growth at prefix | scratch | Main thread, before workers write; order comes from range index. |
| Shared `range_count` across `reserveStreams` | scratch | Capacity is never touched and is a valid bound. B1 keeps the semantics through `eventCapacitySum()`. |
| Structural preflight, component stores, slot map | runtime-growing | This *is* the seam. Proven. |
| No load-time `DataSystem` reserve | runtime-growing | Slice 62 owns `reserveComponentRows`. |
| `ai_memory_ring_capacity` 4; validation ceilings | format / threshold | An inline checksummed ring and authoring bounds. |
| `world_level` rows mid-stage (`dig_controller.zig:368-381`) | runtime-growing | Preflighted, OOM-atomic; reached only by malformed entities. |
| `dense_tile_edits` queue; sparse tile buckets; derived render index; small world-extent arrays | scratch / runtime-growing / world-extent | Bounded per frame and warmed. Sparse tiles can be added at runtime (58/69A own bulk sizing). Overshoot is a few hundred bytes. |
| Demo population sizing, debris pool 512, world config, render reserves | demo content | Lives in the demo caller. 6a10f3e reverted rule-driven render sizing. |
| Pathfinding `SearchScratch` O(cells) per participant | scratch | Direct-indexed, generation-stamped A*. F1 makes it precise. |
| Per-step request and solve pools; `effectiveSolveLimit` clamp | runtime-growing / work budget | Logical bounds proven. The physical term never binds. |
| Probe tables at 2× (50% load); payload free list; resize snapshots | format / scratch | Probe chains terminate; snapshots are cold. |
| Scratch slots (workers + 1); patch edges `pcap²`; flood queues `ct²` | scratch | Proven bounds, reserved before dispatch. |
| World-extent nav arrays | world-extent | Textbook layout. F1 removes the slack. |
| *Rejected:* loud `error.PlaneScratchCapacityExceeded` (pipeline-01 draft) | — | Would turn a population that is legal by construction into a refusal. A1's preflight growth keeps behavior independent of capacity. |
| *Rejected:* `@typeInfo(...).fields.len` (pipeline-03 draft) | — | Not the Zig 0.17 spelling. Use `.@"enum".field_names.len` (`arbitration.zig:27`). |
| *Rejected:* asserting `max_frame_requests <= maxInt(u16)` (pathfinding-12) | — | 71B makes intake content-sized, so the assert becomes a load refusal. Widen to `u32`. |
| *Rejected:* dropping the perception truncation test (pipeline-03 draft) | — | Rewritten at system level instead, so the merge-cap safety net stays covered. |
| *Rejected:* long-pool eviction with `ttl == 0` (pathfinding-06 draft) | — | It would evict live entries. The pool is sized to `max_cached_results` instead. |
| *Rejected:* keeping the cache wipe on shrink (pathfinding-04 draft) | — | The wipe changes outcomes. E2's preserving shrink, with target ≥ live entries, is behavior-neutral. |

### Checklist

- [ ] **M1 · Memory footprint benches.**
  - Add `src/benchmarks/capacity_footprint.zig` with the `footprint-world`, `footprint-nav` and `footprint-spatial` groups, registered in `runner.zig`.
  - `suite.RunStats` gains `reserved_bytes: ?u64 = null` and `peak_bytes: ?u64 = null`, which the formatter prints when set. The fixtures:
    - `initDemoFromMeta`, then `addUndergroundLevelStack(levels - 1)`;
    - a `DataSystem` with the mover count;
    - `SimulationPipeline.init` in the demo capacity shape, with 16 participants;
    - one pathfinding update with every mover requesting.
  - Tests: one `suite.zig` formatting test for the byte fields, pure utility against stubs. No production test calls the bench.
  - Bench: record baselines at sides {16, 256, 512} before D2, F and G land.
- [x] **A1 · Plane-traversal scratch preflight** (§A1).
  - Tests in `dig_controller.zig`:
    - scratch reserved to 0 (`reservePlaneScratch(allocator, 0)`: sets the allocator, leaves capacity 0; a reserve of 1 rounds up to 6 entries and never grows) and two NPCs entering hole cells in the same step: both carves land, `plane_scratch_grown == 1`, and the carved tiles and `world_tile_changed` events (same order) match a run reserved to 4 (headless worlds have no GPU tile buffer, so dense edits are empty in both);
    - the existing FailingAllocator test (`:549`) still passes;
    - with a `FailingAllocator` installed after reserve, a step with `pending_carves ≤ reserve` allocates zero times.
  - Bench: none. No group isolates the dig stage, and the cost is one compare per step.
- [x] **A2 · `drawSprite` growth** (§A2).
  - Tests:
    - `sprite_batch.zig:1634` is split in two:
      - (a) submitting past capacity grows, the stream stays ordered, and `command_overflow_grows == 1`;
      - (b) the same submit under `FailingAllocator(fail_index = 0)` returns `error.OutOfMemory` with `items.len` unchanged, proving no `assumeCapacity` overrun;
    - `loading_state.zig:542` injects through a FailingAllocator on `renderer.batch.allocator` at zero capacity and expects `error.OutOfMemory`;
    - add a correctly reserved frame under `FailingAllocator` with `command_overflow_grows == 0`;
    - `sprite_batch.zig:1611` and `renderer.zig:2316`, `:2360` are unchanged;
    - `grep -rn SpriteCommandOverflow src/` is empty.
  - Bench: `render-prep`, `render-game-prep` (no regression).
- [x] **A3 · Logical intake limit** (§A3).
  - Tests in `system.zig`:
    - grow 8 → 40 agents directly (plus forced physical slack on `prepared_requests`), and separately grow 8 → 128 then hold 40 agents for `capacity_shrink_window` steps so it shrinks to logical 40 (physical > logical on both; "grow to 64, shrink to 40" is unreachable: a shrink needs `agent_count * 2 < current`, and the target is `deriveCapacity(agent_count)`); submitting `max_frame_requests + 5` same-goal requests drops exactly 5 on both, and both accept the same request;
    - the same request stream on a 1-chunk and a 4-chunk minimal world gives an equal `dropped_requests`, independent of world size.
  - Bench: `pathfinding`, `pathfinding-drain`.
- [x] **A4 · Logical search limits** (§A4).
  - Tests in `scratch.zig` and `solve.zig`:
    - a search cannot exhaust the reserved `open_limit` naturally on a small fixture (the heap limit is 4× the node budget and every new-cell push first spends one budget unit, so the node budget binds first), so the tests lower `open_limit` / `corridor_limit` (and `node_budget` for the corridor case) on both scratches as a local fixture, then inflate one scratch's physical capacity well past the limit: local A* still returns `budget_exhausted` at the same expansion count and heap length, abstract relax saturates at the same push, and `buildCorridor` truncates at the same corridor length on both;
    - `open_limit` and `corridor_limit` are equal on a 1-chunk and a 4-chunk world;
    - re-reserving a smaller budget lowers the logical limits while the grow-only physical capacity stays;
    - the wraparound tests at `scratch.zig:276`, `:299` are unchanged.
  - Bench: `pathfinding`, `pathfinding-hard-fallback`, `pathfinding-hard-fallback-budget`, `pathfinding-escalated-detour`.
- [x] **B1 · Production event bound** (§B1).
  - Final-review follow-up M2 (Status): the `.structural_commit` share is a fixed per-step count in events (`structuralEventHeadroom`), enforced on its own by the budgeted commit; the shipped `capacity_limit` re-pins to 255.
  - Tests:
    - `game_demo_state.zig:2156` pins `demo.simulation_frame.events.capacity_limit` after init as a literal, re-pinned by hand;
    - a test walks every `EventProducerId` at comptime and asserts a nonzero budget under the demo config;
    - `eventCapacitySum() == capacity_limit` after `reserve`;
    - the reserve tests in `simulation_pipeline.zig` (`:1643`, `:2091`) are unchanged;
    - a demo FailingAllocator test (installed after init) runs one step that fills every producer's budget with zero allocations and `events.stats.dropped == 0`.
  - Cross-edits:
    - in `slice-56.md:85, 487-489, 584`, `slice-59.md:51, 302-303, 437`, `slice-61.md:80`, `slice-63.md:228-232, 322` and `slice-69b.md:204`, each "`event_reserve` adds X" becomes "a new `EventProducerId` arm with budget X", and each literal update becomes a re-pin of `capacity_limit`;
    - `slice-64b.md:257` adds `structural_headroom` as config and excluded.
  - Bench: `perception`, `ai-affect` (no change expected).
- [x] **C1 · `CollisionSystem.reserve`** (§C1).
  - Tests: on a minimal 4-body fixture, serial `reserve` then `updateSerial` under `FailingAllocator` allocates zero times. The existing warm-up tests are unchanged.
  - Bench: `collision`, `collision-sparse`.
- [x] **C2 · Steering statics sized to the static count** (§C2).
  - Tests:
    - 3 dynamic responders, 1 static, then `reserve(…, 1)`: the first update under `FailingAllocator` allocates nothing;
    - `steering.zig:2319` drops its warm-up step.
  - Bench: `steering`.
- [x] **C3 · `syncPopulationCapacity`** (§C3), including the `reserveRows` and `reserveWindow` split, `growForAgentCount`, and `raiseAgentBudget`.
  - Final-review follow-ups (Status): M1 reserves the steering obstacle snapshot to the responder capacity; L1 extends the growth proof to `world.allocator` and a pinned multi-range run; L2 moves the demo seam test to a minimal fixture.
  - Tests in `simulation_pipeline.zig`, on `testMinimalMultiLevelWorld`:
    - **Growth proof:** build with `movement_body_capacity = 4` and warm one step. Create 8 AI movers through structural commands, commit, and sync. Install `std.testing.FailingAllocator` on the pipeline, frame-stream, data and pathfinding allocators. Run a step where all 12 bodies cross dug holes. Expect zero allocations, `events.stats.dropped == 0`, and every landing carved.
    - Sync at an unchanged population allocates nothing (FailingAllocator), and the spatial window is not re-memset (its pointer and contents are unchanged).
    - A raise refused by a tight `max_nav_memory_bytes` keeps the ceiling, counts `agent_budget_raise_refused == 1`, and the dropped requests are counted.
    - The reserve-then-run proofs and the dig plane-traversal tests (`:3395-3500`) still pass.
  - Cross-edits:
    - `slice-62.md:355`: the state-init spawn terms are initial sizes, and sync is the growth point;
    - `slice-56b.md:232` and `slice-61.md:177, 502` get the same sentence;
    - `slice-64b.md:257` reclassifies `movement_body_capacity` as "excluded — derived capacity".
  - Bench: `scope`, `spatial_index`, `collision`, `steering`, `ai`, `ai-memory`, `ai-affect`, `perception`, `movement`.
- [x] **C4 · Derived perception and affect shares** (§C4).
  - Tests:
    - a default-config pipeline with 2 perception observers that acquire in one step publishes 2 `entity_perceived` events, and AiMemory refreshes both;
    - 3 AiPerception agents in a 1×1 world give a derived share of 6, and an identity swap for all 3 drops 0;
    - the affect share equals drive_count × AiAffect rows;
    - after creating 4 more observers, commit and sync, the share grows to the geometric formula with 0 drops;
    - `simulation_pipeline.zig:2896` is rewritten as a `perception.zig` system test with `PerceptionConfig.max_events_per_step = 1`: truncation in row order, the drop counted, and the warn-once flag set once;
    - the explicit share fields are removed from test configs (`:1630-1631`, `:2078`, `:2149-2150`, `:3619-3620` and similar).
  - Cross-edits:
    - `slice-61.md:80-84, 334-341, 521`: the multiplier becomes automatic, and only the `capacity_limit` re-pin remains;
    - `slice-64b.md:257`: both shares become "excluded — derived capacity".
  - Bench: `perception`, `ai-affect`.
- [x] **C5 · Per-range outputs never warm in-stage** (found by the C3 multi-worker growth proof, `ebeb3c7`; landed 2026-10-06, bench and memory record above).
  - Was: after a C3 growth, `collision`, `scope` and `spatial_index` still allocated their per-range output slots on the first threaded step (the ranges past slot 0 filled on first use), so C3's "allocation-free between seams" held only for the serial path. Perception's range slots are removed outright by I1 and are not part of this item.
  - **As landed (replaces the original sizing premise below).** The range count is not bounded by the worker count: the tuner targets participants × up to `max_ranges_per_participant` (16), and `shapeBatch` aligns every range size up to `range_alignment_items` (16), so the bound is `thread_system.maxRangeCount(capacity, alignment) = ceil(capacity / alignment)` (R = 129 at 2053 bodies). Pre-reserving per-range slots for every reachable partition would cost ≈ cap·H(R) items (≈5.3 MB of 472-byte tier commands at 2053), so:
    - **Outputs with at most one record per input item lose their per-range buffers** (scope collision gather, scope AI halo gather, scope tier policy, spatial-index gather, collision narrowphase): each range writes its own `[range.start, range.end)` window of one 64-byte-aligned buffer sized to the item count and stores its count/diagnostics in a 64-byte-padded tally; the main thread compacts the windows in range order (a forward copy, since dst ≤ src; zero copies when nothing is excluded) or streams them (tier policy, narrowphase). Output and order are identical. The buffers are item-capacity sized and the tallies `maxRangeCount` sized, so `reserve` at the seam covers every partition; the in-stage ensures stay as grow-only safety nets. Jobs assert `range.index < tallies.len`, `range.start == range.index * items_per_range`, and `range.end <= out.len`.
    - **The collision broadphase keeps per-range slots** (pairs per item are data): `reserve` sizes slot r to `estimateBroadphasePairCapacity(cap, ceilDiv(cap, r + 1))` for every `r < maxRangeCount(cap)` (`ensureTotalCapacityPrecise`), which is ≥ the per-slot warm estimate under every partition (any partition's range r covers ≤ `ceilDiv(cap, r + 1)` items). A dense-cluster overflow stays the kept grow-and-replay. Since the C6 review follow-up the slot is `broadphasePairBound(ceilDiv(cap, r + 1))`, unclamped: the old estimate clamped to `cap`, which in a 2-range partition held only 2 pairs per item in range 0 (3 in a 3-range one).
    - No seam change: `growPopulationCapacity` already calls `scope.reserve`, `spatial_index.reserveRows`, and `collision.reserve`.
  - Tests (each fails with the reserves reverted to slot 0): `thread_system.zig` "every selectable batch shape stays within maxRangeCount"; `simulation_scope.zig` "after reserve, threaded gathers and tier policy at 32- then 16-item ranges allocate nothing and match serial" (real 2-worker pool, 131 rows); `spatial_index.zig` "after reserveRows, threaded builds at 32- then 16-item ranges allocate nothing" (no warm build); `collision.zig` "after reserve, threaded broad/narrowphase at 32- then 16-item ranges allocate nothing" (sparse chain); `simulation_pipeline.zig` "population growth on the multi-worker path allocates nothing on the first step after growth" (`expectOnlyOwnersAllocated(&.{})`, world allocator swapped) and "a partition retune after population growth allocates nothing" (`runPopulationGrowthScenario`'s new `retune` parameter: pinned 2-worker/32-item, re-pinned 2-worker/16-item, one stationary step under the uniform `FailingAllocator`; a 64-item range is inline at 37 bodies, so the original "16 → 64" retune is replaced by 32 → 16). The serial-vs-multi parity test keeps `retune = null`.
  - Original change (superseded by the as-landed design above): `syncPopulationCapacity` also reserves each system's per-range slots for the maximum range count the tuner can choose at the new capacity (ranges = ceil(capacity / min items per range), bounded by the worker count), so a partition retune never allocates in-stage. Sizes stay pure functions of capacity and worker count.
  - Original tests (replaced as above): the `runPopulationGrowthScenario` 2-worker variant (tuners pinned to a 2-worker split) asserts zero allocations on the first threaded step after growth, under `FailingAllocator` with the world allocator swapped; plus a retune test that moves from 16- to 64-item ranges with zero allocations.
  - Bench: `collision`, `collision-sparse`, `scope`, `spatial_index` (no-regression gate; recorded above, 0 breaches).
  - **Review follow-up M1 (`78ed7e5`).** `reserve` sized `candidate_pairs`, the narrowphase staging and its tallies to `estimateBroadphasePairCapacity(cap, cap)`, which clamps to 1 pair per body, while the broadphase slots hold up to 4 pairs per range item. A scene with 1–4 pairs per body therefore grew them in-stage (`mergeBroadphaseRangeBuffers`, `prepareNarrowphaseStaging`), uncounted. They are now reserved to `broadphasePairBound(cap) = broadphase_pairs_per_item (4) × cap` (tallies to `maxRangeCount` of it), so every scene with total candidate pairs ≤ 4 × capacity is allocation-free under every partition; denser scenes take the kept grow paths (broadphase replay included). Test: `collision.zig` "after reserve, ~2 pairs per body on the multi-worker path allocate nothing" (64-body chain, 125 pairs, real 2-worker pool at 32- then 16-item ranges, contacts compared with serial); it fails on the old reserve in `mergeBroadphaseRangeBuffers`. Bench and memory record above (+0.49 MiB at 2053 bodies, no time change).
- [x] **C6 · Contact-dependent streams reserved to the pair bound** (found by the C5 review follow-up M1, 2026-10-06; landed 2026-10-06, bench and memory record above).
  - Was: `CollisionSystem.estimateContactCapacity(body)` was `estimateBroadphasePairCapacity(body, body)` (1 contact per body). The seam (`growPopulationCapacity`) and `SimulationPipeline.init` sized `frame.contacts`, `frame.collision_triggers` (`estimateTriggerCapacity`) and `CollisionResponseSystem.reserveForContacts` (intents 2×, triggers 1×) from it, so a scene with more than one contact per body grew `frame.contacts.values` in `collision_detect` (`RangeOutputStream.prefix`), the trigger stream and the response intents and trigger pairs in `collision_respond`, uncounted, even though the collision system's own stores covered 4 pairs per body.
  - **As landed.**
    - `estimateContactCapacity(body)` returns `broadphasePairBound(body)` (contacts ⊆ candidate pairs). Its doc names it the pair bound, past which the streams grow on the main thread.
    - One owner for the contact-dependent reserves: `SimulationPipeline.reserve` calls a new `reserveContactStreams`, sized from the tracked `movement_body_capacity`. It reserves `frame.contacts` through a new `CollisionSystem.reserveContactStream(contacts, body_capacity)` (values to the pair bound, ranges to `maxRangeCount(pair bound, collision_range_alignment_items)`, the narrowphase's range bound), `frame.collision_triggers` to `estimateTriggerCapacity` in one range (the response writes one), and `collision_response.reserveForContacts`. `growPopulationCapacity` drops its own contact, trigger and response reserves: it re-runs `reserve` after updating the tracked capacity. `init` reserves the response to `@max(config.contact_capacity, estimateContactCapacity(population))`, next to `collision.reserve(population)`.
    - B1 bookkeeping is unchanged: `eventCapacitySum()` still sizes the event stream and the shared `range_count` the seam passes to the intent and structural streams. The contact stream's range bound is now its own exact bound, not the event bound (which also covered it, since `plane_traversal` alone is body + 1 ≥ ⌈4·body / 16⌉).
    - **Past the bound: counted, deterministic.** `reserve` stores the declared `reserved_pair_bound` (grow-only, the logical limit). A step whose candidate pairs exceed it is counted in `pair_bound_overflows` and `CollisionStats.pair_bound_exceeded` (perf metric `collision_pair_bound_exceeded`, in the capacity-growth perf line), compared against the stored bound, never a list's `.capacity`. A warn fires on the 1st, 2nd, 4th, … such step (comptime-gated, compiled out of tests). The step still completes through the kept main-thread grow paths (candidate merge, staging, `prefix`, the response ensures), which run between batches, never inside a worker, with output identical to an in-bound run. Contacts ⊆ pairs, so the one count covers the collision stores, the streams and the response. An unreserved system (standalone benches) declares no bound and never counts.
  - Tests:
    - `simulation_pipeline.zig` "after population growth, ~2 solid contacts per body on the multi-worker path allocate nothing" and "... ~2 trigger contacts per body ..." (`runContactBoundScenario`). A 1×1 world: 31 chain bodies plus the player grow the tracked capacity 4 → 64 through `syncPopulationCapacity`, and 32 more fill it with no second growth. That is 117 contacts over 64 bodies. A real 2-worker pool at 16-item ranges (broadphase and narrowphase not inline) runs one `pipeline.update` with every owner on a uniform `FailingAllocator`: 0 allocations, 234 solid intents or 117 trigger events, and no pair-bound overflow. Each test fails with its reserve reverted, all three confirmed: with the old estimate in `prefix` from `mergeNarrowphaseContacts`; with only the response reserve reverted in `ensureIntentCapacity`; with only the trigger stream reverted in the trigger stream's `prefix`.
    - `collision.zig` "candidate pairs past the reserved pair bound are counted, even inside the physical slack": `reserve(4)` declares 16 pairs, and 8 overlapping bodies make 28, inside `candidate_pairs`' rounded-up capacity. Each serial and `update` step counts once, the contacts match an unreserved run, an unreserved system never counts, and `reserve(8)` (32) stops the count.
    - `collision.zig` "a contact stream reserved for a body capacity holds the pair bound".
  - Bench: `collision`, `collision-sparse`, `collision-response-mixed`, `collision-response-solid` (no-regression gate; recorded above, every formal breach re-measured interleaved as noise). Memory +1.57 MiB at 2053 bodies.
  - **Review follow-up (review of `c9496b8..c4c5677`).**
    - **M · Broadphase slots reserved per item, slot growth counted.** `reserve` sized slot r to `estimateBroadphasePairCapacity(cap, ceilDiv(cap, r + 1))`, clamped to `cap`. So range 0 of a 2-range partition (`cap / 2` items) held 2 pairs per item, and range 0 of a 3-range one held 3. At 2–4 pairs per body the slot grew and the broadphase replayed in-stage, uncounted, because `countPairBoundOverflow` checked only the total against `4 × cap`. Slot r is now `broadphasePairBound(ceilDiv(cap, r + 1))`. Range r of any partition covers ≤ `ceilDiv(cap, r + 1)` items, so a scene with ≤ 4 pairs per swept item in every range is allocation-free under every partition. `BroadphaseBuildResult.grew` / `BroadphaseStats.grew` report a warmed unreserved slot, a slot grow-and-replay or a serial candidate-list replay. `countPairBoundOverflow(count, grew)` counts a reserved step once if it is past the total or grew. `CollisionStats.pair_bound_exceeded` and `pair_bound_overflows` now cover both cases. The kept shape is per-range slots, not the cheaper shared buffer with per-range windows (memory and reasoning in the record above).
    - **L1 · Growth rollback restores the declared pair bound.** If `growPopulationCapacity` failed after `collision.reserve(body)` (e.g. in `reserveContactStreams`), it restored `movement_body_capacity` but left `collision.reserved_pair_bound` raised over streams that were never sized. The errdefer now restores it too.
    - **L2 · Past-bound identity on the multi-worker path.** The past-bound test ran only with 0 workers. A real 2-worker variant was added.
    - Tests (M and L1 each fail with the fix reverted, confirmed):
      - `collision.zig` "after reserve, 2- and 3-range broadphase partitions at ~3.9 pairs per body allocate nothing". 96 bodies in a row, each overlapping its next four, give 374 pairs, exactly 4 per item in every range but the last. A real 2-worker pool runs 48-item (2 ranges) and 32-item (3 ranges) partitions under `FailingAllocator`: 0 allocations, contacts equal to serial, no overflow. Fails on the clamped slot reserve.
      - `collision.zig` "a broadphase slot replay within the total pair bound is counted". 64 bodies at a 64-body reserve (256-pair bound) in 2 ranges: 32 isolated bodies, then a 32-body cluster of 171 pairs, past slot 1's 128. The first step counts 1 with contacts equal to serial; the grown slot then counts nothing. Fails with the replay uncounted.
      - `collision.zig` "candidate pairs past the reserved pair bound are counted once per step on the multi-worker path" (L2). `reserve(32)` gives a 128-pair bound; 32 bodies make 145 pairs over 2 ranges of 16. Step 1 is past the bound and also replays slot 1 (65 pairs over 64), and counts once. Step 2 is past the bound only, and counts again. Contacts equal serial. This adds coverage; it passes on the old code.
      - `simulation_pipeline.zig` "a population growth that fails after the collision reserve restores the declared pair bound" (L1). The response allocator fails, so growth 4 → 64 errors in `reserveContactStreams`. `movement_body_capacity` and `reserved_pair_bound` both read their old values, and the retry raises both. Fails with the errdefer line removed (expected 16, found 256).
- [ ] **D1 · Inverted destructible resolve** (§D1).
  - Tests in `destructible_controller.zig`:
    - 300 crates (minimal world, one per cell): a cell interact hits the crate at dense index 299, which fails today;
    - the tie-break, multi-hit, no-intent and FailingAllocator (`:673`) tests are unchanged;
    - an AABB spanning 4 cells is matched by intents on each of its cells;
    - two intents on the same cell both resolve to the same lowest-(index, generation) crate.
  - New bench group `destructible-resolve` (`src/benchmarks/destructible.zig`, registered): items = crates {64, 256, 1024, 10000}, with 8 fixed cell intents per step. Gate: no regression at {64, 256}; record 1024 and 10000.
  - Cross-edits: 61, 63 and 71D as in §D1.
- [ ] **D2 · World-extent spatial window and clamp stat** (§D2).
  - Tests in `spatial_index.zig`:
    - `capacity_cells_x/_y == min(ceil(W/cs) + 1, halo formula)` for a world smaller and a world larger than the halo, with no world built;
    - a 1×1-tile fixture reserves 2×2 cells;
    - a population spanning the full world on both edges builds with `dense_window_clamped == 0`;
    - the skip test (`:1508`) asserts `dense_window_clamped == 1`;
    - after `reserve`, a serial and a real multi-worker build of a world-filling population allocate zero times under FailingAllocator;
    - the formula tests at `:1455-1506` are rewritten, and the 4096² test is kept until Slice 60.
  - Cross-edit: `slice-60.md:169-187, 387, 493`.
  - Bench: `spatial_index`, `ai`, `perception`, `footprint-spatial` (memory).
- [ ] **D3 · Exact LOS visit limit** (§D3).
  - Tests:
    - a minimal world with `tile_size = 8`: a clear 400-unit diagonal ray is visible (blocked today);
    - the existing LOS and DDA parity tests are unchanged;
    - the same ray on a 16×16 and a 64×64 world gives the same result;
    - `grep -n los_max_cells src/` is empty.
  - Bench: `perception`, `perception-los-dense`.
- [ ] **D4 · AI scan radius from the live cell size** (§D4).
  - Tests: an index built at `cell_size = 16` lets separation find a 40-unit neighbor. Existing parity tests are unchanged.
  - Bench: `ai`.
- [ ] **E1 · Shrink keeps accepted work** (§E1).
  - Tests: a shrink with `pending.len` above the derived target drops nothing (`resize_dropped == 0`). Add assertions to `system.zig:4310, 4369, 4400, 4432`.
  - Bench: `pathfinding`, `pathfinding-drain`.
- [ ] **E2 · Preserving resize** (§E2).
  - Tests in `caches.zig`:
    - `resizePreserving` grow and shrink keep every entry's key and path cells, with re-insert order ascending by old slot (compare the probe layout with a fresh insert in that order);
    - shrink compacts stripes correctly.
  - Tests in `system.zig`:
    - a grow keeps every completed entry (same path cells), every unavailable key and every pending key;
    - a shrink with live cache entries above the derived target keeps them all;
    - after warmup the steady state allocates nothing (existing proof).
  - New bench group `pathfinding-elastic-ramp` (`src/benchmarks/pathfinding.zig`): items = final agents {512, 2048}, doubling from 8 every 8 steps toward a fixed goal set. `output_count` = total solves.
  - Gate: solves after ≤ before at every count, plus no mean-step regression. Also run `pathfinding`, `pathfinding-shared-goal`, `pathfinding-cache-open`, `pathfinding-cache-detour`, `pathfinding-cache-unreachable`.
- [ ] **E3 · `NegativeCache`** (§E3).
  - Tests:
    - an entry expires at TTL, and with `ttl == 0` it never expires;
    - a full cache evicts in round-robin order instead of refusing;
    - it survives `resizePreserving`;
    - `caches.zig:738`, `:876` stay valid for `pending_keys`;
    - the negative-cache tests in `system.zig` re-run.
  - Bench: `pathfinding-cache-unreachable`, `pathfinding-hard-fallback`.
- [ ] **E4 · Edge-cap fallback without a version bump** (§E4).
  - Tests:
    - `system.zig:4213` now expects `version_bumps == 0` after a forced fallback, and a cached path that does not cross the batch spans survives and equals a fresh solve on the rebuilt graph;
    - `nav_graph.zig:2812-2860` splits the expectations for edge-cap fallback and full relabel.
  - Cross-edit: in `slice-65b.md`, the lane-job "On a full relabel or fallback, bump version" text and its fallback-equivalence case.
  - Bench: `nav-update-scattered`, `nav-update-multichunk`, `nav-update-links`, `pathfinding`.
- [ ] **E5 · Group tally sized from intake** (§E5).
  - Tests: a step with `max_solved_requests_per_step + 1` distinct shared goals tallies all of them in the same step. The group-field tests (e.g. `:1937`) re-run.
  - Bench: `pathfinding-group-field-detour`, `pathfinding-group-field-detour-moving`, `pathfinding-group-field-detour-moving-hysteresis`.
- [ ] **E6 · Initial agent count** (§E6).
  - Tests:
    - `reserve` with initial 40 gives `effective_agent_capacity == derive(40)`;
    - the first update at 40 agents allocates nothing (FailingAllocator);
    - the `proceduralPathfindingCapacity` test in `game_demo_state.zig` is updated.
  - Bench: `pathfinding`, `footprint-nav` (the step-1 allocation moves to load).
- [ ] **E7 · `solved_paths` slots isolated per worker** (Batch A review follow-up).
  - What: `PathfindingSystem.solved_paths` (`system.zig:96`, `SolvedPath` at `:176`) is written by solve workers at `solve.zig:633`, `:654` (`recordPath`, `recordStartLevelPrefix`) and `:675-676` (`recordStitched`), indexed by `pending_index`. Records are 8-byte aligned and not a whole number of lines, so neighbouring requests solved by different workers write the same line.
  - Why: false sharing on every solved request in a threaded batch. The same effect regressed threaded solves through `SearchScratch` in A4.
  - Fix shape: wrap the record in a padded slot (`SolvedPathSlot { path: SolvedPath, _pad: [threadSharedRecordPadding(SolvedPath)]u8 }`) stored in an `ArrayListAligned(…, thread_shared_record_alignment)`, with a comptime `assertThreadSharedRecord` (Slice 65A's helper, or the module-local copy plus the size assert if 65A has not landed). Alternative if the bench prefers density: index by the dense fallback position, so each range writes a contiguous run and only range boundaries share a line, and pad only those boundaries. Choose by the bench.
  - Tests: comptime layout assert; `@intFromPtr(&slots[1]) - @intFromPtr(&slots[0])` is a multiple of 64; the threaded-solve parity tests (`system.zig`, real multi-worker `ThreadSystem`) give the same paths as serial; the steady-state FailingAllocator proof still allocates nothing.
  - Bench: `zig build -Doptimize=ReleaseFast bench -- --group pathfinding --items 512` and `pathfinding-drain`, threaded rows, 3+ runs before/after; no serial regression.
- [ ] **E8 · Worker path/stitched pool stripes start on a line** (Batch A review follow-up).
  - What: `worker_path_pool` (`system.zig:101`, `u32`) and `worker_stitched_pool` (`system.zig:105`, `StitchedCell`) are carved into per-request stripes of `max_stored_path_cells` / `max_stitched_path_cells` entries (`solve.zig:624-626`, `:670-673`). Neither the pool base nor the stride is line-aligned, so the last line of one worker's stripe is the first line of the next worker's.
  - Why: false sharing at every stripe boundary while workers reconstruct and copy paths.
  - Fix shape: round each stride up to a whole number of 64 B lines (`stride_entries = alignForward(stride * @sizeOf(T), 64) / @sizeOf(T)`), keep the logical stride as the downsample/stitch bound (`recordPath` and the cache still cap at `max_stored_path_cells`), and back both pools with `ArrayListAligned(…, thread_shared_record_alignment)` so the base is aligned. `resizeFilledArrayList` gains an aligned variant. The padded stride is a layout bound, not a behavior input.
  - Tests: every stripe offset is a multiple of 64 bytes from an aligned base; stored path lengths and contents are unchanged against the unpadded layout (plain, downsampled and stitched solves); the FailingAllocator steady-state proof is unchanged.
  - Bench: as E7 (`pathfinding`, `pathfinding-drain`, `pathfinding-hard-fallback`), plus `footprint-nav` for the padding cost (at most one line per solved slot per pool).
- [ ] **F1 · Exact nav reserves** (§F1). Lands after the 64E nav-dirty item.
  - Tests:
    - on a 1-level, 1-chunk minimal world after a nav build: `capacity == len` for `blocked`, `components`, `cell_to_portal`, `portals` and `SearchScratch.cells`, and ResultCache path and stitched capacity equal logical × stride;
    - `types.zig:978` still holds;
    - every steady-state FailingAllocator proof re-runs (`system.zig:1937, 2334, 2455, 3392, 4012, 4041, 4088`; `nav_graph.zig:2599, 3605, 3648, 3751`), and any new allocation is fixed by a reserve at the owning seam.
  - Bench: `nav-update-*`, `pathfinding`, `footprint-nav` (memory).
- [ ] **F2 · Accurate gate terms** (§F2).
  - Tests:
    - update the expected values in `nav_memory.zig:277-450`;
    - add `test "requiredBytes equals the reserved bytes of a built minimal world"` (1 level, 1 chunk, 1 participant), comparing `requiredBytes` with the summed reserved capacities.
  - Record `autoSizedMaxNavMemoryBytes` before and after in Status.
  - Bench: `footprint-nav`.
- [ ] **F3 · Exact dense world arrays** (§F3).
  - Tests in `world_system.zig`:
    - a 16×16-tile, 3-level fixture (`initDemoFromMetaWithUnderground`) gives `dense_tile_ids.capacity == levelCount() * 256` and `dense_layers.capacity == levelCount()`;
    - a 1-level world gives capacity == 256;
    - the `addDenseLayer` FailingAllocator test (`:3944`) still passes.
  - Bench: `footprint-world` (memory and load time); `render-game-prep-dense-deep` (no regression).
- [ ] **G1 · Tier-1 scratch per escalated ordinal** (§G1).
  - Tests:
    - an escalated long corridor lands in a long stripe and is published whole;
    - participant abstract capacity equals the tier-0 caps;
    - `system.zig:3392` (warmed cross-level no-alloc) and `:3259` (escalated cap) are updated;
    - the threaded FailingAllocator solve proof (`:2334`) passes;
    - the `nav_memory` abstract-term tests are updated.
  - Bench: `pathfinding-escalated-detour`, `pathfinding-hard-fallback*`, `pathfinding`, `footprint-nav` (memory).
- [ ] **G2 · Two-pool result cache** (§G2).
  - Tests:
    - a tier-1 result longer than 512 cells is stored whole and served;
    - the long pool evicts the oldest stamp, then the lowest index;
    - the Debug assert holds when the pool is sized at E × ttl;
    - with `ttl == 0` the long pool is sized to `max_cached_results`;
    - the `caches.zig` tests (`:754-1100`) are updated, and the expected bytes in `nav_memory.zig` (`:344`, `:410`) are updated.
  - Bench: `pathfinding-cache-*`, `pathfinding-escalated-detour`, `footprint-nav` (memory).
- [ ] **G3 · `PathfindingCapacity` split** (§G3).
  - Tests:
    - fixtures compile without the derived fields;
    - `system.zig:4310-4470` reads `capacity_derived`;
    - the budget tests in `nav_memory.zig` pass.
  - Bench: `steering`, `pathfinding` (no change).
- [ ] **H1 · Static streams at the reservation** (§H1).
  - Tests: a headless unit test of `staticStreamTargetVertices` for reserved > needed, needed > reserved, and the zero-reserve doubling path. `gpu-smoke` is unchanged.
  - Bench: `render-game-prep-dense-surface`, `render-game-prep-dense-deep`.
- [ ] **H2 · Geometric tile-edit transfer** (§H2).
  - Tests: a headless test of `tileEditTransferTargetBytes`, including the overflow case that returns `error.GpuBufferTooLarge`.
  - Bench: `render-game-prep`.
- [ ] **H3 · Warmed tile-edit upload proof** (§H3).
  - Test in `renderer.zig`, `"warmed uploadTileDataEdits stays allocation-free"`:
    - uses `testRenderer` and a private helper that registers a fake buffer handle (`@ptrFromInt`, never dereferenced) plus params and count directly into `tile_data_buffers`, `params` and `counts`. That is a local fixture, not a production hook;
    - warm with N sorted edits, then simulate the copy-pass clear;
    - with `FailingAllocator(fail_index = 0, resize_fail_index = 0)` on `renderer.allocator`, re-upload N edits with zero allocations;
    - a variant uses a carried overlapping batch, covering `replacePendingStorageRegion`;
    - teardown frees the lists without an SDL release.
  - Bench: n/a (test only).
- [ ] **H4 · Growth without a GPU drain** (§H4).
  - Tests: none headless. `zig build gpu-smoke` passes on every backend available to the owner, and each backend is recorded in Status.
  - Bench: `render-prep` (CPU, no change).
- [ ] **I1 · Perception events from columns** (§I1).
  - Tests:
    - serial and threaded parity is unchanged;
    - new FailingAllocator variants in `perception.zig:3284-3495`: after `reserve`, two `items_per_range` values on a real 2-worker pool allocate zero times;
    - drop the event-slot reserve expectations;
    - remove `PerceptionEventRangeSlot` from 65A's comptime assert list (cross-edit `slice-65a.md`).
  - Bench: `perception`, `perception-scattered-dense-index`, `perception-los-dense`.
- [ ] **I2 · Affect crossings from bits** (§I2).
  - Tests:
    - tests that pin crossing order are updated to (row, drive);
    - serial == threaded parity;
    - new FailingAllocator variants in `affect.zig:1258-1310` (after reserve, multiple partitions);
    - the checksum/replay grep is recorded in the commit;
    - remove `AffectEventRangeSlot` from 65A's comptime list.
  - Bench: `ai-affect`.
- [ ] **J1 · `StateTransitions` budget first** (§J1).
  - Tests: `state.zig:1638` calls `reserve()` and still loops to `max_requests`; `reserve()` never changes `max_requests`. Update `engine.zig:128`.
  - Bench: n/a (init only).
- [ ] **J2 · `FpsCounter` bound assert** (§J2). Tests: comptime only. Cross-edit `slice-67b.md:124-125`.
- [ ] **J3 · `window_slot` width assert** (§J3). Tests: comptime only.
- [ ] **J4 · MAL alignment doc** (§J4). Doc only.
- [ ] **K1 · `SimulationEvents.capacity_limit` justified.** The doc comment at `simulation.zig:245` states that:
  - the limit is the exhaustive producer sum (B1) and follows population (C3, C4);
  - a required-append failure therefore means a producer exceeded its declared budget, which is a bug.

  B1's comptime walk and C3's zero-drop test cover it.
- [ ] **K2 · Pending-queue backpressure justified** (pathfinding-11, `system.zig:1137-1164`).
  - Doc comment: deterministic backpressure gated on the logical `max_pending_requests`, which follows the live agent count.
  - Test, if none exists: submitting `max_pending + 3` distinct keys drops exactly 3, the accepted set is the first `max_pending` in request order, and dropped agents re-request on `.missing`.
- [ ] **K3 · Interior link slots K = 8 justified** (pathfinding-27, `types.zig:131-140`). The doc names it a layout bound: slot ids are a pure function of the dimensions. Confirm that 64E's ninth-interior-ramp refusal test pins the counted refusal.
- [ ] **K4 · Particle pool justified** (gameplay-systems-29, `particle.zig:330-339`).
  - Doc: presentation-only; refusal is in emission order against the logical `capacity`; particles never feed simulation state.
  - Test, if none exists: emitting past capacity refuses and counts, and existing particle order is unchanged.
- [ ] **K5 · Collision-SFX cooldown table justified** (gameplay-systems-36, `audio_controller.zig:26-35, 126-172`).
  - Doc: an audible-concurrency budget and audio policy only.
  - Test, if none exists: with 33 cooling pairs, the entry with the least remaining time is evicted deterministically.
- [x] **K6 · Owned-elsewhere sites carry an owner pointer.** Landed 2026-10-06 with the owners' items: the 64E nav-dirty and link-growth items, the 71B.1 capacity-audit follow-up, and the 68A `reserveAiRowMap` note.
  - `slice-64e.md:376-430`:
    - the nav-dirty item names Slice 72 B1 as its prerequisite and C3's re-run of `reserve`;
    - the link-growth item lists the extra sites from world-data-world-02: the `level_link_limit` field comment (`world_system.zig:304-307`), the `demoLevelLinkLimit` doc (`game_demo_state.zig:210-214`, which becomes "initial reservation"), and the `hasLevelLinkRoom` callers that re-admit after a grow.
  - `slice-71b.md:180-192`: C3's `raiseAgentBudget` composes with the content-sized ceiling.
  - `slice-68a.md:143-146`: `reserveAiRowMap` also runs through C3's sync.
- [ ] **X1 · Docs.**
  - `docs/architecture.md`: the population growth seam (`syncPopulationCapacity`), the event-bound owner, J4.
  - `docs/simulation-tiers-and-pipeline.md`:
    - the Events section names the producer table as the bound;
    - Structural Commands and Post-Commit Reactions add the sync step;
    - the Slice 45 consumer paragraph describes the inverted resolve.
  - `docs/rendering-assets-shaders.md`: `drawSprite` growth and its counter (landed with A2); GPU growth without an idle (after H4).
  - `docs/coding-standards.md` Allocator discipline gets the rule: "behavior gates compare stored logical limits, never `.capacity`" (coding-standards rule landed with A3).
  - Add the Slice 72 row to the roadmap index's Open Frontier table, plus a Suggested Order entry ("72 — any time; Batch A first").

### Acceptance checks

- [ ] `zig build verify` passes, and `zig build test` passes in Debug and ReleaseFast.
- [ ] Grep gates are empty:
  - `SpriteCommandOverflow`, `destructible_cell_scan_budget`, `los_max_cells`, `event_reserve`, `perception_event_reserve`, `affect_event_reserve` and `demoCognitionAgentCount` under `src/`;
  - `grep -rnE "items\.len >= [a-z_.]*\.capacity([^._a-zA-Z0-9]|$)" src/game/systems/pathfinding/` (the trailing class excludes the correct logical gate `self.pending.items.len >= self.capacity.max_pending_requests`, the K2 site, which the unanchored regex also matched; the remaining physical `.capacity` reads in the package, `system.zig`'s append-or-grow choice, the `effectiveSolveLimit` clamp and `reconstructLocalPath`'s Debug assert, are not behavior gates);
  - `std.debug.assert(pending_carves`.
- [ ] Every capacity-dependent-behavior site is either fixed or justified at its site:
  - A1, A2, A3, A4, B1, C3, C4, D1, D2, D3, E1–E5, J1 are fixed;
  - K1–K5 are justified;
  - world-data-world-02, gameplay-systems-31, pathfinding-26 and pathfinding-34 carry owner pointers (K6).
- [ ] Bench gate under the protocol above: every group named in the batch table stays within max(3%, spread), with one Status table per batch. The new groups record their baselines:
  - `destructible-resolve`: {64, 256} gated; 1024 and 10000 recorded;
  - `pathfinding-elastic-ramp`: total solves after ≤ before at 512 and 2048;
  - `footprint-*`.
- [ ] Memory comparison from `footprint-*` on the small (16, 3 levels, 32 movers), shipped (256, 32 levels, 2048 movers) and large (512, 32 levels, 2048 movers) instances, before and after, recorded in Status:
  - D2: `footprint-spatial` window bytes ≤ 0.15 × before on shipped (about 0.53 MB vs about 4.7 MB).
  - F1: the nav-array portion of `footprint-nav` ≤ 0.75 × before on shipped and large.
  - F3: `footprint-world` dense bytes equal levels × cells × 2 B exactly, and `peak_bytes` drops on shipped and large.
  - G1 + G2: `footprint-nav` result-cache plus abstract-scratch bytes ≤ 0.45 × the post-F1 value on shipped at 2048 movers.
  - Small instance: recorded only, because fixed floors dominate.
- [ ] `zig build gpu-smoke` passes on each available backend after H1, H2 and H4 (display-gated). The backends are listed in Status.
- [ ] All cross-slice edits named in B1, C3, C4, D1, D2, E4, I1, I2, J2 and K6 have landed in the same change as their item. (K6 landed 2026-10-06.)
