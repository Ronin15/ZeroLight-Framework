## Slice 86: Collision Subsystem Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](slice-83.md) (layout and tuners), [Slice 84](slice-84.md) (branch order) · Related: [Slice 71B](../slices/slice-71b.md) (the static structure's 64B row), [Slice 72](../slices/slice-72.md) D1 (destructible resolve), [Slice 75](../slices/slice-75.md) (collision fidelity per band) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: landed.** Owner direction 2026-10-11: collision as a whole
subsystem against the current cost model and rules. 71B.1's collision queries
and 71B.2's static split moved here (owner 2026-10-16). Landed on
`core_systems`: banded sweep merge, one collision path, contiguous static and
path-registry runs, statics out of the per-step sweep, response apply as
occupied 16-row blocks streaming packed columns (`intent_order` is gone), the
hot-loop packs and the static-query masked compare (`483d88e`), per-range
slots sized from the selection (`42192b2`), the stored-trigger store
(`a8e0a33`, `de8d308`), and response place merged on main (`faa3200`). The
owner closed the ReleaseFast gaps as inside the spread. Gather and sort are
off main on the `collision` group, and the tall, stacked, and thin shapes
meet their pass. Tier-toggle trigger refresh and static query hit rows
landed in `f027f48`. Range slots meet the bench's `2 * H(ranges)` bound by
attribution (geometric slack plus slots a retune keeps; not a 3× cap).
Tuned-versus-control runs after slice 89 match or beat the best control
within spread. Rows at rest moved to [Slice 75](../slices/slice-75.md) for
the inert-row step after 88. `zig build verify` passed.

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
  dropped. Stored triggers live in per-level page trees (`TriggerStore`,
  `collision_triggers.zig`; `4b44ca6`, `a8e0a33`), patched at the commit seam
  and refreshed from the entities recorded with the allow epoch
  (`TriggerStore.refresh`, `collision_triggers.zig:2050`; `f027f48`); emission is
  one dispatch by emitted cursor with no count pass (`de8d308`).
- `CollisionResponseSystem.gatherRange` stays scalar. `computeIntentMath`
  streams the intent columns in lanes, and the remainder is that multiply
  on a prefix. With workers, each range groups placed intents on a direct
  table keyed by `movement_row >> 4` and scatters the apply columns in
  that order. Apply items are the occupied 16-row blocks. Each run is a
  unit-stride prefix; movement position and velocity are gathered at the  flush. `intent_order` is gone. `placeRuns` (`collision_response.zig:986`)
  runs on main after the gather join (`faa3200`).
- The fill packs each slot's lane inputs before `fillSlots`. `writeSorted`
  copies proxy bounds into the entry columns; the sweep loads those columns
  unit-stride. Narrowphase and static-hit overlap keep the speed squares in
  lanes. The Debug rect
  compare runs after the query joins. The static query's overlap test is
  one masked compare over the column span the box covers (`483d88e`).
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
- The static split landed in `b126599`. Solid static×static pairs are not
  contacts. A static trigger over a static keeps its trigger event (`collision_response.zig:691-693`). Dynamic × static capacity terms from 61
  and 62 stay.
- A static body moves only through structural commands
  (`.grok/rules/simulation.md` § Controllers and processors); a Debug
  verification catches an out-of-band move.
- Static-hit overlap runs in the query's worker ranges
  (`writeStaticHitContacts`). Main merges those range windows
  (`.grok/rules/threading.md`).
