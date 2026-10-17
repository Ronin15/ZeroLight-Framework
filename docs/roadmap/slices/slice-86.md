## Slice 86: Collision Subsystem Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](../archive/slice-83.md) (layout and tuners), [Slice 84](slice-84.md) (branch order) · Related: [Slice 71B](slice-71b.md) (the static structure's 64B row), [Slice 72](slice-72.md) D1 (destructible resolve), [Slice 75](slice-75.md) (collision fidelity per band) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Owner direction 2026-10-11: collision as a whole
subsystem against the current cost model and rules. 71B.1's collision queries
and 71B.2's static split moved here (owner 2026-10-16). Its inert-row item
lands after 88 (index, merged order 9b).

Goal: each body's broadphase work follows its local same-level density,
never column height or level count. Gather and sort leave the main thread.
Rows that do not move (static colliders, items at rest, resource nodes) cost
no per-step collision work while at rest. Every hot loop carries its SIMD
verdict, and the benches cover the worst-case shapes. Contact output and its
order stay deterministic for the order-sensitive consumers.

### Current foundation

- `CollisionSystem` (`src/game/systems/collision.zig`):
  - Every step, `gatherBodies` (`:473`, called at `:327`) and the warm
    insertion `sortWarm` (`:684`, called at `:336`) run scalar on main.
  - The sweep orders on `(min_x, min_y, entity)`. Candidates on other levels
    or outside the body's y span are rejected only after the x sweep visits
    them (`:760`, `:772`, `:885`, `:897`).
  - The broadphase is SIMD and threaded; the narrowphase is threaded.
  - The consumers are order-sensitive: response, audio, and the sensory bus.
- `CollisionResponseSystem.gatherRange` (`collision_response.zig:436`)
  states no SIMD verdict.
- Collision runs on `locomotion` and `cognition` tier rows.
- `StaticColliderSystem` (`src/game/systems/static_colliders.zig:478`, 64G)
  lists static rows per (level, chunk), synced at the commit seam; steering
  queries it through `ColliderView.queryBox` (`:281`, `:328`; `173cc17`).
  Collision still gathers, sorts, and sweeps its statics every step.
- Destructible cell resolve is 72 D1.
- Measured (Debug, 23 workers, `5d5a089` unless noted):
  - `collision-tall`, serial: 2.9 → 26.2 µs per body as the grid's aspect
    goes 1 → 256 at a fixed population.
  - `collision-stacked`, serial: 2.0 → 18.2 µs per body as levels go 1 → 16.
  - `production-step` tuned `--details`: collision is the largest main-thread
    stage in every config. At spread P 16,384 it is 2.95 ms on main, of which
    the gather is 2.75 ms. At crowd P 16,384 it is 11.6 ms on main, with the
    gather at 7.2 ms and the sort at 4.2 ms.
  - `production-step` inert axis (spread P 4,096; 0, 1, 4 inert rows per
    agent): step 2.29 / 3.42 / 7.31 ms, collision main 0.63 / 1.37 /
    3.76 ms, collision bodies 1,541 / 3,077 / 7,685.
  - `collision` tuned at 10,000 bodies: the gather is 3.49 ms, 55% of the
    stage, and 76% of the stage is on main.

### Architecture notes

- Per-item work that grows (gather, sort) threads; main keeps only the
  ordered merge (`.claude/rules/threading.md`).
- Work per body follows what is near it on its own level, never the level's
  height or the level count (`.claude/rules/engine-design.md` § Cost model).
- Rows at rest cost work only when they change; static rows change only
  through structural commands (`.claude/rules/simulation.md`).
- Contact streams are deterministic from range order and sized to the pair
  bound at the seam (`.claude/rules/threading.md`,
  `.claude/rules/budgets-capacities.md`).
- The static split is gated: a control bench must show static-heavy SAP cost
  growing with static count before it lands; otherwise it closes as measured
  not needed. Split contacts equal today's contacts minus static × static
  pairs that produce no response outcome, identical in every field and
  order; a static trigger over a static keeps its trigger event
  (`collision_response.zig:449-450`); dynamic × static capacity terms from 61
  and 62 stay.
- A static body moves only through structural commands
  (`.claude/rules/simulation.md` § Controllers and processors); a Debug
  verification catches an out-of-band move.
- Main holds only the ordered merge of the split's output
  (`.claude/rules/threading.md`); the design decides where resolve runs.
- From [72](slice-72.md) D1: the destructible resolve answered by the
  shared static-collider query. From 75: collision fidelity per band.

### Checklist

- [ ] Broadphase work follows local same-level density. Failure scenario: in a
      tall or deep world the x sweep visits every body in the column and on
      every level before it rejects them (`:760`, `:772`, `:885`, `:897`). The
      sweep order is a `usize` permutation (`order`, `collision.zig:201`)
      sorted by `(min_x, min_y, entity)` (`:1059`) with no level key, and the
      proxies stay in gather order, so every 4-lane candidate block is a
      `gatherFloat4` through it (`:752-757`, `:877-882`) (contiguity audit H2;
      `.claude/rules/memory-performance.md` § Data-oriented design). A level
      key alone leaves the tall shape failing (derived); the order is this
      slice's design. Measured: the per-body growth in `collision-tall` and
      `collision-stacked` above. Pass: time per body flat in aspect and in
      levels (group doc); the sweep reads its proxy columns in sweep order;
      the new contact order is stated for response, audio, and the sensory
      bus, and contacts are otherwise unchanged.
