## Slice 86: Collision Subsystem Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](../archive/slice-83.md) (layout and tuners), [Slice 84](../archive/slice-84.md) (branch order) · Related: [Slice 71B](slice-71b.md) (the static structure's 64B row), [Slice 72](slice-72.md) D1 (destructible resolve), [Slice 75](slice-75.md) (collision fidelity per band) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: in progress.** Owner direction 2026-10-11: collision as a whole
subsystem against the current cost model and rules. 71B.1's collision queries
and 71B.2's static split moved here (owner 2026-10-16). Its inert-row item
lands after 88 (index, merged order 9b). Landed on `core_systems` through
`65aa77d`: banded sweep merge, one collision path, contiguous static and
path-registry runs, statics out of the per-step sweep, and response apply
items as occupied 16-row blocks. The response consumer still reads through
`order[]`. That layout item is next. Rows at rest stay after slice 88.

Goal: each body's broadphase work follows its local same-level density,
never column height or level count. Gather and sort leave the main thread.
Rows that do not move (static colliders, items at rest, resource nodes) cost
no per-step collision work while at rest. Every hot loop carries its SIMD
verdict, and the benches cover the worst-case shapes. Contact output and its
order stay deterministic for the order-sensitive consumers.

### Current foundation

Landed behavior. The measured block below is the pre-slice baseline, not
the current bench.

- `CollisionSystem` fills, sorts, and sweeps on the banded path. With no
  workers those same functions run inline. The sweep key includes level and
  strip. Statics are not sweep entries. Dynamic×static pairs come from
  `StaticColliderSystem` query columns. Solid static×static pairs are
  dropped. A static trigger over a static is stored until the collider
  revision changes, and that refresh runs at the collider sync.
- `CollisionResponseSystem.gatherRange` stays scalar. `computeIntentMath`
  streams the intent columns in lanes. With workers, each range groups
  placed intents on a direct table keyed by `movement_row >> 4`. Apply
  items are the occupied 16-row blocks. The consumer still loads intent
  columns through `order[]` and gathers movement columns in the flush.
- Collision runs on `locomotion` and `cognition` tier rows.
- `StaticColliderSystem` stores statics as contiguous per-chunk runs.
  Steering still queries through `ColliderView.queryBox`. Path
  registrations are contiguous per-chunk runs. `ChunkListMap` is gone.
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
  ordered merge (`.grok/rules/threading.md`).
- Work per body follows what is near it on its own level, never the level's
  height or the level count (`.grok/rules/engine-design.md` § Cost model).
- Rows at rest cost work only when they change; static rows change only
  through structural commands (`.grok/rules/simulation.md`).
- Contact streams are deterministic from range order and sized to the pair
  bound at the seam (`.grok/rules/threading.md`,
  `.grok/rules/budgets-capacities.md`).
- The static split is gated: a control bench must show static-heavy SAP cost
  growing with static count before it lands; otherwise it closes as measured
  not needed. Split contacts equal today's contacts minus static × static
  pairs that produce no response outcome, identical in every field and
  order; a static trigger over a static keeps its trigger event
  (`collision_response.zig:449-450`); dynamic × static capacity terms from 61
  and 62 stay.
- A static body moves only through structural commands
  (`.grok/rules/simulation.md` § Controllers and processors); a Debug
  verification catches an out-of-band move.
- Main holds only the ordered merge of the split's output
  (`.grok/rules/threading.md`); the design decides where resolve runs.
- From [72](slice-72.md) D1: the destructible resolve answered by the
  shared static-collider query. From 75: collision fidelity per band.

### Checklist

- [x] Broadphase work follows local same-level density. The live sweep
      already keys level and strip. Confirmed by the collision benches:
      visits per body stay bounded on the tall, stacked, and thin shapes.
      No separate sweep rewrite. Failure scenario: in a
      tall or deep world the x sweep visits every body in the column and on
      every level before it rejects them (`:760`, `:772`, `:885`, `:897`). The
      sweep order is a `usize` permutation (`order`, `collision.zig:201`)
      sorted by `(min_x, min_y, entity)` (`:1059`) with no level key, and the
      proxies stay in gather order, so every 4-lane candidate block is a
      `gatherFloat4` through it (`:752-757`, `:877-882`) (contiguity audit H2;
      `.grok/rules/memory-performance.md` § Data-oriented design). A level
      key alone leaves the tall shape failing (derived); the order is this
      slice's design. Measured: the per-body growth in `collision-tall` and
      `collision-stacked` above. Pass: time per body flat in aspect and in
      levels (group doc); the sweep reads its proxy columns in sweep order;
      the new contact order is stated for response, audio, and the sensory
      bus, and contacts are otherwise unchanged.