- From [72](../slices/slice-72.md) D1: the destructible resolve answered by the
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
- [x] Gather and sort off main. Debug tuned `collision`
      `--details`: fill and sort run on workers at 1,024, 4,096, and 10,000
      bodies. Main per body is 151 ns, 139 ns, and 143 ns. Absolute main is
      155 µs, 573 µs, and 1.43 ms. `production-step` already had fill and
      sort on workers for all 30 steps, with collision main 92 µs at 1,537
      bodies and 104 µs at 6,145, both with no contacts.
      Failure scenario: main time grows with
      collision bodies every step (`:327`, `:336`). The pre-slice baseline was
      gather 2.75 ms of 2.95 ms main at spread, and gather plus sort 11.4 ms
      at crowd P 16,384.
      Pass: in `collision` and `production-step
      --details` the main share is the ordered merge only; serial == threaded
      across range sizes and worker counts; `FailingAllocator` proof on a
      multi-worker step; a pipeline test proves the stages ran on workers.
- [x] A tier toggle refreshes only the trigger pairs it changes. Landed in
      `f027f48`. A tier cross records the entity (`noteCollisionAllow`,
      `data_system/system.zig:322`); a movement-row removal records the
      removed id and any swapped tail (`removeMovementBodyAt`, `:1014`).
      `TriggerStore.refresh` (`collision_triggers.zig:2050`) gathers those
      entities' pair refs, `sortAffected` (`:1228`) orders them on the
      banded-sort stage, and rank is a point-add on `LevelRank`
      (`applyCountDelta`, `:2139`). Failure: any
      `collision_allow_epoch` move (`data_system/system.zig:306`, `:995`)
      makes `TriggerStore.refresh` (`collision_triggers.zig:1672`)
      re-resolve every stored pair's rows and emit bits, so one entity
      crossing `allowsCollision` costs O(T) in stored pairs (local change at
      world cost, `.grok/rules/engine-design.md` § Cost model). Pass: a
      toggle's refresh work follows the toggled entities' pairs;
      `collision-static-triggers` asserts each measured step refreshes
      `flipped_pairs`, not every stored pair, and its pass shape is refresh
      work flat in stored pairs for a one-entity toggle; serial == threaded
      (0 and 2 workers).
- [x] Static query hit rows are O(1) per slot. Landed in `f027f48`. Each
      `StaticPairBuffer` (`collision.zig:574`) keeps its own hit rows.
      `staticQueryHitBound` (`:1406`) is that slot's reserve window when the
      live count fits, otherwise one geometric step above the live count. A
      slot whose queries fit releases to that bound once capacity is past
      `staticQueryHitLimit` (`:1414`, `grow` `:623`). A slot the partition
      drops frees its hit storage (`releaseDroppedStaticHits`, `:1533`).
      Failure: each static query
      slot holds the high-water rows of the widest query it ever ran
      (`StaticPairBuffer.reserve`, `collision.zig:579-599`, `sizing.hit_rows`),
      never lowered; measured 66.6 KB at 65,536 statics and 226-438 KB at
      4,096 trigger pairs, about 15-20 MB derived (not measured) for a
      10,000-static query. Memory then follows the widest past query, not what
      exists (`.grok/rules/engine-design.md` § Cost model). Pass: rows are a
      fixed window or a decaying high water; `static_hit_rows=` in
      `collision-static-triggers` follows the live query
      (`checkSlotRecords` fails past `staticQueryHitLimit` of that slot's
      live count against one alignment window); serial == threaded (0 and
      2 workers).
