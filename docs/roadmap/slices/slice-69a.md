## Slice 69A: Worldgen Breadth — Caves, Structures And Villages, Autotile Edge Sets

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 61](slice-61.md), [Slice 62](slice-62.md), [Slice 65C](slice-65c.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on:

- **58**: the generator, the spec loader, `noise.valueNoise2`, field seeds,
  per-(level, chunk) jobs, the striped arena and `JobSummary`, `UniformBlocking`,
  `chunk_biomes`, `GeneratedWorld`, and the golden-hash harness.
- **61**: `ResourceNodeKindCatalog` and `resourceNodeTemplate`, for cave nodes
  and node sockets.
- **62**: `SpawnTableId`, the `GeneratedWorld.anchors` path, and
  `spawn_anchor_capacity`, for village anchor sockets.
- **33** (landed): archetype ids for spawn sockets.
- **65C**: Slice 58's entry-point split (`plan`, `ChunkGenContext`,
  `generateJobRange`, `commitJob`, `finish`) and `WorldGenStream`, so every
  69A pass runs inside that job shape and keeps golden parity across lane
  speeds.
- **71A** (when landed; merged order puts it first): its post goals already
  write `NavigationIntent.goal_level = row level`. 69A generalizes that rule
  to every behavior (see "AI goal level").

It also includes the resource-marker cap from the Slice 58 addition below.
Strata depth follows Slice 58's rule: the level index today, and
`-levelElevation` after Slice 38. Lands after 58, 61, 62, and 65C.

Goal: the generated world gains three things:

- **Caves:** walkable underground pockets with bounded surface entrances,
  harvestable cave nodes, and in-cave spawns.
- **Authored structures and multi-structure villages:** floors, walls, and
  sockets that place spawns, nodes, interest markers and a Slice 62 settlement
  anchor.
- **Autotiled biome edges:** edges use the tileset's existing 16-tile
  transition sets.

All of this is load-time, integer-only and chunk-parallel. The output is still
a pure function of `(WorldBuildConfig.seed, spec, structures, dimensions)`.
Slice 58's three pinned goldens stay unchanged, and three new goldens cover the
new features.

### Current foundation (do not rebuild)

- **Slice 58 (planned contract)**:
  - Modules: `worldgen/spec.zig` (strict, `ignore_unknown_fields = false`,
    `version == 1`), `worldgen/generate.zig`, `worldgen/spawns.zig`, and
    `core/noise.zig` (`valueNoise2(seed, x, y, cell_size, octaves) u16`).
  - Seeds and draws: each field seed is `rng.mix64(world_seed, 0, 0,
    field_salt)`, and each per-cell draw is `rng.mix64(field_seed, cell_index,
    level, salt)`.
  - Jobs: one job per (level, chunk), with `items_per_range = 1`, a striped
    output arena and `JobSummary {feature_count, node_count, spawn_count,
    all_blocking, none_blocking, center_biome}`. Each 4×4 block draws one
    jittered feature-or-node candidate.
  - Commit: a main-thread commit in level → chunk → slot order. Spawn and node
    caps are hash-ranked. Survivors are sorted by (level, y, x). The player
    spawn uses a ring search out to 32 cells. Generation refuses with
    `WorldGenChunkFeatureMisaligned` and `WorldGenNoWalkableSpawn`.
  - Fixed caps: `max_worldgen_resource_nodes = 2048`.
  - Goldens: three seeds on a 16×16 world with chunk size 8 and 1 underground
    level.
