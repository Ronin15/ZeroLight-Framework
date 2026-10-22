## Slice 72: Live Capacity Sizing Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none (F and G re-scoped against [Slice 64G](slice-64g.md) first) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** A1–A4, B1, C1–C7, D3, D4, E2, G1–G3, H2, H3, I1, I2,
K6 landed (D3, E2, G1–G3, H2, H3 with 64G; D4 with Slice 84); E3, F1–F3, and J3
superseded; E4 and K3 moved into 64G; M1, D1, E1, E5–E9, H1, H4, J1, J2, J4, K1, K2, K4, K5, X1
open.

Goal: no live behavior (iteration order, deferral, refusal, drops,
truncation, cache flushes, query reach) depends on physical `.capacity`,
allocation history, or a load-time pool that growth can outrun.
Population-sized storage grows at one seam, geometrically ahead of need,
with hot paths allocation-free between growth points; storage follows
content, never a level's area or a world's extent; no `appendAssumeCapacity`
is protected only by a Debug assert; footprint benches show memory following
content across world sizes.

### Current foundation

- Landed: `DataSystem` stores grow with an all-or-fail geometric preflight at
  the structural-commit seam; `EventProducerId.maxEventsPerStep` is the
  exhaustive event bound summed by `eventCapacitySum()` (B1, C4);
  `SimulationPipeline.syncPopulationCapacity` is the one population growth
  seam, after the budgeted commit and before the nav reaction, never refused
  (`raiseAgentBudget`), OOM retried next seam (C3); per-range outputs write
  windows of one item-capacity buffer, broadphase slots reserve to the pair
  bound, perception and affect emit from per-row state after the join (C5,
  C6, I1, I2); pathfinding intake and search spill gate on logical limits
  (A3, A4); `drawSprite` grows (A2); plane-traversal scratch grows on overrun
  (A1).
- Measured: battle-scale contact density ≈0.03 pairs/body/step with
  `collision_pair_bound_exceeded = 0` (C7).
- Open sites in live code: a pathfinding shrink drops accepted work
  (`resize_dropped`); the group tally is
  capped at `min(512, n)`; elastic capacity starts at a floor of 8;
  destructible cell resolve scans only the first
  `destructible_cell_scan_budget` (256) dense rows;
  `solved_paths` and the worker path pool stripes share lines across
  workers; GPU static streams are created at the first upload's exact size;
  `StateTransitions.reserve` sets the refusal bound.
- Per-level nav arrays, dense world arrays, the nav memory gate, and
  `SearchScratch` O(cells) are replaced by 64G's chunk storage.
