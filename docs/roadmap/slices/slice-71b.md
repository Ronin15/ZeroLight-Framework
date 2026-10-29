## Slice 71B: Static Collider Index And Group-Field Prewarm

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md) (71B.1 rows, 71B.3), [Slice 62](slice-62.md) and [Slice 71A](slice-71a.md) (71B.3 only) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** The fixed group-field threshold, its capacity-audit
follow-up, the steering level gate, the shared static structure, and
steering's migration onto it (64G) are landed. Collision's move onto the
structure (71B.1) and the collision static split (71B.2) moved to
[Slice 86](../archive/slice-86.md) (owner 2026-10-16). The structure's 64B cache row
and prewarm (71B.3) are open.

Goal:

- Steering reads one level-aware static-collider structure, owned per
  chunk, instead of re-deriving static obstacles; a static change (a crate
  destroyed in an explosion, a node removed) costs only the chunks it
  touches (landed). Collision's reads and the static split are Slice 86's.
- Path search prewarms group fields for authored shared goals into idle
  slots under fixed per-step budgets, yielding to demand.
- The group-field threshold is a fixed constant (landed).

### Current foundation

- `StaticColliderSystem` (`src/game/systems/static_colliders.zig`, 64G): one
  row per static navigation obstacle (AABB, level, cell span) listed per
  (level, chunk) in entity order, held as contiguous span and float columns
  per chunk (`dfc6ad8`); the commit-seam sync runs plan, touch, group, apply,
  rewrite, and install as tuned worker stages (`6045eda`,
  `static_colliders.zig` `RebuildStage` tuners), plus a size-class query tier with per-chunk anchor bitmaps.
  Nav, steering, and collision read it through `ColliderView`; steering's box
  query (`queryBox`) visits at most 64 hits and 512 probes per agent, so a
  static change costs steering nothing (`steering-static-change` flat in
  static count, `173cc17`). Collision's static pairs come from those columns
  (Slice 86, `b126599`); statics are not sweep entries.
- Statics move only through structural commands; a created static emits
  `component_changed` with `is_static`.
- Group fields (`src/game/systems/pathfinding/`): `max_group_fields` slots
  (`default_max_group_fields = 4`) with a per-field expansion budget
  (`default_group_field_build_budget = 8192`); each field's storage is a pool of
  nav-chunk cell blocks reserved at its first build (64G), and a nav change
  drops only the fields with a costed cell within one cell of a changed cell
  (a rebuilt level drops its own fields). An active goal's field is never
  taken.
- Threshold (landed): `PathfindingSystem.groupFieldThreshold` clamps to a
  fixed `default_min_group_field_agents = 1024` with the ceiling frozen at
  reserve; the demo agent budget is content-sized.
- Benches: pathfinding groups.

### Architecture notes

- The chunk owns the static-collider rows, so a local change costs its
  chunks and a dense change (explosion region) costs its dirty chunks in
  parallel; no rebuild over every static
  (`.grok/rules/engine-design.md` § Cost model,
  `.grok/rules/budgets-capacities.md`).
- Membership matches today's steering walk; order is entity order, so
  steering output equals a full rebuild in that order (today's walk follows
  `DataSystem` dense order, which swap-removes reorder, so no incremental
  structure can match it bit for bit); the structure is a cache class in Slice 64B
  (cold vs warm parity).
- Prewarm sources are authored shared goals (patrol and resource markers,
  spawn anchors); merchants are excluded (they move). Fixed per-step counts
  (one new field, a fixed candidate sweep), a fixed band around the sim
  view, empty slots only, demand evicts prewarm first; no world-scaled
  sectors (`.grok/rules/budgets-capacities.md`,
  `.grok/rules/pathfinding.md`).
- A nav change drops only the group fields on the chunks or levels it
  affects, never all; this needs Slice 64G's chunked nav.
- Prewarmed fields are normalized state for the checksum (64B); the
  step-derived cursor holds none.
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
      [Slice 64G](slice-64g.md) (nav its first consumer): Slice 64B cache row
      with its proving test. Steering's queries landed (`173cc17`);
      collision's moved to Slice 86.
- [x] **71B.1** Steering reads the shared rows (64G `173cc17`).
- [ ] **71B.3** Prewarm origin, empty-slot claim, demand promotion and
      eviction, level- or chunk-scoped field drop on nav change (the
      chunk-scoped drop landed with 64G, `83172ce`, `a869e15`).
- [ ] **71B.3** Slice 64B normalization of prewarm fields.
- [ ] **71B.3** Per-step prewarm (release, cursor, start) with tests and a
      `pathfinding-prewarm` bench.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      bench examples.
- [x] Add the static-mobility writer rule to `.grok/rules/simulation.md`
      (landed with 64G: a static body changes only through structural
      commands).

### Acceptance checks

- [x] 71B.1 fixed threshold: no budget derives from world size.
- [x] 71B.1 capacity audit: no pathfinding threshold or capacity default
      cites world size.
- [x] 71B.1: steering suite unchanged; steering no longer walks every
      collision response; a static change costs flat across total static
      count at three sizes (`steering-static-change` 10/1,000/10,000, `173cc17`).
- [ ] 71B.3: `pathfinding-prewarm` shows fewer solves with prewarm on and no
      regression beyond run-to-run spread; otherwise prewarm defaults off
      (numbers in the commit message); a nav change keeps fields on
      unaffected levels.
- [ ] `zig build verify` passes.