- **Dig tiles and ramps.**
  - `DigConfig.fromMeta` resolves `tunnel_tile = "cave_0"` and `ramp_tile =
    "cobblestone"` (`src/game/dig_controller.zig:57-62`).
  - `digRamp` builds the ramp link shape `{kind = .ramp, level_a = lower,
    level_b = above, same cell, traversal_cost = 1, bidirectional = true}`
    (`:179-193`).
  - A fall carves its landing cell to the tunnel tile (`:294-297`).
  - Level links: `WorldSystem.ensureLevelLinkCapacity` / `addLevelLink` /
    `rampLinkOtherLevel` (`src/game/world_system.zig:1485-1514,1447-1454`).
    Since Slice 64E's link-growth review follow-up, `ensureLevelLinkCapacity`
    and `addLevelLink` grow only an unreserved world; on a reserved world they
    return `error.LevelLinkRoomUnreserved` past the limit (only the dig commit
    seam's admitted growth, `reserveLevelLinks`, raises it).
    `LevelLinkLimitReached` is gone. Generation runs on the unreserved world,
    before `GameDemoState.init`'s `reserveLevelLinks`.
- **Nav memory gate is structural.**
  - `NavMemoryBudget.requiredBytes` sizes per-level static arrays ×
    `level_count`, and abstract slots as `levels × chunks × (4·ct +
    nav_interior_link_slots_per_chunk)` plus a `link_edges` term (Slice 64E),
    independent of how many cells are open
    (`systems/pathfinding/nav_memory.zig`).
  - `budgetForCapacity` takes the link count. Since Slice 64E it is
    `world.levelLinkLimit()`, the load-time link capacity the demo reserves
    with `reserveLevelLinks(levelLinks().len + world chunks ×
    nav_interior_link_slots_per_chunk)` (`demoLevelLinkLimit`,
    `src/game/game_demo_state.zig`) as the initial reservation; the dig commit
    seam raises it when a ramp needs room.
  - `NavGrid.markWorldObstacles` memsets uniform layers, walks non-uniform
    layers per cell, and marks sparse tiles separately
    (`systems/pathfinding/nav_grid.zig:278-302`).
  - A chunk that outgrows its per-chunk edge window has that one window
    relocated at twice its new edge count and re-patched in the same
    incremental update (`growChunkEdgeWindow` in
    `systems/pathfinding/nav_graph.zig`, counted as `edge_windows_grown`;
    64E follow-up, 2026-10-06). The old full-rebuild fallback is gone.
- **Tileset.**
  - `assets/sprites/world_tileset.json` already ships `autotile_sets`
    `grass_dirt`, `water_shore` and `path`, each `layout: "transition_16"` with
    16 tile ids. They are packed by `tools/pack_atlas.py:94-118` and linted by
    `tools/lint_assets_if_changed.py:336`.
  - `src/assets/world_tileset_meta.zig` ignores them today: `JsonRoot` has no
    field for them (`:72-83`), and the parse uses
    `ignore_unknown_fields = true` (`:220`).
  - The `transition_16` art convention is `TRANSITION_MASKS`
    (`tools/tileset_quality.py:27-44`): index 0 none, 1 N, 2 S, 3 E, 4 W,
    5 NW, 6 NE, 7 SW, 8 SE, 9 N+S, 10 E+W, 11 inner, 12–15 X+inner.
    `transition_weight` (`:210-229`) makes 12–15 visually equal to 11.
- **Tile flags** (from `world_tileset.json`):
  - `cobblestone`, `stone_floor` and `rotten_planks` are walkable and
    non-blocking.
  - `brick_wall_*` and `structure_*` block movement and vision.
  - `cave_*` tiles are walkable and non-blocking.
  - `water_shore_1..15` are walkable and non-blocking. `water_shore_0` is
    non-walkable and non-blocking.
- **Interest markers**: `interest_marker_capacity = 128` and kinds
  `investigate|cover|resource|patrol` (`src/game/world_interest.zig:25-36`).
  The demo places 4 investigate markers (`game_demo_state.zig:889-909`).
- **AI goal level.** `writeAiIntentsJob` (`src/game/systems/ai.zig:1367-1403`)
  writes `NavigationIntent` without `goal_level`, so it defaults to 0
  (`src/game/simulation.zig:465-471`). `stageAiDecide` deliberately never
  seeds the player's plane (`simulation_pipeline.zig:1148-1152`). Every
  gathered AI row already carries its world level in `RowInterest.level`
  (`ai.zig:162`, written for every row at `:759` from `worldLevelConst`).
  Pathfinding routes a same-level goal in a different component through the
  abstract graph, including level links (`pathfinding/solve.zig:99-121`), and
  a cross-level goal through link edges (`pathfinding/system.zig:789-795`).

### Architecture notes

**Modules (game layer, load-time only).**

- `src/game/worldgen/caves.zig` holds the pure cave predicate, the entrance
  probe, and the cave-node block candidate.
- `src/game/worldgen/structures.zig` holds the strict `structures.json` loader,
  Phase 0 site selection, the footprint CSR, and commit stamping.
- `src/game/worldgen/autotile.zig` holds the neighbour mask and the pinned
  `transition16Index` table.
- `src/assets/world_tileset_meta.zig` parses `autotile_sets`.
- `worldgen/spec.zig` gains the keys below.
- `worldgen/generate.zig` calls the new modules at the steps named in
  "Generation flow", inside Slice 65C's `plan` / `generateJobRange` /
  `commitJob` / `finish` split.
- `src/game/systems/ai.zig` writes the own-level `goal_level` ("AI goal
  level" below).

**Spec additions.** `assets/world/worldgen.json` keeps `version: 1`; the new
keys are additive and optional, and the strict loader still rejects unknown
keys. In the example below, `"..."` marks fields unchanged from Slice 58's
example; it is abbreviation, not literal content.

```json
{ "version": 1,
  "site_cell_tiles": 48,
  "biomes": [
    { "id": "lake", "elevation_max": 0.30, "palette": [ { "tile": "water_1", "weight": 1 } ],
      "edge_set": "water_shore" },
    { "id": "plains", "default": true, "palette": [ "..." ],
      "structures": [ { "structure": "ruin", "density": 0.10 } ],
      "villages":   [ { "village": "hamlet", "density": 0.25 } ] } ],
  "strata": [
    { "depth_min": 1, "depth_max": 31, "fill": [ "dirt", "dirt_dark" ],
      "veins": [ { "tile": "gravel", "cell_size": 6, "threshold": 0.80 } ],
      "caves": { "floor_tile": "cave_0", "cell_size": 12, "octaves": 2, "threshold": 0.72,
                 "nodes": [ { "kind": "stone_outcrop", "density": 0.03 } ],
                 "entrances": { "surface_tile": "cave_3", "max": 8 } } } ] }
```

`assets/world/structures.json` uses `version: 1`, a strict loader, and is
installed beside `worldgen.json`:

```json
{ "version": 1,
  "structures": [
    { "id": "hut", "size": [5, 5],
      "rows": [ "#####", "#...#", "#...#", "#...#", "##.##" ],
      "legend": { "#": { "floor": "cobblestone", "wall": "brick_wall_0" },
                  ".": { "floor": "rotten_planks" } },
      "sockets": [ { "at": [2, 2], "kind": "spawn", "archetype": "wanderer" } ] },
    { "id": "ruin", "size": [6, 6],
      "rows": [ "##  ##", "#....#", "  ..  ", "  ..  ", "#....#", "##  ##" ],
      "legend": { "#": { "floor": "stone_cracked", "wall": "brick_wall_3" },
                  ".": { "floor": "stone_cracked" } },
      "sockets": [ { "at": [3, 3], "kind": "marker", "marker": "investigate", "radius": 64 } ] } ],
  "villages": [
    { "id": "hamlet", "extent": [24, 24],
      "members": [ { "structure": "hut", "at": [2, 2] }, { "structure": "hut", "at": [17, 2] },
                   { "structure": "hut", "at": [2, 17] }, { "structure": "hut", "at": [17, 17] } ],
      "sockets": [ { "at": [12, 12], "kind": "anchor", "table": "settlement", "radius": 160,
                     "max_alive": 7, "respawn": "refill", "interval_seconds": 120 },
                   { "at": [12, 10], "kind": "node", "node": "berry_bush" } ] } ] }
```

- A space character in `rows` leaves the terrain untouched.
- A legend entry has an optional `floor` (a dense surface tile) and an optional
  `wall` (a sparse obstacle tile at `WorldDepth.obstacle`). At least one of the
  two is required.
- Village sockets use village-local coordinates. Their cells must not lie under
  a member's non-space cell unless that cell's legend has a floor and no wall.
- Socket kinds:
  - `spawn` takes `archetype`.
  - `node` takes a Slice 61 node kind.
  - `marker` takes `investigate` or `resource` plus `radius`. `cover` and
    `patrol` are rejected (`UnconsumedMarkerKind`) because they have no
    consumer yet; the Emergent AI guardrail forbids half-wiring them.
  - `anchor` takes the Slice 62 anchor fields: `table`, `radius`,
    `max_alive`, `respawn`, `interval_seconds`.
- Structure and village ids are file-order dense indices (`u8`). They are
  load-time only, never persisted and never in sim data, so they need no
  closed enum. The file needs no `content_fingerprint` entry, because its only
  effect is world tiles, which saves store directly.

**Caves.**

- Seeds:
  - `cave_field_seed = rng.mix64(world_seed, 0, 0, field_salt_cave)`.
  - `cave_level_seed = rng.mix64(cave_field_seed, level, 0, cave_level_salt)`,
    computed once per job.
- Predicate: `isCaveCell(level_seed, stratum, x, y) = noise.valueNoise2(
  level_seed, x, y, cell_size, octaves) >= threshold_q16`. It is pure and
  integer-only.
- Underground cell precedence: cave floor beats vein, and vein beats fill. A
  cave cuts through veins.
- Validation (the loader rejects all of these loudly):
  - `floor_tile` must be walkable and not `blocks_movement`
    (`CaveFloorBlocks`).
  - `cell_size` must be in `8..=64`. Pockets stay blobby, so per-chunk border
    fragmentation stays at the surface's level. That is the fragmentation the
    measured edge window already absorbs.
  - `threshold` must be in `[0.50, 0.95]`.
  - At most `max_cave_node_rules = 4` node rules, with densities summing to at
    most 1.
  - `entrances` is allowed only on the stratum whose `depth_min == 1`
    (`CaveEntrancesNotAtDepthOne`). Its `max` must be in
    `1..=max_cave_entrances`, and `surface_tile` must be walkable and not
    `blocks_movement`.
- Slice 58's "strata `fill` / `veins` must `blocks_movement`" rule is
  unchanged. Caves are the only open underground cells at generation time.
- A cave layer is neither `all_blocking` nor `none_blocking`, so its
  `UniformBlocking` is `.mixed`.
  - The nav static mask and perception's blocked cache walk that level per cell
    at load (`nav_grid.zig:288-295`). That is load-time cost only.
  - Dig, fall and patch paths are unchanged. A fall onto a cave cell whose
    floor already equals the tunnel tile returns no change.
- **Cave nodes.**
  - Each 4×4 block (`feature_block_cells`) on a cave level draws one jittered
    candidate with the node field seed and the job's `level`. The candidate
    counts only if it lands on a cave cell. One cumulative density draw over
    `caves.nodes` picks a kind or nothing.
  - Records join `GeneratedNodes` with their `level`.
  - Slice 58's node rank key becomes `rng.mix64(node_seed, cell_index, level,
    node_rank_salt)`. Level 0 is unchanged, so 58's goldens are unaffected.
  - Per-job slots are unchanged, because every job already reserves the 4×4
    block count.
- **Cave spawns.**
  - A stratum with `caves` emits spawn candidates only on cave cells, with
    `carve_pocket = false`.
  - Probe `k < spawn_candidates_per_chunk` (4) examines cell
    `boundedU32(spawn_seed, job_index, k, cave_spawn_probe_salt, ct·ct)` in the
    chunk. It is accepted iff the cell is a cave cell and not this job's node
    cell.
  - A stratum without `caves` keeps Slice 58's carve-pocket candidates.
  - **Decision: deep cave spawns stay.** Entrances reach only depth 1, so cave
    spawns at depths 2..31 are reachable only by digging. That is unchanged
    from Slice 58, whose carve-pocket candidates already sit on every
    underground stratum and already compete in the same hash-ranked
    population cap. 69A moves those candidates onto cave cells; it adds no
    candidates per chunk (still `spawn_candidates_per_chunk = 4` probes, and a
    probe that misses a cave cell yields nothing), so the share of the cap
    that goes underground can only fall. Unreached deep agents cost almost
    nothing at runtime (Slice 55 coasting) and are the encounters a digging
    player meets.
- **AI goal level (own-level goals).** Without this, every cave agent's
  wander / investigate / forage goal would be a level-0 goal at the same x/y
  (`NavigationIntent.goal_level` defaults to 0). Pathfinding serves that
  cross-level request through the new entrance links, so cave populations
  would walk out of their caves and pile onto the surface.
  - `writeAiIntentsJob` writes `.goal_level = job.interest[i].level`, the
    row's world level sampled at gather (`RowInterest.level`, gathered for
    every row; after Slice 68A the same value comes from `spatial.levels[r]`,
    a stage-3 snapshot that is current at `ai_decide`). Every resolver
    produces a goal position on the agent's own level, so this is correct by
    construction. It still never seeds the player's plane, so the
    `stageAiDecide` comment at `simulation_pipeline.zig:1148-1152` stays true;
    it gains one sentence: "AI goals are own-level (Slice 69A)."
  - It generalizes Slice 71A's post-goal rule (patrol / follow /
    return_home already write the row level) to every behavior. If 71A has
    not landed, 69A lands the rule alone.
  - Surface agents write 0 exactly as today, so every existing level-0 test is
    bit-identical.
  - **Decided:** a same-level goal in another pocket of the agent's level is
    still routed through the abstract graph, which may cross the surface
    through two entrances. That is legitimate travel that ends on the agent's
    own level; it is not a surface goal.
  - Autonomous cross-level goals are a decided non-goal (umbrella list).
- **Entrances.**
  - A surface job probes exactly one cell, `boundedU32(entrance_seed,
    chunk_index, 0, entrance_probe_salt, ct·ct)`, with `entrance_seed =
    rng.mix64(world_seed, 0, 0, field_salt_entrance)`. The probe is accepted
    iff all of these hold:
    - its post-palette, post-edge surface tile is not `blocks_movement`;
    - it is not inside a Phase 0 stamp AABB (below);
    - it is not this job's feature or node cell;
    - the depth-1 cell is a cave cell (pure recompute);
    - the depth-1 cell is not that block's cave-node cell (pure recompute of
      the depth-1 block candidate).
  - The accepted cell goes into the new field `JobSummary.entrance_cell: ?u32`.
  - Selection (in Slice 65C's `finish`, after every `commitJob`, because it
    ranks candidates from all jobs):
    - collect every candidate;
    - keep the top `min(entrances.max, max_cave_entrances)` by
      `rng.mix64(entrance_seed, cell_index, 0, entrance_rank_salt)`, ties
      broken by `cell_index`;
    - sort by (y, x);
    - call `ensureLevelLinkCapacity(n)` once (the world is still unreserved
      at generation, so it grows; the only error there is `OutOfMemory`).
  - For each entrance:
    - write the surface cell to `surface_tile`. This is a direct slice write.
      A `.blocking` surface layer flips to `.mixed`; `.open` and `.mixed`
      layers are unchanged. The surface layer's `uniform_fill_tile` is
      cleared when `surface_tile` differs from it, the same rule commit
      stamping uses, so the layer never claims a uniform fill it no longer
      has;
    - call `addLevelLink(.{ .kind = .ramp, .level_a = depth1, .cell_a = c,
      .level_b = surface, .cell_b = c, .traversal_cost = 1, .bidirectional =
      true })`. This is exactly `digRamp`'s shape, so plane traversal and nav
      link edges need no new code.
  - Slice 58's player spawn ring search also skips entrance cells.
- **Nav memory budget check (backlog item).** The gate needs no change:
  - `requiredBytes` already budgets every level as fully portal-capable, so
    caves do not change admission.
  - Entrances add at most 16 authored links. They are counted in
    `levelLinks().len` when the demo reserves `levelLinkLimit()` after
    generation, so they flow into `autoSizedMaxNavMemoryBytes` through that
    load-time capacity (Slice 64E).
  - The only content-dependent cost is the measured per-chunk edge window. A
    window that outgrows its build size relocates in place (no rebuild); the
    acceptance soak records `edge_windows_grown` at production size.

**Structures and villages.**

- `site_cell_tiles = S` comes from the spec. Validation:
  - `S` must be in `8..=128`;
  - `S` must be at least the largest referenced template or village extent + 2
    (`SiteCellTooSmall`). Placements are confined to their own site cell, so
    two placements can never overlap and no cross-site conflict rule exists.
- **Phase 0 site selection.** It runs inside Slice 65C's `plan`, on the main
  thread, serially, after `buildCatalog` and the chunk-alignment check and
  before any `generateJobRange`. It reads only pure functions of seed and
  spec, never job output. `GenerationPlan` owns the `StampRecord` list and the
  footprint CSR; `ChunkGenContext` exposes them as immutable slices, so lane
  batches and worker ranges read them without a `*WorldSystem`.
  1. The site grid is `ceilDiv(width, S) × ceilDiv(height, S)` in row-major
     `site_index` order.
  2. The center cell is `(sx·S + S/2, sy·S + S/2)`, clamped to the world. Its
     biome comes from Slice 58's pure classifier. One draw `boundedU32(
     site_seed, site_index, 0, site_pick_salt, 65536)` is compared against
     the biome's cumulative Q16 densities: `structures`, then `villages`, in
     spec order. A miss means the site gets nothing. `site_seed =
     rng.mix64(world_seed, 0, 0, field_salt_site)`.
  3. Jitter is `ox = boundedU32(site_seed, site_index, 1, site_jitter_salt,
     S - w + 1)`, and `oy` likewise with step 2. A placement that leaves the
     world (a partial edge site) is rejected and counted as
     `sites_rejected_bounds`.
  4. **Footprint check.** Recompute Slice 58's terrain tile (biome, palette
     pick and edge rule) for every non-space cell of every member. Any
     `blocks_movement` tile rejects the site (`sites_rejected_terrain`). The
     cost is at most extent² cells per site.
  5. **Capacities (no truncation).** Every survivor is placed. One walk over
     the survivors in `site_index` order sums their member counts and wall
     counts (walls also per surface chunk, once the footprint CSR below
     exists). `plan` reserves the `StampRecord` list for the member total, and
     `finish` reserves `sparse_tiles` and its level-0 per-level and per-chunk
     index lists for the wall totals before any stamp. Every total is a pure
     function of seed, spec and dimensions.
  6. Emit `StampRecord { template, origin_x, origin_y, site_index }` in
     `site_index` order, with villages expanded in member order.
  7. **Footprint CSR.** Over surface chunks, compute counts → prefix → the
     stamp indices whose AABB intersects each chunk. This is load-time
     allocation sized by chunk count, owned by `GenerationPlan`, and freed by
     `finish` or by `WorldGenStream.cancel` (65C's plan teardown).
- **Jobs.** Surface jobs read the immutable CSR. They do not draw feature,
  node, spawn or entrance candidates inside any stamp AABB in their chunk, so
  each structure sits in a clearing. Terrain and edge tiles are still written,
  and stamps overwrite them at commit.
- **Commit stamping.**
  - It runs on the main thread in Slice 65C's `finish`, after every
    `commitJob` (Slice 58's per-job feature commit) and after the per-layer
    uniform state is computed from the accumulators, in `StampRecord` order,
    over each record's non-space cells:
    - a `floor` is a direct dense write on the surface floor layer;
    - a `wall` is `addSparseTile(surface, x, y, wall, 0, .obstacle)`.
  - Floor tiles are validated non-blocking, and the footprint check proved the
    terrain under them non-blocking. So no layer's `uniform_blocking` can
    change; a Debug assert checks this.
  - `uniform_fill_tile` is cleared if any stamp writes a tile id different
    from the fill.
- **Socket outputs.** Positions are cell centers. Sockets are emitted in
  `StampRecord`, then socket order, and authored records are selected before
  ranked candidates:
  - `spawn` sockets become authored `GeneratedSpawns` records with
    `carve_pocket = false`. They count against the caller's population cap
    first; authored overflow is dropped in order and counted as
    `socket_spawns_dropped`. Slice 58's hash-ranked candidates fill the
    remainder.
  - `node` sockets become authored `GeneratedNodes` records ahead of the
    hash-ranked candidates, under `max_worldgen_resource_nodes`.
  - `marker` sockets become authored `GeneratedWorld.markers` records ahead of
    the Slice 58 resource cluster markers, under the shared
    `max_worldgen_interest_markers` (Slice 58 addition).
  - `anchor` sockets become authored `GeneratedWorld.anchors` records ahead of
    Slice 62's biome anchors, under the `u16` anchor-index ceiling
    (`SpawnAnchorId.index`; Slice 62's capacity is world-sized). There is at
    most one anchor socket per template or village (`MultipleAnchorSockets`):
    one settlement roster per village, which is VoidLight's settlement record.
  - Every survivor list is then sorted by (level, y, x), as in Slice 58, so
    `EntityId` assignment stays deterministic.

**Autotile edge sets.**

- `WorldTilesetMeta` gains:
  - `AutotileLayout = enum { transition_16 }`;
  - `AutotileSet = struct { layout: AutotileLayout, tile_ids: [16]u16 }`;
  - an optional `autotile_sets` field on `JsonRoot`;
  - `autotileSetByName(name) ?AutotileSet`.
- Validation at metadata load:
  - an unknown layout fails with `UnknownAutotileLayout`;
  - anything other than exactly 16 ids fails with `AutotileSetIdCount`;
  - every id must exist (the `validateAnimationTileIds` precedent);
  - more than `max_autotile_sets = 16` sets fail.
- A biome's `edge_set` is exclusive with `edge_tile`; setting both fails with
  `EdgeTileAndEdgeSet`. It resolves at spec load to `[16]TileId`.
  Indices 1–15 are the selectable indices. They must all share one
  `blocks_movement` value (`AutotileSetMixedBlocking`), so a cell's blocking
  never depends on its mask shape, and `JobSummary` blocking stays
  shape-independent.
- **Masks.** The cardinal mask is `mask = N | E<<1 | S<<2 | W<<3`. A bit is set
  when that 4-neighbour's biome, recomputed by the pure classifier, differs
  from this cell's. The diagonal mask is
  `diag = NW | NE<<1 | SW<<2 | SE<<3` with the same rule over the four
  diagonal neighbours. Out-of-world neighbours count as the same biome, so
  world borders never edge.
- **Inner-corner art (amends the `transition_16` convention).** Today indices
  12–15 are `{N, S, E, W} + inner`, which `transition_weight`
  (`tools/tileset_quality.py:210-229`) renders visually equal to 11, and
  nothing references them (no runtime consumer; the runtime ignores
  `autotile_sets` today). This slice repurposes them as the four
  diagonal-only inner corners:
  - `TRANSITION_MASKS[12..16]` become `{"nw_inner"}`, `{"ne_inner"}`,
    `{"sw_inner"}`, `{"se_inner"}`.
  - `transition_weight` gains one rule: for a `*_inner` flag, the weight is
    `max(0, 1 − d / 11)`, where `d = math.hypot(dx, dy)` is the distance
    from the named pixel corner (a quarter-circle notch with the same 11-px
    falloff the edges use), so only that corner blends. This is offline art
    generation in Python, not simulation code.
  - `tools/generate_world_tileset.py` regenerates `grass_dirt_12..15` and
    `water_shore_12..15`. Tile ids, names, atlas rows, and the 16-id layout
    are unchanged; only those eight tiles' pixels change. The `path` set
    keeps its own art (`make_path_tile`) and is not an `edge_set` in the
    shipped spec.
  - `docs/atlas-asset-workflow.md` records the amended index table.
- **Pinned comptime table `transition16Index(mask: u4, diag: u4) u4`**:
  - Cardinal mask nonzero (the cardinal edge dominates; diagonals are
    ignored):
    - N → 1, S → 2, E → 3, W → 4.
    - N|W → 5, N|E → 6, S|W → 7, S|E → 8.
    - N|S → 9, E|W → 10.
    - Every 3- and 4-bit mask → 11 (`inner`).
  - Cardinal mask zero:
    - `diag == 0` → 0. Not an edge; the palette tile stays.
    - Exactly one diagonal bit → its inner corner: NW → 12, NE → 13,
      SW → 14, SE → 15.
    - Two or more diagonal bits → 11. The ring art blends every edge band,
      which covers each differing corner; a 16-id layout has no multi-corner
      tiles, and this case needs a one-cell-wide isthmus of the other biome
      on both sides, which the classifier's blobby biomes rarely produce.
- **Decision on the remaining combinations.** A cardinal edge plus a
  differing *opposite* diagonal (for example N with SE) keeps the cardinal
  tile; that corner notch needs the full 47-tile blob layout, which is
  rejected because it would triple every set's atlas footprint for a
  sub-tile detail. This is a decision with its reason, not a deferred gap.
- A cell of an `edge_set` biome with `mask != 0` or `diag != 0` gets
  `tile_ids[transition16Index(mask, diag)]` when that index is nonzero;
  otherwise it keeps its palette tile.

**Fixed constants (none derived from world size).** Each row is a per-site or
per-query work budget, an inline spec-table ceiling that fails loudly at load,
or a validation range. Placement counts are not capped: the site grid gives one
candidate per `S × S` cell, so placements, stamp records and wall sparse tiles
are working capacities sized from the world in Phase 0 (rows marked
*capacity*).

| Constant | Value | Reasoning |
| --- | --- | --- |
| `max_cave_entrances` | 16 | Loud load-time ceiling on the authored `entrances.max`, a content count. It does not size link storage: the demo reserves `levelLinks().len + world chunks × nav_interior_link_slots_per_chunk` after generation (Slice 64E), and entrances are authored links inside that capacity. |
| cave `cell_size` / `threshold` | `8..=64` / `[0.50, 0.95]` | Blobby pockets, at most about half open. |
| `max_cave_node_rules` | 4 | Same shape as the surface rules. |
| `max_structure_templates` / `max_village_layouts` | 32 / 16 | Fixed spec tables. |
| `max_structure_extent_tiles` / `max_village_extent_tiles` | 32 / 64 | Bounds the Phase 0 footprint check (≤ 64² cells per site). |
| `max_village_members` | 8 | VoidLight `VILLAGE_MAX_BUILDINGS`. |
| `max_sockets_per_template` / `max_sockets_per_village` | 8 / 4 | Bounds authored records per site. |
| `max_structure_walls_per_template` | 512 | Half of a 32² template. |
| `max_structure_rules_per_biome` / `max_village_rules_per_biome` | 4 / 2 | Fixed per-biome tables. |
| `site_cell_tiles` | `8..=128`, ≥ largest extent + 2 | One placement per site, so there is no overlap rule. |
| site placements (*capacity*; was `max_worldgen_sites = 64`) | `ceilDiv(width, S) × ceilDiv(height, S)` | One placement per site cell by construction, so every surviving site is placed and nothing truncates. Sites add only load-time stamping; each per-step effect is budgeted on its own (spawns: the population cap; nodes: `max_worldgen_resource_nodes`; markers: `max_worldgen_interest_markers`; anchors: Slice 62's band-local `spawn_anchor_evals_per_step` and fixed band-query row bound, since `spawn_anchor_capacity` is world-sized). |
| wall sparse tiles (*capacity*; was `max_worldgen_structure_sparse = 16384`) | Σ walls of the placed sites | Counted in Phase 0 and reserved before stamping. Safe to scale with the world because Slice 58 bounds `levelBlocksMovement` to one chunk's sparse list, so no per-query cost reads the level's wall count. |
| `max_autotile_sets` | 16 | Fixed metadata parse cap. |

**Generation flow.** These changes are stated against Slice 58's numbered
steps, as split by Slice 65C.

- `plan` (step 1 + 1a): Slice 58's setup and refusals, then Phase 0 site
  selection and the footprint CSR, before the per-job reserve.
- `generateJobRange` (step 2; one body for worker ranges and lane batches):
  - surface jobs do palette, then the autotile edge, then candidates outside
    stamp AABBs, then the entrance probe;
  - underground jobs do fill, then veins, then caves, then cave nodes, then
    cave or carve-pocket spawn candidates.
- `commitJob` (step 3, per job, canonical order): Slice 58's per-job commit,
  unchanged. A cave layer's `all_blocking` / `none_blocking` accumulators
  yield `.mixed` through the existing AND rule.
- `finish`:
  - per-layer uniform state from the accumulators (65C);
  - then structure stamping;
  - then sockets;
  - then entrance selection, surface writes (with the `uniform_fill_tile`
    clear) and links;
  - then step 4, selection: authored records first, then ranked candidates,
    for spawns, nodes, markers and anchors;
  - then step 5, player spawn: the ring search also skips entrance cells.

`WorldGenStream` needs no 69A-specific code: it drives the same four entry
points, so the three new goldens hold at every lane batch size.

`GeneratedWorld` gains `markers: GeneratedMarkers`, which it shares with the
Slice 58 addition, plus `anchors` (Slice 62) and `stats: GenerationStats` with
these fields:

- `cave_open_cells`
- `entrances`
- `sites_evaluated`
- `sites_placed`
- `sites_rejected_bounds`
- `sites_rejected_terrain`
- `socket_spawns_dropped`
- `socket_nodes_dropped`
- `socket_markers_dropped`
- `socket_anchors_dropped`
- `autotiled_edge_cells`

**Determinism.**

- All draws are pure `rng.mix64` keyed by cell, chunk, site or level. Field
  salts are new local constants: `field_salt_cave`, `field_salt_entrance`,
  `field_salt_site`.
- Phase 0 and commit are serial on the main thread in sorted order. Jobs are
  chunk-local and read only immutable inputs (spec, CSR, seeds).
- Serial and threaded runs give the same hash. Integer-only math gives the same
  golden in Debug and ReleaseFast.

**Persistence and checksum.** Slice 69A adds no new `WorldSystem` or
`DataSystem` field. `NavigationIntent.goal_level` is per-step output, so the
own-level rule needs no checksum or save change. Dense and sparse tiles, `level_links`, interest markers,
spawn anchors and `chunk_biomes` are already classified as hashed and saved
(Slices 49, 46, 58, 62).

**Diagnostics.** The `game` scoped logger is used at load only:

- `info` with the `GenerationStats` above;
- one `warn` per cap that truncated: each socket kind (site placements and
  wall tiles are capacities and never truncate).

Generation time flows through the existing `loading_build` timing. There is no
per-cell logging.

**Allocation policy.** Load-time only: Phase 0 scratch, the CSR, and the entrance
candidate list are allocated and freed during generation on the already-bounded
world (Slice 58 precedent). Nothing changes on hot paths.

### Checklist

- [ ] `world_tileset_meta.zig`: parse `autotile_sets` (`AutotileLayout`,
      `AutotileSet`, `autotileSetByName`) with the validation above. Tests: the
      shipped tileset parses all three sets; an unknown layout, a 15-id set and
      an unknown id are each rejected. `docs/atlas-asset-workflow.md` documents
      the amended `transition_16` index convention (12–15 = NW/NE/SW/SE inner
      corners).
- [ ] Inner-corner art: `tools/tileset_quality.py` `TRANSITION_MASKS[12..16]`
      become the four `*_inner` flags and `transition_weight` gains the
      corner rule; regenerate with `tools/generate_world_tileset.py` and
      repack. Only `grass_dirt_12..15` and `water_shore_12..15` change pixels;
      tile ids and names are unchanged. `zig build assets-lint` passes.
- [ ] `worldgen/autotile.zig`: the cardinal and diagonal mask functions and
      the pinned `transition16Index(mask, diag)` table. The test enumerates
      all 16 cardinal masks (with `diag` 0 and 15, showing diagonals are
      ignored when a cardinal bit is set), every single-diagonal case → 12–15,
      a two-diagonal case → 11, `mask == diag == 0` → 0, and a world-border
      cell → no edge.
- [ ] Slice 65C job shape: Phase 0 and the CSR in `plan` (owned by
      `GenerationPlan`, exposed read-only through `ChunkGenContext`), the
      cave, structure-suppression, autotile, and entrance-probe passes in
      `generateJobRange`, `commitJob` unchanged, and stamping, sockets,
      entrances, and selection in `finish`. `WorldGenStream.cancel` frees the
      69A scratch.
- [ ] AI goal level: `writeAiIntentsJob` writes
      `.goal_level = job.interest[i].level`; one-sentence addition to the
      `stageAiDecide` comment. Tests:
      - a level-1 agent in a single hand-built cave pocket with one entrance
        (minimal fixture: 16×16, 1 underground level, a `LevelLink` ramp)
        emits wander and investigate intents with `goal_level == 1` and never
        takes the entrance link over 600 `pipeline.update` steps;
      - a level-0 agent's intents are bit-identical to the pre-change build
        (`goal_level == 0`).
- [ ] `worldgen/spec.zig`: the new keys (`site_cell_tiles`, biome `edge_set`,
      `structures`, `villages`, stratum `caves`) and every validation listed
      above. Rejection tests for each: `CaveFloorBlocks`,
      `CaveEntrancesNotAtDepthOne`, `EdgeTileAndEdgeSet`,
      `AutotileSetMixedBlocking`, `SiteCellTooSmall`, densities summing above
      1, and every cap exceeded.
- [ ] `worldgen/structures.zig`: the strict `structures.json` loader
      (rows/size match, single-char legend, floor/wall flag rules, socket cell
      rules, `UnconsumedMarkerKind`, `MultipleAnchorSockets`, unknown archetype,
      node kind or table), Phase 0 selection, site and wall capacities (no
      truncation), `StampRecord` list, the
      footprint CSR, and commit stamping. Ship `assets/world/structures.json`
      (`hut`, `ruin`, and `hamlet` as 4 huts plus a `settlement` anchor and a
      berry node) and confirm it installs.
- [ ] (capacity audit) Site placements and wall sparse tiles are load-time
      capacities: delete `max_worldgen_sites`, `max_worldgen_structure_sparse`,
      `site_rank_salt`, and `sites_dropped_sparse_cap`. Tests (16×16 fixture):
      placed sites equal surviving sites; `StampRecord` capacity equals the
      Phase 0 member total and `sparse_tiles` capacity equals the pre-stamp
      length plus the Phase 0 wall total; with `std.testing.FailingAllocator`
      installed on the world allocator after those reserves, `finish`'s
      stamping allocates nothing. Lands after Slice 58's per-chunk
      `levelBlocksMovement`.
- [ ] `worldgen/caves.zig` + `generate.zig`:
      - cave predicate and cell precedence;
      - cave nodes, with the node rank key level-amended;
      - cave spawn probes;
      - entrance probe in `JobSummary.entrance_cell`, ranked selection, surface
        write (clearing `uniform_fill_tile` when `surface_tile` differs) and
        `addLevelLink` in `finish`;
      - the player-spawn skip.
- [ ] (added by Slice 64) The entrance commit loop, in its existing rank order, skips an
      entrance cell `c` for which
      `nav_graph.interiorLinkSlotsAvailable(world.levelLinks(), c, .{
      .chunk_tiles = capacity.nav_chunk_tiles, .width = width_tiles,
      .height = height_tiles })` is false (the session's
      `PathfindingCapacity.nav_chunk_tiles`; link endpoints are tile cells,
      as `recordLinkEndpoint` already assumes), and counts
      `worldgen_entrances_refused_link_slots`. The skip is deterministic
      (a pure function of the ranked candidates), so the golden hashes stay
      a pure function of seed and spec. Test: the private entrance-commit
      helper, fed a test-local ranked list of 9 distinct interior cells in
      one 8-tile nav chunk on a 16×16 fixture, commits 8 links and reports 1
      refused. No generated world can then fail Slice 46's
      load-time link-slot validation.
- [ ] `generate.zig`:
      - the jobs' footprint suppression;
      - socket outputs with authored-first selection and drop counters;
      - `GenerationStats`;
      - `GeneratedWorld.markers` and `.anchors`.
- [ ] Ship `worldgen.json` content: lake `edge_set: water_shore`, plains
      structures and villages, dirt strata caves with entrances and
      `stone_outcrop` cave nodes. `zig build assets-lint` passes.
- [ ] `GameDemoState.initProceduralWithRuntimeAssets` adopts the authored
      records through the existing Slice 58, 61 and 62 adoption paths. No new
      adoption code path is added.
- [ ] Docs:
      - `docs/architecture.md`: worldgen breadth, the site model, the
        socket priority rule, and "AI navigation goals are own-level";
      - `docs/development-workflow.md` (or `docs/atlas-asset-workflow.md`):
        authoring `structures.json` and updating the new goldens.

### Acceptance checks

- [ ] Slice 58's three pinned goldens are unchanged, since the 58 fixture spec
      uses none of the new keys. They pass under `zig build test` and
      `zig build test --release=fast`.
- [ ] Three new pinned goldens:
      - Fixture: an inline spec on a 16×16 world with chunk size 8 and 1
        underground level. It has `site_cell_tiles = 8`, a 3×3 hut, and a 6×6
        village of two 2×2 sheds with an anchor socket and a marker socket. It
        also has `water_shore` on a lake biome and caves with `entrances.max =
        2`.
      - The hash extends Slice 58's fold with level links, authored-marker
        records and anchor records.
      - Different seeds give different hashes. The goldens pass in Debug and
        ReleaseFast.
- [ ] `max_worker_threads = 0` and N workers (at least 2 ranges) give the same
      new golden.
- [ ] The three new goldens also pass through `WorldGenStream` at 1-, 8-, and
      64-job lane batches and through the no-lane-thread fallback (Slice 65C's
      parity harness).
- [ ] Structure placement:
      - no two placements overlap;
      - no feature, node, ranked spawn or entrance lies inside a stamp AABB;
      - a site over water is rejected and counted;
      - every surviving site is placed, and the placed set is identical
        across thread counts;
      - the stamp and wall reserves equal the Phase 0 totals (no growth
        during stamping).
- [ ] Socket priority: authored spawns, nodes, markers and anchors are kept
      before ranked candidates. Overflow is dropped in order and counted. A
      village anchor socket becomes a live `SpawnAnchorStore` slot, and its
      roster fills through Slice 62's `population_update`.
- [ ] Caves:
      - a cave stratum layer is `.mixed`, and its nav `blocked_count` equals a
        per-cell recount;
      - a non-cave stratum keeps the `.blocking` memset path;
      - each entrance link resolves through `rampLinkOtherLevel` from both
        ends, and plane traversal moves an entity between the surface and
        depth 1;
      - the entrance count is at most `entrances.max`;
      - an entrance on a uniform-fill surface layer clears its
        `uniform_fill_tile`;
      - cave agents keep own-level goals and stay in their pocket (the AI
        goal-level tests pass).
- [ ] Autotile: every edge cell of a `water_shore` lake holds
      `tile_ids[transition16Index(mask, diag)]`, matching a per-cell
      recomputation, including at least one diagonal-only inner-corner cell
      in the golden fixture; non-edge cells keep their palette tile.
- [ ] Nav memory: the generated production world (256×256, 31 underground
      levels, shipped caves) passes `budget.check` under
      `autoSizedMaxNavMemoryBytes` with `link_count` including entrances. A
      60 s ReleaseSafe soak shows:
      - no `NavWorldTooLarge`;
      - `edge_windows_grown` recorded (window relocations, no rebuilds);
      - `loading_build` recorded before and after.
- [ ] Unit tests stay at 16×16 or smaller with 1 underground level.
- [ ] Bench: new group `worldgen-breadth` (`src/benchmarks/worldgen.zig`,
      registered in `runner.zig`, using Slice 58's side-length/level table)
      with the shipped breadth spec, run as
      `zig build bench -- --group worldgen-breadth`. Tiles/s across the shared
      `serial-direct` and `thread-fixed-auto` cases is recorded beside
      `--group worldgen`.
- [ ] `zig build verify` passes.

### VoidLight reference

**Port:**

- Settlement records (center, radius, biome, building count) become the
  village anchor socket feeding Slice 62's `settlement` roster
  (`src/world/WorldGenerator.cpp:895-903`, `src/world/WorldPopulation.cpp:39-41`).
- Per-biome village weights become per-biome `villages` densities
  (`WorldGenerator.cpp:122-128`).
- `VILLAGE_MIN/MAX_BUILDINGS` becomes the member list, under
  `max_village_members = 8` (`:119-120`).
- The `canPlaceBuilding` no-water/no-obstacle rule becomes the Phase 0
  footprint terrain check (`:909-934`).

**Do not port:**

- `VILLAGE_DENSITY_DIVISOR` (`area / 8000`) village counts (`:117,805`), a
  target count chased by retry loops. ZeroLight's site grid gives one
  deterministic candidate per `S × S` cell, so placements scale with area by
  construction (a load-time content capacity, not a per-step budget) with no
  target count or retries.
- `maxAttempts = targetVillages * 50` retry loops and the
  `default_random_engine` / `uniform_*_distribution` draws (`:800-863`).
- Trig-based building scatter (`:875-880`).
- `tryConnectBuildings` neighbour merges, which depend on order (`:890,991+`).
- The 2×2 hard-coded building size (`:113`).
- `VILLAGE_MIN_DISTANCE` pairwise checks (`:836-845`). Site cells make overlap
  impossible by construction.

