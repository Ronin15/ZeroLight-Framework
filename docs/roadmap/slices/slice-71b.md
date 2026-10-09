## Slice 71B: Static Collider Index, Collision Static Split, And Group-Field Prewarm

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md) (71B.1 rows, 71B.3), [Slice 62](slice-62.md) and [Slice 71A](slice-71a.md) (71B.3 only); 71B.2 is bench-gated · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** The fixed group-field threshold, its capacity-audit
follow-up, and the steering level gate are landed; the shared static
structure and steering migration (71B.1), the collision split (71B.2), and
prewarm (71B.3) are open.

Goal:

- Steering and collision read one level-aware static-collider structure,
  owned per chunk, instead of each re-deriving static obstacles; a static
  change (a crate destroyed in an explosion, a node removed) costs only the
  chunks it touches.
- Collision stops re-gathering, re-sorting, and pair-testing static
  colliders every step; its contact stream equals today's minus
  static × static pairs, in identical order.
- Path search prewarms group fields for authored shared goals into idle
  slots under fixed per-step budgets, yielding to demand.
- The group-field threshold is a fixed constant (landed).

### Current foundation

- Collision (`src/game/systems/collision.zig`): `ProxyRow` MAL, per-step
  body gather with three slot lookups per bounds row, warm insertion sort,
  serial SIMD SAP and threaded range SAP with overflow-grow-replay,
  range-order pair merge; sort key `(min_x, min_y, entity.index,
  generation)`. Contact consumers (`CollisionResponseSystem`,
  `AudioController.queueCollision`, `SensoryBus.enqueuePlayerImpacts`) are
  order-sensitive.
- Steering (`src/game/systems/steering.zig`): `rebuildStaticObstacleSnapshot`
  walks every collision response on rebuild; obstacle rows carry the level
  and other-level obstacles are skipped (landed); invalidation through
  `eventInvalidatesStaticObstacleSpatial`.
- Statics move only through structural commands; a created static emits
  `component_changed` with `is_static`.
- Group fields (`src/game/systems/pathfinding/`): `max_group_fields` slots
  (`default_max_group_fields = 4`) with a per-field expansion budget
  (`default_group_field_build_budget = 8192`), reserved O(level cells) at nav
  build and dropped wholesale on every nav update. Slice 64G replaces the
  per-level nav storage they sit on.
- Threshold (landed): `PathfindingSystem.groupFieldThreshold` clamps to a
  fixed `default_min_group_field_agents = 1024` with the ceiling frozen at
  reserve; the demo agent budget is content-sized.
- Benches: `collision`, `collision-sparse`, pathfinding groups.

### Architecture notes

- The chunk owns the static-collider rows, so a local change costs its
  chunks and a dense change (explosion region) costs its dirty chunks in
  parallel; no rebuild over every static
  (`.claude/rules/engine-design.md` § Cost model,
  `.claude/rules/budgets-capacities.md`).
- Membership matches today's steering walk; order is entity order, so
  steering output equals a full rebuild in that order (today's walk follows
  `DataSystem` dense order, which swap-removes reorder, so no incremental
  structure can match it bit for bit); the structure is a cache class in Slice 64B
  (cold vs warm parity).
- 71B.2 is gated: a control bench must show static-heavy SAP cost growing
  with static count before the split lands; otherwise it closes as measured
  not needed. Split contacts equal single-SAP contacts minus static × static
  pairs, identical in every field and order; dynamic × static capacity
  terms from 61 and 62 stay.
- A body moved out of band is caught by per-touch validation (counted,
  marked dirty, live values used) and by a Debug full verification.
- Prewarm sources are authored shared goals (patrol and resource markers,
  spawn anchors); merchants are excluded (they move). Fixed per-step counts
  (one new field, a fixed candidate sweep), a fixed band around the sim
  view, empty slots only, demand evicts prewarm first; no world-scaled
  sectors (`.claude/rules/budgets-capacities.md`,
  `.claude/rules/pathfinding.md`).
- A nav change drops only the group fields on the chunks or levels it
  affects, never all; this needs Slice 64G's chunked nav.
- Prewarmed fields are normalized state for the checksum (64B); the
  step-derived cursor holds none.
- Threaded writes go to range-disjoint buffers reserved before dispatch;
  resolve and merge are serial and proportional to touched statics
  (`.claude/rules/threading.md`).
- VoidLight reference: keep the idea of a commit-built static structure
  queried per dynamic (its 1D sorted search is unsound and degrades in tall
  worlds); reject its world-width-scaled prewarm sectors.

### Checklist

- [x] **71B.1** Fixed group-field threshold with world-size independence,
      ceiling, and clamp tests.
- [x] **71B.1** Capacity-audit follow-up: content-sized demo agent budget,
      threshold ceiling frozen at reserve, nav-memory requirement test.
- [x] **71B.1** Obstacle rows carry the level; same-level gate in steering
      with static level-change invalidation.
- [ ] **71B.1** The shared static-collider structure built in
      [Slice 64G](slice-64g.md) (nav its first consumer) serves steering's
      and collision's queries; Slice 64B cache row with its proving test.
- [ ] **71B.1** Steering reads the shared rows.
- [ ] **71B.2 (gate, first)** Control benches `collision-static-heavy-sap`,
      `collision-static-heavy`, and `collision-static-index-change` at three
      static counts.
- [ ] **71B.2** Grid-eligible statics leave the SAP; dynamic proxies query
      them in the broadphase jobs; serial resolve, orient, and merge into the
      candidate order; stats.
- [ ] **71B.2** Parity tests (triggers over statics, long walls, statics with
      agents, kinematic statics, cross-level, straddling, ties, negative
      coordinates) and serial == threaded; out-of-band move caught.
- [ ] **71B.2** `FailingAllocator` proofs; contact reserves unchanged.
- [ ] **71B.3** Prewarm origin, empty-slot claim, demand promotion and
      eviction, level- or chunk-scoped field drop on nav change.
- [ ] **71B.3** Slice 64B normalization of prewarm fields.
- [ ] **71B.3** Per-step prewarm (release, cursor, start) with tests and a
      `pathfinding-prewarm` bench.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      bench examples.
- [ ] Add the static-mobility writer rule to `.claude/rules/simulation.md`
      when this lands.

### Acceptance checks

- [x] 71B.1 fixed threshold: no budget derives from world size.
- [x] 71B.1 capacity audit: no pathfinding threshold or capacity default
      cites world size.
- [ ] 71B.1: steering suite unchanged; steering no longer walks every
      collision response; a static change costs flat across total static
      count at three sizes.
- [ ] 71B.2: identical filtered contacts and response outcomes across every
      fixture and worker configuration; static-heavy collision cost no
      longer grows with static count; `collision` and `collision-sparse`
      unchanged.
- [ ] 71B.3: `pathfinding-prewarm` shows fewer solves with prewarm on and no
      regression beyond run-to-run spread; otherwise prewarm defaults off
      (numbers in the commit message); a nav change keeps fields on
      unaffected levels.
- [ ] `zig build verify` passes.