- Owned elsewhere: nav dirty buffers and level links (64G);
  `max_agent_budget` (71B.1, landed); deferred-nav buffers (65B); the
  static obstacle sync (64G's `StaticColliderSystem`); stacked-UI headroom
  (53B, 60); spatial-index coverage of the whole population (75);
  `behavior_count` (73);
  `cognition_stagger_n` and LOD bands (75).
- Kept, justified at each site: work budgets (audio commands per step, SFX
  voices, `TimeLoop.max_updates_per_frame`, full SDL event drain); format
  widths (`TileId` u16, component `enum(u5)`, entity u32, GPU u32 guards,
  AI memory ring, probe tables at 2×); seam growth already proven
  (structural preflight, slot map, state stack, sprite batches, static geometry, texture and text
  slots, range-stream prefix, request and solve pools); presentation pools
  (overlay top-up, particles); per-machine thresholds (pool size, range
  sizes, tuners).

### Architecture notes

- No `stage_order`, `PipelineResource`, or `stageContract()` change.
- Growth points (`.claude/rules/memory-performance.md`): population storage
  in `syncPopulationCapacity`; per-frame render storage on the main thread
  before the threaded emit; gates compare stored logical limits.
- Storage follows content (`.claude/rules/budgets-capacities.md`): a
  world-extent sizing item is rewritten to size by content, or moved into
  64G, never landed as extent sizing.
- New growth and drop counters log once and are perf metrics
  (`.claude/rules/zig-style.md`).
- Each item lands with its tests and bench run; cross-slice text edits land
  in the same change as their item.

### Checklist

- [x] Re-scope F1, F2, F3, and G against 64G: F1–F3 superseded by 64G's chunk
      storage, G1–G3 landed with it (below).
- [ ] M1 · Footprint benches `footprint-world`, `footprint-nav`,
      `footprint-spatial` reporting reserved and peak bytes at three world
      sizes; baselines before F/G land.
- [x] A1 · Plane-traversal scratch grows on overrun, counted.
- [x] A2 · `drawSprite` grows instead of failing; drift counted.
- [x] A3 · Request intake gated on `max_frame_requests`.
- [x] A4 · Logical search limits; `SearchScratch` line-aligned.
- [x] B1 · `EventProducerId` is the production event bound.
- [x] C1 · `CollisionSystem.reserve`.
- [x] C2 · Steering static snapshot sized to statics.
- [x] C3 · `syncPopulationCapacity` population seam.
- [x] C4 · Perception and affect event shares derived from rows.
- [x] C5 · Per-range outputs never warm in-stage (`78ed7e5`).
- [x] C6 · Contact streams reserved to the pair bound; overruns counted.
- [x] C7 · Battle-scale contact density confirmed in the running demo.
- [ ] D1 · Destructible cell resolve reaches every destructible through the
      shared static-collider query, so its cost follows the cells resolved,
      never the destructible count, with no per-step pass over destructibles
      on main (Engine-Core core finding: a pass over every destructible per
      step fails the cost model). Failure scenario: the resolve scans only the
      first 256 dense rows (`destructible_controller.zig:36`, `:294`), so a
      destructible at row 257 or later is never hit (derived; contract test).
      Each scanned row also resolves the slot, level, body, and bounds
      (`:297`). That chase goes away with the scan, not as a packed copy of it.
      Today's tie-break kept; `destructible-resolve` flat in destructible
      count at three counts; 61, 63, and 71D resolve text updated.
- [x] D3 · LOS visit limit from the ray's own length.
- [x] D4 · AI scan radius from the live spatial cell size. Queries take a
      world radius and the index derives the scan box
      (`spatial_index.zig:535`); `grid_cell_size` is gone.
- [ ] E1 · A pathfinding shrink never drops accepted work.
- [x] E2 · Elastic resizes preserve cache entries and pending work, with a
      `pathfinding-elastic-ramp` bench (solves after ≤ before).
- [x] E3 · Negative cache expires and evicts deterministically instead of
      refusing. Superseded: 64G deleted the negative cache; reachability answers
      unreachable goals in O(1) (`2c1a9c1`).
- [ ] E5 · Group tally sized from per-step intake.
- [ ] E6 · Initial elastic capacity from the loaded population.
- [ ] E7 · Solve result slots isolated per worker (65A's helper).
- [ ] E8 · Worker path and stitched pool stripes start on a line.
- [ ] E9 · Per-step solve and fallback budgets are fixed counts, not clamped
      to population.
- [x] F1 · Exact reserves for exact-size nav arrays. Superseded: nav has no
      level-sized arrays; per-chunk pools grow counted at their seam (`5db9025`,
      `eaa4a80`) and each structure's byte bound is checked against live bytes
      (`639f55d`).
- [x] F2 · Nav memory gate charges what load reserves. Superseded: the gate is
      deleted (`1305fa9`); no platform check refuses a world.
- [x] F3 · Dense world arrays sized exactly. Superseded: terrain is per-chunk
      blocks (`453993f`).
- [x] G1 · Tier-1 search scratch sized per escalated solve, not per
      participant (`10bbbc7`).
- [x] G2 · Result-cache path storage sized to the common bound plus a long
      pool that never evicts a live entry (re-scoped by 64G).
- [x] G3 · `PathfindingCapacity` holds caller knobs only; derived values
      private (`a869e15`).
- [ ] H1 · GPU static streams created at the declared reservation.
- [x] H2 · Geometric tile-edit transfer growth.
- [x] H3 · `FailingAllocator` proof for the warmed tile-edit upload: renderer
      test "queueTileStoreUploads folds a carried batch allocation-free after
      reserve".
- [ ] H4 · GPU buffer growth without draining the device (`gpu-smoke` per
      backend). Tile path (`89f5c9a`) and vertex and static streams
      (`ensureBatchCapacity`, `ensureStaticCapacity`, `08c01c2`) landed;
      `gpu-smoke` on each backend remains.
- [x] I1 · Perception events from per-row columns after the join.
- [x] I2 · Affect crossings from per-row bits; checksum tag unchanged.
- [ ] J1 · `StateTransitions` budget set at init, `reserve` follows it.
- [ ] J2 · `FpsCounter` command bound comptime-checked against overlay
      headroom; 67B text updated.
- [x] J3 · `window_slot` width assert for the composite-draw cap. Superseded:
      the cap is gone and `window_slot` is a `u32` behind a checked cast in
      `appendStaticTilemapSpan`.
- [ ] J4 · MAL alignment wording in `docs/architecture.md` and the
      `hotStoreCapacity` doc comment.
- [ ] K1 · `SimulationEvents.capacity_limit` justified at its site.
- [ ] K2 · Pending- and frame-request intake, including past
      `max_agent_budget`: its drop is unreachable by construction or becomes
      deterministic deferral, never a capacity refusal.
- [ ] K4 · Particle pool justified as presentation-only.
- [ ] K5 · Collision-SFX cooldown table justified as audio policy.
- [x] K6 · Owned-elsewhere sites carry an owner pointer.
- [ ] X1 · Docs: `docs/architecture.md` population seam and event-bound
      owner; `docs/simulation-tiers-and-pipeline.md` producer table, sync
      step, destructible resolve; `docs/rendering-assets-shaders.md` GPU
      growth after H4.

### Acceptance checks

- [ ] `zig build verify` passes; `zig build test` passes in Debug and
      ReleaseFast.
- [ ] Grep gates empty under `src/`: `SpriteCommandOverflow`,
      `destructible_cell_scan_budget`, `los_max_cells`, and physical
      `.capacity` behavior gates in `src/game/systems/pathfinding/`.
- [ ] Every capacity-dependent-behavior site is fixed or justified at its
      site.
- [ ] Every item that can move a hot path is benched before and after on
      adjacent commits (`.claude/rules/tests-benchmarks.md`) with no
      regression beyond run-to-run spread; new groups record baselines.
- [ ] `footprint-*` at three world sizes shows memory following content, not
      extent, before and after F and G; numbers in the landing commits.
- [ ] `zig build gpu-smoke` passes on each available backend after H1, H2,
      H4 (display-gated).
