> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none (batch order is internal, see the batch table; Batch F lands after the [Slice 64E](slice-64e.md) nav dirty-buffer capacity item, which needs B1) · Track: [VoidLight port](../tracks/voidlight-port.md)

## Slice 72: Live Capacity Sizing Pass

**Status:** in progress — Batches A, B, C and I landed (with C7, K3 and K6); Batches M, D–H and J, plus K1, K2, K4, K5 and X1, are open (Batch F is unblocked).

**Goal.** The 2026-10-06 capacity audit sized the *planned* slices. This slice applies the same engine practice to every capacity in the *live* `src/` tree. For each data structure, the question is what an experienced engine programmer would do and why. The default answer is to keep it; a change lands only when its concrete benefit outweighs its cost and risk.

Success criteria:

- **Behavior.** No live behavior (iteration order, deferral, refusal, drops, truncation, cache flushes, query reach) depends on a physical `.capacity`, on allocation history, or on a load-time pool that runtime growth can outrun. The exceptions are named work budgets, layout bounds, presentation budgets and load-time platform validation (`max_nav_memory_bytes`, the dense GPU byte budget), each justified at its own site (Batch K); there is no runtime memory ceiling.
- **Population.** Population-sized capacities grow at one point, the main-thread structural-commit seam, geometrically and ahead of need. Hot paths stay allocation-free between growth points, proven by `std.testing.FailingAllocator`.
- **World extent.** Storage follows content and residency; nothing is sized to a level's area or a world's extent (`.claude/rules/budgets-capacities.md`).
- **Assumed capacity.** No `appendAssumeCapacity` is protected only by a Debug assert.
- **Memory.** Memory savings are measured on a small, the shipped, and a large world instance.

In scope: the changes below, the per-site justification of the capacity-dependent sites that are kept, and the cross-slice text edits those changes require. Out of scope (each has a named owner): level-link growth and nav dirty buffers ([64E](slice-64e.md)); the deferred-nav plan buffers and the `markStaticBodies` map ([65B](slice-65b.md)); the content-sized `max_agent_budget` ([71B](slice-71b.md) 71B.1); retiring the stacked-UI headroom ([53B](slice-53b.md), then [60](slice-60.md)); the zoom-band half of the spatial window ([60](slice-60.md)); the perception `pending_dirty` bound ([64B](slice-64b.md) B3); `arbitration.behavior_count` ([61](slice-61.md)); `DataSystem.reserveComponentRows` ([62](slice-62.md)).

### Current foundation