- [ ] Gather and sort off main. Failure scenario: main time grows with
      collision bodies every step (`:327`, `:336`). The pre-slice baseline was
      gather 2.75 ms of 2.95 ms main at spread, and gather plus sort 11.4 ms
      at crowd P 16,384. Tuned `production-step` on current code, with the
      fill batch recorded: fill and sort are on workers for all 30 steps.
      Collision main is 92 µs at 1,537 bodies and 104 µs at 6,145 bodies,
      both with no contacts, and 127 µs / 417 µs at 1,272 / 5,424 contacts.
      Pass: in `collision` and `production-step
      --details` the main share is the ordered merge only; serial == threaded
      across range sizes and worker counts; `FailingAllocator` proof on a
      multi-worker step; a pipeline test proves the stages ran on workers.
- [ ] Rows at rest cost no per-step collision work. Failure scenario: an
      inert row is gathered, sorted, and swept every step it sits in a
      collision tier. Measured: the inert axis above. Pass: `production-step`
      collision cost flat in inert rows; static colliders through the two
      items below.
- [x] Static-collider lists read as contiguous runs (contiguity audit H3).
      Landed in `dfc6ad8`. The chunk owns the runs. `steering-static-dense`
      stayed within noise. The entity-obstacle case was a flat gap of about
      10 µs and was not retuned.
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
      (`.grok/rules/memory-performance.md` § Data-oriented design). Failure
      scenario (derived): a dense base (16 statics per chunk) built in
      interleaved order, or walls built and torn down in play: every agent's
      box query pays a scattered entry load and a scattered row gather per
      listed static, every step. Pass: a box query and a chunk's row walk read
      contiguous runs; a static change re-derives only its own chunks at
      `sync` (`.grok/rules/budgets-capacities.md`); `steering-static-dense`
      gains interleaved-creation and churned variants whose per-agent query
      cost matches the chunk-ordered one. Steering (85) and nav are the
      consumers; the path registry item and the two items below build on this
      structure.
- [x] Collision's static queries read `StaticColliderSystem`
      (`static_colliders.zig:478`, `:580`) instead of gathering statics every
      step (moved from 71B.1). Failure scenario: every static row is
      gathered and sorted each step (`collision.zig:473`, `:684`). Pass:
      `collision-static-index-change` flat in static count.
- [x] Static split (moved from 71B.2), gate first. The gate passed. Landed
      in `b126599`. Tuned Debug time is flat in the static count. The two
      points over 1 ms (SAP at 16,384, index-change at 4,096) are accepted.
      ReleaseFast at 65,536 is 94–151 µs on the split. control benches
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
- [x] A SIMD verdict at `gatherRange`. The loop stays scalar: two slot
      resolves and a variable-length write. `computeIntentMath` is the
      lane consumer and streams the intent columns.
- [x] The rest of the subsystem checked against the cost model and the rules:
      narrowphase, response, contact streams, level handling, and scope tiers,
      over every file it owns (`systems/collision.zig`,
      `collision_response.zig`, `static_colliders.zig`, `contact_query.zig`,
      `destructible_controller.zig`, `data_system/collision.zig`,
      `data_system/destructible.zig`). Each finding becomes an item here.
      `contact_query.zig` and `destructible_controller.zig` live under
      `src/game/`, not `systems/`. Response apply had no new hit. The
      destructible cell scan is 72 D1, which replaces that scan. The other
      hits are the items below.
- [ ] Warm fill resolves each input through other stores inside the lane
      group (`collision.zig:1984`, `FillContext.resolve` at `:1918`).
      Failure: a warm step reads `warm_sources`, bounds, and movement
      position and velocity per lane (`memory-performance.md` § Data-oriented
      design, § SIMD and core math). Pass: the fill job packs those columns
      once in slot order, and `fillSlots` loads that scratch with the lane
      kernel and a masked tail.