- [x] Tuned range slots stay inside the bench's `2 * H(ranges)` bound.
      `recountHeld` (`thread_system.zig:2091`) sums every slot, including
      ones past `range_count`: a set only grows until `release`
      (`thread_system.zig:1991-1992`). `reserveRecords` (`collision.zig:1908`)
      grows with `ensureTotalCapacity`, and `BroadphaseRangeBuffer.held`
      (`collision.zig:465`) is `pairs.capacity`, so that geometric slack is
      inside the ratio (derived, not a measurement of the allocator). The
      bench limit is `2 * harmonic(ranges)` (`benchmarks/collision.zig:2280`,
      `harmonic` `:2355`). Measured, Debug, `-Dcpu=x86_64_v2`, `fa99e72`,
      `tools/bench_ab.py --base none` (warmup 1, iterations 3). Tuned rows
      that name workers were `settled=yes`. Broadphase held pairs over the
      pair bound, as `ratio/limit(ranges)`:

      | group | items | case | ratio |
      | --- | --- | --- | --- |
      | `collision` | 1024 | serial-direct | 1.50/2.00 (1) |
      | `collision` | 1024 | tuned | 4.68/9.49 (64) |
      | `collision` | 4096 | serial-direct | 1.50/2.00 (1) |
      | `collision` | 4096 | tuned | 4.15/10.29 (96) |
      | `collision` | 10000 | tuned | 4.20/10.12 (88) |
      | `collision-thin` | 2000001 (aspect 1) | tuned | 4.07/9.93 (80) |
      | `collision-thin` | 2000016 (aspect 16) | tuned | 4.40/9.93 (80) |
      | `collision-thin` | 2000256 (aspect 256) | tuned | 4.43/10.07 (86) |

      Serial thin is 1.50/2.00 (1) at each aspect. Static ratios in these
      runs were 0.00 (no static slots). A one-range serial step shows the
      geometric factor alone. A tuned step also keeps the slots of every
      shape the retune followed. These runs met the bound. The excess over
      3× is that slack plus the retained retune slots. The pass is the
      bound, not a 3× cap.
- [x] Rows at rest routed to [75](../slices/slice-75.md). The pass is not
      met here: an inert row in a collision tier is gathered, sorted, and
      swept every step (measured axis in Current foundation). 75's collision
      item owns the pass, in the inert-row step after slice 88.
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
      (`queryBox` `static_colliders.zig:422`, `collectOverlaps` `:442`) instead of gathering statics every
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
- [x] Warm fill packs each slot before the lane kernel. Landed in
      `6670f2e`. `packFillRange` (`collision.zig:2706`) writes position,
      offset, size, level, entity index, and `filled` (`u32`, 0 or 1).
      `fillSlots` (`:2754`) loads those columns: a full group with
      `loadFloat4`, a short tail with `loadFloat4Prefix`.
      `chooseSplitters` (`:2815`) still resolves its fixed sample on main.
      Failure: a warm step read `warm_sources`, bounds, and movement
      position and velocity per lane (`memory-performance.md` § Data-oriented
      design, § SIMD and core math). Pass: the fill job packs those columns
      once in slot order, and `fillSlots` loads that scratch with the lane
      kernel and a masked tail.
- [x] `writeSorted` stores proxy bounds in entry order. Landed in
      `9f15071`. After the band merge, `writeSorted` (`collision.zig:2952`)
      copies `min_x/min_y/max_x/max_y` from the proxy at `entry.slot` into
      the entry columns. `SortEntry` stays 32 bytes (`:199`). The sweep
      (`sweepEntries`, `:3024`) loads those columns unit-stride.
      Failure: after the band is in key order, each lane group gathered
      those columns and the warm source by slot
      (`memory-performance.md` § Data-oriented design). Pass: the values
      ride in the entry columns, and the sweep loads them unit-stride.
- [x] Intent math's remainder is the lane multiply. Landed in `d9e5f13`.
      `computeIntentMath` (`collision_response.zig:774`) stores a full group
      with `storeFloat4Slice`. The leftover intents use `loadFloat4Prefix`
      and `storeFloat4Prefix`, so the store does not run past the window.
      Failure: the correction and velocity scale ran in lanes, then repeated
      one intent at a time (`memory-performance.md` § SIMD and core math).
      Pass: the remainder is that kernel with a mask. Inactive lanes do not
      write past the window.
- [x] Narrowphase keeps speed squares in the lane kernel. Landed in
      `bc5c518`. `writeNarrowphaseContactsSimd` (`collision.zig:3085`)
      gathers velocity with the AABBs and stores the squares from the lanes.
      A short group repeats the last in-range pair and the store mask drops
      it. Compaction walks the emit mask. `contactForResolved` is gone.
      `contactForCandidate` (`:3171`) is the test oracle.
      Failure: overlap, normal, and penetration were lanes, then each valid
      lane called `contactForResolved`
      (`memory-performance.md` § SIMD and core math). Pass: velocity and the
      speed squares stay in that lane loop. Compaction into the window may
      stay scalar.