- `DataSystem` component stores are dense `std.MultiArrayList` SoA; rows are added with an all-or-fail geometric preflight at the structural-commit seam (`data_system/structural.zig:541-635`); the slot map uses a LIFO free list with `u32` generations.
- `SimulationEvents` has a per-step `capacity_limit`: required appends fail before any mutation, diagnostic appends drop and count, and `ensureEventAppendCapacity` is the preflight. `RangeOutputStream` grows only at the main-thread prefix.
- **Population seam (C3).** `SimulationPipeline.syncPopulationCapacity(frame, data)` runs in `GameDemoState.applyStructuralCommandsAndPostCommitEvents` after `applyStructuralCommandsBudgeted` and before `reactToPostCommitNavEvents`. Its fast path is a few store-length compares. Its slow path moves each outgrown count to `hotStoreCapacity(rows + rows / 2 + movement_range_alignment_items)`, re-runs the grow-only reserves (scope, `spatial_index.reserveRows` (the window is touched only by `reserveWindow`), steering, collision, dig plane scratch, frame streams), then `reserve(frame, new_cap)` (the event limit plus 64E `reserveNavDirty`, 68A `reserveAiRowMap` and 56B's bitset), then `pathfinding.growForAgentCount`. A ceiling overrun calls `raiseAgentBudget`, which is never refused; an OOM keeps the old ceiling and the next seam retries. Pathfinding shrink stays in `beginUpdate` with its hysteresis.
- **Event bound (B1, C4).** `EventProducerId.maxEventsPerStep` is the exhaustive bound; `eventCapacitySum()` sizes `capacity_limit` and the shared `range_count`. `.structural_commit` is a fixed per-step share in events (`structuralEventHeadroom`), enforced on its own by the budgeted commit; `.nav_reaction` is 1. Perception and affect shares are 2 × AiPerception rows and drive count × AiAffect rows.
- **Per-range outputs (C5, C6, I1, I2).** One-record-per-item outputs write `[range.start, range.end)` windows of one item-capacity buffer with `maxRangeCount`-sized padded tallies. The broadphase keeps per-range slots reserved to `broadphasePairBound(ceilDiv(cap, r + 1))`; contact streams and the response reserve to the pair bound (4 per body) in `reserveContactStreams`, and past-bound steps count in `collision_pair_bound_exceeded`. Perception and affect emit events on the main thread after the join from per-row columns and bits.
- **Pathfinding.** The elastic resize runs on the main thread before dispatch (`pathfinding/system.zig:315-377`). Intake and search spill compare logical limits (A3, A4). `SearchScratch` aligns to the 64 B `thread_shared_record_alignment`. `types.ListResize(T)` makes `ProbeTable.reserve` and `ResultCache.reserve` failure-atomic, and `applyDerivedCapacity` commits limits only after every pool resizes.
- **Render.** Reservations are grow-only with a high-water mark (`reserveSpriteCommands`, `ensureFrameBatchCapacity` before the only threaded phase). `drawSprite` grows past capacity (A2); drift accounting is the comptime-gated `SpriteBatch.ReservationDrift`.
- **Spatial index.** `DenseCellLookup` already supports non-square windows (`capacity_cells_x/_y`, `spatial_index.zig:136-183`); the clamp-and-skip guard is at `:718-748`.
- `AudioCommandBuffer` is the budget-first queue pattern (`app/audio.zig:92-114`, `:169-182`): the budget sets capacity, and `reserve()` follows it.
- Capacity items owned by other slices are not repeated here: 64E nav dirty buffers and level-link growth (landed), 65B "Load-time capacities", 71B "71B.1 capacity-audit follow-up" (landed), 64B "B3 perception cache bound", 60 "Spatial-index dense window", 53B "Stacked-UI headroom retired".
- Bench procedure: `.claude/rules/tests-benchmarks.md`.

### Architecture notes

**Pipeline placement.** No `stage_order` or `PipelineResource` change: `syncPopulationCapacity` runs at the commit seam (`merge_outputs`, main thread) outside `stage_order`; D1's resolve stays inside `action_react` with an unchanged contract; perception and affect write `events` inside their own stages. `stageContract()` is untouched.

**Growth points** (`.claude/rules/memory-performance.md`, `.claude/rules/budgets-capacities.md`). Population-sized storage grows in `syncPopulationCapacity`; world-extent storage is sized exactly at load (F1, F3, D2); per-frame render storage grows on the main thread before the threaded emit (A2, H). Every re-run reserve is grow-only and a no-op at an unchanged size. Gates use stored logical limits: std 0.17 `ArrayList.growCapacity(n) = n + n/2 + cache_line/@sizeOf(T)` and `MultiArrayList.resize` round capacity up, and shrink hysteresis keeps the slack.

**Diagnostics.** New growth and drop counters log once through `logging.game` or `logging.render` (`.claude/rules/zig-style.md`); each counter is also a perf metric.

**Memory measurement (M1).** `src/benchmarks/capacity_footprint.zig` adds `footprint-world`, `footprint-nav` and `footprint-spatial`. Each wraps its fixture in a private byte-counting allocator and reports `reserved_bytes` (live after build), `peak_bytes` (during build) and the build time in `mean_ns`. Items are the world side in tiles, {16, 256, 512}: a 16-tile world has 3 levels and 32 movers; 256 and 512 have 32 levels and 2048 movers. Nav uses 16 fixed participants so results are machine-independent; `footprint-nav` reports after the nav build plus one pathfinding update with every mover requesting, so the elastic result cache is counted.

**Batch plan.** Each batch lands on its own, in table order; an item is checked off with its tests and its bench run. Work under "Owned by other slices" is not part of this slice's completion.

| Batch | Items | Priority | Lands after | Gate benches |
|---|---|---|---|---|
| M | M1 | enabling | — | new `footprint-*` (baseline before D2/F/G) |
| A | A1–A4 (landed) | high | — | `render-prep`, `render-game-prep`, `pathfinding*` |
| B | B1 (landed) | high | — | `perception`, `ai-affect` |
| C | C1–C7 (landed) | high | B | collision, steering, scope, spatial, AI groups |
| D | D1 D2 D3 D4 | high (D3 medium, D4 low) | M (D2 memory) | new `destructible-resolve`, `spatial_index`, `ai`, `perception`, `perception-los-dense`, `footprint-spatial` |
| E | E1–E8 (E4 superseded) | high (E3, E6 medium; E5, E7, E8 low) | — (E2 before E3) | `pathfinding`, `pathfinding-shared-goal`, `pathfinding-drain`, `pathfinding-cache-*`, `pathfinding-group-field-detour*`, `nav-update-*`, new `pathfinding-elastic-ramp` |
| F | F1 F2 F3 | high (F2, F3 medium); memory | M; F2 after F1 | `nav-update-*`, `pathfinding`, `footprint-world`, `footprint-nav` |
| G | G1 G2 G3 | medium (G3 low); memory | F1, E2 | `pathfinding-escalated-detour`, `pathfinding-hard-fallback*`, `pathfinding-cache-*`, `pathfinding`, `footprint-nav` |
| H | H1 H2 H3 H4 | medium (H1, H4 low) | A2 | `render-prep`, `render-game-prep`, `render-game-prep-dense-surface`, `render-game-prep-dense-deep`; `gpu-smoke` |
| I | I1 I2 (landed) | medium | C4 | `perception`, `ai-affect` |
| J | J1 J2 J3 J4 | low | — | none (comptime, init or doc only) |
| K | K1–K6 (K3, K6 landed) | justify | B, C | none |

#### Pathfinding (`src/game/systems/pathfinding/`)

**E1 and E2. Elastic resizes keep live work and cache entries** (pathfinding-04). `system.zig:243-296, 315-377`; `caches.zig:61-74, 294-327`.

- **Now:** every grow or shrink re-reserves `completed` and `unavailable`, wiping them (9 doublings on an 8 → 4096 ramp), which forces re-solve storms (capped at 512 per step) and different motion; a shrink drops pending work past the new cap (`resize_dropped`). Since C3 the grow-time wipe happens at the commit seam, a deterministic one-step shift in path availability on growth steps.
- **E1 (first):** the shrink target is `max(derived, pending.len, group_requests.len)`, capped at `max_agent_budget`; a shrink never drops accepted work.
- **E2:** add `ProbeTable.resizePreserving` and `ResultCache.resizePreserving(allocator, new_logical)`. Grow: payload, `path_cells` and `stitched` columns grow in place, precisely; the stride is unchanged so every `payload_index` stays; new payload indices go on the free list ascending; a new 2× probe table re-inserts occupied slots in ascending old-slot order. Shrink: the caller guarantees `new_logical ≥ live` (cache target `max(derived, completed.len, unavailable.len)`); live entries compact to `[0, live)` in ascending old-slot order, columns `shrinkAndFree`, and the free list and probe table rebuild ascending. `unavailable` and `pending_keys` use `ProbeTable.resizePreserving`. A cache wipe on shrink is not acceptable: it changes outcomes.

**E3. Negative cache with TTL and eviction** (pathfinding-10; after E2). `system.zig:259, 848, 1466`; `caches.zig:103-122, 167-197`. Today `unavailable` is a `KeySet` with no expiry; when full, new definitive negatives are refused and re-solve on every request. Add `NegativeCache`: a `ProbeTable` with a `u32` stamp payload and logical capacity `max_cached_results`; `contains` treats `step - stamp >= ttl` as a miss with the same `ttl == 0` rule as `ResultCache.freshSlotIndex`; a full cache evicts round-robin over occupied physical slots (the `findOrEvictSlot` cursor policy); it uses `resizePreserving`. `pending_keys` stays a `KeySet`.

**E5. Group tally sized from per-step intake** (pathfinding-12). `system.zig:265-266, 368, 1171-1192`; `caches.zig:199-240`. Today capacity is `min(512, n)` from the solve budget, so a new shared goal's tally can wait a step. Size `group_requests` and `group_key_map` to `max_frame_requests`, widen the `GroupKeyMap` payload to `u32` (71B makes intake content-sized, so a `u16` assert would be a load refusal), and clamp `keep_group` to the new logical cap.

**E6. Initial elastic capacity from the loaded population** (pathfinding-05). `system.zig:231-236`; `game_demo_state.zig:220-256, 370`. `reserve` starts at the floor of 8, so the first battle step grows to 2048 in `pathfinding_update` (≈148 MB exact plus ≈9 MB of worker pools). Add `PathfindingCapacity.initial_agent_count` (default `min_capacity_floor`); `reserve` applies `max(floor, initial)`; the demo passes its load-time steering-agent count and the pipeline forwards it.

**F1. Exact reserves for exact-size and world-extent nav arrays** (pathfinding-01; after 64E nav-dirty, landed). `types.zig:873-909` (`setLen`, `resizeArrayList`, `resizeFilledArrayList`; `shouldShrinkCapacity` comment `:878-885`); `scratch.zig:90-94, 217-222`; one-shot reserves at `nav_graph.zig:498, 505, 523, 573-574, 588-589, 594, 598, 1180-1181`, `nav_grid.zig:85`, `caches.zig:320-321`, `system.zig:261, 285`.

- `ArrayList` paths use `ensureTotalCapacityPrecise`; a package-local `reserveExactMultiArray(list, gpa, n)` does `if (list.capacity < n) try list.setCapacity(gpa, n)` (std 0.17 MAL `setCapacity` always reallocates). The `shouldShrinkCapacity` comment names the real cause (std growth, not allocator size classes). Elastic pools keep their ≥ 2× policy at the resize point.
- A steady-state proof that starts allocating is fixed by an explicit reserve at its owning seam, never by restoring slack.
- Expected: about a third less nav memory (≈45 MB of fixed arrays on 256×256×32 with 16 participants, up to ≈75 MB more in the result cache at 2048 movers), so `max_nav_memory_bytes` bounds real memory.

**F2. Nav memory gate charges what load reserves** (pathfinding-37; after F1). `nav_memory.zig:105, 114-117`. Today it charges a `cells × usize` flood queue per level (real: `ct²`, ≈16.8 MB overcount on the demo), counts the local open heap at 1× (reserve is `× open_heap_headroom_factor`), and omits `stitched_scratch`. New terms: `per_level_bytes = cells × (4 + 2) + ct² × usize`; open heap `max(16, max_explored × open_heap_headroom_factor) × @sizeOf(OpenNode)`; plus `(max_stitched_path_cells + 1) × @sizeOf(StitchedCell)` per participant (tier-0 caps after G1). Derive each term from its reserve site with the `multiArrayRowBytes` pattern.

**G1. Tier-1 scratch sized once per escalated ordinal** (pathfinding-07/08). `scratch.zig:79-98`; `system.zig:289-295, 418-420`; `solve.zig:624-676`. Every participant reserves tier-1 abstract scratch (2×16384 slot table, 4×16384 heap, 16384 corridor: ≈2 MB each) and `worker_stitched_pool` gives each of 512 stripes a 2048-cell stride (8 MB), yet at most `max_escalated_solves_per_step` (E = 1) tier-1 solves run per step.

- `prepareFallbackIndices` assigns an escalated ordinal (an array parallel to `fallback_indices`, serial, fallback order) to each tier ≠ 0 item.
- Participant `AbstractScratch` and `stitched_scratch` reserve at `tier0_abstract_node_cap` / `tier0_stitched_cell_cap`; `PathfindingSystem` owns E tier-1 `AbstractScratch` and stitched buffers plus E long stitched stripes, indexed by ordinal; `solveOne` uses them when `request.tier != 0` (each ordinal belongs to one fallback item, so no worker pinning).
- `nav_memory` abstract term becomes tier-0 × participants + E × tier-1. Expected ≈2 → ≈0.5 MB per participant; worker stitched pool 8 → ≈2 MB.

**G2. Result-cache stripes sized to the common bound plus a long pool** (pathfinding-06; after E2). `caches.zig:252-327, 469-546`; `system.zig:258`. Each entry reserves a 512 × u32 plain stripe plus a 2048 × `StitchedCell` stripe (≈18 KB, ≈148 MB at 2048 movers; this drives `autoSizedMaxNavMemoryBytes`).

- The common stitched stripe uses `tier0_stitched_cell_cap` (512), ≈6 KB per entry. A long pool holds `max_escalated_solves_per_step × ttl` stripes at `max_stitched_path_cells`; with `ttl == 0` (no expiry, `caches.zig:449`) it is sized to `max_cached_results`, so capacity never evicts a live entry.
- A full long pool evicts the oldest stamp, then the lowest index; a Debug assert checks the victim satisfies `step - stamp >= ttl`. The entry records which pool and stripe hold its path. Update the `nav_memory` terms.
- Expected ≈148 → ≈54 MB at 2048 movers; the gate's ceiling term ≈296 → ≈100 MB.

**G3. Caller knobs separated from derived capacities** (pathfinding-38). `types.zig:26-35, 435-497, 509-522`; fixtures in `test_support.zig:70-82`, `simulation_pipeline.zig:1431-1438`, `benchmarks/steering.zig:62-69`. Five derived fields are settable but silently overwritten. `PathfindingCapacity` keeps only caller knobs (`max_agent_budget`, `initial_agent_count`, strides, budgets, chunk tiles, group-field config, memory ceiling); a private `DerivedCapacity` from `deriveCapacity` holds the five derived values. Delete the dead `default_*` constants and fixture assignments.

#### Gameplay systems

**D1. Destructible cell resolve reaches every row** (gameplay-systems-34). `destructible_controller.zig:31-36, 263-323`. Each cell intent scans only the first 256 dense rows, whose order depends on creation and swap-remove history, so on maps with more than 256 crates some cannot be hit. The shared `SpatialIndexSystem` indexes AI agents only (`spatial_index.zig:546-596`), so it cannot serve this. Two-phase resolve inside `process` (reads only `data`, `world` and merged intents, all const in `action_react`):

- **Phase A.** Collect each cell intent (target invalid, `has_cell`) into a fixed `[action_intent_live_capacity]` stack array of `(level, cell_y, cell_x, intent_ordinal)`, sorted by key.
- **Phase B** (only if A found intents). Walk `destructibleSliceConst()` once; skip rows dead or lacking `movement_body` and `collision_bounds` (level `worldLevelConst orelse 0`); compute the row's AABB cell span; if `span_cells × ceil(log2(I + 1)) < I` binary-search each span cell (lower bound, then equal keys), else test each intent cell directly. The existing `contains_center or overlaps_cell` predicate makes the final accept; each candidate updates that intent's best with the lowest-(index, generation) tie-break.
- `applyIntentDamage` runs in intent order with the pre-resolved targets; delete `destructible_cell_scan_budget`. Results equal today's whenever D ≤ 256.
- **Cross-edits:** slice-61's foundation text describes the inverted resolve; slice-63's merchant `.interact` resolve uses the same pass and deletes `merchant_cell_scan_budget`; slice-71d's merchant snapshot holds every live merchant row (sized from `MerchantStore` rows at state init, grown by C3's sync), built lazily once per update sorted by (level, cell) so the nearest query walks only cells within `ai_trade_query_radius`, and `ai_trade_merchant_capacity`, `ai_trade_merchants_truncated` and the "63 precedent" sentence are deleted.