- [ ] Gather and sort off main. Failure scenario: main time grows with
      collision bodies every step (`:327`, `:336`). Measured: the gather is
      2.75 ms of the 2.95 ms main at spread, and the gather plus sort are
      11.4 ms at crowd P 16,384. Pass: in `collision` and `production-step
      --details` the main share is the ordered merge only; serial == threaded
      across range sizes and worker counts; `FailingAllocator` proof on a
      multi-worker step; a pipeline test proves the stages ran on workers.
- [ ] Rows at rest cost no per-step collision work. Failure scenario: an
      inert row is gathered, sorted, and swept every step it sits in a
      collision tier. Measured: the inert axis above. Pass: `production-step`
      collision cost flat in inert rows; static colliders through the two
      items below.
- [ ] Static-collider lists read as contiguous runs (contiguity audit H3).
      Failure: `query_lists` and `chunk_lists`
      (`static_colliders.zig:497-499`) are `ChunkListMap`s, a hashed key →
      head table over a free-list entry pool linked per key
      (`chunk_list_map.zig:194`, `:237-265`), and the row AABBs sit in a
      separate pool with row ids per entity index
      (`static_colliders.zig:481-486`). `ColliderView.queryBox` (`:328`), run
      by every steered agent every step for the obstacle push
      (`steering/avoidance.zig:256`, up to 512 work steps), walks
      `query_lists` per (level, class, cell) (`:445`) through `next_entries`
      and gathers 4 floats per entry by row id (`walkList`, `:451-475`; the
      site's verdict names the pointer chase, `:326-327`); nav walks
      `chunk_lists` per changed chunk (`nav_grid.zig:277`,
      `nav_graph.zig:2987`). `rebuild` appends entries and rows in
      entity-index order (`:669-683`) and `sync` relinks from the free pools,
      so a cell's entries are adjacent only when its statics hold consecutive
      entity indices and no sync has relinked them
      (`.claude/rules/memory-performance.md` § Data-oriented design). Failure
      scenario (derived): a dense base (16 statics per chunk) built in
      interleaved order, or walls built and torn down in play: every agent's
      box query pays a scattered entry load and a scattered row gather per
      listed static, every step. Pass: a box query and a chunk's row walk read
      contiguous runs; a static change re-derives only its own chunks at
      `sync` (`.claude/rules/budgets-capacities.md`); `steering-static-dense`
      gains interleaved-creation and churned variants whose per-agent query
      cost matches the chunk-ordered one. Steering (85) and nav are the
      consumers; the path registry item and the two items below build on this
      structure.
- [ ] Collision's static queries read `StaticColliderSystem`
      (`static_colliders.zig:478`, `:580`) instead of gathering statics every
      step (moved from 71B.1). Failure scenario: every static row is
      gathered and sorted each step (`collision.zig:473`, `:684`). Pass:
      `collision-static-index-change` flat in static count.
- [ ] Static split (moved from 71B.2), gate first: control benches
      `collision-static-heavy-sap`, `collision-static-heavy`, and
      `collision-static-index-change` at three static counts. If the gate
      passes: statics leave the per-step sweep; contacts equal today's minus
      static × static pairs that produce no response outcome, identical in
      every field and order; main holding only the ordered merge; stats.
      Parity tests (triggers over statics, long
      walls, statics with agents, kinematic statics, cross-level,
      straddling, ties, negative coordinates), serial == threaded, an
      out-of-band move caught; `FailingAllocator` proofs; contact reserves
      unchanged.
- [ ] A SIMD verdict at `gatherRange` (`collision_response.zig:436`).
- [ ] The rest of the subsystem checked against the cost model and the rules:
      narrowphase, response, contact streams, level handling, and scope tiers,
      over every file it owns (`systems/collision.zig`,
      `collision_response.zig`, `static_colliders.zig`, `contact_query.zig`,
      `destructible_controller.zig`, `data_system/collision.zig`,
      `data_system/destructible.zig`). Each finding becomes an item here.
- [ ] Path registry lists read as contiguous runs per key (contiguity audit
      L1). Failure: the `path_index` shards are `ChunkListMap`s keyed by
      (level, chunk) (`pathfinding/system.zig:150`), and the threaded
      `nav_evict` jobs (`pathfinding/eviction.zig:250`, `:303`) and the cold
      `evictLevel` (`:60`) walk each changed key's linked list; the site's
      verdict names the pointer chase (`eviction.zig:301-302`)
      (`.claude/rules/memory-performance.md` § Data-oriented design, § Hot
      paths). Failure scenario: after publish churn, an explosion's
      multi-chunk change evicts through scattered entries. Pass: eviction
      reads each key's registrations as one contiguous run; it lands with the
      static-collider item, whose lists use the same `ChunkListMap`
      (`src/game/systems/chunk_list_map.zig`).
- [ ] Benches at the worst-case shapes (thin, tall, deep, dense), with the
      shape asserts landing with each fix (`.claude/rules/tests-benchmarks.md`).
- [ ] Tests: identical contacts and order across worker counts; cross-level,
      tall, and inert fixtures; allocation-free warmed step.
- [ ] Docs: `docs/architecture.md` collision;
      `docs/simulation-tiers-and-pipeline.md` stage list.

### Acceptance checks

- [ ] `collision-tall` and `collision-stacked` meet their pass shape;
      `collision`, `collision-sparse`, and `collision-response-stage` show no
      regression beyond run-to-run spread.
- [ ] `production-step`: collision main time is the ordered merge only, and
      flat in inert rows.
- [ ] Static split (if the gate passes): identical filtered contacts and
      response outcomes across every fixture and worker configuration;
      static-heavy collision cost no longer grows with static count;
      `collision` and `collision-sparse` unchanged.
- [ ] `zig build verify` passes.