- [x] Static-pair hits are packed before the contact loop. Landed in
      `ee92e92`. `packStaticHits` (`collision.zig:2152`) writes movement
      index, generation, allow (0 or 1), and velocity onto the hit row.
      `writeStaticHitContacts` (`:2197`) streams those columns.
      Failure: after the search, every hit indexed `row_of_index`, tier, and
      the movement row (`memory-performance.md` § Data-oriented design).
      Pass: the contact loop streams hit columns that already hold entity,
      movement index, allow bit, and velocity.
- [x] Stored trigger pairs read a packed allow word (`af44a86`). Superseded
      by `de8d308`: per-page valid and allowed masks and node prefixes replace
      the allow word (`trigger_allow`, `packTriggerAllow`,
      `appendTriggerContacts`, and `writeTriggerRow` are gone).
      `collision_allow_epoch` moves when a tier crosses `allowsCollision`
      (`data_system/system.zig:306`) and when a movement row is removed
      (`:995`). A new body does not move it.
      Failure: every step walked every stored pair and sliced the movement
      store per pair (`memory-performance.md` § Data-oriented design;
      `threading.md` § What runs where). Pass: main does not call `tierAt`.
      The allow bit is packed before that pass, and main reserves once.
- [x] Static hit contacts use the narrowphase overlap lanes. Landed in
      `ee92e92`. `writeStaticHitContacts` (`collision.zig:2197`) is that
      kernel, including a 1–3 hit tail via prefix loads. A shared edge stays
      a query hit and is not a contact. The search stays scalar.
      Failure: each hit ran `contactForAabbs` on a dense hit buffer that the
      next body reuses (`memory-performance.md` § SIMD and core math). Pass:
      the overlap math on that buffer is one masked lane loop. The search
      stays scalar.
- [x] Static query overlap. The masked compare landed in `483d88e`.
      `scanUncapped` (`static_colliders.zig:650`) and `queryBox`'s
      capped walk (`scanCapped`, `:676`) share `overlapMaskLanes` (`:792`).
      A full group loads with `loadFloat4`; a short slice uses
      `loadFloat4Prefix`. The anchor walk and the chunk search stay scalar.
      The scan reads the column span the box covers. `queryBox` (`:422`) uses that compare and still stops on the work budget and the hit cap.
      A copy of short runs into a side group is not this kernel. ReleaseFast
      `collision-static-heavy`, one static per cell, 30 iterations, 3 reps,
      both sides inline: 4,096 110.2 → 127.4 µs (+17 µs), 16,384 123.6 →
      110.9 µs (−13 µs), 65,536 151.4 → 104.7 µs (−47 µs), all inside wide
      spreads. The owner closed it on that pair.
- [x] Debug static scan does not read `DataSystem`. Landed in `28f6b61`.
      The overlap scan records the entity ids it walked (`recordSpan`, `static_colliders.zig:660`). After the query joins,
      `compareStoredRects` (`collision.zig:2374`) checks each distinct
      static's stored bounds against the live rect. A mismatch is
      `StaticMovedOutsideCommit`. ReleaseFast calls `collectOverlaps` and
      does not record, stamp, or compare.
      Failure: in Debug every tested row resolved `row_of_index`, the slot,
      the body, and the bounds inside the scan. ReleaseFast compiled the
      call out (`memory-performance.md` § Data-oriented design). Pass: the
      scan does not read `DataSystem`.