**D2. Spatial-index window sized to the world, clamp made visible** (gameplay-systems-25, world-extent half). `spatial_index.zig:94-133, 160-183, 501-512, 684-754`; caller `simulation_pipeline.zig:690-694`; helpers `ai.zig:1417-1427`, `perception.zig:1742-1752`. The window is 768² cells (4.7 MiB, memset) on every instance including ≈115 1×1 test fixtures (the demo needs 257²), and a populated box wider than it is silently clamped and skipped.

- `DenseWindowGeometry` gains `world_extent_x: ?f32` and `world_extent_y: ?f32`; per axis `window_cells = min(ceil(world_extent_px / cell_size) + 1, current halo formula)` (+1 covers an in-bounds position exactly on the far edge). `SimulationPipeline.init` passes `bounds_width`/`bounds_height`; the `testSpatialIndex` helpers pass their fixture extent; the lookup uses `capacity_cells_x/_y`.
- Add counted `SpatialIndexStats.dense_window_clamped` (perf metric `spatial_dense_window_clamped`) with a once-per-session warn. Both constants and the 4096² ceiling test stay until Slice 60 replaces the halo term.
- **Cross-edit** slice-60's "Spatial-index dense window" item: Slice 72 lands the world-extent term (+1), the non-square sizing and the stat; Slice 60 keeps the band term and the constant deletion.

