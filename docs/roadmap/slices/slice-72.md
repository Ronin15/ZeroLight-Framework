## Slice 72: Live Capacity Sizing Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none (F and G re-scoped against [Slice 64G](slice-64g.md) first) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** A1–A4, B1, C1–C7, I1, I2, K3 landed; M1, D, E,
F, G, H, J, K1, K2, K4, K5, X1 open.

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
- Open sites in live code: elastic pathfinding resizes wipe `completed` and
  `unavailable`, and a shrink drops accepted work (`resize_dropped`);
  `unavailable` never expires and refuses when full; the group tally is
  capped at `min(512, n)`; elastic capacity starts at a floor of 8;
  destructible cell resolve scans only the first
  `destructible_cell_scan_budget` (256) dense rows; the spatial-index dense
  window is halo-derived on every instance and clamps a wider populated box
  out silently; LOS `los_max_cells` (64) assumes 32-unit tiles; AI scan radius
  uses an unenforced `grid_cell_size` (32); `solved_paths` and the worker
  path/stitched pool stripes share lines across workers; GPU static streams
  and the tile-edit transfer buffer grow from exact sizes and GPU growth
  waits for idle; `StateTransitions.reserve` sets the refusal bound.
- Per-level nav arrays, dense world arrays, the nav memory gate, and
  `SearchScratch` O(cells) are replaced by 64G's chunk storage.
- Owned elsewhere: nav dirty buffers and level-link growth (64E, landed);
  `max_agent_budget` (71B.1, landed); deferred-nav buffers (65B); the
  `markStaticBodies` per-call map (64G's nav storage); stacked-UI headroom
  (53B, 60); spatial-index coverage of the whole population (75);
  perception `pending_dirty` (64G); `behavior_count` (73);
  `cognition_stagger_n` and LOD bands (75).
- Kept, justified at each site: work budgets (audio commands per step, SFX
  voices, `TimeLoop.max_updates_per_frame`, full SDL event drain); format
  widths (`TileId` u16, component `enum(u5)`, entity u32, GPU u32 guards,
  `k_max_tilemap_window_layers`, `k_max_dense_submit_stack_cap`, AI memory
  ring, probe tables at 2×); seam growth already proven (structural preflight,
  slot map, state stack, sprite batches, static geometry, texture and text
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

- [ ] Re-scope F1, F2, F3, and G against 64G before implementing them:
      each is dropped, moved into 64G, or rewritten to size by content.
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
- [ ] D1 · Destructible cell resolve reaches every row (one pass over
      destructibles per step, today's tie-break), with `destructible-resolve`
      bench; 61, 63, and 71D resolve text updated.
- [ ] D3 · LOS visit limit from the ray's own length.
- [ ] D4 · AI scan radius from the live spatial cell size.
- [ ] E1 · A pathfinding shrink never drops accepted work.
- [ ] E2 · Elastic resizes preserve cache entries and pending work, with a
      `pathfinding-elastic-ramp` bench (solves after ≤ before).
- [ ] E3 · Negative cache expires and evicts deterministically instead of
      refusing.
- [ ] E5 · Group tally sized from per-step intake.
- [ ] E6 · Initial elastic capacity from the loaded population.
- [ ] E7 · Solve result slots isolated per worker (65A's helper).
- [ ] E8 · Worker path and stitched pool stripes start on a line.
- [x] E4 · Superseded by 64E's edge-window growth.
- [ ] F1 · Exact reserves for exact-size nav arrays (re-scoped by 64G).
- [ ] F2 · Nav memory gate charges what load reserves (re-scoped by 64G).
- [ ] F3 · Dense world arrays sized exactly (re-scoped by 64G).
- [ ] G1 · Tier-1 search scratch sized per escalated solve, not per
      participant (re-scoped by 64G).
- [ ] G2 · Result-cache path storage sized to the common bound plus a long
      pool that never evicts a live entry (re-scoped by 64G).
- [ ] G3 · `PathfindingCapacity` holds caller knobs only; derived values
      private.
- [ ] H1 · GPU static streams created at the declared reservation.
- [ ] H2 · Geometric tile-edit transfer growth.
- [ ] H3 · `FailingAllocator` proof for the warmed tile-edit upload.
- [ ] H4 · GPU buffer growth without draining the device (`gpu-smoke` per
      backend).
- [x] I1 · Perception events from per-row columns after the join.
- [x] I2 · Affect crossings from per-row bits; checksum tag unchanged.
- [ ] J1 · `StateTransitions` budget set at init, `reserve` follows it.
- [ ] J2 · `FpsCounter` command bound comptime-checked against overlay
      headroom; 67B text updated.
- [ ] J3 · `window_slot` width assert for the composite-draw cap.
- [ ] J4 · MAL alignment wording in `docs/architecture.md` and the
      `hotStoreCapacity` doc comment.
- [ ] K1 · `SimulationEvents.capacity_limit` justified at its site.
- [ ] K2 · Pending-queue intake: its drop is unreachable by construction or
      becomes deterministic deferral, never a capacity refusal.
- [x] K3 · Interior link slots: a per-chunk floor that grows in place.
- [ ] K4 · Particle pool justified as presentation-only.
- [ ] K5 · Collision-SFX cooldown table justified as audio policy.
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
- [ ] Every bench named by an item shows no regression beyond run-to-run
      spread; new groups record baselines.
- [ ] `footprint-*` at three world sizes shows memory following content, not
      extent, before and after F and G; numbers in the landing commits.
- [ ] `zig build gpu-smoke` passes on each available backend after H1, H2,
      H4 (display-gated).