- [ ] `writeSorted` gathers proxy columns through `entry.slot`
      (`collision.zig:2203`). Failure: after the band is in key order, each
      lane group gathers `min_x/min_y/max_x/max_y` and the warm source by
      slot (`memory-performance.md` § Data-oriented design). Pass: those
      values are stored in entry order and `writeSorted` loads them
      unit-stride. Where the values ride (the sort record, or one pack) is
      open.
- [ ] Intent math keeps a scalar tail (`collision_response.zig:781`).
      Failure: `computeIntentMath` runs the correction and velocity scale
      in lanes, then repeats that math one intent at a time
      (`memory-performance.md` § SIMD and core math). Pass: the remainder
      is that kernel with a mask. Inactive lanes do not write past the
      window.
- [ ] Narrowphase drains lane contacts into scalar calls
      (`collision.zig:2379`). Failure: overlap, normal, and penetration are
      lanes, then each valid lane calls `contactForResolved`
      (`memory-performance.md` § SIMD and core math). Pass: velocity and the
      speed squares stay in that lane loop. Compaction into the window may
      stay scalar.
- [ ] Static-pair materialization looks up entity slots per hit
      (`collision.zig:1654`, `tierAt` at `:1633`). Failure: after the search,
      every hit indexes `row_of_index`, tier, and the movement row
      (`memory-performance.md` § Data-oriented design). Pass: the contact
      loop streams hit columns that already hold entity, movement index,
      allow bit, and velocity. Where those columns are packed is open.
- [ ] Stored trigger pairs re-check tiers on the caller of `update`
      (`collision.zig:1503`). Failure: every step walks every stored pair
      and slices the movement store per pair (`memory-performance.md`
      § Data-oriented design; `threading.md` § What runs where). Pass: main
      does not call `tierAt`. The allow bit is packed before that pass, and
      main reserves once. Where the bit is stored is open.
- [ ] Static hit contacts stay scalar over packed float columns
      (`collision.zig:1650`). Failure: each hit runs `contactForAabbs` on a
      dense hit buffer that the next body reuses
      (`memory-performance.md` § SIMD and core math). Pass: the overlap math
      on that buffer is one masked lane loop. The search stays scalar.
- [ ] Static query overlap. The collision query is uncapped and a cell
      holds one static, so that compare stays the tight scalar loop
      (`scanUncapped`). A lane kernel replaces it only when ReleaseFast
      `collision-static-heavy` is faster than that loop. A copy of short
      runs into a side group is not that kernel. Measured against
      `d9e5f13`: the copy and the in-place prefix were slower or inside a
      wide spread, and the change did not land.
- [ ] Debug static scan chases `DataSystem` per row
      (`static_colliders.zig:629`). Failure: in Debug every tested row
      resolves `row_of_index`, the slot, the body, and the bounds.
      ReleaseFast compiles the call out (`memory-performance.md`
      § Data-oriented design). Pass: the scan does not read `DataSystem`.
      Where a rect compare moves is open.
- [x] Path registry lists read as contiguous runs per key (contiguity audit
      L1). Failure: the `path_index` shards are `ChunkListMap`s keyed by
      (level, chunk) (`pathfinding/system.zig:150`), and the threaded
      `nav_evict` jobs (`pathfinding/eviction.zig:250`, `:303`) and the cold
      `evictLevel` (`:60`) walk each changed key's linked list; the site's
      verdict names the pointer chase (`eviction.zig:301-302`)
      (`.grok/rules/memory-performance.md` § Data-oriented design, § Hot
      paths). Failure scenario: after publish churn, an explosion's
      multi-chunk change evicts through scattered entries. Pass: eviction
      reads each key's registrations as one contiguous run; it lands with the
      static-collider item, whose lists use the same `ChunkListMap`
      (`src/game/systems/chunk_list_map.zig`).