**D3. LOS visit limit from the ray's own length** (gameplay-systems-07). `perception.zig:143-153, 1426-1492`. `los_max_cells = 64` assumes 32-unit tiles, so below `tile_size ≈ 11.3` a full-range diagonal fails closed. After resolving `start_cell`/`end_cell`, use `const visit_limit: u32 = @abs(end_x - start_x) + @abs(end_y - start_y) + 1;` and loop `while (visited < visit_limit)`; keep the fail-closed return as the float-pathology guard; delete `los_max_cells`. Identical results on 32-pixel tiles.

**D4. AI scan radius from the live cell size** (gameplay-systems-03). `ai.zig:260-268, 277`. Comptime `grid_cell_size = 32` "must match" the shared index unenforced. `buildAiSeparationContext` computes the separation and cohere radii once per update with `spatial_index.cellScanRadius(radius, spatial.cell_size)` into `AiSeparationContext`; delete `grid_cell_size`. If 68A's AiSystem rewrite lands first it carries this; check off with a pointer.

#### Render (`src/render/`)

**H1. GPU static streams created at the declared reservation** (render-assets-09). `renderer.zig:1399-1421, 495-502`; trigger `world_system.zig:962-1040`. First creation uses the exact vertex count and then doubles lazily (6 → … → 192, up to 5 GPU-idle growths in play). `reserveStaticGeometry` records `reserved_static_vertices`; a pure `staticStreamTargetVertices(needed, reserved, current) usize` returns `max(needed, reserved)` on first creation and doubles past that; fix the stale comment at `:1399-1402`.

**H2. Geometric tile-edit transfer growth** (render-assets-11). `renderer.zig:285-286, 1075-1095, 1384-1397`. The transfer buffer is recreated at the exact `required_bytes` on every new per-frame high. `stageTileEdits` sizes it with a pure `tileEditTransferTargetBytes(len, capacity) !u32 = storageByteSize(max(len, tile_edit_scratch.capacity))`, so GPU growths never outnumber the geometric CPU scratch growths. The growth point stays before acquire.

**H3. Warmed tile-edit upload is allocation-free** (render-assets-10). `renderer.zig:284, 1019-1048, 1377`. The `ensureTotalCapacity` + `appendAssumeCapacity` pairing has no FailingAllocator proof (`.claude/rules/memory-performance.md`). Test only; see the Checklist.

**H4. GPU buffer growth without draining the device** (render-assets-12; `gpu-smoke`-gated). `renderer.zig:1263` (warn), `:1270`, `:1415`, `:1086` (`SDL_WaitForGPUIdle`); SDL contract `SDL_gpu.h:3069`, `:3083`. SDL releases buffers "as soon as it is safe", so the idle buys no safety. Drop the idle in the three grow paths (create → swap → release); warn only on growth during a frame, and `reserveSpriteCommands` logs at debug. If a backend corrupts in `gpu-smoke`, keep the idle on that backend only, with a documented reason. Texture replacement and `releaseTileDataBuffers` keep their idle.

**J2. Overlay headroom checked against the overlay's cost** (render-assets-04). `renderer.zig:196`; `fps_counter.zig:122-140`. Add `pub const max_sprite_commands = 1 + 10` to `FpsCounter` and `comptime { std.debug.assert(max_sprite_commands <= Renderer.k_overlay_command_headroom); }` in `fps_counter.zig`. Cross-edit slice-67b's `FpsCounter` "Bound" bullet to set the constant to 4 + 10 = 14 under this assert.

**J3. Width guard for the composite-draw cap** (render-assets-07). `renderer.zig:232, 545`; `sprite_batch.zig:233`. Next to `k_max_dense_composite_draws` (stays 32), add `comptime { std.debug.assert(k_max_dense_composite_draws <= std.math.maxInt(@FieldType(DrawGroup, "window_slot")) + 1); }`, closing a latent ReleaseFast `@intCast` hazard.

#### World data and app core

**F3. Dense world arrays sized exactly at load** (world-data-world-01). `world_system.zig:459-513` (`initProceduralFromMeta`), `1731-1765` (`addDenseLayer`), `1772-1785` (`addUndergroundLevelStack`), `1930-1970` (`rebuildChunks`). `dense_tile_ids` grows 1.5× per layer (7 reallocs, ≈0.9 MB wasted on 256×256×32; ≈3.7 MB wasted and ≈36 MB transient peak at 512²×32); chunk rows over-allocate 1.5×.

