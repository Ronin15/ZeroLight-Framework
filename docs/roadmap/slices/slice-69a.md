## Slice 69A: Worldgen Breadth — Caves, Structures And Villages, Autotile Edge Sets

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 61](slice-61.md), [Slice 62](slice-62.md), [Slice 65C](slice-65c.md), [Slice 64G](slice-64g.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 58 (generator, spec, goldens), 61 (node kinds
for cave nodes and sockets), 62 (spawn tables and anchors for village
sockets), 65C (the streamed generation job shape), and 64G (level links
stored with their endpoint chunks). After 71A when both are planned (71A's
post goals already use the agent's level). Strata depth follows 58: level
index today, elevation after 38.

Goal: generated worlds gain walkable caves with surface entrances, cave
nodes, and in-cave spawns; authored structures and multi-structure villages
whose sockets place spawns, nodes, interest markers, and a settlement anchor;
and biome edges autotiled from the tileset's transition sets. Generation
stays integer-only, chunk-parallel, and a pure function of seed, spec,
structures, and dimensions; Slice 58's goldens are unchanged and new goldens
cover the new features.

### Current foundation

- Dig: `DigConfig.fromMeta` resolves the tunnel tile (`cave_0`) and ramp tile
  (`cobblestone`); `digRamp` builds a bidirectional ramp `LevelLink` on one
  cell; a fall carves its landing cell (`src/game/dig_controller.zig`).
- Level links are a world-wide list on `WorldSystem` (`addLevelLink`,
  `rampLinkOtherLevel`); 64G stores them with their endpoint chunks.
- Tileset: `assets/sprites/world_tileset.json` ships `autotile_sets`
  (`grass_dirt`, `water_shore`, `path`; `transition_16`, 16 ids each), packed
  by `tools/pack_atlas.py` and linted; `world_tileset_meta.zig` ignores them
  (no field, `ignore_unknown_fields = true`). The art convention
  (`tools/tileset_quality.py`) makes indices 12–15 duplicates of 11.
- Tile flags: `cobblestone`, `stone_floor`, `rotten_planks`, and `cave_*` are
  walkable; `brick_wall_*` and `structure_*` block movement and vision.
- `InterestMarkerStore` (`world_interest.zig`) has kinds
  `investigate|cover|resource|patrol`; 58 grows it with content.
- AI goal level: `writeAiIntentsJob` (`systems/ai.zig`) writes
  `NavigationIntent` without `goal_level`, so it defaults to 0; every gathered
  row already carries its level. Pathfinding routes a cross-level goal through
  link edges, so an underground agent's wander goal pulls it to the surface.

### Architecture notes

- Owner direction: chunks own terrain; worlds are created in play
  (`.claude/rules/budgets-capacities.md`). Caves, stamps, and entrances are
  chunk content generated with the world; nothing is sized to world extent.
- Every placement is content: sites, structures, sockets, entrances, and
  walls follow spec density and site geometry and are never truncated by a
  cap; spec tables have load-time format bounds only.
- Placements are confined to their own site cell, so no two overlap by
  construction; site selection reads only pure functions of seed and spec,
  and jobs read it as immutable input (`.claude/rules/threading.md`).
- Entrances are ordinary ramp links (dig's shape), so plane traversal and
  nav need no new path.
- Cross-level goals are 73's (archetype data); a goal in another pocket may
  route through entrances.
- Cave layers are mixed terrain; dig, fall, and nav patch paths are
  unchanged.
- Settlement anchors from village sockets feed Slice 62's important roster.
- Autotile: the duplicate indices 12–15 become inner corners (offline art
  regeneration; tile ids and names unchanged); blocking never depends on mask
  shape.
- No new persistent state: tiles, links, markers, anchors, and biomes are
  already hashed and saved.
- VoidLight: port settlement records, per-biome village weights, member
  lists, and the no-water footprint check; do not port target-count retry
  loops, distribution draws, trig scatter, order-dependent merges, or
  pairwise distance checks.

### Checklist

- [ ] Tileset metadata parses `autotile_sets` with validation; inner-corner
      art regenerated; `docs/atlas-asset-workflow.md` records the amended
      index table.
- [ ] Pinned cardinal/diagonal mask → transition index table with exhaustive
      tests.
- [ ] Spec keys for caves, structures, villages, edge sets, and site size,
      with rejection tests; strict `structures.json` loader; shipped content
      installed.
- [ ] Caves: pure cave predicate, cell precedence, cave nodes, cave spawns,
      ranked entrances committed as ramp links; player spawn skips entrances.
- [ ] Structures: site selection in the plan step, footprint terrain check,
      jobs suppress features under footprints, stamping and sockets at
      finish; every surviving site placed.
- [ ] Every ranked entrance commits as a ramp link; none is skipped for
      capacity (64G never refuses a link).
- [ ] AI goal level: AI intents carry their goal's level, not a default 0.
- [ ] Gameplay state adopts the authored records through 58, 61, and 62's
      existing adoption paths.
- [ ] Docs: `docs/architecture.md` (worldgen breadth, site model, goal
      level); structures authoring and golden update in
      `docs/development-workflow.md`.

### Acceptance checks

- [ ] Slice 58's goldens unchanged in Debug and ReleaseFast; three new
      goldens (16×16, one underground level, hut, village, shore lake, caves
      with two entrances) pass with 0 and N workers and through 65C's lane
      batches and fallback.
- [ ] No two placements overlap; nothing ranked lies under a stamp; a site
      over water is rejected; every surviving site is placed identically
      across thread counts.
- [ ] A village anchor socket becomes a live anchor whose roster fills
      through 62.
- [ ] Caves: cave layers give nav results equal to a per-cell recount;
      entrances resolve from both ends and plane traversal crosses them.
- [ ] A cave agent's same-level goals keep it in its pocket over 600 steps;
      a surface agent's intents are bit-identical to before.
- [ ] Autotile edge cells match a per-cell recomputation, including an
      inner-corner cell.
- [ ] Bench `worldgen-breadth` beside `worldgen`: cost linear in chunk count.
- [ ] Unit tests stay within the fixture rule; `zig build verify` passes.