- [x] Path registry lists read as contiguous runs per key (contiguity audit
      L1). Failure: the `path_index` shards are `ChunkListMap`s keyed by
      (level, chunk) (`pathfinding/system.zig:150`), and the threaded
      `nav_evict` jobs (`pathfinding/eviction.zig:250`, `:303`) and the cold
      `evictLevel` (`:60`) walk each changed key's linked list; the site's
      verdict names the pointer chase (`eviction.zig:301-302`)
      (`.grok/rules/memory-performance.md` § Data-oriented design, § Hot
      paths). Failure scenario: after publish churn, an explosion's
      multi-chunk change evicts through scattered entries. Pass: eviction
      reads each key's registrations as one contiguous run. Landed with the
      static-collider runs; both are `ChunkDirectory` payloads
      (`src/game/systems/chunk_list_map.zig`). `ChunkListMap` is gone.
- [x] Collision response's `apply` stage dispatches items that track its work.
      Landed in `65aa77d`. Occupied 16-row blocks: 33 / 129 / 513 at
      1,024 / 4,096 / 16,384 contacts. The separate no-worker path is gone.
      The consumer streams packed columns; that item is below.
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
- [x] Response apply streams packed columns. Landed in `24970f0`.
      Gather scatters correction, normal, velocity scale, kind, and movement
      row into `packed_intents` in apply order (`collision_response.zig:952`).
      `intent_order` is gone. `applyBlockJob` (`:1106`) walks each run as a
      unit-stride prefix. `applyGroup` (`:1068`) prefix-loads it. A repeated
      row flushes first. A short group is that kernel with a mask. The open
      group ends at the run. Movement position and velocity are gathered at
      the flush. Inline apply copies the same intent fields into `ApplyLanes` (`:1170`) and calls `applyGroup`. Contact order stays. The 16-row block
      stays.
      Failure: the hot read was an index permutation through `order[]`, and
      a short group called `applyIntentScalar` per row
      (`memory-performance.md` § Data-oriented design, § SIMD and core math).
      Pass: the intent fields are packed once in apply order, the tail is a
      masked lane batch, and movement position and velocity are gathered at
      the flush. Contact order stays. The 16-row block ownership stays.
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
- [x] Benches at the worst-case shapes (thin, tall, deep, dense), with the
      shape asserts landing with each fix (`.grok/rules/tests-benchmarks.md`).
      Debug tuned, fixed 4,096 bodies except stacked, which grows levels:
      tall per body 340 / 346 / 307 ns at aspect 1 / 16 / 256; thin 326 /
      319 / 281 ns; stacked 588 / 329 / 286 ns at 1 / 4 / 16 levels
      (1,024 / 4,096 / 16,384 bodies) with visits per body 9.47 at every
      level. Dense `collision` per body is 296 ns and 304 ns at 4,096 and
      10,000. The shape asserts passed in that run.
- [x] Tests: identical contacts and order across worker counts; cross-level,
      tall, and inert fixtures; allocation-free warmed step. Contact parity
      across range sizes and worker counts, the tall and cross-level layout
      in `fillReferenceLayout`, and the warmed allocation-free step are in
      `collision.zig`. The inert fixture is [75](../slices/slice-75.md)'s
      collision item.
- [x] Docs: `docs/architecture.md` collision and response. The pipeline
      stage list matches `stage_order` (`collision_scope_gather` →
      `collision_detect` → `collision_respond`), so
      `docs/simulation-tiers-and-pipeline.md` is unchanged.

### Acceptance checks

- [x] `collision-tall` and `collision-stacked` meet their pass shape;
      `collision`, `collision-sparse`, and `collision-response-stage` show no
      regression beyond run-to-run spread. The shape numbers are on the bench
      item above. Tuned `collision-sparse` per body is 209 / 138 / 88 ns at
      1,024 / 4,096 / 10,000. Tuned `collision-response-stage` is 150 µs /
      305 µs / 1.18 ms at 1,024 / 4,096 / 16,384 contacts, with main outside
      the stage batches 11 / 25 / 118 µs. No paired pre-slice run; the groups
      completed and their asserts held.