- `addUndergroundLevelStack` adds `dense_tile_ids.ensureTotalCapacityPrecise(len + underground_count × cellCount())` and a grow-only guarded `dense_layers.setCapacity(len + underground_count)` next to the `level_base_z` reserve.
- `initProceduralFromMeta` reserves precisely for `(1 + config.underground_level_count) × cellCount()` before the ground layer; `addDenseLayer` uses `ensureTotalCapacityPrecise` (OOM-atomic preflight kept); `rebuildChunks` uses `next.rows.setCapacity(allocator, chunk_count)`.

**J4. Architecture doc matches MAL alignment** (world-data-ds-04, doc only). `docs/architecture.md` (MAL alignment text); `data_system/types.zig:21-31`. The text becomes "contiguous scalar columns; worker ranges split at `movement_range_alignment_items` (16) boundaries; MAL does not guarantee 64-byte column bases (`.claude/rules/memory-performance.md`)"; add the same sentence to the `hotStoreCapacity` doc comment.

**J1. `StateTransitions` budget first** (app-core-10). `state.zig:184-224, 292-303`; `engine.zig:126-128`. `reserve(capacity)` sets both list capacity and the refusal bound. Rename `default_capacity` to `pub const max_requests_per_frame: usize = 8`; `max_requests` is fixed at init; `pub fn reserve(self) !void { try self.requests.ensureTotalCapacity(self.allocator, self.max_requests); }` mirrors `AudioCommandBuffer.reserve`; `Engine.init` calls `try transitions.reserve();`. Enqueue refusal and the lazy fallback stay.

#### Owned by other slices (listed so this pass covers every site)

| Survivor | Site | Owner and item | This slice's part |
|---|---|---|---|
| render-assets-05 | `renderer.zig:198-212` stacked-UI headroom; `render_prep.zig:330-339` | 53B "Stacked-UI headroom retired", then 60 `k_post_state_command_headroom` | none; A2 composes unchanged |
| world-data-world-02, gameplay-systems-31, pathfinding-26 | level-link pool | 64E level-link growth at the dig commit seam (landed) | K6 (landed) |
| pathfinding-17 | nav dirty buffers (`system.zig:110-127, 268-280`) | 64E nav dirty buffers (landed); 65B "Load-time capacities" (fence window) | B1, C3 (landed) |
| pathfinding-29 | `nav_grid.zig:105-129` per-call map | 65B "Load-time capacities" | none |
| pathfinding-34 | `types.zig:97-100` 4096 ceiling | 71B "71B.1 capacity-audit follow-up" (landed) | C3's `raiseAgentBudget` composes (landed) |
| gameplay-systems-09 | `perception.zig:458-469, 857-889` `pending_dirty` | 64B "B3 perception cache bound" | none |
| gameplay-systems-17 | `arbitration.zig:24-25` `behavior_count` | 61 AI forage bullet | none |
| gameplay-systems-25 (band half) | spatial window zoom band | 60 spatial-index dense window | D2 cross-edit |

#### Kept by decision

| Site | Kind | Why kept |
|---|---|---|
| `AudioCommandBuffer` 32/step (`config.zig:42`, `audio.zig:92-114`) | work budget | Budget sets capacity; refusal is loud and deterministic, and the contact retries next step. |
| Lazy grow-to-bound fallback (`audio.zig:175-181`, `state.zig:296-301`) | other | Cold; grows once straight to the bound; never `assumeCapacity` unreserved. |
| SFX voice pool 16 | work budget | Bounds mixer cost; voice stealing is the concurrency policy. |
| Audio ID arrays, perf-log/input enum arrays, `simd.lane_count`, stateless RNG, `frames_in_flight` [1,3] | format | Exact from manifest, enum, ISA or SDL range. |
| Audio name maps, `AssetCache` path map and leases, preload scratch, atlas JSON ceilings, shader 1 MiB ceiling | runtime-growing / other | Setup-time only, manifest-bounded, loud on corrupt input. |
| Worker pool `cpu_count - 1`; `items_per_range` 64; tuner thresholds | other / budget / threshold | Per machine at init (65A owns it); outputs independent of range shape; `threaded_batch_ns` derives from dispatch cost. |
| `StateStack.states` growth | runtime-growing | App structural seam; depth ≤ 4. |
| `TimeLoop.max_updates_per_frame` 5; frame-pacer fallback | work budget / threshold | Spiral-of-death clamp; pacer derives from the fixed step. |
| Unbounded SDL event drain | work budget | Must drain fully; SDL owns the queue. |
| Overlay top-up 16 (`engine.zig:364-368`) | scratch | Bounded engine content; J2 compile-checks it. |
| Initial batch of 4096 commands; CPU/GPU batch growth policy | runtime-growing | Default ring for non-reserving states; geometric, before the threaded phase, proven. |
| `k_max_tilemap_window_layers` 32; `k_max_dense_submit_stack_cap` 32 | format | std140 uniform width plus per-pixel work bound, refused loudly at load. |
| Static geometry and draw-list reservations; `staticGeometryCapacity` | runtime-growing | Bounded by the composite cap, grow-only, proven. |
| Texture and text slot maps | runtime-growing | Cold growth; 53A replaces dynamic text. |
| Tile-data buffer registry; `k_max_dense_tile_gpu_bytes` 64 MiB | world-extent / other | One exact buffer per world plus a loud platform ceiling. |
| u32 GPU byte and vertex guards; `TileId` u16; component `enum(u5)`; entity `u32` | format | Index and format widths that fail loudly. |
| Sprite-prep range thresholds | threshold | Per-quad cost, tuned by the tuner. |
| Stimulus budgets; `action_intent_live_capacity` 64; `cognition_stagger_n` 4; LOD bands | work budget / threshold | Fixed per-step buses with counted drops; cadences that change behavior by design. |
| `SimulationEvents.capacity_limit` mechanism | scratch | All-or-fail preflight; sized by B1/C3/C4; K1 justifies it. |
| `RangeOutputStream` growth at prefix; shared `range_count` across `reserveStreams` | scratch | Main thread before workers write; `eventCapacitySum()` keeps the shared bound valid. |
| Structural preflight, component stores, slot map | runtime-growing | This is the seam; proven. |
| No load-time `DataSystem` reserve | runtime-growing | Slice 62 owns `reserveComponentRows`. |
| `ai_memory_ring_capacity` 4; validation ceilings | format / threshold | Inline checksummed ring and authoring bounds. |
| `world_level` rows mid-stage (`dig_controller.zig:368-381`) | runtime-growing | Preflighted, OOM-atomic; reached only by malformed entities. |
| `dense_tile_edits` queue; sparse tile buckets; derived render index; small world-extent arrays | scratch / runtime-growing / world-extent | Bounded per frame and warmed; 58/69A own sparse bulk sizing. |
| Demo population sizing, debris pool 512, world config, render reserves | demo content | Lives in the demo caller. |
| Pathfinding `SearchScratch` O(cells) per participant | scratch | Direct-indexed, generation-stamped A*; F1 makes it precise. |
| Per-step request and solve pools; `effectiveSolveLimit` clamp | runtime-growing / work budget | Logical bounds proven; the physical term never binds. |
| Probe tables at 2× (50% load); payload free list; resize snapshots | format / scratch | Probe chains terminate; snapshots are cold. |
| Scratch slots (workers + 1); patch edges `pcap²`; flood queues `ct²` | scratch | Proven bounds, reserved before dispatch. |
| World-extent nav arrays | world-extent | Textbook layout; F1 removes the slack. |

