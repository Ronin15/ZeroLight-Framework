## Slice 58: Seeded Procedural World Generation

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 57](slice-57.md), [Slice 61](slice-61.md), [Slice 64G](slice-64g.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 64G (chunk-owned terrain and nav), 49 (world
seed), 57 (items for dig yields), and 61 (resource-node kinds and template).
Slice 38 rebinds strata depth to elevation when it lands; 62 extends the spec
with spawn anchors; 65C streams generation on the lane; 74 creates worlds in
play through this generator.

Goal: a data-authored generator (biomes, palettes, surface features, resource
nodes, underground strata and veins, spawns, resource interest markers)
replaces the hard-coded one. A world is a pure function of its seed, the
spec, and its dimensions, generated chunk by chunk into 64G's chunk-owned
terrain, so creating a world costs its own chunks and the same seed gives the
same golden hash on serial and threaded runs and in Debug and ReleaseFast.

### Current foundation

- `WorldSystem.initProcedural` / `initProceduralFromMeta`
  (`src/game/world_system.zig`) fill the surface through the threaded
  per-chunk `buildProceduralChunk` over hard-coded `proceduralGroundTile`
  rules, then the serial `addProceduralSparseTiles`; the private `hash2` is
  not `src/core/rng.zig`.
- `WorldBuildConfig` has a literal `seed` default and `chunk_size_tiles = 16`;
  Slice 49 sets the seed from `session_seed.derive(.worldgen_procedural)`.
- Underground levels are a uniform `dirt` fill (`addUndergroundLevelStack`);
  uniform layers (`uniform_fill_tile`) drive the nav and perception fast
  paths.
- `levelBlocksMovement` scans every dense band of the world and the level's
  whole sparse list per query; 64G replaces this storage.
- Demo spawns are hard-coded grids (`spawnTestSquares`, underground pockets)
  sized by the demo constant `battle_scale_demo_mover_count`; obstacles and
  interest markers are fixed (`game_demo_state.zig`).
- `InterestMarkerStore` (`world_interest.zig`) is a fixed 128-slot inline
  store.
- Tileset: named tiles with `walkable` / `blocks_movement` / `blocks_vision`
  flags (`assets/sprites/world_tileset.json`, strict
  `src/assets/world_tileset_meta.zig`).

### Architecture notes

- Owner direction: chunk `(level, cx, cy)` is the unit of storage and work;
  worlds are created and destroyed in play. Generation writes chunks, never a
  level-sized array, and nothing is sized to world extent
  (`.claude/rules/budgets-capacities.md`).
- Generation is integer-only and order-independent: every draw is a pure
  function of seed, cell, and level, so chunks generate independently and in
  parallel (`.claude/rules/threading.md`, `.claude/rules/simulation.md` §
  Determinism). Integer value noise is a new `core` primitive.
- Populations, nodes, features, and markers follow content density in the
  spec; nothing is truncated by a cap and nothing is sized from a demo
  constant (`.claude/rules/engine-design.md` § Target scale). Spec tables
  have load-time format bounds only.
- Uniform (all-open, all-blocking) chunks stay on 64G's cheap path; mixed
  chunks (water beside grass, veined strata) stay correct for nav and
  perception.
- Underground strata are solid until dug, preserving dig semantics.
- Dig yields: a dig of a yield tile creates world items through Slice 57's
  template, rolled per cell and level on `seed.derive(.dig_yield)`, under the
  dig stage's per-step budget; never refused for capacity.
- Resource interest markers mark node clusters; marker storage grows with
  content.
- Generation reads only immutable inputs and writes only the world under
  construction, so 65C can run it on the lane and 74 can run it for a world
  created in play.
- Persistent: per-chunk biome is hashed and saved (Slices 49 / 46, same
  change).
- VoidLight: port biome classification, per-biome densities, deposit rarity,
  and decoration weights as data; do not port its implementation-defined
  distributions, float Perlin, order-dependent streams, rivers, or scans.

### Checklist

- [ ] Integer value noise in `src/core/` with determinism, range,
      continuity, and seed-sensitivity tests.
- [ ] Strict `worldgen.json` spec loader resolving tiles, archetypes, items,
      and node kinds; shipped spec installed.
- [ ] Chunk-parallel generation into chunk-owned terrain with a
      deterministic commit; old generator and `hash2` removed.
- [ ] Per-chunk biome stored and exposed; hashed and saved.
- [ ] Generated spawns, resource nodes, and player spawn adopted by the
      gameplay state, at content density with no cap.
- [ ] Uniform and mixed chunk classification kept correct for nav and
      perception after generation and after digs.
- [ ] Dig yields through Slice 57's world-item template.
- [ ] (added by Slice 69) Resource interest markers at node clusters;
      `InterestMarkerStore` grows with content instead of a fixed slot count.
- [ ] Docs: `docs/architecture.md` (worldgen ownership, seed flow, chunked
      generation), authoring and golden-update procedure in
      `docs/development-workflow.md`, dig yields in
      `docs/simulation-tiers-and-pipeline.md`.

### Acceptance checks

- [ ] Three pinned seeds match literal golden hashes under `zig build test`
      and `--release=fast`; different seeds differ.
- [ ] Serial and N-worker generation give the identical hash.
- [ ] Loader rejects malformed specs (unknown names, missing default biome,
      non-blocking strata, out-of-range values).
- [ ] No spawn lands on blocking terrain or a node; spawn and node order is
      deterministic; counts follow spec density on worlds of different size.
- [ ] Mixed and uniform chunks give nav and perception results equal to a
      per-cell recount.
- [ ] Dig yield: one deterministic world item per yield dig; the same cell
      on two levels rolls independently.
- [ ] (added by Slice 69) Markers coincide with surviving nodes; a spec
      without markers yields none.
- [ ] Bench `worldgen`: generation cost linear in chunk count across three
      world sizes; serial and threaded cases.
- [ ] (added by Slices 68A–68C) The 68A re-baseline procedure is run on a
      generated world and its rows recorded.
- [ ] Unit tests stay within the fixture rule
      (`.claude/rules/tests-benchmarks.md`); `zig build verify` passes.