- [x] Collision response's `apply` stage dispatches items that track its work.
      Landed in `65aa77d`. Occupied 16-row blocks: 33 / 129 / 513 at
      1,024 / 4,096 / 16,384 contacts. The separate no-worker path is gone.
      The consumer layout is the next item, not this one.
      Failure: it dispatches one item per fixed band (`collision_response.zig:296`,
      `:307`; at most `max_bands` 64, `:56`), a fixed partition count whose work
      varies behind it (`.grok/rules/threading.md`: "A stage's items are units
      whose count tracks its work (runs, keys, rows), never a fixed partition
      count whose work varies behind it"). Failure scenario: a step of 16 intents
      and one of 16,384 both dispatch at most 64 items (one per band), and a
      crowd landing its intents in one band dispatches one item holding all
      the work, so the stage's item count says nothing about its work and its
      tuner samples a count the work does not track (derived). Pass:
      apply items are units counted by the placed intents or movement-row
      blocks they hold, with results independent of the item count (the
      `max_bands` comment states they already are); `collision-response-stage`
      shows apply items per range tracking intents at 1,024, 4,096, and 16,384;
      serial == threaded across range sizes. A 4-pass radix per gather range
      was measured and rejected. The landing groups on a direct block-id
      table. Tuned Debug at 16,384 contacts was 699 µs to 980 µs, inside the
      base spread, and stands as noise.
- [ ] Response apply reads intent columns through `order[]`
      (`src/game/systems/collision_response.zig` `ApplyLanes.push`) and
      gathers movement columns inside the flush. A partial lane group then
      calls `applyIntentScalar` per row. Failure: the hot read is an index
      permutation, and a short group leaves the lane path
      (`memory-performance.md` § Data-oriented design, § SIMD and core math).
      The movement gather is not exempt. Pass: the intent fields and the
      movement columns the consumer uses are packed once in its read order,
      and the tail is a masked lane batch. Contact order stays. The 16-row
      block ownership stays.
- [x] Collision's banded fill and sort fails the cost model when it runs
      inline (lands before the response and contiguity landings, with the
      item after it: every later collision A/B and the static gate measure
      this path), and production runs it inline whenever the tuner keeps collision
      inline. Failure: the banded path (`sortJob` -> `EntryWriter.finishBand`)
      concatenates the first, second, and spilled runs per band and runs one
      `pdq`, O(E log(E/64)) on an already-settled order, where `buildDirect`
      (`collision.zig:726-731`) sorts the three runs separately and merges them
      (`mergeIntoSorted`, `:731-732`), O(E) on a warm order
      (`.grok/rules/engine-design.md` § Cost model). Measured (scratch
      comparison count, not a bench group): 14 / 17 / 21 comparisons per item
      at n = 4K / 32K / 256K, against a flat 2 for the merge. Pass: each band
      sorts each run and merges them (a merge buffer with its reserve and a
      `FailingAllocator` proof), measured by the collision bench groups at warm
      shapes, serial and threaded.
- [x] After the item above, collision has one path. Landed in `5595275`.
      (`.grok/rules/tests-benchmarks.md` § Test and production code, point
      1). Delete `updateDirect` (`collision.zig:628`), `buildDirect` (`:704`),
      `buildBroadphaseCandidatesDirect` (`:1045`), the no-worker branch in
      `update` (`:587-588`), and the test helper `buildForTest` (`:1697`, which
      calls `buildDirect`; its callers at `:2031`, `:2388`, `:3101` move to the
      one path). Pass: no `*Direct` collision entry remains; the collision
      benches and tests run the production path.
- [x] `CollisionResponseSystem.run` has a separate no-worker serial path.
      Landed with `65aa77d`. Zero workers run the same gather and apply
      their own window.
      (lands with the response gather rework, which edits the same run;
      `collision_response.zig:270`, the `else` of `withWorkers`;
      `.grok/rules/tests-benchmarks.md` § Test and production code, point
      1). Pass: it is removed after a cost check that the stage run inline
      does no worse (`collision-response-stage`, serial and inline, same
      mode).
- [ ] Benches at the worst-case shapes (thin, tall, deep, dense), with the
      shape asserts landing with each fix (`.grok/rules/tests-benchmarks.md`).
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
- [x] Static split (if the gate passes): identical filtered contacts and
      response outcomes across every fixture and worker configuration;
      static-heavy collision cost no longer grows with static count;
      `collision` and `collision-sparse` unchanged. Landed in `b126599`.
      The tuned Debug table is accepted. ReleaseFast at 65,536 is 94–151 µs.
- [ ] `zig build verify` passes.