### Checklist

- [ ] **Re-scope against [Slice 64G](slice-64g.md) before implementing F1, F3, D2, and G** (design pass): 64G replaces the per-level terrain and nav arrays these items size (`NavGrid`, `NavLevelGraph`, `dense_tile_ids`); each item is dropped, moved into 64G, or rewritten to size by content.
- [ ] **M1 · Memory footprint benches.** Add `src/benchmarks/capacity_footprint.zig` (groups above), registered in `runner.zig`. `suite.RunStats` gains `reserved_bytes: ?u64 = null` and `peak_bytes: ?u64 = null`, printed when set. Fixtures: `initDemoFromMeta` then `addUndergroundLevelStack(levels - 1)`; a `DataSystem` with the mover count; `SimulationPipeline.init` in the demo capacity shape with 16 participants; one pathfinding update with every mover requesting.
  - Tests: one `suite.zig` formatting test for the byte fields (pure utility against stubs).
  - Bench: record baselines at {16, 256, 512} before D2, F and G land.
- [x] **A1 · Plane-traversal scratch preflight:** `growPlaneScratch` on overrun, counted in `dig_plane_scratch_grown`.
- [x] **A2 · `drawSprite` grows instead of failing:** `SpriteCommandOverflow` removed; drift counted in `SpriteBatch.ReservationDrift`.
- [x] **A3 · Request intake gated on `max_frame_requests`.**
- [x] **A4 · Logical `open_limit` / `corridor_limit` in search;** `SearchScratch` aligned to 64 B.
- [x] **B1 · `EventProducerId` is the production event bound** (`eventCapacitySum`, enforced `.structural_commit` share; shipped `capacity_limit` 255; cross-edits landed).
- [x] **C1 · `CollisionSystem.reserve`.**
- [x] **C2 · Steering static snapshot sized to statics** (reserved to the responder capacity).
- [x] **C3 · `syncPopulationCapacity`** with the `reserveRows`/`reserveWindow` split, `growForAgentCount` and `raiseAgentBudget` (cross-edits landed).
- [x] **C4 · Perception and affect shares derived from rows** (cross-edits landed).
- [x] **C5 · Per-range outputs never warm in-stage** (windowed outputs, bound-reserved broadphase slots; `78ed7e5`).
- [x] **C6 · Contact-dependent streams reserved to the pair bound,** past-bound steps counted.
- [x] **C7 · Battle-scale contact density confirmed in the running demo:** ≈0.03 pairs/body/step, `collision_pair_bound_exceeded=0`.
- [ ] **D1 · Inverted destructible resolve** (§D1).
  - Tests in `destructible_controller.zig`: 300 crates (minimal world, one per cell), a cell interact hits dense index 299; an AABB spanning 4 cells is matched by intents on each cell; two intents on one cell resolve to the same lowest-(index, generation) crate; the tie-break, multi-hit, no-intent and FailingAllocator (`:673`) tests are unchanged.
  - New bench group `destructible-resolve` (`src/benchmarks/destructible.zig`): crates {64, 256, 1024, 10000}, 8 fixed cell intents per step.
  - Cross-edits: 61, 63, 71D as in §D1.
- [ ] **D2 · World-extent spatial window and clamp stat** (§D2).
  - Tests in `spatial_index.zig`: `capacity_cells_x/_y == min(ceil(W/cs) + 1, halo formula)` for a world smaller and larger than the halo, no world built; a 1×1-tile fixture reserves 2×2 cells; a population spanning both edges builds with `dense_window_clamped == 0`; the skip test (`:1508`) asserts `dense_window_clamped == 1`; after `reserve`, serial and real multi-worker builds of a world-filling population allocate nothing under FailingAllocator; rewrite the formula tests (`:1455-1506`), keep the 4096² test until Slice 60.
  - Cross-edit: slice-60 as in §D2. Bench: `spatial_index`, `ai`, `perception`, `footprint-spatial`.
- [ ] **D3 · Exact LOS visit limit** (§D3). Tests: with `tile_size = 8` a clear 400-unit diagonal is visible; the same ray on 16×16 and 64×64 worlds agrees; LOS and DDA parity tests unchanged; `grep -n los_max_cells src/` empty. Bench: `perception`, `perception-los-dense`.
- [ ] **D4 · AI scan radius from the live cell size** (§D4). Test: an index at `cell_size = 16` lets separation find a 40-unit neighbor; parity tests unchanged. Bench: `ai`.
- [ ] **E1 · Shrink keeps accepted work** (§E1). Test: a shrink with `pending.len` above the derived target gives `resize_dropped == 0`; add assertions to `system.zig:4310, 4369, 4400, 4432`. Bench: `pathfinding`, `pathfinding-drain`.
- [ ] **E2 · Preserving resize** (§E2).
  - Tests in `caches.zig`: grow and shrink keep every entry's key and path cells, with re-insert order ascending by old slot (probe layout equals a fresh insert in that order); shrink compacts stripes. In `system.zig`: a grow keeps every completed, unavailable and pending entry; a shrink with live entries above the derived target keeps them; the steady-state no-alloc proof holds.
  - New bench group `pathfinding-elastic-ramp` (`src/benchmarks/pathfinding.zig`): final agents {512, 2048}, doubling from 8 every 8 steps toward a fixed goal set, `output_count` = total solves; gate: solves after ≤ before at every count. Also run `pathfinding`, `pathfinding-shared-goal`, `pathfinding-cache-*`.
