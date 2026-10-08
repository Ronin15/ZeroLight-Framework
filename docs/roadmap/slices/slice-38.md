## Slice 38: Elevation Above The Surface

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 37](../archive/slice-37.md), [Slice 64G](slice-64g.md) · Track: [Long-term gameplay direction](../tracks/gameplay-direction.md)

**Status: not started.** Slice 37 is landed; 64G lands first in the merged
order and rewrites the nav and render sites this slice migrates.

Goal: a world can hold levels above the surface as well as below it. Each
level carries an explicit, stable elevation (0 at the surface, positive above,
negative below), and every "is this the surface / is there a level above"
decision reads elevation instead of storage index 0. Sky exposure derives from
elevation, and the render window looks above and below the active level
symmetrically.

### Current foundation

- `WorldSystem` levels are append-order indices (`level_base_z`, appended only
  through `appendLevelBaseZ`; `addLevel`, `addUndergroundLevelStack` in
  `src/game/world_system.zig`). `world_level: u16` is treated as an opaque
  index everywhere (`DataSystem`, `LevelLink`, `CellCoord`), which can stay.
- Index 0 is still treated as the surface at live sites:
  - `dig_controller.zig`: the hole-vs-tunnel branch (`plan.level == 0`), the
    ramp early-return on level 0, `setEntityLevel`'s `level == 0` return, and
    `digRamp` treating `level - 1` as the plane above;
  - `systems/world_gate.zig`: both walk gates return on `level == 0`;
  - `systems/pathfinding/nav_graph.zig` / `nav_grid.zig`: `markStaticBodies`
    runs only for level 0, so non-surface levels never receive `DataSystem`
    collision bodies (64G replaces this storage; the outcome must carry over);
  - `game_demo_state.placeDemoInterestMarkers` places markers on level 0.
- `DenseLayerRenderWindow` (`world_system.zig`) looks below the active level,
  plus one level above only through `ceiling_when_underground`.
- `worldZForLevel` saturates Z through `i64` math; `k_max_dense_submit_stack_cap`
  (32) bounds the levels drawn in one window, validated at load by
  `validateDenseRenderBudget`.
- Slice 59 (not landed) plans `level_sky_exposed` beside `level_base_z`.

### Architecture notes

- Elevation is a stored per-level fact set when the level is created, never
  derived from index, append order, or `base_z`; levels are added in play at
  the seam (`.claude/rules/budgets-capacities.md`).
- `addLevel` keeps its signature: the first level is the surface, each later
  `addLevel` sits one below the lowest, so every existing multi-level fixture
  keeps its meaning. Levels above the surface come from an explicit elevated
  stack builder (allocation and indexing only; no default fill content).
- Sky exposure is `elevation >= 0`, computed where the level is appended; no
  caller can disagree with elevation. If Slice 59 lands first, its stored flag
  becomes derived here; if this lands first, 59 reads it.
- "Is there a level above" is an elevation-adjacency lookup, not an index
  comparison.
- The render window cap bounds levels drawn, never levels that exist; it does
  not grow with elevation count (`.claude/rules/render.md`).
- Needs from 64G: collision bodies reach nav on every level; per-chunk
  render pages so the window is a selection of levels, not a level-sized
  buffer.
- Persistent: elevation is hashed and saved (Slice 49 classification and the
  Slice 46 section in the same change); a load whose sky exposure disagrees
  with elevation is rejected.

### Checklist

- [ ] Per-level elevation stored at the level-append seam, kept in lockstep
      with every per-level list (an OOM on any reserve leaves all lengths
      equal); elevation accessor.
- [ ] `addLevel` implicit elevation (surface first, then one below the
      lowest); underground stack passes real negative elevation; elevated
      stack builder for positive elevation.
- [ ] Sky exposure derived from elevation (amends 59 if it landed first).
- [ ] Render window with levels above and below in elevation terms; the
      default reproduces today's window exactly.
- [ ] Surface special cases (dig hole vs tunnel, ramp early-return,
      `setEntityLevel`, both walk gates, nav static bodies, demo interest
      markers) migrated to elevation.
- [ ] `digRamp`'s "nothing above" check becomes an elevation-adjacency lookup.
- [ ] Slice 49 / 46 classification and save section for elevation; loader
      rejects inconsistent sky exposure.
- [ ] Docs: `docs/architecture.md` and `docs/simulation-tiers-and-pipeline.md`
      describe elevation, not index 0, as the surface.

### Acceptance checks

- [ ] Elevation, sky exposure, and stack bookkeeping are correct for surface,
      underground, and elevated levels; an `addLevel`-only 3-level fixture
      gives sky exposure `[true, false, false]`.
- [ ] Every migrated site is re-proven on a world whose surface is not index 0
      (an elevated level above it); a non-surface level receives collision
      bodies in nav.
- [ ] `digRamp` adjacency verified on an elevated + surface + underground
      fixture (zig-debug-specialist check recommended; the one non-mechanical
      change).
- [ ] Render window above-only, below-only, and both; default window
      byte-identical to today.
- [ ] With a night environment, perception range scales on an elevated level
      and not on an underground one (once 59 has landed).
- [ ] `zig build verify` passes.