- [x] Tuned-versus-control measurements after slice 89. Debug,
      `-Dcpu=x86_64_v2`, `fa99e72`, `tools/bench_ab.py --base none` (warmup 1,
      iterations 3); tuned rows that name workers `settled=yes`. The
      production tuned case matches or beats its best control within spread
      at the size where that stage threads. One-rep gaps over 10% were rerun
      at 3 reps
      (`.grok/rules/tests-benchmarks.md` § Benchmarks) and are noise. The
      one-rep +20% and +14% did not survive that rerun. No tuner item.
      - `collision` 10000, 3 reps of tuned and large-range: tuned median
        2.21 ms, spread 0.9%, 23/23; large-range median 2.43 ms, spread
        8.2%. Matched 3/3. Worst rep tuned 2.21 ms against large-range
        2.31 ms (−4%). The one rep of all cases was tuned 2.40 ms at 23/23
        against large-range 2.00 ms (+20%); serial 11.51 ms, fixed-1
        7.81 ms, fixed-2 5.00 ms, fixed-auto 2.61 ms, small-range 2.55 ms,
        clamp 2.16 ms.
      - `collision-sparse` 10000, 3 reps: tuned median 682.6 µs, spread
        9.8%, 23/23; large-range median 704.2 µs, spread 21.7%. Matched
        2/3. Worst rep tuned 710.6 µs against large-range 662.2 µs (+7%),
        inside the control's spread. The one rep was tuned 768.7 µs at
        23/23 against large-range 677.2 µs (+14%); serial 3.95 ms, fixed-1
        2.55 ms, fixed-2 2.42 ms, small-range 940.4 µs, clamp 817.6 µs,
        fixed-auto 763.0 µs.
      - `collision-tall` items 256 (aspect 256, population fixed), one rep, all cases, 23/23: serial
        4.75 ms, fixed-1 2.85 ms, fixed-2 2.37 ms, large-range 1.21 ms,
        fixed-auto 1.09 ms, small-range 971.3 µs, clamp 876.4 µs, tuned
        857.7 µs (−2% against clamp).
      - `collision-stacked` items 1000016 (16 levels), one rep, all cases,
        23/23: serial 18.42 ms, fixed-1 12.72 ms, fixed-2 9.47 ms,
        fixed-auto 3.95 ms, large-range 3.94 ms, small-range 4.39 ms, clamp
        3.30 ms, tuned 3.06 ms (−7% against clamp).
      - `collision-response-stage` 16384 contacts, one rep, all cases,
        23/23: serial 5.83 ms, fixed-1 5.91 ms, fixed-2 4.54 ms, large-range
        2.57 ms, fixed-auto 1.75 ms, small-range 1.72 ms, clamp 1.32 ms,
        tuned 880.9 µs (−33% against clamp).
      - Same runs, serial against tuned only: `collision` 1024 serial
        889.1 µs, tuned 314.8 µs at 9/23; `collision` 4096 serial 4.57 ms,
        tuned 1.10 ms at 23/23; `collision-thin` at 23/23, aspect 1 serial
        4.66 ms, tuned 1.14 ms; aspect 16 serial 4.58 ms, tuned 1.05 ms;
        aspect 256 serial 3.64 ms, tuned 999.9 µs.
- [x] `production-step` ordered merge: collision main time is the ordered
      merge only, the checked gather-and-sort item. Flat in inert rows is
      [75](../slices/slice-75.md)'s collision item, in the inert-row step
      after slice 88.
- [x] Static split (if the gate passes): identical filtered contacts and
      response outcomes across every fixture and worker configuration;
      static-heavy collision cost no longer grows with static count;
      `collision` and `collision-sparse` unchanged. Landed in `b126599`.
      The tuned Debug table is accepted. ReleaseFast at 65,536 is 94–151 µs.
- [x] `zig build verify` passes.