- [ ] **E3 · `NegativeCache`** (§E3). Tests: expiry at TTL and never with `ttl == 0`; a full cache evicts round-robin instead of refusing; survives `resizePreserving`; `caches.zig:738`, `:876` stay valid for `pending_keys`; the `system.zig` negative-cache tests re-run. Bench: `pathfinding-cache-unreachable`, `pathfinding-hard-fallback`.
- [x] **E4 · Edge-cap fallback without a version bump:** superseded by 64E's edge-window growth (incremental branch, `version_bumps == 0`).
- [ ] **E5 · Group tally sized from intake** (§E5). Test: `max_solved_requests_per_step + 1` distinct shared goals all tally in one step; group-field tests (e.g. `:1937`) re-run. Bench: `pathfinding-group-field-detour*`.
- [ ] **E6 · Initial agent count** (§E6). Tests: `reserve` with initial 40 gives `effective_agent_capacity == derive(40)`; the first update at 40 agents allocates nothing; update the `proceduralPathfindingCapacity` test in `game_demo_state.zig`. Bench: `pathfinding`, `footprint-nav`.
- [ ] **E7 · `solved_paths` slots isolated per worker.** `PathfindingSystem.solved_paths` (`system.zig:96`, `SolvedPath` at `:176`) is written by solve workers by `pending_index` (`solve.zig:633`, `:654`, `:675-676`); 8-byte records let neighbouring requests on different workers share a line.
  - Fix: a padded `SolvedPathSlot { path: SolvedPath, _pad: [threadSharedRecordPadding(SolvedPath)]u8 }` in an `ArrayListAligned(…, thread_shared_record_alignment)` with comptime `assertThreadSharedRecord` (65A's helper, or a module-local copy plus size assert). Alternative if the bench prefers density: index by dense fallback position so each range writes a contiguous run, padding only range boundaries. Choose by the bench.
  - Tests: comptime layout assert; slot stride a multiple of 64; threaded-solve parity (real multi-worker `ThreadSystem`) equals serial; steady-state FailingAllocator proof unchanged. Bench: `pathfinding --items 512`, `pathfinding-drain`, threaded rows; no serial regression.
- [ ] **E8 · Worker path/stitched pool stripes start on a line.** `worker_path_pool` (`system.zig:101`) and `worker_stitched_pool` (`:105`) stripes (`solve.zig:624-626`, `:670-673`) are not line-aligned, so stripe boundaries false-share.
  - Fix: round each stride up to whole 64 B lines (`stride_entries = alignForward(stride * @sizeOf(T), 64) / @sizeOf(T)`), keep the logical stride as the downsample/stitch bound, back both pools with `ArrayListAligned(…, thread_shared_record_alignment)`; `resizeFilledArrayList` gains an aligned variant.
  - Tests: every stripe offset is a multiple of 64 from an aligned base; stored paths unchanged against the unpadded layout (plain, downsampled, stitched); FailingAllocator proof unchanged. Bench: as E7 plus `pathfinding-hard-fallback`, `footprint-nav`.
- [ ] **F1 · Exact nav reserves** (§F1).
  - Tests: on a 1-level, 1-chunk world after a nav build, `capacity == len` for `blocked`, `components`, `cell_to_portal`, `portals` and `SearchScratch.cells`, and ResultCache path and stitched capacity equal logical × stride; `types.zig:978` holds; every steady-state FailingAllocator proof re-runs (`system.zig:1937, 2334, 2455, 3392, 4012, 4041, 4088`; `nav_graph.zig:2599, 3605, 3648, 3751`).
  - Bench: `nav-update-*`, `pathfinding`, `footprint-nav`.
- [ ] **F2 · Accurate gate terms** (§F2). Tests: update expected values in `nav_memory.zig:277-450`; add "requiredBytes equals the reserved bytes of a built minimal world" (1 level, 1 chunk, 1 participant). Record `autoSizedMaxNavMemoryBytes` before and after in the commit. Bench: `footprint-nav`.
- [ ] **F3 · Exact dense world arrays** (§F3). Tests in `world_system.zig`: a 16×16, 3-level fixture (`initDemoFromMetaWithUnderground`) gives `dense_tile_ids.capacity == levelCount() * 256` and `dense_layers.capacity == levelCount()`; a 1-level world gives 256; the `addDenseLayer` FailingAllocator test (`:3944`) passes. Bench: `footprint-world`, `render-game-prep-dense-deep`.
- [ ] **G1 · Tier-1 scratch per escalated ordinal** (§G1). Tests: an escalated long corridor lands in a long stripe and is published whole; participant abstract capacity equals the tier-0 caps; update `system.zig:3392` and `:3259`; the threaded FailingAllocator solve proof (`:2334`) passes; update the `nav_memory` abstract-term tests. Bench: `pathfinding-escalated-detour`, `pathfinding-hard-fallback*`, `pathfinding`, `footprint-nav`.
- [ ] **G2 · Two-pool result cache** (§G2). Tests: a tier-1 result over 512 cells is stored whole and served; the long pool evicts oldest stamp then lowest index; the Debug assert holds at E × ttl; with `ttl == 0` the pool is `max_cached_results`; update `caches.zig` (`:754-1100`) and `nav_memory.zig` expected bytes. Bench: `pathfinding-cache-*`, `pathfinding-escalated-detour`, `footprint-nav`.
- [ ] **G3 · `PathfindingCapacity` split** (§G3). Tests: fixtures compile without the derived fields; `system.zig:4310-4470` reads `capacity_derived`; `nav_memory.zig` budget tests pass. Bench: `steering`, `pathfinding`.
- [ ] **H1 · Static streams at the reservation** (§H1). Test: headless `staticStreamTargetVertices` for reserved > needed, needed > reserved, and zero-reserve doubling. Bench: `render-game-prep-dense-surface`, `render-game-prep-dense-deep`.
- [ ] **H2 · Geometric tile-edit transfer** (§H2). Test: headless `tileEditTransferTargetBytes`, including the overflow case returning `error.GpuBufferTooLarge`. Bench: `render-game-prep`.
- [ ] **H3 · Warmed tile-edit upload proof** (§H3). Test in `renderer.zig`, "warmed uploadTileDataEdits stays allocation-free": `testRenderer` plus a private helper that registers a fake buffer handle (`@ptrFromInt`, never dereferenced) and params/count directly into `tile_data_buffers`, `params`, `counts` (a local fixture, not a production hook); warm with N sorted edits, simulate the copy-pass clear, then re-upload N edits under `FailingAllocator(fail_index = 0, resize_fail_index = 0)` on `renderer.allocator` with zero allocations; a variant with a carried overlapping batch covers `replacePendingStorageRegion`; teardown frees the lists without an SDL release.
- [ ] **H4 · Growth without a GPU drain** (§H4). `zig build gpu-smoke` passes on every backend available to the owner, each recorded in the commit. Bench: `render-prep`.
- [x] **I1 · Perception events derived from per-row columns** after the join; per-range event slots deleted.
- [x] **I2 · Affect crossings from per-row bits,** emitted in (gather row, drive) order; slots, `merge_scratch` and sort deleted; `checksum_format_tag` unchanged.
- [ ] **J1 · `StateTransitions` budget first** (§J1). Tests: `state.zig:1638` calls `reserve()` and still loops to `max_requests`; `reserve()` never changes `max_requests`; update `engine.zig:128`.
- [ ] **J2 · `FpsCounter` bound assert** (§J2). Comptime only; cross-edit slice-67b.
- [ ] **J3 · `window_slot` width assert** (§J3). Comptime only.
- [ ] **J4 · MAL alignment doc** (§J4). Doc only.
- [ ] **K1 · `SimulationEvents.capacity_limit` justified.** The doc comment at `simulation.zig:245` states the limit is the exhaustive producer sum (B1) that follows population (C3, C4), so a required-append failure means a producer exceeded its declared budget, a bug. B1's comptime walk and C3's zero-drop test cover it.
- [ ] **K2 · Pending-queue backpressure justified** (pathfinding-11, `system.zig:1137-1164`). Doc: deterministic backpressure gated on the logical `max_pending_requests`, which follows the live agent count. Test, if none exists: `max_pending + 3` distinct keys drop exactly 3, the accepted set is the first `max_pending` in request order, and dropped agents re-request on `.missing`.
- [x] **K3 · Interior link slots:** K = 8 is a per-chunk floor that doubles in place; no refusal left to justify.
- [ ] **K4 · Particle pool justified** (gameplay-systems-29, `particle.zig:330-339`). Doc: presentation-only; refusal in emission order against the logical `capacity`; particles never feed simulation state. Test, if none exists: emitting past capacity refuses and counts, existing particle order unchanged.
- [ ] **K5 · Collision-SFX cooldown table justified** (gameplay-systems-36, `audio_controller.zig:26-35, 126-172`). Doc: an audible-concurrency budget and audio policy only. Test, if none exists: with 33 cooling pairs, the entry with the least remaining time is evicted deterministically.
- [x] **K6 · Owned-elsewhere sites carry an owner pointer** (64E, 71B.1, 68A cross-edits).
- [ ] **X1 · Docs.**
  - `docs/architecture.md`: the population growth seam (`syncPopulationCapacity`), the event-bound owner, J4.
  - `docs/simulation-tiers-and-pipeline.md`: the Events section names the producer table as the bound; Structural Commands and Post-Commit Reactions add the sync step; the Slice 45 consumer paragraph describes the inverted resolve.
  - `docs/rendering-assets-shaders.md`: `drawSprite` growth and its counter (landed with A2); GPU growth without an idle (after H4).
  - The logical-limit gate rule is in `.claude/rules/memory-performance.md` (landed with A3).
  - Add the Slice 72 row to the roadmap index's Open Frontier table, plus a Suggested Order entry ("72 — any time; Batch A first").

### Acceptance checks

- [ ] `zig build verify` passes, and `zig build test` passes in Debug and ReleaseFast.
- [ ] Grep gates are empty:
  - `SpriteCommandOverflow`, `destructible_cell_scan_budget`, `los_max_cells`, `event_reserve`, `perception_event_reserve`, `affect_event_reserve` and `demoCognitionAgentCount` under `src/`;
  - `grep -rnE "items\.len >= [a-z_.]*\.capacity([^._a-zA-Z0-9]|$)" src/game/systems/pathfinding/` (the trailing class excludes the logical K2 gate `self.pending.items.len >= self.capacity.max_pending_requests`; the remaining physical `.capacity` reads — `system.zig`'s append-or-grow choice, the `effectiveSolveLimit` clamp, `reconstructLocalPath`'s Debug assert — are not behavior gates);
  - `std.debug.assert(pending_carves`.
- [ ] Every capacity-dependent-behavior site is fixed or justified at its site: A1–A4, B1, C3, C4, D1, D2, D3, E1–E5 and J1 fixed; K1–K5 justified; world-data-world-02, gameplay-systems-31, pathfinding-26 and pathfinding-34 carry owner pointers (K6).
- [ ] Bench gate per `.claude/rules/tests-benchmarks.md`: every group named in the batch table shows no regression beyond run-to-run spread. New groups record baselines: `destructible-resolve` ({64, 256} gated; 1024 and 10000 recorded), `pathfinding-elastic-ramp` (total solves after ≤ before at 512 and 2048), `footprint-*`.
- [ ] Memory comparison from `footprint-*` on the small (16, 3 levels, 32 movers), shipped (256, 32 levels, 2048 movers) and large (512, 32 levels, 2048 movers) instances, before and after, recorded in the landing commits:
  - D2: `footprint-spatial` window bytes ≤ 0.15 × before on shipped (≈0.53 MB vs ≈4.7 MB);
  - F1: the nav-array portion of `footprint-nav` ≤ 0.75 × before on shipped and large;
  - F3: `footprint-world` dense bytes equal levels × cells × 2 B exactly, and `peak_bytes` drops on shipped and large;
  - G1 + G2: `footprint-nav` result-cache plus abstract-scratch bytes ≤ 0.45 × the post-F1 value on shipped at 2048 movers;
  - small instance: recorded only, because fixed floors dominate.
- [ ] `zig build gpu-smoke` passes on each available backend after H1, H2 and H4 (display-gated); backends listed in the H4 commit.
- [ ] All cross-slice edits named in D1, D2 and J2 land in the same change as their item (B1, C3, C4, E4, I1, I2 and K6 cross-edits landed).
